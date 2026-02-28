// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {MessagingSender} from "../src/MessageSender.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {SupportedNetworks} from "./utils/SupportedNetworks.sol";

/// @notice Deploys and configures MessagingSender on one of the 5 supported testnets.
///
/// Prerequisites:
///   1. Set LOCAL_CCIP_ROUTER and LOCAL_LINK_TOKEN in your .env for the target chain
///   2. (Optional) set DESTINATION_GAS_LIMIT, PAY_FEES_IN_LINK
///   3. Import your deployer key: cast wallet import deployer --interactive
///
/// Simulate (dry run):
///   forge script script/Deploysender.s.sol --rpc-url sepolia
///
/// Deploy:
///   forge script script/Deploysender.s.sol \
///     --rpc-url sepolia \
///     --account deployer \
///     --broadcast \
///     -vvvv
contract DeploySender is Script {
    function run() public returns (MessagingSender senderContract) {
        require(
            SupportedNetworks.isSupportedChainId(block.chainid),
            "Unsupported chain: use Sepolia/Amoy/Arb Sepolia/Base Sepolia/OP Sepolia"
        );

        uint64 localSelector = SupportedNetworks.selectorByChainId(block.chainid);
        string memory networkName = SupportedNetworks.nameByChainId(block.chainid);
        address localRouter = vm.envAddress("LOCAL_CCIP_ROUTER");
        address localLink = vm.envAddress("LOCAL_LINK_TOKEN");
        bool payInLink = vm.envOr("PAY_FEES_IN_LINK", true);
        uint256 destinationGasLimit = vm.envOr("DESTINATION_GAS_LIMIT", uint256(400_000));
        address securityManager = vm.envOr("SECURITY_MANAGER_CONTRACT", address(0));
        address tokenVerifier = vm.envOr("TOKEN_VERIFIER_CONTRACT", address(0));
        address chainRegistry = vm.envOr("CHAIN_REGISTRY_CONTRACT", address(0));
        uint8 resolverMode = _resolverModeFromEnv();

        console.log("Deploying MessagingSender on", networkName);
        console.log("Chain ID:      ", block.chainid);
        console.log("Chain selector:", localSelector);
        console.log("Pay fees in:   ", payInLink ? "LINK" : "native");

        vm.startBroadcast();

        senderContract = new MessagingSender(localRouter, localLink, payInLink);

        // Allowlist all supported destination chains except this chain.
        uint64[5] memory selectors = SupportedNetworks.allSelectors();
        for (uint256 i = 0; i < selectors.length; i++) {
            if (selectors[i] != localSelector) {
                senderContract.allowlistDestinationChain(selectors[i], true);
            }
        }

        // Set production extraArgs with configurable gas limit.
        bytes memory productionExtraArgs = Client._argsToBytes(
            Client.GenericExtraArgsV2({gasLimit: destinationGasLimit, allowOutOfOrderExecution: false})
        );
        senderContract.updateExtraArgs(productionExtraArgs);

        if (securityManager != address(0) || tokenVerifier != address(0)) {
            senderContract.configureSecurity(securityManager, tokenVerifier);
        }

        if (chainRegistry != address(0) || resolverMode != 0) {
            require(chainRegistry != address(0), "CHAIN_REGISTRY_CONTRACT required when resolver mode is enabled");
            senderContract.configureChainRegistry(chainRegistry, resolverMode);
        }

        vm.stopBroadcast();

        require(senderContract.getRouter() == localRouter, "router mismatch");
        require(senderContract.getLinkToken() == localLink, "link token mismatch");

        console.log("=============================================");
        console.log("MessagingSender deployed at:", address(senderContract));
        console.log("Router:                    ", localRouter);
        console.log("LINK token:                ", localLink);
        console.log("Security manager:          ", securityManager);
        console.log("Token verifier:            ", tokenVerifier);
        console.log("Chain registry:            ", chainRegistry);
        console.log("Resolver mode:             ", resolverMode);
        console.log("=============================================");
        console.log("Allowlisted destination selectors:");
        for (uint256 i = 0; i < selectors.length; i++) {
            if (selectors[i] != localSelector) {
                console.log("- ", selectors[i]);
            }
        }
    }

    function _resolverModeFromEnv() internal view returns (uint8 mode) {
        string memory modeName = vm.envOr("CHAIN_RESOLVER_MODE", string("DISABLED"));
        bytes32 m = keccak256(bytes(modeName));
        if (m == keccak256("DISABLED")) return 0;
        if (m == keccak256("MONITOR")) return 1;
        if (m == keccak256("ENFORCE")) return 2;
        revert("Invalid CHAIN_RESOLVER_MODE");
    }
}
