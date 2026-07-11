// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Helpers.sol";
import "../src/BondingCurveMath.sol";

/// @notice Fuzz tests + stress tests with invariant checks at each step.
///         Goes beyond explicit scenarios to find bugs in random interaction patterns.
contract FuzzAndInvariantsTest is Helpers {

    // ════════════════════════════════════════════════════════════
    //  FUZZ 1 — getTokensForETH never overflows curve supply
    // ════════════════════════════════════════════════════════════

    function testFuzz_GetTokensForETH_NeverExceedsCurveSupply(
        uint256 currentSold,
        uint256 ethAmount
    ) public pure {
        currentSold = bound(currentSold, 0, 800_000_000 * 1e18 - 1);
        ethAmount   = bound(ethAmount,   1, 100 ether);

        uint256 tokens = BondingCurveMath.getTokensForETH(
            currentSold, ethAmount, 24 ether
        );

        assertLe(currentSold + tokens, 800_000_000 * 1e18,
            "tokens + sold exceeds CURVE_SUPPLY");
    }

    // ════════════════════════════════════════════════════════════
    //  FUZZ 2 — Buy/sell round-trip: never profitable for trader
    // ════════════════════════════════════════════════════════════

    function testFuzz_BuySell_RoundTrip_NeverProfit(uint256 ethAmount) public {
        // Stay clear of anti-snipe (max ~0.3 ETH on empty curve)
        ethAmount = bound(ethAmount, 0.001 ether, 0.25 ether);

        uint256 id = _createAndDeploy(alice, 0.5 ether);

        uint256 bobBalBefore = bob.balance;
        _buy(id, bob, ethAmount);
        uint256 bobTokens = _balanceOf(id, bob);

        if (bobTokens == 0) return;

        _sell(id, bob, bobTokens);
        uint256 bobBalAfter = bob.balance;

        // Bob must lose ETH (fees taken on both buy and sell)
        assertLt(bobBalAfter, bobBalBefore, "bob must lose ETH on round-trip");

        // Loss bounded by total fees ~2.5% × 2 = 5% (sanity check)
        uint256 lost = bobBalBefore - bobBalAfter;
        assertLe(lost, ethAmount * 5 / 100, "loss bounded by 5%");
    }

    // ════════════════════════════════════════════════════════════
    //  FUZZ 3 — getETHForTokens stays within totalRaised
    // ════════════════════════════════════════════════════════════

    function testFuzz_GetETHForTokens_BoundedByTotalRaised(
        uint256 ethToBuy,
        uint256 tokensToSellBps
    ) public {
        ethToBuy        = bound(ethToBuy, 0.01 ether, 0.25 ether);
        tokensToSellBps = bound(tokensToSellBps, 1, 10000);

        uint256 id = _createAndDeploy(alice, 0.1 ether);
        _buy(id, bob, ethToBuy);

        uint256 bobTokens = _balanceOf(id, bob);
        if (bobTokens == 0) return;

        uint256 toSell = (bobTokens * tokensToSellBps) / 10000;
        if (toSell == 0) return;

        uint256 ethOutFromCurve = BondingCurveMath.getETHForTokens(
            _info(id).tokensSold,
            toSell,
            _info(id).graduationETH
        );

        assertLe(ethOutFromCurve, _info(id).totalRaised + 1,
            "curve never owes more than what's raised");
    }

    // ════════════════════════════════════════════════════════════
    //  STRESS 1 — Random buy/sell sequence, ETH ledger always balanced
    //
    //  This is our "manual invariant test": run 50 random operations
    //  and verify the ETH ledger holds at every single step.
    //
    //  Invariant: address(factory).balance == totalRaised + platformFees
    //                                       + creatorFees + referrerFees
    //  (with small drift tolerance for rounding, always in contract's favor)
    // ════════════════════════════════════════════════════════════

    function testStress_EthLedgerAlwaysBalanced(uint256 seed) public {
        // Bound seed to give Foundry deterministic but varied scenarios
        seed = bound(seed, 1, type(uint256).max);

        uint256 id = _createAndDeploy(alice, 0.1 ether);
        address[3] memory actors = [alice, bob, charlie];

        for (uint256 i = 0; i < 50; i++) {
            if (_info(id).graduated) break;

            // Pseudo-random action selection from seed + iteration
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address actor = actors[r % 3];
            bool isBuy = (r >> 8) % 2 == 0;

            if (isBuy) {
                uint256 amt = bound(r >> 16, 0.001 ether, 0.05 ether);
                if (_info(id).totalRaised + amt > 20 ether) continue;
                vm.deal(actor, actor.balance + amt);
                vm.prank(actor);
                try factory.buy{value: amt}(id, 0, address(0), "") {} catch {}
            } else {
                uint256 bal = _balanceOf(id, actor);
                if (bal == 0) continue;
                uint256 toSell = bound(r >> 16, 1, bal);
                vm.prank(actor);
                try factory.sell(id, toSell, 0, address(0), "") {} catch {}
            }

            // ── INVARIANT CHECK at each step ──
            _checkLedgerInvariant(id);
        }
    }

    function _checkLedgerInvariant(uint256 id) internal view {
        MegaPumpFactory.TokenInfo memory info = _info(id);
        uint256 expected = info.totalRaised
            + factory.platformFeesAccrued()
            + info.creatorFees;
        // referrer fees are 0 in this test (no referrer used)

        uint256 actual = address(factory).balance;

        // Contract must always have AT LEAST what's owed
        assertGe(actual, expected, "factory short of ETH");

        // Drift bounded by a few wei from rounding
        assertLe(actual - expected, 1000, "drift exceeds 1000 wei");
    }

    // ════════════════════════════════════════════════════════════
    //  STRESS 2 — Token supply invariant always holds
    //
    //  Invariant: tokensSold == TOTAL_SUPPLY - balanceOf(factory)
    //  (i.e., tokens out of the curve = tokens not in factory)
    // ════════════════════════════════════════════════════════════

    function testStress_TokenSupplyAlwaysCoherent(uint256 seed) public {
        seed = bound(seed, 1, type(uint256).max);

        uint256 id = _createAndDeploy(alice, 0.1 ether);
        address[3] memory actors = [alice, bob, charlie];

        for (uint256 i = 0; i < 50; i++) {
            if (_info(id).graduated) break;

            uint256 r = uint256(keccak256(abi.encode(seed, i, "supply")));
            address actor = actors[r % 3];
            bool isBuy = (r >> 8) % 2 == 0;

            if (isBuy) {
                uint256 amt = bound(r >> 16, 0.001 ether, 0.05 ether);
                if (_info(id).totalRaised + amt > 20 ether) continue;
                vm.deal(actor, actor.balance + amt);
                vm.prank(actor);
                try factory.buy{value: amt}(id, 0, address(0), "") {} catch {}
            } else {
                uint256 bal = _balanceOf(id, actor);
                if (bal == 0) continue;
                uint256 toSell = bound(r >> 16, 1, bal);
                vm.prank(actor);
                try factory.sell(id, toSell, 0, address(0), "") {} catch {}
            }

            // ── INVARIANT: tokensSold == TOTAL_SUPPLY - factory's token balance ──
            address tokenAddr = _info(id).tokenAddress;
            uint256 factoryBalance = IERC20(tokenAddr).balanceOf(address(factory));
            uint256 tokensSold = _info(id).tokensSold;

            assertEq(
                tokensSold,
                factory.TOTAL_SUPPLY() - factoryBalance,
                "tokensSold != TOTAL_SUPPLY - factory.balance"
            );
        }
    }

    // ════════════════════════════════════════════════════════════
    //  STRESS 3 — Graduated tokens stay graduated forever
    // ════════════════════════════════════════════════════════════

    function testStress_GraduatedTokensStayGraduated() public {
        uint256 id = _createAndDeploy(alice, 0.1 ether);

        // Force graduation via a series of buys
        for (uint256 i = 0; i < 20; i++) {
            if (_info(id).graduated) break;
            vm.deal(bob, 100 ether);
            vm.prank(bob);
            try factory.buy{value: 5 ether}(id, 0, address(0), "") {} catch {}
        }

        assertTrue(_info(id).graduated, "must have graduated");

        // After graduation, ALL buy/sell attempts must revert
        for (uint256 i = 0; i < 10; i++) {
            vm.deal(charlie, 10 ether);

            vm.prank(charlie);
            try factory.buy{value: 1 ether}(id, 0, address(0), "") {
                revert("buy after graduation must revert");
            } catch {}

            vm.prank(charlie);
            try factory.sell(id, 1, 0, address(0), "") {
                revert("sell after graduation must revert");
            } catch {}

            // Token still marked graduated
            assertTrue(_info(id).graduated, "still graduated");
        }
    }
}