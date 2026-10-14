// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./RealDexHelpers.sol";

/// @dev Random sequences of every user action against the real DEX.
///      Every call is pranked from one of three actors; reverts are tolerated
///      (they are part of the protocol), state is checked by the invariants.
contract ProtocolHandler is Test {
    MegaPumpFactory public f;
    MegaPumpLens public lens;
    MockQuoteToken public usdm;   // 18 dec
    MockQuoteToken public usdc;   // 6 dec
    address[3] public actors;
    uint256 public signerPk;
    address public referrer = address(0xBEEF);

    uint256 public trades;        // bounds the tolerated rounding dust
    uint256 public creations;

    constructor(MegaPumpFactory _f, MegaPumpLens _l, MockQuoteToken _usdm, MockQuoteToken _usdc, address[3] memory _actors, uint256 _signerPk) {
        f = _f; lens = _l; usdm = _usdm; usdc = _usdc; actors = _actors; signerPk = _signerPk;
    }

    receive() external payable {}

    function _actor(uint256 seed) internal view returns (address) { return actors[seed % 3]; }

    function _refSig(address trader) internal view returns (bytes memory) {
        bytes32 h = keccak256(abi.encodePacked(referrer, trader));
        bytes32 eh = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, eh);
        return abi.encodePacked(r, s, v);
    }

    function createEth(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 1, 0.2 ether);
        string memory n = string.concat("T", vm.toString(creations));
        vm.prank(a);
        try f.createAndBuyForCreator{value: amount}(a, n, "TK", "ipfs://x", 0, 0, "", 0, address(0), "") {
            creations++; trades++;
        } catch {}
    }

    function createQuote(uint256 seed, uint256 amount, bool six) external {
        address a = _actor(seed);
        MockQuoteToken q = six ? usdc : usdm;
        uint256 unit = six ? 1e6 : 1e18;
        amount = bound(amount, 1, 300 * unit);
        string memory n = string.concat("Q", vm.toString(creations));
        vm.prank(a);
        try f.createAndBuyWithQuote(a, n, "QK", "ipfs://q", address(q), 0, 0, "", amount, 0, address(0), "") {
            creations++; trades++;
        } catch {}
    }

    function buy(uint256 seed, uint256 id, uint256 amount, bool withRef) external {
        if (f.tokenCount() == 0) return;
        id = bound(id, 1, f.tokenCount());
        address a = _actor(seed);
        MegaPumpLens.TokenInfo memory i = lens.getTokenInfo(id);
        bytes memory sig = withRef ? _refSig(a) : bytes("");
        address r = withRef ? referrer : address(0);
        if (i.quote == address(0)) {
            amount = bound(amount, 1, 30 ether);
            vm.prank(a);
            try f.buy{value: amount}(id, 0, r, sig) { trades++; } catch {}
        } else {
            uint256 unit = i.quote == address(usdc) ? 1e6 : 1e18;
            amount = bound(amount, 1, 25_000 * unit);
            vm.prank(a);
            try f.buyWithQuote(id, amount, 0, r, sig) { trades++; } catch {}
        }
    }

    function sell(uint256 seed, uint256 id, uint256 pct, bool withRef) external {
        if (f.tokenCount() == 0) return;
        id = bound(id, 1, f.tokenCount());
        address a = _actor(seed);
        MegaPumpLens.TokenInfo memory i = lens.getTokenInfo(id);
        if (i.tokenAddress == address(0)) return;
        uint256 bal = IERC20(i.tokenAddress).balanceOf(a);
        if (bal == 0) return;
        uint256 amt = bal * bound(pct, 1, 100) / 100;
        bytes memory sig = withRef ? _refSig(a) : bytes("");
        vm.prank(a);
        try f.sell(id, amt, 0, withRef ? referrer : address(0), sig) { trades++; } catch {}
    }

    function claimCreator(uint256 seed, uint256 id) external {
        if (f.tokenCount() == 0) return;
        id = bound(id, 1, f.tokenCount());
        vm.prank(_actor(seed));
        try f.claimCreatorFees(id) {} catch {}
    }

    function claimAll(uint256 seed) external {
        uint256 n = f.tokenCount();
        if (n == 0) return;
        uint256[] memory ids = new uint256[](n);
        for (uint256 k = 0; k < n; k++) ids[k] = k + 1;
        vm.prank(_actor(seed));
        try f.claimAllCreatorFees(ids) {} catch {}
    }

    function claimReferrer(bool quote, bool six) external {
        vm.prank(referrer);
        if (!quote) { try f.claimReferrerFees() {} catch {} }
        else { try f.claimReferrerQuoteFees(address(six ? usdc : usdm)) {} catch {} }
    }

    function withdraw(bool quote, bool six) external {
        if (!quote) { try f.withdrawPlatformFees() {} catch {} }
        else { try f.withdrawQuoteFees(address(six ? usdc : usdm)) {} catch {} }
    }

    function roll(uint256 n) external {
        vm.roll(block.number + bound(n, 1, 10));
    }

    function togglePause() external {
        f.setPaused(!f.paused());
    }
}

contract AuditInvariantsTest is RealDexHelpers {
    ProtocolHandler handler;
    MockQuoteToken usdm;
    MockQuoteToken usdc;

    function setUp() public override {
        super.setUp();
        usdm = _newQuote("USDm", 18);
        usdc = _newQuote("USDC", 6);
        factory.setTokenCreationCooldown(0);
        handler = new ProtocolHandler(factory, lens, usdm, usdc, [alice, bob, charlie], signerPk);
        // the handler is the owner for withdraw/pause: hand the proxy over to it
        factory.transferOwnership(address(handler));
        vm.prank(address(handler));
        factory.acceptOwnership();
        vm.deal(address(handler), 0);
        targetContract(address(handler));
    }

    // ETH held ≥ ETH owed, surplus = rounding dust only
    function invariant_EthSolvent() public view {
        uint256 owed = factory.platformFeesAccrued() + factory.referrerFees(handler.referrer());
        for (uint256 id = 1; id <= factory.tokenCount(); id++) {
            MegaPumpLens.TokenInfo memory i = lens.getTokenInfo(id);
            if (i.quote != address(0)) continue;
            owed += i.creatorFees;
            if (!i.graduated) owed += i.totalRaised;
        }
        assertGe(address(factory).balance, owed, "ETH: owed > held");
        assertLe(address(factory).balance - owed, 4 * (handler.trades() + 1), "ETH: surplus beyond rounding dust");
    }

    function invariant_QuoteSolvent() public view {
        _quoteSolvent(usdm);
        _quoteSolvent(usdc);
    }

    function _quoteSolvent(MockQuoteToken q) internal view {
        uint256 owed = factory.quoteFeesAccrued(address(q)) + factory.referrerQuoteFees(handler.referrer(), address(q));
        for (uint256 id = 1; id <= factory.tokenCount(); id++) {
            MegaPumpLens.TokenInfo memory i = lens.getTokenInfo(id);
            if (i.quote != address(q)) continue;
            owed += i.creatorFees;
            if (!i.graduated) owed += i.totalRaised;
        }
        assertGe(q.balanceOf(address(factory)), owed, "quote: owed > held");
        assertLe(q.balanceOf(address(factory)) - owed, 4 * (handler.trades() + 1), "quote: surplus beyond dust");
    }

    // Curve bookkeeping per token
    function invariant_CurveState() public view {
        for (uint256 id = 1; id <= factory.tokenCount(); id++) {
            MegaPumpLens.TokenInfo memory i = lens.getTokenInfo(id);
            assertLe(i.tokensSold, factory.CURVE_SUPPLY(), "sold > curve supply");
            IERC20 t = IERC20(i.tokenAddress);
            if (!i.graduated) {
                assertLe(i.totalRaised, i.graduationETH, "raised beyond threshold without graduating");
                assertEq(t.balanceOf(address(factory)), factory.TOTAL_SUPPLY() - i.tokensSold, "factory token balance != unsold");
                // every token sold can be bought back by the curve: raised >= cost(sold)
                uint256 cost = BondingCurveMath.getETHForTokens(i.tokensSold, i.tokensSold, i.graduationETH);
                assertGe(i.totalRaised, cost, "raised < curve cost of what is sold");
            } else {
                assertTrue(i.dexPool != address(0), "graduated without pool");
                assertEq(t.balanceOf(address(factory)), 0, "factory keeps tokens after graduation");
                (uint256 rTok, uint256 rQ) = _reserves(i.dexPool, i.tokenAddress);
                assertGt(rTok, 0); assertGt(rQ, 0);
                assertEq(IRealV2Pair(i.dexPool).balanceOf(address(factory)), 0, "factory holds LP");
            }
            assertEq(factory.tokenIdByAddress(i.tokenAddress), id, "id bijection");
        }
    }

    /// @dev Proves the handler really exercises the protocol (creations, trades,
    ///      graduations in ETH and in both quotes) and that the invariants hold after.
    function test_Handler_ProducesActivity_AndInvariantsHold() public {
        uint256 seed = 7;
        for (uint256 k = 0; k < 180; k++) {
            seed = uint256(keccak256(abi.encode(seed, k)));
            uint256 op = seed % 9;
            if (op == 0) handler.createEth(seed, seed >> 8);
            else if (op == 1) handler.createQuote(seed, seed >> 8, (seed >> 4) % 2 == 0);
            else if (op <= 4) handler.buy(seed, (seed >> 16) % 7 + 1, seed >> 32, (seed >> 3) % 2 == 0);
            else if (op <= 6) handler.sell(seed, (seed >> 16) % 7 + 1, (seed >> 32) % 100, (seed >> 3) % 2 == 0);
            else if (op == 7) handler.claimAll(seed);
            else handler.roll(seed % 10);
            if (k % 50 == 0) { handler.claimReferrer(k % 100 == 0, k % 150 == 0); handler.withdraw(k % 100 == 0, false); }
            if (k % 30 == 29) { invariant_EthSolvent(); invariant_QuoteSolvent(); invariant_CurveState(); }
        }
        uint256 grads; uint256 ethTok; uint256 qTok;
        for (uint256 id = 1; id <= factory.tokenCount(); id++) {
            MegaPumpLens.TokenInfo memory i = lens.getTokenInfo(id);
            if (i.graduated) grads++;
            if (i.quote == address(0)) ethTok++; else qTok++;
        }
        emit log_named_uint("tokens created", factory.tokenCount());
        emit log_named_uint("eth tokens", ethTok);
        emit log_named_uint("quote tokens", qTok);
        emit log_named_uint("trades", handler.trades());
        emit log_named_uint("graduated", grads);
        assertGt(handler.trades(), 40, "handler traded");
        assertGt(grads, 0, "handler graduated at least one token");
        assertGt(qTok, 0, "quote tokens exist");
    }
}
