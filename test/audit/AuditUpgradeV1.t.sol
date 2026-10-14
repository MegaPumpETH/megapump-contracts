// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./RealDexHelpers.sol";

/// @notice Rehearsal of the MAINNET upgrade: v1 (implementation
///         0xFCBc25742Ae81ab38846065c62e228f5372122bf, source = public repo
///         MegaPumpETH/megapump-contracts @ c9085e4, same compiler settings)
///         → v3.1 (this repo), on the REAL DEX V2 fork, with state written by v1
///         first. Mainnet is empty and paused, but the rehearsal also covers a
///         populated v1 so that nothing in the layout is taken on faith.
/// @dev    test/fixtures/MegaPumpFactoryV1.json = creation bytecode of the v1
///         factory (GraduationLib was internal in v1: no linking).
contract AuditUpgradeV1Test is RealDexHelpers {
    uint256 internal idTrade;
    uint256 internal idGrad;
    uint256 internal idThird;
    bytes   internal thirdSig;
    address internal constant REF = address(0xBEEF);

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
        super.setUp();   // real DEX wired to the v3 proxy from Helpers — replaced below

        bytes memory v1code = vm.getCode("test/fixtures/MegaPumpFactoryV1.json");
        address v1impl = _deployRaw(v1code);
        ERC1967Proxy proxy = new ERC1967Proxy(
            v1impl, abi.encodeCall(MegaPumpFactory.initialize, (address(realRouter), address(weth)))
        );
        factory = MegaPumpFactory(payable(address(proxy)));
        vm.prank(feeToSetter);
        dexFactory.setPairCreator(address(factory));
        factory.setSigner(signer);
        factory.setTokenCreationCooldown(0);

        // v1 state: trades + referrer fees, a graduation on the real DEX, a third-party deploy
        idTrade = _createTokenWithBuy(alice, "LegacyOne", "LG1", "ipfs://l1", 0.01 ether);
        vm.roll(block.number + 6);
        _buyWithReferrer(idTrade, bob, 2 ether, REF);
        _buy(idTrade, charlie, 1 ether);
        _sell(idTrade, charlie, IERC20(_raw1(idTrade).tokenAddress).balanceOf(charlie) / 2);

        idGrad = _createTokenWithBuy(charlie, "LegacyGrad", "LGG", "ipfs://lg", 0.01 ether);
        vm.roll(block.number + 6);
        _buy(idGrad, bob, 30 ether);   // overflow buy → v1 graduation on the real DEX
        assertTrue(_raw1(idGrad).graduated, "v1 graduated on the real DEX");

        thirdSig = _signCreateFor(alice, "Third", "THR", "ipfs://third", type(uint256).max, 7);
        vm.prank(bob);
        idThird = factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Third", "THR", "ipfs://third", type(uint256).max, 7, thirdSig, 0, address(0), ""
        );
        vm.roll(block.number + 6);
    }

    function _rawTokenData(uint256 id) internal view returns (bytes memory) {
        (bool ok, bytes memory ret) = address(factory).staticcall(abi.encodeWithSignature("tokenData(uint256)", id));
        require(ok, "tokenData failed");
        return abi.encodePacked(uint256(32), ret);
    }
    function _raw1(uint256 id) internal view returns (V1Data memory) { return abi.decode(_rawTokenData(id), (V1Data)); }
    function _raw3(uint256 id) internal view returns (V3Data memory) { return abi.decode(_rawTokenData(id), (V3Data)); }

    function _upgrade() internal {
        MegaPumpFactory v3impl = new MegaPumpFactory();   // GraduationLib linked by forge
        factory.upgradeToAndCall(address(v3impl), "");
        lens = new MegaPumpLens(address(factory));
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

    // ── v1 proxy sanity: the estimates live ON the proxy in v1 ──
    function test_V1_ProxyServesEstimatesAndGetTokenInfo() public view {
        (bool ok, bytes memory ret) = address(factory).staticcall(
            abi.encodeWithSignature("estimateBuy(uint256,uint256,address)", idTrade, 1 ether, bob));
        assertTrue(ok, "v1 proxy answers estimateBuy");
        assertGt(abi.decode(ret, (uint256)), 0);
        (ok, ) = address(factory).staticcall(abi.encodeWithSignature("getTokenInfo(uint256)", idTrade));
        assertTrue(ok, "v1 proxy answers getTokenInfo");
    }

    function test_UpgradeV1_EveryFieldUnchanged_AndSolvent() public {
        uint256 n = factory.tokenCount();
        V1Data[] memory before = new V1Data[](n + 1);
        for (uint256 id = 1; id <= n; id++) before[id] = _raw1(id);
        uint256 plat = factory.platformFeesAccrued();
        uint256 ref  = factory.referrerFees(REF);
        uint256 bal  = address(factory).balance;
        uint256 cool = factory.tokenCreationCooldown();
        address sgn  = factory.trustedSigner();

        _upgrade();

        assertEq(factory.tokenCount(), n);
        assertEq(factory.platformFeesAccrued(), plat);
        assertEq(factory.referrerFees(REF), ref);
        assertEq(factory.owner(), owner);
        assertEq(factory.trustedSigner(), sgn);
        assertEq(factory.tokenCreationCooldown(), cool);
        assertEq(factory.router(), address(realRouter));
        assertEq(factory.weth(), address(weth));
        assertEq(factory.graduationETH(), 24 ether);
        assertEq(factory.platformFeeBps(), 100);
        assertEq(factory.creatorFeeBps(), 25);
        assertEq(factory.referrerFeeBps(), 10);
        assertEq(factory.graduationFee(), 0.015 ether);
        assertEq(factory.pendingOwner(), address(0));
        assertEq(address(factory).balance, bal);
        assertFalse(factory.paused());

        for (uint256 id = 1; id <= n; id++) {
            V1Data memory b = before[id];
            V3Data memory a = _raw3(id);
            assertEq(a.creator, b.creator);
            assertEq(a.name, b.name, "v1 names stay in storage");
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
            assertEq(a.quote, address(0), "v1 tokens are ETH tokens");
            assertEq(factory.tokenIdByAddress(b.tokenAddress), id);
            MegaPumpLens.TokenInfo memory i = lens.getTokenInfo(id);
            assertEq(i.name, b.name, "Lens reads v1 names from storage");
            assertEq(i.quote, address(0));
        }
        assertGe(address(factory).balance, _ethOwed(), "solvent after upgrade");
        // the v1 pool is still the pool
        assertEq(dexFactory.getPair(before[idGrad].tokenAddress, address(weth)), before[idGrad].dexPool);
    }

    function test_UpgradeV1_ConsumedSignatureStaysConsumed_SigHashKey() public {
        _upgrade();
        // v1 stored usedSignatures[keccak(sig)]; v3 checks both keys
        assertTrue(factory.usedSignatures(keccak256(thirdSig)), "v1 key still set");
        vm.prank(charlie);
        vm.expectRevert(SignatureAlreadyUsed.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Third", "THR", "ipfs://third", type(uint256).max, 7, thirdSig, 0, address(0), ""
        );
        // and the creator's own replay is blocked too
        vm.prank(alice);
        vm.expectRevert(SignatureAlreadyUsed.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Third", "THR", "ipfs://third", type(uint256).max, 7, thirdSig, 0, address(0), ""
        );
    }

    function test_UpgradeV1_LegacyTokenTradesClaimsAndGraduatesOnRealDex() public {
        _upgrade();
        uint256 est = lens.estimateBuy(idTrade, 1 ether, bob);
        uint256 t0 = _balanceOf(idTrade, bob);
        _buyWithReferrer(idTrade, bob, 1 ether, REF);
        assertEq(_balanceOf(idTrade, bob) - t0, est, "Lens estimate == v3 execution on a v1 token");

        uint256 fees = _raw3(idTrade).creatorFees;
        uint256 a0 = alice.balance;
        vm.prank(alice);
        factory.claimCreatorFees(idTrade);
        assertEq(alice.balance - a0, fees);

        uint256 r = factory.referrerFees(REF);
        vm.prank(REF);
        factory.claimReferrerFees();
        assertEq(REF.balance, r);

        // graduate the legacy token under v3 on the real DEX
        _graduateEth(idTrade, bob);
        V3Data memory d = _raw3(idTrade);
        assertEq(d.dexPool, _predictPair(d.tokenAddress, address(weth)));
        (uint256 rTok, uint256 rWeth) = _reserves(d.dexPool, d.tokenAddress);
        assertEq(rWeth, d.totalRaised - factory.graduationFee());
        assertEq(rTok, factory.TOTAL_SUPPLY() - d.tokensSold);
        assertGe(address(factory).balance, _ethOwed(), "solvent");
    }

    function test_UpgradeV1_QuotesWorkAfterSetQuote() public {
        _upgrade();
        MockQuoteToken usdm = _newQuote("USDm", 18);
        uint256 id = _createQuoteToken(bob, usdm, 50e18);
        assertEq(id, idThird + 1);
        assertEq(lens.getTokenInfo(id).quote, address(usdm));
        vm.roll(block.number + 6);
        vm.prank(charlie);
        factory.buyWithQuote(id, 30_000e18, 0, address(0), "");
        assertTrue(lens.getTokenInfo(id).graduated);
        uint256 owed = factory.quoteFeesAccrued(address(usdm)) + lens.getTokenInfo(id).creatorFees;
        assertGe(usdm.balanceOf(address(factory)), owed);
        assertLe(usdm.balanceOf(address(factory)) - owed, 4, "dust only");
    }

    /// @dev Deployment ordering: after the upgrade the proxy no longer serves the
    ///      estimates. The mainnet front reads them ON THE PROXY (lib/chains.ts,
    ///      lens = proxy): it must point at a deployed Lens BEFORE the upgrade.
    function test_UpgradeV1_ProxyLosesEstimates_FrontMustSwitchToLensFirst() public {
        _upgrade();
        (bool ok, ) = address(factory).staticcall(
            abi.encodeWithSignature("estimateBuy(uint256,uint256,address)", idTrade, 1 ether, bob));
        assertFalse(ok, "estimateBuy on the proxy reverts after the upgrade");
        (ok, ) = address(factory).staticcall(abi.encodeWithSignature("getTokenInfo(uint256)", idTrade));
        assertFalse(ok, "getTokenInfo on the proxy reverts after the upgrade");
        assertGt(lens.estimateBuy(idTrade, 1 ether, bob), 0, "the Lens answers");
    }

    function test_UpgradeV1_OnlyOwner_AndNoReinitialize() public {
        MegaPumpFactory v3impl = new MegaPumpFactory();
        vm.prank(bob);
        vm.expectRevert(NotOwner.selector);
        factory.upgradeToAndCall(address(v3impl), "");
        _upgrade();
        vm.expectRevert();   // InvalidInitialization
        factory.initialize(address(realRouter), address(weth));
        vm.expectRevert();   // implementation itself is locked
        v3impl.initialize(address(realRouter), address(weth));
    }
}
