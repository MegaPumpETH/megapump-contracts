// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Helpers.sol";

/// @notice Coverage tests for previously untested zones.
contract CoverageTest is Helpers {

    // ════════════════════════════════════════════════════════════
    //  TESTS 1-3 — Validate the _emitTrade fix
    // ════════════════════════════════════════════════════════════

    function _decodeTradeEvent(Vm.Log memory log)
        internal pure returns (uint256 platformFee, uint256 creatorFee)
    {
        (
            , , , uint256 _platformFee, uint256 _creatorFee, , , , , ,
        ) = abi.decode(
            log.data,
            (bool, uint256, uint256, uint256, uint256, uint256, address, uint256, uint256, uint256, uint256)
        );
        return (_platformFee, _creatorFee);
    }

    function _findTradeLog(Vm.Log[] memory logs) internal pure returns (Vm.Log memory) {
        bytes32 tradeTopic = keccak256(
            "Trade(uint256,address,address,bool,uint256,uint256,uint256,uint256,uint256,address,uint256,uint256,uint256,uint256)"
        );
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == tradeTopic) return logs[i];
        }
        revert("Trade event not found");
    }

    function test_EmitTrade_CreatorBuy_FeesAccurate() public {
        // V2: token already has tokens via initial 0.01 buy. We test a SECOND
        // creator-buy where alice buys again.
        uint256 id = _createAndDeploy(alice, 0.01 ether);

        uint256 buyAmount = 0.1 ether;
        uint256 platformBefore = factory.platformFeesAccrued();
        uint256 creatorBefore  = _info(id).creatorFees;

        vm.recordLogs();
        vm.prank(alice);
        factory.buy{value: buyAmount}(id, 0, address(0), "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 eventPlatformFee, uint256 eventCreatorFee) = _decodeTradeEvent(_findTradeLog(logs));

        uint256 actualPlatformFee = factory.platformFeesAccrued() - platformBefore;
        uint256 actualCreatorFee  = _info(id).creatorFees - creatorBefore;

        assertEq(eventPlatformFee, actualPlatformFee, "platformFee event matches state");
        assertEq(eventCreatorFee,  actualCreatorFee,  "creatorFee event matches state");
        assertEq(actualCreatorFee, 0, "creator buying = no creator fee");
    }

    function test_EmitTrade_CreatorSell_FeesAccurate() public {
        uint256 id = _createAndDeploy(alice, 0.5 ether);
        uint256 aliceTokens = _balanceOf(id, alice);

        uint256 platformBefore     = factory.platformFeesAccrued();
        uint256 creatorFeesBefore  = _info(id).creatorFees;

        vm.recordLogs();
        vm.prank(alice);
        factory.sell(id, aliceTokens / 2, 0, address(0), "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 eventPlatformFee, uint256 eventCreatorFee) = _decodeTradeEvent(_findTradeLog(logs));

        uint256 actualPlatformFee  = factory.platformFeesAccrued() - platformBefore;
        uint256 actualCreatorFee   = _info(id).creatorFees - creatorFeesBefore;

        assertEq(eventPlatformFee, actualPlatformFee, "platformFee event matches state on sell");
        assertEq(eventCreatorFee,  actualCreatorFee,  "creatorFee event matches state on sell");
        assertEq(actualCreatorFee, 0, "creator selling = no creator fee");
    }

    function test_EmitTrade_NonCreatorBuy_FeesAccurate() public {
        uint256 id = _createAndDeploy(alice, 0.1 ether);

        uint256 platformBefore     = factory.platformFeesAccrued();
        uint256 creatorFeesBefore  = _info(id).creatorFees;

        vm.recordLogs();
        vm.prank(bob);
        factory.buy{value: 0.1 ether}(id, 0, address(0), "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 eventPlatformFee, uint256 eventCreatorFee) = _decodeTradeEvent(_findTradeLog(logs));

        uint256 actualPlatformFee = factory.platformFeesAccrued() - platformBefore;
        uint256 actualCreatorFee  = _info(id).creatorFees - creatorFeesBefore;

        assertEq(eventPlatformFee, actualPlatformFee, "non-creator: platformFee match");
        assertEq(eventCreatorFee,  actualCreatorFee,  "non-creator: creatorFee match");
        assertGt(actualCreatorFee, 0, "non-creator buying = creator fee accrued");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 4 — claimCreatorFees AFTER graduation
    // ════════════════════════════════════════════════════════════

    function test_ClaimCreatorFees_AfterGraduation() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        _buy(id, bob, 5 ether);
        uint256 feesBeforeGrad = _info(id).creatorFees;
        assertGt(feesBeforeGrad, 0, "fees accrued");

        vm.deal(charlie, 100 ether);
        vm.prank(charlie);
        factory.buy{value: 30 ether}(id, 0, address(0), "");
        assertTrue(_info(id).graduated, "token graduated");

        uint256 feesAfterGrad = _info(id).creatorFees;
        assertGe(feesAfterGrad, feesBeforeGrad, "fees never decrease before claim");

        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        factory.claimCreatorFees(id);

        assertEq(alice.balance - aliceBalBefore, feesAfterGrad, "alice received all fees");
        assertEq(_info(id).creatorFees, 0, "fees zeroed");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 5 — getTokenInfo bondingProgress = 10000 post-grad
    // ════════════════════════════════════════════════════════════

    function test_GetTokenInfo_PostGraduation() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        vm.deal(charlie, 100 ether);
        vm.prank(charlie);
        factory.buy{value: 30 ether}(id, 0, address(0), "");
        assertTrue(_info(id).graduated);

        MegaPumpLens.TokenInfo memory info = _info(id);
        assertEq(info.bondingProgress, 10000, "bondingProgress maxed post-grad");
        assertTrue(info.graduated);
        assertTrue(info.dexPool != address(0), "dexPool set");
        assertTrue(info.deployed);
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 6 — createAndBuyForCreator with non-zero minTokensOut
    //  (replaces old TEST 6 about createAndBuy)
    // ════════════════════════════════════════════════════════════

    function test_CreateAndBuyForCreator_WithMinTokensOut_PassesWhenAchievable() public {
        bytes memory sig = _signCreateFor(
            alice, "Test", "TST", "", type(uint256).max
        );
        vm.prank(alice);
        uint256 id = factory.createAndBuyForCreator{value: 0.1 ether}(
            alice,
            "Test", "TST", "",
            type(uint256).max,
            0, sig,
            1,             // minTokensOut = 1 wei (trivial)
            address(0), ""
        );
        assertTrue(_info(id).deployed);
        assertGt(_balanceOf(id, alice), 0);
    }

    function test_CreateAndBuyForCreator_WithMinTokensOut_RevertsWhenImpossible() public {
        bytes memory sig = _signCreateFor(
            alice, "Test", "TST", "", type(uint256).max
        );
        vm.prank(alice);
        vm.expectRevert(SlippageExceeded.selector);
        factory.createAndBuyForCreator{value: 0.1 ether}(
            alice,
            "Test", "TST", "",
            type(uint256).max,
            0, sig,
            type(uint256).max,  // impossibly high min
            address(0), ""
        );
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 7 — Buy near curve supply limit
    // ════════════════════════════════════════════════════════════

    function test_BuyNearCurveLimit_ExceedsCurveSupplyOrGraduates() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        vm.deal(bob, 200 ether);
        vm.prank(bob);
        factory.buy{value: 50 ether}(id, 0, address(0), "");

        assertTrue(_info(id).graduated, "should have graduated");

        uint256 sold = _info(id).tokensSold;
        uint256 curveSupply = factory.CURVE_SUPPLY();
        assertGe(sold, curveSupply - 1e18, "tokensSold near CURVE_SUPPLY at graduation");
        assertLe(sold, curveSupply, "tokensSold never exceeds CURVE_SUPPLY");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 8 — getTokenId edge cases
    // ════════════════════════════════════════════════════════════

    function test_GetTokenId_UnknownAddress_Reverts() public {
        vm.expectRevert(TokenNotFound.selector);
        factory.getTokenId(address(0xDEAD));
    }

    function test_GetTokenId_KnownAddress_ReturnsCorrectId() public {
        uint256 id1 = _createTokenCustom(alice, "A", "AA", "", 0.1 ether);
        uint256 id2 = _createTokenCustom(bob,   "B", "BB", "", 0.1 ether);

        address addr1 = _info(id1).tokenAddress;
        address addr2 = _info(id2).tokenAddress;

        assertEq(factory.getTokenId(addr1), id1, "id1 retrieved by address");
        assertEq(factory.getTokenId(addr2), id2, "id2 retrieved by address");
        assertTrue(addr1 != addr2, "addresses are distinct");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 9 — Multiple referrers, concurrent accumulation
    // ════════════════════════════════════════════════════════════

    function test_MultipleReferrers_ConcurrentAccumulation() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        address ref1 = address(0xCAFE);
        address ref2 = address(0xBEEF);

        bytes memory sig1 = _signReferrer(ref1, bob);
        vm.prank(bob);
        factory.buy{value: 2 ether}(id, 0, ref1, sig1);

        bytes memory sig2 = _signReferrer(ref2, charlie);
        vm.prank(charlie);
        factory.buy{value: 3 ether}(id, 0, ref2, sig2);

        sig1 = _signReferrer(ref1, bob);
        vm.prank(bob);
        factory.buy{value: 1 ether}(id, 0, ref1, sig1);

        uint256 expectedRef1 = ((2 ether + 1 ether) * factory.referrerFeeBps()) / 10000;
        uint256 expectedRef2 = (3 ether * factory.referrerFeeBps()) / 10000;

        assertEq(factory.referrerFees(ref1), expectedRef1, "ref1 fees accurate");
        assertEq(factory.referrerFees(ref2), expectedRef2, "ref2 fees accurate");

        uint256 ref1BalBefore = ref1.balance;
        vm.prank(ref1);
        factory.claimReferrerFees();
        assertEq(ref1.balance - ref1BalBefore, expectedRef1, "ref1 claimed correctly");
        assertEq(factory.referrerFees(ref1), 0);

        assertEq(factory.referrerFees(ref2), expectedRef2, "ref2 untouched");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 10 — Name boundary lengths
    //  V2: validation reverts happen BEFORE first-buy execution.
    // ════════════════════════════════════════════════════════════

    function test_TokenName_BoundaryLengths() public {
        // Name = 32 chars exact → OK
        string memory name32 = "12345678901234567890123456789012";
        _createTokenCustom(alice, name32, "TST", "", 0.01 ether);

        // Name = 33 chars → revert
        string memory name33 = "123456789012345678901234567890123";
        bytes memory badSig = _signCreateFor(bob, name33, "TST", "", type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(InvalidName.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            bob, name33, "TST", "",
            type(uint256).max,
            0, badSig,
            0, address(0), ""
        );

        // Name = empty → revert
        bytes memory emptySig = _signCreateFor(charlie, "", "TST", "", type(uint256).max);
        vm.prank(charlie);
        vm.expectRevert(InvalidName.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            charlie, "", "TST", "",
            type(uint256).max,
            0, emptySig,
            0, address(0), ""
        );

        // Name = 1 char → OK
        _createTokenCustom(charlie, "X", "TST", "", 0.01 ether);
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 11 — Ticker boundary lengths
    // ════════════════════════════════════════════════════════════

    function test_TokenTicker_BoundaryLengths() public {
        // Ticker = 10 chars exact → OK
        _createTokenCustom(alice, "Name", "1234567890", "", 0.01 ether);

        // Ticker = 11 chars → revert
        bytes memory badSig = _signCreateFor(bob, "Name", "12345678901", "", type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(InvalidTicker.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            bob, "Name", "12345678901", "",
            type(uint256).max,
            0, badSig,
            0, address(0), ""
        );

        // Ticker = empty → revert
        bytes memory emptySig = _signCreateFor(charlie, "Name", "", "", type(uint256).max);
        vm.prank(charlie);
        vm.expectRevert(InvalidTicker.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            charlie, "Name", "", "",
            type(uint256).max,
            0, emptySig,
            0, address(0), ""
        );

        // Ticker = 1 char → OK
        _createTokenCustom(charlie, "Name", "X", "", 0.01 ether);
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 12 — Burn remaining tokens on graduation
    // ════════════════════════════════════════════════════════════

    function test_BurnRemainingTokens_OnGraduation() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        vm.deal(bob, 100 ether);
        vm.prank(bob);
        factory.buy{value: 50 ether}(id, 0, address(0), "");
        assertTrue(_info(id).graduated);

        address tokenAddr = _info(id).tokenAddress;
        uint256 factoryBalance = IERC20(tokenAddr).balanceOf(address(factory));
        assertEq(factoryBalance, 0, "factory holds 0 tokens post-grad");

        uint256 deadBalance = IERC20(tokenAddr).balanceOf(factory.DEAD());
        uint256 totalSupply = factory.TOTAL_SUPPLY();
        uint256 holders = _balanceOf(id, alice) + _balanceOf(id, bob);
        uint256 pmBalance = IERC20(tokenAddr).balanceOf(address(router));
        assertEq(
            holders + factoryBalance + pmBalance + deadBalance,
            totalSupply,
            "total supply conserved across all holders"
        );
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 13 — claimAllCreatorFees gas profile
    // ════════════════════════════════════════════════════════════

    function test_ClaimAllCreatorFees_BatchGasProfile() public {
        uint256 BATCH_SIZE = 10;

        factory.setTokenCreationCooldown(0);

        uint256[] memory ids = new uint256[](BATCH_SIZE);

        // Generate distinct names to avoid any ambiguity
        for (uint256 i = 0; i < BATCH_SIZE; i++) {
            string memory name = string(abi.encodePacked("Tok", _toStr(i)));
            string memory ticker = string(abi.encodePacked("T", _toStr(i)));
            uint256 id = _createTokenCustom(alice, name, ticker, "", 0.1 ether);
            _buy(id, bob, 0.5 ether);
            ids[i] = id;
        }

        uint256 totalExpected;
        for (uint256 i = 0; i < BATCH_SIZE; i++) {
            totalExpected += _info(ids[i]).creatorFees;
        }
        assertGt(totalExpected, 0);

        uint256 aliceBalBefore = alice.balance;
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        factory.claimAllCreatorFees(ids);
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(alice.balance - aliceBalBefore, totalExpected, "exact total claimed");

        emit log_named_uint("Gas used for batch claim", gasUsed);
        emit log_named_uint("Batch size", BATCH_SIZE);
        emit log_named_uint("Gas per token (avg)", gasUsed / BATCH_SIZE);

        assertLt(gasUsed / BATCH_SIZE, 100_000, "gas per token reasonable");
    }

    /// @dev Tiny uint→string helper for unique names in loops.
    function _toStr(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 tmp = v;
        uint256 len;
        while (tmp != 0) { len++; tmp /= 10; }
        bytes memory buf = new bytes(len);
        while (v != 0) { len--; buf[len] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(buf);
    }
}
