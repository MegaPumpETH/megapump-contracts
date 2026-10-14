// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MegaPumpFactory, TokenNotFound, InvalidAddress, QuoteNotEnabled} from "./MegaPumpFactory.sol";
import {BondingCurveMath} from "./BondingCurveMath.sol";
import {MegaPumpToken} from "./MegaPumpToken.sol";

/// @title  MegaPumpLens — read-only views over the MegaPump factory
/// @author MegaPump
/// @notice Estimates and token snapshots that used to live in MegaPumpFactory.
///         Moved out to keep the factory well under the 24,576-byte EIP-170
///         limit, which leaves room for the upgrades to come.
/// @dev    Stateless and permissionless: no storage besides the immutable
///         factory address, no funds, no admin, no write path. Every function
///         reads the factory's public getters and applies the exact formulas the
///         former in-factory views used, with the same BondingCurveMath library,
///         so results are identical to the wei. Function names, parameters and
///         return types are unchanged: integrations only swap the address.
///
///         v3 (multi-quote): TokenInfo gains `quote` as its last field
///         (address(0) = ETH) and every amount of a token, graduationETH
///         included, is in that token's quote. The estimates on existing tokens
///         need nothing more for that reason. Two functions cover a PENDING
///         token in an ERC-20 quote: estimateFirstBuyQuote and
///         estimateFirstBuyReverseQuote.
///
///         Points at the PROXY, never at an implementation. The proxy address is
///         permanent, so a factory upgrade needs a new Lens only if it changes the
///         fee or curve logic. In that case, deploy a new Lens (one transaction,
///         nothing to migrate) and update its address in the frontend config.
///
///         Nothing on-chain relies on these values. Execution and slippage checks
///         (minTokensOut, minETH) remain enforced by the factory itself.
contract MegaPumpLens {

    /// @notice The MegaPump factory proxy this Lens reads from.
    MegaPumpFactory public immutable factory;

    /// @notice Full snapshot of a token, layout unchanged from the former
    ///         MegaPumpFactory.TokenInfo (same fields, same order, same ABI).
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
        uint256 graduationETH;   // graduation threshold, in quote units since v3
        address quote;           // v3: address(0) = ETH
    }

    constructor(address _factory) {
        if (_factory == address(0)) revert InvalidAddress();
        factory = MegaPumpFactory(payable(_factory));
    }

    // ============================================================
    //  INTERNAL READERS
    // ============================================================

    /// @dev Same check as the factory's validToken modifier, same error.
    function _validToken(uint256 _id) internal view {
        if (_id == 0 || _id > factory.tokenCount()) revert TokenNotFound();
    }

    /// @dev The three fields every estimate needs, from the public tokenData
    ///      getter (15 fields since v3: creator … graduationETH, quote).
    function _curve(uint256 _id)
        internal view returns (address creator, uint256 tokensSold, uint256 gradEth)
    {
        (creator, , , , , , , , tokensSold, , , , , gradEth, ) = factory.tokenData(_id);
    }

    /// @dev Total fee applied to a trade. The creator trading their own token
    ///      pays no creator fee, exactly as in the factory's buy and sell paths.
    function _feeBps(bool _isCreator) internal view returns (uint256) {
        return factory.platformFeeBps() + (_isCreator ? 0 : factory.creatorFeeBps());
    }

    // ============================================================
    //  ESTIMATES — DEPLOYED tokens
    // ============================================================

    /// @notice Estimates tokens received for a given ETH buy amount.
    /// @param _trader Address that will execute the buy. Pass `address(0)`
    ///                to use default fees (non-creator). For accurate
    ///                estimates, pass the actual buyer address.
    function estimateBuy(uint256 _tokenId, uint256 _ethAmount, address _trader)
        external view returns (uint256)
    {
        _validToken(_tokenId);
        (address creator, uint256 tokensSold, uint256 gradEth) = _curve(_tokenId);
        uint256 feeBps = _feeBps(_trader == creator);
        uint256 ethAfterFees = _ethAmount - (_ethAmount * feeBps) / 10000;
        return BondingCurveMath.getTokensForETH(tokensSold, ethAfterFees, gradEth);
    }

    /// @notice Estimates ETH received for a given token sell amount.
    function estimateSell(uint256 _tokenId, uint256 _tokenAmount, address _trader)
        external view returns (uint256)
    {
        _validToken(_tokenId);
        (address creator, uint256 tokensSold, uint256 gradEth) = _curve(_tokenId);
        uint256 feeBps = _feeBps(_trader == creator);
        uint256 ethBefore = BondingCurveMath.getETHForTokens(tokensSold, _tokenAmount, gradEth);
        return ethBefore - (ethBefore * feeBps) / 10000;
    }

    /// @notice ETH to send (fees included) to receive at least `tokensWanted`.
    function estimateBuyReverse(uint256 _tokenId, uint256 _tokensWanted, address _trader)
        external view returns (uint256)
    {
        _validToken(_tokenId);
        (address creator, uint256 tokensSold, uint256 gradEth) = _curve(_tokenId);
        uint256 ethNet = BondingCurveMath.getETHForExactTokens(tokensSold, _tokensWanted, gradEth);
        uint256 feeBps = _feeBps(_trader == creator);
        return (ethNet * 10000 + (10000 - feeBps) - 1) / (10000 - feeBps);
    }

    /// @notice Tokens to sell to receive at least `ethWanted` after fees.
    function estimateSellReverse(uint256 _tokenId, uint256 _ethWanted, address _trader)
        external view returns (uint256)
    {
        _validToken(_tokenId);
        (address creator, uint256 tokensSold, uint256 gradEth) = _curve(_tokenId);
        uint256 feeBps = _feeBps(_trader == creator);
        uint256 ethGross = (_ethWanted * 10000 + (10000 - feeBps) - 1) / (10000 - feeBps);
        return BondingCurveMath.getTokensForExactETH(tokensSold, ethGross, gradEth);
    }

    // ============================================================
    //  ESTIMATES — PENDING tokens (first buy)
    //
    //  A PENDING token has no on-chain state yet (totalRaised = 0,
    //  tokensSold = 0) and will lock the factory's CURRENT global
    //  graduationETH at creation. No tokenId, so the caller states
    //  whether the future buyer is the creator (no creator fee).
    //  No sell estimate: nobody holds a PENDING token.
    // ============================================================

    /// @notice Tokens received for a first buy of `_ethAmount` on any PENDING token.
    function estimateFirstBuy(uint256 _ethAmount, bool _isCreator)
        external view returns (uint256)
    {
        return _firstBuy(factory.graduationETH(), _ethAmount, _isCreator);
    }

    /// @notice v3 — same as estimateFirstBuy for a PENDING token quoted in an
    ///         ERC-20 (`_amount` in quote units).
    function estimateFirstBuyQuote(address _quote, uint256 _amount, bool _isCreator)
        external view returns (uint256)
    {
        return _firstBuy(_quoteThreshold(_quote), _amount, _isCreator);
    }

    /// @dev Threshold a new token in `_quote` would lock at creation. Reverts
    ///      like createAndBuyWithQuote when the quote is unknown or disabled.
    function _quoteThreshold(address _quote) internal view returns (uint256 amount) {
        bool enabled;
        (enabled, amount, ) = factory.quoteConfig(_quote);
        if (!enabled) revert QuoteNotEnabled();
    }

    function _firstBuy(uint256 gradEth, uint256 _ethAmount, bool _isCreator)
        internal view returns (uint256)
    {
        if (_ethAmount == 0) return 0;
        uint256 feeBps = _feeBps(_isCreator);

        // Same defensive cap as the former factory view: mirrors the overflow
        // path of _executeBuy when totalRaised = 0.
        uint256 ethAfterFees = _ethAmount - (_ethAmount * feeBps) / 10000;
        if (ethAfterFees > gradEth) ethAfterFees = gradEth;

        return BondingCurveMath.getTokensForETH(0, ethAfterFees, gradEth);
    }

    /// @notice ETH to send (fees included) to receive at least `_tokensWanted`
    ///         on a first buy.
    function estimateFirstBuyReverse(uint256 _tokensWanted, bool _isCreator)
        external view returns (uint256)
    {
        return _firstBuyReverse(factory.graduationETH(), _tokensWanted, _isCreator);
    }

    /// @notice v3 — same as estimateFirstBuyReverse for an ERC-20 quote.
    function estimateFirstBuyReverseQuote(address _quote, uint256 _tokensWanted, bool _isCreator)
        external view returns (uint256)
    {
        return _firstBuyReverse(_quoteThreshold(_quote), _tokensWanted, _isCreator);
    }

    function _firstBuyReverse(uint256 gradEth, uint256 _tokensWanted, bool _isCreator)
        internal view returns (uint256)
    {
        if (_tokensWanted == 0) return 0;
        uint256 ethNet = BondingCurveMath.getETHForExactTokens(0, _tokensWanted, gradEth);
        uint256 feeBps = _feeBps(_isCreator);
        return (ethNet * 10000 + (10000 - feeBps) - 1) / (10000 - feeBps);
    }

    // ============================================================
    //  SNAPSHOT
    // ============================================================

    /// @notice Returns a full snapshot of a token's on-chain state.
    function getTokenInfo(uint256 _tokenId) external view returns (TokenInfo memory info) {
        _validToken(_tokenId);
        (
            info.creator,
            info.name,
            info.ticker,
            info.metadataURI,
            ,                   // createdBlock
            info.createdAt,
            info.tokenAddress,
            info.totalRaised,
            info.tokensSold,
            info.creatorFees,
            info.graduated,
            info.dexPool,
            ,                   // lpTokenId
            info.graduationETH,
            info.quote
        ) = factory.tokenData(_tokenId);

        // v3: name, ticker and metadata URI are no longer stored in tokenData;
        // they live on the token contract, deployed at creation.
        if (bytes(info.name).length == 0 && info.tokenAddress != address(0)) {
            MegaPumpToken t = MegaPumpToken(info.tokenAddress);
            info.name        = t.name();
            info.ticker      = t.symbol();
            info.metadataURI = t.metadataURI();
        }

        info.currentPrice    = BondingCurveMath.getCurrentPrice(info.tokensSold, info.graduationETH);
        info.marketCap       = BondingCurveMath.getMarketCap(info.tokensSold, info.graduationETH);
        info.bondingProgress = info.graduated ? 10000 : (info.totalRaised * 10000) / info.graduationETH;
        info.deployed        = info.tokenAddress != address(0);
    }
}
