// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./MegaPumpToken.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./BondingCurveMath.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "./GraduationLib.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ============================================================
//  ReentrancyGuard (inline — OZ v5 upgradeable no longer ships a separate file)
// ============================================================
abstract contract ReentrancyGuardUpgradeable is Initializable {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;
    uint256 private _reentrancyStatus;

    function __ReentrancyGuard_init() internal onlyInitializing {
        _reentrancyStatus = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        if (_reentrancyStatus == _ENTERED) revert ReentrantCall();
        _reentrancyStatus = _ENTERED;
    }

    function _nonReentrantAfter() private {
        _reentrancyStatus = _NOT_ENTERED;
    }
}


// ============================================================
//  Custom errors — saves ~2KB vs require strings
// ============================================================
error ReentrantCall();
error NotOwner();
error ContractPaused();
error TokenNotFound();
error AlreadyGraduated();
error InvalidAddress();
error InvalidName();
error InvalidTicker();
error NoETH();
error AntiSnipe();
error ZeroTokensOut();
error ExceedsCurveSupply();
error SlippageExceeded();
error NoTokens();
error TokenNotDeployed();
error ExceedsSoldSupply();
error ETHTransferFailed();
error NotCreator();
error NoFees();
error EmptyBatch();
error BatchTooLarge();
error NotPendingOwner();
error BelowMinimum();
error AboveMaximum();
error ExceedsMaxFee();
error NoReferrerFees();
error ReferrerFeeExceedsPlatformFee();
error CreationCooldown(uint256 remainingSeconds);
error NoPendingTransfer();
error SignatureExpired();
error SignatureAlreadyUsed();
error InvalidSignature();
error WrongQuote();
error QuoteNotEnabled();
error QuoteAmountMismatch();

/// @title  MegaPumpFactory — Memecoin launchpad on MegaETH (UUPS Upgradeable)
/// @author MegaPump
/// @notice Free token creation, bonding curve pricing, automatic graduation.
/// @dev    Storage layout is append-only — never remove or reorder existing variables.
///         Add new variables only at the END of the storage section on upgrades.
///
/// v3 — multi-quote: a token is quoted in ETH or in an ERC-20 the owner enabled
/// with setQuote (USDm, MEGA...). The quote is fixed at creation (TokenData.quote,
/// address(0) = ETH, so every pre-v3 token is ETH) and every amount of the token
/// is in it: curve, fees, graduation threshold and fee, DEX pool. The ETH
/// functions keep their ABI; the ERC-20 path has its own (createAndBuyWithQuote,
/// buyWithQuote, claimReferrerQuoteFees, withdrawQuoteFees). A quote must be a
/// plain ERC-20: no fee on transfer, no rebase.
///
/// Security highlights:
/// - ReentrancyGuard on all fund-moving functions (buy, sell, claims, withdraw)
/// - Solidity 0.8.24 native overflow / underflow protection
/// - Checks-Effects-Interactions pattern throughout
/// - Slippage protection on buy and sell (anti-sandwich / front-running)
/// - Anti-snipe window on first N blocks after creation
/// - All prices computed on-chain — no external oracle
/// - ERC-20 quotes: SafeERC20, and every pull checks the amount actually received
contract MegaPumpFactory is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;


    // ============================================================
    //  CONSTANTS (bytecode — safe to change between upgrades)
    // ============================================================

    uint256 public constant TOTAL_SUPPLY         = 1_000_000_000 * 1e18;
    uint256 public constant CURVE_SUPPLY         = 800_000_000   * 1e18; // 80% on bonding curve
    uint256 public constant DEX_SUPPLY           = 200_000_000   * 1e18; // 20% to DEX at graduation
    uint256 public constant ANTI_SNIPE_BLOCKS    = 5;
    uint256 public constant ANTI_SNIPE_MAX       = CURVE_SUPPLY / 10;    // 10% of curve supply per tx
    address public constant DEAD                 = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant MIN_GRADUATION_ETH   = 5 ether;
    uint256 public constant MAX_GRADUATION_ETH   = 100 ether;
    uint256 public constant MAX_PLATFORM_FEE_BPS = 500;  // 5% hard cap
    uint256 public constant MAX_CREATOR_FEE_BPS  = 200;  // 2% hard cap
    uint256 public constant MAX_GRADUATION_FEE   = 0.1 ether;
    bytes32 public constant CREATE_TYPEHASH = keccak256(
        "CreateToken(address creator,string name,string ticker,string metadataURI,uint256 deadline,uint256 nonce)"
    );
    /// @notice v3 — creation of a token quoted in an ERC-20 (USDm, MEGA...).
    ///         The quote is signed by the creator, so a third party cannot change it.
    bytes32 public constant CREATE_QUOTE_TYPEHASH = keccak256(
        "CreateTokenWithQuote(address creator,string name,string ticker,string metadataURI,address quote,uint256 deadline,uint256 nonce)"
    );


    // ============================================================
    //  STRUCTS
    // ============================================================

    struct TokenData {
        address creator;
        string  name;
        string  ticker;
        string  metadataURI;
        uint256 createdBlock;
        uint256 createdAt;
        address tokenAddress;
        uint256 totalRaised;   // ETH net of fees currently held by the curve
        uint256 tokensSold;
        uint256 creatorFees;   // accumulated creator fees (claimable)
        bool    graduated;
        address dexPool;
        uint256 lpTokenId;
        uint256 graduationETH; // ← locked at creation (in quote units since v3)
        address quote;         // ← v3: quote asset, address(0) = ETH (all pre-v3 tokens)
    }

    /// @notice v3 — settings of an ERC-20 quote asset (USDm, MEGA...).
    ///         ETH keeps its legacy settings (graduationETH, graduationFee).
    struct QuoteConfig {
        bool    enabled;          // new tokens may be created in this quote
        uint256 graduationAmount; // threshold locked into new tokens, in quote units
        uint256 graduationFee;    // taken at graduation, in quote units
    }

    // TokenInfo moved to MegaPumpLens along with getTokenInfo (same fields, same ABI).

    // ============================================================
    //  STORAGE — declaration order is IMMUTABLE across upgrades
    //  ⚠️  Append only — never reorder or remove existing variables.
    //  Slot numbers below match `forge inspect MegaPumpFactory storageLayout`.
    //  Slot 0 is _reentrancyStatus, inherited from ReentrancyGuardUpgradeable.
    //  (Initializable / UUPSUpgradeable use ERC-7201 namespaced storage and
    //   consume no sequential slots.)
    // ============================================================

    // Slot 1
    address public owner;
    // Slot 2
    address public router;
    // Slot 3 — packed: weth (20B) + paused (1B)
    address public weth;
    bool    public paused;
    // Slot 4
    uint256 public platformFeesAccrued;
    // Slot 5
    uint256 public graduationETH;
    // Slot 6
    uint256 public tokenCount;
    // Slot 7
    mapping(uint256 => TokenData) public tokenData;
    // Slot 8
    mapping(address => uint256) public tokenIdByAddress;
    // Slot 9 — configurable fees
    uint256 public platformFeeBps; // default: 100  (1%)
    // Slot 10
    uint256 public creatorFeeBps;  // default: 25   (0.25%)
    // Slot 11
    uint256 public graduationFee;  // default: 0.015 ETH
     // Slot 12 — pendingOwner (20B)
    address public pendingOwner;   // two-step ownership transfer

    // ── Referral (append-only upgrade) ───────────────────────────
    // Slot 13
    /// @notice Accumulated referrer fees, claimable via claimReferrerFees()
    mapping(address => uint256) public referrerFees;
    // Slot 14
    /// @notice Referrer fee in bps — must stay strictly below platformFeeBps
    uint256 public referrerFeeBps; // default: 10 (0.1%)

    // ── Trusted signer for referrer validation (append-only) ──────
    // Slot 15
    address public trustedSigner;

    // ── Token creation rate limit (append-only) ──────────────────
    // Slot 16
    mapping(address => uint256) public lastTokenCreatedAt;
    // Slot 17
    uint256 public tokenCreationCooldown;

    // ── Gasless creation (append-only) ───────────────────────────
    // Slot 18
    /// @notice Tracks consumed creation signatures — anti-replay
    mapping(bytes32 => bool) public usedSignatures;

    // ── Multi-quote (v3, append-only) ────────────────────────────
    // Slot 19
    /// @notice Settings of each ERC-20 quote asset. ETH is not in here.
    mapping(address => QuoteConfig) public quoteConfig;
    // Slot 20
    /// @notice Platform fees accrued per ERC-20 quote (ETH stays in platformFeesAccrued)
    mapping(address => uint256) public quoteFeesAccrued;
    // Slot 21
    /// @notice Referrer fees per referrer and ERC-20 quote (ETH stays in referrerFees)
    mapping(address => mapping(address => uint256)) public referrerQuoteFees;

    // ── Future upgrades: add new variables HERE only ─────────────

    // ============================================================
    //  EVENTS
    // ============================================================

    event TokenCreated(
        uint256 indexed tokenId, string name, string ticker,
        string metadataURI, address indexed creator, bytes32 indexed signatureHash, uint256 timestamp
    );
    event TokenDeployed(
        uint256 indexed tokenId, address indexed tokenAddress, uint256 timestamp
    );
    event Trade(
        uint256 indexed tokenId, address indexed tokenAddress,
        address indexed trader, bool isBuy,
        uint256 ethAmount, uint256 tokenAmount,
        uint256 platformFee, uint256 creatorFee,
        uint256 referrerFee, address referrer,
        uint256 newPrice, uint256 newMarketCap,
        uint256 newTokensSold, uint256 timestamp
    );
    event Graduated(
        uint256 indexed tokenId, address indexed tokenAddress,
        address indexed dexPool, uint256 lpTokenId,
        uint256 liquidityETH, uint256 liquidityTokens, uint256 timestamp
    );
    event CreatorFeesClaimed(
        uint256 indexed tokenId, address indexed creator, uint256 amount
    );
    event CreatorFeesClaimedAll(
        address indexed creator, uint256 totalAmount, uint256 tokenCount
    );
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ReferrerFeesClaimed(address indexed referrer, uint256 amount);
    event SignerUpdated(address indexed oldSigner, address indexed newSigner);
    event TokenCreationCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);
    event OwnershipTransferCancelled(address indexed cancelledOwner);
    /// @notice v3 — emitted at creation of a token quoted in an ERC-20.
    ///         A token without this event is quoted in ETH.
    event TokenQuote(uint256 indexed tokenId, address indexed quote);
    event QuoteUpdated(address indexed quote, bool enabled, uint256 graduationAmount, uint256 graduationFee);
    event ReferrerQuoteFeesClaimed(address indexed referrer, address indexed quote, uint256 amount);
    /// @notice A creator cancelled one of their signed creation intents.
    event CreationCancelled(address indexed creator, bytes32 indexed digest);

    // ============================================================
    //  MODIFIERS
    // ============================================================

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    modifier notPaused() {
        _notPaused();
        _;
    }

    modifier validToken(uint256 _id) {
        _validToken(_id);
        _;
    }

    modifier notGraduated(uint256 _id) {
        _notGraduated(_id);
        _;
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner) revert NotOwner();
    }

    function _notPaused() internal view {
        if (paused) revert ContractPaused();
    }

    function _validToken(uint256 _id) internal view {
        if (_id == 0 || _id > tokenCount) revert TokenNotFound();
    }

    function _notGraduated(uint256 _id) internal view {
        if (tokenData[_id].graduated) revert AlreadyGraduated();
    }

    // ============================================================
    //  CONSTRUCTOR — disables initialize() on the implementation
    // ============================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============================================================
    //  INITIALIZER — called once via the proxy, never re-runs on upgrade
    // ============================================================

    function initialize(
        address _router,
        address _weth
    ) external initializer {
        __ReentrancyGuard_init();
        if (_router == address(0)) revert InvalidAddress();
        if (_weth == address(0)) revert InvalidAddress();
        owner  = msg.sender;
        router = _router;
        weth   = _weth;
        graduationETH   = 24 ether;
        platformFeeBps  = 100;
        creatorFeeBps   = 25;
        graduationFee   = 0.015 ether;
        referrerFeeBps  = 10;
        tokenCreationCooldown = 60;
    }

    // ============================================================
    //  UUPS — upgrade authorization (owner only)
    // ============================================================

    function _authorizeUpgrade(address /*newImplementation*/)
        internal override onlyOwner {}

    receive() external payable {}


    /// @notice EIP-712 domain separator, computed on-the-fly.
    /// @dev    Computed at call time rather than stored to avoid storage layout
    ///         concerns on upgrades and to remain robust against chain forks.
    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("MegaPump")),
            keccak256(bytes("1")),
            block.chainid,
            address(this)
        ));
    }


    /// @notice Creates a token AND buys in a single transaction, with the
    ///         creator pre-signing the creation params offchain (EIP-712).
    /// @dev    This is the ONLY entry point for token creation. Used both
    ///         when the creator buys their own token immediately and when
    ///         a third party performs the first buy. The creator never pays gas:
    ///         only the caller (msg.sender, the first buyer) does.
    /// @param _creator     The wallet that signed the creation message
    /// @param _name        Token name (1-32 chars)
    /// @param _ticker      Token ticker (1-10 chars)
    /// @param _metadataURI ipfs:// URI to the ERC-721-style metadata JSON
    /// @param _deadline    Signature expiry (use type(uint256).max for "no expiry")
    /// @param _signature   EIP-712 signature by _creator over the above fields.
    ///                     Optional when msg.sender == _creator (empty bytes),
    ///                     consumed whenever passed (anti-replay).
    /// @param _minTokensOut Slippage protection on the first buy
    /// @param _referrer    Optional referrer address (use address(0) for none)
    /// @param _referrerSig Referrer signature from backend (or empty bytes if none)
    /// @return The on-chain tokenId assigned to this token
    function createAndBuyForCreator(
        address _creator,
        string calldata _name,
        string calldata _ticker,
        string calldata _metadataURI,
        uint256 _deadline,
        uint256 _nonce,
        bytes calldata _signature,
        uint256 _minTokensOut,
        address _referrer,
        bytes calldata _referrerSig
    ) external payable nonReentrant notPaused returns (uint256) {
        // ── 1. Validation inputs ──────────────────────────────────
        _validateCreate(_creator, _name, _ticker, msg.value);

        // ── 2. Auth path: either msg.sender == creator OR valid EIP-712 sig ──
        //
        // When the creator calls this function themselves, their transaction
        // signature is itself proof of authorization — no need to require an
        // additional EIP-712 signature. This is the "self-create + buy" path
        // and gives a 1-popup UX in the frontend.
        //
        // Third parties (anyone paying gas on behalf of the creator) MUST
        // provide a valid EIP-712 signature from the creator. This preserves
        // the gasless flow's security guarantees.
        //
        // A signature passed on the self-create path is not verified, but it
        // IS consumed (see _consumeCreateSignature): the creator may be
        // deploying their own pending token, whose signature is public. Left
        // unconsumed, a third party could replay it and deploy a clone.
        if (msg.sender != _creator || _signature.length != 0) {
            bytes32 structHash = keccak256(abi.encode(
                CREATE_TYPEHASH,
                _creator,
                keccak256(bytes(_name)),
                keccak256(bytes(_ticker)),
                keccak256(bytes(_metadataURI)),
                _deadline,
                _nonce
            ));
            if (msg.sender != _creator) _checkCreateSignature(_creator, structHash, _deadline, _signature);
            else _consumeCreateSignature(structHash, _signature);
        }
        // Else: self-create with no signature. Tx signature is proof enough.

        // ── 3-4. Cooldown, then the token slot (quoted in ETH) ────
        uint256 id = _createToken(_creator, _name, _ticker, _metadataURI, address(0), _signature);

        // ── 5. Execute the first buy ────
        _executeBuy(id, msg.value, _minTokensOut, _referrer, _referrerSig);

        return id;
    }

    /// @notice v3 — same as createAndBuyForCreator for a token quoted in an
    ///         ERC-20 (USDm, MEGA...). The quote is part of the creator's
    ///         EIP-712 signature (CreateTokenWithQuote). The first buyer must
    ///         have approved `_amountIn` of the quote to this contract; only
    ///         the amount actually used is pulled.
    function createAndBuyWithQuote(
        address _creator,
        string calldata _name,
        string calldata _ticker,
        string calldata _metadataURI,
        address _quote,
        uint256 _deadline,
        uint256 _nonce,
        bytes calldata _signature,
        uint256 _amountIn,
        uint256 _minTokensOut,
        address _referrer,
        bytes calldata _referrerSig
    ) external nonReentrant notPaused returns (uint256) {
        _validateCreate(_creator, _name, _ticker, _amountIn);
        if (!quoteConfig[_quote].enabled) revert QuoteNotEnabled();

        // Same auth rule as createAndBuyForCreator, signature consumed on the
        // self-create path too.
        if (msg.sender != _creator || _signature.length != 0) {
            bytes32 structHash = keccak256(abi.encode(
                CREATE_QUOTE_TYPEHASH,
                _creator,
                keccak256(bytes(_name)),
                keccak256(bytes(_ticker)),
                keccak256(bytes(_metadataURI)),
                _quote,
                _deadline,
                _nonce
            ));
            if (msg.sender != _creator) _checkCreateSignature(_creator, structHash, _deadline, _signature);
            else _consumeCreateSignature(structHash, _signature);
        }

        uint256 id = _createToken(_creator, _name, _ticker, _metadataURI, _quote, _signature);
        _executeBuy(id, _amountIn, _minTokensOut, _referrer, _referrerSig);
        return id;
    }

    /// @dev Input checks shared by both creation paths, in their original order.
    function _validateCreate(
        address _creator, string calldata _name, string calldata _ticker, uint256 _amount
    ) internal pure {
        if (bytes(_name).length == 0 || bytes(_name).length > 32) revert InvalidName();
        if (bytes(_ticker).length == 0 || bytes(_ticker).length > 10) revert InvalidTicker();
        if (_amount == 0) revert NoETH();
        if (_creator == address(0)) revert InvalidAddress();
    }

    /// @dev Third-party creation: checks the creator's EIP-712 signature over
    ///      `_structHash` and consumes it (anti-replay).
    function _checkCreateSignature(
        address _creator, bytes32 _structHash, uint256 _deadline, bytes calldata _signature
    ) internal {
        if (block.timestamp > _deadline) revert SignatureExpired();

        bytes32 digest = _consumeCreateSignature(_structHash, _signature);

        // Universal verification: ECDSA for EOAs (bit-identical to v1),
        // ERC-1271 isValidSignature for smart accounts (MOSS, Safe, ...).
        if (!SignatureChecker.isValidSignatureNow(_creator, digest, _signature)) {
            revert InvalidSignature();
        }
    }

    /// @dev Marks the creation intent `_structHash` as used and returns its
    ///      EIP-712 digest. Reverts if it was already used.
    ///      On the self-create path (msg.sender == creator) it is called
    ///      without verifying the signature: the digest embeds the caller as
    ///      creator, so the caller can only close their own intents. No
    ///      deadline check either, the creator's own tx needs none.
    function _consumeCreateSignature(bytes32 _structHash, bytes calldata _signature)
        internal returns (bytes32 digest)
    {
        digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), _structHash));

        // Replay guard keyed on the DIGEST (the creation intent), not the
        // signature bytes. ERC-1271 accounts may accept multiple byte-strings
        // for one digest (multiple session keys, envelope malleability) —
        // keying on sig bytes would allow replaying the same intent.
        // The sigHash check preserves pre-upgrade consumed entries (v1 wrote
        // sigHash keys into this same mapping/slot).
        bytes32 sigHash = keccak256(_signature);
        if (usedSignatures[sigHash] || usedSignatures[digest]) revert SignatureAlreadyUsed();
        usedSignatures[digest] = true;
    }

    /// @notice Cancels a signed creation intent before anyone deploys it. The
    ///         signature becomes unusable, for everyone. Pass the exact fields
    ///         that were signed, with `_quote = address(0)` for an ETH token.
    /// @dev    Only the creator can cancel: the digest embeds msg.sender as the
    ///         creator, so any other caller only marks a digest nobody signed.
    ///         Same replay key as the creation paths (usedSignatures[digest]).
    ///         Not paused on purpose: withdrawing an intent must always work.
    function cancelCreation(
        string calldata _name,
        string calldata _ticker,
        string calldata _metadataURI,
        address _quote,
        uint256 _deadline,
        uint256 _nonce
    ) external {
        bytes32 structHash = _quote == address(0)
            ? keccak256(abi.encode(
                CREATE_TYPEHASH, msg.sender,
                keccak256(bytes(_name)), keccak256(bytes(_ticker)), keccak256(bytes(_metadataURI)),
                _deadline, _nonce))
            : keccak256(abi.encode(
                CREATE_QUOTE_TYPEHASH, msg.sender,
                keccak256(bytes(_name)), keccak256(bytes(_ticker)), keccak256(bytes(_metadataURI)),
                _quote, _deadline, _nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        if (usedSignatures[digest]) revert SignatureAlreadyUsed();
        usedSignatures[digest] = true;
        emit CreationCancelled(msg.sender, digest);
    }

    /// @dev Cooldown on the creator, then the token slot and its ERC-20.
    ///      v3: the ERC-20 is deployed here, straight from calldata, and the
    ///      name, ticker and metadata URI are no longer copied into tokenData:
    ///      they live on the token contract and in TokenCreated. Saves three
    ///      string writes per creation and ~2.5 KB of factory bytecode. The
    ///      first buy still follows in the same transaction, and the event
    ///      order is unchanged: TokenCreated, TokenDeployed, then Trade.
    ///      The graduation threshold is locked from the quote's current setting.
    function _createToken(
        address _creator,
        string calldata _name,
        string calldata _ticker,
        string calldata _metadataURI,
        address _quote,
        bytes calldata _signature
    ) internal returns (uint256 id) {
        // ── Cooldown check on the CREATOR (not msg.sender) ────
        uint256 last = lastTokenCreatedAt[_creator];
        if (last != 0 && block.timestamp - last < tokenCreationCooldown) {
            revert CreationCooldown(tokenCreationCooldown - (block.timestamp - last));
        }
        lastTokenCreatedAt[_creator] = block.timestamp;

        // ── Create the token slot with creator = signer ───────
        // Fresh slot: every field not written here is zero.
        id = ++tokenCount;
        TokenData storage d = tokenData[id];
        d.creator       = _creator;
        d.createdBlock  = block.number;
        d.createdAt     = block.timestamp;
        d.graduationETH = _quote == address(0) ? graduationETH : quoteConfig[_quote].graduationAmount;
        d.quote         = _quote;

        emit TokenCreated(
            id, _name, _ticker, _metadataURI,
            _creator, keccak256(_signature), block.timestamp
        );
        if (_quote != address(0)) emit TokenQuote(id, _quote);

        // ── Deploy the ERC-20 (the whole supply is minted to this contract) ──
        address token = address(new MegaPumpToken(_name, _ticker, _metadataURI, address(this)));
        d.tokenAddress = token;
        tokenIdByAddress[token] = id;
        emit TokenDeployed(id, token, block.timestamp);
    }

    // ============================================================
    //  BUY
    // ============================================================

    /// @notice Buys a token quoted in ETH, paid with msg.value.
    /// @param _referrer Referrer address from backend — address(0) if none.
    function buy(uint256 _tokenId, uint256 _minTokensOut, address _referrer, bytes calldata _referrerSig)
        external payable nonReentrant notPaused validToken(_tokenId) notGraduated(_tokenId)
    {
        if (tokenData[_tokenId].quote != address(0)) revert WrongQuote();
        _executeBuy(_tokenId, msg.value, _minTokensOut, _referrer, _referrerSig);
    }

    /// @notice v3 — buys a token quoted in an ERC-20 (USDm, MEGA...).
    ///         `_amountIn` of the quote must be approved to this contract; only
    ///         the amount actually used is pulled (less near graduation).
    function buyWithQuote(
        uint256 _tokenId,
        uint256 _amountIn,
        uint256 _minTokensOut,
        address _referrer,
        bytes calldata _referrerSig
    ) external nonReentrant notPaused validToken(_tokenId) notGraduated(_tokenId) {
        if (tokenData[_tokenId].quote == address(0)) revert WrongQuote();
        _executeBuy(_tokenId, _amountIn, _minTokensOut, _referrer, _referrerSig);
    }


    /// @dev `_amountIn` is msg.value for ETH tokens, the approved amount for
    ///      ERC-20 quoted tokens. All amounts below are in the token's quote.
    function _executeBuy(
        uint256 _tokenId,
        uint256 _amountIn,
        uint256 _minTokensOut,
        address _referrer,
        bytes calldata _referrerSig
    ) internal {
        if (_amountIn == 0) revert NoETH();
        TokenData storage data = tokenData[_tokenId];

        // Legacy: tokens created before v3 deploy their ERC-20 on first buy.
        // Since v3 the token is deployed at creation (_createToken).
        if (data.tokenAddress == address(0)) _deployToken(_tokenId);

        bool isCreatorBuying = (msg.sender == data.creator);
        uint256 totalFeeBps  = platformFeeBps + (isCreatorBuying ? 0 : creatorFeeBps);

        // ════════════════════════════════════════════════════════════════
        //  STEP 1 — Compute how much of msg.value is actually consumed
        //  by the curve (ethGrossUsed) vs refunded (ethRefund).
        //
        //  Convention: fees are charged ONLY on ethGrossUsed.
        //  - ethGrossUsed   = total gross actually used (curve + fees)
        //  - ethNetUsed     = net entering the curve = ethGrossUsed × (1 - feeBps)
        //  - ethRefund      = msg.value - ethGrossUsed
        //
        //  Design choice: the buyer never pays fees on the refunded amount.
        // ════════════════════════════════════════════════════════════════

        uint256 ethGrossUsed;
        uint256 ethNetForCurve;
        {
            // Tentative net based on the full amount in
            uint256 fullFee     = (_amountIn * totalFeeBps) / 10000;
            uint256 fullNet     = _amountIn - fullFee;
            uint256 raisedAfter = data.totalRaised + fullNet;

            if (raisedAfter <= data.graduationETH) {
                // No overflow → consume the full amount
                ethGrossUsed   = _amountIn;
                ethNetForCurve = fullNet;
            } else {
                // Overflow → cap net to exactly graduationETH - totalRaised
                ethNetForCurve = data.graduationETH - data.totalRaised;
                // Recover gross from net: gross = net × 10000 / (10000 - feeBps)
                // Round DOWN (in favor of contract) — buyer gets slightly more refund.
                // Formula: ethGrossUsed = ethNetForCurve × 10000 / (10000 - totalFeeBps)
                // Note: integer division truncates → ethGrossUsed × (10000 - feeBps) / 10000
                //       may yield slightly less than ethNetForCurve in net. That's fine:
                //       totalRaised may end at graduationETH - 1 wei, still triggers grad.
                ethGrossUsed = (ethNetForCurve * 10000) / (10000 - totalFeeBps);

                // Edge guard: if rounding made ethGrossUsed > _amountIn, cap to _amountIn.
                // Should never happen with sane inputs but defensive.
                if (ethGrossUsed > _amountIn) {
                    ethGrossUsed   = _amountIn;
                    // Recompute final net consistently
                    uint256 finalFee = (ethGrossUsed * totalFeeBps) / 10000;
                    ethNetForCurve  = ethGrossUsed - finalFee;
                }
            }
        }

        uint256 ethRefund = _amountIn - ethGrossUsed;

        // ════════════════════════════════════════════════════════════════
        //  STEP 2 — Compute tokens out from the actual net used
        // ════════════════════════════════════════════════════════════════

        uint256 tokensOut = BondingCurveMath.getTokensForETH(
            data.tokensSold,
            ethNetForCurve,
            data.graduationETH
        );

        // Anti-snipe
        if (block.number <= data.createdBlock + ANTI_SNIPE_BLOCKS) {
            if (tokensOut > ANTI_SNIPE_MAX) revert AntiSnipe();
        }

        if (tokensOut == 0) revert ZeroTokensOut();
        if (data.tokensSold + tokensOut > CURVE_SUPPLY) revert ExceedsCurveSupply();
        if (tokensOut < _minTokensOut) revert SlippageExceeded();

        // ════════════════════════════════════════════════════════════════
        //  STEP 3 — Compute fees on ethGrossUsed (NOT msg.value)
        // ════════════════════════════════════════════════════════════════

        uint256 platformFeeFull = (ethGrossUsed * platformFeeBps) / 10000;
        uint256 creatorFee      = isCreatorBuying ? 0 : (ethGrossUsed * creatorFeeBps) / 10000;

        // Referrer takes a slice OF the platform fee (not on top)
        uint256 refFee = 0;
        address effectiveReferrer = _sanitizeReferrer(_referrer, _referrerSig);
        if (effectiveReferrer != address(0)) {
            refFee = (ethGrossUsed * referrerFeeBps) / 10000;
            // Defensive: setReferrerFeeBps already enforces refFeeBps < platformFeeBps,
            // so refFee < platformFeeFull is guaranteed. Belt-and-suspenders:
            if (refFee >= platformFeeFull) refFee = platformFeeFull > 0 ? platformFeeFull - 1 : 0;
            _creditReferrer(data.quote, effectiveReferrer, refFee);
        }

        // ERC-20 quote: pull exactly what the curve uses, so nothing has to be
        // refunded. ETH arrived with msg.value; its unused part is refunded below.
        if (data.quote != address(0)) _pullQuote(data.quote, ethGrossUsed);

        // ════════════════════════════════════════════════════════════════
        //  STEP 4 — State updates BEFORE external calls (CEI strict)
        // ════════════════════════════════════════════════════════════════

        data.totalRaised    += ethNetForCurve;
        data.tokensSold     += tokensOut;
        data.creatorFees    += creatorFee;
        _creditPlatform(data.quote, platformFeeFull - refFee);

        // ════════════════════════════════════════════════════════════════
        //  STEP 5 — External calls: token transfer, then refund, then grad
        //  Order matters: refund MUST happen before _graduate() because
        //  _graduate() drains totalRaised to the DEX pool.
        // ════════════════════════════════════════════════════════════════

        IERC20(data.tokenAddress).transfer(msg.sender, tokensOut);

        if (ethRefund > 0 && data.quote == address(0)) {
            (bool refunded, ) = payable(msg.sender).call{value: ethRefund}("");
            if (!refunded) revert ETHTransferFailed();
        }

        // Trade event reflects ACTUAL fees accrued (not theoretical)
        // platformFee in event = platformFeeFull - refFee (what really went to platform)
        _emitTrade(
            _tokenId, msg.sender, true,
            ethGrossUsed, tokensOut,
            effectiveReferrer, refFee,
            platformFeeFull - refFee,
            creatorFee
        );

        // Graduation check — atomic in the same transaction
        if (data.totalRaised >= data.graduationETH) _graduate(_tokenId);
    }

    /// @dev Deploys the ERC-20 token on the first buy
    function _deployToken(uint256 _tokenId) internal {
        TokenData storage data = tokenData[_tokenId];
        MegaPumpToken token = new MegaPumpToken(
            data.name, data.ticker, data.metadataURI, address(this)
        );
        data.tokenAddress = address(token);
        tokenIdByAddress[address(token)] = _tokenId;
        emit TokenDeployed(_tokenId, address(token), block.timestamp);
    }

    /// @dev Emits Trade event in a separate stack frame to avoid stack-too-deep.
    ///      Fees are passed in to reflect REAL amounts accrued (creator fee can
    ///      be 0 when creator is the trader). DO NOT recompute fees here.
    function _emitTrade(
        uint256 _tokenId, address _trader, bool _isBuy,
        uint256 _ethAmount, uint256 _tokenAmount,
        address _referrer, uint256 _referrerFee,
        uint256 _platformFee,
        uint256 _creatorFee
    ) internal {
        TokenData storage d = tokenData[_tokenId];
        emit Trade(
            _tokenId, d.tokenAddress, _trader, _isBuy,
            _ethAmount, _tokenAmount,
            _platformFee,
            _creatorFee,
            _referrerFee, _referrer,
            BondingCurveMath.getCurrentPrice(d.tokensSold, d.graduationETH),
            BondingCurveMath.getMarketCap(d.tokensSold, d.graduationETH),
            d.tokensSold, block.timestamp
        );
    }

    // ============================================================
    //  SELL — single TX, no approve needed
    // ============================================================

    /// @notice Sells tokens in a single transaction.
    /// @dev    No approve step required. MegaPumpToken.allowance() returns
    ///         type(uint256).max for the factory address, so transferFrom()
    ///         always succeeds without any prior user approval.
    /// @param _tokenId     Token ID to sell
    /// @param _tokenAmount Amount of tokens in wei (18 decimals)
    /// @param _minETH      Minimum ETH to receive — slippage protection (0 = none)
    /// @param _referrer Referrer address from backend — address(0) if none.
    function sell(
    uint256 _tokenId,
    uint256 _tokenAmount,
    uint256 _minETH,
    address _referrer,
    bytes calldata _referrerSig
    ) external nonReentrant validToken(_tokenId) notGraduated(_tokenId) {
        _executeSell(_tokenId, _tokenAmount, _minETH, _referrer, _referrerSig);
    }

    function _executeSell(uint256 _tokenId, uint256 _tokenAmount, uint256 _minEthOut, address _referrer, bytes calldata _referrerSig) internal {
        if (_tokenAmount == 0) revert NoTokens();
        TokenData storage data = tokenData[_tokenId];
        if (data.tokenAddress == address(0)) revert TokenNotDeployed();
        if (_tokenAmount > data.tokensSold) revert ExceedsSoldSupply();

        uint256 ethOut = BondingCurveMath.getETHForTokens(data.tokensSold, _tokenAmount, data.graduationETH);
        if (ethOut > data.totalRaised) ethOut = data.totalRaised; // safety cap

        bool isCreatorSelling = (msg.sender == data.creator);
        uint256 totalFeeBps = platformFeeBps + (isCreatorSelling ? 0 : creatorFeeBps);
        uint256 ethToSeller = ethOut - (ethOut * totalFeeBps) / 10000;

        if (ethToSeller < _minEthOut) revert SlippageExceeded();

        // Fee split: referrer gets REFERRER_FEE_BPS from platform fee, not added on top
        uint256 grossPlatformFee  = (ethOut * platformFeeBps) / 10000;
        uint256 refFee            = 0;
        address effectiveReferrer = _sanitizeReferrer(_referrer, _referrerSig);
        if (effectiveReferrer != address(0)) {
            refFee = (ethOut * referrerFeeBps) / 10000;
            _creditReferrer(data.quote, effectiveReferrer, refFee);
        }

        // Compute real creator fee (0 if creator selling)
        uint256 creatorFee = isCreatorSelling ? 0 : (ethOut * creatorFeeBps) / 10000;

        // State updates BEFORE transfers (Checks-Effects-Interactions)
        data.totalRaised    -= ethOut;
        data.tokensSold     -= _tokenAmount;
        data.creatorFees    += creatorFee;
        _creditPlatform(data.quote, grossPlatformFee - refFee);

        IERC20(data.tokenAddress).transferFrom(msg.sender, address(this), _tokenAmount);
        _send(data.quote, msg.sender, ethToSeller);

        // Trade event reflects ACTUAL fees accrued
        _emitTrade(
            _tokenId, msg.sender, false,
            ethOut, _tokenAmount,
            effectiveReferrer, refFee,
            grossPlatformFee - refFee,
            creatorFee
        );
    }

    // ============================================================
    //  REFERRAL HELPERS
    // ============================================================

    /// @dev Rejects: address(0) and self-referral.
    ///      Backend controls which address is passed as referrer.
    ///      C-04: a malformed signature (wrong length, high-s, unrecoverable)
    ///      no longer reverts the whole trade — the referrer is simply
    ///      ignored, like an unsigned one. `tryRecoverCalldata` returns
    ///      address(0) on error, which can never equal a non-zero trustedSigner.
    function _sanitizeReferrer(
    address _referrer,
    bytes calldata _sig
    ) internal view returns (address) {
        if (_referrer == address(0))     return address(0);
        if (_referrer == msg.sender)     return address(0);
        if (trustedSigner == address(0)) return address(0);

        // Hash includes msg.sender — signature can't be reused by another trader
        bytes32 hash = keccak256(abi.encodePacked(_referrer, msg.sender));
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(hash);
        (address recovered, , ) = ECDSA.tryRecoverCalldata(ethHash, _sig);

        if (recovered != trustedSigner) return address(0);
        return _referrer;
    }

    /// @notice Claim all accumulated referrer fees in one call.
    function claimReferrerFees() external nonReentrant {
        uint256 amount = referrerFees[msg.sender];
        if (amount == 0) revert NoReferrerFees();
        referrerFees[msg.sender] = 0;
        (bool sent, ) = payable(msg.sender).call{value: amount}("");
        if (!sent) revert ETHTransferFailed();
        emit ReferrerFeesClaimed(msg.sender, amount);
    }

    /// @notice v3 — claims referrer fees accrued in an ERC-20 quote.
    function claimReferrerQuoteFees(address _quote) external nonReentrant {
        uint256 amount = referrerQuoteFees[msg.sender][_quote];
        if (amount == 0) revert NoReferrerFees();
        referrerQuoteFees[msg.sender][_quote] = 0;
        _send(_quote, msg.sender, amount);
        emit ReferrerQuoteFeesClaimed(msg.sender, _quote, amount);
    }

    // ============================================================
    //  QUOTE HELPERS (v3) — address(0) is ETH, anything else an ERC-20
    // ============================================================

    function _creditPlatform(address _quote, uint256 _amount) internal {
        if (_quote == address(0)) platformFeesAccrued += _amount;
        else quoteFeesAccrued[_quote] += _amount;
    }

    function _creditReferrer(address _quote, address _referrer, uint256 _amount) internal {
        if (_quote == address(0)) referrerFees[_referrer] += _amount;
        else referrerQuoteFees[_referrer][_quote] += _amount;
    }

    /// @dev Pulls `_amount` of an ERC-20 quote from msg.sender and checks the
    ///      contract really received it: a fee-on-transfer or otherwise
    ///      non-standard quote would break the accounting, so it reverts.
    function _pullQuote(address _quote, uint256 _amount) internal {
        uint256 before = IERC20(_quote).balanceOf(address(this));
        IERC20(_quote).safeTransferFrom(msg.sender, address(this), _amount);
        if (IERC20(_quote).balanceOf(address(this)) - before != _amount) revert QuoteAmountMismatch();
    }

    /// @dev Pays `_amount` of the quote (ETH or ERC-20) to `_to`.
    function _send(address _quote, address _to, uint256 _amount) internal {
        if (_quote == address(0)) {
            (bool sent, ) = payable(_to).call{value: _amount}("");
            if (!sent) revert ETHTransferFailed();
        } else {
            IERC20(_quote).safeTransfer(_to, _amount);
        }
    }

    // ============================================================
    //  GRADUATION
    // ============================================================

    /// @dev Internal graduation handler:
    ///      1. Marks token as graduated (blocks all future buys/sells atomically)
    ///      2. Deducts graduation fee
    ///      3. Adds liquidity (ETH + tokens) to our own Uniswap V2 pool via the Router
    ///      4. LP tokens are sent to DEAD (liquidity locked/burned forever — no rug possible)
    ///      5. Burns any remaining tokens held by the factory
    function _graduate(uint256 _tokenId) internal {
        TokenData storage data = tokenData[_tokenId];
        address quote = data.quote;
        uint256 fee   = quote == address(0) ? graduationFee : quoteConfig[quote].graduationFee;
        // A quote's fee could be raised after a token locked a lower threshold:
        // cap it so a later config change can never block a graduation. For ETH
        // this never binds (fee <= 0.1 ETH, threshold >= 5 ETH).
        if (fee > data.totalRaised / 10) fee = data.totalRaised / 10;
        if (data.totalRaised <= fee) revert BelowMinimum();
        data.graduated = true;

        uint256 ethForDex = data.totalRaised - fee;
        _creditPlatform(quote, fee);

        uint256 tokensForDex = IERC20(data.tokenAddress).balanceOf(address(this));

        (address pool, uint256 liquidity) = GraduationLib.executeGraduation(
            GraduationLib.GradParams({
                tokenAddress: data.tokenAddress,
                weth:         weth,
                quote:        quote,
                router:       router,
                ethForDex:    ethForDex,
                tokensForDex: tokensForDex
            })
        );

        data.dexPool   = pool;
        data.lpTokenId = liquidity; 

        // Burn remaining tokens
        uint256 remaining = IERC20(data.tokenAddress).balanceOf(address(this));
        if (remaining > 0) IERC20(data.tokenAddress).transfer(DEAD, remaining);

        emit Graduated(
            _tokenId, data.tokenAddress, pool, liquidity,
            ethForDex, tokensForDex, block.timestamp
        );
    }


    // ============================================================
    //  CREATOR FEES
    // ============================================================

    /// @notice Claims accumulated creator fees for a single token.
    function claimCreatorFees(uint256 _tokenId) external nonReentrant validToken(_tokenId) {
        TokenData storage data = tokenData[_tokenId];
        if (msg.sender != data.creator) revert NotCreator();
        uint256 amount = data.creatorFees;
        if (amount == 0) revert NoFees();
        data.creatorFees = 0;
        _send(data.quote, msg.sender, amount);
        emit CreatorFeesClaimed(_tokenId, msg.sender, amount);
    }

    /// @notice Claims creator fees across multiple tokens in one transaction.
    /// @dev    Skips tokens where caller is not creator or fees are zero.
    ///         v3: one batch pays in one quote. The first claimable token sets
    ///         it; tokens in another quote are skipped (claim them separately).
    ///         Max 100 tokens per call to cap gas usage.
    function claimAllCreatorFees(uint256[] calldata _tokenIds) external nonReentrant {
        if (_tokenIds.length == 0) revert EmptyBatch();
        if (_tokenIds.length > 100) revert BatchTooLarge();

        uint256 totalAmount = 0;
        uint256 claimed     = 0;
        address batchQuote;

        for (uint256 i = 0; i < _tokenIds.length; i++) {
            uint256 tokenId = _tokenIds[i];
            if (tokenId == 0 || tokenId > tokenCount) continue;
            TokenData storage data = tokenData[tokenId];
            if (data.creator != msg.sender) continue;
            if (data.creatorFees == 0) continue;
            if (claimed == 0) batchQuote = data.quote;
            else if (data.quote != batchQuote) continue;

            uint256 amount = data.creatorFees;
            data.creatorFees = 0;
            totalAmount += amount;
            claimed++;

            emit CreatorFeesClaimed(tokenId, msg.sender, amount);
        }

        if (totalAmount == 0) revert NoFees();

        _send(batchQuote, msg.sender, totalAmount);

        emit CreatorFeesClaimedAll(msg.sender, totalAmount, claimed);
    }

    // ============================================================
    //  VIEW FUNCTIONS
    // ============================================================

    function getTokenCount() external view returns (uint256) { return tokenCount; }

    function getTokenId(address _tokenAddress) external view returns (uint256) {
        uint256 id = tokenIdByAddress[_tokenAddress];
        if (id == 0) revert TokenNotFound();
        return id;
    }

    // Estimates (estimateBuy, estimateSell, estimateBuyReverse,
    // estimateSellReverse, estimateFirstBuy, estimateFirstBuyReverse) and
    // getTokenInfo now live in MegaPumpLens: same signatures, same results,
    // read from this proxy's public getters. Moved out to free bytecode.

    // ============================================================
    //  ADMIN
    // ============================================================

    /// @notice Withdraws accumulated platform fees to the owner wallet.
    function withdrawPlatformFees() external nonReentrant onlyOwner {
        uint256 amount = platformFeesAccrued;
        if (amount == 0) revert NoFees();
        platformFeesAccrued = 0;
        (bool sent, ) = payable(owner).call{value: amount}("");
        if (!sent) revert ETHTransferFailed();
    }

    /// @notice v3 — withdraws platform fees accrued in an ERC-20 quote.
    function withdrawQuoteFees(address _quote) external nonReentrant onlyOwner {
        uint256 amount = quoteFeesAccrued[_quote];
        if (amount == 0) revert NoFees();
        quoteFeesAccrued[_quote] = 0;
        _send(_quote, owner, amount);
    }

    /// @notice v3 — adds, updates or disables an ERC-20 quote asset.
    /// @dev    Disabling only blocks new tokens: existing ones keep trading and
    ///         graduating with the fee set here. Each token locks the threshold
    ///         at creation. The fee is capped at 10% of the threshold.
    function setQuote(address _quote, bool _enabled, uint256 _graduationAmount, uint256 _graduationFee)
        external onlyOwner
    {
        if (_quote == address(0) || _quote == weth) revert InvalidAddress();
        if (_graduationAmount == 0) revert BelowMinimum();
        if (_graduationFee * 10 > _graduationAmount) revert ExceedsMaxFee();
        quoteConfig[_quote] = QuoteConfig(_enabled, _graduationAmount, _graduationFee);
        emit QuoteUpdated(_quote, _enabled, _graduationAmount, _graduationFee);
    }

    function setPaused(bool _p) external onlyOwner { paused = _p; }

    /// @notice Step 1 of ownership transfer — nominates a new owner.
    function transferOwnership(address _new) external onlyOwner {
        if (_new == address(0)) revert InvalidAddress();
        if (_new == msg.sender) revert InvalidAddress();
        pendingOwner = _new;
        emit OwnershipTransferStarted(owner, _new);
    }

    /// @notice Step 2 of ownership transfer — pending owner confirms.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner        = pendingOwner;
        pendingOwner = address(0);
    }

    /// @notice Cancels a pending ownership transfer.
    function cancelTransferOwnership() external onlyOwner {
        if (pendingOwner == address(0)) revert NoPendingTransfer();
        emit OwnershipTransferCancelled(pendingOwner);
        pendingOwner = address(0);
    }

    function setRouter(address _router) external onlyOwner {
        if (_router == address(0)) revert InvalidAddress();
        router = _router;
    }



    function setGraduationETH(uint256 _amount) external onlyOwner {
        if (_amount < MIN_GRADUATION_ETH) revert BelowMinimum();
        if (_amount > MAX_GRADUATION_ETH) revert AboveMaximum();
        graduationETH = _amount;
    }

    function setWeth(address _weth) external onlyOwner {
        if (_weth == address(0)) revert InvalidAddress();
        weth = _weth;
    }

    function setPlatformFeeBps(uint256 _bps) external onlyOwner {
        if (_bps > MAX_PLATFORM_FEE_BPS) revert ExceedsMaxFee();
        if (_bps <= referrerFeeBps) revert ReferrerFeeExceedsPlatformFee();
        platformFeeBps = _bps;
    }

    function setCreatorFeeBps(uint256 _bps) external onlyOwner {
        if (_bps > MAX_CREATOR_FEE_BPS) revert ExceedsMaxFee();
        creatorFeeBps = _bps;
    }

    /// @notice Sets the referrer fee. Cannot exceed current platformFeeBps.
    function setReferrerFeeBps(uint256 _bps) external onlyOwner {
        if (_bps >= platformFeeBps) revert ReferrerFeeExceedsPlatformFee();
        referrerFeeBps = _bps;
    }

    function setGraduationFee(uint256 _fee) external onlyOwner {
        if (_fee > MAX_GRADUATION_FEE) revert ExceedsMaxFee();
        graduationFee = _fee;
    }

    function setSigner(address _signer) external onlyOwner {
        if (_signer == address(0)) revert InvalidAddress();
        emit SignerUpdated(trustedSigner, _signer);
        trustedSigner = _signer;
    }

    function setTokenCreationCooldown(uint256 _seconds) external onlyOwner {
        if (_seconds > 3600) revert AboveMaximum(); // max 1h
        emit TokenCreationCooldownUpdated(tokenCreationCooldown, _seconds);
        tokenCreationCooldown = _seconds;
    }   
}
