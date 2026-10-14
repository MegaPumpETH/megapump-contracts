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
        console.log("");
        console.log("GraduationLib is a linked library: forge deployed it in this run,");
        console.log("just before the implementation (two transactions).");
        console.log("");
        console.log("Next, in this order (v3):");
        console.log(" 1. upgradeToAndCall(<address above>, 0x) from the owner.");
        console.log(" 2. script/DeployLens.s.sol on the proxy: Lens v3 reads the v3");
        console.log("    tokenData, so it comes AFTER the upgrade. The previous Lens");
        console.log("    keeps working meanwhile.");
        console.log(" 3. New Lens address in lib/chains.ts, then node sync-abi.js.");
        console.log("ERC-20 quotes stay off until setQuote (script/SetQuote.s.sol).");
    }
}