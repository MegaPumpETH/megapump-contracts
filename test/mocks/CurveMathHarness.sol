// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "../../src/BondingCurveMath.sol";
/// @dev Test-only: exposes the internal pure functions of BondingCurveMath.
contract CurveMathHarness {
    function tokensForETH(uint256 s, uint256 e, uint256 g) external pure returns (uint256) { return BondingCurveMath.getTokensForETH(s, e, g); }
    function ethForTokens(uint256 s, uint256 t, uint256 g) external pure returns (uint256) { return BondingCurveMath.getETHForTokens(s, t, g); }
    function ethForExactTokens(uint256 s, uint256 t, uint256 g) external pure returns (uint256) { return BondingCurveMath.getETHForExactTokens(s, t, g); }
    function tokensForExactETH(uint256 s, uint256 e, uint256 g) external pure returns (uint256) { return BondingCurveMath.getTokensForExactETH(s, e, g); }
    function price(uint256 s, uint256 g) external pure returns (uint256) { return BondingCurveMath.getCurrentPrice(s, g); }
    function marketCap(uint256 s, uint256 g) external pure returns (uint256) { return BondingCurveMath.getMarketCap(s, g); }
}
