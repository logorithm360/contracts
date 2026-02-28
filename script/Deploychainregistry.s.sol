// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {ChainRegistry} from "../src/ChainRegistry.sol";
import {IChainRegistry} from "../src/interfaces/IChainRegistry.sol";
import {SupportedNetworks} from "./utils/SupportedNetworks.sol";

interface IResolverConfigurable {
    function configureChainRegistry(address registry, uint8 mode) external;
}

contract DeployChainRegistry is Script {
    function run() external returns (ChainRegistry registry) {
        vm.startBroadcast();
        registry = new ChainRegistry();
        vm.stopBroadcast();

        console.log("ChainRegistry deployed:", address(registry));
    }
}

contract SeedDefaultChainsAndLanes is Script {
    function run() external {
        address registryAddr = vm.envAddress("CHAIN_REGISTRY_CONTRACT");
        ChainRegistry registry = ChainRegistry(registryAddr);
        uint8 feeTokenMode = uint8(vm.envOr("CHAIN_DEFAULT_FEE_TOKEN_MODE", uint256(3)));

        vm.startBroadcast();

        bool[5] memory configured;
        configured[0] = _tryUpsertChain(
            registry,
            SupportedNetworks.ETHEREUM_SEPOLIA_CHAIN_ID,
            SupportedNetworks.ETHEREUM_SEPOLIA_SELECTOR,
            "Ethereum Sepolia",
            "SEPOLIA"
        );
        configured[1] = _tryUpsertChain(
            registry,
            SupportedNetworks.POLYGON_AMOY_CHAIN_ID,
            SupportedNetworks.POLYGON_AMOY_SELECTOR,
            "Polygon Amoy",
            "AMOY"
        );
        configured[2] = _tryUpsertChain(
            registry,
            SupportedNetworks.ARBITRUM_SEPOLIA_CHAIN_ID,
            SupportedNetworks.ARBITRUM_SEPOLIA_SELECTOR,
            "Arbitrum Sepolia",
            "ARBITRUM_SEPOLIA"
        );
        configured[3] = _tryUpsertChain(
            registry,
            SupportedNetworks.BASE_SEPOLIA_CHAIN_ID,
            SupportedNetworks.BASE_SEPOLIA_SELECTOR,
            "Base Sepolia",
            "BASE_SEPOLIA"
        );
        configured[4] = _tryUpsertChain(
            registry,
            SupportedNetworks.OP_SEPOLIA_CHAIN_ID,
            SupportedNetworks.OP_SEPOLIA_SELECTOR,
            "OP Sepolia",
            "OP_SEPOLIA"
        );

        uint64[5] memory selectors = SupportedNetworks.allSelectors();
        for (uint256 i = 0; i < selectors.length; i++) {
            if (!configured[i]) continue;
            for (uint256 j = 0; j < selectors.length; j++) {
                if (i == j || !configured[j]) continue;
                registry.setLane(selectors[i], selectors[j], true, feeTokenMode);
            }
        }

        vm.stopBroadcast();

        console.log("Seeded default chains and lanes on registry", registryAddr);
    }

    function _tryUpsertChain(
        ChainRegistry registry,
        uint256 chainId,
        uint64 selector,
        string memory displayName,
        string memory aliasKey
    ) internal returns (bool configured) {
        address router = vm.envOr(string.concat("CHAIN_", aliasKey, "_ROUTER"), address(0));
        address linkToken = vm.envOr(string.concat("CHAIN_", aliasKey, "_LINK_TOKEN"), address(0));
        address wrappedNative = vm.envOr(string.concat("CHAIN_", aliasKey, "_WRAPPED_NATIVE"), address(0));
        bool active = vm.envOr(string.concat("CHAIN_", aliasKey, "_ACTIVE"), true);

        if (router == address(0) || linkToken == address(0)) {
            console.log("Skipping chain (missing router/link):", displayName);
            return false;
        }

        IChainRegistry.ChainRecord memory record = IChainRegistry.ChainRecord({
            chainId: chainId,
            selector: selector,
            name: displayName,
            router: router,
            linkToken: linkToken,
            wrappedNative: wrappedNative,
            isActive: active,
            isTestnet: true
        });

        registry.upsertChain(record);
        console.log("Upserted chain:", displayName, "selector:", selector);
        configured = true;
    }
}

contract SeedDefaultLaneTokens is Script {
    function run() external {
        address registryAddr = vm.envAddress("CHAIN_REGISTRY_CONTRACT");
        uint64 sourceSelector = uint64(vm.envUint("CHAIN_TOKEN_SOURCE_SELECTOR"));
        uint64 destinationSelector = uint64(vm.envUint("CHAIN_TOKEN_DESTINATION_SELECTOR"));
        address sourceToken = vm.envAddress("CHAIN_TOKEN_SOURCE_ADDRESS");
        address destinationToken = vm.envAddress("CHAIN_TOKEN_DESTINATION_ADDRESS");
        uint8 decimals = uint8(vm.envUint("CHAIN_TOKEN_DECIMALS"));
        string memory symbol = vm.envString("CHAIN_TOKEN_SYMBOL");
        bool isActive = vm.envOr("CHAIN_TOKEN_ACTIVE", true);

        vm.startBroadcast();
        ChainRegistry(registryAddr)
            .setLaneToken(
                sourceSelector,
                destinationSelector,
                sourceToken,
                destinationToken,
                decimals,
                keccak256(bytes(symbol)),
                isActive
            );
        vm.stopBroadcast();

        console.log("Seeded lane token", sourceToken);
        console.log("Lane source selector", sourceSelector);
        console.log("Lane destination selector", destinationSelector);
    }
}

contract SeedServiceBindings is Script {
    function run() external {
        address registryAddr = vm.envAddress("CHAIN_REGISTRY_CONTRACT");
        uint64 chainSelector = uint64(vm.envUint("CHAIN_SERVICE_SELECTOR"));
        string memory serviceName = vm.envString("CHAIN_SERVICE_KEY");
        address serviceContract = vm.envAddress("CHAIN_SERVICE_CONTRACT");
        bool isActive = vm.envOr("CHAIN_SERVICE_ACTIVE", true);

        vm.startBroadcast();
        ChainRegistry(registryAddr)
            .setServiceContract(chainSelector, keccak256(bytes(serviceName)), serviceContract, isActive);
        vm.stopBroadcast();

        console.log("Seeded service binding", serviceName, "on selector", chainSelector);
    }
}

contract ConfigureResolverOnSendersAndTrader is Script {
    function run() external {
        address registryAddr = vm.envAddress("CHAIN_REGISTRY_CONTRACT");
        uint8 mode = _resolverModeFromEnv();

        vm.startBroadcast();
        _configure(vm.envOr("MESSAGE_SENDER_CONTRACT", address(0)), registryAddr, mode, "MessagingSender");
        _configure(vm.envOr("TOKEN_SENDER_CONTRACT", address(0)), registryAddr, mode, "TokenTransferSender");
        _configure(vm.envOr("PROGRAMMABLE_SENDER_CONTRACT", address(0)), registryAddr, mode, "ProgrammableTokenSender");
        _configure(vm.envOr("AUTOMATED_TRADER_CONTRACT", address(0)), registryAddr, mode, "AutomatedTrader");
        vm.stopBroadcast();
    }

    function _configure(address target, address registry, uint8 mode, string memory label) internal {
        if (target == address(0)) {
            console.log("Skipping", label, "(address not set)");
            return;
        }

        IResolverConfigurable(target).configureChainRegistry(registry, mode);
        console.log("Configured", label, "resolver mode", mode);
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

contract CheckChainRegistryState is Script {
    function run() external view {
        address registryAddr = vm.envAddress("CHAIN_REGISTRY_CONTRACT");
        ChainRegistry registry = ChainRegistry(registryAddr);

        console.log("=============================================");
        console.log("ChainRegistry:", registryAddr);
        console.log("=============================================");

        IChainRegistry.ChainRecord[] memory chains = registry.getSupportedChains(0, 50);
        console.log("Active chains:", chains.length);
        for (uint256 i = 0; i < chains.length; i++) {
            console.log("Chain name:", chains[i].name);
            console.log("Selector:", chains[i].selector);
            console.log("Chain ID:", chains[i].chainId);
        }

        IChainRegistry.LaneRecord[] memory lanes = registry.getActiveLanes(0, 200);
        console.log("Active lanes:", lanes.length);
        for (uint256 i = 0; i < lanes.length; i++) {
            console.log("Lane source:", lanes[i].sourceSelector);
            console.log("Lane destination:", lanes[i].destinationSelector);
            console.log("Lane fee mode:", lanes[i].feeTokenMode);
        }
    }
}
