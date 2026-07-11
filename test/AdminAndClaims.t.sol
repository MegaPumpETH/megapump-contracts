// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Helpers.sol";

/// @notice Tests for fee claiming, platform fee withdrawal, and pause behavior.
///         Covers all paths that move user/protocol funds outside of buy/sell.
contract AdminAndClaimsTest is Helpers {

    // ════════════════════════════════════════════════════════════
    //  TEST 1 — claimCreatorFees: single-token claim
    // ════════════════════════════════════════════════════════════

    function test_ClaimCreatorFees_Single() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        // Generate creator fees: bob (non-creator) buys
        _buy(id, bob, 10 ether);

        uint256 expectedFees = _info(id).creatorFees;
        assertGt(expectedFees, 0, "fees accrued");

        // Non-creator cannot claim
        vm.prank(bob);
        vm.expectRevert(NotCreator.selector);
        factory.claimCreatorFees(id);

        // Creator claims successfully
        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        factory.claimCreatorFees(id);

        assertEq(alice.balance - aliceBalBefore, expectedFees, "alice got fees");
        assertEq(_info(id).creatorFees, 0, "fees zeroed");

        // Double-claim reverts
        vm.prank(alice);
        vm.expectRevert(NoFees.selector);
        factory.claimCreatorFees(id);
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 2 — claimAllCreatorFees: batch claim
    // ════════════════════════════════════════════════════════════

    function test_ClaimAllCreatorFees_Batch() public {
        // Alice creates 3 tokens (with distinct names to avoid any pending ambiguity)
        uint256 id1 = _createTokenCustom(alice, "AliceA", "AA", "", 1 ether);
        uint256 id2 = _createTokenCustom(alice, "AliceB", "AB", "", 1 ether);
        uint256 id3 = _createTokenCustom(alice, "AliceC", "AC", "", 1 ether);

        // Bob creates 1 token (alice is NOT creator → must be skipped)
        uint256 idBob = _createTokenCustom(bob, "BobCoin", "BOB", "", 0.01 ether);
        _buy(idBob, charlie, 1 ether);  // generates fees for bob, not alice

        // Bob buys on alice's tokens 1 and 3 (NOT 2 → id2 has zero creator fees beyond default)
        uint256 id2FeesBeforeMoreBuys = _info(id2).creatorFees;
        _buy(id1, bob, 5 ether);
        _buy(id3, bob, 3 ether);

        uint256 fees1 = _info(id1).creatorFees;
        uint256 fees3 = _info(id3).creatorFees;
        uint256 fees2 = _info(id2).creatorFees;
        assertGt(fees1, 0, "id1 has fees");
        assertGt(fees3, 0, "id3 has fees");
        // id2 should have the same fees as right after creation (alice's own first buy: 0 creator fee)
        assertEq(fees2, id2FeesBeforeMoreBuys, "id2 fees unchanged");

        // Alice batch-claims all 4 tokens (including bob's and possibly zero-fee one)
        uint256[] memory ids = new uint256[](4);
        ids[0] = id1; ids[1] = id2; ids[2] = id3; ids[3] = idBob;

        uint256 expectedTotal = fees1 + fees2 + fees3;  // id2 may be 0; idBob skipped (not alice's)
        uint256 aliceBalBefore = alice.balance;

        if (expectedTotal == 0) {
            // All-zero edge case: should revert NoFees
            vm.prank(alice);
            vm.expectRevert(NoFees.selector);
            factory.claimAllCreatorFees(ids);
        } else {
            vm.prank(alice);
            factory.claimAllCreatorFees(ids);
            assertEq(alice.balance - aliceBalBefore, expectedTotal, "got alice's fees only");
            assertEq(_info(id1).creatorFees, 0);
            assertEq(_info(id2).creatorFees, 0);
            assertEq(_info(id3).creatorFees, 0);
            assertGt(_info(idBob).creatorFees, 0, "bob's fees untouched");
        }
    }

    function test_ClaimAllCreatorFees_AllSkipped_Reverts() public {
        // Alice tries to claim on bob's token only → all skipped
        uint256 idBob = _createTokenCustom(bob, "BobCoin", "BOB", "", 0.01 ether);
        _buy(idBob, charlie, 1 ether);

        uint256[] memory ids = new uint256[](1);
        ids[0] = idBob;

        vm.prank(alice);
        vm.expectRevert(NoFees.selector);
        factory.claimAllCreatorFees(ids);
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 3 — claimReferrerFees: full flow
    // ════════════════════════════════════════════════════════════

    function test_ClaimReferrerFees() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        address referrer = address(0xCAFE);
        bytes memory sig = _signReferrer(referrer, bob);
        vm.prank(bob);
        factory.buy{value: 5 ether}(id, 0, referrer, sig);

        uint256 expectedFees = factory.referrerFees(referrer);
        assertGt(expectedFees, 0, "ref fees accrued");

        uint256 refBalBefore = referrer.balance;
        vm.prank(referrer);
        factory.claimReferrerFees();

        assertEq(referrer.balance - refBalBefore, expectedFees, "referrer got fees");
        assertEq(factory.referrerFees(referrer), 0, "fees zeroed");

        vm.prank(referrer);
        vm.expectRevert(NoReferrerFees.selector);
        factory.claimReferrerFees();
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 4 — withdrawPlatformFees: owner-only + reset to zero
    // ════════════════════════════════════════════════════════════

    function test_WithdrawPlatformFees() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        _buy(id, bob, 10 ether);

        uint256 expected = factory.platformFeesAccrued();
        assertGt(expected, 0, "platform fees accrued");

        // Non-owner cannot withdraw
        vm.prank(alice);
        vm.expectRevert(NotOwner.selector);
        factory.withdrawPlatformFees();

        // Owner withdraws
        uint256 ownerBalBefore = owner.balance;
        factory.withdrawPlatformFees();

        assertEq(owner.balance - ownerBalBefore, expected, "owner got fees");
        assertEq(factory.platformFeesAccrued(), 0, "fees zeroed");

        vm.expectRevert(NoFees.selector);
        factory.withdrawPlatformFees();
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 5 — pause behavior: blocks creation/buy, allows sell/claim/withdraw
    //  V2: only one creation entry point (createAndBuyForCreator). Pause must
    //  block it. Users must always be able to exit (sell) and recover (claim).
    // ════════════════════════════════════════════════════════════

    function test_Pause_BlocksCreationAndBuy_AllowsExit() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        address referrer = address(0xCAFE);
        bytes memory sig = _signReferrer(referrer, bob);
        vm.prank(bob);
        factory.buy{value: 5 ether}(id, 0, referrer, sig);

        uint256 bobTokens = _balanceOf(id, bob);
        assertGt(bobTokens, 0);
        assertGt(_info(id).creatorFees, 0);
        assertGt(factory.referrerFees(referrer), 0);
        assertGt(factory.platformFeesAccrued(), 0);

        // ── PAUSE ──
        factory.setPaused(true);

        // ── 1. createAndBuyForCreator blocked ──
        bytes memory creatorSig = _signCreateFor(
            charlie, "X", "X", "", type(uint256).max
        );
        vm.prank(charlie);
        vm.expectRevert(ContractPaused.selector);
        factory.createAndBuyForCreator{value: 0.05 ether}(
            charlie, "X", "X", "",
            type(uint256).max,
            0, creatorSig,
            0, address(0), ""
        );

        // ── 2. buy blocked ──
        vm.prank(charlie);
        vm.expectRevert(ContractPaused.selector);
        factory.buy{value: 1 ether}(id, 0, address(0), "");

        // ── 3. sell still works (user can exit) ──
        vm.prank(bob);
        factory.sell(id, bobTokens / 2, 0, address(0), "");
        assertLt(_balanceOf(id, bob), bobTokens, "bob exited partially");

        // ── 4. claimCreatorFees still works ──
        vm.prank(alice);
        factory.claimCreatorFees(id);

        // ── 5. claimReferrerFees still works ──
        vm.prank(referrer);
        factory.claimReferrerFees();

        // ── 6. withdrawPlatformFees still works ──
        factory.withdrawPlatformFees();
    }
}
