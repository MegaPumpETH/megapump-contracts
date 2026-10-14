// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Helpers.sol";

/// @notice Validation and edge case tests.
contract ValidationAndEdgeTest is Helpers {

    // ════════════════════════════════════════════════════════════
    //  Internal helper: build creation params + try via createAndBuyForCreator
    //  Returns true if the call succeeded.
    //  Uses 0.01 ether buy by default.
    // ════════════════════════════════════════════════════════════

    function _tryCreate(
        address creator,
        string memory name,
        string memory ticker
    ) internal returns (bool ok, uint256 id) {
        bytes memory sig = _signCreateFor(creator, name, ticker, "", type(uint256).max);
        vm.prank(creator);
        try factory.createAndBuyForCreator{value: 0.01 ether}(
            creator, name, ticker, "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        ) returns (uint256 _id) {
            ok = true;
            id = _id;
        } catch {
            ok = false;
        }
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 1 — createAndBuyForCreator cooldown (per-creator, default 60s)
    // ════════════════════════════════════════════════════════════

    function test_CreateTokenCooldown_BlocksRapidCreation() public {
        factory.setTokenCreationCooldown(60);

        bytes memory sigA = _signCreateFor(alice, "First", "FST", "", type(uint256).max);
        vm.prank(alice);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "First", "FST", "",
            type(uint256).max,
            0, sigA,
            0, address(0), ""
        );

        bytes memory sigB = _signCreateFor(alice, "Second", "SEC", "", type(uint256).max);
        vm.prank(alice);
        vm.expectPartialRevert(CreationCooldown.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Second", "SEC", "",
            type(uint256).max,
            0, sigB,
            0, address(0), ""
        );

        // Bob can create (cooldown is per-creator)
        bytes memory bobSig = _signCreateFor(bob, "Bob1", "BOB", "", type(uint256).max);
        vm.prank(bob);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            bob, "Bob1", "BOB", "",
            type(uint256).max,
            0, bobSig,
            0, address(0), ""
        );

        vm.warp(block.timestamp + 59);
        bytes memory sigC = _signCreateFor(alice, "Still", "STL", "", type(uint256).max);
        vm.prank(alice);
        vm.expectPartialRevert(CreationCooldown.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Still", "STL", "",
            type(uint256).max,
            0, sigC,
            0, address(0), ""
        );

        vm.warp(block.timestamp + 2);
        bytes memory sigD = _signCreateFor(alice, "Now", "NOW", "", type(uint256).max);
        vm.prank(alice);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Now", "NOW", "",
            type(uint256).max,
            0, sigD,
            0, address(0), ""
        );
    }

    function test_CreateTokenCooldown_DisabledWhenZero() public {
        // setUp set cooldown to 0; alice can create rapidly
        _createTokenCustom(alice, "A", "A", "", 0.01 ether);
        _createTokenCustom(alice, "B", "B", "", 0.01 ether);
        _createTokenCustom(alice, "C", "C", "", 0.01 ether);
        assertEq(factory.tokenCount(), 3);
    }

    function test_CreateTokenCooldown_MaxIsOneHour() public {
        vm.expectRevert(AboveMaximum.selector);
        factory.setTokenCreationCooldown(3601);

        factory.setTokenCreationCooldown(3600);
        assertEq(factory.tokenCreationCooldown(), 3600);

        factory.setTokenCreationCooldown(0);
        assertEq(factory.tokenCreationCooldown(), 0);
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 2 — Admin setter bounds
    // ════════════════════════════════════════════════════════════

    function test_Setters_PlatformFeeBps_RespectsMax() public {
        vm.expectRevert(ExceedsMaxFee.selector);
        factory.setPlatformFeeBps(501);

        factory.setPlatformFeeBps(500);
        assertEq(factory.platformFeeBps(), 500);

        factory.setReferrerFeeBps(0);
        factory.setPlatformFeeBps(1);   // 1 > 0, OK
        assertEq(factory.platformFeeBps(), 1);
}

    function test_Setters_CreatorFeeBps_RespectsMax() public {
        vm.expectRevert(ExceedsMaxFee.selector);
        factory.setCreatorFeeBps(201);

        factory.setCreatorFeeBps(200);
        assertEq(factory.creatorFeeBps(), 200);

        factory.setCreatorFeeBps(0);
        assertEq(factory.creatorFeeBps(), 0);
    }

    function test_Setters_ReferrerFeeBps_MustBeBelowPlatformFee() public {

        vm.expectRevert(ReferrerFeeExceedsPlatformFee.selector);
        factory.setReferrerFeeBps(100);   // 100 >= 100 → revert

        vm.expectRevert(ReferrerFeeExceedsPlatformFee.selector);
        factory.setReferrerFeeBps(101);   // 101 >= 100 → revert

        factory.setReferrerFeeBps(99);    // 99 < 100 → OK
        assertEq(factory.referrerFeeBps(), 99);

        vm.expectRevert(ReferrerFeeExceedsPlatformFee.selector);
        factory.setPlatformFeeBps(50);    // 50 <= 99 → revert

        assertEq(factory.platformFeeBps(), 100);
        assertEq(factory.referrerFeeBps(), 99);
    }

    function test_Setters_GraduationETH_RespectsBounds() public {
        vm.expectRevert(BelowMinimum.selector);
        factory.setGraduationETH(0);

        vm.expectRevert(BelowMinimum.selector);
        factory.setGraduationETH(4.99 ether);

        vm.expectRevert(AboveMaximum.selector);
        factory.setGraduationETH(100 ether + 1);

        factory.setGraduationETH(5 ether);
        assertEq(factory.graduationETH(), 5 ether);

        factory.setGraduationETH(100 ether);
        assertEq(factory.graduationETH(), 100 ether);
    }

    function test_Setters_GraduationFee_RespectsMax() public {
        vm.expectRevert(ExceedsMaxFee.selector);
        factory.setGraduationFee(0.1 ether + 1);

        factory.setGraduationFee(0.1 ether);
        assertEq(factory.graduationFee(), 0.1 ether);

        factory.setGraduationFee(0);
        assertEq(factory.graduationFee(), 0);
    }


    function test_Setters_OnlyOwner() public {
        vm.startPrank(alice);

        vm.expectRevert(NotOwner.selector);
        factory.setPlatformFeeBps(100);

        vm.expectRevert(NotOwner.selector);
        factory.setCreatorFeeBps(25);

        vm.expectRevert(NotOwner.selector);
        factory.setReferrerFeeBps(10);

        vm.expectRevert(NotOwner.selector);
        factory.setGraduationETH(10 ether);

        vm.expectRevert(NotOwner.selector);
        factory.setGraduationFee(0.01 ether);

        vm.expectRevert(NotOwner.selector);
        factory.setTokenCreationCooldown(120);

        vm.expectRevert(NotOwner.selector);
        factory.setSigner(address(0xABCD));

        vm.expectRevert(NotOwner.selector);
        factory.setPaused(true);

        vm.expectRevert(NotOwner.selector);
        factory.setRouter(address(0xDEAD));

        vm.expectRevert(NotOwner.selector);
        factory.setWeth(address(0xDEAD));

        vm.expectRevert(NotOwner.selector);
        factory.transferOwnership(bob);

        vm.expectRevert(NotOwner.selector);
        factory.cancelTransferOwnership();

        vm.expectRevert(NotOwner.selector);
        factory.withdrawPlatformFees();

        vm.stopPrank();
    }

    function test_Setters_AddressValidation() public {
        vm.expectRevert(InvalidAddress.selector);
        factory.setRouter(address(0));

        vm.expectRevert(InvalidAddress.selector);
        factory.setWeth(address(0));

        vm.expectRevert(InvalidAddress.selector);
        factory.transferOwnership(address(0));

        vm.expectRevert(InvalidAddress.selector);
        factory.transferOwnership(owner);
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 3 — ERC20 allowance override
    // ════════════════════════════════════════════════════════════

    function test_ERC20Allowance_FactoryHasMax() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        IERC20 token = IERC20(_tokenAddr(id));

        assertEq(
            token.allowance(alice, address(factory)),
            type(uint256).max,
            "factory has max from alice"
        );
        assertEq(
            token.allowance(address(0xDEAD), address(factory)),
            type(uint256).max,
            "factory has max from anyone"
        );
        assertEq(
            token.allowance(bob, address(factory)),
            type(uint256).max,
            "factory has max from bob"
        );
    }

    function test_ERC20Allowance_OthersStandard() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        IERC20 token = IERC20(_tokenAddr(id));

        assertEq(token.allowance(alice, bob), 0);

        vm.prank(alice);
        token.approve(bob, 1000);
        assertEq(token.allowance(alice, bob), 1000, "standard allowance set");

        vm.prank(bob);
        token.transferFrom(alice, bob, 500);
        assertEq(token.balanceOf(bob), 500);
        assertEq(token.allowance(alice, bob), 500, "decremented");

        vm.prank(bob);
        vm.expectRevert();
        token.transferFrom(alice, bob, 600);
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 4 — Multi-token state isolation
    // ════════════════════════════════════════════════════════════

    function test_MultipleTokens_StateIsolation() public {
        uint256 idA = _createTokenCustom(alice,   "A", "AA", "", 1 ether);
        uint256 idB = _createTokenCustom(bob,     "B", "BB", "", 2 ether);
        uint256 idC = _createTokenCustom(charlie, "C", "CC", "", 0.5 ether);

        MegaPumpLens.TokenInfo memory infoA_before = _info(idA);
        MegaPumpLens.TokenInfo memory infoC_before = _info(idC);

        _buy(idB, charlie, 5 ether);
        _buy(idB, alice, 3 ether);
        uint256 charlieB = _balanceOf(idB, charlie);
        _sell(idB, charlie, charlieB / 2);

        MegaPumpLens.TokenInfo memory infoA_after = _info(idA);
        MegaPumpLens.TokenInfo memory infoC_after = _info(idC);

        assertEq(infoA_after.totalRaised,  infoA_before.totalRaised);
        assertEq(infoA_after.tokensSold,   infoA_before.tokensSold);
        assertEq(infoA_after.creatorFees,  infoA_before.creatorFees);
        assertEq(infoA_after.tokenAddress, infoA_before.tokenAddress);

        assertEq(infoC_after.totalRaised,  infoC_before.totalRaised);
        assertEq(infoC_after.tokensSold,   infoC_before.tokensSold);
        assertEq(infoC_after.creatorFees,  infoC_before.creatorFees);

        assertTrue(infoA_after.tokenAddress != _info(idB).tokenAddress);
        assertTrue(infoA_after.tokenAddress != infoC_after.tokenAddress);
        assertTrue(_info(idB).tokenAddress  != infoC_after.tokenAddress);

        assertEq(infoA_after.creator, alice);
        assertEq(_info(idB).creator,  bob);
        assertEq(infoC_after.creator, charlie);
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 5 — Small amount edge cases
    //  V2 NOTE: createAndBuyForCreator REQUIRES msg.value > 0, so the
    //  "1 wei buy on creation" path doesn't exist directly. But the
    //  small-buy behavior on an already-deployed token still does.
    // ════════════════════════════════════════════════════════════

    function test_SmallAmounts_OneWeiBuy_AcceptedButZeroFees() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        uint256 platformBefore = factory.platformFeesAccrued();
        uint256 creatorBefore  = _info(id).creatorFees;
        uint256 bobBalBefore   = bob.balance;

        vm.prank(bob);
        factory.buy{value: 1}(id, 0, address(0), "");

        assertEq(bobBalBefore - bob.balance, 1, "exact 1 wei spent");
        assertGt(_balanceOf(id, bob), 0, "got non-zero tokens");

        assertEq(factory.platformFeesAccrued(), platformBefore, "no platform fee");
        assertEq(_info(id).creatorFees, creatorBefore, "no creator fee");
    }

    function test_SmallAmounts_ZeroEthBuy_Reverts() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        vm.prank(bob);
        vm.expectRevert(NoETH.selector);
        factory.buy{value: 0}(id, 0, address(0), "");
    }

    function test_SmallAmounts_ZeroTokensSell_Reverts() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        _buy(id, bob, 1 ether);

        vm.prank(bob);
        vm.expectRevert(NoTokens.selector);
        factory.sell(id, 0, 0, address(0), "");
    }

    function test_SmallAmounts_TinyButValidBuy() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        uint256 estimated = lens.estimateBuy(id, 10000, bob);

        if (estimated == 0) {
            vm.prank(bob);
            vm.expectRevert(ZeroTokensOut.selector);
            factory.buy{value: 10000}(id, 0, address(0), "");
        } else {
            vm.prank(bob);
            factory.buy{value: 10000}(id, 0, address(0), "");
            assertGt(_balanceOf(id, bob), 0);
        }
    }

    function test_SmallAmounts_SellMoreThanSold_Reverts() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        _buy(id, bob, 1 ether);

        uint256 sold = _info(id).tokensSold;

        vm.prank(alice);
        vm.expectRevert(ExceedsSoldSupply.selector);
        factory.sell(id, sold + 1, 0, address(0), "");
    }

    function test_SmallAmounts_OneTokenSell_Behavior() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        _buy(id, bob, 1 ether);

        uint256 totalRaisedBefore = _info(id).totalRaised;
        uint256 tokensSoldBefore  = _info(id).tokensSold;

        vm.prank(bob);
        try factory.sell(id, 1, 0, address(0), "") {
            assertLe(_info(id).totalRaised, totalRaisedBefore, "raised never grows on sell");
            assertEq(_info(id).tokensSold, tokensSoldBefore - 1, "exactly 1 token less");
        } catch {
            // Acceptable to revert
        }
    }
}
