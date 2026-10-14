// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BondingCurveMath} from "../src/BondingCurveMath.sol";

/// @notice Fuzz tests for the bonding curve's economic invariants.
///         BondingCurveMath is a pure library → no deployment needed,
///         its internal functions are called directly (inlined).
///
///         Core invariant: you can NEVER extract more value from the
///         curve than you put in. If any of these tests fail, Foundry
///         prints the exact counterexample (the inputs that break it) —
///         which is precisely what we want to find before mainnet.
contract BondingCurveFuzzTest is Test {
    uint256 constant CURVE_SUPPLY = 800_000_000 * 1e18;
    uint256 constant MIN_GRAD     = 5 ether;   // = MIN_GRADUATION_ETH
    uint256 constant MAX_GRAD     = 100 ether; // = MAX_GRADUATION_ETH

    // ──────────────────────────────────────────────────────────────────
    //  INVARIANT 1 — A buy → sell round-trip is NEVER profitable.
    //  Buy with E ETH (receive T tokens), then immediately sell those T
    //  tokens back. The ETH returned must never exceed E (gross, before
    //  fees). Otherwise value is created from nothing → the curve is drainable.
    // ──────────────────────────────────────────────────────────────────
    function testFuzz_buyThenSellNeverProfits(
        uint256 currentSold,
        uint256 ethIn,
        uint256 grad
    ) public pure {
        grad        = bound(grad, MIN_GRAD, MAX_GRAD);
        currentSold = bound(currentSold, 0, CURVE_SUPPLY - 1);
        ethIn       = bound(ethIn, 1, 200 ether);

        uint256 tokensOut = BondingCurveMath.getTokensForETH(currentSold, ethIn, grad);
        if (tokensOut == 0) return; // nothing bought, nothing to test

        uint256 newSold = currentSold + tokensOut;
        uint256 ethOut  = BondingCurveMath.getETHForTokens(newSold, tokensOut, grad);

        assertLe(ethOut, ethIn, "PROFITABLE ROUND-TRIP: value extracted from the curve");
    }

    // ──────────────────────────────────────────────────────────────────
    //  INVARIANT 2 — A sell → buy round-trip NEVER yields more tokens.
    //  Sell T tokens (receive E ETH), then buy back with E. The tokens
    //  received must never exceed T. Otherwise value is extractable in
    //  the other direction.
    // ──────────────────────────────────────────────────────────────────
    function testFuzz_sellThenBuyNeverGainsTokens(
        uint256 currentSold,
        uint256 tokensToSell,
        uint256 grad
    ) public pure {
        grad         = bound(grad, MIN_GRAD, MAX_GRAD);
        currentSold  = bound(currentSold, 1, CURVE_SUPPLY);
        tokensToSell = bound(tokensToSell, 1, currentSold);

        uint256 ethOut = BondingCurveMath.getETHForTokens(currentSold, tokensToSell, grad);
        if (ethOut == 0) return;

        uint256 newSold    = currentSold - tokensToSell;
        uint256 tokensBack = BondingCurveMath.getTokensForETH(newSold, ethOut, grad);

        assertLe(tokensBack, tokensToSell, "SELL-THEN-BUY GAINS TOKENS: value extracted");
    }

    // ──────────────────────────────────────────────────────────────────
    //  INVARIANT 3 — tokensSold NEVER exceeds CURVE_SUPPLY,
    //  even with an absurd ETH amount (cap test).
    // ──────────────────────────────────────────────────────────────────
    function testFuzz_neverExceedsCurveSupply(
        uint256 currentSold,
        uint256 ethIn,
        uint256 grad
    ) public pure {
        grad        = bound(grad, MIN_GRAD, MAX_GRAD);
        currentSold = bound(currentSold, 0, CURVE_SUPPLY);
        ethIn       = bound(ethIn, 0, 1_000_000 ether); // deliberately huge

        uint256 tokensOut = BondingCurveMath.getTokensForETH(currentSold, ethIn, grad);
        assertLe(currentSold + tokensOut, CURVE_SUPPLY, "CURVE_SUPPLY exceeded");
    }

    // ──────────────────────────────────────────────────────────────────
    //  INVARIANT 4 — Price is monotonic: more tokens sold ⇒ price never
    //  lower. (Linear curve → price increases with supply.)
    // ──────────────────────────────────────────────────────────────────
    function testFuzz_priceMonotonic(
        uint256 sold1,
        uint256 sold2,
        uint256 grad
    ) public pure {
        grad  = bound(grad, MIN_GRAD, MAX_GRAD);
        sold1 = bound(sold1, 0, CURVE_SUPPLY);
        sold2 = bound(sold2, 0, CURVE_SUPPLY);
        if (sold1 > sold2) (sold1, sold2) = (sold2, sold1);

        uint256 p1 = BondingCurveMath.getCurrentPrice(sold1, grad);
        uint256 p2 = BondingCurveMath.getCurrentPrice(sold2, grad);
        assertLe(p1, p2, "PRICE NOT MONOTONIC as a function of supply");
    }
}