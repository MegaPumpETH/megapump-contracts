// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./RealDexHelpers.sol";

/// @dev Buyer that refuses ETH: any refund to it must make the buy revert.
contract NoReceiveBuyer {
    MegaPumpFactory immutable f;
    constructor(MegaPumpFactory _f) { f = _f; }
    function buy(uint256 id) external payable {
        f.buy{value: msg.value}(id, 0, address(0), "");
    }
}

/// @dev Buyer that, when refunded (overflow buy = graduation in the same tx),
///      donates its freshly bought tokens to the FUTURE pair address, and
///      also tries to re-enter sell(). Both must be harmless.
contract RefundDonor {
    MegaPumpFactory immutable f;
    address public pair;
    address public token;
    uint256 public id;
    bool public reenterSellFailed;
    constructor(MegaPumpFactory _f) { f = _f; }
    function arm(uint256 _id, address _token, address _pair) external { id = _id; token = _token; pair = _pair; }
    function buy() external payable {
        f.buy{value: msg.value}(id, 0, address(0), "");
    }
    receive() external payable {
        // 1. donate half of the tokens we hold to the predicted pool address
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).transfer(pair, bal / 2);
        // 2. try to sell the rest during the refund callback (re-entrancy)
        try f.sell(id, bal - bal / 2, 0, address(0), "") {
            reenterSellFailed = false;
        } catch {
            reenterSellFailed = true;
        }
    }
}

/// @notice Graduation and pool attacks against the REAL DEX V2 fork.
contract AuditRealDexTest is RealDexHelpers {

    /// @dev held >= owed, and the surplus is rounding dust only (≤ 2 wei per trade path).
    function _assertCovered(uint256 held, uint256 owed, string memory what) internal pure {
        assertGe(held, owed, what);
        assertLe(held - owed, 4, string.concat(what, ": surplus is more than rounding dust"));
    }

    // ─────────────────────────────────────────────────────────
    //  1. Nominal ETH graduation: pool, reserves, LP burned, solvency
    // ─────────────────────────────────────────────────────────
    function test_RealDex_EthGraduation_PoolReservesAndLpBurned() public {
        uint256 id = _createTokenWithBuy(alice, "Grad", "GRD", "ipfs://g", 0.01 ether);
        assertEq(dexFactory.getPair(_tokenAddr(id), address(weth)), address(0), "no pool before graduation");

        uint256 platBefore = factory.platformFeesAccrued();
        uint256 bobBefore = bob.balance;
        _graduateEth(id, bob);

        _checkPool(id);
        _checkFactoryLedger(id, platBefore, bobBefore - bob.balance);
        _checkCurveClosedDexOpen(id);
    }

    function _checkPool(uint256 id) internal {
        address token = _tokenAddr(id);
        MegaPumpLens.TokenInfo memory i = _info(id);
        assertEq(i.dexPool, _predictPair(token, address(weth)), "pool at the CREATE2 address of the hardcoded init code hash");
        assertEq(dexFactory.allPairsLength(), 1);
        (uint256 rTok, uint256 rWeth) = _reserves(i.dexPool, token);
        assertEq(rWeth, i.totalRaised - factory.graduationFee(), "ETH side of the pool = totalRaised - graduation fee");
        assertEq(rTok, factory.TOTAL_SUPPLY() - i.tokensSold, "token side = everything the curve did not sell");
        IRealV2Pair p = IRealV2Pair(i.dexPool);
        assertEq(p.balanceOf(factory.DEAD()), p.totalSupply() - 1000, "LP burned to DEAD (MINIMUM_LIQUIDITY at address(0))");
        assertEq(p.balanceOf(address(factory)), 0, "factory keeps no LP");
        assertEq(i.totalRaised, factory.graduationETH(), "threshold reached exactly (net capped)");
    }

    function _checkFactoryLedger(uint256 id, uint256 platBefore, uint256 spent) internal view {
        MegaPumpLens.TokenInfo memory i = _info(id);
        assertEq(IERC20(_tokenAddr(id)).balanceOf(address(factory)), 0, "leftover tokens burned");
        _assertCovered(address(factory).balance, factory.platformFeesAccrued() + i.creatorFees, "factory ETH = fees owed");
        assertEq(factory.platformFeesAccrued() - platBefore, factory.graduationFee() + spent * 100 / 10000,
            "platform fee = 1% of the gross used + graduation fee");
    }

    function _checkCurveClosedDexOpen(uint256 id) internal {
        address[] memory path = new address[](2);
        path[0] = address(weth); path[1] = _tokenAddr(id);
        vm.prank(charlie);
        uint256[] memory out = realRouter.swapExactETHForTokens{value: 0.1 ether}(0, path, charlie, block.timestamp);
        assertGt(out[1], 0, "swap executed on the DEX");
        vm.prank(charlie);
        vm.expectRevert(AlreadyGraduated.selector);
        factory.buy{value: 1 ether}(id, 0, address(0), "");
    }

    // ─────────────────────────────────────────────────────────
    //  2. Nobody can pre-create or seed the pool before graduation
    // ─────────────────────────────────────────────────────────
    function test_RealDex_PairSquat_ThirdPartyCannotCreatePair() public {
        uint256 id = _createTokenWithBuy(alice, "Squat", "SQT", "ipfs://s", 0.01 ether);
        address token = _tokenAddr(id);

        vm.prank(bob);
        vm.expectRevert(bytes("UniswapV2: FORBIDDEN_CREATE"));
        dexFactory.createPair(token, address(weth));

        // Through the router (addLiquidityETH creates the pair when missing → same revert)
        vm.roll(block.number + 6);
        _buy(id, bob, 1 ether);
        vm.startPrank(bob);
        IERC20(token).approve(address(realRouter), type(uint256).max);
        vm.expectRevert(bytes("UniswapV2: FORBIDDEN_CREATE"));
        realRouter.addLiquidityETH{value: 1 ether}(token, 1e18, 0, 0, bob, block.timestamp);
        vm.stopPrank();
        assertEq(dexFactory.getPair(token, address(weth)), address(0));
    }

    // ─────────────────────────────────────────────────────────
    //  3. Donations to the future pool address go to DEAD, never into the price
    // ─────────────────────────────────────────────────────────
    function test_RealDex_DonationsBeforeGraduation_AreSkimmedToDead() public {
        uint256 id = _createTokenWithBuy(alice, "Don", "DON", "ipfs://d", 0.01 ether);
        address predicted = _predictPair(_tokenAddr(id), address(weth));

        vm.roll(block.number + 6);
        _buy(id, charlie, 1 ether);
        uint256 donated = _donate(id, predicted);
        uint256 deadTok = IERC20(_tokenAddr(id)).balanceOf(factory.DEAD());
        _graduateEth(id, bob);

        assertEq(_info(id).dexPool, predicted);
        _assertReservesClean(id);
        assertEq(weth.balanceOf(factory.DEAD()), 2 ether, "donated WETH burned");
        assertGe(IERC20(_tokenAddr(id)).balanceOf(factory.DEAD()) - deadTok, donated, "donated tokens burned");
    }

    /// @dev charlie sends half his tokens and 2 WETH to the (empty) future pool address.
    function _donate(uint256 id, address predicted) internal returns (uint256 donated) {
        address token = _tokenAddr(id);
        donated = IERC20(token).balanceOf(charlie) / 2;
        vm.startPrank(charlie);
        IERC20(token).transfer(predicted, donated);
        weth.deposit{value: 2 ether}();
        weth.transfer(predicted, 2 ether);
        vm.stopPrank();
        assertEq(IERC20(token).balanceOf(predicted), donated);
        assertEq(weth.balanceOf(predicted), 2 ether);
    }

    /// @dev Reserves == exactly what graduation deposited, and pool balances == reserves.
    function _assertReservesClean(uint256 id) internal view {
        address token = _tokenAddr(id);
        MegaPumpLens.TokenInfo memory i = _info(id);
        (uint256 rTok, uint256 rWeth) = _reserves(i.dexPool, token);
        assertEq(rWeth, i.totalRaised - factory.graduationFee(), "reserves ignore donated WETH");
        assertEq(rTok, factory.TOTAL_SUPPLY() - i.tokensSold, "reserves ignore donated tokens");
        assertEq(IERC20(token).balanceOf(i.dexPool), rTok, "pool token balance == reserve");
        assertEq(weth.balanceOf(i.dexPool), rWeth, "pool WETH balance == reserve");
        _assertCovered(address(factory).balance, factory.platformFeesAccrued() + i.creatorFees, "factory solvent");
    }

    // ─────────────────────────────────────────────────────────
    //  4. Refund callback: donation to the pool + re-entrant sell are harmless
    // ─────────────────────────────────────────────────────────
    function test_RealDex_RefundCallback_DonatesAndReenters_Harmless() public {
        uint256 id = _createTokenWithBuy(alice, "Cb", "CB", "ipfs://cb", 0.01 ether);
        address token = _tokenAddr(id);
        RefundDonor donor = new RefundDonor(factory);
        donor.arm(id, token, _predictPair(token, address(weth)));
        vm.deal(address(donor), 100 ether);
        vm.roll(block.number + 6);

        // Overflow buy → refund → receive() → donate + try sell → then graduation
        donor.buy{value: factory.graduationETH() + 3 ether}();
        assertTrue(donor.reenterSellFailed(), "re-entrant sell reverted (ReentrantCall)");
        assertTrue(_info(id).graduated);
        _assertReservesClean(id);
    }

    // ─────────────────────────────────────────────────────────
    //  5. Buyer that cannot receive ETH: refund fails → whole buy reverts
    // ─────────────────────────────────────────────────────────
    function test_RealDex_NoReceiveBuyer_OverflowBuyReverts_ExactBuyWorks() public {
        uint256 id = _createTokenWithBuy(alice, "NoRx", "NRX", "ipfs://n", 0.01 ether);
        NoReceiveBuyer b = new NoReceiveBuyer(factory);
        vm.deal(address(b), 100 ether);
        vm.roll(block.number + 6);
        uint256 overflowValue = factory.graduationETH() + 1 ether;
        vm.expectRevert(ETHTransferFailed.selector);
        b.buy{value: overflowValue}(id);   // needs a refund → reverts
        b.buy{value: 1 ether}(id);                              // no refund → fine
        assertGt(_balanceOf(id, address(b)), 0);
    }

    // ─────────────────────────────────────────────────────────
    //  6. ERC-20 quote graduation (18 and 6 decimals) on the real DEX
    // ─────────────────────────────────────────────────────────
    function test_RealDex_QuoteGraduation_18dec() public {
        MockQuoteToken usdm = _newQuote("USDm", 18);
        uint256 id = _createQuoteToken(alice, usdm, 10e18);
        vm.roll(block.number + 6);
        vm.prank(bob);
        factory.buyWithQuote(id, 30_000e18, 0, address(0), "");
        _assertQuotePool(id, usdm, 20_000e18 - 50e18);
        // Only the amount needed was pulled from bob: net still needed after alice's first buy
        uint256 aliceNet = 10e18 - 10e18 * 100 / 10000;          // creator pays 1% only
        uint256 gross = (20_000e18 - aliceNet) * 10000 / (10000 - 125);   // same rounding as the contract
        assertEq(usdm.balanceOf(bob), 1_000_000e18 - gross, "bob paid exactly the gross the curve used");
    }

    function _assertQuotePool(uint256 id, MockQuoteToken q, uint256 expectedQuoteSide) internal view {
        address token = _tokenAddr(id);
        MegaPumpLens.TokenInfo memory i = _info(id);
        assertTrue(i.graduated, "graduated");
        assertEq(i.dexPool, _predictPair(token, address(q)), "pool address");
        (uint256 rTok, uint256 rQ) = _reserves(i.dexPool, token);
        assertEq(rQ, expectedQuoteSide, "quote side = threshold - quote graduation fee");
        assertEq(rTok, factory.TOTAL_SUPPLY() - i.tokensSold, "token side");
        _assertCovered(q.balanceOf(address(factory)), factory.quoteFeesAccrued(address(q)) + i.creatorFees, "quote solvent");
        assertEq(IRealV2Pair(i.dexPool).balanceOf(factory.DEAD()), IRealV2Pair(i.dexPool).totalSupply() - 1000, "LP burned");
    }

    function test_RealDex_QuoteGraduation_6dec_PriceEventsStartAtZero() public {
        MockQuoteToken usdc = _newQuote("USDC", 6);
        uint256 id = _createQuoteToken(alice, usdc, 1e6);   // 1 USDC first buy
        // Early on the curve the on-chain spot price rounds to 0 in quote units
        assertEq(_info(id).currentPrice, 0, "6-decimal quote: price rounds to 0 early (display only)");
        assertEq(_info(id).marketCap, 0, "market cap reads 0 too");
        vm.roll(block.number + 6);
        vm.prank(charlie);
        factory.buyWithQuote(id, 9e6, 0, address(0), "");
        // ~10 USDC in: true price ≈ 1.1e-6 USDC/token, on-chain price = 1 unit → MC quantised to 1 000 USDC steps
        assertEq(_info(id).currentPrice, 1, "price = 1 unit (1e-6 USDC)");
        assertEq(_info(id).marketCap, 1_000e6, "market cap quantised to 1 000 USDC");
        vm.roll(block.number + 6);
        vm.prank(bob);
        factory.buyWithQuote(id, 25_000e6, 0, address(0), "");
        _assertQuotePool(id, usdc, 20_000e6 - 50e6);
    }

    // ─────────────────────────────────────────────────────────
    //  7. Two buyers race the last slot in one block: second gets AlreadyGraduated
    // ─────────────────────────────────────────────────────────
    function test_RealDex_SameBlock_BuyAfterGraduation_Reverts_NoFundsLost() public {
        uint256 id = _createTokenWithBuy(alice, "Race", "RCE", "ipfs://r", 0.01 ether);
        vm.roll(block.number + 6);
        uint256 c0 = charlie.balance;
        _graduateEth(id, bob);
        vm.prank(charlie);
        vm.expectRevert(AlreadyGraduated.selector);
        factory.buy{value: 1 ether}(id, 0, address(0), "");
        assertEq(charlie.balance, c0, "revert returns the ETH");
        vm.prank(bob);
        vm.expectRevert(AlreadyGraduated.selector);
        factory.sell(id, 1e18, 0, address(0), "");
    }

    // ─────────────────────────────────────────────────────────
    //  8. Last-buyer arbitrage at graduation (known x2 jump) — measured
    // ─────────────────────────────────────────────────────────
    function test_RealDex_LastBuyerArbitrage_Measured() public {
        uint256 id = _createTokenWithBuy(alice, "Arb", "ARB", "ipfs://a", 0.01 ether);
        address token = _tokenAddr(id);
        vm.roll(block.number + 6);
        // Fill most of the curve first (other buyers), the arbitrageur buys the last part
        _buy(id, charlie, 20 ether);
        uint256 raised = _info(id).totalRaised;
        uint256 need = factory.graduationETH() - raised;      // net still needed
        uint256 gross = need * 10000 / (10000 - 125) + 1;      // + fees
        uint256 b0 = bob.balance;
        vm.prank(bob);
        factory.buy{value: gross}(id, 0, address(0), "");
        assertTrue(_info(id).graduated);
        uint256 spent = b0 - bob.balance;
        // sell everything right away on the DEX
        address[] memory path = new address[](2);
        path[0] = token; path[1] = address(weth);
        vm.startPrank(bob);
        IERC20(token).approve(address(realRouter), type(uint256).max);
        uint256[] memory out = realRouter.swapExactTokensForETH(IERC20(token).balanceOf(bob), 0, path, bob, block.timestamp);
        vm.stopPrank();
        int256 pnl = int256(out[1]) - int256(spent);
        emit log_named_uint("last buyer spent (wei)", spent);
        emit log_named_uint("last buyer got back on DEX (wei)", out[1]);
        emit log_named_int("pnl (wei)", pnl);
        assertGt(out[1], spent, "the last buyer profits from the x2 opening price (accepted design)");
    }

    // ─────────────────────────────────────────────────────────
    //  9. Anti-snipe is per-transaction: N txs in the creation block buy the whole curve
    // ─────────────────────────────────────────────────────────
    function test_AntiSnipe_PerTxCapOnly_WholeCurveInCreationBlock() public {
        uint256 id = _createTokenWithBuy(alice, "Snipe", "SNP", "ipfs://sn", 0.01 ether);
        // same block, no roll: 80M tokens per tx max → 10 txs reach the curve supply / graduation
        uint256 maxTok = factory.ANTI_SNIPE_MAX();
        uint256 buys;
        for (uint256 k = 0; k < 12 && !_info(id).graduated; k++) {
            uint256 sold = _info(id).tokensSold;
            uint256 want = maxTok - 1e15;   // just under the per-tx cap (reverse estimate rounds up)
            if (sold + want > factory.CURVE_SUPPLY()) want = factory.CURVE_SUPPLY() - sold;
            uint256 gross = lens.estimateBuyReverse(id, want, bob);
            vm.prank(bob);
            factory.buy{value: gross}(id, 0, address(0), "");
            buys++;
        }
        assertTrue(_info(id).graduated, "graduated in the creation block by splitting into per-tx buys");
        emit log_named_uint("txs needed in block 0", buys);
        assertLe(buys, 12);
    }

    // ─────────────────────────────────────────────────────────
    //  10. 1 wei deploys someone else's pending token (griefing cost = gas)
    // ─────────────────────────────────────────────────────────
    function test_PendingToken_DeployableWithOneWei() public {
        bytes memory sig = _signCreateFor(alice, "Pend", "PND", "ipfs://p", type(uint256).max, 42);
        vm.prank(bob);
        uint256 id = factory.createAndBuyForCreator{value: 1}(
            alice, "Pend", "PND", "ipfs://p", type(uint256).max, 42, sig, 0, address(0), ""
        );
        assertEq(_info(id).tokensSold, _balanceOf(id, bob));
        assertGt(_balanceOf(id, bob), 0, "1 wei buys a dust amount and deploys the token");
        emit log_named_uint("tokens for 1 wei", _balanceOf(id, bob));
    }

    // ─────────────────────────────────────────────────────────
    //  11. ETH sent straight to the proxy is stuck forever (no withdraw path)
    // ─────────────────────────────────────────────────────────
    function test_EthSentToProxy_IsStuck() public {
        vm.prank(bob);
        (bool ok, ) = address(factory).call{value: 1 ether}("");
        assertTrue(ok, "receive() accepts it");
        vm.expectRevert(NoFees.selector);
        factory.withdrawPlatformFees();       // nothing accrued → cannot recover it
        assertEq(address(factory).balance, 1 ether);
    }

    // ─────────────────────────────────────────────────────────
    //  12. DEX protocol fee switch: feeTo set later only mints LP to feeTo on growth
    // ─────────────────────────────────────────────────────────
    function test_RealDex_FeeToSwitch_MintsProtocolLpOnlyToFeeTo() public {
        uint256 id = _createTokenWithBuy(alice, "Fee", "FEE", "ipfs://f", 0.01 ether);
        address token = _tokenAddr(id);
        _graduateEth(id, bob);
        address pool = _info(id).dexPool;
        vm.prank(feeToSetter);
        dexFactory.setFeeTo(address(0xF33));
        address[] memory path = new address[](2);
        path[0] = address(weth); path[1] = token;
        for (uint256 k = 0; k < 5; k++) {
            vm.prank(charlie);
            realRouter.swapExactETHForTokens{value: 1 ether}(0, path, charlie, block.timestamp);
        }
        // Protocol fee is realised at the next mint/burn once kLast is set: first add sets kLast,
        // swaps grow k, second add mints the fee LP to feeTo (pair exists → router add allowed for anyone).
        vm.startPrank(charlie);
        IERC20(token).approve(address(realRouter), type(uint256).max);
        realRouter.addLiquidityETH{value: 0.01 ether}(token, IERC20(token).balanceOf(charlie) / 2, 0, 0, charlie, block.timestamp);
        for (uint256 k = 0; k < 5; k++) {
            realRouter.swapExactETHForTokens{value: 1 ether}(0, path, charlie, block.timestamp);
        }
        realRouter.addLiquidityETH{value: 0.01 ether}(token, IERC20(token).balanceOf(charlie) / 2, 0, 0, charlie, block.timestamp);
        vm.stopPrank();
        assertGt(IRealV2Pair(pool).balanceOf(address(0xF33)), 0, "protocol fee LP minted to feeTo once enabled");
        assertEq(IRealV2Pair(pool).balanceOf(address(factory)), 0);
    }
}
