// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MegaPumpFactory} from "../src/MegaPumpFactory.sol";
import {MockQuoteToken} from "./mocks/QuoteMocks.sol";

// ──────────────────────────────────────────────────────────────────────────
//  GRADUATION INTEGRATION TEST — MegaETH TESTNET FORK
//
//  Strategy: fork the testnet where the V2 DEX is ALREADY deployed (real
//  Factory/Router/Pair with the CORRECT init code hash). Deploy a fresh
//  MegaPump proxy inside the fork, wire it to the real DEX, reconfigure
//  the pairCreator (via vm.prank on the feeToSetter), then run a full
//  graduation and verify EVERYTHING.
//
//  Run with:
//    forge test --match-contract GraduationForkTest --fork-url megaeth_testnet -vvv
//  (megaeth_testnet is defined in foundry.toml under [rpc_endpoints])
// ──────────────────────────────────────────────────────────────────────────

interface IV2Factory {
    function feeToSetter() external view returns (address);
    function pairCreator() external view returns (address);
    function setPairCreator(address) external;
    function getPair(address, address) external view returns (address);
    function createPair(address, address) external returns (address);
}

interface IV2Pair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

contract GraduationForkTest is Test {
    // ════════════════════════════════════════════════════════════════════
    //  Live DEX addresses (MegaETH testnet — chainId 6343).
    //  These point to our deployed MegaPump DEX instance. To run these fork
    //  tests against your own instance, deploy the factory/router from the
    //  megapump-dex-contracts repo and replace the addresses below.
    // ════════════════════════════════════════════════════════════════════
    address constant DEX_FACTORY = 0xaE2Fb05d477a50d54EC185Fd730971A998f46a51;
    address constant DEX_ROUTER  = 0x5044A9b3dBB09614F98B35Ea610F5a11FB3A473F;
    address constant WETH        = 0x4200000000000000000000000000000000000006;
    // feeToSetter = the deployer EOA (allowed to call setPairCreator)
    address constant FEE_TO_SETTER = 0x5FFC36EdFa367ED5b03585f1Bd4fEa54c7a49F45;

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    MegaPumpFactory factory; // our fresh MegaPump proxy
    IV2Factory dexFactory;

    address creator = makeAddr("creator");
    address buyer   = makeAddr("buyer");
    address attacker = makeAddr("attacker");

    function setUp() public {
        // No fork (plain `forge test`): the live DEX isn't there. Skip these
        // tests instead of failing in setUp; run them with --fork-url.
        if (DEX_FACTORY.code.length == 0) {
            vm.skip(true);
            return;
        }

        // ── 1. Deploy the implementation + MegaPump proxy inside the fork ──
        MegaPumpFactory impl = new MegaPumpFactory();
        bytes memory initData = abi.encodeCall(
            MegaPumpFactory.initialize,
            (DEX_ROUTER, WETH)
        );
        factory = MegaPumpFactory(payable(address(new ERC1967Proxy(address(impl), initData))));

        // ── 2. Wire the DEX to OUR proxy via the feeToSetter ──
        dexFactory = IV2Factory(DEX_FACTORY);
        // Sanity check: the forked DEX's feeToSetter is the one we expect
        assertEq(dexFactory.feeToSetter(), FEE_TO_SETTER, "unexpected testnet feeToSetter");

        vm.prank(FEE_TO_SETTER);
        dexFactory.setPairCreator(address(factory));
        assertEq(dexFactory.pairCreator(), address(factory), "pairCreator != our proxy");

        // ── 3. Fund the actors ──
        vm.deal(creator, 200 ether);
        vm.deal(buyer, 200 ether);
        vm.deal(attacker, 10 ether);
    }

    // ── Read helpers for the TokenData struct (15 fields since v3) ──
    function _tokenAddr(uint256 id) internal view returns (address a) {
        (, , , , , , a, , , , , , , , ) = factory.tokenData(id);
    }
    function _graduated(uint256 id) internal view returns (bool g) {
        (, , , , , , , , , , g, , , , ) = factory.tokenData(id);
    }
    function _dexPool(uint256 id) internal view returns (address p) {
        (, , , , , , , , , , , p, , , ) = factory.tokenData(id);
    }
    function _totalRaised(uint256 id) internal view returns (uint256 r) {
        (, , , , , , , r, , , , , , , ) = factory.tokenData(id);
    }
    function _creatorFees(uint256 id) internal view returns (uint256 f) {
        (, , , , , , , , , f, , , , , ) = factory.tokenData(id);
    }

    function _createToken(uint256 firstBuyEth) internal returns (uint256 id, address tokenAddr) {
        vm.prank(creator);
        id = factory.createAndBuyForCreator{value: firstBuyEth}(
            creator, "TestCoin", "TEST", "ipfs://meta",
            type(uint256).max, 0, "", 0, address(0), ""
        );
        tokenAddr = _tokenAddr(id);
        // Exit the anti-snipe window (5 blocks) to allow large buys.
        vm.roll(block.number + 6);
    }

    // ════════════════════════════════════════════════════════════════════
    //  TEST 1 — A third party can NOT pre-create the pair (FORBIDDEN_CREATE).
    //  This is what makes amountMin=0 safe in GraduationLib.
    // ════════════════════════════════════════════════════════════════════
    function test_AttackerCannotCreatePair() public {
        (, address tokenAddr) = _createToken(0.01 ether);

        vm.prank(attacker);
        vm.expectRevert(bytes("UniswapV2: FORBIDDEN_CREATE"));
        dexFactory.createPair(tokenAddr, WETH);

        assertEq(dexFactory.getPair(tokenAddr, WETH), address(0), "pair should not exist before graduation");
    }

    // ════════════════════════════════════════════════════════════════════
    //  TEST 2 — Full honest graduation, exhaustive checks.
    // ════════════════════════════════════════════════════════════════════
    function test_HonestGraduation() public {
        uint256 gradEth = factory.graduationETH();
        uint256 gradFee = factory.graduationFee();

        // Small first buy (within anti-snipe limits); _createToken exits the window.
        (uint256 id, address tokenAddr) = _createToken(0.01 ether);

        // Now outside the anti-snipe window → large graduation buy allowed.
        uint256 buyerBalBefore = buyer.balance;
        vm.prank(buyer);
        factory.buy{value: gradEth + 10 ether}(id, 0, address(0), "");

        // ── Graduation happened ──
        assertTrue(_graduated(id), "token should have graduated");
        address pool = _dexPool(id);
        assertTrue(pool != address(0), "dexPool not set");
        assertEq(dexFactory.getPair(tokenAddr, WETH), pool, "dexPool != getPair");

        // ── CRITICAL INVARIANT: no ETH "lost". The contract balance breaks
        //   down exactly into: platform fees + unclaimed creator fees +
        //   unclaimed referrer fees. No referrer here.
        uint256 contractEth   = address(factory).balance;
        uint256 feesAccrued   = factory.platformFeesAccrued();
        uint256 creatorFeesId = _creatorFees(id); // creator fees of the graduated token
        // A few wei of tolerance: the integer divisions of the graduationETH
        // cap leave rounding dust (1 wei here) sitting in the contract.
        // Harmless — we're checking for the absence of any significant leak.
        assertApproxEqAbs(
            contractEth,
            feesAccrued + creatorFeesId,
            100, // 100 wei = 1e-16 ETH, generous yet infinitesimal
            "ETH accounting broken: balance != platformFees + creatorFees"
        );

        // ── The graduationFee is properly counted in the fees ──
        assertGe(feesAccrued, gradFee, "graduationFee not counted in platformFeesAccrued");

        // ── The pool holds the right ratio ──
        IV2Pair pair = IV2Pair(pool);
        (uint112 r0, uint112 r1, ) = pair.getReserves();
        (uint256 reserveToken, uint256 reserveWeth) = pair.token0() == tokenAddr
            ? (uint256(r0), uint256(r1))
            : (uint256(r1), uint256(r0));

        // Deposited tokens: ~200M (DEX_SUPPLY). Log the exact value to see
        // the real gap vs 200M (effect of curve rounding).
        emit log_named_uint("reserveToken (tokens in the pool)", reserveToken);
        emit log_named_uint("reserveWeth  (ETH in the pool)", reserveWeth);
        emit log_named_uint("graduationETH", gradEth);
        emit log_named_uint("graduationFee", gradFee);

        // Deposited WETH ≈ gradEth - gradFee (wide tolerance since the exact
        // threshold crossing depends on curve rounding)
        assertApproxEqRel(reserveWeth, gradEth - gradFee, 0.05e18, "WETH reserve != ~ethForDex");
        // tokens ≈ 200M within 1%
        assertApproxEqRel(reserveToken, 200_000_000 ether, 0.01e18, "token reserve != ~200M");

        // ── INVARIANT: no tokens trapped in the contract (remainder burned) ──
        uint256 contractTokenBal = IERC20(tokenAddr).balanceOf(address(factory));
        assertEq(contractTokenBal, 0, "tokens trapped in the contract after graduation");

        // ── The LP is entirely burned to DEAD (minus MINIMUM_LIQUIDITY) ──
        uint256 lpAtDead = pair.balanceOf(DEAD);
        assertGt(lpAtDead, 0, "LP should be at DEAD");
        assertEq(lpAtDead, pair.totalSupply() - 1000, "LP not entirely burned");

        // ── The surplus was properly refunded to the buyer ──
        //   They must not have spent more than ~gradEth (+ gas, ignored here).
        uint256 spent = buyerBalBefore - buyer.balance;
        assertLe(spent, gradEth + 1 ether, "surplus not refunded (spent too much)");

        // ── Trading after graduation is impossible ──
        vm.prank(buyer);
        vm.expectRevert(); // AlreadyGraduated
        factory.buy{value: 1 ether}(id, 0, address(0), "");

        vm.prank(buyer);
        vm.expectRevert(); // AlreadyGraduated (sell)
        factory.sell(id, 1 ether, 0, address(0), "");
    }

    // ════════════════════════════════════════════════════════════════════
    //  TEST 3 — Before graduation, no pair exists (ratio not manipulable).
    // ════════════════════════════════════════════════════════════════════
    function test_NoPairBeforeGraduation() public {
        (, address tokenAddr) = _createToken(0.01 ether);
        assertEq(dexFactory.getPair(tokenAddr, WETH), address(0), "pair exists before graduation");
        assertFalse(_graduated(1), "should not have graduated with a small buy");
    }

    // ════════════════════════════════════════════════════════════════════
    //  TEST 4 — Graduation reached through increments (several small buys),
    //  not one large buy. Verifies the threshold triggers correctly when
    //  accumulating.
    // ════════════════════════════════════════════════════════════════════
    function test_GraduationByIncrements() public {
        uint256 gradEth = factory.graduationETH();
        (uint256 id, ) = _createToken(0.01 ether); // small; _createToken rolls the blocks

        uint256 chunk = gradEth / 4 + 1 ether;
        for (uint256 i = 0; i < 8; i++) {
            if (_graduated(id)) break;
            vm.prank(buyer);
            factory.buy{value: chunk}(id, 0, address(0), "");
        }

        assertTrue(_graduated(id), "should have graduated through increments");
        assertApproxEqAbs(
            address(factory).balance,
            factory.platformFeesAccrued() + _creatorFees(id),
            100,
            "ETH accounting broken after incremental graduation"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    //  TEST 5 — v3: a token quoted in an ERC-20 graduates into a token/quote
    //  pair on the real DEX (addLiquidity), a pair only our proxy can create.
    // ════════════════════════════════════════════════════════════════════
    function test_QuoteGraduation() public {
        MockQuoteToken usd = new MockQuoteToken("USD test", "USDt", 18);
        factory.setQuote(address(usd), true, 1_000 ether, 10 ether);
        usd.mint(creator, 10 ether);
        usd.mint(buyer, 5_000 ether);
        vm.prank(creator);
        usd.approve(address(factory), type(uint256).max);
        vm.prank(buyer);
        usd.approve(address(factory), type(uint256).max);

        vm.prank(creator);
        uint256 id = factory.createAndBuyWithQuote(
            creator, "QuoteCoin", "QTE", "ipfs://q", address(usd),
            type(uint256).max, 0, "", 5 ether, 0, address(0), ""
        );
        address tokenAddr = _tokenAddr(id);
        vm.roll(block.number + 6);

        // Nobody else can open the token/quote pair before graduation
        vm.prank(attacker);
        vm.expectRevert(bytes("UniswapV2: FORBIDDEN_CREATE"));
        dexFactory.createPair(tokenAddr, address(usd));

        uint256 before = usd.balanceOf(buyer);
        vm.prank(buyer);
        factory.buyWithQuote(id, 2_000 ether, 0, address(0), "");

        assertTrue(_graduated(id), "quote token should have graduated");
        address pool = _dexPool(id);
        assertEq(dexFactory.getPair(tokenAddr, address(usd)), pool, "dexPool != getPair(token, quote)");
        assertEq(dexFactory.getPair(tokenAddr, WETH), address(0), "no WETH pair for a quote token");

        IV2Pair pair = IV2Pair(pool);
        (uint112 r0, uint112 r1, ) = pair.getReserves();
        (uint256 reserveToken, uint256 reserveQuote) = pair.token0() == tokenAddr
            ? (uint256(r0), uint256(r1))
            : (uint256(r1), uint256(r0));
        assertEq(reserveQuote, 1_000 ether - 10 ether, "quote reserve != threshold - fee");
        assertApproxEqRel(reserveToken, 200_000_000 ether, 0.01e18, "token reserve != ~200M");
        assertEq(pair.balanceOf(DEAD), pair.totalSupply() - 1000, "LP not entirely burned");
        assertEq(IERC20(tokenAddr).balanceOf(address(factory)), 0, "tokens trapped in the contract");
        assertLt(before - usd.balanceOf(buyer), 2_000 ether, "pulled more than what graduates");

        // What the factory still holds in the quote is exactly what it owes
        assertApproxEqAbs(
            usd.balanceOf(address(factory)),
            factory.quoteFeesAccrued(address(usd)) + _creatorFees(id),
            100,
            "quote accounting broken"
        );
        assertEq(address(factory).balance, 0, "no ETH involved");
    }
}