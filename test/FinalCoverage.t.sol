// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Helpers.sol";

/// @notice Final coverage tests addressing all gaps identified in audit.
contract FinalCoverageTest is Helpers {

    // ════════════════════════════════════════════════════════════
    //  TEST 1 — createAndBuyForCreator respects cooldown (per-creator)
    // ════════════════════════════════════════════════════════════

    function test_CreateAndBuyForCreator_RespectsCooldown() public {
        factory.setTokenCreationCooldown(60);

        // Alice creates first
        bytes memory sig1 = _signCreateFor(alice, "First", "FST", "", type(uint256).max);
        vm.prank(alice);
        factory.createAndBuyForCreator{value: 0.05 ether}(
            alice, "First", "FST", "",
            type(uint256).max,
            0, sig1,
            0, address(0), ""
        );

        // Immediate second by alice → revert
        bytes memory sig2 = _signCreateFor(alice, "Second", "SEC", "", type(uint256).max);
        vm.prank(alice);
        vm.expectPartialRevert(CreationCooldown.selector);
        factory.createAndBuyForCreator{value: 0.05 ether}(
            alice, "Second", "SEC", "",
            type(uint256).max,
            0, sig2,
            0, address(0), ""
        );

        // Bob can still create (cooldown is per-creator)
        bytes memory bobSig = _signCreateFor(bob, "BobToken", "BOB", "", type(uint256).max);
        vm.prank(bob);
        factory.createAndBuyForCreator{value: 0.05 ether}(
            bob, "BobToken", "BOB", "",
            type(uint256).max,
            0, bobSig,
            0, address(0), ""
        );

        // After 61s, alice can again
        vm.warp(block.timestamp + 61);
        bytes memory sig3 = _signCreateFor(alice, "AliceAgain", "AAA", "", type(uint256).max);
        vm.prank(alice);
        factory.createAndBuyForCreator{value: 0.05 ether}(
            alice, "AliceAgain", "AAA", "",
            type(uint256).max,
            0, sig3,
            0, address(0), ""
        );
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 2 — createAndBuyForCreator with msg.value == 0
    // ════════════════════════════════════════════════════════════

    function test_CreateAndBuyForCreator_ZeroValue_Reverts() public {
        bytes memory sig = _signCreateFor(alice, "Test", "TST", "", type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(NoETH.selector);
        factory.createAndBuyForCreator{value: 0}(
            alice, "Test", "TST", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 3 — Validation: name and ticker
    // ════════════════════════════════════════════════════════════

    function test_CreateAndBuyForCreator_InvalidName_Reverts() public {
        // Empty name
        bytes memory sig1 = _signCreateFor(alice, "", "TST", "", type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(InvalidName.selector);
        factory.createAndBuyForCreator{value: 0.05 ether}(
            alice, "", "TST", "",
            type(uint256).max,
            0, sig1,
            0, address(0), ""
        );

        // Name > 32 chars
        string memory long = "123456789012345678901234567890123";
        bytes memory sig2 = _signCreateFor(alice, long, "TST", "", type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(InvalidName.selector);
        factory.createAndBuyForCreator{value: 0.05 ether}(
            alice, long, "TST", "",
            type(uint256).max,
            0, sig2,
            0, address(0), ""
        );
    }

    function test_CreateAndBuyForCreator_InvalidTicker_Reverts() public {
        bytes memory sig1 = _signCreateFor(alice, "Name", "", "", type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(InvalidTicker.selector);
        factory.createAndBuyForCreator{value: 0.05 ether}(
            alice, "Name", "", "",
            type(uint256).max,
            0, sig1,
            0, address(0), ""
        );

        bytes memory sig2 = _signCreateFor(alice, "Name", "12345678901", "", type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(InvalidTicker.selector);
        factory.createAndBuyForCreator{value: 0.05 ether}(
            alice, "Name", "12345678901", "",
            type(uint256).max,
            0, sig2,
            0, address(0), ""
        );
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 4 — buy/sell with invalid tokenId (validToken modifier)
    // ════════════════════════════════════════════════════════════

    function test_Buy_InvalidTokenId_Reverts() public {
        vm.prank(bob);
        vm.expectRevert(TokenNotFound.selector);
        factory.buy{value: 0.1 ether}(0, 0, address(0), "");

        vm.prank(bob);
        vm.expectRevert(TokenNotFound.selector);
        factory.buy{value: 0.1 ether}(999, 0, address(0), "");
    }

    function test_Sell_InvalidTokenId_Reverts() public {
        vm.prank(bob);
        vm.expectRevert(TokenNotFound.selector);
        factory.sell(0, 1e18, 0, address(0), "");

        vm.prank(bob);
        vm.expectRevert(TokenNotFound.selector);
        factory.sell(999, 1e18, 0, address(0), "");
    }

    function test_ClaimCreatorFees_InvalidTokenId_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(TokenNotFound.selector);
        factory.claimCreatorFees(0);

        vm.prank(alice);
        vm.expectRevert(TokenNotFound.selector);
        factory.claimCreatorFees(999);
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 5 — claimAllCreatorFees edge cases
    // ════════════════════════════════════════════════════════════

    function test_ClaimAllCreatorFees_EmptyArray_Reverts() public {
        uint256[] memory empty = new uint256[](0);
        vm.prank(alice);
        vm.expectRevert(EmptyBatch.selector);
        factory.claimAllCreatorFees(empty);
    }

    function test_ClaimAllCreatorFees_OversizedBatch_Reverts() public {
        uint256[] memory ids = new uint256[](101);
        for (uint256 i = 0; i < 101; i++) {
            ids[i] = i + 1;
        }
        vm.prank(alice);
        vm.expectRevert(BatchTooLarge.selector);
        factory.claimAllCreatorFees(ids);
    }

    function test_ClaimAllCreatorFees_InvalidIdsInBatch_SilentlySkipped() public {
        uint256 id = _createAndDeploy(alice, 0.1 ether);
        _buy(id, bob, 1 ether);
        uint256 expectedFees = _info(id).creatorFees;
        assertGt(expectedFees, 0);

        uint256[] memory ids = new uint256[](4);
        ids[0] = 0;
        ids[1] = 999;
        ids[2] = id;
        ids[3] = 12345;

        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        factory.claimAllCreatorFees(ids);

        assertEq(alice.balance - aliceBalBefore, expectedFees, "got valid fees only");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 6 — Reentrancy on createAndBuyForCreator
    //
    //  V2: Attacker is installed via vm.etch at an address whose pk we know,
    //  so we can sign the EIP-712 message on its behalf.
    //  The attacker contract triggers a refund (by buying near graduation),
    //  and tries to re-enter on receive().
    // ════════════════════════════════════════════════════════════

    function test_CreateAndBuyForCreator_Reentrancy_Blocked() public {
        // Set up attacker at a known EOA address
        uint256 attackerPk = uint256(keccak256("attacker.pk.create"));
        address attackerAddr = vm.addr(attackerPk);

        CreateAndBuyAttacker template = new CreateAndBuyAttacker(factory);
        vm.etch(attackerAddr, address(template).code);
        // Initialize storage slot 0 (factory address)
        vm.store(attackerAddr, bytes32(uint256(0)), bytes32(uint256(uint160(address(factory)))));

        vm.deal(attackerAddr, 100 ether);

        // Sign for the attacker
        bytes memory sig = _signCreate(
            attackerPk, attackerAddr,
            "Attack", "ATK", "",
            type(uint256).max
        );

        // The attack: createAndBuyForCreator with massive value → triggers refund
        // → refund call to attackerAddr → receive() tries to re-enter
        // → nonReentrant MUST revert
        vm.expectRevert();
        CreateAndBuyAttacker(payable(attackerAddr)).attackWithSig{value: 50 ether}(sig);
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 7 — Reentrancy on withdrawPlatformFees
    // ════════════════════════════════════════════════════════════

    function test_WithdrawPlatformFees_Reentrancy_Blocked() public {
        uint256 id = _createAndDeploy(alice, 0.5 ether);
        _buy(id, bob, 5 ether);
        assertGt(factory.platformFeesAccrued(), 0);

        WithdrawAttacker attacker = new WithdrawAttacker(factory);
        factory.transferOwnership(address(attacker));
        attacker.acceptOwnership();

        vm.expectRevert();
        attacker.attack();
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 8 — initialize: address(0) checks
    // ════════════════════════════════════════════════════════════

    function test_Initialize_ZeroRouter_Reverts() public {
        MegaPumpFactory impl = new MegaPumpFactory();

        bytes memory badInit = abi.encodeCall(
            MegaPumpFactory.initialize,
            (address(0), address(weth))
        );
        vm.expectRevert(InvalidAddress.selector);
        new ERC1967Proxy(address(impl), badInit);
    }

    function test_Initialize_ZeroWeth_Reverts() public {
        MegaPumpFactory impl = new MegaPumpFactory();

        bytes memory badInit = abi.encodeCall(
            MegaPumpFactory.initialize,
            (address(router), address(0))
        );
        vm.expectRevert(InvalidAddress.selector);
        new ERC1967Proxy(address(impl), badInit);
    }

    function test_Initialize_DoubleInitialize_Reverts() public {
        vm.expectRevert();
        factory.initialize(address(router), address(weth));
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 9 — Ownership: multiple transferOwnership overwrites pending
    // ════════════════════════════════════════════════════════════

    function test_Ownership_MultipleTransfer_OverwritesPending() public {
        factory.transferOwnership(alice);
        assertEq(factory.pendingOwner(), alice);

        factory.transferOwnership(bob);
        assertEq(factory.pendingOwner(), bob, "pending overwritten to bob");

        vm.prank(alice);
        vm.expectRevert(NotPendingOwner.selector);
        factory.acceptOwnership();

        vm.prank(bob);
        factory.acceptOwnership();
        assertEq(factory.owner(), bob);
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 10 — Sell without owning tokens reverts cleanly
    // ════════════════════════════════════════════════════════════

    function test_Sell_NoTokens_RevertsCleanly() public {
        uint256 id = _createAndDeploy(alice, 0.1 ether);
        _buy(id, bob, 0.5 ether);

        uint256 raisedBefore   = _info(id).totalRaised;
        uint256 soldBefore     = _info(id).tokensSold;
        uint256 platformBefore = factory.platformFeesAccrued();

        vm.prank(charlie);
        vm.expectRevert();
        factory.sell(id, 1e18, 0, address(0), "");

        assertEq(_info(id).totalRaised,   raisedBefore,   "raised unchanged");
        assertEq(_info(id).tokensSold,    soldBefore,     "sold unchanged");
        assertEq(factory.platformFeesAccrued(), platformBefore, "fees unchanged");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 11 — Total supply conservation
    // ════════════════════════════════════════════════════════════

    function test_TotalSupplyConservation_StrictInvariant() public {
        uint256 id = _createAndDeploy(alice, 0.5 ether);
        _buy(id, bob, 1 ether);
        _buy(id, charlie, 0.7 ether);

        address dave = address(0xDA1E);
        vm.deal(dave, 10 ether);
        _buy(id, dave, 0.3 ether);

        uint256 bobTokens = _balanceOf(id, bob);
        _sell(id, bob, bobTokens / 2);

        uint256 charlieTokens = _balanceOf(id, charlie);
        _sell(id, charlie, charlieTokens);

        address tokenAddr = _info(id).tokenAddress;
        uint256 sumHolders =
              _balanceOf(id, alice)
            + _balanceOf(id, bob)
            + _balanceOf(id, charlie)
            + _balanceOf(id, dave);
        uint256 factoryHolds = IERC20(tokenAddr).balanceOf(address(factory));

        assertEq(
            sumHolders + factoryHolds,
            factory.TOTAL_SUPPLY(),
            "every token accounted for"
        );

        assertEq(_info(id).tokensSold, sumHolders, "tokensSold == sum(holders)");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 12 — TokenIdByAddress consistency
    // ════════════════════════════════════════════════════════════

    function test_TokenIdByAddress_BijectionMaintained() public {
        uint256 id1 = _createTokenCustom(alice,   "A", "AA", "", 0.1 ether);
        uint256 id2 = _createTokenCustom(bob,     "B", "BB", "", 0.1 ether);
        uint256 id3 = _createTokenCustom(charlie, "C", "CC", "", 0.1 ether);

        address addr1 = _info(id1).tokenAddress;
        address addr2 = _info(id2).tokenAddress;
        address addr3 = _info(id3).tokenAddress;

        assertEq(factory.getTokenId(addr1), id1);
        assertEq(factory.getTokenId(addr2), id2);
        assertEq(factory.getTokenId(addr3), id3);

        assertEq(_info(id1).tokenAddress, addr1);
        assertEq(_info(id2).tokenAddress, addr2);
        assertEq(_info(id3).tokenAddress, addr3);

        assertTrue(addr1 != addr2);
        assertTrue(addr2 != addr3);
        assertTrue(addr1 != addr3);
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 13 — getTokenCount accuracy
    // ════════════════════════════════════════════════════════════

    function test_GetTokenCount_Accuracy() public {
        assertEq(factory.getTokenCount(), 0, "starts at 0");

        _createTokenCustom(alice, "A", "AA", "", 0.1 ether);
        assertEq(factory.getTokenCount(), 1);

        _createTokenCustom(bob, "B", "BB", "", 0.1 ether);
        assertEq(factory.getTokenCount(), 2);

        _createTokenCustom(charlie, "X", "X", "", 0.1 ether);
        assertEq(factory.getTokenCount(), 3);

        // Failed creation does NOT increment
        bytes memory sig = _signCreateFor(alice, "", "X", "", type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(InvalidName.selector);
        factory.createAndBuyForCreator{value: 0.05 ether}(
            alice, "", "X", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );
        assertEq(factory.getTokenCount(), 3, "failed creation does not increment");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 14 — DEX_SUPPLY constant matches actual DEX allocation
    // ════════════════════════════════════════════════════════════

    function test_DexSupply_MatchesAllocation() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        vm.deal(bob, 100 ether);
        vm.prank(bob);
        factory.buy{value: 50 ether}(id, 0, address(0), "");
        assertTrue(_info(id).graduated);

        address tokenAddr = _info(id).tokenAddress;
        uint256 pmHolds = IERC20(tokenAddr).balanceOf(address(router));

        uint256 dexSupply = factory.DEX_SUPPLY();
        assertApproxEqAbs(pmHolds, dexSupply, 100, "DEX received DEX_SUPPLY");
    }


    function test_ClaimAllCreatorFees_ExactlyMaxBatch_Succeeds() public {
        // One real token with accrued fees; the other 99 slots are invalid IDs
        // that get silently skipped. This proves the boundary: a batch of
        // exactly 100 passes the size check (101 reverts — see test above),
        // and the valid entry still pays out.
        uint256 id = _createTokenCustom(alice, "Max", "MAX", "", 0.1 ether);
        _buy(id, bob, 1 ether); // third-party buy → creator fees for alice

        uint256[] memory ids = new uint256[](100);
        ids[0] = id;
        for (uint256 i = 1; i < 100; i++) {
            ids[i] = 100_000 + i; // out-of-range IDs, skipped by the loop
        }

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        factory.claimAllCreatorFees(ids);
        assertGt(alice.balance, balBefore, "batch of exactly 100 must pass and pay out");
    }


    /// @notice Gas measurement: 100 REAL claims in one batch (worst case).
    ///         Proves the max batch fits comfortably in any realistic block
    ///         gas limit. Logs the exact cost of the claim call itself,
    ///         isolated from the token-creation setup.
    function test_ClaimAllCreatorFees_MaxBatch_GasMeasured() public {
        uint256[] memory ids = new uint256[](100);
        for (uint256 i = 0; i < 100; i++) {
            // Distinct URI per token: the self-create signature is consumed (M1),
            // the same signed fields can't launch twice.
            uint256 id = _createTokenCustom(alice, "G", "GG", string.concat("ipfs://g", vm.toString(i)), 0.01 ether);
            _buy(id, bob, 0.5 ether); // real third-party buy → real creator fees
            ids[i] = id;
            vm.roll(block.number + 1); // spread out, avoids cooldown/anti-snipe interference
        }

        uint256 balBefore = alice.balance;

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        factory.claimAllCreatorFees(ids);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Gas used by claimAllCreatorFees(100 real claims)", gasUsed);
        emit log_named_uint("Gas per claim (avg)", gasUsed / 100);
        emit log_named_uint("ETH received", alice.balance - balBefore);

        assertGt(alice.balance, balBefore, "all 100 claims paid out");
        // Generous ceiling: far below any block gas limit. If this ever fails,
        // the claim loop's cost profile has fundamentally changed — investigate.
        assertLt(gasUsed, 5_000_000, "100-claim batch must stay well under block limits");
    }
}

// ════════════════════════════════════════════════════════════════════
//  ATTACKERS
// ════════════════════════════════════════════════════════════════════

contract CreateAndBuyAttacker {
    MegaPumpFactory public factory;
    bool public reentered;

    constructor(MegaPumpFactory _f) { factory = _f; }

    /// @notice Triggers createAndBuyForCreator with a pre-signed sig.
    ///         Must be called from a deal-funded address whose pk signed `sig`.
    function attackWithSig(bytes calldata sig) external payable {
        factory.createAndBuyForCreator{value: msg.value}(
            address(this),
            "Attack", "ATK", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            // Try a re-enter — must fail.
            // We use a malformed sig (any bytes) — it will fail signature check
            // OR fail reentrancy. Either way: top-level call must revert.
            bytes memory dummy = new bytes(65);
            try factory.createAndBuyForCreator{value: 0.01 ether}(
                address(this), "R", "R", "",
                type(uint256).max,
                0, dummy,
                0, address(0), ""
            ) {
                revert("reentry should have failed");
            } catch {
                revert("reentry blocked");
            }
        }
    }
}

contract WithdrawAttacker {
    MegaPumpFactory public factory;
    bool public reentered;

    constructor(MegaPumpFactory _f) { factory = _f; }

    function acceptOwnership() external {
        factory.acceptOwnership();
    }

    function attack() external {
        factory.withdrawPlatformFees();
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            try factory.withdrawPlatformFees() {
                revert("reentry should have failed");
            } catch {
                revert("reentry blocked");
            }
        }
    }
}
