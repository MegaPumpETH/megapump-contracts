// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Attacks around graduation, against the REAL MegaPump V2 fork (permissioned
// createPair, skim at graduation). The unit suite covers graduation with a
// mock router only; this one needs a chain where the DEX is deployed:
//
//   forge test --fork-url $TESTNET_RPC_URL --match-path test/GraduationAttacksFork.t.sol -vv
//
// Addresses default to the testnet deployment and can be overridden by env
// (DEX_FACTORY, DEX_ROUTER, WETH_ADDR, FEE_TO_SETTER). Without a fork the
// suite skips itself, so CI stays green.

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/MegaPumpFactory.sol";
import {MockQuoteToken} from "./mocks/QuoteMocks.sol";

interface IWETH9 { function deposit() external payable; function transfer(address, uint256) external returns (bool); }
interface IV2F {
    function createPair(address, address) external returns (address);
    function getPair(address, address) external view returns (address);
    function setPairCreator(address) external;
}
interface IV2P {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}
interface IV2R {
    function swapExactTokensForETH(uint256, uint256, address[] calldata, address, uint256) external returns (uint256[] memory);
}

/// Buyer contract that cannot receive ETH (no receive/fallback).
contract NoReceiveBuyer {
    function buy(MegaPumpFactory f, uint256 id) external payable { f.buy{value: msg.value}(id, 0, address(0), ""); }
}

/// Buyer that re-enters the factory from its refund callback.
contract ReentrantBuyer {
    MegaPumpFactory public f; uint256 public id; bool public reentered; bytes public err;
    function buy(MegaPumpFactory _f, uint256 _id) external payable { f = _f; id = _id; _f.buy{value: msg.value}(_id, 0, address(0), ""); }
    receive() external payable {
        if (!reentered) {
            reentered = true;
            try f.buy{value: 0}(id, 0, address(0), "") { err = "no revert"; } catch (bytes memory e) { err = e; }
        }
    }
}

contract GraduationAttacksForkTest is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address DEXF;
    address ROUTER;
    address WETH;
    address FEE_TO_SETTER;

    MegaPumpFactory f;
    MockQuoteToken usdm;
    address creator  = makeAddr("gaCreator");
    address buyer    = makeAddr("gaBuyer");
    address attacker = makeAddr("gaAttacker");
    uint256 nonce;

    function setUp() public {
        DEXF          = vm.envOr("DEX_FACTORY",   address(0xaE2Fb05d477a50d54EC185Fd730971A998f46a51));
        ROUTER        = vm.envOr("DEX_ROUTER",    address(0x5044A9b3dBB09614F98B35Ea610F5a11FB3A473F));
        WETH          = vm.envOr("WETH_ADDR",     address(0x4200000000000000000000000000000000000006));
        FEE_TO_SETTER = vm.envOr("FEE_TO_SETTER", address(0x5FFC36EdFa367ED5b03585f1Bd4fEa54c7a49F45));
        if (DEXF.code.length == 0) { vm.skip(true); return; }

        MegaPumpFactory impl = new MegaPumpFactory();
        f = MegaPumpFactory(payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(MegaPumpFactory.initialize, (ROUTER, WETH))))));
        f.setGraduationETH(5 ether);
        f.setTokenCreationCooldown(0);
        usdm = new MockQuoteToken("USDm", "USDM", 18);
        f.setQuote(address(usdm), true, 13_400e18, 40e18);
        vm.prank(FEE_TO_SETTER);
        IV2F(DEXF).setPairCreator(address(f));
        vm.deal(creator, 100 ether); vm.deal(buyer, 500 ether); vm.deal(attacker, 500 ether);
    }

    // The test contract owns the fresh proxy: withdrawPlatformFees pays it.
    receive() external payable {}

    // ── helpers ───────────────────────────────────────────────────
    function _td(uint256 id) internal view returns (address tok, uint256 raised, uint256 sold, uint256 cfees, bool grad, address pool, uint256 gradAmt) {
        (, , , , , , tok, raised, sold, cfees, grad, pool, , gradAmt, ) = f.tokenData(id);
    }
    function _createEth(uint256 firstBuy) internal returns (uint256 id, address tok) {
        vm.prank(creator);
        id = f.createAndBuyForCreator{value: firstBuy}(creator, "Grad Attack", "GATK", string.concat("ipfs://ga-", vm.toString(++nonce)), type(uint256).max, nonce, "", 0, address(0), "");
        (tok, , , , , , ) = _td(id);
        vm.roll(block.number + 6); // leave the anti-snipe window
    }
    function _futurePair(address tok, address quote) internal returns (address pair) {
        uint256 snap = vm.snapshotState();
        vm.prank(address(f));
        pair = IV2F(DEXF).createPair(tok, quote);
        vm.revertToState(snap);
        assertEq(pair.code.length, 0, "pair must not exist yet");
    }
    function _reserves(address pair, address tok) internal view returns (uint256 rTok, uint256 rQuote) {
        (uint112 r0, uint112 r1, ) = IV2P(pair).getReserves();
        (rTok, rQuote) = IV2P(pair).token0() == tok ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }
    function _graduatedAmounts() internal returns (uint256 liq, uint256 liqTok) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Graduated(uint256,address,address,uint256,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(f) && logs[i].topics[0] == sig) {
                (, liq, liqTok, ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                return (liq, liqTok);
            }
        }
        revert("no Graduated event");
    }

    // ── 1. Nobody but the launchpad can create the pool ───────────
    function test_AttackerCannotCreatePair() public {
        (, address tok) = _createEth(0.04 ether);
        vm.prank(attacker);
        vm.expectRevert();
        IV2F(DEXF).createPair(tok, WETH);
        assertEq(IV2F(DEXF).getPair(tok, WETH), address(0));
    }

    // ── 2. Donations to the future pool address are skimmed to DEAD ──
    function test_DonationsToFuturePairAreSkimmed_ETH() public {
        (uint256 id, address tok) = _createEth(0.04 ether);
        address pair = _futurePair(tok, WETH);
        vm.prank(attacker); f.buy{value: 0.5 ether}(id, 0, address(0), "");
        uint256 atkTok = IERC20(tok).balanceOf(attacker);
        vm.startPrank(attacker);
        IWETH9(WETH).deposit{value: 3 ether}();
        IERC20(tok).transfer(pair, atkTok / 2);
        IWETH9(WETH).transfer(pair, 3 ether);
        vm.stopPrank();
        uint256 deadTok = IERC20(tok).balanceOf(DEAD);
        uint256 deadWeth = IERC20(WETH).balanceOf(DEAD);

        vm.recordLogs();
        vm.prank(buyer); f.buy{value: 10 ether}(id, 0, address(0), "");
        (, , , , bool grad, address pool, uint256 gradAmt) = _td(id);
        assertTrue(grad, "graduated");
        assertEq(pool, pair, "pool at the predicted address");
        (uint256 liq, uint256 liqTok) = _graduatedAmounts();
        (uint256 rTok, uint256 rQuote) = _reserves(pair, tok);
        assertEq(rQuote, liq, "WETH reserve == graduation liquidity only");
        assertEq(rTok, liqTok, "token reserve == graduation liquidity only");
        assertEq(liq, gradAmt - f.graduationFee(), "liquidity = threshold - fee");
        assertEq(IERC20(WETH).balanceOf(DEAD) - deadWeth, 3 ether, "donated WETH skimmed to DEAD");
        assertGe(IERC20(tok).balanceOf(DEAD) - deadTok, atkTok / 2, "donated tokens skimmed to DEAD");
        assertEq(IV2P(pair).balanceOf(DEAD) + 1000, IV2P(pair).totalSupply(), "all LP burned to DEAD (except MINIMUM_LIQUIDITY)");
    }

    // ── 3. Same with an ERC-20 quote ──────────────────────────────
    function test_DonationsToFuturePairAreSkimmed_Quote() public {
        usdm.mint(creator, 1_000e18); usdm.mint(attacker, 10_000e18); usdm.mint(buyer, 40_000e18);
        vm.startPrank(creator);
        usdm.approve(address(f), type(uint256).max);
        uint256 id = f.createAndBuyWithQuote(creator, "Grad Attack Q", "GATQ", "ipfs://ga-q", address(usdm), type(uint256).max, 999, "", 100e18, 0, address(0), "");
        vm.stopPrank();
        (address tok, , , , , , ) = _td(id);
        vm.roll(block.number + 6);
        address pair = _futurePair(tok, address(usdm));
        vm.startPrank(attacker);
        usdm.approve(address(f), type(uint256).max);
        f.buyWithQuote(id, 1_000e18, 0, address(0), "");
        IERC20(tok).transfer(pair, IERC20(tok).balanceOf(attacker));
        IERC20(address(usdm)).transfer(pair, 5_000e18);
        vm.stopPrank();

        vm.recordLogs();
        vm.startPrank(buyer);
        usdm.approve(address(f), type(uint256).max);
        uint256 before = usdm.balanceOf(buyer);
        f.buyWithQuote(id, 30_000e18, 0, address(0), "");
        vm.stopPrank();
        (, , , , bool grad, address pool, ) = _td(id);
        assertTrue(grad);
        assertEq(pool, pair);
        (uint256 liq, uint256 liqTok) = _graduatedAmounts();
        (uint256 rTok, uint256 rQuote) = _reserves(pair, tok);
        assertEq(rQuote, liq); assertEq(rTok, liqTok);
        assertLt(before - usdm.balanceOf(buyer), 30_000e18, "only the used part is pulled");
    }

    // ── 4. Arbitrage right at graduation (measured, not asserted) ─
    function test_GraduationArbitrageMeasured() public {
        (uint256 id, address tok) = _createEth(0.04 ether);
        vm.prank(buyer); f.buy{value: 4 ether}(id, 0, address(0), "");
        uint256 ethBefore = attacker.balance;
        vm.prank(attacker); f.buy{value: 5 ether}(id, 0, address(0), ""); // takes the end of the curve and graduates
        (, , , , bool grad, , ) = _td(id);
        assertTrue(grad);
        uint256 spent = ethBefore - attacker.balance;
        uint256 got = IERC20(tok).balanceOf(attacker);
        vm.startPrank(attacker);
        IERC20(tok).approve(ROUTER, got);
        address[] memory path = new address[](2); path[0] = tok; path[1] = WETH;
        IV2R(ROUTER).swapExactTokensForETH(got, 0, path, attacker, block.timestamp);
        vm.stopPrank();
        uint256 back = attacker.balance - (ethBefore - spent);
        emit log_named_decimal_uint("last buyer spent (ETH)", spent, 18);
        emit log_named_decimal_uint("sold on the pool right after (ETH)", back, 18);
        if (back > spent) emit log_named_decimal_uint("ARBITRAGE PROFIT (ETH)", back - spent, 18);
        else emit log_named_decimal_uint("round-trip loss (ETH)", spent - back, 18);
    }

    // ── 5. After graduation the curve is closed for everyone ──────
    function test_CurveClosedAfterGraduation() public {
        (uint256 id, address tok) = _createEth(0.04 ether);
        vm.prank(buyer); f.buy{value: 10 ether}(id, 0, address(0), "");
        vm.prank(attacker); vm.expectRevert(AlreadyGraduated.selector); f.buy{value: 0.1 ether}(id, 0, address(0), "");
        uint256 bal = IERC20(tok).balanceOf(buyer);
        vm.prank(buyer); vm.expectRevert(AlreadyGraduated.selector); f.sell(id, bal / 2, 0, address(0), "");
    }

    // ── 6. Overshoot refund: the buyer pays exactly what the curve used ─
    function test_OvershootRefundExact() public {
        (uint256 id, ) = _createEth(0.04 ether);
        (, uint256 raised, , , , , uint256 gradAmt) = _td(id);
        uint256 before = buyer.balance;
        vm.prank(buyer); f.buy{value: 50 ether}(id, 0, address(0), "");
        uint256 paid = before - buyer.balance;
        uint256 expected = ((gradAmt - raised) * 10000) / (10000 - f.platformFeeBps() - f.creatorFeeBps());
        assertApproxEqAbs(paid, expected, 1, "paid == gross needed to reach the threshold");
    }

    // ── 7. A buyer that cannot receive its refund only hurts itself ─
    function test_NoReceiveBuyerCannotBlockGraduation() public {
        (uint256 id, ) = _createEth(0.04 ether);
        NoReceiveBuyer nb = new NoReceiveBuyer();
        vm.prank(attacker);
        vm.expectRevert(ETHTransferFailed.selector);
        nb.buy{value: 20 ether}(f, id);
        vm.prank(buyer); f.buy{value: 20 ether}(id, 0, address(0), "");
        (, , , , bool grad, , ) = _td(id);
        assertTrue(grad, "someone else graduates normally");
    }

    // ── 8. Re-entering from the refund callback is blocked ─────────
    function test_ReentrancyFromRefundBlocked() public {
        (uint256 id, ) = _createEth(0.04 ether);
        ReentrantBuyer rb = new ReentrantBuyer();
        vm.prank(attacker); rb.buy{value: 20 ether}(f, id);
        assertTrue(rb.reentered());
        assertEq(bytes4(rb.err()), ReentrantCall.selector, "inner buy reverted with ReentrantCall");
        (, , , , bool grad, , ) = _td(id);
        assertTrue(grad);
    }

    // ── 9. Withdrawing platform fees never touches curve funds ────
    function test_WithdrawFeesThenEveryoneSellsBack() public {
        (uint256 id, address tok) = _createEth(0.04 ether);
        address[3] memory users = [makeAddr("gaU1"), makeAddr("gaU2"), makeAddr("gaU3")];
        for (uint256 i; i < 3; i++) { vm.deal(users[i], 5 ether); vm.prank(users[i]); f.buy{value: 1 ether}(id, 0, address(0), ""); }
        f.withdrawPlatformFees();
        for (uint256 i; i < 3; i++) {
            uint256 bal = IERC20(tok).balanceOf(users[i]);
            vm.prank(users[i]); f.sell(id, bal, 0, address(0), "");
            assertEq(IERC20(tok).balanceOf(users[i]), 0);
        }
        uint256 cb = IERC20(tok).balanceOf(creator);
        vm.prank(creator); f.sell(id, cb, 0, address(0), "");
        (, , uint256 sold, , , , ) = _td(id);
        assertEq(sold, 0, "everything sold back");
    }

    // ── 10. Solvency fuzz on one token (random buys/sells) ─────────
    function testFuzz_SolvencyAfterRandomTrades(uint256 seed) public {
        (uint256 id, address tok) = _createEth(0.04 ether);
        address[3] memory users = [makeAddr("gaF1"), makeAddr("gaF2"), makeAddr("gaF3")];
        for (uint256 i; i < 3; i++) vm.deal(users[i], 10 ether);
        for (uint256 k; k < 12; k++) {
            seed = uint256(keccak256(abi.encode(seed, k)));
            address u = users[seed % 3];
            (, , , , bool grad, , ) = _td(id);
            if (grad) break;
            if ((seed >> 8) % 3 != 0) {
                vm.prank(u); try f.buy{value: 1 + ((seed >> 16) % 1.2 ether)}(id, 0, address(0), "") {} catch {}
            } else {
                uint256 bal = IERC20(tok).balanceOf(u);
                if (bal == 0) continue;
                vm.prank(u); try f.sell(id, 1 + ((seed >> 16) % bal), 0, address(0), "") {} catch {}
            }
        }
        (, uint256 raised, uint256 sold, uint256 cfees, bool g, , ) = _td(id);
        // A fresh factory: every wei it holds belongs to this token's curve,
        // its creator or the platform.
        assertGe(address(f).balance, (g ? 0 : raised) + cfees + f.platformFeesAccrued(), "solvency");
        if (g) assertEq(IERC20(tok).balanceOf(address(f)), 0, "nothing left after graduation");
        else assertEq(IERC20(tok).balanceOf(address(f)) + sold, 1_000_000_000e18, "supply accounting");
    }
}
