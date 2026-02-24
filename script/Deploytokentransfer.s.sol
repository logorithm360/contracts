// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {SupportedNetworks} from "./utils/SupportedNetworks.sol";
import {TokenTransferSender} from "../src/TokenTransferSender.sol";
import {TokenTransferReceiver} from "../src/TokenTransferReceiver.sol";

/// @notice Deploys and configures TokenTransferSender on one of the 5 supported testnets.
///
/// Prerequisites:
///   1. Set LOCAL_CCIP_ROUTER and LOCAL_LINK_TOKEN for the source chain
///   2. (Optional) set LOCAL_CCIP_BNM_TOKEN and LOCAL_CCIP_LNM_TOKEN to pre-allowlist
///   3. (Optional) set TOKEN_TRANSFER_DESTINATION_GAS_LIMIT (default 0; set >0 for contract receivers)
///
/// Run (dry-run):
///   forge script script/Deploytokentransfer.s.sol:DeployTokenSender --rpc-url sepolia
///
/// Run (broadcast):
///   forge script script/Deploytokentransfer.s.sol:DeployTokenSender \
///     --rpc-url sepolia \
///     --account deployer \
///     --broadcast \
///     -vvvv
contract DeployTokenSender is Script {
    function run() public returns (TokenTransferSender senderContract) {
        require(
            SupportedNetworks.isSupportedChainId(block.chainid),
            "Unsupported chain: use Sepolia/Amoy/Arb Sepolia/Base Sepolia/OP Sepolia"
        );

        uint64 localSelector = SupportedNetworks.selectorByChainId(block.chainid);
        string memory networkName = SupportedNetworks.nameByChainId(block.chainid);

        address localRouter = vm.envAddress("LOCAL_CCIP_ROUTER");
        address localLink = vm.envAddress("LOCAL_LINK_TOKEN");
        bool payInLink = vm.envOr("PAY_FEES_IN_LINK", true);
        uint256 destinationGasLimit = vm.envOr("TOKEN_TRANSFER_DESTINATION_GAS_LIMIT", uint256(0));
        address securityManager = vm.envOr("SECURITY_MANAGER_CONTRACT", address(0));
        address tokenVerifier = vm.envOr("TOKEN_VERIFIER_CONTRACT", address(0));

        address localBnm = vm.envOr("LOCAL_CCIP_BNM_TOKEN", address(0));
        address localLnm = vm.envOr("LOCAL_CCIP_LNM_TOKEN", address(0));

        console.log("Deploying TokenTransferSender on", networkName);
        console.log("Chain ID:      ", block.chainid);
        console.log("Chain selector:", localSelector);
        console.log("Pay fees in:   ", payInLink ? "LINK" : "native");

        vm.startBroadcast();

        senderContract = new TokenTransferSender(localRouter, localLink, payInLink);

        // Allowlist all supported destination chains except this one.
        uint64[5] memory selectors = SupportedNetworks.allSelectors();
        for (uint256 i = 0; i < selectors.length; i++) {
            if (selectors[i] != localSelector) {
                senderContract.allowlistDestinationChain(selectors[i], true);
            }
        }

        // Always allow LINK token because it can be sent and is used for LINK-fee path.
        senderContract.allowlistToken(localLink, true);

        if (localBnm != address(0)) {
            senderContract.allowlistToken(localBnm, true);
        }
        if (localLnm != address(0)) {
            senderContract.allowlistToken(localLnm, true);
        }

        // gasLimit = 0 for EOA receiver flows. Set >0 for contract receivers.
        bytes memory transferExtraArgs = Client._argsToBytes(
            Client.GenericExtraArgsV2({gasLimit: destinationGasLimit, allowOutOfOrderExecution: false})
        );
        senderContract.updateExtraArgs(transferExtraArgs);

        if (securityManager != address(0) || tokenVerifier != address(0)) {
            senderContract.configureSecurity(securityManager, tokenVerifier);
        }

        vm.stopBroadcast();

        require(senderContract.getRouter() == localRouter, "router mismatch");
        require(senderContract.getLinkToken() == localLink, "link token mismatch");

        console.log("=============================================");
        console.log("TokenTransferSender deployed at:", address(senderContract));
        console.log("Router:                        ", localRouter);
        console.log("LINK token:                    ", localLink);
        console.log("Default token-transfer gasLimit:", destinationGasLimit);
        console.log("Security manager:               ", securityManager);
        console.log("Token verifier:                 ", tokenVerifier);
        console.log("=============================================");
        console.log("Allowlisted destination selectors:");
        for (uint256 i = 0; i < selectors.length; i++) {
            if (selectors[i] != localSelector) {
                console.log("- ", selectors[i]);
            }
        }
        console.log("Allowlisted source-chain tokens:");
        console.log("- LINK", localLink);
        if (localBnm != address(0)) console.log("- CCIP-BnM", localBnm);
        if (localLnm != address(0)) console.log("- CCIP-LnM", localLnm);
    }
}

/// @notice Deploys and configures TokenTransferReceiver on one of the 5 supported testnets.
///
/// Prerequisites:
///   1. Set LOCAL_CCIP_ROUTER for the destination chain
///   2. (Optional) set sender addresses per source chain:
///      SEPOLIA_TOKEN_SENDER_CONTRACT,
///      AMOY_TOKEN_SENDER_CONTRACT,
///      ARBITRUM_SEPOLIA_TOKEN_SENDER_CONTRACT,
///      BASE_SEPOLIA_TOKEN_SENDER_CONTRACT,
///      OP_SEPOLIA_TOKEN_SENDER_CONTRACT
///
/// Run (dry-run):
///   forge script script/Deploytokentransfer.s.sol:DeployTokenReceiver --rpc-url amoy
///
/// Run (broadcast):
///   forge script script/Deploytokentransfer.s.sol:DeployTokenReceiver \
///     --rpc-url amoy \
///     --account deployer \
///     --broadcast \
///     -vvvv
contract DeployTokenReceiver is Script {
    function run() public returns (TokenTransferReceiver receiverContract) {
        require(
            SupportedNetworks.isSupportedChainId(block.chainid),
            "Unsupported chain: use Sepolia/Amoy/Arb Sepolia/Base Sepolia/OP Sepolia"
        );

        uint64 localSelector = SupportedNetworks.selectorByChainId(block.chainid);
        string memory networkName = SupportedNetworks.nameByChainId(block.chainid);

        address localRouter = vm.envAddress("LOCAL_CCIP_ROUTER");

        console.log("Deploying TokenTransferReceiver on", networkName);
        console.log("Chain ID:      ", block.chainid);
        console.log("Chain selector:", localSelector);

        vm.startBroadcast();

        receiverContract = new TokenTransferReceiver(localRouter);

        // Allowlist all supported source chains except this one.
        uint64[5] memory selectors = SupportedNetworks.allSelectors();
        for (uint256 i = 0; i < selectors.length; i++) {
            if (selectors[i] != localSelector) {
                receiverContract.allowlistSourceChain(selectors[i], true);

                address senderForSource = _tokenSenderBySelector(selectors[i]);
                if (senderForSource != address(0)) {
                    receiverContract.allowlistSender(selectors[i], senderForSource, true);
                }
            }
        }

        vm.stopBroadcast();

        require(receiverContract.getRouter() == localRouter, "router mismatch");

        console.log("=============================================");
        console.log("TokenTransferReceiver deployed at:", address(receiverContract));
        console.log("Router:                         ", localRouter);
        console.log("=============================================");
        console.log("Source chain allowlist configured for selectors:");
        for (uint256 i = 0; i < selectors.length; i++) {
            if (selectors[i] != localSelector) {
                console.log("- ", selectors[i]);
            }
        }

        console.log("Configured token-sender addresses (if provided in env):");
        for (uint256 i = 0; i < selectors.length; i++) {
            if (selectors[i] != localSelector) {
                address senderForSource = _tokenSenderBySelector(selectors[i]);
                if (senderForSource != address(0)) {
                    console.log("- selector", selectors[i], "sender", senderForSource);
                }
            }
        }
    }

    function _tokenSenderBySelector(uint64 selector) internal view returns (address) {
        if (selector == SupportedNetworks.ETHEREUM_SEPOLIA_SELECTOR) {
            return vm.envOr("SEPOLIA_TOKEN_SENDER_CONTRACT", address(0));
        }
        if (selector == SupportedNetworks.POLYGON_AMOY_SELECTOR) {
            return vm.envOr("AMOY_TOKEN_SENDER_CONTRACT", address(0));
        }
        if (selector == SupportedNetworks.ARBITRUM_SEPOLIA_SELECTOR) {
            return vm.envOr("ARBITRUM_SEPOLIA_TOKEN_SENDER_CONTRACT", address(0));
        }
        if (selector == SupportedNetworks.BASE_SEPOLIA_SELECTOR) {
            return vm.envOr("BASE_SEPOLIA_TOKEN_SENDER_CONTRACT", address(0));
        }
        if (selector == SupportedNetworks.OP_SEPOLIA_SELECTOR) {
            return vm.envOr("OP_SEPOLIA_TOKEN_SENDER_CONTRACT", address(0));
        }
        return address(0);
    }
}
