// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Helpers.sol";

/// @notice Tests for the V2 graduation-overflow refund mechanism.
contract GraduationOverflowTest is Helpers {

    function _fillCurveTo(uint256 id, uint256 targetNetRaised) internal {
        uint256 gradEth = factory.graduationETH();
        require(targetNetRaised < gradEth, "target must be below graduation");

        uint256 current = _info(id).totalRaised;
        if (current >= targetNetRaised) return;

        uint256 needed = targetNetRaised - current;
        uint256 feeBps = factory.platformFeeBps() + factory.creatorFeeBps();
        uint256 gross  = (needed * 10000 + (10000 - feeBps) - 1) / (10000 - feeBps);

        vm.deal(bob, gross + 10 ether);
        _buy(id, bob, gross);
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 1 — No overflow: buy completes without refund
    // ════════════════════════════════════════════════════════════

    function test_BuyNoOverflow_NoRefund() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        uint256 aliceBalBefore = alice.balance;
        uint256 raisedBefore   = _info(id).totalRaised;

        _buy(id, alice, 1 ether);

        assertEq(aliceBalBefore - alice.balance, 1 ether, "no refund expected");

        uint256 expectedNet = 0.99 ether;
        assertEq(_info(id).totalRaised - raisedBefore, expectedNet, "totalRaised correct");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 2 — Overflow: refund correct, graduation triggered
    // ════════════════════════════════════════════════════════════

    function test_BuyExactOverflow_RefundCorrect_AndGraduates() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        _fillCurveTo(id, 23.985 ether);
        assertFalse(_info(id).graduated, "should not be graduated yet");

        uint256 raisedBefore = _info(id).totalRaised;
        uint256 ethNeededNet = 24 ether - raisedBefore;

        uint256 sendAmount = 2 ether;
        uint256 charlieBalBefore = charlie.balance;

        vm.prank(charlie);
        factory.buy{value: sendAmount}(id, 0, address(0), "");

        uint256 raisedAfter = _info(id).totalRaised;
        assertGe(raisedAfter, 24 ether - 1, "totalRaised within 1 wei of grad");
        assertLe(raisedAfter, 24 ether, "totalRaised never exceeds grad");

        assertTrue(_info(id).graduated, "must have graduated");

        uint256 actualSpent = charlieBalBefore - charlie.balance;
        assertLt(actualSpent, sendAmount, "charlie must have been refunded");

        uint256 expectedGross = (ethNeededNet * 10000) / (10000 - 125);
        assertApproxEqAbs(actualSpent, expectedGross, 2, "spent matches expected gross");

        assertGt(_balanceOf(id, charlie), 0, "charlie has tokens");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 3 — Creator buying near graduation
    // ════════════════════════════════════════════════════════════

    function test_BuyOverflow_CreatorBuying() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        _fillCurveTo(id, 23.985 ether);
        assertFalse(_info(id).graduated);

        uint256 raisedBefore = _info(id).totalRaised;
        uint256 ethNeededNet = 24 ether - raisedBefore;
        uint256 aliceBalBefore = alice.balance;

        vm.prank(alice);
        factory.buy{value: 5 ether}(id, 0, address(0), "");

        assertTrue(_info(id).graduated, "graduated");

        uint256 actualSpent = aliceBalBefore - alice.balance;
        uint256 expectedGross = (ethNeededNet * 10000) / (10000 - 100);
        assertApproxEqAbs(actualSpent, expectedGross, 2, "creator spent matches");

        assertLt(actualSpent, 5 ether, "got refunded");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 4 — Overflow with a referrer
    // ════════════════════════════════════════════════════════════

    function test_BuyOverflow_WithReferrer() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        _fillCurveTo(id, 23.985 ether);

        uint256 raisedBefore = _info(id).totalRaised;
        uint256 ethNeededNet = 24 ether - raisedBefore;

        address referrer = address(0xBEEF);
        bytes memory sig = _signReferrer(referrer, charlie);

        uint256 charlieBalBefore = charlie.balance;
        vm.prank(charlie);
        factory.buy{value: 3 ether}(id, 0, referrer, sig);

        assertTrue(_info(id).graduated);

        uint256 actualSpent = charlieBalBefore - charlie.balance;
        uint256 expectedGross = (ethNeededNet * 10000) / (10000 - 125);
        assertApproxEqAbs(actualSpent, expectedGross, 2, "spent matches");

        uint256 refBps = factory.referrerFeeBps();
        uint256 expectedRefFee = (actualSpent * refBps) / 10000;
        assertApproxEqAbs(factory.referrerFees(referrer), expectedRefFee, 2, "ref fee on gross only");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 5a — ETH conservation: refund logic only (no graduation)
    // ════════════════════════════════════════════════════════════

    function test_EthConservation_NoGraduation() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        _fillCurveTo(id, 10 ether);

        uint256 raisedBefore   = _info(id).totalRaised;
        uint256 platformBefore = factory.platformFeesAccrued();
        uint256 creatorBefore  = _info(id).creatorFees;

        uint256 sendAmount = 2 ether;
        uint256 charlieBalBefore = charlie.balance;

        vm.prank(charlie);
        factory.buy{value: sendAmount}(id, 0, address(0), "");

        uint256 deltaRaised   = _info(id).totalRaised - raisedBefore;
        uint256 deltaPlatform = factory.platformFeesAccrued() - platformBefore;
        uint256 deltaCreator  = _info(id).creatorFees - creatorBefore;
        uint256 refunded      = sendAmount - (charlieBalBefore - charlie.balance);

        assertEq(refunded, 0, "no refund when far from graduation");

        uint256 sum = deltaRaised + deltaPlatform + deltaCreator + refunded;
        assertEq(sum, sendAmount, "ETH conserved at wei precision");
        assertFalse(_info(id).graduated, "should not be graduated");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 5b — ETH conservation: full overflow + graduation
    // ════════════════════════════════════════════════════════════

    function test_EthConservation_WithGraduation() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        _fillCurveTo(id, 23.985 ether);

        uint256 raisedBefore   = _info(id).totalRaised;
        uint256 platformBefore = factory.platformFeesAccrued();
        uint256 creatorBefore  = _info(id).creatorFees;
        uint256 gradFee        = factory.graduationFee();

        uint256 sendAmount = 2 ether;
        uint256 charlieBalBefore = charlie.balance;

        vm.prank(charlie);
        factory.buy{value: sendAmount}(id, 0, address(0), "");

        assertTrue(_info(id).graduated, "must have graduated");

        uint256 deltaRaised   = _info(id).totalRaised - raisedBefore;
        uint256 deltaPlatform = factory.platformFeesAccrued() - platformBefore;
        uint256 deltaCreator  = _info(id).creatorFees - creatorBefore;
        uint256 refunded      = sendAmount - (charlieBalBefore - charlie.balance);

        uint256 sum = deltaRaised + (deltaPlatform - gradFee) + deltaCreator + refunded;

        assertApproxEqAbs(sum, sendAmount, 2, "ETH ledger balances after grad fee adjustment");
        assertLe(sum, sendAmount, "no ETH created out of thin air");

        uint256 contractBalance = address(factory).balance;
        uint256 owedToClaimers = factory.platformFeesAccrued() + _info(id).creatorFees;
        assertEq(contractBalance, owedToClaimers, "contract balance matches claimable ledger");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 6 — Exact graduation: msg.value matches needed → no refund
    // ════════════════════════════════════════════════════════════

    function test_BuyExactGraduation_NoRefund() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        _fillCurveTo(id, 23.985 ether);

        uint256 ethNeededNet = 24 ether - _info(id).totalRaised;
        uint256 feeBps = 125;
        uint256 exactGross = (ethNeededNet * 10000 + (10000 - feeBps) - 1) / (10000 - feeBps);

        uint256 charlieBalBefore = charlie.balance;
        vm.prank(charlie);
        factory.buy{value: exactGross}(id, 0, address(0), "");

        uint256 actualSpent = charlieBalBefore - charlie.balance;
        assertApproxEqAbs(actualSpent, exactGross, 1, "no meaningful refund");
        assertTrue(_info(id).graduated, "graduated");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 7 — Tiny overflow (1 wei above)
    // ════════════════════════════════════════════════════════════

    function test_BuyTinyOverflow_DoesNotRevert() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        _fillCurveTo(id, 23.985 ether);

        uint256 ethNeededNet = 24 ether - _info(id).totalRaised;
        uint256 feeBps = 125;
        uint256 exactGross = (ethNeededNet * 10000 + (10000 - feeBps) - 1) / (10000 - feeBps);

        vm.prank(charlie);
        factory.buy{value: exactGross + 1}(id, 0, address(0), "");

        assertTrue(_info(id).graduated);
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 8 — Anti-snipe respected during overflow attempt
    //  V2: createToken now includes the small 0.01 ETH first buy.
    //  Subsequent 5 ETH buy by bob within anti-snipe window still reverts.
    // ════════════════════════════════════════════════════════════

    function test_AntiSnipeRespected_DuringOverflow() public {
        uint256 id = _createTokenCustomNoSkip(alice, "AS", "AS", "", 0.01 ether);

        vm.prank(bob);
        vm.expectRevert(AntiSnipe.selector);
        factory.buy{value: 5 ether}(id, 0, address(0), "");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 9 — Slippage protection on capped tokens
    // ════════════════════════════════════════════════════════════

    function test_Slippage_RejectsCappedTokens() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        _fillCurveTo(id, 23.985 ether);

        vm.prank(charlie);
        vm.expectRevert(SlippageExceeded.selector);
        factory.buy{value: 2 ether}(id, 100_000_000 * 1e18, address(0), "");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 10 — Reentrancy on refund call
    // ════════════════════════════════════════════════════════════

    function test_ReentrancyOnRefund_Blocked() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        _fillCurveTo(id, 23.985 ether);

        ReentrancyAttacker attacker = new ReentrancyAttacker(factory, id);
        vm.deal(address(attacker), 10 ether);

        vm.expectRevert();
        attacker.attack{value: 2 ether}();
    }
}

contract ReentrancyAttacker {
    MegaPumpFactory public factory;
    uint256 public targetId;
    bool public reentered;

    constructor(MegaPumpFactory _f, uint256 _id) {
        factory = _f;
        targetId = _id;
    }

    function attack() external payable {
        factory.buy{value: msg.value}(targetId, 0, address(0), "");
    }

    receive() external payable {
        if (!reentered && address(factory).balance >= 0.1 ether) {
            reentered = true;
            try factory.buy{value: 0.1 ether}(targetId, 0, address(0), "") {
            } catch {
                revert("reentry blocked correctly");
            }
        }
    }
}