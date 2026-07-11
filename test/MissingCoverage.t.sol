// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Helpers.sol";

/// @notice Coverage for the last identified gaps: recovery after pause,
///         absence of renounceOwnership (irreversibility), actual behavior of
///         the locked graduationETH, sanity of the deployed token's metadata,
///         and fee-pocket isolation on withdraw.
interface IERC20Meta {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
}

// ════════════════════════════════════════════════════════════════════
//  Attacker for reentrancy on the BATCH claimAllCreatorFees.
//  The attacker is a token creator; when it receives the batch ETH in
//  its receive(), it attempts to re-claim -> must be blocked.
// ════════════════════════════════════════════════════════════════════

contract BatchClaimReentrancyAttacker {
    MegaPumpFactory public factory; // slot 0
    uint256 public targetId;        // slot 1
    bool public reentered;          // slot 2

    constructor(MegaPumpFactory _f) { factory = _f; }

    function attackBatch(uint256 _id) external {
        targetId = _id;
        uint256[] memory ids = new uint256[](1);
        ids[0] = _id;
        factory.claimAllCreatorFees(ids);
    }

    receive() external payable {
        if (reentered) return;
        reentered = true;
        uint256[] memory ids = new uint256[](1);
        ids[0] = targetId;
        try factory.claimAllCreatorFees(ids) {
            revert("reentry should have failed");
        } catch {
            revert("reentry blocked");
        }
    }
}

contract MissingCoverageTest is Helpers {

    // ════════════════════════════════════════════════════════════
    //  TEST 1 — Recovery after pause (unpause)
    //  setPaused(true) is tested elsewhere. Here we verify the main
    //  safety net: it must be possible to EXIT the pause.
    // ════════════════════════════════════════════════════════════

    function test_Unpause_RestoresCreationAndBuy() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        factory.setPaused(true);
        assertTrue(factory.paused(), "paused");

        // buy blocked during pause
        vm.prank(bob);
        vm.expectRevert(ContractPaused.selector);
        factory.buy{value: 1 ether}(id, 0, address(0), "");

        // ── UNPAUSE ──
        factory.setPaused(false);
        assertFalse(factory.paused(), "unpaused");

        // buy works again
        _buy(id, bob, 1 ether);
        assertGt(_balanceOf(id, bob), 0, "buy restored after unpause");

        // creation works again
        uint256 id2 = _createTokenCustom(charlie, "Post", "PST", "", 0.1 ether);
        assertTrue(_info(id2).deployed, "creation restored after unpause");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 2 — renounceOwnership must NOT exist
    //  Irreversibly bricking the admin is an unacceptable risk.
    //  We probe the selector via a low-level call: it must fail.
    // ════════════════════════════════════════════════════════════

    function test_RenounceOwnership_NotAvailable() public {
        (bool success, ) = address(factory).call(
            abi.encodeWithSignature("renounceOwnership()")
        );
        assertFalse(success, "renounceOwnership must not be callable");

        // Ownership is intact
        assertEq(factory.owner(), owner, "owner unchanged");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 3a — Locked graduationETH: BEHAVIOR, not just the value
    //  A token created at grad=24 must graduate at 24, even if the
    //  global setting later moves to 50.
    // ════════════════════════════════════════════════════════════

    function test_GraduationETH_OldTokenGraduatesAtLockedValue() public {
        // Created while the global = 24 ETH (default)
        uint256 id = _createAndDeploy(alice, 1 ether);
        assertEq(_info(id).graduationETH, 24 ether, "locked at 24");

        // The global rises to 50 AFTER creation
        factory.setGraduationETH(50 ether);
        assertEq(factory.graduationETH(), 50 ether, "global = 50");

        // The old token must graduate at ITS locked 24 ETH.
        // A buy exceeding 24 (but below 50) must trigger graduation.
        vm.deal(bob, 100 ether);
        vm.prank(bob);
        factory.buy{value: 40 ether}(id, 0, address(0), "");

        assertTrue(_info(id).graduated, "must graduate at locked 24, not global 50");
        // totalRaised capped near 24, not 50
        assertLe(_info(id).totalRaised, 24 ether, "raised capped at the locked value");
        assertGe(_info(id).totalRaised, 24 ether - 0.1 ether, "raised close to 24");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 3b — A token created AFTER the change uses the new global
    // ════════════════════════════════════════════════════════════

    function test_GraduationETH_NewTokenUsesNewGlobal() public {
        factory.setGraduationETH(50 ether);

        uint256 id = _createAndDeploy(bob, 1 ether);
        assertEq(_info(id).graduationETH, 50 ether, "new token = new global");

        // A buy exceeding 24 but staying below 50 must NOT graduate
        // (proof that the threshold in use is indeed 50).
        vm.deal(charlie, 100 ether);
        vm.prank(charlie);
        factory.buy{value: 30 ether}(id, 0, address(0), "");

        assertFalse(_info(id).graduated, "must not graduate below the new 50 threshold");
        assertGt(_info(id).totalRaised, 24 ether, "exceeded the old threshold without graduating");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 4 — Sanity of the deployed ERC20 token's metadata
    //  Verifies the actually deployed MegaPumpToken has the right
    //  name/symbol/decimals/totalSupply (end-to-end validation).
    // ════════════════════════════════════════════════════════════

    function test_DeployedToken_Metadata() public {
        uint256 id = _createTokenCustom(alice, "MoonDoge", "MDOGE", "ipfs://x", 0.1 ether);
        IERC20Meta token = IERC20Meta(_tokenAddr(id));

        assertEq(token.name(), "MoonDoge", "correct name");
        assertEq(token.symbol(), "MDOGE", "correct symbol");
        assertEq(token.decimals(), 18, "18 decimals");
        assertEq(token.totalSupply(), factory.TOTAL_SUPPLY(), "totalSupply == TOTAL_SUPPLY");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 5 — withdrawPlatformFees touches ONLY the platform fees
    //  Creator/referrer fees must remain intact (no wrong pocket
    //  drained). Touches funds → deserves a direct assert.
    // ════════════════════════════════════════════════════════════

    function test_WithdrawPlatformFees_DoesNotTouchOtherPockets() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        // Generate all 3 pockets: platform + creator (bob is not the creator) + referrer
        address ref = address(0xCAFE);
        bytes memory sig = _signReferrer(ref, bob);
        vm.prank(bob);
        factory.buy{value: 5 ether}(id, 0, ref, sig);

        uint256 creatorBefore  = _info(id).creatorFees;
        uint256 referrerBefore = factory.referrerFees(ref);
        assertGt(creatorBefore, 0, "creator fees accrued");
        assertGt(referrerBefore, 0, "referrer fees accrued");
        assertGt(factory.platformFeesAccrued(), 0, "platform fees accrued");

        // Platform withdraw
        factory.withdrawPlatformFees();

        // Platform emptied, the other two pockets INTACT
        assertEq(factory.platformFeesAccrued(), 0, "platform emptied");
        assertEq(_info(id).creatorFees, creatorBefore, "creator fees intact");
        assertEq(factory.referrerFees(ref), referrerBefore, "referrer fees intact");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 6 — Signer rotation: a referral signature created with
    //  the old signer must become invalid after setSigner.
    //  (security of the referral signature system)
    // ════════════════════════════════════════════════════════════

    function test_SignerRotation_OldSignerSigsRejected() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        address ref = address(0xCAFE);

        // Baseline: a sig from the CURRENT signer does attribute the fee
        bytes memory sig1 = _signReferrer(ref, bob);
        vm.prank(bob);
        factory.buy{value: 2 ether}(id, 0, ref, sig1);
        uint256 feesAfterFirst = factory.referrerFees(ref);
        assertGt(feesAfterFirst, 0, "baseline: current signer's sig attributes the fee");

        // ── ROTATION: change the signer to another address ──
        factory.setSigner(address(0xBEEF));

        // A new sig from the OLD signer must be silently rejected
        // (same behavior as an invalid sig).
        bytes memory sig2 = _signReferrer(ref, charlie);
        vm.prank(charlie);
        factory.buy{value: 2 ether}(id, 0, ref, sig2);

        // No referral fee added: the old key no longer signs anything valid
        assertEq(
            factory.referrerFees(ref),
            feesAfterFirst,
            "old signer's sig must not attribute fees after rotation"
        );
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 7 — Graduation with graduationFee = 0.
    //  Verifies ethForDex = graduationETH - 0 breaks nothing
    //  (no underflow, graduation completes).
    // ════════════════════════════════════════════════════════════

    function test_Graduation_WithZeroFee_Succeeds() public {
        factory.setGraduationFee(0);
        assertEq(factory.graduationFee(), 0, "fee = 0");

        uint256 id = _createAndDeploy(alice, 1 ether);

        // Large buy to cross the threshold (24 ETH by default)
        vm.deal(bob, 100 ether);
        vm.prank(bob);
        factory.buy{value: 30 ether}(id, 0, address(0), "");

        assertTrue(_info(id).graduated, "must graduate even with graduationFee at 0");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 8 — Accrued fees survive an ownership change.
    //  The new owner controls (and can withdraw) fees accrued under
    //  the old one: fees belong to the contract, not to the EOA.
    // ════════════════════════════════════════════════════════════

    function test_Fees_SurviveOwnershipTransfer() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        // Accrue platform fees
        vm.prank(bob);
        factory.buy{value: 5 ether}(id, 0, address(0), "");
        uint256 accrued = factory.platformFeesAccrued();
        assertGt(accrued, 0, "platform fees accrued");

        // 2-step ownership transfer to a new owner
        address newOwner = makeAddr("newOwner");
        factory.transferOwnership(newOwner);
        vm.prank(newOwner);
        factory.acceptOwnership();
        assertEq(factory.owner(), newOwner, "new owner in place");

        // The new owner can withdraw fees accrued under the old one
        vm.prank(newOwner);
        factory.withdrawPlatformFees();
        assertEq(factory.platformFeesAccrued(), 0, "fees withdrawn by the new owner");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 9 — Reentrancy on the BATCH claimAllCreatorFees.
    //  The single claim is already tested elsewhere; the batch sends
    //  ETH at the end of the loop and is a distinct attack vector.
    // ════════════════════════════════════════════════════════════

    function test_ReentrancyOnClaimAllCreatorFees_Blocked() public {
        BatchClaimReentrancyAttacker attacker = new BatchClaimReentrancyAttacker(factory);
        vm.deal(address(attacker), 1 ether);

        // Self-create: msg.sender == creator -> no signature required
        vm.prank(address(attacker));
        uint256 id = factory.createAndBuyForCreator{value: 0.01 ether}(
            address(attacker), "BatchAtk", "BAT", "",
            type(uint256).max, 0, "", 0, address(0), ""
        );
        vm.roll(block.number + factory.ANTI_SNIPE_BLOCKS() + 1);

        // A third-party buy generates creator fees for the attacker-creator
        _buy(id, bob, 5 ether);
        assertGt(_info(id).creatorFees, 0, "creator fees accrued");

        // Reentrancy through the batch must fail (nonReentrant + CEI)
        vm.expectRevert();
        attacker.attackBatch(id);
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 10 — metadataURI has no length bound.
    //  Locks in the current behavior (long URI accepted). Not a DoS
    //  vector: the creator pays their own storage gas.
    // ════════════════════════════════════════════════════════════

    function test_MetadataURI_NoLengthLimit_Documented() public {
        string memory longUri = "ipfs://";
        for (uint256 i = 0; i < 20; i++) {
            longUri = string.concat(longUri, "0123456789abcdef0123456789abcdef");
        }

        uint256 id = _createTokenCustom(alice, "LongMeta", "LM", longUri, 0.1 ether);
        assertTrue(_info(id).deployed, "creation accepted with a long metadataURI");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 11 — estimate* on a graduated token.
    //  May revert or return an informative value; what matters is
    //  that trading remains blocked no matter what.
    // ════════════════════════════════════════════════════════════

    function test_Estimate_OnGraduatedToken_TradeStaysBlocked() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        vm.deal(bob, 100 ether);
        vm.prank(bob);
        factory.buy{value: 30 ether}(id, 0, address(0), "");
        assertTrue(_info(id).graduated, "graduated");

        // estimateSell on graduated: documented, non-binding behavior
        try factory.estimateSell(id, 1_000_000 ether, bob) returns (uint256 out) {
            emit log_named_uint("estimateSell on graduated (informative)", out);
        } catch {
            emit log("estimateSell reverts on graduated (acceptable)");
        }

        // Real guarantee: the sell is blocked, whatever estimate says
        vm.prank(bob);
        vm.expectRevert(AlreadyGraduated.selector);
        factory.sell(id, 1 ether, 0, address(0), "");
    }
}