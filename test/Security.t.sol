// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Helpers.sol";
import "../src/MegaPumpFactory.sol";

/// @notice V2 implementation contract used to test UUPS upgrade.
///         Adds a new function `upgradedMarker()` to verify upgrade succeeded.
contract MegaPumpFactoryV2 is MegaPumpFactory {
    /// @notice New view function only present in V2
    function upgradedMarker() external pure returns (string memory) {
        return "v2";
    }
}

/// @notice Security-critical tests: upgrade safety, ownership transfer, referrer sig.
contract SecurityTest is Helpers {

    // ════════════════════════════════════════════════════════════
    //  TEST 1 — UUPS upgrade preserves state
    //  Deploy V2 impl, upgrade via owner, verify ALL state survives
    //  (tokens, fees, ownership, signer, paused state, fee config)
    // ════════════════════════════════════════════════════════════

    function test_UUPS_UpgradePreservesState() public {
        // ── Setup non-trivial state before upgrade ──
        uint256 id1 = _createAndDeploy(alice, 1 ether);
        _buy(id1, bob, 5 ether);

        // Generate fees (alice creator, bob non-creator → creator fees accrue)
        // Generate referrer fees
        address ref = address(0xCAFE);
        bytes memory sig = _signReferrer(ref, charlie);
        vm.prank(charlie);
        factory.buy{value: 2 ether}(id1, 0, ref, sig);

        // Snapshot ALL critical state
        uint256 totalRaisedBefore     = _info(id1).totalRaised;
        uint256 tokensSoldBefore      = _info(id1).tokensSold;
        uint256 creatorFeesBefore     = _info(id1).creatorFees;
        uint256 platformFeesBefore    = factory.platformFeesAccrued();
        uint256 referrerFeesBefore    = factory.referrerFees(ref);
        address ownerBefore           = factory.owner();
        address signerBefore          = factory.trustedSigner();
        uint256 platformFeeBpsBefore  = factory.platformFeeBps();
        uint256 creatorFeeBpsBefore   = factory.creatorFeeBps();
        uint256 referrerFeeBpsBefore  = factory.referrerFeeBps();
        uint256 graduationETHBefore   = factory.graduationETH();
        uint256 tokenCountBefore      = factory.tokenCount();
        address tokenAddrBefore       = _info(id1).tokenAddress;
        uint256 bobTokensBefore       = _balanceOf(id1, bob);
        uint256 charlieTokensBefore   = _balanceOf(id1, charlie);

        // ── Deploy V2 implementation and upgrade ──
        MegaPumpFactoryV2 v2Impl = new MegaPumpFactoryV2();
        factory.upgradeToAndCall(address(v2Impl), "");

        // ── Verify V2 marker exists (proxy now points at V2) ──
        MegaPumpFactoryV2 upgradedFactory = MegaPumpFactoryV2(payable(address(factory)));
        assertEq(upgradedFactory.upgradedMarker(), "v2", "upgrade succeeded");

        // ── Verify ALL state preserved ──
        assertEq(_info(id1).totalRaised,        totalRaisedBefore,    "totalRaised");
        assertEq(_info(id1).tokensSold,         tokensSoldBefore,     "tokensSold");
        assertEq(_info(id1).creatorFees,        creatorFeesBefore,    "creatorFees");
        assertEq(factory.platformFeesAccrued(), platformFeesBefore,   "platformFees");
        assertEq(factory.referrerFees(ref),     referrerFeesBefore,   "referrerFees");
        assertEq(factory.owner(),               ownerBefore,          "owner");
        assertEq(factory.trustedSigner(),       signerBefore,         "signer");
        assertEq(factory.platformFeeBps(),      platformFeeBpsBefore, "platformFeeBps");
        assertEq(factory.creatorFeeBps(),       creatorFeeBpsBefore,  "creatorFeeBps");
        assertEq(factory.referrerFeeBps(),      referrerFeeBpsBefore, "referrerFeeBps");
        assertEq(factory.graduationETH(),       graduationETHBefore,  "graduationETH");
        assertEq(factory.tokenCount(),          tokenCountBefore,     "tokenCount");
        assertEq(_info(id1).tokenAddress,       tokenAddrBefore,      "tokenAddress");
        assertEq(_balanceOf(id1, bob),          bobTokensBefore,      "bob balance");
        assertEq(_balanceOf(id1, charlie),      charlieTokensBefore,  "charlie balance");

        // ── Verify post-upgrade operations still work ──
        // Bob can still sell his tokens
        uint256 bobBalBefore = bob.balance;
        _sell(id1, bob, bobTokensBefore / 2);
        assertGt(bob.balance, bobBalBefore, "bob received ETH from sell");

        // Alice can still claim creator fees
        vm.prank(alice);
        factory.claimCreatorFees(id1);
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 2 — Only owner can upgrade
    // ════════════════════════════════════════════════════════════

    function test_UUPS_OnlyOwnerCanUpgrade() public {
        MegaPumpFactoryV2 v2Impl = new MegaPumpFactoryV2();

        // Alice (not owner) tries to upgrade
        vm.prank(alice);
        vm.expectRevert(NotOwner.selector);
        factory.upgradeToAndCall(address(v2Impl), "");

        // Verify still on V1 (no marker function)
        // We can't easily test "no upgradedMarker", but we can check the
        // function selector reverts when called
        (bool success,) = address(factory).call(
            abi.encodeWithSignature("upgradedMarker()")
        );
        assertFalse(success, "upgradedMarker not yet present");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 3 — Ownership 2-step: full happy path
    //  Owner proposes transfer, new owner accepts, ownership changes.
    // ════════════════════════════════════════════════════════════

    function test_Ownership_TwoStepTransfer_HappyPath() public {
        address newOwner = alice;
        assertEq(factory.owner(), owner, "initial owner");

        // Step 1: current owner proposes transfer
        factory.transferOwnership(newOwner);

        // Ownership unchanged until accept
        assertEq(factory.owner(), owner, "still old owner before accept");
        assertEq(factory.pendingOwner(), newOwner, "pending owner set");

        // Step 2: new owner accepts
        vm.prank(newOwner);
        factory.acceptOwnership();

        // Ownership transferred
        assertEq(factory.owner(), newOwner, "new owner active");
        assertEq(factory.pendingOwner(), address(0), "pending cleared");

        // Old owner can no longer perform owner-only actions
        vm.expectRevert(NotOwner.selector);
        factory.setPaused(true);

        // New owner can
        vm.prank(newOwner);
        factory.setPaused(true);
        assertTrue(factory.paused(), "new owner paused successfully");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 4 — Only pending owner can accept
    // ════════════════════════════════════════════════════════════

    function test_Ownership_OnlyPendingCanAccept() public {
        factory.transferOwnership(alice);

        // Bob (not pending) tries to accept
        vm.prank(bob);
        vm.expectRevert(NotPendingOwner.selector);
        factory.acceptOwnership();

        // Even old owner can't accept
        vm.expectRevert(NotPendingOwner.selector);
        factory.acceptOwnership();

        // Pending owner (alice) can
        vm.prank(alice);
        factory.acceptOwnership();
        assertEq(factory.owner(), alice);
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 5 — Owner can cancel pending transfer
    // ════════════════════════════════════════════════════════════

    function test_Ownership_CancelPendingTransfer() public {
        factory.transferOwnership(alice);
        assertEq(factory.pendingOwner(), alice);

        // Owner cancels
        factory.cancelTransferOwnership();
        assertEq(factory.pendingOwner(), address(0), "pending cleared");
        assertEq(factory.owner(), owner, "owner unchanged");

        // Alice can no longer accept (she's not the pending owner anymore)
        vm.prank(alice);
        vm.expectRevert(NotPendingOwner.selector);
        factory.acceptOwnership();

        // Cancel with no pending → reverts
        vm.expectRevert(NoPendingTransfer.selector);
        factory.cancelTransferOwnership();
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 6 — Referrer signature edge cases
    //  Invalid sigs must NOT revert (silent skip = no fee), but valid
    //  sigs must work. Self-referral and address(0) referrer must give 0 fee.
    // ════════════════════════════════════════════════════════════

    function test_Referrer_InvalidSignature_SilentSkip() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        address fakeReferrer = address(0xBEEF);
        // Sign for a DIFFERENT trader (charlie) but submit as bob → invalid
        bytes memory wrongSig = _signReferrer(fakeReferrer, charlie);

        uint256 platformBefore = factory.platformFeesAccrued();

        // Bob buys with bad sig — should NOT revert, just skip the ref fee
        vm.prank(bob);
        factory.buy{value: 1 ether}(id, 0, fakeReferrer, wrongSig);

        // Referrer got 0 fee (signature invalid → silently ignored)
        assertEq(factory.referrerFees(fakeReferrer), 0, "no ref fee on bad sig");

        // Platform got the FULL fee (no referrer cut taken)
        uint256 platformDelta = factory.platformFeesAccrued() - platformBefore;
        uint256 expectedFullPlatformFee = (1 ether * factory.platformFeeBps()) / 10000;
        assertEq(platformDelta, expectedFullPlatformFee, "platform got full fee");
    }

    function test_Referrer_SelfReferral_NoFee() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        // Bob signs for himself as referrer
        bytes memory sig = _signReferrer(bob, bob);

        vm.prank(bob);
        factory.buy{value: 1 ether}(id, 0, bob, sig);

        // Self-referral gives 0 fee
        assertEq(factory.referrerFees(bob), 0, "no fee for self-referral");
    }

    function test_Referrer_ZeroAddress_NoFee() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        // Bob buys with no referrer (address(0))
        vm.prank(bob);
        factory.buy{value: 1 ether}(id, 0, address(0), "");

        // Zero address referrer accrues nothing
        assertEq(factory.referrerFees(address(0)), 0, "no fee for zero ref");
    }

    function test_Referrer_SetSignerZero_Reverts() public {
        // Owner cannot accidentally disable the signer system by setting to zero
        vm.expectRevert(InvalidAddress.selector);
        factory.setSigner(address(0));
    }

    function test_Referrer_WrongSignerKey_NoFee() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        // Sign with a key that is NOT the trusted signer
        uint256 fakePk = 0xDEAD;
        address ref = address(0xBEEF);
        bytes32 hash = keccak256(abi.encodePacked(ref, bob));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(fakePk, ethHash);
        bytes memory wrongSig = abi.encodePacked(r, s, v);

        vm.prank(bob);
        factory.buy{value: 1 ether}(id, 0, ref, wrongSig);

        // Wrong signer → silent skip, no fee accrued
        assertEq(factory.referrerFees(ref), 0, "no fee with wrong signer key");
    }

    function test_Referrer_ValidSignature_WorksNormally() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        address ref = address(0xBEEF);
        bytes memory sig = _signReferrer(ref, bob);

        vm.prank(bob);
        factory.buy{value: 1 ether}(id, 0, ref, sig);

        // Valid signature → ref fee accrues
        uint256 expectedRefFee = (1 ether * factory.referrerFeeBps()) / 10000;
        assertEq(factory.referrerFees(ref), expectedRefFee, "valid ref fee accrues");
    }
}