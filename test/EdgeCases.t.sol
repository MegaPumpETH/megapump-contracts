// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Helpers.sol";

/// @notice Final edge cases discovered through adversarial review.
contract EdgeCasesTest is Helpers {

    // ════════════════════════════════════════════════════════════
    //  TEST 1 — Defensive path: refFee >= platformFeeFull cap
    // ════════════════════════════════════════════════════════════

    function test_DefensivePath_RefFeeExceedsPlatformImpossible() public {
        factory.setReferrerFeeBps(99);  // OK, 99 < 100

        vm.expectRevert(ReferrerFeeExceedsPlatformFee.selector);
        factory.setPlatformFeeBps(50);

        assertEq(factory.platformFeeBps(), 100);
        assertEq(factory.referrerFeeBps(), 99);
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 2 — Buy on graduated token reverts AlreadyGraduated
    // ════════════════════════════════════════════════════════════

    function test_BuyOnGraduatedToken_RevertsAlreadyGraduated() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        vm.deal(bob, 100 ether);
        vm.prank(bob);
        factory.buy{value: 50 ether}(id, 0, address(0), "");
        assertTrue(_info(id).graduated);

        vm.prank(charlie);
        vm.expectRevert(AlreadyGraduated.selector);
        factory.buy{value: 1 ether}(id, 0, address(0), "");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 3 — claimAllCreatorFees with mix of graduated + non-graduated
    // ════════════════════════════════════════════════════════════

    function test_ClaimAllCreatorFees_MixedGraduatedAndNot() public {
        uint256 idA = _createTokenCustom(alice, "A", "AA", "", 1 ether);
        _buy(idA, bob, 5 ether);
        uint256 feesA_BeforeGrad = _info(idA).creatorFees;

        vm.deal(charlie, 100 ether);
        vm.prank(charlie);
        factory.buy{value: 30 ether}(idA, 0, address(0), "");
        assertTrue(_info(idA).graduated, "A graduated");
        uint256 feesA_AfterGrad = _info(idA).creatorFees;
        assertGt(feesA_AfterGrad, feesA_BeforeGrad);

        uint256 idB = _createTokenCustom(alice, "B", "BB", "", 1 ether);
        _buy(idB, bob, 2 ether);
        uint256 feesB = _info(idB).creatorFees;
        assertGt(feesB, 0);
        assertFalse(_info(idB).graduated, "B not graduated");

        uint256 idC = _createTokenCustom(alice, "C", "CC", "", 0.1 ether);
        // alice's create-and-deploy is creator-buying → 0 creator fees (only platform)
        uint256 feesC_initial = _info(idC).creatorFees;
        // Could be 0 or near-zero residual

        uint256[] memory ids = new uint256[](3);
        ids[0] = idA; ids[1] = idB; ids[2] = idC;

        uint256 expectedTotal = feesA_AfterGrad + feesB + feesC_initial;
        uint256 aliceBalBefore = alice.balance;

        vm.prank(alice);
        factory.claimAllCreatorFees(ids);

        assertEq(alice.balance - aliceBalBefore, expectedTotal, "got A + B + C fees");
        assertEq(_info(idA).creatorFees, 0);
        assertEq(_info(idB).creatorFees, 0);
        assertEq(_info(idC).creatorFees, 0);
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 4 — Anti-snipe boundary: exact pass/fail
    // ════════════════════════════════════════════════════════════

    function test_AntiSnipe_BoundaryExact() public {
        // Use _createTokenCustomNoSkip to stay in the anti-snipe window
        uint256 id = _createTokenCustomNoSkip(alice, "AS", "AS", "", 0.01 ether);
        uint256 antiMax = factory.ANTI_SNIPE_MAX();

        // Binary search for the ETH amount that yields tokens close to antiMax
        // (the initial 0.01 ether by alice consumed a tiny portion, so we still
        // have ~all of antiMax available to bob in the same window)
        uint256 low = 0.01 ether;
        uint256 high = 1 ether;
        uint256 ethJustBelow = 0;
        uint256 ethJustAbove = 0;

        for (uint256 i = 0; i < 30; i++) {
            uint256 mid = (low + high) / 2;
            uint256 estimate = lens.estimateBuy(id, mid, bob);
            if (estimate <= antiMax) {
                ethJustBelow = mid;
                low = mid + 1;
            } else {
                ethJustAbove = mid;
                high = mid - 1;
            }
            if (low >= high) break;
        }

        require(ethJustBelow > 0, "couldn't find under-bound");
        require(ethJustAbove > 0, "couldn't find over-bound");

        // ethJustBelow passes
        vm.prank(bob);
        factory.buy{value: ethJustBelow}(id, 0, address(0), "");
        uint256 bobTokens = _balanceOf(id, bob);
        assertLe(bobTokens, antiMax, "passed buy stayed under limit");
        assertGt(bobTokens, 0, "got tokens");

        // Fresh token for over-bound test
        uint256 id2 = _createTokenCustomNoSkip(charlie, "AS2", "AS2", "", 0.01 ether);

        vm.prank(bob);
        vm.expectRevert(AntiSnipe.selector);
        factory.buy{value: ethJustAbove}(id2, 0, address(0), "");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 5 — Re-accept ownership after first accept reverts
    // ════════════════════════════════════════════════════════════

    function test_AcceptOwnership_AfterAccept_Reverts() public {
        factory.transferOwnership(alice);

        vm.prank(alice);
        factory.acceptOwnership();
        assertEq(factory.owner(), alice);
        assertEq(factory.pendingOwner(), address(0), "pending cleared");

        vm.prank(alice);
        vm.expectRevert(NotPendingOwner.selector);
        factory.acceptOwnership();

        vm.prank(bob);
        vm.expectRevert(NotPendingOwner.selector);
        factory.acceptOwnership();

        vm.expectRevert(NotPendingOwner.selector);
        factory.acceptOwnership();
    }
}