// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Helpers.sol";
import "./mocks/QuoteMocks.sol";

/// @notice Review M1 (27/09): a signature passed on the self-create path
///         (msg.sender == creator) is now consumed.
///
///         Before, the fast path ignored it entirely. A creator deploying their
///         own pending token (gasless creation, signature public in the API and
///         in the calldata) left that signature valid: once the cooldown was
///         over, anyone could replay it and deploy a clone (same name, ticker,
///         metadata, same creator). And if a third party deployed the pending
///         token first, the creator's own tx still went through and deployed a
///         second one.
///
///         Self-create WITHOUT a signature (the front's create + buy) is
///         unchanged: nothing to consume.
contract SelfCreateSignatureTest is Helpers {
    MockQuoteToken internal usdm;

    string  internal constant NAME     = "Pending";
    string  internal constant TICKER   = "PEND";
    string  internal constant URI      = "ipfs://pending";
    uint256 internal constant NONCE    = 42;
    uint256 internal constant DEADLINE = type(uint256).max;

    function setUp() public override {
        super.setUp();
        usdm = new MockQuoteToken("MegaUSD", "USDm", 18);
        factory.setQuote(address(usdm), true, 20_000e18, 50e18);

        address[3] memory actors = [alice, bob, charlie];
        for (uint256 i; i < actors.length; i++) {
            usdm.mint(actors[i], 1_000_000e18);
            vm.prank(actors[i]);
            usdm.approve(address(factory), type(uint256).max);
        }
    }

    // ════════════════════════════════════════════════════════════
    //  Helpers
    // ════════════════════════════════════════════════════════════

    function _quoteDigest(address creator, uint256 deadline, uint256 nonce) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            factory.CREATE_QUOTE_TYPEHASH(),
            creator,
            keccak256(bytes(NAME)),
            keccak256(bytes(TICKER)),
            keccak256(bytes(URI)),
            address(usdm),
            deadline,
            nonce
        ));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _signQuote(address creator, uint256 deadline, uint256 nonce) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_pkOf(creator), _quoteDigest(creator, deadline, nonce));
        return abi.encodePacked(r, s, v);
    }

    /// @dev `caller` deploys alice's token quoted in ETH, with `sig` (or none).
    function _deployEth(address caller, bytes memory sig, uint256 deadline, uint256 nonce)
        internal returns (uint256)
    {
        vm.prank(caller);
        return factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, NAME, TICKER, URI, deadline, nonce, sig, 0, address(0), ""
        );
    }

    /// @dev Same, quoted in USDm.
    function _deployQuote(address caller, bytes memory sig, uint256 deadline, uint256 nonce)
        internal returns (uint256)
    {
        vm.prank(caller);
        return factory.createAndBuyWithQuote(
            alice, NAME, TICKER, URI, address(usdm), deadline, nonce, sig, 50e18, 0, address(0), ""
        );
    }

    /// @dev Past alice's creation cooldown: it must not be what stops a clone.
    function _afterCooldown() internal {
        vm.warp(block.timestamp + factory.tokenCreationCooldown() + 1);
    }

    // ════════════════════════════════════════════════════════════
    //  The replay: creator deploys their pending token, then a third party
    // ════════════════════════════════════════════════════════════

    function test_SelfCreate_ConsumesSignature_ReplayReverts() public {
        bytes memory sig = _signCreateFor(alice, NAME, TICKER, URI, DEADLINE, NONCE);

        uint256 id = _deployEth(alice, sig, DEADLINE, NONCE);
        assertEq(_info(id).creator, alice);
        assertTrue(
            factory.usedSignatures(_createDigest(alice, NAME, TICKER, URI, DEADLINE, NONCE)),
            "intent consumed on the self-create path"
        );

        _afterCooldown();
        vm.expectRevert(SignatureAlreadyUsed.selector);
        _deployEth(bob, sig, DEADLINE, NONCE);
        assertEq(factory.tokenCount(), 1, "no clone");
    }

    function test_SelfCreate_ConsumesSignature_ReplayReverts_Quote() public {
        bytes memory sig = _signQuote(alice, DEADLINE, NONCE);

        uint256 id = _deployQuote(alice, sig, DEADLINE, NONCE);
        assertEq(_info(id).creator, alice);
        assertEq(_info(id).quote, address(usdm));
        assertTrue(factory.usedSignatures(_quoteDigest(alice, DEADLINE, NONCE)), "intent consumed");

        _afterCooldown();
        vm.expectRevert(SignatureAlreadyUsed.selector);
        _deployQuote(bob, sig, DEADLINE, NONCE);
        assertEq(factory.tokenCount(), 1, "no clone");
    }

    // ════════════════════════════════════════════════════════════
    //  The race: a third party deploys first, the creator's tx lands after
    // ════════════════════════════════════════════════════════════

    function test_Race_ThirdPartyFirst_CreatorTxReverts() public {
        bytes memory sig = _signCreateFor(alice, NAME, TICKER, URI, DEADLINE, NONCE);
        _deployEth(bob, sig, DEADLINE, NONCE);

        _afterCooldown();
        vm.expectRevert(SignatureAlreadyUsed.selector);
        _deployEth(alice, sig, DEADLINE, NONCE);
        assertEq(factory.tokenCount(), 1, "the pending token deploys once");
    }

    function test_Race_ThirdPartyFirst_CreatorTxReverts_Quote() public {
        bytes memory sig = _signQuote(alice, DEADLINE, NONCE);
        _deployQuote(bob, sig, DEADLINE, NONCE);

        _afterCooldown();
        vm.expectRevert(SignatureAlreadyUsed.selector);
        _deployQuote(alice, sig, DEADLINE, NONCE);
        assertEq(factory.tokenCount(), 1, "the pending token deploys once");
    }

    // ════════════════════════════════════════════════════════════
    //  Unchanged: self-create without a signature (front: create + buy)
    // ════════════════════════════════════════════════════════════

    function test_SelfCreate_EmptySignature_NothingConsumed() public {
        uint256 a = _deployEth(alice, "", 0, 0);
        _afterCooldown();
        uint256 b = _deployEth(alice, "", 0, 0);

        assertTrue(a != b, "same fields, two launches");
        assertEq(_info(b).creator, alice);
        assertFalse(factory.usedSignatures(_createDigest(alice, NAME, TICKER, URI, 0, 0)));
    }

    function test_SelfCreate_EmptySignature_NothingConsumed_Quote() public {
        uint256 a = _deployQuote(alice, "", 0, 0);
        _afterCooldown();
        uint256 b = _deployQuote(alice, "", 0, 0);

        assertTrue(a != b, "same fields, two launches");
        assertEq(_info(b).quote, address(usdm));
        assertFalse(factory.usedSignatures(_quoteDigest(alice, 0, 0)));
    }

    // ════════════════════════════════════════════════════════════
    //  Self path: the creator's tx is the authorization
    // ════════════════════════════════════════════════════════════

    /// @notice An expired pending signature doesn't block its own creator (as
    ///         before), and is consumed all the same.
    function test_SelfCreate_ExpiredSignature_Works_AndIsConsumed() public {
        uint256 deadline = block.timestamp + 1;
        bytes memory sig = _signCreateFor(alice, NAME, TICKER, URI, deadline, NONCE);
        vm.warp(deadline + 1);

        uint256 id = _deployEth(alice, sig, deadline, NONCE);
        assertEq(_info(id).creator, alice);
        assertTrue(factory.usedSignatures(_createDigest(alice, NAME, TICKER, URI, deadline, NONCE)));
    }

    /// @notice The self path doesn't verify the signature, but the consumed
    ///         digest binds msg.sender as creator: copying alice's pending
    ///         fields and signature into his own self-create, bob only closes
    ///         his own intent. Alice's pending token stays deployable.
    function test_SelfCreate_CannotBurnSomeoneElsesIntent() public {
        bytes memory sig = _signCreateFor(alice, NAME, TICKER, URI, DEADLINE, NONCE);

        vm.prank(bob);
        uint256 bobs = factory.createAndBuyForCreator{value: 0.01 ether}(
            bob, NAME, TICKER, URI, DEADLINE, NONCE, sig, 0, address(0), ""
        );
        assertEq(_info(bobs).creator, bob);
        assertTrue(factory.usedSignatures(_createDigest(bob, NAME, TICKER, URI, DEADLINE, NONCE)));
        assertFalse(
            factory.usedSignatures(_createDigest(alice, NAME, TICKER, URI, DEADLINE, NONCE)),
            "alice's intent untouched"
        );

        uint256 alices = _deployEth(charlie, sig, DEADLINE, NONCE);
        assertEq(_info(alices).creator, alice, "charlie still deploys alice's pending token");
    }

    /// @notice Same with the quote typehash: bob can't close alice's intent.
    function test_SelfCreate_CannotBurnSomeoneElsesIntent_Quote() public {
        bytes memory sig = _signQuote(alice, DEADLINE, NONCE);

        vm.prank(bob);
        factory.createAndBuyWithQuote(
            bob, NAME, TICKER, URI, address(usdm), DEADLINE, NONCE, sig, 50e18, 0, address(0), ""
        );
        assertFalse(factory.usedSignatures(_quoteDigest(alice, DEADLINE, NONCE)), "alice's intent untouched");

        uint256 alices = _deployQuote(charlie, sig, DEADLINE, NONCE);
        assertEq(_info(alices).creator, alice);
    }

    /// @notice A reverted self-create (anti-snipe here) rolls the consumption
    ///         back: the creator retries with the same signature.
    function test_SelfCreate_RevertRollsBackConsumption_Quote() public {
        bytes memory sig = _signQuote(alice, DEADLINE, NONCE);

        vm.expectRevert(AntiSnipe.selector);
        vm.prank(alice);
        factory.createAndBuyWithQuote(
            alice, NAME, TICKER, URI, address(usdm), DEADLINE, NONCE, sig, 1_000e18, 0, address(0), ""
        );
        assertFalse(factory.usedSignatures(_quoteDigest(alice, DEADLINE, NONCE)));

        uint256 id = _deployQuote(alice, sig, DEADLINE, NONCE);
        assertEq(_info(id).creator, alice, "retry succeeds");
    }

    // ════════════════════════════════════════════════════════════
    //  Fuzz: whoever goes first, a pending intent deploys once
    // ════════════════════════════════════════════════════════════

    function testFuzz_PendingIntent_DeploysOnce(uint256 nonce, bool creatorFirst, bool quoted) public {
        bytes memory sig = quoted
            ? _signQuote(alice, DEADLINE, nonce)
            : _signCreateFor(alice, NAME, TICKER, URI, DEADLINE, nonce);
        address first  = creatorFirst ? alice : bob;
        address second = creatorFirst ? bob : alice;

        if (quoted) _deployQuote(first, sig, DEADLINE, nonce);
        else _deployEth(first, sig, DEADLINE, nonce);

        _afterCooldown();
        vm.expectRevert(SignatureAlreadyUsed.selector);
        if (quoted) _deployQuote(second, sig, DEADLINE, nonce);
        else _deployEth(second, sig, DEADLINE, nonce);

        assertEq(factory.tokenCount(), 1);
    }
}
