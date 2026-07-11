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

/// @title  MegaPumpFactory — Memecoin launchpad on MegaETH (UUPS Upgradeable)
/// @author MegaPump
/// @notice Free token creation, bonding curve pricing, automatic graduation.
/// @dev    Storage layout is append-only — never remove or reorder existing variables.
///         Add new variables only at the END of the storage section on upgrades.
///
/// Security highlights:
/// - ReentrancyGuard on all fund-moving functions (buy, sell, claims, withdraw)
/// - Solidity 0.8.24 native overflow / underflow protection
/// - Checks-Effects-Interactions pattern throughout
/// - Slippage protection on buy and sell (anti-sandwich / front-running)
/// - Anti-snipe window on first N blocks after creation
/// - All prices computed on-chain — no external oracle
contract MegaPumpFactory is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable {


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
        uint256 graduationETH; // ← locked at creation
    }

    struct TokenInfo {
        address creator;
        string  name;
        string  ticker;
        string  metadataURI;
        address tokenAddress;
        uint256 totalRaised;
        uint256 tokensSold;
        uint256 creatorFees;
        bool    graduated;
        address dexPool;
        uint256 createdAt;
        uint256 currentPrice;
        uint256 marketCap;
        uint256 bondingProgress; // basis points (0–10000)
        bool    deployed;
        uint256 graduationETH;
    }

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
    /// @param _signature   EIP-712 signature by _creator over the above fields
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
        if (bytes(_name).length == 0 || bytes(_name).length > 32) revert InvalidName();
        if (bytes(_ticker).length == 0 || bytes(_ticker).length > 10) revert InvalidTicker();
        if (msg.value == 0) revert NoETH();
        if (_creator == address(0)) revert InvalidAddress();

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
        if (msg.sender != _creator) {
            // ── Third-party path: require valid EIP-712 signature ──
            if (block.timestamp > _deadline) revert SignatureExpired();

            bytes32 sigHash = keccak256(_signature);
            if (usedSignatures[sigHash]) revert SignatureAlreadyUsed();
            usedSignatures[sigHash] = true;

            bytes32 structHash = keccak256(abi.encode(
                CREATE_TYPEHASH,
                _creator,
                keccak256(bytes(_name)),
                keccak256(bytes(_ticker)),
                keccak256(bytes(_metadataURI)),
                _deadline,
                _nonce
            ));
            bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
            address recovered = ECDSA.recover(digest, _signature);
            if (recovered != _creator) revert InvalidSignature();
        }
        // Else: msg.sender == _creator. Self-create. Tx signature is proof enough.

        // ── 3. Cooldown check on the CREATOR (not msg.sender) ────
        uint256 last = lastTokenCreatedAt[_creator];
        if (last != 0 && block.timestamp - last < tokenCreationCooldown) {
            revert CreationCooldown(tokenCreationCooldown - (block.timestamp - last));
        }
        lastTokenCreatedAt[_creator] = block.timestamp;

        // ── 4. Create the token slot with creator = signer ───────
        tokenCount++;
        tokenData[tokenCount] = TokenData({
            creator: _creator,
            name: _name,
            ticker: _ticker,
            metadataURI: _metadataURI,
            createdBlock: block.number,
            createdAt: block.timestamp,
            tokenAddress: address(0),
            totalRaised: 0,
            tokensSold: 0,
            creatorFees: 0,
            graduated: false,
            dexPool: address(0),
            lpTokenId: 0,
            graduationETH: graduationETH
        });

        emit TokenCreated(
            tokenCount, _name, _ticker, _metadataURI,
            _creator, keccak256(_signature), block.timestamp
        );

        // ── 5. Execute the first buy ────
        _executeBuy(tokenCount, _minTokensOut, _referrer, _referrerSig);

        return tokenCount;
    }

    // ============================================================
    //  BUY
    // ============================================================

    /// @param _referrer Referrer address from backend — address(0) if none.
    function buy(uint256 _tokenId, uint256 _minTokensOut, address _referrer, bytes calldata _referrerSig)
        external payable nonReentrant notPaused validToken(_tokenId) notGraduated(_tokenId)
    { _executeBuy(_tokenId, _minTokensOut, _referrer, _referrerSig); }


    function _executeBuy(
        uint256 _tokenId,
        uint256 _minTokensOut,
        address _referrer,
        bytes calldata _referrerSig
    ) internal {
        if (msg.value == 0) revert NoETH();
        TokenData storage data = tokenData[_tokenId];

        // Deploy ERC-20 on first buy (deferred deployment)
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
            // Tentative net based on full msg.value
            uint256 fullFee     = (msg.value * totalFeeBps) / 10000;
            uint256 fullNet     = msg.value - fullFee;
            uint256 raisedAfter = data.totalRaised + fullNet;

            if (raisedAfter <= data.graduationETH) {
                // No overflow → consume the full amount
                ethGrossUsed   = msg.value;
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

                // Edge guard: if rounding made ethGrossUsed > msg.value, cap to msg.value.
                // Should never happen with sane inputs but defensive.
                if (ethGrossUsed > msg.value) {
                    ethGrossUsed   = msg.value;
                    // Recompute final net consistently
                    uint256 finalFee = (ethGrossUsed * totalFeeBps) / 10000;
                    ethNetForCurve  = ethGrossUsed - finalFee;
                }
            }
        }

        uint256 ethRefund = msg.value - ethGrossUsed;

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
            referrerFees[effectiveReferrer] += refFee;
        }

        // ════════════════════════════════════════════════════════════════
        //  STEP 4 — State updates BEFORE external calls (CEI strict)
        // ════════════════════════════════════════════════════════════════

        data.totalRaised    += ethNetForCurve;
        data.tokensSold     += tokensOut;
        data.creatorFees    += creatorFee;
        platformFeesAccrued += platformFeeFull - refFee;

        // ════════════════════════════════════════════════════════════════
        //  STEP 5 — External calls: token transfer, then refund, then grad
        //  Order matters: refund MUST happen before _graduate() because
        //  _graduate() drains totalRaised to the DEX pool.
        // ════════════════════════════════════════════════════════════════

        IERC20(data.tokenAddress).transfer(msg.sender, tokensOut);

        if (ethRefund > 0) {
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
            referrerFees[effectiveReferrer] += refFee;
        }

        // Compute real creator fee (0 if creator selling)
        uint256 creatorFee = isCreatorSelling ? 0 : (ethOut * creatorFeeBps) / 10000;

        // State updates BEFORE transfers (Checks-Effects-Interactions)
        data.totalRaised    -= ethOut;
        data.tokensSold     -= _tokenAmount;
        data.creatorFees    += creatorFee;
        platformFeesAccrued += grossPlatformFee - refFee;

        IERC20(data.tokenAddress).transferFrom(msg.sender, address(this), _tokenAmount);
        (bool sent, ) = payable(msg.sender).call{value: ethToSeller}("");
        if (!sent) revert ETHTransferFailed();

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
        address recovered = ECDSA.recover(ethHash, _sig);

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
        if (data.totalRaised <= graduationFee) revert BelowMinimum();
        data.graduated = true;

        uint256 ethForDex    = data.totalRaised - graduationFee;
        platformFeesAccrued += graduationFee;

        uint256 tokensForDex = IERC20(data.tokenAddress).balanceOf(address(this));

        (address pool, uint256 liquidity) = GraduationLib.executeGraduation(
            GraduationLib.GradParams({
                tokenAddress: data.tokenAddress,
                weth:         weth,
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
        (bool sent, ) = payable(msg.sender).call{value: amount}("");
        if (!sent) revert ETHTransferFailed();
        emit CreatorFeesClaimed(_tokenId, msg.sender, amount);
    }

    /// @notice Claims creator fees across multiple tokens in one transaction.
    /// @dev    Skips tokens where caller is not creator or fees are zero.
    ///         Max 100 tokens per call to cap gas usage.
    function claimAllCreatorFees(uint256[] calldata _tokenIds) external nonReentrant {
        if (_tokenIds.length == 0) revert EmptyBatch();
        if (_tokenIds.length > 100) revert BatchTooLarge();

        uint256 totalAmount = 0;
        uint256 claimed     = 0;

        for (uint256 i = 0; i < _tokenIds.length; i++) {
            uint256 tokenId = _tokenIds[i];
            if (tokenId == 0 || tokenId > tokenCount) continue;
            TokenData storage data = tokenData[tokenId];
            if (data.creator != msg.sender) continue;
            if (data.creatorFees == 0) continue;

            uint256 amount = data.creatorFees;
            data.creatorFees = 0;
            totalAmount += amount;
            claimed++;

            emit CreatorFeesClaimed(tokenId, msg.sender, amount);
        }

        if (totalAmount == 0) revert NoFees();

        (bool sent, ) = payable(msg.sender).call{value: totalAmount}("");
        if (!sent) revert ETHTransferFailed();

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

    /// @notice Estimates tokens received for a given ETH buy amount.
    /// @param _trader Address that will execute the buy. Pass `address(0)`
    ///                to use default fees (non-creator). For accurate
    ///                estimates, pass the actual buyer address.
    function estimateBuy(uint256 _tokenId, uint256 _ethAmount, address _trader)
        external view validToken(_tokenId) returns (uint256)
    {
        bool isCreator = _trader == tokenData[_tokenId].creator;
        uint256 feeBps = platformFeeBps + (isCreator ? 0 : creatorFeeBps);
        uint256 ethAfterFees = _ethAmount - (_ethAmount * feeBps) / 10000;
        return BondingCurveMath.getTokensForETH(
            tokenData[_tokenId].tokensSold,
            ethAfterFees,
            tokenData[_tokenId].graduationETH
        );
    }

    /// @notice Estimates ETH received for a given token sell amount.
    function estimateSell(uint256 _tokenId, uint256 _tokenAmount, address _trader)
        external view validToken(_tokenId) returns (uint256)
    {
        bool isCreator = _trader == tokenData[_tokenId].creator;
        uint256 feeBps = platformFeeBps + (isCreator ? 0 : creatorFeeBps);
        uint256 ethBefore = BondingCurveMath.getETHForTokens(
            tokenData[_tokenId].tokensSold,
            _tokenAmount,
            tokenData[_tokenId].graduationETH
        );
        return ethBefore - (ethBefore * feeBps) / 10000;
    }

    /// @notice ETH to send (fees included) to receive at least `tokensWanted`.
    function estimateBuyReverse(uint256 _tokenId, uint256 _tokensWanted, address _trader)
        external view validToken(_tokenId) returns (uint256)
    {
        uint256 ethNet = BondingCurveMath.getETHForExactTokens(
            tokenData[_tokenId].tokensSold,
            _tokensWanted,
            tokenData[_tokenId].graduationETH
        );
        bool isCreator = _trader == tokenData[_tokenId].creator;
        uint256 feeBps = platformFeeBps + (isCreator ? 0 : creatorFeeBps);
        return (ethNet * 10000 + (10000 - feeBps) - 1) / (10000 - feeBps);
    }

    /// @notice Tokens to sell to receive at least `ethWanted` after fees.
    function estimateSellReverse(uint256 _tokenId, uint256 _ethWanted, address _trader)
        external view validToken(_tokenId) returns (uint256)
    {
        bool isCreator = _trader == tokenData[_tokenId].creator;
        uint256 feeBps = platformFeeBps + (isCreator ? 0 : creatorFeeBps);
        uint256 ethGross = (_ethWanted * 10000 + (10000 - feeBps) - 1) / (10000 - feeBps);
        return BondingCurveMath.getTokensForExactETH(
            tokenData[_tokenId].tokensSold,
            ethGross,
            tokenData[_tokenId].graduationETH
        );
    }


    // ════════════════════════════════════════════════════════════════
    //  FIRST-BUY ESTIMATES (PENDING tokens — no on-chain state yet)
    //
    //  Used by the frontend to estimate the first buy of a PENDING token.
    //  PENDING tokens have no on-chain state (totalRaised=0, tokensSold=0),
    //  which makes the math deterministic and independent of any tokenId.
    //
    //  Sell estimates are intentionally omitted: a PENDING token has no
    //  minted supply, so no one can hold tokens to sell.
    //
    //  The _isCreator flag is required because the contract has no tokenId
    //  to look up the creator from — the frontend must indicate explicitly
    //  whether the caller is the future creator (no creator fee) or a
    //  third-party first-buyer (full fees).
    // ════════════════════════════════════════════════════════════════

    /// @notice Tokens received for a first buy of `_ethAmount` on any PENDING
    ///         token. Mirrors the `estimateBuy` API for tokens that don't
    ///         exist on-chain yet.
    function estimateFirstBuy(uint256 _ethAmount, bool _isCreator)
        external view returns (uint256)
    {
        if (_ethAmount == 0) return 0;
        uint256 feeBps = platformFeeBps + (_isCreator ? 0 : creatorFeeBps);

        // Cap ethAfterFees defensively to graduationETH. Mirrors the overflow
        // path of _executeBuy for the first-buy case where totalRaised=0.
        // This guarantees we never feed an absurd input into the curve math.
        uint256 ethAfterFees = _ethAmount - (_ethAmount * feeBps) / 10000;
        if (ethAfterFees > graduationETH) ethAfterFees = graduationETH;

        return BondingCurveMath.getTokensForETH(0, ethAfterFees, graduationETH);
    }

    /// @notice ETH to send (fees included) to receive at least `_tokensWanted`
    ///         on a first buy. Mirrors `estimateBuyReverse`.
    function estimateFirstBuyReverse(uint256 _tokensWanted, bool _isCreator)
        external view returns (uint256)
    {
        if (_tokensWanted == 0) return 0;
        uint256 ethNet = BondingCurveMath.getETHForExactTokens(
            0,                  // tokensSold = 0 for PENDING
            _tokensWanted,
            graduationETH
        );
        uint256 feeBps = platformFeeBps + (_isCreator ? 0 : creatorFeeBps);
        return (ethNet * 10000 + (10000 - feeBps) - 1) / (10000 - feeBps);
}

    /// @notice Returns a full snapshot of a token's on-chain state.
    function getTokenInfo(uint256 _tokenId) external view validToken(_tokenId)
        returns (TokenInfo memory info)
    {
        TokenData storage d = tokenData[_tokenId];
        info.creator         = d.creator;
        info.name            = d.name;
        info.ticker          = d.ticker;
        info.metadataURI     = d.metadataURI;
        info.tokenAddress    = d.tokenAddress;
        info.totalRaised     = d.totalRaised;
        info.tokensSold      = d.tokensSold;
        info.creatorFees     = d.creatorFees;
        info.graduated       = d.graduated;
        info.dexPool         = d.dexPool;
        info.createdAt       = d.createdAt;
        info.currentPrice    = BondingCurveMath.getCurrentPrice(d.tokensSold, d.graduationETH);
        info.marketCap       = BondingCurveMath.getMarketCap(d.tokensSold, d.graduationETH);
        info.bondingProgress = d.graduated ? 10000 : (d.totalRaised * 10000) / d.graduationETH;
        info.deployed        = d.tokenAddress != address(0);
        info.graduationETH   = d.graduationETH;
    }


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
