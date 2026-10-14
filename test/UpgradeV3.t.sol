// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Helpers.sol";
import "./mocks/QuoteMocks.sol";

/// @notice Rehearsal of the v2 → v3 upgrade, in place, on a proxy that runs
///         the exact v2 bytecode (main at 4d27a34, the implementation live on
///         testnet): it accumulates real state first (trades, fees, referrer,
///         a graduation, a third-party signature), then is upgraded, and every
///         legacy token, balance and signature must behave as before.
/// @dev    test/fixtures/MegaPumpFactoryV2.json is the creation bytecode of
///         MegaPumpFactory compiled from main at 4d27a34 (same compiler settings).
///         Before the MAINNET upgrade, rerun this with the bytecode of the
///         implementation live on mainnet.
contract UpgradeV3Test is Helpers {
    MockQuoteToken internal usdm;

    uint256 internal idTrade;   // trades, creator fees, referrer fees
    uint256 internal idNear;    // close to graduation
    uint256 internal idGrad;    // graduated in v2
    uint256 internal idThird;   // created by a third party with alice's signature
    bytes   internal thirdSig;

    address internal constant REF = address(0xBEEF);

    /// @dev The 14 fields of the v2 tokenData getter.
    struct V2Data {
        address creator;
        string  name;
        string  ticker;
        string  metadataURI;
        uint256 createdBlock;
        uint256 createdAt;
        address tokenAddress;
        uint256 totalRaised;
        uint256 tokensSold;
        uint256 creatorFees;
        bool    graduated;
        address dexPool;
        uint256 lpTokenId;
        uint256 graduationETH;
    }

    /// @dev The 15 fields of the v3 getter: the v2 ones, then quote.
    struct V3Data {
        address creator;
        string  name;
        string  ticker;
        string  metadataURI;
        uint256 createdBlock;
        uint256 createdAt;
        address tokenAddress;
        uint256 totalRaised;
        uint256 tokensSold;
        uint256 creatorFees;
        bool    graduated;
        address dexPool;
        uint256 lpTokenId;
        uint256 graduationETH;
        address quote;
    }

    function setUp() public override {
        super.setUp(); // mocks and actors; its v3 proxy is replaced below

        // ── A proxy running the v2 bytecode ──
        bytes memory v2code = vm.getCode("test/fixtures/MegaPumpFactoryV2.json");
        address v2impl;
        assembly { v2impl := create(0, add(v2code, 0x20), mload(v2code)) }
        require(v2impl != address(0), "v2 deploy failed");
        ERC1967Proxy proxy = new ERC1967Proxy(
            v2impl, abi.encodeCall(MegaPumpFactory.initialize, (address(router), address(weth)))
        );
        factory = MegaPumpFactory(payable(address(proxy)));
        factory.setSigner(signer);
        factory.setTokenCreationCooldown(0);

        // ── Legacy state, written by v2 (the ETH ABI is the same in v3) ──
        idTrade = _createTokenWithBuy(alice, "Legacy", "LGC", "ipfs://legacy", 0.01 ether);
        vm.roll(block.number + 6);
        _buyWithReferrer(idTrade, bob, 2 ether, REF);
        _buy(idTrade, charlie, 1 ether);
        _sell(idTrade, charlie, IERC20(_raw2(idTrade).tokenAddress).balanceOf(charlie) / 2);

        idNear = _createTokenWithBuy(alice, "Near", "NEAR", "ipfs://near", 0.01 ether);
        vm.roll(block.number + 6);
        _buy(idNear, bob, 20 ether);

        idGrad = _createTokenWithBuy(charlie, "Grad", "GRAD", "ipfs://grad", 0.01 ether);
        vm.roll(block.number + 6);
        _buy(idGrad, bob, 30 ether); // overflow path: graduates, refunds the rest

        thirdSig = _signCreateFor(alice, "Third", "THR", "ipfs://third", type(uint256).max, 7);
        vm.prank(bob);
        idThird = factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Third", "THR", "ipfs://third", type(uint256).max, 7, thirdSig, 0, address(0), ""
        );
        vm.roll(block.number + 6);

        usdm = new MockQuoteToken("MegaUSD", "USDm", 18);
    }

    // ── Raw getter reads (a multi-value return is a tuple: prefix the
    //    offset word to decode it as one struct) ──

    function _rawTokenData(uint256 id) internal view returns (bytes memory) {
        (bool ok, bytes memory ret) = address(factory).staticcall(
            abi.encodeWithSignature("tokenData(uint256)", id)
        );
        require(ok, "tokenData failed");
        return abi.encodePacked(uint256(32), ret);
    }

    function _raw2(uint256 id) internal view returns (V2Data memory) {
        return abi.decode(_rawTokenData(id), (V2Data));
    }

    function _raw3(uint256 id) internal view returns (V3Data memory) {
        return abi.decode(_rawTokenData(id), (V3Data));
    }

    function _upgrade() internal {
        MegaPumpFactory v3impl = new MegaPumpFactory();
        factory.upgradeToAndCall(address(v3impl), "");
        // Lens v3 decodes the 15-field getter: deploy it AFTER the upgrade.
        lens = new MegaPumpLens(address(factory));
    }

    /// @dev Everything owed in ETH stays covered by the ETH the factory holds.
    function _assertEthSolvent() internal view {
        uint256 owed = factory.platformFeesAccrued() + factory.referrerFees(REF);
        for (uint256 id = 1; id <= factory.tokenCount(); id++) {
            MegaPumpLens.TokenInfo memory i = lens.getTokenInfo(id);
            if (i.quote != address(0)) continue;
            owed += i.creatorFees;
            if (!i.graduated) owed += i.totalRaised;
        }
        assertGe(address(factory).balance, owed, "ETH owed > ETH held");
    }

    // ════════════════════════════════════════════════════════════
    //  Tests
    // ════════════════════════════════════════════════════════════

    function test_Upgrade_EveryLegacyFieldUnchanged() public {
        uint256 n = factory.tokenCount();
        V2Data[] memory before = new V2Data[](n + 1);
        for (uint256 id = 1; id <= n; id++) before[id] = _raw2(id);
        uint256 plat = factory.platformFeesAccrued();
        uint256 ref  = factory.referrerFees(REF);
        uint256 grad = factory.graduationETH();
        uint256 bal  = address(factory).balance;
        assertTrue(before[idGrad].graduated, "setup: graduated in v2");

        _upgrade();

        assertEq(factory.tokenCount(), n);
        assertEq(factory.platformFeesAccrued(), plat);
        assertEq(factory.referrerFees(REF), ref);
        assertEq(factory.graduationETH(), grad);
        assertEq(factory.owner(), owner);
        assertEq(address(factory).balance, bal);

        for (uint256 id = 1; id <= n; id++) {
            V2Data memory b = before[id];
            V3Data memory a = _raw3(id);
            assertEq(a.creator, b.creator);
            assertEq(a.name, b.name, "legacy names stay in storage");
            assertEq(a.ticker, b.ticker);
            assertEq(a.metadataURI, b.metadataURI);
            assertEq(a.createdBlock, b.createdBlock);
            assertEq(a.createdAt, b.createdAt);
            assertEq(a.tokenAddress, b.tokenAddress);
            assertEq(a.totalRaised, b.totalRaised);
            assertEq(a.tokensSold, b.tokensSold);
            assertEq(a.creatorFees, b.creatorFees);
            assertEq(a.graduated, b.graduated);
            assertEq(a.dexPool, b.dexPool);
            assertEq(a.lpTokenId, b.lpTokenId);
            assertEq(a.graduationETH, b.graduationETH);
            assertEq(a.quote, address(0), "legacy tokens are quoted in ETH");

            MegaPumpLens.TokenInfo memory i = lens.getTokenInfo(id);
            assertEq(i.name, b.name);
            assertEq(i.totalRaised, b.totalRaised);
            assertEq(factory.tokenIdByAddress(b.tokenAddress), id);
        }
        _assertEthSolvent();
    }

    function test_Upgrade_LegacyTokensTradeClaimAndGraduateInEth() public {
        _upgrade();

        uint256 est = lens.estimateBuy(idTrade, 1 ether, bob);
        uint256 t0 = _balanceOf(idTrade, bob);
        _buyWithReferrer(idTrade, bob, 1 ether, REF);
        assertEq(_balanceOf(idTrade, bob) - t0, est, "estimate == execution");

        uint256 sellAmt = _balanceOf(idTrade, bob) / 3;
        uint256 estOut = lens.estimateSell(idTrade, sellAmt, bob);
        uint256 e0 = bob.balance;
        _sell(idTrade, bob, sellAmt);
        assertEq(bob.balance - e0, estOut, "legacy sell pays ETH");

        uint256 fees = _info(idTrade).creatorFees;
        assertGt(fees, 0);
        uint256 a0 = alice.balance;
        vm.prank(alice);
        factory.claimCreatorFees(idTrade);
        assertEq(alice.balance - a0, fees, "legacy creator fees in ETH");

        uint256 r = factory.referrerFees(REF);
        assertGt(r, 0);
        vm.prank(REF);
        factory.claimReferrerFees();
        assertEq(REF.balance, r, "legacy referrer fees in ETH");

        uint256 plat0 = factory.platformFeesAccrued();
        _buy(idNear, bob, 10 ether);
        assertTrue(_info(idNear).graduated);
        assertEq(router.lastQuote(), address(0), "ETH graduation: addLiquidityETH");
        assertGt(factory.platformFeesAccrued() - plat0, factory.graduationFee(), "trade fee + graduation fee");

        vm.prank(bob);
        vm.expectRevert(AlreadyGraduated.selector);
        factory.buy{value: 1 ether}(idGrad, 0, address(0), "");

        _assertEthSolvent();
    }

    function test_Upgrade_V2ConsumedSignatureStaysConsumed() public {
        _upgrade();
        vm.prank(charlie);
        vm.expectRevert(SignatureAlreadyUsed.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Third", "THR", "ipfs://third", type(uint256).max, 7, thirdSig, 0, address(0), ""
        );
    }

    function test_Upgrade_QuotesOffUntilSetQuote() public {
        _upgrade();
        usdm.mint(bob, 1_000e18);
        vm.prank(bob);
        usdm.approve(address(factory), type(uint256).max);

        vm.prank(bob);
        vm.expectRevert(QuoteNotEnabled.selector);
        factory.createAndBuyWithQuote(
            bob, "Q", "Q", "", address(usdm), type(uint256).max, 0, "", 50e18, 0, address(0), ""
        );

        factory.setQuote(address(usdm), true, 20_000e18, 50e18);
        vm.prank(bob);
        uint256 id = factory.createAndBuyWithQuote(
            bob, "Q", "Q", "", address(usdm), type(uint256).max, 0, "", 50e18, 0, address(0), ""
        );
        assertEq(id, idThird + 1, "ids continue after the legacy ones");
        assertEq(_info(id).quote, address(usdm));
        assertEq(_info(id).name, "Q");
        _assertEthSolvent();
    }

    function test_Upgrade_NewEthTokenReadsNamesFromTheToken() public {
        _upgrade();
        uint256 id = _createTokenWithBuy(bob, "Fresh", "FRSH", "ipfs://fresh", 0.01 ether);
        V3Data memory raw = _raw3(id);
        assertEq(bytes(raw.name).length, 0, "v3 no longer stores names");
        MegaPumpLens.TokenInfo memory i = _info(id);
        assertEq(i.name, "Fresh");
        assertEq(i.ticker, "FRSH");
        assertEq(i.metadataURI, "ipfs://fresh");
        assertEq(i.quote, address(0));
        _assertEthSolvent();
    }
}
