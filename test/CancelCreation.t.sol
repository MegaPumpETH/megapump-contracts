// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Helpers.sol";
import {MockQuoteToken} from "./mocks/QuoteMocks.sol";

/// cancelCreation: a creator withdraws a signed creation intent before anyone
/// deploys it (a pending token cancelled on the site stays cancelled on-chain).
contract CancelCreationTest is Helpers {
    string constant NAME = "Cancel Me";
    string constant TICKER = "CNCL";
    string constant URI = "ipfs://cancel";
    uint256 constant DEADLINE = type(uint256).max;
    uint256 constant NONCE = 7;

    event CreationCancelled(address indexed creator, bytes32 indexed digest);

    function _deployWithSig(address caller, bytes memory sig) internal returns (uint256) {
        vm.prank(caller);
        return factory.createAndBuyForCreator{value: 0.01 ether}(alice, NAME, TICKER, URI, DEADLINE, NONCE, sig, 0, address(0), "");
    }

    function test_Cancel_BlocksThirdPartyDeploy() public {
        bytes memory sig = _signCreateFor(alice, NAME, TICKER, URI, DEADLINE, NONCE);
        bytes32 digest = _createDigest(alice, NAME, TICKER, URI, DEADLINE, NONCE);
        vm.expectEmit(true, true, false, false, address(factory));
        emit CreationCancelled(alice, digest);
        vm.prank(alice);
        factory.cancelCreation(NAME, TICKER, URI, address(0), DEADLINE, NONCE);
        assertTrue(factory.usedSignatures(digest));
        vm.expectRevert(SignatureAlreadyUsed.selector);
        _deployWithSig(bob, sig);
    }

    function test_Cancel_BlocksTheCreatorsOwnSignatureToo() public {
        bytes memory sig = _signCreateFor(alice, NAME, TICKER, URI, DEADLINE, NONCE);
        vm.prank(alice);
        factory.cancelCreation(NAME, TICKER, URI, address(0), DEADLINE, NONCE);
        vm.expectRevert(SignatureAlreadyUsed.selector);
        _deployWithSig(alice, sig);
    }

    function test_Cancel_Twice_Reverts() public {
        vm.startPrank(alice);
        factory.cancelCreation(NAME, TICKER, URI, address(0), DEADLINE, NONCE);
        vm.expectRevert(SignatureAlreadyUsed.selector);
        factory.cancelCreation(NAME, TICKER, URI, address(0), DEADLINE, NONCE);
        vm.stopPrank();
    }

    function test_Cancel_ByAnotherWallet_DoesNotTouchTheCreatorsIntent() public {
        bytes memory sig = _signCreateFor(alice, NAME, TICKER, URI, DEADLINE, NONCE);
        vm.prank(bob);
        factory.cancelCreation(NAME, TICKER, URI, address(0), DEADLINE, NONCE); // bob's own digest
        uint256 id = _deployWithSig(charlie, sig);
        (address creator, , , , , , , , , , , , , , ) = factory.tokenData(id);
        assertEq(creator, alice, "alice's intent still deploys, as alice");
    }

    function test_Cancel_AfterDeploy_Reverts() public {
        bytes memory sig = _signCreateFor(alice, NAME, TICKER, URI, DEADLINE, NONCE);
        _deployWithSig(bob, sig);
        vm.prank(alice);
        vm.expectRevert(SignatureAlreadyUsed.selector);
        factory.cancelCreation(NAME, TICKER, URI, address(0), DEADLINE, NONCE);
    }

    function test_Cancel_WorksWhilePaused() public {
        bytes memory sig = _signCreateFor(alice, NAME, TICKER, URI, DEADLINE, NONCE);
        factory.setPaused(true);
        vm.prank(alice);
        factory.cancelCreation(NAME, TICKER, URI, address(0), DEADLINE, NONCE);
        factory.setPaused(false);
        vm.expectRevert(SignatureAlreadyUsed.selector);
        _deployWithSig(bob, sig);
    }

    function test_Cancel_QuoteIntent() public {
        MockQuoteToken usdm = new MockQuoteToken("USDm", "USDM", 18);
        factory.setQuote(address(usdm), true, 13_400e18, 40e18);
        bytes32 structHash = keccak256(abi.encode(
            factory.CREATE_QUOTE_TYPEHASH(), alice,
            keccak256(bytes(NAME)), keccak256(bytes(TICKER)), keccak256(bytes(URI)),
            address(usdm), DEADLINE, NONCE));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ALICE_PK, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        // Cancelling the ETH variant leaves the quote intent untouched...
        vm.prank(alice);
        factory.cancelCreation(NAME, TICKER, URI, address(0), DEADLINE, NONCE);
        assertFalse(factory.usedSignatures(digest));
        // ...cancelling with the quote closes it.
        vm.prank(alice);
        factory.cancelCreation(NAME, TICKER, URI, address(usdm), DEADLINE, NONCE);
        assertTrue(factory.usedSignatures(digest));

        usdm.mint(bob, 1_000e18);
        vm.startPrank(bob);
        usdm.approve(address(factory), type(uint256).max);
        vm.expectRevert(SignatureAlreadyUsed.selector);
        factory.createAndBuyWithQuote(alice, NAME, TICKER, URI, address(usdm), DEADLINE, NONCE, sig, 100e18, 0, address(0), "");
        vm.stopPrank();
    }
}
