// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/MegaPumpFactory.sol";
import "../src/MegaPumpLens.sol";

/// @notice Deploys MegaPumpLens next to an EXISTING MegaPump proxy.
/// @dev    v3: the Lens decodes the v3 tokenData getter (15 fields, quote
///         last), so the proxy must already run v3: deploy it right AFTER the
///         upgrade. The previous Lens keeps answering until the frontend
///         switches (same numbers, names empty for tokens created in v3).
///         No owner, no Safe needed.
///
///         Usage (pass the PROXY, never an implementation):
///           forge script script/DeployLens.s.sol --sig "run(address)" <PROXY> \
///             --rpc-url <RPC> --broadcast
///         MegaETH: add --gas-estimate-multiplier 10000 as for every deployment.
contract DeployLens is Script {
    function run(address proxy) external {
        require(proxy.code.length > 0, "No contract at this address on this chain");

        // Sanity: this must be a MegaPump factory, not an implementation or
        // an unrelated contract. CURVE_SUPPLY is a constant every version has.
        MegaPumpFactory factory = MegaPumpFactory(payable(proxy));
        require(factory.CURVE_SUPPLY() == 800_000_000 * 1e18, "Not a MegaPump factory");
        try factory.CREATE_QUOTE_TYPEHASH() returns (bytes32) {} catch {
            revert("Proxy not on v3 yet: upgrade it first, this Lens reads the v3 tokenData");
        }

        vm.startBroadcast();
        MegaPumpLens lens = new MegaPumpLens(proxy);
        vm.stopBroadcast();

        require(address(lens.factory()) == proxy, "Lens wired to the wrong factory");

        console.log("==============================================");
        console.log("  MegaPumpLens Deployed");
        console.log("==============================================");
        console.log("Chain ID       :", block.chainid);
        console.log("Factory proxy  :", proxy);
        console.log("Lens           :", address(lens));
        console.log("Next: set this Lens address in the frontend (lib/chains.ts)");
        console.log("and verify it on the explorer.");
        console.log("==============================================");
    }
}
