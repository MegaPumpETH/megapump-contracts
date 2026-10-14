// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Helpers.sol";

/// @notice Basic tests for createAndBuyForCreator — atomic token creation + first buy.
///         For exhaustive gasless-specific tests (signature replay, EIP-712 edges,
///         third-party first buy, race conditions, etc.) see GaslessCreation.t.sol.
contract CreateAndBuyForCreatorTest is Helpers {

    // ════════════════════════════════════════════════════════════
    //  TEST 1 — Normal flow: creator self-buys at creation
    // ════════════════════════════════════════════════════════════

    function test_CreateAndBuyForCreator_NormalFlow() public {
        uint256 buyAmount = 0.2 ether;
        uint256 aliceBalBefore = alice.balance;

        bytes memory sig = _signCreateFor(
            alice, "MoonDoge", "MDOGE", "ipfs://moon", type(uint256).max, 0
        );
        vm.prank(alice);
        uint256 id = factory.createAndBuyForCreator{value: buyAmount}(
            alice,
            "MoonDoge", "MDOGE", "ipfs://moon",
            type(uint256).max,
            0,            // nonce
            sig,
            0, address(0), ""
        );

        assertEq(id, 1);
        assertEq(factory.tokenCount(), 1);

        MegaPumpLens.TokenInfo memory info = _info(id);
        assertTrue(info.deployed, "ERC20 deployed");
        assertEq(info.creator, alice);
        assertGt(_balanceOf(id, alice), 0, "creator received tokens");

        assertEq(aliceBalBefore - alice.balance, buyAmount, "exact spend");

        // Alice is creator → only platform fee (1%) → net = 99%
        assertEq(info.totalRaised, (buyAmount * 9900) / 10000, "net = 99%");
        assertEq(factory.platformFeesAccrued(), buyAmount / 100);
        assertEq(info.creatorFees, 0, "no creator fee on creator buy");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 2 — With referrer
    // ════════════════════════════════════════════════════════════

    function test_CreateAndBuyForCreator_WithReferrer() public {
        address referrer = address(0xBEEF);
        bytes memory refSig = _signReferrer(referrer, alice);
        bytes memory sig = _signCreateFor(
            alice, "RefCoin", "REF", "", type(uint256).max, 0
        );

        uint256 buyAmount = 0.2 ether;
        vm.prank(alice);
        uint256 id = factory.createAndBuyForCreator{value: buyAmount}(
            alice,
            "RefCoin", "REF", "",
            type(uint256).max,
            0,            // nonce
            sig,
            0, referrer, refSig
        );

        MegaPumpLens.TokenInfo memory info = _info(id);
        assertTrue(info.deployed);

        uint256 refBps = factory.referrerFeeBps();
        uint256 expectedRefFee = (buyAmount * refBps) / 10000;
        assertEq(factory.referrerFees(referrer), expectedRefFee, "ref fee");

        uint256 grossPlatformFee = (buyAmount * factory.platformFeeBps()) / 10000;
        assertEq(factory.platformFeesAccrued(), grossPlatformFee - expectedRefFee);
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 3 — Anti-snipe blocks massive initial buy
    // ════════════════════════════════════════════════════════════

    function test_CreateAndBuyForCreator_AntiSnipeBlocksMassiveBuy() public {
        vm.deal(alice, 60 ether);

        bytes memory sig = _signCreateFor(
            alice, "InstaGrad", "IGRAD", "", type(uint256).max, 0
        );
        vm.prank(alice);
        vm.expectRevert(AntiSnipe.selector);
        factory.createAndBuyForCreator{value: 50 ether}(
            alice,
            "InstaGrad", "IGRAD", "",
            type(uint256).max,
            0,            // nonce
            sig,
            0, address(0), ""
        );
    }
}
