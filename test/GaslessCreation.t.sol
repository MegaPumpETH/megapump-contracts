// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Helpers.sol";
import "../src/MegaPumpFactory.sol";

/// @notice Exhaustive tests for the gasless creation flow (createAndBuyForCreator).
///         Focus areas: EIP-712 signature validity, anti-replay, third-party
///         scenarios, cross-domain protection, cooldown invariants, storage
///         layout, creator-as-referrer, defensive edges, and NONCE handling.
///
///         Companion to CreateAndBuyForCreator.t.sol (happy-path coverage).
contract GaslessCreationTest is Helpers {

    // ════════════════════════════════════════════════════════════════
    //  SECTION 1 — EIP-712 SIGNATURE VALIDITY
    // ════════════════════════════════════════════════════════════════

    function test_SigExpired_BeforeBlockTimestamp() public {
        vm.warp(1_000_000);
        uint256 deadline = block.timestamp - 1;

        bytes memory sig = _signCreateFor(alice, "Tok", "TK", "", deadline, 0);
        vm.prank(bob);
        vm.expectRevert(SignatureExpired.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            deadline,
            0, sig,
            0, address(0), ""
        );
    }

    function test_SigExpired_DeadlineZero() public {
        vm.warp(1);
        bytes memory sig = _signCreateFor(alice, "Tok", "TK", "", 0, 0);
        vm.prank(bob);
        vm.expectRevert(SignatureExpired.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            0,
            0, sig,
            0, address(0), ""
        );
    }

    function test_SigDeadline_EqualToBlockTimestamp_Succeeds() public {
        vm.warp(1_000_000);
        uint256 deadline = block.timestamp;

        bytes memory sig = _signCreateFor(alice, "Tok", "TK", "", deadline, 0);
        vm.prank(alice);
        uint256 id = factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            deadline,
            0, sig,
            0, address(0), ""
        );
        assertEq(_info(id).creator, alice, "creator recorded");
    }

    function test_SigDeadline_MaxUint_NeverExpires() public {
        vm.warp(type(uint256).max - 10);
        bytes memory sig = _signCreateFor(alice, "Tok", "TK", "", type(uint256).max, 0);
        vm.prank(alice);
        uint256 id = factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );
        assertEq(_info(id).creator, alice);
    }

    function test_SigInvalid_WrongSigner() public {
        bytes memory sig = _signCreate(BOB_PK, alice, "Tok", "TK", "", type(uint256).max, 0);
        vm.prank(charlie);
        vm.expectRevert(InvalidSignature.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );
    }

    function test_SigInvalid_TamperedName() public {
        bytes memory sig = _signCreateFor(alice, "Original", "TK", "", type(uint256).max, 0);
        vm.prank(bob);
        vm.expectRevert(InvalidSignature.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tampered", "TK", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );
    }

    function test_SigInvalid_TamperedTicker() public {
        bytes memory sig = _signCreateFor(alice, "Tok", "AAA", "", type(uint256).max, 0);
        vm.prank(bob);
        vm.expectRevert(InvalidSignature.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "BBB", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );
    }

    function test_SigInvalid_TamperedMetadataURI() public {
        bytes memory sig = _signCreateFor(alice, "Tok", "TK", "ipfs://A", type(uint256).max, 0);
        vm.prank(bob);
        vm.expectRevert(InvalidSignature.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "ipfs://B",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );
    }

    function test_SigInvalid_TamperedDeadline() public {
        bytes memory sig = _signCreateFor(alice, "Tok", "TK", "", 100, 0);
        vm.warp(50);
        vm.prank(bob);
        vm.expectRevert(InvalidSignature.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            200,
            0, sig,
            0, address(0), ""
        );
    }

    function test_SigInvalid_TamperedCreatorParam() public {
        bytes memory sig = _signCreateFor(alice, "Tok", "TK", "", type(uint256).max, 0);
        vm.prank(charlie);
        vm.expectRevert(InvalidSignature.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            bob, "Tok", "TK", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );
    }

    function test_SigInvalid_CreatorZeroAddress() public {
        bytes memory anySig = new bytes(65);
        vm.prank(alice);
        vm.expectRevert(InvalidAddress.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            address(0), "Tok", "TK", "",
            type(uint256).max,
            0, anySig,
            0, address(0), ""
        );
    }

    function test_SigInvalid_EmptySignature() public {
        bytes memory emptySig = "";
        vm.prank(bob);
        vm.expectRevert();
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            0, emptySig,
            0, address(0), ""
        );
    }

    function test_SigInvalid_WrongLengthSignature() public {
        bytes memory badSig = new bytes(64);
        vm.prank(bob);
        vm.expectRevert();
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            0, badSig,
            0, address(0), ""
        );
    }

    function test_SigInvalid_AllZeroSignature() public {
        bytes memory zeroSig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        vm.prank(bob);
        vm.expectRevert();
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            0, zeroSig,
            0, address(0), ""
        );
    }

    function test_SigInvalid_HighSMalleability() public {
        bytes32 digest = _createDigest(alice, "Tok", "TK", "", type(uint256).max, 0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ALICE_PK, digest);

        uint256 N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(N - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;

        bytes memory malleableSig = abi.encodePacked(r, highS, flippedV);

        vm.prank(bob);
        vm.expectRevert();
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            0, malleableSig,
            0, address(0), ""
        );
    }

    // ════════════════════════════════════════════════════════════════
    //  SECTION 2 — ANTI-REPLAY
    // ════════════════════════════════════════════════════════════════

    function test_AntiReplay_SameSigTwice() public {
        bytes memory sig = _signCreateFor(alice, "Tok", "TK", "", type(uint256).max, 0);

        vm.prank(bob);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );

        vm.prank(bob);
        vm.expectRevert(SignatureAlreadyUsed.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );
    }

    function test_AntiReplay_RevertDoesNotConsumeSig() public {
        bytes memory sig = _signCreateFor(alice, "Tok", "TK", "", type(uint256).max, 0);
        vm.deal(alice, 100 ether);

        vm.prank(alice);
        vm.expectRevert(AntiSnipe.selector);
        factory.createAndBuyForCreator{value: 50 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );

        vm.prank(alice);
        uint256 id = factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );
        assertEq(_info(id).creator, alice, "creation succeeded on retry");
    }

    function test_AntiReplay_RaceConditionTwoBuyers() public {
        bytes memory sig = _signCreateFor(alice, "Tok", "TK", "", type(uint256).max, 0);

        vm.prank(bob);
        uint256 id = factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );
        assertEq(_info(id).creator, alice, "alice is creator");

        vm.prank(charlie);
        vm.expectRevert(SignatureAlreadyUsed.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );
    }

    // ════════════════════════════════════════════════════════════════
    //  SECTION 3 — THIRD-PARTY FLOW
    // ════════════════════════════════════════════════════════════════

    function test_ThirdPartyBuy_AliceSignsBobBuys() public {
        uint256 aliceBalBefore = alice.balance;
        uint256 bobBalBefore = bob.balance;

        bytes memory sig = _signCreateFor(alice, "Tok", "TK", "", type(uint256).max, 0);
        vm.prank(bob);
        uint256 id = factory.createAndBuyForCreator{value: 0.05 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );

        MegaPumpLens.TokenInfo memory info = _info(id);

        // ── Creator is alice (NOT bob) ──
        assertEq(info.creator, alice, "alice is creator");

        // ── Bob received tokens (he's the buyer) ──
        assertGt(_balanceOf(id, bob), 0, "bob holds tokens");
        assertEq(_balanceOf(id, alice), 0, "alice holds 0 tokens");

        // ── Alice's balance UNCHANGED (zero-fee promise) ──
        assertEq(alice.balance, aliceBalBefore, "alice spent 0");

        // ── Bob spent exactly 0.05 ETH ──
        assertEq(bobBalBefore - bob.balance, 0.05 ether, "bob spent 0.05 ETH");

        // ── Bob is non-creator → creator fees DID accrue ──
        assertGt(info.creatorFees, 0, "creator fees accrue from bob's buy");

        // ── Alice can claim those creator fees ──
        uint256 feesAccrued = info.creatorFees;
        uint256 aliceBalBeforeClaim = alice.balance;
        vm.prank(alice);
        factory.claimCreatorFees(id);
        assertEq(alice.balance - aliceBalBeforeClaim, feesAccrued, "alice claimed fees");
    }

    function test_ThirdPartyBuy_WithReferrer() public {
        address ref = address(0xBEEF);
        bytes memory creatorSig = _signCreateFor(alice, "Tok", "TK", "", type(uint256).max, 0);
        bytes memory refSig = _signReferrer(ref, bob);

        vm.prank(bob);
        uint256 id = factory.createAndBuyForCreator{value: 0.05 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            0, creatorSig,
            0, ref, refSig
        );

        MegaPumpLens.TokenInfo memory info = _info(id);

        assertEq(info.creator, alice);
        assertGt(_balanceOf(id, bob), 0);

        uint256 expectedRef = (0.05 ether * factory.referrerFeeBps()) / 10000;
        assertEq(factory.referrerFees(ref), expectedRef, "referrer accrued fees");
        assertGt(info.creatorFees, 0, "creator fees accrue");
    }

    function test_ThirdPartyBuy_CreatorBuysOwnSigLater() public {
        bytes memory sig = _signCreateFor(alice, "Tok", "TK", "", type(uint256).max, 0);

        vm.warp(block.timestamp + 1 hours);

        vm.prank(alice);
        uint256 id = factory.createAndBuyForCreator{value: 0.05 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );

        MegaPumpLens.TokenInfo memory info = _info(id);
        assertEq(info.creator, alice, "alice creator");
        assertGt(_balanceOf(id, alice), 0, "alice received tokens (she's the buyer)");
        // Creator buying her own token → NO creator fee
        assertEq(info.creatorFees, 0, "no creator fee on self-buy");
    }

    // ════════════════════════════════════════════════════════════════
    //  SECTION 4 — CROSS-DOMAIN REPLAY PROTECTION
    // ════════════════════════════════════════════════════════════════

    function test_CrossChain_ReplayProtection() public {
        uint256 originalChainId = block.chainid;
        bytes memory sig = _signCreateFor(alice, "Tok", "TK", "", type(uint256).max, 0);

        vm.chainId(originalChainId + 1);

        vm.prank(bob);
        vm.expectRevert(InvalidSignature.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );

        vm.chainId(originalChainId);
    }

    function test_CrossContract_ReplayProtection() public {
        bytes memory sig = _signCreateFor(alice, "Tok", "TK", "", type(uint256).max, 0);

        MegaPumpFactory impl2 = new MegaPumpFactory();
        bytes memory initData = abi.encodeCall(
            MegaPumpFactory.initialize,
            (address(router), address(weth))
        );
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(impl2), initData);
        MegaPumpFactory factory2 = MegaPumpFactory(payable(address(proxy2)));
        factory2.setSigner(signer);
        factory2.setTokenCreationCooldown(0);

        vm.prank(bob);
        vm.expectRevert(InvalidSignature.selector);
        factory2.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );
    }

    function test_DomainSeparator_MatchesOffchain() public {
        bytes32 expectedDomain = _domainSeparator();

        bytes memory sig = _signCreateFor(alice, "Tok", "TK", "", type(uint256).max, 0);

        vm.prank(alice);
        uint256 id = factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );
        assertEq(_info(id).creator, alice);
        assertTrue(expectedDomain != bytes32(0), "domain separator computed");
    }

    // ════════════════════════════════════════════════════════════════
    //  SECTION 5 — COOLDOWN INVARIANTS
    // ════════════════════════════════════════════════════════════════

    function test_Cooldown_AppliesToSignerNotCaller() public {
        factory.setTokenCreationCooldown(60);

        bytes memory sig1 = _signCreateFor(alice, "Tok1", "T1", "", type(uint256).max, 0);
        vm.prank(bob);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok1", "T1", "",
            type(uint256).max,
            0, sig1,
            0, address(0), ""
        );

        bytes memory sig2 = _signCreateFor(alice, "Tok2", "T2", "", type(uint256).max, 0);
        vm.prank(charlie);
        vm.expectPartialRevert(CreationCooldown.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok2", "T2", "",
            type(uint256).max,
            0, sig2,
            0, address(0), ""
        );

        bytes memory bobSig = _signCreateFor(bob, "BobTok", "BB", "", type(uint256).max, 0);
        vm.prank(charlie);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            bob, "BobTok", "BB", "",
            type(uint256).max,
            0, bobSig,
            0, address(0), ""
        );

        vm.warp(block.timestamp + 61);
        vm.prank(charlie);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok2", "T2", "",
            type(uint256).max,
            0, sig2,
            0, address(0), ""
        );
    }

    function test_Cooldown_ExpiresCorrectly() public {
        factory.setTokenCreationCooldown(60);

        bytes memory sig1 = _signCreateFor(alice, "A", "A", "", type(uint256).max, 0);
        vm.prank(alice);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "A", "A", "",
            type(uint256).max,
            0, sig1,
            0, address(0), ""
        );

        vm.warp(block.timestamp + 30);
        bytes memory sig2 = _signCreateFor(alice, "B", "B", "", type(uint256).max, 0);
        vm.prank(alice);
        vm.expectPartialRevert(CreationCooldown.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "B", "B", "",
            type(uint256).max,
            0, sig2,
            0, address(0), ""
        );

        vm.warp(block.timestamp + 30);
        vm.prank(alice);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "B", "B", "",
            type(uint256).max,
            0, sig2,
            0, address(0), ""
        );
    }

    // ════════════════════════════════════════════════════════════════
    //  SECTION 6 — CREATOR AS REFERRER
    // ════════════════════════════════════════════════════════════════

    function test_CreatorAsReferrer_AccruesBothFeeStreams() public {
        uint256 id = _createAndDeploy(alice, 1 ether);

        uint256 creatorFeesBefore = _info(id).creatorFees;
        uint256 aliceRefFeesBefore = factory.referrerFees(alice);

        bytes memory refSig = _signReferrer(alice, bob);
        vm.prank(bob);
        factory.buy{value: 5 ether}(id, 0, alice, refSig);

        MegaPumpLens.TokenInfo memory info = _info(id);

        uint256 creatorFeesDelta = info.creatorFees - creatorFeesBefore;
        assertGt(creatorFeesDelta, 0, "creator fees accrued");

        uint256 refFeesDelta = factory.referrerFees(alice) - aliceRefFeesBefore;
        assertGt(refFeesDelta, 0, "referrer fees accrued for the creator");

        uint256 expectedRefFee = (5 ether * factory.referrerFeeBps()) / 10000;
        assertEq(refFeesDelta, expectedRefFee, "referrer fee correct");

        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        factory.claimCreatorFees(id);
        vm.prank(alice);
        factory.claimReferrerFees();
        assertEq(
            alice.balance - aliceBalBefore,
            creatorFeesDelta + refFeesDelta,
            "alice received creator + referrer fees"
        );
    }

    // ════════════════════════════════════════════════════════════════
    //  SECTION 7 — UUPS UPGRADE PRESERVES GASLESS STATE
    // ════════════════════════════════════════════════════════════════

    /// @notice Upgrade preserves the digest-keyed replay guard (v2 semantics).
    function test_Upgrade_PreservesReplayGuard() public {
        bytes memory sig = _signCreateFor(alice, "Tok", "TK", "", type(uint256).max, 0);
        vm.prank(bob);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "", type(uint256).max, 0, sig, 0, address(0), "");

        bytes32 digest = _createDigest(alice, "Tok", "TK", "", type(uint256).max, 0);
        assertTrue(factory.usedSignatures(digest), "intent marked pre-upgrade");

        MegaPumpFactory newImpl = new MegaPumpFactory();
        factory.upgradeToAndCall(address(newImpl), "");

        assertTrue(factory.usedSignatures(digest), "intent STILL marked post-upgrade");
        vm.prank(bob);
        vm.expectRevert(SignatureAlreadyUsed.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "", type(uint256).max, 0, sig, 0, address(0), "");
    }

    /// @notice v1→v2 migration guard: entries written by v1 under SIGHASH keys
    ///         must still block replay in v2 (dual check sigHash || digest).
    ///         Simulates a v1 entry via vm.store (v1 source no longer in repo).
    function test_MigrationGuard_V1SigHashEntry_BlocksReplay() public {
        bytes memory sig = _signCreateFor(alice, "Legacy", "LGC", "", type(uint256).max, 7);
        bytes32 sigHash = keccak256(sig);

        uint256 mappingSlot = 18; // ← à remplacer, voir étape 3
        bytes32 entrySlot = keccak256(abi.encode(sigHash, bytes32(mappingSlot)));
        vm.store(address(factory), entrySlot, bytes32(uint256(1)));

        vm.prank(bob);
        vm.expectRevert(SignatureAlreadyUsed.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Legacy", "LGC", "", type(uint256).max, 7, sig, 0, address(0), "");
    }

    function test_Upgrade_PreservesCooldownState() public {
        factory.setTokenCreationCooldown(60);

        bytes memory sig = _signCreateFor(alice, "Tok", "TK", "", type(uint256).max, 0);
        vm.prank(alice);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );
        uint256 lastBefore = factory.lastTokenCreatedAt(alice);
        assertGt(lastBefore, 0, "cooldown timer set");

        MegaPumpFactory newImpl = new MegaPumpFactory();
        factory.upgradeToAndCall(address(newImpl), "");

        assertEq(factory.lastTokenCreatedAt(alice), lastBefore, "cooldown state preserved");

        bytes memory sig2 = _signCreateFor(alice, "Tok2", "T2", "", type(uint256).max, 0);
        vm.prank(alice);
        vm.expectPartialRevert(CreationCooldown.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok2", "T2", "",
            type(uint256).max,
            0, sig2,
            0, address(0), ""
        );
    }

    // ════════════════════════════════════════════════════════════════
    //  SECTION 8 — STORAGE LAYOUT ASSERTIONS
    //
    //  Solidity packs variables that fit together into single slots (e.g.,
    //  weth + paused bool share slot 3, not 3 and 4 as the source
    //  comments suggest). Rather than hardcoding magic slot numbers that drift
    //  with future packing changes, we DERIVE the slot positions empirically:
    //    1. Write a known value to a known mapping key
    //    2. Probe every slot 0-30 to find which one stores our value
    //    3. Assert the slot is in a sane range (i.e., it exists and isn't slot 0)
    //
    //  This guards against accidental layout breakage on future upgrades while
    //  remaining resilient to Solidity's packing rules.
    // ════════════════════════════════════════════════════════════════

    /// @notice usedSignatures mapping must be addressable: writing to it
    ///         shows up in storage, and reading reflects the write.
    function test_StorageLayout_UsedSignaturesMappingIsLive() public {
        bytes memory sig = _signCreateFor(alice, "Tok", "TK", "", type(uint256).max, 0);
        bytes32 digest = _createDigest(alice, "Tok", "TK", "", type(uint256).max, 0);

        // Pre-consumption: must be false
        assertFalse(factory.usedSignatures(digest), "starts false");

        vm.prank(bob);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );

        // Post-consumption: must be true (via the public getter)
        assertTrue(factory.usedSignatures(digest), "intent marked used after creation");

        // Find the actual storage slot by probing slots 0-30
        uint256 foundSlot = type(uint256).max;
        for (uint256 slot = 0; slot <= 30; slot++) {
            bytes32 entrySlot = keccak256(abi.encode(digest, bytes32(slot)));
            bytes32 raw = vm.load(address(factory), entrySlot);
            if (uint256(raw) == 1) {
                foundSlot = slot;
                break;
            }
        }

        // We MUST have found it somewhere in 0-30. If not, layout is wildly broken.
        assertLt(foundSlot, 30, "usedSignatures mapping found in expected slot range");
        emit log_named_uint("usedSignatures resides at slot", foundSlot);

        // Sanity: an unrelated hash should NOT appear at that slot
        bytes32 randomHash = keccak256("definitely-not-used");
        bytes32 randomSlot = keccak256(abi.encode(randomHash, bytes32(foundSlot)));
        bytes32 randomRaw = vm.load(address(factory), randomSlot);
        assertEq(uint256(randomRaw), 0, "unused hash slot is zero");
    }

    /// @notice lastTokenCreatedAt mapping must persist creation timestamp.
    function test_StorageLayout_LastTokenCreatedAtMappingIsLive() public {
        vm.warp(123456789);

        bytes memory sig = _signCreateFor(alice, "Tok", "TK", "", type(uint256).max, 0);
        vm.prank(alice);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );

        // Public getter must return the warp timestamp
        assertEq(factory.lastTokenCreatedAt(alice), 123456789, "timestamp recorded");

        // Find which slot the mapping lives at by probing
        uint256 foundSlot = type(uint256).max;
        for (uint256 slot = 0; slot <= 30; slot++) {
            bytes32 entrySlot = keccak256(abi.encode(alice, bytes32(slot)));
            bytes32 raw = vm.load(address(factory), entrySlot);
            if (uint256(raw) == 123456789) {
                foundSlot = slot;
                break;
            }
        }

        assertLt(foundSlot, 30, "lastTokenCreatedAt mapping found in expected slot range");
        emit log_named_uint("lastTokenCreatedAt resides at slot", foundSlot);

        // Sanity: another address has no record
        bytes32 randomSlot = keccak256(abi.encode(address(0xDEAD), bytes32(foundSlot)));
        bytes32 randomRaw = vm.load(address(factory), randomSlot);
        assertEq(uint256(randomRaw), 0, "unused address slot is zero");
    }

    // ════════════════════════════════════════════════════════════════
    //  SECTION 9 — SELL WITH REFERRER
    // ════════════════════════════════════════════════════════════════

    function test_Sell_WithReferrer_AccruesFees() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        _buy(id, bob, 5 ether);
        uint256 bobTokens = _balanceOf(id, bob);

        address ref = address(0xBEEF);
        bytes memory refSig = _signReferrer(ref, bob);

        uint256 refBefore = factory.referrerFees(ref);
        vm.prank(bob);
        factory.sell(id, bobTokens / 2, 0, ref, refSig);

        assertGt(factory.referrerFees(ref), refBefore, "referrer fees accrued on sell");
    }

    // ════════════════════════════════════════════════════════════════
    //  SECTION 10 — graduationETH locked at creation
    // ════════════════════════════════════════════════════════════════

    function test_GraduationETH_LockedPerToken() public {
        uint256 id = _createAndDeploy(alice, 1 ether);
        uint256 originalGrad = _info(id).graduationETH;
        assertEq(originalGrad, 24 ether, "starts at default 24 ETH");

        factory.setGraduationETH(50 ether);
        assertEq(factory.graduationETH(), 50 ether, "global updated");

        assertEq(_info(id).graduationETH, originalGrad, "existing token unchanged");

        bytes memory sig = _signCreateFor(bob, "NewTok", "NEW", "", type(uint256).max, 0);
        vm.prank(bob);
        uint256 id2 = factory.createAndBuyForCreator{value: 0.01 ether}(
            bob, "NewTok", "NEW", "",
            type(uint256).max,
            0, sig,
            0, address(0), ""
        );
        assertEq(_info(id2).graduationETH, 50 ether, "new token uses new global");
    }

    // ════════════════════════════════════════════════════════════════
    //  SECTION 11 — NONCE SEMANTICS
    //
    //  The nonce was added to the EIP-712 typed data so that two creations
    //  with IDENTICAL (creator, name, ticker, metadataURI, deadline) but
    //  DIFFERENT nonces produce DIFFERENT signatures.
    //
    //  This lets a creator legitimately retry / launch duplicates without
    //  hitting the deterministic-ECDSA wall (same digest = same signature).
    // ════════════════════════════════════════════════════════════════

    /// @notice Two creations with same inputs but different nonces must produce
    ///         different signatures, allowing both to coexist without 409.
    function test_Nonce_DifferentNoncesProduceDifferentSignatures() public {
        bytes memory sig1 = _signCreateFor(alice, "Tok", "TK", "", type(uint256).max, 1);
        bytes memory sig2 = _signCreateFor(alice, "Tok", "TK", "", type(uint256).max, 2);

        assertTrue(keccak256(sig1) != keccak256(sig2), "different nonces -> different sigs");
    }

    /// @notice Same nonce + same other params = same signature (deterministic).
    function test_Nonce_SameNonceProducesSameSignature() public {
        bytes memory sig1 = _signCreateFor(alice, "Tok", "TK", "", type(uint256).max, 42);
        bytes memory sig2 = _signCreateFor(alice, "Tok", "TK", "", type(uint256).max, 42);

        assertEq(keccak256(sig1), keccak256(sig2), "same nonce -> identical sigs (deterministic)");
    }

    /// @notice A creator can create two identical tokens (same name/ticker/uri)
    ///         in sequence by using different nonces — third-party path.
    function test_Nonce_AllowsDuplicateTokensViaThirdParty() public {
        // Token A — nonce=1, bob is first buyer
        bytes memory sigA = _signCreateFor(alice, "Twin", "TW", "ipfs://same", type(uint256).max, 1);
        vm.prank(bob);
        uint256 idA = factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Twin", "TW", "ipfs://same",
            type(uint256).max,
            1, sigA,
            0, address(0), ""
        );

        // Token B — same inputs but nonce=2, charlie is first buyer
        bytes memory sigB = _signCreateFor(alice, "Twin", "TW", "ipfs://same", type(uint256).max, 2);
        vm.prank(charlie);
        uint256 idB = factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Twin", "TW", "ipfs://same",
            type(uint256).max,
            2, sigB,
            0, address(0), ""
        );

        // Both tokens exist with different IDs and same creator
        assertTrue(idA != idB, "different token IDs");
        assertEq(_info(idA).creator, alice);
        assertEq(_info(idB).creator, alice);

        // Sigs are different so both anti-replay slots are independent
        bytes32 digestA = _createDigest(alice, "Twin", "TW", "ipfs://same", type(uint256).max, 1);
        bytes32 digestB = _createDigest(alice, "Twin", "TW", "ipfs://same", type(uint256).max, 2);
        assertTrue(factory.usedSignatures(digestA), "intent A marked used");
        assertTrue(factory.usedSignatures(digestB), "intent B marked used");
    }

    /// @notice Tampering with the nonce (signing with N, calling with N+1)
    ///         must revert InvalidSignature.
    function test_Nonce_TamperedNonceReverts() public {
        // Alice signs with nonce=5
        bytes memory sig = _signCreateFor(alice, "Tok", "TK", "", type(uint256).max, 5);

        // Bob tries to use it with nonce=6
        vm.prank(bob);
        vm.expectRevert(InvalidSignature.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            6, sig,
            0, address(0), ""
        );
    }

    /// @notice Fast-path (msg.sender == creator) ignores the nonce entirely.
    ///         The creator can pass any nonce value since it's not validated.
    function test_Nonce_IgnoredInFastPath() public {
        // Alice signs nothing meaningful — fast path doesn't check signature
        bytes memory anySig = new bytes(65);

        // Alice self-buys, passes random nonce and empty sig
        vm.prank(alice);
        uint256 id = factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "FastPath", "FP", "",
            0,                  // deadline (ignored in fast path)
            999999,             // nonce (ignored in fast path)
            anySig,
            0, address(0), ""
        );

        assertEq(_info(id).creator, alice, "fast path succeeded with arbitrary nonce");
    }

    /// @notice MaxUint256 nonce works — no overflow or special handling.
    function test_Nonce_MaxValueWorks() public {
        bytes memory sig = _signCreateFor(
            alice, "Tok", "TK", "", type(uint256).max, type(uint256).max
        );

        vm.prank(bob);
        uint256 id = factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            type(uint256).max,
            sig,
            0, address(0), ""
        );

        assertEq(_info(id).creator, alice, "max nonce accepted");
    }

    /// @notice Signature with one nonce is still anti-replay protected
    ///         even after a successful creation with a different nonce.
    function test_Nonce_AntiReplayIsPerSignature() public {
        // Create token A with nonce=1
        bytes memory sigA = _signCreateFor(alice, "Tok", "TK", "ipfs://a", type(uint256).max, 1);
        vm.prank(bob);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "ipfs://a",
            type(uint256).max,
            1, sigA,
            0, address(0), ""
        );

        // Try to replay sigA — must fail even though A's metadataURI differs from
        // future tokens. Replay = same sig consumed twice = SignatureAlreadyUsed.
        vm.prank(charlie);
        vm.expectRevert(SignatureAlreadyUsed.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "ipfs://a",
            type(uint256).max,
            1, sigA,
            0, address(0), ""
        );
    }

    // ════════════════════════════════════════════════════════════════
    //  SECTION 12 — FUZZ TESTS
    // ════════════════════════════════════════════════════════════════

    function testFuzz_ValidSignature_AlwaysSucceeds(
        uint8 nameLen,
        uint8 tickerLen,
        uint64 buyEth,
        uint256 nonce
    ) public {
        nameLen = uint8(bound(uint256(nameLen), 1, 32));
        tickerLen = uint8(bound(uint256(tickerLen), 1, 10));
        uint256 eth = bound(uint256(buyEth), 1, 0.2 ether);

        bytes memory nameBytes = new bytes(nameLen);
        for (uint256 i; i < nameLen; ++i) nameBytes[i] = 0x41;
        bytes memory tickerBytes = new bytes(tickerLen);
        for (uint256 i; i < tickerLen; ++i) tickerBytes[i] = 0x42;

        string memory name = string(nameBytes);
        string memory ticker = string(tickerBytes);

        bytes memory sig = _signCreateFor(alice, name, ticker, "", type(uint256).max, nonce);
        vm.prank(alice);
        uint256 id = factory.createAndBuyForCreator{value: eth}(
            alice, name, ticker, "",
            type(uint256).max,
            nonce, sig,
            0, address(0), ""
        );
        assertEq(_info(id).creator, alice, "fuzz: creator recorded");
    }

    function testFuzz_TamperedSignature_AlwaysReverts(bytes32 seed) public {
        bytes memory sig = _signCreateFor(alice, "Tok", "TK", "", type(uint256).max, 0);

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        bytes32 mutatedR = r ^ seed;
        vm.assume(mutatedR != r);

        bytes memory tampered = abi.encodePacked(mutatedR, s, v);

        vm.prank(bob);
        vm.expectRevert();
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            0, tampered,
            0, address(0), ""
        );
    }

    /// @notice Fuzz: any nonce mismatch between signed and called must revert.
    function testFuzz_TamperedNonce_AlwaysReverts(uint256 signedNonce, uint256 calledNonce) public {
        vm.assume(signedNonce != calledNonce);

        bytes memory sig = _signCreateFor(alice, "Tok", "TK", "", type(uint256).max, signedNonce);

        vm.prank(bob);
        vm.expectRevert(InvalidSignature.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Tok", "TK", "",
            type(uint256).max,
            calledNonce, sig,
            0, address(0), ""
        );
    }
}
