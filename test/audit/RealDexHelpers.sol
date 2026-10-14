// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../Helpers.sol";
import "../mocks/QuoteMocks.sol";

/// @dev Minimal views of the real Uniswap V2 fork (compiled artifacts in
///      test/fixtures/dex, bit-identical to the public megapump-dex-contracts
///      out/ folder and to a fresh solc 0.5.16 / 0.6.6 build).
interface IRealV2Factory {
    function createPair(address a, address b) external returns (address);
    function getPair(address a, address b) external view returns (address);
    function setPairCreator(address) external;
    function setFeeTo(address) external;
    function setFeeToSetter(address) external;
    function pairCreator() external view returns (address);
    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);
    function allPairsLength() external view returns (uint256);
}

interface IRealV2Router {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    function addLiquidityETH(address token, uint256 amountTokenDesired, uint256 amountTokenMin, uint256 amountETHMin, address to, uint256 deadline)
        external payable returns (uint256, uint256, uint256);
    function addLiquidity(address tokenA, address tokenB, uint256 amountADesired, uint256 amountBDesired, uint256 amountAMin, uint256 amountBMin, address to, uint256 deadline)
        external returns (uint256, uint256, uint256);
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external payable returns (uint256[] memory);
    function swapExactTokensForETH(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external returns (uint256[] memory);
    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external returns (uint256[] memory);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
}

interface IRealV2Pair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function skim(address to) external;
    function sync() external;
    function kLast() external view returns (uint256);
}

/// @notice Same actors and signing helpers as Helpers, but the proxy is wired
///         to the REAL MegaPump DEX V2 fork instead of MockV2Router, exactly
///         like testnet / mainnet (pairCreator = proxy, LP to DEAD).
abstract contract RealDexHelpers is Helpers {
    IRealV2Factory public dexFactory;
    IRealV2Router  public realRouter;
    bytes32        public pairInitCodeHash;
    address        public feeToSetter = address(0xFEE70);

    function _deployRaw(bytes memory code) internal returns (address a) {
        assembly { a := create(0, add(code, 0x20), mload(code)) }
        require(a != address(0), "deploy failed");
    }

    function setUp() public virtual override {
        super.setUp();

        // Real DEX: factory(feeToSetter), router(factory, weth)
        dexFactory = IRealV2Factory(_deployRaw(abi.encodePacked(
            vm.getCode("test/fixtures/dex/MegaPumpV2Factory.json"), abi.encode(feeToSetter)
        )));
        realRouter = IRealV2Router(_deployRaw(abi.encodePacked(
            vm.getCode("test/fixtures/dex/MegaPumpV2Router.json"), abi.encode(address(dexFactory), address(weth))
        )));
        pairInitCodeHash = keccak256(vm.getCode("test/fixtures/dex/UniswapV2Pair.json"));
        vm.label(address(dexFactory), "dexFactory");
        vm.label(address(realRouter), "realRouter");

        vm.prank(feeToSetter);
        dexFactory.setPairCreator(address(factory));
        factory.setRouter(address(realRouter));
    }

    /// @dev CREATE2 address the DEX factory will use for (a, b).
    function _predictPair(address a, address b) internal view returns (address) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return address(uint160(uint256(keccak256(abi.encodePacked(
            hex"ff", address(dexFactory), keccak256(abi.encodePacked(t0, t1)), pairInitCodeHash
        )))));
    }

    function _reserves(address pair, address token) internal view returns (uint256 rToken, uint256 rOther) {
        (uint112 r0, uint112 r1, ) = IRealV2Pair(pair).getReserves();
        if (IRealV2Pair(pair).token0() == token) return (r0, r1);
        return (r1, r0);
    }

    /// @dev Graduates an ETH token in one overflow buy from `buyer`.
    function _graduateEth(uint256 id, address buyer) internal {
        vm.roll(block.number + factory.ANTI_SNIPE_BLOCKS() + 1);
        uint256 value = factory.graduationETH() + 5 ether;   // read BEFORE the prank (a view call would consume it)
        vm.prank(buyer);
        factory.buy{value: value}(id, 0, address(0), "");
        assertTrue(_info(id).graduated, "should have graduated");
    }

    function _newQuote(string memory sym, uint8 dec) internal returns (MockQuoteToken q) {
        q = new MockQuoteToken(sym, sym, dec);
        uint256 unit = 10 ** dec;
        // Threshold in quote units: 20 000 units, fee 50 units (same shape as testnet USDm)
        factory.setQuote(address(q), true, 20_000 * unit, 50 * unit);
        q.mint(alice, 1_000_000 * unit);
        q.mint(bob, 1_000_000 * unit);
        q.mint(charlie, 1_000_000 * unit);
        vm.prank(alice);   q.approve(address(factory), type(uint256).max);
        vm.prank(bob);     q.approve(address(factory), type(uint256).max);
        vm.prank(charlie); q.approve(address(factory), type(uint256).max);
    }

    function _createQuoteToken(address creator, MockQuoteToken q, uint256 firstBuy) internal returns (uint256 id) {
        vm.prank(creator);
        id = factory.createAndBuyWithQuote(
            creator, "QToken", "QT", "ipfs://q", address(q), type(uint256).max, 0, "",
            firstBuy, 0, address(0), ""
        );
    }
}
