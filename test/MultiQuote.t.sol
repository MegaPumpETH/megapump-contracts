// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Helpers.sol";
import "./mocks/QuoteMocks.sol";
import "./mocks/ERC1271Mocks.sol";

/// @notice v3 multi-quote: tokens quoted in an ERC-20 (USDm, MEGA...) next to
///         ETH tokens. The ETH paths are covered by the existing suites, which
///         run unchanged; this file covers what v3 adds and what it must not
///         leak into the ETH side (balances, fees, events).
contract MultiQuoteTest is Helpers {
    MockQuoteToken internal usdm; // 18 decimals, like USDm
    MockQuoteToken internal mega; // 18 decimals
    MockQuoteToken internal usd6; // 6 decimals: the curve must not care

    uint256 internal constant USDM_GRAD = 20_000e18;
    uint256 internal constant USDM_FEE  = 50e18;
    uint256 internal constant MEGA_GRAD = 1_000_000e18;
    uint256 internal constant MEGA_FEE  = 2_500e18;
    uint256 internal constant USD6_GRAD = 20_000e6;
    uint256 internal constant USD6_FEE  = 50e6;

    address internal referrer = address(0xBEEF);

    function setUp() public override {
        super.setUp();
        usdm = new MockQuoteToken("MegaUSD", "USDm", 18);
        mega = new MockQuoteToken("MEGA", "MEGA", 18);
        usd6 = new MockQuoteToken("USD6", "USD6", 6);

        factory.setQuote(address(usdm), true, USDM_GRAD, USDM_FEE);
        factory.setQuote(address(mega), true, MEGA_GRAD, MEGA_FEE);
        factory.setQuote(address(usd6), true, USD6_GRAD, USD6_FEE);

        address[3] memory actors = [alice, bob, charlie];
        for (uint256 i; i < actors.length; i++) {
            usdm.mint(actors[i], 1_000_000e18);
            mega.mint(actors[i], 100_000_000e18);
            usd6.mint(actors[i], 1_000_000e6);
            vm.startPrank(actors[i]);
            usdm.approve(address(factory), type(uint256).max);
            mega.approve(address(factory), type(uint256).max);
            usd6.approve(address(factory), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ════════════════════════════════════════════════════════════
    //  Helpers
    // ════════════════════════════════════════════════════════════

    function _quoteDigest(
        address creator, string memory name, string memory ticker, string memory uri,
        address quote, uint256 deadline, uint256 nonce
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            factory.CREATE_QUOTE_TYPEHASH(),
            creator,
            keccak256(bytes(name)),
            keccak256(bytes(ticker)),
            keccak256(bytes(uri)),
            quote,
            deadline,
            nonce
        ));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _signQuote(
        address creator, string memory name, string memory ticker, string memory uri,
        address quote, uint256 deadline, uint256 nonce
    ) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            _pkOf(creator), _quoteDigest(creator, name, ticker, uri, quote, deadline, nonce)
        );
        return abi.encodePacked(r, s, v);
    }

    /// @dev Self-create (no signature needed) + first buy, at the current block.
    function _createQ(address creator, address quote, uint256 amountIn) internal returns (uint256 id) {
        vm.prank(creator);
        id = factory.createAndBuyWithQuote(
            creator, "QuoteCoin", "QTE", "ipfs://q", quote,
            type(uint256).max, 0, "", amountIn, 0, address(0), ""
        );
    }

    function _createQAndSkip(address creator, address quote, uint256 amountIn) internal returns (uint256 id) {
        id = _createQ(creator, quote, amountIn);
        vm.roll(block.number + factory.ANTI_SNIPE_BLOCKS() + 1);
    }

    function _buyQ(uint256 id, address buyer, uint256 amount) internal {
        vm.prank(buyer);
        factory.buyWithQuote(id, amount, 0, address(0), "");
    }

    function _sellQ(uint256 id, address seller, uint256 amount) internal {
        vm.prank(seller);
        factory.sell(id, amount, 0, address(0), "");
    }

    function _feeBps(bool isCreator) internal view returns (uint256) {
        return factory.platformFeeBps() + (isCreator ? 0 : factory.creatorFeeBps());
    }

    // ════════════════════════════════════════════════════════════
    //  Quote registry (Safe)
    // ════════════════════════════════════════════════════════════

    function test_SetQuote_OnlyOwner() public {
        vm.prank(bob);
        vm.expectRevert(NotOwner.selector);
        factory.setQuote(address(usdm), true, USDM_GRAD, USDM_FEE);
    }

    function test_SetQuote_RejectsEthAndWeth() public {
        vm.expectRevert(InvalidAddress.selector);
        factory.setQuote(address(0), true, 1e18, 0);
        vm.expectRevert(InvalidAddress.selector);
        factory.setQuote(address(weth), true, 1e18, 0);
    }

    function test_SetQuote_RejectsZeroThreshold() public {
        vm.expectRevert(BelowMinimum.selector);
        factory.setQuote(address(usdm), true, 0, 0);
    }

    function test_SetQuote_FeeCappedAtTenPercentOfThreshold() public {
        vm.expectRevert(ExceedsMaxFee.selector);
        factory.setQuote(address(usdm), true, 1_000e18, 100e18 + 1);
        factory.setQuote(address(usdm), true, 1_000e18, 100e18);
    }

    function test_SetQuote_StoresAndEmits() public {
        vm.expectEmit(true, false, false, true, address(factory));
        emit MegaPumpFactory.QuoteUpdated(address(mega), false, 5e24, 1e21);
        factory.setQuote(address(mega), false, 5e24, 1e21);

        (bool enabled, uint256 amount, uint256 fee) = factory.quoteConfig(address(mega));
        assertFalse(enabled);
        assertEq(amount, 5e24);
        assertEq(fee, 1e21);
    }

    // ════════════════════════════════════════════════════════════
    //  Creation
    // ════════════════════════════════════════════════════════════

    function test_CreateWithQuote_SelfCreate() public {
        uint256 before = usdm.balanceOf(alice);
        uint256 ethBefore = alice.balance;

        vm.recordLogs();
        uint256 id = _createQ(alice, address(usdm), 50e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        MegaPumpLens.TokenInfo memory info = _info(id);
        assertEq(info.quote, address(usdm), "quote stored");
        assertEq(info.graduationETH, USDM_GRAD, "threshold locked from the quote");
        assertEq(info.creator, alice);
        assertTrue(info.deployed);
        assertEq(info.name, "QuoteCoin");
        assertEq(info.ticker, "QTE");
        assertEq(info.metadataURI, "ipfs://q");
        assertGt(_balanceOf(id, alice), 0);

        assertEq(before - usdm.balanceOf(alice), 50e18, "pulls exactly the amount");
        assertEq(usdm.balanceOf(address(factory)), 50e18);
        assertEq(alice.balance, ethBefore, "no ETH involved");
        assertEq(address(factory).balance, 0);

        bytes32 tokenQuote = keccak256("TokenQuote(uint256,address)");
        bool seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0] == tokenQuote) {
                assertEq(uint256(logs[i].topics[1]), id);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(usdm));
                seen = true;
            }
        }
        assertTrue(seen, "TokenQuote emitted");
    }

    function test_CreateEth_NoTokenQuoteEvent() public {
        vm.recordLogs();
        uint256 id = _createToken(alice);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 tokenQuote = keccak256("TokenQuote(uint256,address)");
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != tokenQuote);
        }
        assertEq(_info(id).quote, address(0));
    }

    /// @dev The backend indexes TokenCreated, then TokenDeployed, then Trade.
    ///      v3 deploys the ERC-20 at creation: the order must not change.
    function testFuzz_EventOrder_CreatedDeployedTrade(bool quoted) public {
        vm.recordLogs();
        if (quoted) _createQ(alice, address(usdm), 50e18);
        else _createToken(alice);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 created  = keccak256("TokenCreated(uint256,string,string,string,address,bytes32,uint256)");
        bytes32 deployed = keccak256("TokenDeployed(uint256,address,uint256)");
        bytes32 trade    = keccak256(
            "Trade(uint256,address,address,bool,uint256,uint256,uint256,uint256,uint256,address,uint256,uint256,uint256,uint256)"
        );
        uint256 iC = type(uint256).max;
        uint256 iD = type(uint256).max;
        uint256 iT = type(uint256).max;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(factory)) continue;
            bytes32 t = logs[i].topics[0];
            if (t == created) iC = i;
            else if (t == deployed) iD = i;
            else if (t == trade) iT = i;
        }
        assertLt(iC, iD, "TokenCreated before TokenDeployed");
        assertLt(iD, iT, "TokenDeployed before Trade");
    }

    function test_TokenData_NoLongerStoresNames() public {
        uint256 id = _createToken(alice);
        (, string memory name, string memory ticker, string memory uri, , , address tokenAddr, , , , , , , , ) =
            factory.tokenData(id);
        assertEq(bytes(name).length, 0);
        assertEq(bytes(ticker).length, 0);
        assertEq(bytes(uri).length, 0);
        assertEq(MegaPumpToken(tokenAddr).name(), "TestCoin");
        assertEq(MegaPumpToken(tokenAddr).symbol(), "TEST");
        assertEq(MegaPumpToken(tokenAddr).metadataURI(), "ipfs://test");
        assertEq(factory.getTokenId(tokenAddr), id);
    }

    function test_CreateWithQuote_ThirdParty() public {
        bytes memory sig = _signQuote(alice, "Gasless", "GAS", "ipfs://g", address(usdm), type(uint256).max, 7);
        uint256 bobBefore = usdm.balanceOf(bob);

        vm.prank(bob);
        uint256 id = factory.createAndBuyWithQuote(
            alice, "Gasless", "GAS", "ipfs://g", address(usdm),
            type(uint256).max, 7, sig, 50e18, 0, address(0), ""
        );

        assertEq(_info(id).creator, alice, "creator is the signer");
        assertGt(_balanceOf(id, bob), 0, "first buyer gets the tokens");
        assertEq(bobBefore - usdm.balanceOf(bob), 50e18, "first buyer pays");

        vm.prank(bob);
        vm.expectRevert(SignatureAlreadyUsed.selector);
        factory.createAndBuyWithQuote(
            alice, "Gasless", "GAS", "ipfs://g", address(usdm),
            type(uint256).max, 7, sig, 50e18, 0, address(0), ""
        );
    }

    function test_CreateWithQuote_QuoteIsSigned() public {
        bytes memory sig = _signQuote(alice, "Gasless", "GAS", "ipfs://g", address(usdm), type(uint256).max, 0);
        vm.prank(bob);
        vm.expectRevert(InvalidSignature.selector);
        factory.createAndBuyWithQuote(
            alice, "Gasless", "GAS", "ipfs://g", address(mega),
            type(uint256).max, 0, sig, 50e18, 0, address(0), ""
        );
    }

    function test_CreateWithQuote_RejectsEthTypehashSignature() public {
        bytes memory ethSig = _signCreateFor(alice, "Gasless", "GAS", "ipfs://g", type(uint256).max, 0);
        vm.prank(bob);
        vm.expectRevert(InvalidSignature.selector);
        factory.createAndBuyWithQuote(
            alice, "Gasless", "GAS", "ipfs://g", address(usdm),
            type(uint256).max, 0, ethSig, 50e18, 0, address(0), ""
        );
    }

    function test_CreateEth_RejectsQuoteTypehashSignature() public {
        bytes memory qSig = _signQuote(alice, "Gasless", "GAS", "ipfs://g", address(0), type(uint256).max, 0);
        vm.prank(bob);
        vm.expectRevert(InvalidSignature.selector);
        factory.createAndBuyForCreator{value: 0.01 ether}(
            alice, "Gasless", "GAS", "ipfs://g", type(uint256).max, 0, qSig, 0, address(0), ""
        );
    }

    function test_CreateWithQuote_ExpiredSignature() public {
        // Fixed values: under via_ir, `block.timestamp + 1` gets re-evaluated
        // after vm.warp, so the signed deadline would drift from the one passed.
        vm.warp(1_000_000);
        uint256 deadline = 999_999;
        bytes memory sig = _signQuote(alice, "Late", "LATE", "", address(usdm), deadline, 0);
        vm.prank(bob);
        vm.expectRevert(SignatureExpired.selector);
        factory.createAndBuyWithQuote(alice, "Late", "LATE", "", address(usdm), deadline, 0, sig, 50e18, 0, address(0), "");
    }

    function test_CreateWithQuote_SmartAccountCreator() public {
        uint256 sessionPk = 0x5E55;
        Valid1271 account = new Valid1271(vm.addr(sessionPk));
        bytes32 digest = _quoteDigest(address(account), "Smart", "SMRT", "ipfs://s", address(mega), type(uint256).max, 0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sessionPk, digest);

        vm.prank(bob);
        uint256 id = factory.createAndBuyWithQuote(
            address(account), "Smart", "SMRT", "ipfs://s", address(mega),
            type(uint256).max, 0, abi.encodePacked(r, s, v), 1_000e18, 0, address(0), ""
        );
        assertEq(_info(id).creator, address(account));
        assertEq(_info(id).quote, address(mega));
    }

    function test_CreateWithQuote_DisabledUnknownOrEthQuote_Reverts() public {
        factory.setQuote(address(mega), false, MEGA_GRAD, MEGA_FEE);
        MockQuoteToken unknown = new MockQuoteToken("Unknown", "UNK", 18);
        address[3] memory quotes = [address(mega), address(unknown), address(0)];
        for (uint256 i; i < quotes.length; i++) {
            vm.prank(alice);
            vm.expectRevert(QuoteNotEnabled.selector);
            factory.createAndBuyWithQuote(alice, "X", "X", "", quotes[i], type(uint256).max, 0, "", 50e18, 0, address(0), "");
        }
    }

    function test_CreateWithQuote_ZeroAmount_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(NoETH.selector);
        factory.createAndBuyWithQuote(alice, "X", "X", "", address(usdm), type(uint256).max, 0, "", 0, 0, address(0), "");
    }

    function test_CreateWithQuote_WithoutApproval_Reverts() public {
        vm.startPrank(alice);
        usdm.approve(address(factory), 0);
        vm.expectRevert();
        factory.createAndBuyWithQuote(alice, "X", "X", "", address(usdm), type(uint256).max, 0, "", 50e18, 0, address(0), "");
        vm.stopPrank();
    }

    function test_CreateWithQuote_RejectsEth() public {
        vm.prank(alice);
        (bool ok, ) = address(factory).call{value: 1 ether}(abi.encodeCall(
            factory.createAndBuyWithQuote,
            (alice, "X", "X", "", address(usdm), type(uint256).max, 0, "", 50e18, 0, address(0), "")
        ));
        assertFalse(ok, "nonpayable");
    }

    function test_CreateWithQuote_FeeOnTransferQuote_Reverts() public {
        FeeOnTransferToken taxed = new FeeOnTransferToken();
        factory.setQuote(address(taxed), true, USDM_GRAD, USDM_FEE);
        taxed.mint(alice, 1_000e18);
        vm.startPrank(alice);
        taxed.approve(address(factory), type(uint256).max);
        vm.expectRevert(QuoteAmountMismatch.selector);
        factory.createAndBuyWithQuote(alice, "T", "T", "", address(taxed), type(uint256).max, 0, "", 50e18, 0, address(0), "");
        vm.stopPrank();
    }

    function test_CreateWithQuote_AntiSnipeStillApplies() public {
        // 10% of the curve supply costs 1% of the threshold (quadratic curve).
        vm.prank(alice);
        vm.expectRevert(AntiSnipe.selector);
        factory.createAndBuyWithQuote(
            alice, "Snipe", "SNP", "", address(usdm), type(uint256).max, 0, "", 1_000e18, 0, address(0), ""
        );
    }

    // ════════════════════════════════════════════════════════════
    //  Buy
    // ════════════════════════════════════════════════════════════

    function test_BuyEth_OnQuoteToken_Reverts() public {
        uint256 id = _createQAndSkip(alice, address(usdm), 50e18);
        vm.prank(bob);
        vm.expectRevert(WrongQuote.selector);
        factory.buy{value: 1 ether}(id, 0, address(0), "");
    }

    function test_BuyWithQuote_OnEthToken_Reverts() public {
        uint256 id = _createAndDeploy(alice, 0.01 ether);
        vm.prank(bob);
        vm.expectRevert(WrongQuote.selector);
        factory.buyWithQuote(id, 100e18, 0, address(0), "");
    }

    function test_BuyWithQuote_AccountingInQuote() public {
        uint256 id = _createQAndSkip(alice, address(usdm), 50e18);
        MegaPumpLens.TokenInfo memory i0 = _info(id);
        uint256 platBefore   = factory.quoteFeesAccrued(address(usdm));
        uint256 ethFeesBefore = factory.platformFeesAccrued();

        uint256 amount = 1_000e18;
        bytes memory refSig = _signReferrer(referrer, bob);
        vm.prank(bob);
        factory.buyWithQuote(id, amount, 0, referrer, refSig);

        MegaPumpLens.TokenInfo memory i1 = _info(id);
        uint256 plat = (amount * factory.platformFeeBps()) / 10000;
        uint256 cre  = (amount * factory.creatorFeeBps()) / 10000;
        uint256 ref  = (amount * factory.referrerFeeBps()) / 10000;
        uint256 net  = amount - (amount * _feeBps(false)) / 10000;

        assertEq(i1.totalRaised - i0.totalRaised, net, "net into the curve");
        assertEq(i1.creatorFees - i0.creatorFees, cre, "creator fee in USDm");
        assertEq(factory.quoteFeesAccrued(address(usdm)) - platBefore, plat - ref, "platform fee in USDm");
        assertEq(factory.referrerQuoteFees(referrer, address(usdm)), ref, "referrer fee in USDm");
        assertEq(factory.referrerFees(referrer), 0, "nothing credited in ETH");
        assertEq(factory.platformFeesAccrued(), ethFeesBefore, "ETH fees untouched");
    }

    function test_BuyWithQuote_Slippage() public {
        uint256 id = _createQAndSkip(alice, address(usdm), 50e18);
        uint256 est = lens.estimateBuy(id, 500e18, bob);
        vm.prank(bob);
        vm.expectRevert(SlippageExceeded.selector);
        factory.buyWithQuote(id, 500e18, est + 1, address(0), "");
        vm.prank(bob);
        factory.buyWithQuote(id, 500e18, est, address(0), "");
    }

    function test_BuyWithQuote_Overflow_PullsOnlyWhatGraduates() public {
        uint256 id = _createQAndSkip(alice, address(usdm), 50e18);
        uint256 raised = _info(id).totalRaised;
        uint256 platBefore = factory.quoteFeesAccrued(address(usdm));
        uint256 bobBefore = usdm.balanceOf(bob);

        _buyQ(id, bob, 100_000e18); // far more than the curve can take

        MegaPumpLens.TokenInfo memory info = _info(id);
        assertTrue(info.graduated, "graduated");

        uint256 net   = USDM_GRAD - raised;
        uint256 gross = (net * 10000) / (10000 - _feeBps(false));
        assertEq(bobBefore - usdm.balanceOf(bob), gross, "pulls only the gross that fills the curve");

        // Pool token/USDm, LP burned, graduation fee kept in USDm
        assertEq(router.lastQuote(), address(usdm), "paired with USDm");
        assertEq(router.lastTo(), factory.DEAD(), "LP to DEAD");
        assertEq(router.lastAmountETH(), USDM_GRAD - USDM_FEE, "quote into the pool");
        uint256 buyPlat = (gross * factory.platformFeeBps()) / 10000;
        assertEq(factory.quoteFeesAccrued(address(usdm)) - platBefore, buyPlat + USDM_FEE, "platform + graduation fee");
        assertEq(address(factory).balance, 0, "no ETH moved");

        vm.prank(bob);
        vm.expectRevert(AlreadyGraduated.selector);
        factory.buyWithQuote(id, 1e18, 0, address(0), "");
    }

    function test_GraduationFee_CappedIfConfigRaisedLater() public {
        factory.setQuote(address(usdm), true, 1_000e18, 50e18);
        uint256 id = _createQAndSkip(alice, address(usdm), 5e18); // locks a 1,000 USDm threshold
        factory.setQuote(address(usdm), true, 10_000e18, 1_000e18); // fee now above that token's threshold

        _buyQ(id, bob, 100_000e18);

        assertTrue(_info(id).graduated, "a later config cannot block graduation");
        assertEq(router.lastAmountETH(), 1_000e18 - 100e18, "fee capped at 10% of what was raised");
    }

    function test_SixDecimalsQuote_TradesAndGraduates() public {
        uint256 id = _createQAndSkip(alice, address(usd6), 50e6);
        assertGt(_balanceOf(id, alice), 0);

        _buyQ(id, bob, 1_000e6);
        uint256 bal = _balanceOf(id, bob);
        uint256 before = usd6.balanceOf(bob);
        _sellQ(id, bob, bal / 3);
        assertGt(usd6.balanceOf(bob), before, "sell pays in the 6-decimals quote");

        _buyQ(id, charlie, 100_000e6);
        assertTrue(_info(id).graduated);
        assertEq(router.lastQuote(), address(usd6));
    }

    // ════════════════════════════════════════════════════════════
    //  Sell
    // ════════════════════════════════════════════════════════════

    function test_Sell_QuoteToken_PaysQuoteNotEth() public {
        uint256 id = _createQAndSkip(alice, address(usdm), 50e18);
        _buyQ(id, bob, 2_000e18);
        uint256 amount = _balanceOf(id, bob) / 2;
        uint256 est = lens.estimateSell(id, amount, bob);
        uint256 usdmBefore = usdm.balanceOf(bob);
        uint256 ethBefore = bob.balance;

        _sellQ(id, bob, amount);

        assertEq(usdm.balanceOf(bob) - usdmBefore, est, "paid the Lens estimate, in USDm");
        assertEq(bob.balance, ethBefore, "no ETH");
    }

    function test_DisabledQuote_ExistingTokensKeepTrading() public {
        uint256 id = _createQAndSkip(alice, address(usdm), 50e18);
        factory.setQuote(address(usdm), false, USDM_GRAD, USDM_FEE);

        _buyQ(id, bob, 1_000e18);
        _sellQ(id, bob, _balanceOf(id, bob) / 2);

        vm.prank(alice);
        vm.expectRevert(QuoteNotEnabled.selector);
        factory.createAndBuyWithQuote(alice, "N", "N", "", address(usdm), type(uint256).max, 0, "", 50e18, 0, address(0), "");
    }

    // ════════════════════════════════════════════════════════════
    //  Claims
    // ════════════════════════════════════════════════════════════

    function test_ClaimCreatorFees_QuoteToken() public {
        uint256 id = _createQAndSkip(alice, address(usdm), 50e18);
        _buyQ(id, bob, 2_000e18);
        uint256 fees = _info(id).creatorFees;
        assertGt(fees, 0);
        uint256 before = usdm.balanceOf(alice);
        uint256 ethBefore = alice.balance;

        vm.prank(alice);
        factory.claimCreatorFees(id);

        assertEq(usdm.balanceOf(alice) - before, fees);
        assertEq(alice.balance, ethBefore);
        assertEq(_info(id).creatorFees, 0);
    }

    function test_ClaimAllCreatorFees_OneQuotePerBatch() public {
        uint256 ethId  = _createTokenCustom(alice, "EthCoin", "ETHC", "ipfs://e", 0.01 ether);
        uint256 usdmId = _createQAndSkip(alice, address(usdm), 50e18);
        uint256 megaId = _createQAndSkip(alice, address(mega), 5_000e18);
        _buy(ethId, bob, 1 ether);
        _buyQ(usdmId, bob, 2_000e18);
        _buyQ(megaId, bob, 100_000e18);

        uint256 fe = _info(ethId).creatorFees;
        uint256 fu = _info(usdmId).creatorFees;
        uint256 fm = _info(megaId).creatorFees;
        assertGt(fe * fu * fm, 0);

        uint256 eB = alice.balance;
        uint256 uB = usdm.balanceOf(alice);
        uint256 mB = mega.balanceOf(alice);

        // The first claimable token (USDm) sets the batch quote
        uint256[] memory ids = new uint256[](3);
        ids[0] = usdmId; ids[1] = ethId; ids[2] = megaId;
        vm.prank(alice);
        factory.claimAllCreatorFees(ids);
        assertEq(usdm.balanceOf(alice) - uB, fu, "USDm batch paid");
        assertEq(alice.balance, eB, "ETH token skipped");
        assertEq(mega.balanceOf(alice), mB, "MEGA token skipped");
        assertEq(_info(ethId).creatorFees, fe);
        assertEq(_info(megaId).creatorFees, fm);

        // Next batch: ETH first, MEGA skipped
        uint256[] memory ids2 = new uint256[](2);
        ids2[0] = ethId; ids2[1] = megaId;
        vm.prank(alice);
        factory.claimAllCreatorFees(ids2);
        assertEq(alice.balance - eB, fe, "ETH batch paid");
        assertEq(_info(megaId).creatorFees, fm);

        // Last batch: MEGA
        uint256[] memory ids3 = new uint256[](1);
        ids3[0] = megaId;
        vm.prank(alice);
        factory.claimAllCreatorFees(ids3);
        assertEq(mega.balanceOf(alice) - mB, fm, "MEGA batch paid");
    }

    function test_ReferrerQuoteFees_ClaimInQuote() public {
        uint256 id = _createQAndSkip(alice, address(usdm), 50e18);
        bytes memory refSig = _signReferrer(referrer, bob);
        vm.prank(bob);
        factory.buyWithQuote(id, 1_000e18, 0, referrer, refSig);
        uint256 owed = factory.referrerQuoteFees(referrer, address(usdm));
        assertGt(owed, 0);

        vm.prank(referrer);
        vm.expectRevert(NoReferrerFees.selector);
        factory.claimReferrerFees(); // nothing in ETH

        vm.prank(referrer);
        factory.claimReferrerQuoteFees(address(usdm));
        assertEq(usdm.balanceOf(referrer), owed);
        assertEq(factory.referrerQuoteFees(referrer, address(usdm)), 0);

        vm.prank(referrer);
        vm.expectRevert(NoReferrerFees.selector);
        factory.claimReferrerQuoteFees(address(usdm));
        vm.prank(referrer);
        vm.expectRevert(NoReferrerFees.selector);
        factory.claimReferrerQuoteFees(address(0));
    }

    function test_WithdrawQuoteFees_OwnerOnly() public {
        uint256 id = _createQAndSkip(alice, address(usdm), 50e18);
        _buyQ(id, bob, 1_000e18);
        uint256 accrued = factory.quoteFeesAccrued(address(usdm));
        assertGt(accrued, 0);

        vm.prank(bob);
        vm.expectRevert(NotOwner.selector);
        factory.withdrawQuoteFees(address(usdm));

        uint256 before = usdm.balanceOf(owner);
        factory.withdrawQuoteFees(address(usdm));
        assertEq(usdm.balanceOf(owner) - before, accrued);

        vm.expectRevert(NoFees.selector);
        factory.withdrawQuoteFees(address(usdm));
        vm.expectRevert(NoFees.selector);
        factory.withdrawQuoteFees(address(0));
    }

    // ════════════════════════════════════════════════════════════
    //  Ledger: the contract always holds what it owes, per quote
    // ════════════════════════════════════════════════════════════

    function testFuzz_QuoteLedgerBalanced(uint256 seed) public {
        uint256 id = _createQAndSkip(alice, address(usdm), 50e18);
        uint256 ethId = _createTokenCustom(alice, "EthCoin", "ETHC", "ipfs://e", 0.01 ether);
        bytes memory refSig = _signReferrer(referrer, bob);

        for (uint256 i; i < 12; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address who = r % 2 == 0 ? bob : charlie;
            if (r % 3 != 0) {
                uint256 amount = bound(r >> 8, 1e18, 1_500e18);
                vm.prank(who);
                factory.buyWithQuote(id, amount, 0, who == bob ? referrer : address(0), who == bob ? refSig : bytes(""));
            } else {
                uint256 bal = _balanceOf(id, who);
                if (bal > 0) _sellQ(id, who, bal / 2 + 1);
            }
            if (_info(id).graduated) break;
        }
        _buy(ethId, bob, 0.5 ether); // ETH side keeps its own ledger

        MegaPumpLens.TokenInfo memory info = _info(id);
        if (!info.graduated) {
            uint256 owed = info.totalRaised + info.creatorFees
                + factory.quoteFeesAccrued(address(usdm))
                + factory.referrerQuoteFees(referrer, address(usdm));
            uint256 held = usdm.balanceOf(address(factory));
            assertGe(held, owed, "never short of USDm");
            assertLe(held - owed, 100, "rounding dust only");
        }
        assertEq(factory.referrerFees(referrer), 0, "no USDm trade credited in ETH");
    }

    // ════════════════════════════════════════════════════════════
    //  Lens v3
    // ════════════════════════════════════════════════════════════

    function testFuzz_Lens_EstimateBuy_Quote_MatchesExecution(uint256 amount, bool asCreator) public {
        uint256 id = _createQAndSkip(alice, address(usdm), 50e18);
        address buyer = asCreator ? alice : bob;
        MegaPumpLens.TokenInfo memory info = _info(id);
        uint256 maxNoOverflow = ((info.graduationETH - info.totalRaised - 1) * 10000) / (10000 - _feeBps(asCreator));
        amount = bound(amount, 1e12, maxNoOverflow);
        uint256 est = lens.estimateBuy(id, amount, buyer);
        vm.assume(est > 0);

        uint256 before = _balanceOf(id, buyer);
        _buyQ(id, buyer, amount);
        assertEq(_balanceOf(id, buyer) - before, est);
    }

    function test_Lens_FirstBuyQuote_MatchesCreation() public {
        uint256 est = lens.estimateFirstBuyQuote(address(usdm), 50e18, true);
        uint256 id = _createQ(alice, address(usdm), 50e18);
        assertEq(_balanceOf(id, alice), est, "creator first buy");

        uint256 want = 1_000_000e18;
        uint256 pay = lens.estimateFirstBuyReverseQuote(address(usdm), want, false);
        bytes memory sig = _signQuote(alice, "Rev", "REV", "", address(usdm), type(uint256).max, 1);
        vm.prank(bob);
        uint256 id2 = factory.createAndBuyWithQuote(
            alice, "Rev", "REV", "", address(usdm), type(uint256).max, 1, sig, pay, 0, address(0), ""
        );
        assertGe(_balanceOf(id2, bob), want, "reverse quote delivers at least what was asked");
    }

    function test_Lens_FirstBuyQuote_UnknownOrDisabledQuote_Reverts() public {
        vm.expectRevert(QuoteNotEnabled.selector);
        lens.estimateFirstBuyQuote(address(0xdead), 1e18, false);
        vm.expectRevert(QuoteNotEnabled.selector);
        lens.estimateFirstBuyReverseQuote(address(0xdead), 1e18, false);
        vm.expectRevert(QuoteNotEnabled.selector);
        lens.estimateFirstBuyQuote(address(0), 1e18, false);

        // Disabled: same answer as createAndBuyWithQuote would give
        vm.prank(owner);
        factory.setQuote(address(usdm), false, USDM_GRAD, USDM_FEE);
        vm.expectRevert(QuoteNotEnabled.selector);
        lens.estimateFirstBuyQuote(address(usdm), 1e18, false);
        vm.expectRevert(QuoteNotEnabled.selector);
        lens.estimateFirstBuyReverseQuote(address(usdm), 1e18, false);
    }

    function test_Lens_GetTokenInfo_EthToken() public {
        uint256 id = _createToken(alice);
        MegaPumpLens.TokenInfo memory info = _info(id);
        assertEq(info.quote, address(0));
        assertEq(info.name, "TestCoin", "names read from the token");
        assertEq(info.graduationETH, factory.graduationETH());
    }
}
