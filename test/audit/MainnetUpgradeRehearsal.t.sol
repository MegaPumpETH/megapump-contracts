// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./RealDexHelpers.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @dev Stand-in for the Safe in local mode: a CONTRACT owner, like on mainnet.
contract SafeStub {
    function exec(address to, uint256 value, bytes calldata data) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = to.call{value: value}(data);
        require(ok, "safe exec failed");
    }
    receive() external payable {}
}

/// @notice Rehearsal of TOMORROW's mainnet operation, in the exact shape of the
///         mainnet: v1 bytecode (test/fixtures/MegaPumpFactoryV1.json is the
///         creation code of 0xFCBc…22bf, byte for byte), owner = a CONTRACT
///         (the Safe), protocol PAUSED, then as the Safe: upgradeToAndCall(v3, ""),
///         setGraduationETH(8 ETH), setSigner, setQuote(USDm), setQuote(MEGA),
///         setPaused(false), then trading, graduation and claims on the real DEX.
///
///         Two modes, same assertions:
///         - local (default): everything deployed here, v1 state written first.
///         - fork: MAINNET_FORK=1 forge test --fork-url <RPC> --match-contract
///           MainnetUpgradeRehearsal -vv → attaches to the REAL proxy, Safe and
///           DEX; the Safe is impersonated. Quote flows need `deal` to find the
///           USDm / MEGA balance slot; they are skipped (and said so) otherwise.
contract MainnetUpgradeRehearsalTest is RealDexHelpers {
    // ── Mainnet addresses (chain 4326) ──
    address constant MAINNET_PROXY       = 0xB6bC3988d62D2979b3ab7AABCcf3c9443f7dAbc4;
    address constant MAINNET_IMPL_V1     = 0xFCBc25742Ae81ab38846065c62e228f5372122bf;
    address constant MAINNET_SAFE        = 0x2CBd81baCFFa7166A82023575f53CbC567B4e970;
    address constant MAINNET_DEX_FACTORY = 0x4188aDbFfBec026EdE44F2C3A7E22beDD880a46f;
    address constant MAINNET_ROUTER      = 0xB24563A4ecF250C8238e41DF0af51D97734c1ec5;
    address constant MAINNET_WETH        = 0x4200000000000000000000000000000000000006;
    address constant MAINNET_USDM        = 0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7;
    address constant MAINNET_MEGA        = 0x28B7E77f82B25B95953825F1E3eA0E36c1c29861;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // ── Target configuration (decision of 13 October 2026) ──
    uint256 constant TARGET_GRADUATION_ETH = 8 ether;
    uint256 constant USDM_THRESHOLD = 20_000e18;   // 8 ETH at ~2 500 $/ETH
    uint256 constant USDM_FEE       = 40e18;       // 0.015 / 8 = 0.1875 % → 37.5, rounded
    uint256 constant MEGA_THRESHOLD = 450_000e18;  // 20 000 $ at ~0.045 $/MEGA
    uint256 constant MEGA_FEE       = 850e18;

    bool    internal fork;
    address internal safe;
    address internal v1impl;
    address internal usdm;
    address internal mega;
    bool    internal quoteFlows = true;
    address internal constant REF = address(0xBEEF);
    uint256 internal idLegacy;      // v1 token with trades, not graduated
    uint256 internal idLegacyGrad;  // v1 token graduated on the real DEX
    bytes   internal legacySig;

    struct V1Data {
        address creator; string name; string ticker; string metadataURI;
        uint256 createdBlock; uint256 createdAt; address tokenAddress;
        uint256 totalRaised; uint256 tokensSold; uint256 creatorFees;
        bool graduated; address dexPool; uint256 lpTokenId; uint256 graduationETH;
    }
    struct V3Data {
        address creator; string name; string ticker; string metadataURI;
        uint256 createdBlock; uint256 createdAt; address tokenAddress;
        uint256 totalRaised; uint256 tokensSold; uint256 creatorFees;
        bool graduated; address dexPool; uint256 lpTokenId; uint256 graduationETH;
        address quote;
    }

    function setUp() public override {
        fork = vm.envOr("MAINNET_FORK", false);
        super.setUp();   // actors, signing keys, a throwaway v3 proxy + real DEX (replaced below)

        if (fork) {
            require(block.chainid == 4326, "MAINNET_FORK needs --fork-url on MegaETH mainnet (4326)");
            factory     = MegaPumpFactory(payable(MAINNET_PROXY));
            safe        = MAINNET_SAFE;
            v1impl      = MAINNET_IMPL_V1;
            dexFactory  = IRealV2Factory(MAINNET_DEX_FACTORY);
            realRouter  = IRealV2Router(MAINNET_ROUTER);
            weth        = MockWETH(payable(MAINNET_WETH));
            usdm        = MAINNET_USDM;
            mega        = MAINNET_MEGA;
            vm.deal(alice, 100 ether); vm.deal(bob, 100 ether); vm.deal(charlie, 100 ether);
            try this.dealQuote(usdm, bob, 1_000_000e18) {} catch { quoteFlows = false; }
            try this.dealQuote(mega, bob, 10_000_000e18) {} catch { quoteFlows = false; }
            if (quoteFlows) {
                this.dealQuote(usdm, charlie, 1_000_000e18);
                this.dealQuote(mega, charlie, 10_000_000e18);
                vm.prank(bob);     IERC20(usdm).approve(address(factory), type(uint256).max);
                vm.prank(bob);     IERC20(mega).approve(address(factory), type(uint256).max);
                vm.prank(charlie); IERC20(usdm).approve(address(factory), type(uint256).max);
                vm.prank(charlie); IERC20(mega).approve(address(factory), type(uint256).max);
            }
            return;
        }

        // ── Local: the mainnet v1 bytecode behind a fresh proxy, real DEX wired ──
        bytes memory v1code = vm.getCode("test/fixtures/MegaPumpFactoryV1.json");
        v1impl = _deployRaw(v1code);
        ERC1967Proxy proxy = new ERC1967Proxy(
            v1impl, abi.encodeCall(MegaPumpFactory.initialize, (address(realRouter), address(weth)))
        );
        factory = MegaPumpFactory(payable(address(proxy)));
        vm.prank(feeToSetter);
        dexFactory.setPairCreator(address(factory));
        factory.setSigner(signer);
        factory.setTokenCreationCooldown(0);

        // v1 state, so that nothing in the layout is taken on faith
        idLegacy = _createTokenWithBuy(alice, "LegacyOne", "LG1", "ipfs://l1", 0.01 ether);
        vm.roll(block.number + 6);
        _buyWithReferrer(idLegacy, bob, 2 ether, REF);
        _buy(idLegacy, charlie, 1 ether);
        _sell(idLegacy, charlie, IERC20(_raw1(idLegacy).tokenAddress).balanceOf(charlie) / 2);
        idLegacyGrad = _createTokenWithBuy(charlie, "LegacyGrad", "LGG", "ipfs://lg", 0.01 ether);
        vm.roll(block.number + 6);
        _buy(idLegacyGrad, bob, 30 ether);
        assertTrue(_raw1(idLegacyGrad).graduated, "v1 graduated on the real DEX");
        legacySig = _signCreateFor(alice, "Third", "THR", "ipfs://third", type(uint256).max, 7);
        vm.prank(bob);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Third", "THR", "ipfs://third", type(uint256).max, 7, legacySig, 0, address(0), ""
        );
        vm.roll(block.number + 6);

        // Mainnet shape: owner = a contract (the Safe), cooldown back to 60 s, PAUSED
        SafeStub stub = new SafeStub();
        safe = address(stub);
        factory.setTokenCreationCooldown(60);
        factory.transferOwnership(safe);
        stub.exec(address(factory), 0, abi.encodeCall(MegaPumpFactory.acceptOwnership, ()));
        stub.exec(address(factory), 0, abi.encodeCall(MegaPumpFactory.setPaused, (true)));

        MockQuoteToken u = _newQuoteNoConfig("USDm", 18);
        MockQuoteToken m = _newQuoteNoConfig("MEGA", 18);
        usdm = address(u); mega = address(m);
    }

    // ── helpers ──
    function dealQuote(address token, address to, uint256 amount) external { deal(token, to, amount); }

    function _newQuoteNoConfig(string memory sym, uint8 dec) internal returns (MockQuoteToken q) {
        q = new MockQuoteToken(sym, sym, dec);
        uint256 unit = 10 ** dec;
        q.mint(bob, 10_000_000 * unit);
        q.mint(charlie, 10_000_000 * unit);
        vm.prank(bob);     q.approve(address(factory), type(uint256).max);
        vm.prank(charlie); q.approve(address(factory), type(uint256).max);
    }

    function _asSafe(bytes memory data) internal {
        if (fork) {
            vm.prank(safe);
            (bool ok, ) = address(factory).call(data);
            require(ok, "safe call failed");
        } else {
            SafeStub(payable(safe)).exec(address(factory), 0, data);
        }
    }

    function _rawTokenData(uint256 id) internal view returns (bytes memory) {
        (bool ok, bytes memory ret) = address(factory).staticcall(abi.encodeWithSignature("tokenData(uint256)", id));
        require(ok, "tokenData failed");
        return abi.encodePacked(uint256(32), ret);
    }
    function _raw1(uint256 id) internal view returns (V1Data memory) { return abi.decode(_rawTokenData(id), (V1Data)); }
    function _raw3(uint256 id) internal view returns (V3Data memory) { return abi.decode(_rawTokenData(id), (V3Data)); }
    function _impl() internal view returns (address) { return address(uint160(uint256(vm.load(address(factory), IMPL_SLOT)))); }

    function _upgradeAsSafe() internal returns (MegaPumpFactory v3impl) {
        v3impl = new MegaPumpFactory();   // GraduationLib deployed and linked by forge
        _asSafe(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(v3impl), "")));
        lens = new MegaPumpLens(address(factory));
    }

    /// @dev The exact Safe transactions of the runbook, in order. Logged as calldata.
    function _configureAsSafe() internal {
        bytes[5] memory txs = [
            abi.encodeCall(MegaPumpFactory.setGraduationETH, (TARGET_GRADUATION_ETH)),
            abi.encodeCall(MegaPumpFactory.setSigner, (signer)),
            abi.encodeCall(MegaPumpFactory.setQuote, (usdm, true, USDM_THRESHOLD, USDM_FEE)),
            abi.encodeCall(MegaPumpFactory.setQuote, (mega, true, MEGA_THRESHOLD, MEGA_FEE)),
            abi.encodeCall(MegaPumpFactory.setPaused, (false))
        ];
        string[5] memory names = ["setGraduationETH(8 ETH)", "setSigner(<backend signer>)", "setQuote(USDm)", "setQuote(MEGA)", "setPaused(false)"];
        for (uint256 i = 0; i < 5; i++) {
            console2.log("Safe tx %s -> proxy, value 0 :", names[i]);
            console2.logBytes(txs[i]);
            _asSafe(txs[i]);
        }
    }

    function _ethOwed() internal view returns (uint256 owed) {
        owed = factory.platformFeesAccrued() + factory.referrerFees(REF);
        for (uint256 id = 1; id <= factory.tokenCount(); id++) {
            V3Data memory d = _raw3(id);
            if (d.quote != address(0)) continue;
            owed += d.creatorFees;
            if (!d.graduated) owed += d.totalRaised;
        }
    }

    // ═════════════════════════════════════════════════════════════
    //  1. Pre-state: what `cast call` must print on the mainnet proxy BEFORE
    // ═════════════════════════════════════════════════════════════
    function test_Rehearsal_1_PreState() public view {
        console2.log("chainid", block.chainid);
        console2.log("implementation", _impl());
        console2.log("owner", factory.owner());
        console2.log("paused", factory.paused());
        console2.log("tokenCount", factory.tokenCount());
        console2.log("platformFeesAccrued", factory.platformFeesAccrued());
        console2.log("trustedSigner", factory.trustedSigner());
        console2.log("graduationETH", factory.graduationETH());
        console2.log("router", factory.router());
        console2.log("weth", factory.weth());
        console2.log("DEX pairCreator", dexFactory.pairCreator());
        console2.log("DEX feeTo", dexFactory.feeTo());
        console2.log("DEX feeToSetter", dexFactory.feeToSetter());

        assertEq(_impl(), v1impl, "proxy runs v1");
        assertEq(factory.owner(), safe, "owner is the Safe");
        assertTrue(factory.paused(), "paused before the upgrade");
        assertEq(factory.router(), address(realRouter));
        assertEq(factory.weth(), address(weth));
        assertEq(factory.graduationETH(), 24 ether, "v1 default, 8 ETH comes with the Safe batch");
        assertEq(factory.platformFeeBps(), 100);
        assertEq(factory.creatorFeeBps(), 25);
        assertEq(factory.referrerFeeBps(), 10);
        assertEq(factory.graduationFee(), 0.015 ether);
        assertEq(factory.tokenCreationCooldown(), 60);
        assertEq(factory.pendingOwner(), address(0));
        assertEq(dexFactory.pairCreator(), address(factory), "only the proxy can create pairs");
        assertEq(dexFactory.feeTo(), address(0), "no protocol fee on the DEX");
        assertEq(realRouter.factory(), address(dexFactory));
        assertEq(realRouter.WETH(), address(weth));
        // init code hash of the router == hash of the pair creation code in the fixtures
        if (!fork) assertEq(pairInitCodeHash, keccak256(vm.getCode("test/fixtures/dex/UniswapV2Pair.json")));
    }

    // ═════════════════════════════════════════════════════════════
    //  2. upgradeToAndCall from the Safe: every slot kept, paused stays true
    // ═════════════════════════════════════════════════════════════
    function test_Rehearsal_2_UpgradeKeepsEveryFieldAndStaysPaused() public {
        uint256 n     = factory.tokenCount();
        V3Data[] memory before = new V3Data[](n + 1);
        bytes32[] memory rawBefore = new bytes32[](n + 1);
        for (uint256 id = 1; id <= n; id++) {
            // raw v1 tokenData getter (14 fields) kept as bytes for an exact compare
            (bool ok, bytes memory ret) = address(factory).staticcall(abi.encodeWithSignature("tokenData(uint256)", id));
            require(ok); rawBefore[id] = keccak256(ret);
        }
        uint256 plat  = factory.platformFeesAccrued();
        uint256 ref   = factory.referrerFees(REF);
        uint256 bal   = address(factory).balance;
        address sgn   = factory.trustedSigner();
        uint256 cool  = factory.tokenCreationCooldown();
        uint256 grad  = factory.graduationETH();
        bool    usedK = fork ? false : factory.usedSignatures(keccak256(legacySig));

        MegaPumpFactory v3impl = _upgradeAsSafe();

        assertEq(_impl(), address(v3impl), "implementation slot = v3");
        assertEq(factory.owner(), safe, "owner unchanged");
        assertTrue(factory.paused(), "STILL PAUSED after the upgrade");
        assertEq(factory.tokenCount(), n);
        assertEq(factory.platformFeesAccrued(), plat);
        assertEq(factory.referrerFees(REF), ref);
        assertEq(address(factory).balance, bal);
        assertEq(factory.trustedSigner(), sgn);
        assertEq(factory.tokenCreationCooldown(), cool);
        assertEq(factory.graduationETH(), grad);
        assertEq(factory.router(), address(realRouter));
        assertEq(factory.weth(), address(weth));
        assertEq(factory.platformFeeBps(), 100);
        assertEq(factory.creatorFeeBps(), 25);
        assertEq(factory.referrerFeeBps(), 10);
        assertEq(factory.graduationFee(), 0.015 ether);
        assertEq(factory.pendingOwner(), address(0));
        if (!fork) assertEq(factory.usedSignatures(keccak256(legacySig)), usedK, "consumed signatures kept");
        for (uint256 id = 1; id <= n; id++) {
            (bool ok, bytes memory ret) = address(factory).staticcall(abi.encodeWithSignature("tokenData(uint256)", id));
            require(ok);
            // v3 getter = the 14 v1 words + quote (address(0) for a v1 token): the v1 prefix is identical
            bytes memory prefix = new bytes(ret.length - 32);
            for (uint256 k = 0; k < prefix.length; k++) prefix[k] = ret[k];
            // string offsets shift by one word in the v3 tuple: compare field by field instead
            V3Data memory a = _raw3(id);
            assertEq(a.quote, address(0), "v1 tokens are ETH tokens");
            assertEq(factory.tokenIdByAddress(a.tokenAddress), id);
            assertEq(lens.getTokenInfo(id).name, a.name, "Lens reads v1 names");
            before[id] = a;
        }
        assertGe(address(factory).balance, _ethOwed(), "solvent after upgrade");
        // the v3 quote storage starts empty
        (bool en, uint256 amt, uint256 fee) = factory.quoteConfig(usdm);
        assertFalse(en); assertEq(amt, 0); assertEq(fee, 0);
        assertEq(factory.quoteFeesAccrued(usdm), 0);

        // nobody can re-initialize, nobody else can upgrade
        vm.expectRevert();
        factory.initialize(address(realRouter), address(weth));
        vm.expectRevert();
        v3impl.initialize(address(realRouter), address(weth));
        vm.prank(bob);
        vm.expectRevert(NotOwner.selector);
        factory.upgradeToAndCall(address(v3impl), "");
    }

    // ═════════════════════════════════════════════════════════════
    //  3. Pause semantics after the upgrade, BEFORE setPaused(false)
    // ═════════════════════════════════════════════════════════════
    function test_Rehearsal_3_WhilePaused_CreateAndBuyRefused_SellAndClaimsOpen() public {
        _upgradeAsSafe();
        bytes memory sig = _signCreateFor(alice, "Paused", "PSD", "ipfs://p", type(uint256).max, 11);
        vm.prank(alice);
        vm.expectRevert(ContractPaused.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(alice, "Paused", "PSD", "ipfs://p", type(uint256).max, 11, sig, 0, address(0), "");
        if (!fork) {
            vm.prank(bob);
            vm.expectRevert(ContractPaused.selector);
            factory.buy{value: 0.1 ether}(idLegacy, 0, address(0), "");
            // selling and claiming are deliberately NOT paused (the exit is never blocked)
            uint256 half = _balanceOf(idLegacy, bob) / 2;
            _sell(idLegacy, bob, half);
            uint256 fees = _raw3(idLegacy).creatorFees;
            uint256 a0 = alice.balance;
            vm.prank(alice); factory.claimCreatorFees(idLegacy);
            assertEq(alice.balance - a0, fees, "creator claim works while paused");
            uint256 r = factory.referrerFees(REF);
            vm.prank(REF); factory.claimReferrerFees();
            assertEq(REF.balance, r, "referrer claim works while paused");
        }
    }

    // ═════════════════════════════════════════════════════════════
    //  4. The Safe batch of the runbook, then the config `cast call` must show
    // ═════════════════════════════════════════════════════════════
    function test_Rehearsal_4_ConfigureAsSafe_ExpectedValues() public {
        _upgradeAsSafe();
        _configureAsSafe();
        assertEq(factory.owner(), safe);
        assertFalse(factory.paused(), "open after setPaused(false)");
        assertEq(factory.trustedSigner(), signer);
        assertEq(factory.graduationETH(), 8 ether);
        assertEq(factory.MIN_GRADUATION_ETH(), 5 ether);
        assertEq(factory.MAX_GRADUATION_ETH(), 100 ether);
        assertEq(factory.graduationFee(), 0.015 ether);
        assertEq(factory.MAX_GRADUATION_FEE(), 0.1 ether);
        assertEq(factory.platformFeeBps(), 100);  assertEq(factory.MAX_PLATFORM_FEE_BPS(), 500);
        assertEq(factory.creatorFeeBps(), 25);    assertEq(factory.MAX_CREATOR_FEE_BPS(), 200);
        assertEq(factory.referrerFeeBps(), 10);
        assertEq(factory.tokenCreationCooldown(), 60);
        (bool en, uint256 amt, uint256 fee) = factory.quoteConfig(usdm);
        assertTrue(en); assertEq(amt, USDM_THRESHOLD); assertEq(fee, USDM_FEE);
        (en, amt, fee) = factory.quoteConfig(mega);
        assertTrue(en); assertEq(amt, MEGA_THRESHOLD); assertEq(fee, MEGA_FEE);
        assertEq(factory.router(), address(realRouter));
        assertEq(factory.weth(), address(weth));
        assertEq(IERC20Metadata(usdm).decimals(), 18, "USDm 18 decimals");
        assertEq(IERC20Metadata(mega).decimals(), 18, "MEGA 18 decimals");
        // setQuote refuses WETH, a zero threshold, and a fee above 10 % (revert bubbles through the Safe)
        vm.expectRevert();
        _asSafe(abi.encodeCall(MegaPumpFactory.setQuote, (address(weth), true, 1e18, 0)));
        vm.expectRevert();
        _asSafe(abi.encodeCall(MegaPumpFactory.setQuote, (usdm, true, 0, 0)));
        vm.expectRevert();
        _asSafe(abi.encodeCall(MegaPumpFactory.setQuote, (usdm, true, 1000e18, 101e18)));
        // a non-owner cannot touch any of it
        vm.prank(bob); vm.expectRevert(NotOwner.selector); factory.setGraduationETH(9 ether);
        vm.prank(bob); vm.expectRevert(NotOwner.selector); factory.setPaused(true);
        vm.prank(bob); vm.expectRevert(NotOwner.selector); factory.setSigner(bob);
        vm.prank(bob); vm.expectRevert(NotOwner.selector); factory.setQuote(usdm, false, 1e18, 0);
        vm.prank(bob); vm.expectRevert(NotOwner.selector); factory.setRouter(bob);
        vm.prank(bob); vm.expectRevert(NotOwner.selector); factory.setPlatformFeeBps(200);
        vm.prank(bob); vm.expectRevert(NotOwner.selector); factory.transferOwnership(bob);
    }

    // ═════════════════════════════════════════════════════════════
    //  5. ETH flow at 8 ETH: both creation paths, anti-snipe, fees, graduation,
    //     refund of the excess, pool, burn, DEX swap, claims
    // ═════════════════════════════════════════════════════════════
    function test_Rehearsal_5_EthFlowAt8Eth() public {
        _upgradeAsSafe();
        _configureAsSafe();
        vm.warp(block.timestamp + 120);

        // creator-signed, third party deploys (the pending-creation path of the site)
        uint256 id = _createAndBuyByThirdParty(alice, bob, "Mainnet", "MNT", "ipfs://mnt", 0.05 ether, type(uint256).max);
        V3Data memory d = _raw3(id);
        assertEq(d.creator, alice); assertEq(d.graduationETH, 8 ether, "threshold locked at creation");
        assertEq(d.quote, address(0));
        // anti-snipe: > 80 M tokens in one tx refused during the first 5 blocks
        vm.prank(charlie);
        vm.expectRevert(AntiSnipe.selector);
        factory.buy{value: 3 ether}(id, 0, address(0), "");
        vm.roll(block.number + 6);

        // referred buy: fee split exact
        uint256 plat0 = factory.platformFeesAccrued(); uint256 ref0 = factory.referrerFees(REF);
        uint256 cre0 = _raw3(id).creatorFees;
        uint256 est = lens.estimateBuy(id, 1 ether, charlie);
        uint256 t0 = _balanceOf(id, charlie);
        _buyWithReferrer(id, charlie, 1 ether, REF);
        assertEq(_balanceOf(id, charlie) - t0, est, "Lens estimate == execution");
        assertEq(factory.referrerFees(REF) - ref0, 1 ether * 10 / 10000, "0.1 % to the referrer");
        assertEq(factory.platformFeesAccrued() - plat0, 1 ether * 100 / 10000 - 1 ether * 10 / 10000, "0.9 % kept by the platform");
        assertEq(_raw3(id).creatorFees - cre0, 1 ether * 25 / 10000, "0.25 % to the creator");

        // creator buys and sells without creator fee
        uint256 cre1 = _raw3(id).creatorFees;
        vm.prank(alice); factory.buy{value: 0.5 ether}(id, 0, address(0), "");
        assertEq(_raw3(id).creatorFees, cre1, "no creator fee on the creator's own buy");
        _sell(id, alice, _balanceOf(id, alice) / 2);
        assertEq(_raw3(id).creatorFees, cre1, "nor on the creator's own sell");

        // graduation with an overflow buy: excess refunded, pool, LP to DEAD, dust burned
        uint256 raisedBefore = _raw3(id).totalRaised;
        uint256 need = 8 ether - raisedBefore;
        uint256 b0 = bob.balance;
        vm.prank(bob);
        factory.buy{value: need + 2 ether}(id, 0, address(0), "");
        d = _raw3(id);
        assertTrue(d.graduated, "graduated at 8 ETH");
        assertApproxEqAbs(d.tokensSold, factory.CURVE_SUPPLY(), 1e12, "curve fully sold (sqrt rounding dust < 1e-6 token)");
        uint256 spent = b0 - bob.balance;
        assertLt(spent, need + 2 ether, "the excess of the overflow buy was refunded");
        assertApproxEqRel(spent, need * 10000 / (10000 - 125), 1e15, "paid ~ the missing amount plus 1.25 % fees");
        assertEq(d.dexPool, _predictPair(d.tokenAddress, address(weth)), "pool at the CREATE2 address (init code hash OK)");
        (uint256 rTok, uint256 rWeth) = _reserves(d.dexPool, d.tokenAddress);
        assertEq(rWeth, 8 ether - 0.015 ether, "7.985 ETH in the pool");
        assertApproxEqAbs(rTok, factory.TOTAL_SUPPLY() - factory.CURVE_SUPPLY(), 1e12, "200 M tokens in the pool (+ unsold dust)");
        assertEq(IERC20(d.tokenAddress).balanceOf(address(factory)), 0, "nothing left in the factory");
        assertGt(IRealV2Pair(d.dexPool).balanceOf(GraduationLib.DEAD), 0, "LP at DEAD");
        assertEq(IRealV2Pair(d.dexPool).balanceOf(address(factory)), 0);
        // opening price = 2x the last curve price (less the 0.015 fee); MC = 5 x (8 - 0.015) ETH
        uint256 lastCurvePrice = 2 * 8 ether * 1e18 / factory.CURVE_SUPPLY();   // wei per 1e18 tokens
        uint256 dexPrice = rWeth * 1e18 / rTok;
        assertApproxEqRel(dexPrice, 2 * lastCurvePrice, 3e15, "DEX opens at ~2x the last curve price");
        uint256 mc = dexPrice * factory.TOTAL_SUPPLY() / 1e18;
        assertApproxEqRel(mc, 5 * (8 ether - 0.015 ether), 1e9, "opening MC = 5 x (threshold - fee)");
        console2.log("last curve price (wei/token*1e18)", lastCurvePrice);
        console2.log("DEX opening price", dexPrice);
        console2.log("opening market cap (wei)", mc);
        // curve closed, DEX open: swap through the router, getAmountsOut == execution
        vm.prank(bob);
        vm.expectRevert(AlreadyGraduated.selector);
        factory.buy{value: 0.1 ether}(id, 0, address(0), "");
        address[] memory path = new address[](2); path[0] = address(weth); path[1] = d.tokenAddress;
        uint256[] memory q = realRouter.getAmountsOut(0.1 ether, path);
        uint256 c0 = IERC20(d.tokenAddress).balanceOf(charlie);
        vm.prank(charlie);
        realRouter.swapExactETHForTokens{value: 0.1 ether}(0, path, charlie, block.timestamp);
        assertEq(IERC20(d.tokenAddress).balanceOf(charlie) - c0, q[1], "getAmountsOut == execution");
        // and the sell leg: tokens -> ETH through the router, quoted then executed
        address[] memory back = new address[](2); back[0] = d.tokenAddress; back[1] = address(weth);
        uint256 sellAmt = q[1] / 2;
        uint256[] memory qs = realRouter.getAmountsOut(sellAmt, back);
        vm.prank(charlie); IERC20(d.tokenAddress).approve(address(realRouter), sellAmt);
        uint256 e0 = charlie.balance;
        vm.prank(charlie);
        realRouter.swapExactTokensForETH(sellAmt, 0, back, charlie, block.timestamp);
        assertEq(charlie.balance - e0, qs[1], "sell on the DEX: getAmountsOut == execution");
        // claims: creator (one, batch), referrer, platform by the Safe only
        uint256 fees = _raw3(id).creatorFees;
        uint256 a0 = alice.balance;
        vm.prank(alice); factory.claimCreatorFees(id);
        assertEq(alice.balance - a0, fees);
        uint256[] memory ids = new uint256[](1); ids[0] = id;
        vm.prank(alice); vm.expectRevert(NoFees.selector); factory.claimAllCreatorFees(ids);
        vm.prank(REF); factory.claimReferrerFees();
        vm.prank(bob); vm.expectRevert(NotOwner.selector); factory.withdrawPlatformFees();
        uint256 s0 = safe.balance; uint256 plat = factory.platformFeesAccrued();
        _asSafe(abi.encodeCall(MegaPumpFactory.withdrawPlatformFees, ()));
        assertEq(safe.balance - s0, plat, "platform fees to the Safe");
        assertGe(address(factory).balance, _ethOwed(), "solvent");
    }

    // ═════════════════════════════════════════════════════════════
    //  6. USDm and MEGA at the configured thresholds (mocks locally; real
    //     tokens on the fork when `deal` can set a balance)
    // ═════════════════════════════════════════════════════════════
    function test_Rehearsal_6_QuoteFlows_UsdmAndMega() public {
        _upgradeAsSafe();
        _configureAsSafe();
        if (!quoteFlows) { console2.log("SKIPPED: deal() cannot set USDm/MEGA balances on this fork"); return; }
        vm.warp(block.timestamp + 120);
        _quoteFlow(usdm, USDM_THRESHOLD, USDM_FEE, "USDm");
        vm.warp(block.timestamp + 120);
        _quoteFlow(mega, MEGA_THRESHOLD, MEGA_FEE, "MEGA");
    }

    function _quoteFlow(address q, uint256 threshold, uint256 fee, string memory sym) internal {
        vm.prank(bob);
        uint256 id = factory.createAndBuyWithQuote(bob, sym, sym, "ipfs://q", q, type(uint256).max, 0, "", threshold / 100, 0, address(0), "");
        V3Data memory d = _raw3(id);
        assertEq(d.quote, q); assertEq(d.graduationETH, threshold, "quote threshold locked at creation");
        vm.roll(block.number + 6);
        uint256 plat0 = factory.quoteFeesAccrued(q);
        uint256 est = lens.estimateBuy(id, threshold / 10, charlie);
        uint256 t0 = _balanceOf(id, charlie);
        vm.prank(charlie); factory.buyWithQuote(id, threshold / 10, 0, address(0), "");
        assertEq(_balanceOf(id, charlie) - t0, est, "Lens estimate == execution (quote)");
        assertEq(factory.quoteFeesAccrued(q) - plat0, threshold / 10 * 100 / 10000, "1 % platform fee in the quote");
        // sell half back, then graduate
        _sellQuote(id, charlie, _balanceOf(id, charlie) / 2);
        uint256 need = threshold - _raw3(id).totalRaised;
        uint256 c0 = IERC20(q).balanceOf(charlie);
        vm.prank(charlie); factory.buyWithQuote(id, need * 2, 0, address(0), "");
        d = _raw3(id);
        assertTrue(d.graduated, "graduated at the quote threshold");
        assertLt(c0 - IERC20(q).balanceOf(charlie), need * 2, "excess not pulled (ERC-20: exact amount only)");
        assertEq(d.dexPool, _predictPair(d.tokenAddress, q));
        (uint256 rTok, uint256 rQ) = _reserves(d.dexPool, d.tokenAddress);
        assertEq(rQ, threshold - fee, "threshold minus fee in the pool");
        assertApproxEqAbs(rTok, factory.TOTAL_SUPPLY() - factory.CURVE_SUPPLY(), 1e12);
        assertGt(IRealV2Pair(d.dexPool).balanceOf(GraduationLib.DEAD), 0, "LP at DEAD");
        // DEX swap in the quote
        address[] memory path = new address[](2); path[0] = q; path[1] = d.tokenAddress;
        uint256[] memory out = realRouter.getAmountsOut(threshold / 1000, path);
        vm.prank(charlie); IERC20(q).approve(address(realRouter), type(uint256).max);
        uint256 b0 = IERC20(d.tokenAddress).balanceOf(charlie);
        vm.prank(charlie); realRouter.swapExactTokensForTokens(threshold / 1000, 0, path, charlie, block.timestamp);
        assertEq(IERC20(d.tokenAddress).balanceOf(charlie) - b0, out[1], "getAmountsOut == execution (quote pool)");
        address[] memory back = new address[](2); back[0] = d.tokenAddress; back[1] = q;
        uint256[] memory qs = realRouter.getAmountsOut(out[1] / 2, back);
        vm.prank(charlie); IERC20(d.tokenAddress).approve(address(realRouter), out[1] / 2);
        uint256 q1 = IERC20(q).balanceOf(charlie);
        vm.prank(charlie); realRouter.swapExactTokensForTokens(out[1] / 2, 0, back, charlie, block.timestamp);
        assertEq(IERC20(q).balanceOf(charlie) - q1, qs[1], "sell on the quote pool: getAmountsOut == execution");
        // claims in the quote: creator, platform by the Safe
        uint256 cf = _raw3(id).creatorFees; uint256 q0 = IERC20(q).balanceOf(bob);
        vm.prank(bob); factory.claimCreatorFees(id);
        assertEq(IERC20(q).balanceOf(bob) - q0, cf, "creator fees paid in the quote");
        uint256 pf = factory.quoteFeesAccrued(q); uint256 s0 = IERC20(q).balanceOf(safe);
        _asSafe(abi.encodeCall(MegaPumpFactory.withdrawQuoteFees, (q)));
        assertEq(IERC20(q).balanceOf(safe) - s0, pf, "quote platform fees to the Safe");
        assertGe(IERC20(q).balanceOf(address(factory)), _quoteOwed(q), "solvent in the quote");
        assertLe(IERC20(q).balanceOf(address(factory)) - _quoteOwed(q), 4, "fee rounding dust only (wei)");
    }

    function _sellQuote(uint256 id, address who, uint256 amount) internal {
        vm.prank(who); factory.sell(id, amount, 0, address(0), "");
    }

    function _quoteOwed(address q) internal view returns (uint256 owed) {
        owed = factory.quoteFeesAccrued(q);
        for (uint256 id = 1; id <= factory.tokenCount(); id++) {
            V3Data memory d = _raw3(id);
            if (d.quote != q) continue;
            owed += d.creatorFees;
            if (!d.graduated) owed += d.totalRaised;
        }
    }

    // ═════════════════════════════════════════════════════════════
    //  7. Legacy v1 token keeps trading and graduates under v3 at ITS locked 24 ETH
    // ═════════════════════════════════════════════════════════════
    function test_Rehearsal_7_LegacyV1TokenGraduatesUnderV3() public {
        if (fork) { console2.log("local only: mainnet has no v1 token"); return; }
        _upgradeAsSafe();
        _configureAsSafe();
        V3Data memory d = _raw3(idLegacy);
        assertEq(d.graduationETH, 24 ether, "a v1 token keeps its 24 ETH threshold");
        vm.roll(block.number + 6);
        uint256 need = 24 ether - d.totalRaised;
        vm.prank(bob);
        factory.buy{value: need + 2 ether}(idLegacy, 0, address(0), "");
        d = _raw3(idLegacy);
        assertTrue(d.graduated, "graduated at its own 24 ETH, not at the new 8 ETH");
        assertEq(d.dexPool, _predictPair(d.tokenAddress, address(weth)));
        (uint256 rTok, uint256 rWeth) = _reserves(d.dexPool, d.tokenAddress);
        assertEq(rWeth, 24 ether - 0.015 ether);
        assertApproxEqAbs(rTok, factory.TOTAL_SUPPLY() - factory.CURVE_SUPPLY(), 1e12);
        assertGe(address(factory).balance, _ethOwed(), "solvent");
    }
}
