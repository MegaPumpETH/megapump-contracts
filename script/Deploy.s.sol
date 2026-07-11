// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/MegaPumpFactory.sol";
import "../src/MegaPumpAddresses.sol";


interface IDexFactory {
    function setPairCreator(address) external;
    function pairCreator() external view returns (address);
}

contract DeployMegaPump is Script {
    function run() external {

        MegaPumpAddresses.ChainConfig memory cfg = MegaPumpAddresses.current();

        require(
            cfg.router.code.length > 0,
            "Router has no code on this chain"
        );
        require(
            cfg.weth.code.length > 0,
            "WETH has no code on this chain"
        );

        console.log("==============================================");
        console.log("   Deploying MegaPump on:", cfg.name);
        console.log("   Chain ID:", block.chainid);
        console.log("   Router (DEX V2):", cfg.router);
        console.log("   WETH:", cfg.weth);
        console.log("==============================================");

        if (block.chainid == MegaPumpAddresses.MEGAETH_MAINNET) {
            console.log("");
            console.log("   !!! MAINNET DEPLOYMENT !!!");
            console.log("");
        }

        vm.startBroadcast();

        MegaPumpFactory implementation = new MegaPumpFactory();

        bytes memory initData = abi.encodeWithSelector(
            MegaPumpFactory.initialize.selector,
            cfg.router,
            cfg.weth
        );

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );

        IDexFactory(cfg.dexFactory).setPairCreator(address(proxy));

        vm.stopBroadcast();

        require(
            IDexFactory(cfg.dexFactory).pairCreator() == address(proxy),
            "setPairCreator FAILED - graduations would be blocked"
        );

        MegaPumpFactory factory = MegaPumpFactory(payable(address(proxy)));
        console.log("==============================================");
        console.log("   MegaPump UUPS Proxy Deployed");
        console.log("==============================================");
        console.log("PROXY (permanent address) :", address(proxy));
        console.log("Implementation v1          :", address(implementation));
        console.log("Owner                      :", factory.owner());
        console.log("Router (DEX V2)            :", factory.router());
        console.log("WETH                       :", factory.weth());
        console.log("Graduation ETH             :", factory.graduationETH() / 1e18, "ETH");
        console.log("==============================================");
    }
}