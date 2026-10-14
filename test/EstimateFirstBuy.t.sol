// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Helpers.sol";
import "../src/BondingCurveMath.sol";

/// @notice Tests for estimateFirstBuy & estimateFirstBuyReverse — the view
///         functions the frontend uses to display a "You receive" / "You pay"
///         estimate before a PENDING token's first buy.
///
///         Since PENDING tokens have no on-chain state (totalRaised=0,
///         tokensSold=0), these functions don't take a tokenId. They simply
///         apply the curve math at zero state, with fees adjusted based on
///         whether the future caller will be the creator (self-buy = no
///         creator fee) or a third party.
contract EstimateFirstBuyTest is Helpers {

    // ════════════════════════════════════════════════════════════
    //  estimateFirstBuy — direct (ETH -> tokens)
    // ════════════════════════════════════════════════════════════

    function test_EstimateFirstBuy_ZeroEth_ReturnsZero() public {
        assertEq(lens.estimateFirstBuy(0, false), 0, "zero in -> zero out (3rd party)");
        assertEq(lens.estimateFirstBuy(0, true),  0, "zero in -> zero out (creator)");
    }

    function test_EstimateFirstBuy_NonCreator_AppliesFullFees() public view {
        uint256 ethIn = 0.1 ether;
        uint256 tokensOut = lens.estimateFirstBuy(ethIn, false);

        uint256 totalFeeBps  = factory.platformFeeBps() + factory.creatorFeeBps();
        uint256 ethAfterFees = ethIn - (ethIn * totalFeeBps) / 10000;
        uint256 expected = BondingCurveMath.getTokensForETH(
            0,
            ethAfterFees,
            factory.graduationETH()
        );

        assertEq(tokensOut, expected, "3rd-party first buy with full fees");
    }

    function test_EstimateFirstBuy_Creator_NoCreatorFee() public view {
        uint256 ethIn = 0.1 ether;
        uint256 tokensOut = lens.estimateFirstBuy(ethIn, true);

        // Creator pays only platform fee (no creator fee on their own buy)
        uint256 feeBps       = factory.platformFeeBps();
        uint256 ethAfterFees = ethIn - (ethIn * feeBps) / 10000;
        uint256 expected = BondingCurveMath.getTokensForETH(
            0,
            ethAfterFees,
            factory.graduationETH()
        );

        assertEq(tokensOut, expected, "creator self-buy: only platform fee");
    }

    function test_EstimateFirstBuy_CreatorGetsMoreThanThirdParty() public view {
        uint256 ethIn = 0.1 ether;
        uint256 asCreator    = lens.estimateFirstBuy(ethIn, true);
        uint256 asThirdParty = lens.estimateFirstBuy(ethIn, false);

        assertGt(asCreator, asThirdParty, "creator pays less fees -> receives more tokens");
    }

    function test_EstimateFirstBuy_CappedAtGraduationETH() public view {
        // Huge buy that would push past graduation in one shot.
        // The function MUST cap ethAfterFees to graduationETH to avoid
        // returning absurd values from the curve math.
        uint256 hugeEthIn = 100 ether;
        uint256 tokensOut = lens.estimateFirstBuy(hugeEthIn, false);

        // Expected = curve at zero state with ethAfterFees capped to graduationETH
        uint256 expected = BondingCurveMath.getTokensForETH(
            0,
            factory.graduationETH(),
            factory.graduationETH()
        );

        assertEq(tokensOut, expected, "huge buy capped to graduationETH");
    }

    // ════════════════════════════════════════════════════════════
    //  estimateFirstBuy — matches actual execution
    //
    //  The real test: the estimate must match what the contract
    //  actually delivers on a first buy via createAndBuyForCreator.
    // ════════════════════════════════════════════════════════════

    function test_EstimateFirstBuy_MatchesActualExecution_Creator() public {
        uint256 ethIn = 0.05 ether;

        // Estimate first (alice IS the creator -> isCreator=true)
        uint256 estimated = lens.estimateFirstBuy(ethIn, true);

        // Execute the first buy via createAndBuyForCreator
        bytes memory sig = _signCreateFor(
            alice, "EstTest", "EST", "ipfs://test", type(uint256).max, 0
        );
        vm.prank(alice);
        uint256 id = factory.createAndBuyForCreator{value: ethIn}(
            alice,
            "EstTest", "EST", "ipfs://test",
            type(uint256).max,
            0,            // nonce
            sig,
            0, address(0), ""
        );

        uint256 actualBalance = _balanceOf(id, alice);
        assertEq(actualBalance, estimated, "creator: estimate must equal delivery");
    }

    function test_EstimateFirstBuy_MatchesActualExecution_ThirdParty() public {
        uint256 ethIn = 0.05 ether;

        // Estimate first (bob is third party, NOT the creator -> isCreator=false)
        uint256 estimated = lens.estimateFirstBuy(ethIn, false);

        // Bob executes the first buy on behalf of alice (creator)
        // Alice signs the create authorization
        bytes memory sig = _signCreateFor(
            alice, "EstTest2", "EST2", "ipfs://test", type(uint256).max, 0
        );
        vm.deal(bob, ethIn);
        vm.prank(bob);
        uint256 id = factory.createAndBuyForCreator{value: ethIn}(
            alice,
            "EstTest2", "EST2", "ipfs://test",
            type(uint256).max,
            0,            // nonce
            sig,
            0, address(0), ""
        );

        // Bob is the buyer -> tokens go to bob
        uint256 actualBalance = _balanceOf(id, bob);
        assertEq(actualBalance, estimated, "third party: estimate must equal delivery");
    }

    // ════════════════════════════════════════════════════════════
    //  estimateFirstBuyReverse — reverse (tokens -> ETH)
    // ════════════════════════════════════════════════════════════

    function test_EstimateFirstBuyReverse_ZeroTokens_ReturnsZero() public {
        assertEq(lens.estimateFirstBuyReverse(0, false), 0);
        assertEq(lens.estimateFirstBuyReverse(0, true),  0);
    }

    function test_EstimateFirstBuyReverse_RoundTrip_NonCreator() public view {
        // Round-trip: tokens -> ETH (reverse) -> tokens (forward) must give ≥ original.
        // Reverse rounds UP (ceil) so the forward call should yield at least
        // tokensWanted — never less.
        uint256 tokensWanted = 1_000_000 ether;
        uint256 ethNeeded     = lens.estimateFirstBuyReverse(tokensWanted, false);
        uint256 tokensReceived = lens.estimateFirstBuy(ethNeeded, false);

        assertGe(tokensReceived, tokensWanted, "reverse must round up (3rd party)");
    }

    function test_EstimateFirstBuyReverse_RoundTrip_Creator() public view {
        uint256 tokensWanted = 1_000_000 ether;
        uint256 ethNeeded     = lens.estimateFirstBuyReverse(tokensWanted, true);
        uint256 tokensReceived = lens.estimateFirstBuy(ethNeeded, true);

        assertGe(tokensReceived, tokensWanted, "reverse must round up (creator)");
    }

    function test_EstimateFirstBuyReverse_CreatorNeedsLessETH() public view {
        uint256 tokensWanted = 1_000_000 ether;
        uint256 asCreator    = lens.estimateFirstBuyReverse(tokensWanted, true);
        uint256 asThirdParty = lens.estimateFirstBuyReverse(tokensWanted, false);

        assertLt(asCreator, asThirdParty, "creator pays less ETH for same tokens");
    }

    function test_EstimateFirstBuyReverse_MatchesActualExecution_Creator() public {
        // Use reverse to figure out how much ETH alice needs for ~1M tokens,
        // then actually buy and verify she receives at least 1M tokens.
        uint256 tokensWanted = 1_000_000 ether;
        uint256 ethNeeded    = lens.estimateFirstBuyReverse(tokensWanted, true);

        bytes memory sig = _signCreateFor(
            alice, "RevTest", "REV", "ipfs://test", type(uint256).max, 0
        );
        vm.prank(alice);
        uint256 id = factory.createAndBuyForCreator{value: ethNeeded}(
            alice,
            "RevTest", "REV", "ipfs://test",
            type(uint256).max,
            0,            // nonce
            sig,
            0, address(0), ""
        );

        uint256 actualBalance = _balanceOf(id, alice);
        assertGe(actualBalance, tokensWanted, "reverse: must receive at least tokensWanted");
    }
}
