// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/MegaPumpFactory.sol";
import "../src/MegaPumpToken.sol";
import "../src/GraduationLib.sol";

// ════════════════════════════════════════════════════════════════════
//  MOCKS — unchanged from V1
// ════════════════════════════════════════════════════════════════════

contract MockWETH {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function deposit() external payable { balanceOf[msg.sender] += msg.value; }
    function withdraw(uint256 a) external {
        require(balanceOf[msg.sender] >= a);
        balanceOf[msg.sender] -= a;
        payable(msg.sender).transfer(a);
    }
    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a; return true;
    }
    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a);
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        require(balanceOf[from] >= a);
        require(allowance[from][msg.sender] >= a);
        allowance[from][msg.sender] -= a;
        balanceOf[from] -= a; balanceOf[to] += a; return true;
    }
    receive() external payable { balanceOf[msg.sender] += msg.value; }
}

contract MockV2Router {
    address public lastTo;
    uint256 public lastAmountToken;
    uint256 public lastAmountETH;
    uint256 public lastLiquidity;
    mapping(address => address) public pairOf;


    function factory() external view returns (address) {
        return address(this);
    }

    function getPair(address tokenA, address /*tokenB*/) external view returns (address) {
        return pairOf[tokenA];
    }

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 /*amountTokenMin*/,
        uint256 /*amountETHMin*/,
        address to,
        uint256 /*deadline*/
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        IERC20(token).transferFrom(msg.sender, address(this), amountTokenDesired);
        lastTo          = to;
        lastAmountToken = amountTokenDesired;
        lastAmountETH   = msg.value;
        liquidity       = amountTokenDesired;
        lastLiquidity   = liquidity;
        pairOf[token]   = address(uint160(uint256(keccak256(abi.encodePacked(token, "pair")))));
        amountToken     = amountTokenDesired;
        amountETH       = msg.value;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(pairOf[tokenA] == address(0), "pair exists");
        MockV2Pair p = new MockV2Pair();
        pair = address(p);
        pairOf[tokenA] = pair;
        emit PairCreated(tokenA, tokenB, pair);
    }

    event PairCreated(address indexed token0, address indexed token1, address pair);
}


contract MockV2Pair {
    function skim(address) external {}
    function getReserves() external pure returns (uint112, uint112, uint32) {
        return (0, 0, 0);
    }
    function token0() external view returns (address) { return address(this); }
    function totalSupply() external pure returns (uint256) { return 0; }
    function balanceOf(address) external pure returns (uint256) { return 0; }
}

// ════════════════════════════════════════════════════════════════════
//  BASE TEST — proxy deploy, mocks, EIP-712 signing helpers
//
//  CHANGES vs V1:
//  - All createAndBuyForCreator calls now require a `nonce` parameter.
//  - _createDigest / _signCreate / _signCreateFor have nonce-aware variants
//    plus backward-compat overloads (nonce=0 default).
//  - Internal helpers (_createTokenWithBuy, _createAndBuyByThirdParty) pass
//    nonce=0 by default since the tests don't need to vary it.
// ════════════════════════════════════════════════════════════════════

abstract contract Helpers is Test {
    MegaPumpFactory public factory;
    MockWETH public weth;
    MockV2Router public router;

    address public owner = address(this);

    // ── Actors derived from known private keys (for EIP-712 signing) ──
    uint256 public constant ALICE_PK   = 0xA11CE0FF1CE5C0DE000000000000000000000000000000000000000000000001;
    uint256 public constant BOB_PK     = 0xB0B0000000000000000000000000000000000000000000000000000000000002;
    uint256 public constant CHARLIE_PK = 0xC4A1100E0000000000000000000000000000000000000000000000000000003;

    address public alice;
    address public bob;
    address public charlie;

    // Trusted signer for referrer signatures (DIFFERENT from creator pks above)
    uint256 public signerPk = 0xA17C5E;
    address public signer;

    // ── EIP-712 domain (mirror of contract's) ──────────────────────
    bytes32 public constant DOMAIN_NAME_HASH    = keccak256(bytes("MegaPump"));
    bytes32 public constant DOMAIN_VERSION_HASH = keccak256(bytes("1"));
    bytes32 public constant DOMAIN_TYPEHASH     = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    function setUp() public virtual {
        weth = new MockWETH();
        router = new MockV2Router();
        signer = vm.addr(signerPk);

        // Derive actor addresses from private keys
        alice   = vm.addr(ALICE_PK);
        bob     = vm.addr(BOB_PK);
        charlie = vm.addr(CHARLIE_PK);

        // Label for nicer trace output
        vm.label(alice,   "alice");
        vm.label(bob,     "bob");
        vm.label(charlie, "charlie");

        // Deploy implementation + proxy + initialize
        MegaPumpFactory impl = new MegaPumpFactory();
        bytes memory initData = abi.encodeCall(
            MegaPumpFactory.initialize,
            (address(router), address(weth))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        factory = MegaPumpFactory(payable(address(proxy)));

        // Set trusted signer + disable cooldown for simpler tests
        factory.setSigner(signer);
        factory.setTokenCreationCooldown(0);

        // Fund actors generously
        vm.deal(alice,   1_000 ether);
        vm.deal(bob,     1_000 ether);
        vm.deal(charlie, 1_000 ether);
    }

    // ════════════════════════════════════════════════════════════
    //  EIP-712 SIGNATURE HELPER
    // ════════════════════════════════════════════════════════════

    /// @notice Resolves the known private key for a known actor address.
    /// @dev Reverts if `who` is not one of the known test actors.
    function _pkOf(address who) internal view returns (uint256) {
        if (who == alice)   return ALICE_PK;
        if (who == bob)     return BOB_PK;
        if (who == charlie) return CHARLIE_PK;
        revert("Helpers: unknown actor - register pk in _pkOf");
    }

    /// @notice Computes the EIP-712 domain separator the factory uses.
    /// @dev Must match _domainSeparator() in MegaPumpFactory exactly.
    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(
            DOMAIN_TYPEHASH,
            DOMAIN_NAME_HASH,
            DOMAIN_VERSION_HASH,
            block.chainid,
            address(factory)
        ));
    }

    /// @notice Builds the EIP-712 digest for a CreateToken message (with nonce).
    function _createDigest(
        address _creator,
        string memory _name,
        string memory _ticker,
        string memory _metadataURI,
        uint256 _deadline,
        uint256 _nonce
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            factory.CREATE_TYPEHASH(),
            _creator,
            keccak256(bytes(_name)),
            keccak256(bytes(_ticker)),
            keccak256(bytes(_metadataURI)),
            _deadline,
            _nonce
        ));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    /// @notice Backward-compat overload — nonce defaults to 0.
    function _createDigest(
        address _creator,
        string memory _name,
        string memory _ticker,
        string memory _metadataURI,
        uint256 _deadline
    ) internal view returns (bytes32) {
        return _createDigest(_creator, _name, _ticker, _metadataURI, _deadline, 0);
    }

    /// @notice Produces a valid EIP-712 signature signed by `_creatorPk` (with nonce).
    function _signCreate(
        uint256 _creatorPk,
        address _creator,
        string memory _name,
        string memory _ticker,
        string memory _metadataURI,
        uint256 _deadline,
        uint256 _nonce
    ) internal view returns (bytes memory) {
        bytes32 digest = _createDigest(_creator, _name, _ticker, _metadataURI, _deadline, _nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_creatorPk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Backward-compat overload — nonce defaults to 0.
    function _signCreate(
        uint256 _creatorPk,
        address _creator,
        string memory _name,
        string memory _ticker,
        string memory _metadataURI,
        uint256 _deadline
    ) internal view returns (bytes memory) {
        return _signCreate(_creatorPk, _creator, _name, _ticker, _metadataURI, _deadline, 0);
    }

    /// @notice Convenience: signs CreateToken for a known actor address (with nonce).
    function _signCreateFor(
        address _creator,
        string memory _name,
        string memory _ticker,
        string memory _metadataURI,
        uint256 _deadline,
        uint256 _nonce
    ) internal view returns (bytes memory) {
        return _signCreate(_pkOf(_creator), _creator, _name, _ticker, _metadataURI, _deadline, _nonce);
    }

    /// @notice Backward-compat overload — nonce defaults to 0.
    function _signCreateFor(
        address _creator,
        string memory _name,
        string memory _ticker,
        string memory _metadataURI,
        uint256 _deadline
    ) internal view returns (bytes memory) {
        return _signCreateFor(_creator, _name, _ticker, _metadataURI, _deadline, 0);
    }

    // ════════════════════════════════════════════════════════════
    //  TOKEN CREATION HELPERS
    //
    //  V2 behavior: every token creation is also a first buy.
    //  The minimum viable first buy is small (0.01 ether default) so the
    //  creator pays minimal slippage. Tests can override.
    // ════════════════════════════════════════════════════════════

    /// @notice Default first-buy amount when not specified.
    uint256 internal constant _DEFAULT_FIRST_BUY = 0.01 ether;

    /// @notice Creates a token AT THE CURRENT BLOCK with `creator` as the first buyer.
    ///         Does NOT advance the block — useful for anti-snipe tests.
    function _createToken(address creator) internal returns (uint256) {
        return _createTokenWithBuy(creator, "TestCoin", "TEST", "ipfs://test", _DEFAULT_FIRST_BUY);
    }

    /// @notice Creates a token (with safe sub-anti-snipe initial buy), skips the
    ///         anti-snipe window, then optionally tops up via a second creator-buy
    ///         to reach the desired total initial spend.
    /// @dev    `firstBuyEth` is the TOTAL ETH the creator commits at setup.
    ///         When > _DEFAULT_FIRST_BUY, we split:
    ///           - 0.01 ether at creation (always under anti-snipe)
    ///           - remainder bought right after, post anti-snipe skip
    ///         This preserves V1 test semantics (caller asks for X ETH of setup spend).
    function _createAndDeploy(address creator, uint256 firstBuyEth) internal returns (uint256 id) {
        if (firstBuyEth <= _DEFAULT_FIRST_BUY) {
            // Fits under anti-snipe in one shot
            id = _createTokenWithBuy(creator, "TestCoin", "TEST", "ipfs://test", firstBuyEth);
            vm.roll(block.number + factory.ANTI_SNIPE_BLOCKS() + 1);
        } else {
            // Split: tiny safe buy at creation, then top-up after anti-snipe lift
            id = _createTokenWithBuy(creator, "TestCoin", "TEST", "ipfs://test", _DEFAULT_FIRST_BUY);
            vm.roll(block.number + factory.ANTI_SNIPE_BLOCKS() + 1);
            uint256 remaining = firstBuyEth - _DEFAULT_FIRST_BUY;
            _buy(id, creator, remaining);
        }
    }

    /// @notice Full-control variant: custom name/ticker/uri AND custom buy amount.
    function _createTokenCustom(
        address creator,
        string memory name,
        string memory ticker,
        string memory metadataURI,
        uint256 firstBuyEth
    ) internal returns (uint256 id) {
        if (firstBuyEth <= _DEFAULT_FIRST_BUY) {
            id = _createTokenWithBuy(creator, name, ticker, metadataURI, firstBuyEth);
            vm.roll(block.number + factory.ANTI_SNIPE_BLOCKS() + 1);
        } else {
            id = _createTokenWithBuy(creator, name, ticker, metadataURI, _DEFAULT_FIRST_BUY);
            vm.roll(block.number + factory.ANTI_SNIPE_BLOCKS() + 1);
            uint256 remaining = firstBuyEth - _DEFAULT_FIRST_BUY;
            _buy(id, creator, remaining);
        }
    }

    /// @notice Same as _createTokenCustom but does NOT skip anti-snipe.
    function _createTokenCustomNoSkip(
        address creator,
        string memory name,
        string memory ticker,
        string memory metadataURI,
        uint256 firstBuyEth
    ) internal returns (uint256 id) {
        id = _createTokenWithBuy(creator, name, ticker, metadataURI, firstBuyEth);
    }

    /// @notice Low-level: sign + call createAndBuyForCreator. No anti-snipe skip.
    ///         Uses nonce=0 for simplicity — tests don't need to vary the nonce
    ///         since each call uses a different (name, ticker, metadataURI) tuple.
    function _createTokenWithBuy(
        address creator,
        string memory name,
        string memory ticker,
        string memory metadataURI,
        uint256 firstBuyEth
    ) internal returns (uint256 id) {
        bytes memory sig = _signCreateFor(
            creator, name, ticker, metadataURI, type(uint256).max, 0
        );
        vm.prank(creator);
        id = factory.createAndBuyForCreator{value: firstBuyEth}(
            creator,
            name, ticker, metadataURI,
            type(uint256).max,
            0,           // nonce
            sig,
            0,           // minTokensOut
            address(0),  // referrer
            ""           // referrerSig
        );
    }

    // ════════════════════════════════════════════════════════════
    //  THIRD-PARTY FIRST BUY HELPER
    //  Lets test simulate "alice signs, bob buys first" — the core
    //  gasless creation flow.
    // ════════════════════════════════════════════════════════════

    /// @notice Alice signs offchain, Bob performs the first buy.
    function _createAndBuyByThirdParty(
        address creator,
        address firstBuyer,
        string memory name,
        string memory ticker,
        string memory metadataURI,
        uint256 firstBuyEth,
        uint256 deadline
    ) internal returns (uint256 id) {
        bytes memory sig = _signCreateFor(creator, name, ticker, metadataURI, deadline, 0);
        vm.prank(firstBuyer);
        id = factory.createAndBuyForCreator{value: firstBuyEth}(
            creator,
            name, ticker, metadataURI,
            deadline,
            0,           // nonce
            sig,
            0, address(0), ""
        );
    }

    // ════════════════════════════════════════════════════════════
    //  BUY / SELL HELPERS — unchanged
    // ════════════════════════════════════════════════════════════

    function _buy(uint256 id, address buyer, uint256 ethAmount) internal {
        vm.prank(buyer);
        factory.buy{value: ethAmount}(id, 0, address(0), "");
    }

    function _sell(uint256 id, address seller, uint256 tokenAmount) internal {
        vm.prank(seller);
        factory.sell(id, tokenAmount, 0, address(0), "");
    }

    function _buyWithMin(uint256 id, address buyer, uint256 eth, uint256 minTokens) internal {
        vm.prank(buyer);
        factory.buy{value: eth}(id, minTokens, address(0), "");
    }

    // ── Referrer signature helper ───────────────────────────────

    function _signReferrer(address referrer, address trader) internal view returns (bytes memory) {
        bytes32 hash = keccak256(abi.encodePacked(referrer, trader));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, ethHash);
        return abi.encodePacked(r, s, v);
    }

    function _buyWithReferrer(uint256 id, address buyer, uint256 eth, address referrer) internal {
        bytes memory sig = _signReferrer(referrer, buyer);
        vm.prank(buyer);
        factory.buy{value: eth}(id, 0, referrer, sig);
    }

    // ════════════════════════════════════════════════════════════
    //  TOKEN DATA ACCESSORS
    // ════════════════════════════════════════════════════════════

    function _info(uint256 id) internal view returns (MegaPumpFactory.TokenInfo memory) {
        return factory.getTokenInfo(id);
    }

    function _tokenAddr(uint256 id) internal view returns (address) {
        return _info(id).tokenAddress;
    }

    function _balanceOf(uint256 id, address who) internal view returns (uint256) {
        return IERC20(_tokenAddr(id)).balanceOf(who);
    }

    // ════════════════════════════════════════════════════════════
    //  CONSERVATION INVARIANT SNAPSHOT
    // ════════════════════════════════════════════════════════════

    struct EthSnapshot {
        uint256 totalRaised;
        uint256 platformFees;
        uint256 creatorFees;
        uint256 referrerFees;
        uint256 buyerBalance;
    }

    function _snapshot(uint256 id, address buyer, address referrer) internal view returns (EthSnapshot memory s) {
        MegaPumpFactory.TokenInfo memory info = _info(id);
        s.totalRaised   = info.totalRaised;
        s.platformFees  = factory.platformFeesAccrued();
        s.creatorFees   = info.creatorFees;
        s.referrerFees  = referrer == address(0) ? 0 : factory.referrerFees(referrer);
        s.buyerBalance  = buyer.balance;
    }

    receive() external payable {}
}
