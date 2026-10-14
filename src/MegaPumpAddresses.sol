// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MegaPumpAddresses
/// @notice Single source of truth for on-chain addresses, per chain.
///
///         Addresses are selected automatically via block.chainid, which makes
///         it IMPOSSIBLE to deploy with the wrong addresses: the chainid comes
///         from the EVM itself, not from an environment variable that could be
///         copied incorrectly.
///
library MegaPumpAddresses {
    // ─── Chain IDs ──────────────────────────────────────────
    uint256 internal constant MEGAETH_MAINNET = 4326;
    uint256 internal constant MEGAETH_TESTNET = 6343;

    struct ChainConfig {
        address router;  
        address dexFactory;
        address weth;
        string  name;
    }
    /// @notice Returns the config for the current chain (via block.chainid).
    /// @dev Reverts if the chain is not supported — safe by default.
    function current() internal view returns (ChainConfig memory) {
        return get(block.chainid);
    }

    /// @notice Returns the config for a given chainId.
    /// @dev Reverts if the chain is not supported.
    function get(uint256 chainId) internal pure returns (ChainConfig memory cfg) {
        if (chainId == MEGAETH_MAINNET) {
            cfg = ChainConfig({
                router: 0xB24563A4ecF250C8238e41DF0af51D97734c1ec5,
                dexFactory: 0x4188aDbFfBec026EdE44F2C3A7E22beDD880a46f,
                weth:   0x4200000000000000000000000000000000000006,
                name:   "MegaETH Mainnet"
            });
        } else if (chainId == MEGAETH_TESTNET) {
            cfg = ChainConfig({
                router: 0x5044A9b3dBB09614F98B35Ea610F5a11FB3A473F,
                dexFactory: 0xaE2Fb05d477a50d54EC185Fd730971A998f46a51,
                weth:   0x4200000000000000000000000000000000000006,
                name:   "MegaETH Testnet"
            });
        } else {
            revert(string(abi.encodePacked(
                "MegaPumpAddresses: unsupported chainId ",
                _toString(chainId)
            )));
        }

        // ─── Safety guard: addresses MUST be configured ───
        require(cfg.router != address(0), "MegaPumpAddresses: router not set for this chain");
        require(cfg.weth   != address(0), "MegaPumpAddresses: weth not set for this chain");
        require(cfg.dexFactory != address(0), "MegaPumpAddresses: dexFactory not set for this chain");
    }

    function _toString(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}