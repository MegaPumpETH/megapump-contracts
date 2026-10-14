// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Helpers.sol";
import "./mocks/ERC1271Mocks.sol";

/// @notice ERC-1271 support in createAndBuyForCreator (SignatureChecker upgrade).
///         Covers: smart-account signatures, digest-keyed replay guard (F2),
///         privilege-escalation checks, malicious account behaviors.
///         EOA non-regression lives in GaslessCreation.t.sol — untouched.
contract CreateERC1271Test is Helpers {
    uint256 constant SESSION_PK = 0xA11CE001;
    address sessionKey;
    address buyer = address(0xB0B1);

    Valid1271 mossLike;
    AlwaysValid1271 alwaysValid;
    Reverting1271 reverting;
    Malleable1271 malleable;

    function setUp() public override {
        super.setUp();
        sessionKey  = vm.addr(SESSION_PK);
        mossLike    = new Valid1271(sessionKey);
        alwaysValid = new AlwaysValid1271();
        reverting   = new Reverting1271();
        malleable   = new Malleable1271(sessionKey);
        vm.deal(buyer, 100 ether);
    }


    function _sessionSig(bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SESSION_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    function _createAs(address creator, bytes memory sig, uint256 nonce)
        internal returns (uint256)
    {
        vm.prank(buyer);
        return factory.createAndBuyForCreator{value: 0.1 ether}(
            creator, "Moss Token", "MOSS", "ipfs://moss",
            type(uint256).max, nonce, sig, 0, address(0), ""
        );
    }

    // ════════════════════════════════════════════════════════════
    //  ERC-1271 happy path
    // ════════════════════════════════════════════════════════════

    function test_1271_ValidSig_Creates() public {
        bytes32 d = _createDigest(address(mossLike), "Moss Token", "MOSS", "ipfs://moss", type(uint256).max, 1);
        uint256 id = _createAs(address(mossLike), _sessionSig(d), 1);

        MegaPumpLens.TokenInfo memory info = _info(id);
        assertTrue(info.deployed, "ERC20 deployed");
        assertEq(info.creator, address(mossLike), "smart account is creator");
        assertGt(_balanceOf(id, buyer), 0, "buyer received tokens");
    }

    function test_1271_WrongSessionKey_Reverts() public {
        bytes32 d = _createDigest(address(mossLike), "Moss Token", "MOSS", "ipfs://moss", type(uint256).max, 2);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(0xBAD), d);
        vm.prank(buyer);
        vm.expectRevert(InvalidSignature.selector);
        factory.createAndBuyForCreator{value: 0.1 ether}(
            address(mossLike), "Moss Token", "MOSS", "ipfs://moss",
            type(uint256).max, 2, abi.encodePacked(r, s, v), 0, address(0), ""
        );
    }

    // ════════════════════════════════════════════════════════════
    //  F2 — The central test: replay via blocked malleable variant
    // ════════════════════════════════════════════════════════════

    function test_1271_MalleableVariant_SecondCreate_Reverts() public {
        bytes32 d = _createDigest(address(malleable), "Moss Token", "MOSS", "ipfs://moss", type(uint256).max, 3);
        bytes memory realSig  = _sessionSig(d);
        bytes memory variantA = abi.encode(realSig, uint256(111));
        bytes memory variantB = abi.encode(realSig, uint256(222));
        assertTrue(keccak256(variantA) != keccak256(variantB), "distinct byte-strings");

        _createAs(address(malleable), variantA, 3);

        vm.warp(block.timestamp + factory.tokenCreationCooldown() + 1);

        vm.prank(buyer);
        vm.expectRevert(SignatureAlreadyUsed.selector);
        factory.createAndBuyForCreator{value: 0.1 ether}(
            address(malleable), "Moss Token", "MOSS", "ipfs://moss",
            type(uint256).max, 3, variantB, 0, address(0), ""
        );
    }

    // ════════════════════════════════════════════════════════════
    //  Privilege Escalation & Cooldown
    // ════════════════════════════════════════════════════════════

    function test_1271_AlwaysValid_NoPrivilegeEscalation() public {
        uint256 id = _createAs(address(alwaysValid), hex"deadbeef", 4);
        MegaPumpLens.TokenInfo memory info = _info(id);
        assertEq(info.creator, address(alwaysValid), "creator is the account itself, nothing more");
    }

    function test_1271_AlwaysValid_CooldownApplies() public {
        vm.prank(owner); 
        factory.setTokenCreationCooldown(60);  

        _createAs(address(alwaysValid), hex"01", 5);

        vm.prank(buyer);
        vm.expectRevert();  // CreationCooldown(remaining)
        factory.createAndBuyForCreator{value: 0.1 ether}(
            address(alwaysValid), "Second", "SEC", "",
            type(uint256).max, 6, hex"02", 0, address(0), ""
        );
    }

    // ════════════════════════════════════════════════════════════
    //  Malicious accounts
    // ════════════════════════════════════════════════════════════

    function test_1271_RevertingAccount_CleanRevert() public {
        bytes32 d = _createDigest(address(reverting), "Moss Token", "MOSS", "ipfs://moss", type(uint256).max, 7);
        vm.prank(buyer);
        vm.expectRevert(InvalidSignature.selector); 
        factory.createAndBuyForCreator{value: 0.1 ether}(
            address(reverting), "Moss Token", "MOSS", "ipfs://moss",
            type(uint256).max, 7, _sessionSig(d), 0, address(0), ""
        );
    }

    function test_1271_ReturndataBomb_CleanRevert() public {
        ReturndataBomb1271 bomb = new ReturndataBomb1271();
        vm.prank(buyer);
        vm.expectRevert(InvalidSignature.selector);
        factory.createAndBuyForCreator{value: 0.1 ether}(
            address(bomb), "Bomb", "BMB", "",
            type(uint256).max, 8, hex"00", 0, address(0), ""
        );
    }

    // ════════════════════════════════════════════════════════════
    //  Digest guard: two different intentions do not block each other
    // ════════════════════════════════════════════════════════════

    function test_1271_DifferentNonce_DifferentDigest_BothCreate() public {
        bytes32 d1 = _createDigest(address(mossLike), "Moss Token", "MOSS", "ipfs://moss", type(uint256).max, 10);
        _createAs(address(mossLike), _sessionSig(d1), 10);

        vm.warp(block.timestamp + factory.tokenCreationCooldown() + 1);

        bytes32 d2 = _createDigest(address(mossLike), "Moss Token", "MOSS", "ipfs://moss", type(uint256).max, 11);
        uint256 id2 = _createAs(address(mossLike), _sessionSig(d2), 11);
        assertEq(id2, 2, "second intent with new nonce creates fine");
    }
}