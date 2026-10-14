// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Helpers.sol";

/// @notice Parity between MegaPumpLens estimates and what the factory really
///         executes. The frontend derives minTokensOut / minETH from these
///         estimates, so any drift would either revert trades or weaken the
///         slippage protection. Fuzzed over amounts, creator vs third party.
contract LensParityTest is Helpers {

    uint256 constant BPS = 10000;

    // ════════════════════════════════════════════════════════════
    //  Helpers
    // ════════════════════════════════════════════════════════════

    function _feeBps(bool isCreator) internal view returns (uint256) {
        return factory.platformFeeBps() + (isCreator ? 0 : factory.creatorFeeBps());
    }

    /// @dev Largest gross ETH that cannot hit the graduation overflow path,
    ///      so the buy consumes exactly msg.value and the estimate applies.
    function _maxNoOverflow(uint256 id, bool isCreator) internal view returns (uint256) {
        MegaPumpLens.TokenInfo memory info = _info(id);
        uint256 remaining = info.graduationETH - info.totalRaised;
        return ((remaining - 1) * BPS) / (BPS - _feeBps(isCreator));
    }

    // ════════════════════════════════════════════════════════════
    //  Buy — estimateBuy == tokens actually received
    // ════════════════════════════════════════════════════════════

    function testFuzz_EstimateBuy_MatchesExecution(uint256 ethIn, bool asCreator) public {
        uint256 id = _createAndDeploy(alice, 0.01 ether); // anti-snipe window skipped
        address buyer = asCreator ? alice : bob;

        ethIn = bound(ethIn, 1e12, _maxNoOverflow(id, asCreator));
        uint256 estimated = lens.estimateBuy(id, ethIn, buyer);
        vm.assume(estimated > 0);

        uint256 before = _balanceOf(id, buyer);
        _buy(id, buyer, ethIn);

        assertEq(_balanceOf(id, buyer) - before, estimated, "lens estimate != tokens received");
    }

    // ════════════════════════════════════════════════════════════
    //  Sell — estimateSell == ETH actually received
    // ════════════════════════════════════════════════════════════

    function testFuzz_EstimateSell_MatchesExecution(
        uint256 buyEth,
        uint256 sellBps,
        bool asCreator
    ) public {
        uint256 id = _createAndDeploy(alice, 0.01 ether);
        address seller = asCreator ? alice : bob;

        buyEth = bound(buyEth, 0.001 ether, _maxNoOverflow(id, asCreator));
        _buy(id, seller, buyEth);

        uint256 held = _balanceOf(id, seller);
        sellBps = bound(sellBps, 1, BPS);
        uint256 amount = (held * sellBps) / BPS;
        vm.assume(amount > 0);

        uint256 estimated = lens.estimateSell(id, amount, seller);

        uint256 before = seller.balance;
        _sell(id, seller, amount);

        assertEq(seller.balance - before, estimated, "lens estimate != ETH received");
    }

    // ════════════════════════════════════════════════════════════
    //  First buy — estimateFirstBuy == tokens received at creation
    // ════════════════════════════════════════════════════════════

    function testFuzz_EstimateFirstBuy_MatchesCreatorSelfBuy(uint256 ethIn) public {
        ethIn = bound(ethIn, 1e12, lens.estimateFirstBuyReverse(factory.ANTI_SNIPE_MAX(), true));
        uint256 estimated = lens.estimateFirstBuy(ethIn, true);
        vm.assume(estimated > 0 && estimated <= factory.ANTI_SNIPE_MAX());

        uint256 id = _createTokenCustomNoSkip(alice, "Parity", "PAR", "ipfs://p", ethIn);

        assertEq(_balanceOf(id, alice), estimated, "creator first buy != estimate");
    }

    function testFuzz_EstimateFirstBuy_MatchesThirdPartyBuy(uint256 ethIn) public {
        ethIn = bound(ethIn, 1e12, lens.estimateFirstBuyReverse(factory.ANTI_SNIPE_MAX(), false));
        uint256 estimated = lens.estimateFirstBuy(ethIn, false);
        vm.assume(estimated > 0 && estimated <= factory.ANTI_SNIPE_MAX());

        uint256 id = _createAndBuyByThirdParty(
            alice, bob, "Parity", "PAR", "ipfs://p", ethIn, type(uint256).max
        );

        assertEq(_balanceOf(id, bob), estimated, "third-party first buy != estimate");
    }

    // ════════════════════════════════════════════════════════════
    //  Reverse estimates — paying the quote gets at least what was asked
    // ════════════════════════════════════════════════════════════

    function testFuzz_EstimateBuyReverse_DeliversAtLeastWanted(uint256 wanted, bool asCreator) public {
        uint256 id = _createAndDeploy(alice, 0.01 ether);
        address buyer = asCreator ? alice : bob;

        MegaPumpLens.TokenInfo memory info = _info(id);
        wanted = bound(wanted, 1 ether, (factory.CURVE_SUPPLY() - info.tokensSold) / 2);

        uint256 ethToSend = lens.estimateBuyReverse(id, wanted, buyer);
        vm.assume(ethToSend <= _maxNoOverflow(id, asCreator));

        uint256 before = _balanceOf(id, buyer);
        _buy(id, buyer, ethToSend);

        assertGe(_balanceOf(id, buyer) - before, wanted, "reverse quote under-delivers");
    }

    // ════════════════════════════════════════════════════════════
    //  Anti-snipe "Max" button.
    //
    //  The raw quote estimateFirstBuyReverse(ANTI_SNIPE_MAX) rounds UP,
    //  so paying it exactly lands a few hundred million token-wei above
    //  the cap and reverts AntiSnipe (known, see the frontend comment in
    //  app/create/page.tsx). The frontend therefore truncates the max DOWN
    //  to 4 decimals before offering it. These tests pin both facts, so a
    //  change in rounding on either side cannot silently break "Max".
    // ════════════════════════════════════════════════════════════

    /// @dev Mirrors Math.floor(Number(formatEther(maxWei)) * 10000) / 10000.
    function _frontendMax(bool isCreator) internal view returns (uint256) {
        uint256 maxWei = lens.estimateFirstBuyReverse(factory.ANTI_SNIPE_MAX(), isCreator);
        return (maxWei / 1e14) * 1e14;
    }

    function test_MaxFirstBuy_AsOffered_Creator_PassesAntiSnipe() public {
        uint256 offered = _frontendMax(true);
        uint256 id = _createTokenCustomNoSkip(alice, "Max", "MAX", "ipfs://m", offered);
        assertLe(_balanceOf(id, alice), factory.ANTI_SNIPE_MAX(), "offered max above cap");
    }

    function test_MaxFirstBuy_AsOffered_ThirdParty_PassesAntiSnipe() public {
        uint256 offered = _frontendMax(false);
        uint256 id = _createAndBuyByThirdParty(
            alice, bob, "Max", "MAX", "ipfs://m", offered, type(uint256).max
        );
        assertLe(_balanceOf(id, bob), factory.ANTI_SNIPE_MAX(), "offered max above cap");
    }

    function test_MaxFirstBuy_RawQuote_OvershootsCap() public view {
        uint256 maxWei = lens.estimateFirstBuyReverse(factory.ANTI_SNIPE_MAX(), true);
        assertGt(lens.estimateFirstBuy(maxWei, true), factory.ANTI_SNIPE_MAX(),
            "raw quote now stays under the cap: the frontend truncation can be revisited");
    }

    // ════════════════════════════════════════════════════════════
    //  Lens wiring
    // ════════════════════════════════════════════════════════════

    function test_Lens_PointsAtProxy() public view {
        assertEq(address(lens.factory()), address(factory), "lens must read the proxy");
    }

    function test_Lens_Constructor_RejectsZeroFactory() public {
        vm.expectRevert(InvalidAddress.selector);
        new MegaPumpLens(address(0));
    }

    function test_Lens_UnknownToken_Reverts() public {
        vm.expectRevert(TokenNotFound.selector);
        lens.getTokenInfo(0);

        vm.expectRevert(TokenNotFound.selector);
        lens.estimateBuy(1, 1 ether, bob);

        uint256 id = _createAndDeploy(alice, 0.01 ether);

        vm.expectRevert(TokenNotFound.selector);
        lens.estimateSell(id + 1, 1 ether, bob);
    }

    function test_Lens_FirstBuyFollowsGlobalGraduationETH() public {
        uint256 before = lens.estimateFirstBuy(1 ether, false);
        factory.setGraduationETH(50 ether);
        uint256 afterChange = lens.estimateFirstBuy(1 ether, false);
        assertLt(afterChange, before, "higher threshold -> fewer tokens for the same ETH");
    }
}
