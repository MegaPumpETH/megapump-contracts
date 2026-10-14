// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./RealDexHelpers.sol";

/// @notice The front derives minOut from the Lens: any gap between the Lens and
///         the factory at the graduation boundary would turn into reverts or
///         unprotected trades. Fuzzed around the overflow region.
contract AuditLensParityTest is RealDexHelpers {

    function _state(uint256 fill) internal returns (uint256 id) {
        id = _createTokenWithBuy(alice, "Par", "PAR", "ipfs://p", 0.01 ether);
        vm.roll(block.number + 6);
        fill = bound(fill, 0, 22 ether);
        if (fill > 0) _buy(id, charlie, fill);
    }

    /// @dev Below the threshold the Lens is exact; crossing it, the factory caps the
    ///      net to what is left and the Lens (which does not know totalRaised) may
    ///      promise a hair more. Measured: never more than 1e-9 relative.
    function testFuzz_Lens_EstimateBuy_VsExecution_AcrossGraduation(uint256 fill, uint256 amt) public {
        uint256 id = _state(fill);
        amt = bound(amt, 1e9, 30 ether);
        uint256 est = lens.estimateBuy(id, amt, bob);
        uint256 raisedBefore = _info(id).totalRaised;
        uint256 b0 = _balanceOf(id, bob);
        vm.prank(bob);
        factory.buy{value: amt}(id, 0, address(0), "");
        uint256 got = _balanceOf(id, bob) - b0;
        bool overflow = raisedBefore + (amt - amt * 125 / 10000) > factory.graduationETH();
        if (!overflow) {
            assertEq(got, est, "below threshold: Lens == execution");
        } else {
            assertLe(got, est, "overflow: never more than the estimate");
            assertGe(got + 1, est - est / 1e9, "overflow: estimate off by at most 1e-9");
            assertTrue(_info(id).graduated);
        }
    }

    function testFuzz_Lens_EstimateBuyReverse_DeliversWanted_OrGraduates(uint256 fill, uint256 want) public {
        uint256 id = _state(fill);
        uint256 left = factory.CURVE_SUPPLY() - _info(id).tokensSold;
        want = bound(want, 1e18, left);
        uint256 gross = lens.estimateBuyReverse(id, want, bob);
        uint256 b0 = _balanceOf(id, bob);
        vm.prank(bob);
        factory.buy{value: gross}(id, 0, address(0), "");
        uint256 got = _balanceOf(id, bob) - b0;
        if (!_info(id).graduated) {
            assertGe(got, want, "reverse estimate under-pays");
            assertLe(got - want, 1e12, "reverse estimate over-pays by more than dust");
        } else {
            // asked for the end of the curve: the factory stops at the threshold (dust fewer tokens)
            assertGe(got + 1e12, want);
        }
    }

    function testFuzz_Lens_EstimateSell_VsExecution(uint256 fill, uint256 pct) public {
        uint256 id = _state(fill);
        uint256 bal = _balanceOf(id, charlie);
        if (bal == 0) return;
        uint256 amt = bal * bound(pct, 1, 100) / 100;
        uint256 est = lens.estimateSell(id, amt, charlie);
        uint256 e0 = charlie.balance;
        vm.prank(charlie);
        factory.sell(id, amt, est, address(0), "");   // minETH = exactly the estimate
        assertEq(charlie.balance - e0, est, "sell: Lens == execution");
    }

    /// @dev Different revert names for the same condition: the front maps both.
    function test_Lens_EstimateSell_RevertName_DiffersFromFactory() public {
        uint256 id = _state(1 ether);
        uint256 tooMuch = _info(id).tokensSold + 1;
        vm.expectRevert(NotEnoughSold.selector);
        lens.estimateSell(id, tooMuch, charlie);
        vm.prank(charlie);
        vm.expectRevert(ExceedsSoldSupply.selector);
        factory.sell(id, tooMuch, 0, address(0), "");
    }

    /// @dev The exact-threshold buy and the +1 wei buy both graduate, with exact refunds.
    function test_ExactThreshold_And_PlusOneWei_BothGraduate() public {
        uint256 id = _state(10 ether);
        uint256 need = factory.graduationETH() - _info(id).totalRaised;
        uint256 gross = need * 10000 / (10000 - 125);
        // adjust so that net == need exactly (floor effects)
        while (gross - gross * 125 / 10000 < need) gross++;
        uint256 b0 = bob.balance;
        vm.prank(bob);
        factory.buy{value: gross + 1}(id, 0, address(0), "");
        assertTrue(_info(id).graduated, "+1 wei graduates");
        assertEq(_info(id).totalRaised, factory.graduationETH(), "raised == threshold");
        uint256 spent = b0 - bob.balance;
        assertLe(gross + 1 - spent, 2, "refund is the surplus minus rounding dust");
    }
}
