// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

error ZeroAmount();

interface IUniswapV2Router {
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function factory() external view returns (address);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Pair {
    function skim(address to) external;
}

library GraduationLib {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct GradParams {
        address tokenAddress;
        address weth;
        address quote;         // v3: address(0) = ETH (pair with WETH), else the ERC-20 quote
        address router;
        uint256 ethForDex;     // quote amount for the pool (ETH or ERC-20 units)
        uint256 tokensForDex;
    }


    /// @dev External (v3): deployed once and linked, called by DELEGATECALL, so
    ///      it runs in the factory's context but its code sits outside the
    ///      factory's EIP-170 budget.
    function executeGraduation(GradParams memory p)
        external returns (address pool, uint256 liquidity)
    {
        if (p.ethForDex == 0 || p.tokensForDex == 0) revert ZeroAmount();

        address pairWith = p.quote == address(0) ? p.weth : p.quote;
        address factory = IUniswapV2Router(p.router).factory();
        pool = IUniswapV2Factory(factory).getPair(p.tokenAddress, pairWith);
        if (pool == address(0)) {
            pool = IUniswapV2Factory(factory).createPair(p.tokenAddress, pairWith);
        }

        IUniswapV2Pair(pool).skim(DEAD);

        IERC20(p.tokenAddress).approve(p.router, p.tokensForDex);

        if (p.quote == address(0)) {
            ( , , liquidity) = IUniswapV2Router(p.router).addLiquidityETH{value: p.ethForDex}(
                p.tokenAddress, p.tokensForDex, 0, 0, DEAD, block.timestamp
            );
        } else {
            SafeERC20.forceApprove(IERC20(p.quote), p.router, p.ethForDex);
            ( , , liquidity) = IUniswapV2Router(p.router).addLiquidity(
                p.tokenAddress, p.quote, p.tokensForDex, p.ethForDex, 0, 0, DEAD, block.timestamp
            );
        }
    }
}