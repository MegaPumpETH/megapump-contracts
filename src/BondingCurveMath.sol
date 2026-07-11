// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ── Custom error used by this library ─────────────────────────
error NotEnoughSold();
error InsufficientLiquidity();

/// @title  BondingCurveMath
/// @notice Pure math library for MegaPumpFactory — bonding curve pricing and DEX pool helpers.
/// @dev    Extracted from MegaPumpFactory to stay under the 24 576-byte contract size limit.
///         All functions are `internal pure/view`
///         not deployed as a separate contract. No state is read or written here.
///
///         Curve model: linear price growth → quadratic cost function.
///         price(sold) = 2 × graduationETH × sold / CURVE_SUPPLY²
///         cost(0 → N) = graduationETH × N² / CURVE_SUPPLY²
library BondingCurveMath {

    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;
    uint256 internal constant CURVE_SUPPLY = 800_000_000   * 1e18; // 80% on bonding curve

    // ============================================================
    //  BONDING CURVE — BUY SIDE
    // ============================================================

    /// @notice Returns tokens received for a given net ETH amount (fees already deducted).
    /// @dev    Solves the quadratic: newSold² = currentSold² + (ethAmount × CURVE_SUPPLY) / graduationETH
    ///         Derived from integrating the linear price curve.
    /// @param currentSold   Tokens already sold (wei)
    /// @param ethAmount     Net ETH entering the curve — after platform + creator fees (wei)
    /// @param graduationETH Target ETH to reach graduation (wei)
    /// @return tokens       Amount of tokens to transfer to the buyer (wei)
    function getTokensForETH(
        uint256 currentSold,
        uint256 ethAmount,
        uint256 graduationETH
    ) internal pure returns (uint256 tokens) {
        if (ethAmount == 0) return 0;
        uint256 scaled  = (ethAmount * CURVE_SUPPLY) / graduationETH;
        uint256 inner   = currentSold * currentSold + scaled * CURVE_SUPPLY;
        uint256 newSold = sqrt(inner);
        if (newSold > CURVE_SUPPLY) newSold = CURVE_SUPPLY;
        return newSold - currentSold;
    }

    // ============================================================
    //  BONDING CURVE — SELL SIDE
    // ============================================================

    /// @notice Returns gross ETH released when selling a given token amount.
    /// @dev    Fees are applied by the factory after this call, not here.
    ///         Uses the inverse of the buy formula:
    ///         ethOut = (currentSold² - newSold²) × graduationETH / CURVE_SUPPLY²
    /// @param currentSold   Tokens currently sold (wei)
    /// @param tokenAmount   Tokens being sold (wei)
    /// @param graduationETH Target ETH to reach graduation (wei)
    /// @return ethOut       Gross ETH before fees (wei)
    function getETHForTokens(
        uint256 currentSold,
        uint256 tokenAmount,
        uint256 graduationETH
    ) internal pure returns (uint256 ethOut) {
        if (tokenAmount == 0) return 0;
        if (tokenAmount > currentSold) revert NotEnoughSold();
        uint256 newSold = currentSold - tokenAmount;
        uint256 diff    = currentSold * currentSold - newSold * newSold;
        return (diff / CURVE_SUPPLY) * graduationETH / CURVE_SUPPLY;
    }

    // ============================================================
    //  PRICE & MARKET CAP
    // ============================================================

    /// @notice Spot price in ETH per token (18 decimals) at a given supply point.
    /// @dev    price = 2 × graduationETH × currentSold / CURVE_SUPPLY²
    function getCurrentPrice(
        uint256 currentSold,
        uint256 graduationETH
    ) internal pure returns (uint256) {
        if (currentSold == 0) return 0;
        uint256 numerator = (2 * graduationETH * currentSold) / CURVE_SUPPLY;
        return (numerator * 1e18) / CURVE_SUPPLY;
    }

    /// @notice Fully diluted market cap in ETH (18 decimals).
    /// @dev    marketCap = price × TOTAL_SUPPLY
    function getMarketCap(
        uint256 currentSold,
        uint256 graduationETH
    ) internal pure returns (uint256) {
        return (getCurrentPrice(currentSold, graduationETH) * TOTAL_SUPPLY) / 1e18;
    }


    /// @notice Net ETH needed (before adding fees) to buy exactly `tokensWanted`.
    /// @dev    Inverse of getTokensForETH. Rounds UP so buyer always sends enough.
    ///         newSold = currentSold + tokensWanted
    ///         ethNeeded = (newSold² - currentSold²) × graduationETH / CURVE_SUPPLY²
    function getETHForExactTokens(
        uint256 currentSold,
        uint256 tokensWanted,
        uint256 graduationETH
    ) internal pure returns (uint256) {
        if (tokensWanted == 0) return 0;
        uint256 newSold = currentSold + tokensWanted;
        if (newSold > CURVE_SUPPLY) newSold = CURVE_SUPPLY;
        uint256 diff = newSold * newSold - currentSold * currentSold;
        // Round up: mirrors getETHForTokens division order but ceils
        return divCeil(divCeil(diff, CURVE_SUPPLY) * graduationETH, CURVE_SUPPLY);
    }

    /// @notice Tokens to sell to release exactly `ethWanted` gross (before fee deduction).
    /// @dev    Inverse of getETHForTokens. Rounds UP so seller always sends enough tokens.
    ///         newSold² = currentSold² - ethWanted × CURVE_SUPPLY² / graduationETH
    function getTokensForExactETH(
        uint256 currentSold,
        uint256 ethWanted,
        uint256 graduationETH
    ) internal pure returns (uint256) {
        if (ethWanted == 0) return 0;
        uint256 scaled = (ethWanted * CURVE_SUPPLY) / graduationETH;
        uint256 sub = scaled * CURVE_SUPPLY;
        if (sub > currentSold * currentSold) revert InsufficientLiquidity();
        uint256 newSold = sqrt(currentSold * currentSold - sub);
        uint256 tokens = currentSold - newSold;
        // +1 wei safety: integer division in getETHForTokens may round down
        return tokens + 1;
    }

    /// @dev Division rounding up: ceil(a / b)
    function divCeil(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }

    // ============================================================
    //  UTILITIES
    // ============================================================

    /// @dev Integer square root — Babylonian (Newton's) method.
    ///      Returns floor(sqrt(x)).
    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
}
