// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Helpers.sol";

/// @notice Tests for creator-aware estimate functions.
contract EstimateFunctionsTest is Helpers {

    // ════════════════════════════════════════════════════════════
    //  estimateBuy
    // ════════════════════════════════════════════════════════════

    function test_EstimateBuy_CreatorVsNonCreator() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        uint256 ethAmt = 1 ether;
        uint256 estCreator    = factory.estimateBuy(id, ethAmt, alice);
        uint256 estNonCreator = factory.estimateBuy(id, ethAmt, bob);

        assertGt(estCreator, estNonCreator, "creator gets more for same ETH");
    }

    function test_EstimateBuy_AddressZero_DefaultsToNonCreator() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        uint256 estDefault    = factory.estimateBuy(id, 1 ether, address(0));
        uint256 estNonCreator = factory.estimateBuy(id, 1 ether, bob);

        assertEq(estDefault, estNonCreator, "address(0) returns safe estimate");
    }

    function test_EstimateBuy_MatchesActual_Creator() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        uint256 estimated = factory.estimateBuy(id, 1 ether, alice);
        uint256 balBefore = _balanceOf(id, alice);

        _buy(id, alice, 1 ether);
        uint256 received = _balanceOf(id, alice) - balBefore;

        assertEq(received, estimated, "creator estimate matches actual");
    }

    function test_EstimateBuy_MatchesActual_NonCreator() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        uint256 estimated = factory.estimateBuy(id, 1 ether, bob);
        uint256 balBefore = _balanceOf(id, bob);

        _buy(id, bob, 1 ether);
        uint256 received = _balanceOf(id, bob) - balBefore;

        assertEq(received, estimated, "non-creator estimate matches actual");
    }

    // ════════════════════════════════════════════════════════════
    //  estimateSell
    // ════════════════════════════════════════════════════════════

    function test_EstimateSell_CreatorVsNonCreator() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        _buy(id, bob, 5 ether);

        uint256 amount = 1_000_000 * 1e18;
        uint256 estCreator    = factory.estimateSell(id, amount, alice);
        uint256 estNonCreator = factory.estimateSell(id, amount, bob);

        assertGt(estCreator, estNonCreator, "creator receives more on sell");
    }

    function test_EstimateSell_AddressZero_DefaultsToNonCreator() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        _buy(id, bob, 5 ether);

        uint256 amount = 1_000_000 * 1e18;
        uint256 estDefault    = factory.estimateSell(id, amount, address(0));
        uint256 estNonCreator = factory.estimateSell(id, amount, bob);

        assertEq(estDefault, estNonCreator, "address(0) returns safe estimate");
    }

    function test_EstimateSell_MatchesActual_Creator() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        uint256 aliceTokens = _balanceOf(id, alice);
        uint256 sellAmount = aliceTokens / 2;

        uint256 estimated = factory.estimateSell(id, sellAmount, alice);
        uint256 ethBefore = alice.balance;

        _sell(id, alice, sellAmount);
        uint256 received = alice.balance - ethBefore;

        assertEq(received, estimated, "creator estimate matches actual sell");
    }

    function test_EstimateSell_MatchesActual_NonCreator() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        _buy(id, bob, 5 ether);

        uint256 bobTokens = _balanceOf(id, bob);
        uint256 sellAmount = bobTokens / 2;

        uint256 estimated = factory.estimateSell(id, sellAmount, bob);
        uint256 ethBefore = bob.balance;

        _sell(id, bob, sellAmount);
        uint256 received = bob.balance - ethBefore;

        assertEq(received, estimated, "non-creator estimate matches actual");
    }

    // ════════════════════════════════════════════════════════════
    //  estimateBuyReverse
    // ════════════════════════════════════════════════════════════

    function test_EstimateBuyReverse_CreatorVsNonCreator() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        uint256 tokensWanted = 1_000_000 * 1e18;
        uint256 ethCreator    = factory.estimateBuyReverse(id, tokensWanted, alice);
        uint256 ethNonCreator = factory.estimateBuyReverse(id, tokensWanted, bob);

        assertLt(ethCreator, ethNonCreator, "creator pays less for same tokens");
    }

    function test_EstimateBuyReverse_DeliversAtLeastWanted_Creator() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        uint256 tokensWanted = 5_000_000 * 1e18;
        uint256 ethRequired = factory.estimateBuyReverse(id, tokensWanted, alice);
        uint256 balBefore = _balanceOf(id, alice);

        _buy(id, alice, ethRequired);
        uint256 received = _balanceOf(id, alice) - balBefore;

        assertGe(received, tokensWanted, "creator receives at least what was reversed");
    }

    function test_EstimateBuyReverse_DeliversAtLeastWanted_NonCreator() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        uint256 tokensWanted = 5_000_000 * 1e18;
        uint256 ethRequired = factory.estimateBuyReverse(id, tokensWanted, bob);
        uint256 balBefore = _balanceOf(id, bob);

        _buy(id, bob, ethRequired);
        uint256 received = _balanceOf(id, bob) - balBefore;

        assertGe(received, tokensWanted, "non-creator receives at least what was reversed");
    }

    // ════════════════════════════════════════════════════════════
    //  estimateSellReverse
    // ════════════════════════════════════════════════════════════

    function test_EstimateSellReverse_CreatorVsNonCreator() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        _buy(id, bob, 5 ether);

        uint256 ethWanted = 0.5 ether;
        uint256 tokensCreator    = factory.estimateSellReverse(id, ethWanted, alice);
        uint256 tokensNonCreator = factory.estimateSellReverse(id, ethWanted, bob);

        assertLt(tokensCreator, tokensNonCreator, "creator sells fewer tokens for same ETH");
    }

    function test_EstimateSellReverse_DeliversAtLeastWanted_NonCreator() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        _buy(id, bob, 5 ether);

        uint256 ethWanted = 0.5 ether;
        uint256 tokensToSell = factory.estimateSellReverse(id, ethWanted, bob);
        uint256 ethBefore = bob.balance;

        _sell(id, bob, tokensToSell);
        uint256 received = bob.balance - ethBefore;

        assertGe(received, ethWanted, "non-creator receives at least what was reversed");
    }

    // ════════════════════════════════════════════════════════════
    //  Cross-sanity
    // ════════════════════════════════════════════════════════════

    function test_BuyForward_BackwardConsistency_NonCreator() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        uint256 ethSent = 1 ether;
        uint256 tokensExpected = factory.estimateBuy(id, ethSent, bob);
        uint256 ethRequired    = factory.estimateBuyReverse(id, tokensExpected, bob);

        assertGe(ethRequired, ethSent, "reverse never returns less");
        assertLe(ethRequired - ethSent, 100, "reverse drift < 100 wei");
    }
}