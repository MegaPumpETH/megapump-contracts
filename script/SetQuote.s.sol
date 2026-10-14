// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../src/MegaPumpFactory.sol";

/// @notice Adds, updates or disables an ERC-20 quote (USDm, MEGA...) on the factory.
/// @dev    Amounts are given in WHOLE units (13400 = 13,400 USDm). The script reads
///         the quote's decimals on-chain and scales them, so a forgotten 1e18 can
///         never lock a dust threshold into new tokens.
///
///         Only the factory owner can apply it. When the broadcaster is not the
///         owner (a Safe on mainnet), nothing is sent: the script prints the
///         calldata to submit from the owner instead.
///
///         Usage:
///           forge script script/SetQuote.s.sol:SetQuote \
///             --sig "run(address,address,bool,uint256,uint256)" \
///             <PROXY> <QUOTE> true <THRESHOLD_WHOLE> <FEE_WHOLE> \
///             --rpc-url <RPC> --account <KEYSTORE> --sender <ADDRESS> --broadcast
///         Disable (existing tokens keep trading and graduating):
///           same with `false` and the current threshold and fee.
contract SetQuote is Script {
    function run(address proxy, address quote, bool enabled, uint256 thresholdWhole, uint256 feeWhole)
        external
    {
        MegaPumpFactory factory = MegaPumpFactory(payable(proxy));
        require(factory.CURVE_SUPPLY() == 800_000_000 * 1e18, "Not a MegaPump factory");
        try factory.CREATE_QUOTE_TYPEHASH() returns (bytes32) {} catch {
            revert("Proxy not on v3 yet: upgrade it first");
        }
        require(quote.code.length > 0, "No contract at the quote address on this chain");

        uint8 dec = IERC20Metadata(quote).decimals();
        uint256 unit = 10 ** uint256(dec);
        uint256 threshold = thresholdWhole * unit;
        uint256 fee = feeWhole * unit;
        require(fee * 10 <= threshold, "Fee above 10% of the threshold: the contract refuses it");

        bytes memory data = abi.encodeCall(MegaPumpFactory.setQuote, (quote, enabled, threshold, fee));

        console.log("==============================================");
        console.log("  setQuote");
        console.log("==============================================");
        console.log("Chain ID         :", block.chainid);
        console.log("Factory proxy    :", proxy);
        console.log("Quote            :", quote);
        console.log("Symbol           :", IERC20Metadata(quote).symbol());
        console.log("Decimals         :", uint256(dec));
        console.log("Enabled          :", enabled);
        console.log("Threshold (whole):", thresholdWhole);
        console.log("Fee (whole)      :", feeWhole);
        console.log("Calldata (to the proxy, value 0):");
        console.logBytes(data);

        vm.startBroadcast();
        (, address sender, ) = vm.readCallers();
        if (sender != factory.owner()) {
            vm.stopBroadcast();
            console.log("");
            console.log("Broadcaster is not the owner:", sender);
            console.log("Owner is:", factory.owner());
            console.log("Nothing sent. Submit the calldata above from the owner.");
            return;
        }
        factory.setQuote(quote, enabled, threshold, fee);
        vm.stopBroadcast();

        (bool e, uint256 a, uint256 f) = factory.quoteConfig(quote);
        require(e == enabled && a == threshold && f == fee, "setQuote not applied");
        console.log("Applied. New tokens in this quote lock this threshold at creation.");
    }
}
