// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/MegaPumpFactory.sol";


contract UpgradeMegaPump is Script {
    function run() external {
        vm.startBroadcast();
        MegaPumpFactory newImplementation = new MegaPumpFactory();
        vm.stopBroadcast();

        console.log("==============================================");
        console.log("  New Implementation Deployed");
        console.log("==============================================");
        console.log("Address:", address(newImplementation));
    }
}