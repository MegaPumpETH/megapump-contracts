// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
        address router;       
        uint256 ethForDex;
        uint256 tokensForDex;
    }


    function executeGraduation(GradParams memory p)
        internal returns (address pool, uint256 liquidity)
    {
        if (p.ethForDex == 0 || p.tokensForDex == 0) revert ZeroAmount();

        address factory = IUniswapV2Router(p.router).factory();
        pool = IUniswapV2Factory(factory).getPair(p.tokenAddress, p.weth);
        if (pool == address(0)) {
            pool = IUniswapV2Factory(factory).createPair(p.tokenAddress, p.weth);
        }

        IUniswapV2Pair(pool).skim(DEAD);

        IERC20(p.tokenAddress).approve(p.router, p.tokensForDex);

        ( , , liquidity) = IUniswapV2Router(p.router).addLiquidityETH{value: p.ethForDex}(
            p.tokenAddress, p.tokensForDex, 0, 0, DEAD, block.timestamp
        );
    }
}