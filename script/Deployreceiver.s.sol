// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {MessagingReceiver} from "../src/MessageReceiver.sol";
import {SupportedNetworks} from "./utils/SupportedNetworks.sol";

/// @notice Deploys and configures MessagingReceiver on one of the 5 supported testnets.
///
/// Prerequisites:
///   1. Set LOCAL_CCIP_ROUTER in your .env for the target chain
///   2. Set sender addresses (optional) per source chain:
///      SEPOLIA_SENDER_CONTRACT, AMOY_SENDER_CONTRACT, ARBITRUM_SEPOLIA_SENDER_CONTRACT,
///      BASE_SEPOLIA_SENDER_CONTRACT, OP_SEPOLIA_SENDER_CONTRACT
///   3. Import your deployer key: cast wallet import deployer --interactive
///
/// Simulate:
///   forge script script/Deployreceiver.s.sol --rpc-url amoy
///
/// Deploy:
///   forge script script/Deployreceiver.s.sol \
///     --rpc-url amoy \
///     --account deployer \
///     --broadcast \
///     -vvvv
contract DeployReceiver is Script {
    function run() public returns (MessagingReceiver receiverContract) {
        require(
            SupportedNetworks.isSupportedChainId(block.chainid),
            "Unsupported chain: use Sepolia/Amoy/Arb Sepolia/Base Sepolia/OP Sepolia"
        );

        uint64 localSelector = SupportedNetworks.selectorByChainId(block.chainid);
        string memory networkName = SupportedNetworks.nameByChainId(block.chainid);
        address localRouter = vm.envAddress("LOCAL_CCIP_ROUTER");

        console.log("Deploying MessagingReceiver on", networkName);
        console.log("Chain ID:      ", block.chainid);
        console.log("Chain selector:", localSelector);

        vm.startBroadcast();

        receiverContract = new MessagingReceiver(localRouter);

        // Allowlist all supported source chains except this chain.
        uint64[5] memory selectors = SupportedNetworks.allSelectors();
        for (uint256 i = 0; i < selectors.length; i++) {
            if (selectors[i] != localSelector) {
                receiverContract.allowlistSourceChain(selectors[i], true);

                address senderForSource = _senderBySelector(selectors[i]);
                if (senderForSource != address(0)) {
                    receiverContract.allowlistSender(selectors[i], senderForSource, true);
                }
            }
        }

        vm.stopBroadcast();

        require(receiverContract.getRouter() == localRouter, "router mismatch");

        console.log("=============================================");
        console.log("MessagingReceiver deployed at:", address(receiverContract));
        console.log("Router:                     ", localRouter);
        console.log("=============================================");
        console.log("Source chain allowlist configured for selectors:");
        for (uint256 i = 0; i < selectors.length; i++) {
            if (selectors[i] != localSelector) {
                console.log("- ", selectors[i]);
            }
        }
        console.log("Configured sender addresses (if provided in env):");
        for (uint256 i = 0; i < selectors.length; i++) {
            if (selectors[i] != localSelector) {
                address senderForSource = _senderBySelector(selectors[i]);
                if (senderForSource != address(0)) {
                    console.log("- selector", selectors[i], "sender", senderForSource);
                }
            }
        }
    }

    function _senderBySelector(uint64 selector) internal view returns (address) {
        if (selector == SupportedNetworks.ETHEREUM_SEPOLIA_SELECTOR) {
            return vm.envOr("SEPOLIA_SENDER_CONTRACT", address(0));
        }
        if (selector == SupportedNetworks.POLYGON_AMOY_SELECTOR) {
            return vm.envOr("AMOY_SENDER_CONTRACT", address(0));
        }
        if (selector == SupportedNetworks.ARBITRUM_SEPOLIA_SELECTOR) {
            return vm.envOr("ARBITRUM_SEPOLIA_SENDER_CONTRACT", address(0));
        }
        if (selector == SupportedNetworks.BASE_SEPOLIA_SELECTOR) {
            return vm.envOr("BASE_SEPOLIA_SENDER_CONTRACT", address(0));
        }
        if (selector == SupportedNetworks.OP_SEPOLIA_SELECTOR) {
            return vm.envOr("OP_SEPOLIA_SENDER_CONTRACT", address(0));
        }
        return address(0);
    }
}
