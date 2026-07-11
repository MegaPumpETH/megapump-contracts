// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/MegaPumpAddresses.sol";

/// @notice Wrapper qui expose la lib via des fonctions external.
contract AddressesHarness {
    function get(uint256 chainId) external pure returns (MegaPumpAddresses.ChainConfig memory) {
        return MegaPumpAddresses.get(chainId);
    }

    function current() external view returns (MegaPumpAddresses.ChainConfig memory) {
        return MegaPumpAddresses.current();
    }
}

contract MegaPumpAddressesTest is Test {
    AddressesHarness harness;

    function setUp() public {
        harness = new AddressesHarness();
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 1 — Mainnet (4326) returns the deployed addresses
    // ════════════════════════════════════════════════════════════
    function test_Get_Mainnet_ReturnsDeployedAddresses() public view {
        MegaPumpAddresses.ChainConfig memory cfg = harness.get(4326);

        assertEq(
            cfg.router,
            0xB24563A4ecF250C8238e41DF0af51D97734c1ec5,
            "mainnet router (DEX V2)"
        );
        assertEq(
            cfg.dexFactory,
            0x4188aDbFfBec026EdE44F2C3A7E22beDD880a46f,
            "mainnet dexFactory (DEX V2)"
        );
        assertEq(cfg.weth, 0x4200000000000000000000000000000000000006, "mainnet weth");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 2 — Testnet (6343) returns correct addresses
    // ════════════════════════════════════════════════════════════
    function test_Get_Testnet() public view {
        MegaPumpAddresses.ChainConfig memory cfg = harness.get(6343);

        assertEq(
            cfg.router,
            0x5044A9b3dBB09614F98B35Ea610F5a11FB3A473F,
            "testnet router (DEX V2)"
        );
        assertEq(
            cfg.dexFactory,
            0xaE2Fb05d477a50d54EC185Fd730971A998f46a51,
            "testnet dexFactory (DEX V2)"
        );
        assertEq(cfg.weth, 0x4200000000000000000000000000000000000006, "testnet weth");
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 3 — Unsupported chain reverts
    // ════════════════════════════════════════════════════════════
    function test_Get_UnsupportedChain_Reverts() public {
        vm.expectRevert();
        harness.get(999999);
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 4 — Ethereum mainnet (1) is NOT supported, reverts
    // ════════════════════════════════════════════════════════════
    function test_Get_EthereumMainnet_Reverts() public {
        vm.expectRevert();
        harness.get(1);
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 5 — current() uses block.chainid (testnet)
    // ════════════════════════════════════════════════════════════
    function test_Current_FollowsBlockChainId() public {
        vm.chainId(6343);
        MegaPumpAddresses.ChainConfig memory testnetCfg = harness.current();
        assertEq(
            testnetCfg.router,
            0x5044A9b3dBB09614F98B35Ea610F5a11FB3A473F,
            "current() picks testnet router on chainid 6343"
        );
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 6 — current() picks mainnet config on chainid 4326
    // ════════════════════════════════════════════════════════════
    function test_Current_MainnetChainId_ReturnsConfig() public {
        vm.chainId(4326);
        MegaPumpAddresses.ChainConfig memory mainnetCfg = harness.current();
        assertEq(
            mainnetCfg.router,
            0xB24563A4ecF250C8238e41DF0af51D97734c1ec5,
            "current() picks mainnet router on chainid 4326"
        );
    }

    // ════════════════════════════════════════════════════════════
    //  TEST 7 — current() reverts on unsupported chain
    // ════════════════════════════════════════════════════════════
    function test_Current_UnsupportedChain_Reverts() public {
        vm.chainId(12345);
        vm.expectRevert();
        harness.current();
    }
}