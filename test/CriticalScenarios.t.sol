// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Helpers.sol";

/// @notice Critical security & correctness tests: graduation, sell paths,
///         anti-snipe, reentrancy on all ETH-sending functions.
contract CriticalScenariosTest is Helpers {

    // ────────────────────────────────────────────────────────────
    //  Helper: fill curve to a target totalRaised (in net ETH)
    // ────────────────────────────────────────────────────────────

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
    //  TEST 1 — Sell reverts after graduation
    // ════════════════════════════════════════════════════════════

    function test_SellRevertsAfterGraduation() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        _buy(id, bob, 5 ether);
        uint256 bobTokens = _balanceOf(id, bob);
        assertGt(bobTokens, 0);

        _fillCurveTo(id, 23.985 ether);
        vm.prank(charlie);
        factory.buy{value: 2 ether}(id, 0, address(0), "");
        assertTrue(_info(id).graduated, "should be graduated");

        vm.prank(bob);
        vm.expectRevert(AlreadyGraduated.selector);
        factory.sell(id, bobTokens, 0, address(0), "");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 2 — Buy that lands EXACTLY on graduationETH (no overflow)
    // ════════════════════════════════════════════════════════════

    function test_BuyExactlyOnGraduation_NoOverflowPath() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        _fillCurveTo(id, 19 ether);

        uint256 raisedBefore = _info(id).totalRaised;
        uint256 netNeeded = 24 ether - raisedBefore;
        uint256 feeBps = 125; // charlie not creator
        uint256 exactGross = (netNeeded * 10000 + (10000 - feeBps) - 1) / (10000 - feeBps);

        uint256 charlieBalBefore = charlie.balance;
        vm.prank(charlie);
        factory.buy{value: exactGross}(id, 0, address(0), "");

        uint256 actualSpent = charlieBalBefore - charlie.balance;
        assertApproxEqAbs(actualSpent, exactGross, 1, "no significant refund");

        assertTrue(_info(id).graduated, "graduated at exact threshold");

        uint256 raisedAfter = _info(id).totalRaised;
        assertGe(raisedAfter, 24 ether - 1, "raised at grad - 1 wei min");
        assertLe(raisedAfter, 24 ether, "raised never exceeds grad");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 3 — Sell ALL tokens down to zero (no underflow)
    // ════════════════════════════════════════════════════════════

    function test_SellAllTokensDownToZero() public {
        uint256 id = _createAndDeploy(alice, 2 ether);
        _buy(id, bob, 3 ether);
        uint256 bobTokens = _balanceOf(id, bob);
        uint256 aliceTokens = _balanceOf(id, alice);

        _sell(id, bob, bobTokens);
        assertEq(_balanceOf(id, bob), 0, "bob has zero tokens");

        _sell(id, alice, aliceTokens);
        assertEq(_balanceOf(id, alice), 0, "alice has zero tokens");

        MegaPumpLens.TokenInfo memory info = _info(id);
        assertLe(info.tokensSold, 10, "tokensSold near zero");
        assertLe(info.totalRaised, 1e15, "totalRaised drained (residual fees only)");
        assertFalse(info.graduated, "not graduated, just emptied");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 4 — Sell slippage protection
    // ════════════════════════════════════════════════════════════

    function test_SellSlippageProtection() public {
        uint256 id = _createAndDeploy(alice, 5 ether);
        uint256 aliceTokens = _balanceOf(id, alice);

        vm.prank(alice);
        vm.expectRevert(SlippageExceeded.selector);
        factory.sell(id, aliceTokens, 100 ether, address(0), "");
    }

    function test_SellSlippageJustBelowAcceptable() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        _buy(id, bob, 5 ether);
        uint256 bobTokens = _balanceOf(id, bob);

        uint256 expected = lens.estimateSell(id, bobTokens, bob);

        vm.prank(bob);
        vm.expectRevert(SlippageExceeded.selector);
        factory.sell(id, bobTokens, expected + 1, address(0), "");

        vm.prank(bob);
        factory.sell(id, bobTokens, expected, address(0), "");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 5 — Multi-actor state coherence
    // ════════════════════════════════════════════════════════════

    function test_MultiActorStateCoherence() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        _buy(id, bob, 2 ether);
        _buy(id, charlie, 1.5 ether);
        address dave = address(0xDA1E);
        address eve  = address(0xE1E);
        vm.deal(dave, 100 ether);
        vm.deal(eve, 100 ether);
        _buy(id, dave, 0.5 ether);
        _buy(id, eve, 3 ether);

        uint256 bobTokens = _balanceOf(id, bob);
        _sell(id, bob, bobTokens / 2);
        uint256 charlieTokens = _balanceOf(id, charlie);
        _sell(id, charlie, charlieTokens);
        _buy(id, dave, 1 ether);

        uint256 sumBalances = _balanceOf(id, alice)
            + _balanceOf(id, bob)
            + _balanceOf(id, charlie)
            + _balanceOf(id, dave)
            + _balanceOf(id, eve);

        MegaPumpLens.TokenInfo memory info = _info(id);
        assertEq(info.tokensSold, sumBalances, "tokensSold == sum of holders");

        uint256 contractTokens = IERC20(info.tokenAddress).balanceOf(address(factory));
        uint256 expectedHeld = factory.TOTAL_SUPPLY() - info.tokensSold;
        assertEq(contractTokens, expectedHeld, "factory holds curve remainder");

        uint256 claimable = factory.platformFeesAccrued() + info.creatorFees;
        uint256 expectedBalance = claimable + info.totalRaised;
        uint256 actualBalance = address(factory).balance;
        assertGe(actualBalance, expectedBalance, "contract never short of ETH");
        assertLe(actualBalance - expectedBalance, 100, "drift < 100 wei (rounding)");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 6 — Anti-snipe block-by-block window
    //
    //  V2 NOTE: _createToken() now includes a small first buy (0.01 ether).
    //  This consumes a small portion of the anti-snipe window at block N but
    //  yields very few tokens (well under ANTI_SNIPE_MAX). Subsequent large
    //  buys in the same anti-snipe window still trigger the limit.
    // ════════════════════════════════════════════════════════════

    function test_AntiSnipe_BlockByBlock() public {
        uint256 antiBlocks = factory.ANTI_SNIPE_BLOCKS();

        // Token created at block N (charlie creates with default 0.01 ether buy).
        // Use _createTokenCustomNoSkip so we stay in the anti-snipe window.
        uint256 id2 = _createTokenCustomNoSkip(charlie, "AS", "AS", "", 0.01 ether);

        // Same block N: big buy by bob → must hit anti-snipe
        vm.prank(bob);
        vm.expectRevert(AntiSnipe.selector);
        factory.buy{value: 5 ether}(id2, 0, address(0), "");

        // Blocks N+1 to N+ANTI_SNIPE_BLOCKS: still anti-snipe
        for (uint256 i = 1; i <= antiBlocks; i++) {
            vm.roll(block.number + 1);
            vm.prank(bob);
            vm.expectRevert(AntiSnipe.selector);
            factory.buy{value: 5 ether}(id2, 0, address(0), "");
        }

        // Block N+ANTI_SNIPE_BLOCKS+1: free
        vm.roll(block.number + 1);
        _buy(id2, bob, 5 ether);
        assertGt(_balanceOf(id2, bob), 0, "anti-snipe lifted past window");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 7 — Reentrancy on sell
    // ════════════════════════════════════════════════════════════

    function test_ReentrancyOnSell_Blocked() public {
        uint256 id = _createAndDeploy(alice, 5 ether);
        SellReentrancyAttacker attacker = new SellReentrancyAttacker(factory, id);

        vm.deal(address(attacker), 5 ether);
        attacker.buyTokens{value: 2 ether}();
        uint256 attackerTokens = _balanceOf(id, address(attacker));
        assertGt(attackerTokens, 0);

        vm.expectRevert();
        attacker.attack();
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 8 — Reentrancy on claimCreatorFees and claimReferrerFees
    // ════════════════════════════════════════════════════════════

    function test_ReentrancyOnClaimCreatorFees_Blocked() public {
        // ── Setup: install the attacker contract at an EOA address ──
        // This lets us sign EIP-712 on the attacker's behalf.
        uint256 attackerPk = uint256(keccak256("attacker.pk"));
        address attackerAddr = vm.addr(attackerPk);

        ClaimReentrancyAttacker attackerTemplate = new ClaimReentrancyAttacker(factory);
        vm.etch(attackerAddr, address(attackerTemplate).code);
        // Initialize storage: factory slot 0
        vm.store(attackerAddr, bytes32(uint256(0)), bytes32(uint256(uint160(address(factory)))));

        ClaimReentrancyAttacker attacker = ClaimReentrancyAttacker(payable(attackerAddr));
        vm.deal(attackerAddr, 1 ether);

        // ── Sign + create token with attacker as creator ──
        bytes memory sig = _signCreate(
            attackerPk, attackerAddr,
            "AttackCoin", "ATK", "", type(uint256).max
        );

        vm.prank(attackerAddr);
        uint256 id = factory.createAndBuyForCreator{value: 0.01 ether}(
            attackerAddr, "AttackCoin", "ATK", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );
        vm.roll(block.number + factory.ANTI_SNIPE_BLOCKS() + 1);

        _buy(id, bob, 5 ether);
        assertGt(_info(id).creatorFees, 0, "creator fees accrued");

        vm.expectRevert();
        attacker.attackCreator(id);
    }

    function test_ReentrancyOnClaimReferrerFees_Blocked() public {
        ClaimReentrancyAttacker attacker = new ClaimReentrancyAttacker(factory);
        vm.deal(address(attacker), 1 ether);

        uint256 id = _createAndDeploy(alice, 1 ether);

        bytes memory sig = _signReferrer(address(attacker), bob);
        vm.prank(bob);
        factory.buy{value: 5 ether}(id, 0, address(attacker), sig);

        assertGt(factory.referrerFees(address(attacker)), 0);

        vm.expectRevert();
        attacker.attackReferrer();
    }
}

// ════════════════════════════════════════════════════════════════════
//  Sell reentrancy attacker
// ════════════════════════════════════════════════════════════════════

contract SellReentrancyAttacker {
    MegaPumpFactory public factory;
    uint256 public id;
    bool public reentered;

    constructor(MegaPumpFactory _f, uint256 _id) {
        factory = _f;
        id = _id;
    }

    function buyTokens() external payable {
        factory.buy{value: msg.value}(id, 0, address(0), "");
    }

    function attack() external {
        (, , , , , , address tokenAddr, , , , , , , , ) = factory.tokenData(id);
        IERC20 token = IERC20(tokenAddr);
        uint256 bal = token.balanceOf(address(this));
        factory.sell(id, bal, 0, address(0), "");
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            try factory.sell(id, 1, 0, address(0), "") {
                revert("reentry should have failed");
            } catch {
                revert("reentry blocked");
            }
        }
    }
}

// ════════════════════════════════════════════════════════════════════
//  Claim reentrancy attacker — creator + referrer paths
//
//  V2: cannot create a token by just calling createToken (gone).
//  The attacker uses createAndBuyForCreator with an externally-supplied
//  signature: the test passes the signature in.
// ════════════════════════════════════════════════════════════════════

contract ClaimReentrancyAttacker {
    MegaPumpFactory public factory;
    uint256 public targetId;
    bool public reentered;
    uint8 public mode; // 0 = creator, 1 = referrer

    constructor(MegaPumpFactory _f) { factory = _f; }

    /// @notice Creates a token where the attacker itself is the creator.
    /// @dev    For this to work, the externally-built `sig` must be a valid
    ///         EIP-712 signature where the signer == address(this).
    ///         A contract has no native ECDSA key, so this is only feasible
    ///         via vm.etch in the test setup (see _redeployAttackerAtKnownEOA).
    function createTokenAsCreator(bytes calldata sig) external payable returns (uint256 id) {
        id = factory.createAndBuyForCreator{value: 0.01 ether}(
            address(this),
            "AttackCoin", "ATK", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );
        targetId = id;
    }

    function attackCreator(uint256 _id) external {
        targetId = _id;
        mode = 0;
        factory.claimCreatorFees(_id);
    }

    function attackReferrer() external {
        mode = 1;
        factory.claimReferrerFees();
    }

    receive() external payable {
        if (reentered) return;
        reentered = true;

        if (mode == 0) {
            try factory.claimCreatorFees(targetId) {
                revert("reentry should have failed");
            } catch {
                revert("reentry blocked");
            }
        } else {
            try factory.claimReferrerFees() {
                revert("reentry should have failed");
            } catch {
                revert("reentry blocked");
            }
        }
    }
}
