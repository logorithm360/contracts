// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {ChainAlertRegistry} from "../src/ChainAlertRegistry.sol";
import {UserRecordRegistry} from "../src/UserRecordRegistry.sol";
import {SecurityManager} from "../src/SecurityManager.sol";

/// @notice Deploys ChainAlertRegistry for on-chain alert rules/state tracking.
contract DeployChainAlertRegistry is Script {
    function run() external returns (ChainAlertRegistry registry) {
        vm.startBroadcast();
        registry = new ChainAlertRegistry();
        vm.stopBroadcast();

        console.log("ChainAlertRegistry deployed at:", address(registry));
    }
}

/// @notice Authorizes/deauthorizes CRE workflow contract for alert state writes.
contract ConfigureChainAlertWorkflowAuthorizer is Script {
    function run() external {
        address registryAddr = vm.envAddress("CHAINALERT_REGISTRY_CONTRACT");
        address workflowAddr = vm.envAddress("CHAINALERT_WORKFLOW_ADDRESS");
        bool enabled = vm.envOr("CHAINALERT_WORKFLOW_ENABLED", true);

        require(registryAddr != address(0), "CHAINALERT_REGISTRY_CONTRACT not set");
        require(workflowAddr != address(0), "CHAINALERT_WORKFLOW_ADDRESS not set");

        vm.startBroadcast();
        ChainAlertRegistry(registryAddr).setWorkflowAuthorizer(workflowAddr, enabled);
        vm.stopBroadcast();

        console.log("ChainAlertRegistry:", registryAddr);
        console.log("Workflow authorizer:", workflowAddr);
        console.log("Enabled:", enabled);
    }
}

/// @notice Configures all chainAlert workflow permissions across Feature 4/5/6 contracts in one transaction batch.
contract ConfigureChainAlertSystemAccess is Script {
    function run() external {
        address workflowAddr = vm.envAddress("CHAINALERT_WORKFLOW_ADDRESS");
        require(workflowAddr != address(0), "CHAINALERT_WORKFLOW_ADDRESS not set");

        bool enableWorkflow = vm.envOr("CHAINALERT_WORKFLOW_ENABLED", true);
        bool enableFeature5Writer = vm.envOr("CHAINALERT_ENABLE_FEATURE5_WRITER", true);
        bool enableFeature6Caller = vm.envOr("CHAINALERT_ENABLE_FEATURE6_CALLER", true);

        address chainAlertRegistryAddr = vm.envAddress("CHAINALERT_REGISTRY_CONTRACT");
        require(chainAlertRegistryAddr != address(0), "CHAINALERT_REGISTRY_CONTRACT not set");

        address userRecordRegistryAddr = vm.envOr("USER_RECORD_REGISTRY_CONTRACT", address(0));
        address securityManagerAddr = vm.envOr("SECURITY_MANAGER_CONTRACT", address(0));

        if (enableFeature5Writer) {
            require(userRecordRegistryAddr != address(0), "USER_RECORD_REGISTRY_CONTRACT not set");
        }
        if (enableFeature6Caller) {
            require(securityManagerAddr != address(0), "SECURITY_MANAGER_CONTRACT not set");
        }

        vm.startBroadcast();

        ChainAlertRegistry(chainAlertRegistryAddr).setWorkflowAuthorizer(workflowAddr, enableWorkflow);

        if (enableFeature5Writer) {
            if (enableWorkflow) {
                UserRecordRegistry(userRecordRegistryAddr).grantSystemWriter(workflowAddr);
            } else {
                UserRecordRegistry(userRecordRegistryAddr).revokeSystemWriter(workflowAddr);
            }
        }

        if (enableFeature6Caller) {
            SecurityManager(securityManagerAddr).authoriseCaller(workflowAddr, enableWorkflow);
        }

        vm.stopBroadcast();

        console.log("=============================================");
        console.log("ChainAlert system access configured");
        console.log("=============================================");
        console.log("Workflow:", workflowAddr);
        console.log("Enabled:", enableWorkflow);
        console.log("ChainAlertRegistry:", chainAlertRegistryAddr);
        if (enableFeature5Writer) {
            console.log("UserRecordRegistry:", userRecordRegistryAddr);
        } else {
            console.log("UserRecordRegistry: skipped");
        }
        if (enableFeature6Caller) {
            console.log("SecurityManager:", securityManagerAddr);
        } else {
            console.log("SecurityManager: skipped");
        }
        console.log("=============================================");
    }
}

/// @notice Reads current chainAlert workflow permissions across Feature 4/5/6 contracts.
contract VerifyChainAlertSystemAccess is Script {
    function run() external view {
        address workflowAddr = vm.envAddress("CHAINALERT_WORKFLOW_ADDRESS");
        address chainAlertRegistryAddr = vm.envAddress("CHAINALERT_REGISTRY_CONTRACT");
        address userRecordRegistryAddr = vm.envOr("USER_RECORD_REGISTRY_CONTRACT", address(0));
        address securityManagerAddr = vm.envOr("SECURITY_MANAGER_CONTRACT", address(0));

        require(workflowAddr != address(0), "CHAINALERT_WORKFLOW_ADDRESS not set");
        require(chainAlertRegistryAddr != address(0), "CHAINALERT_REGISTRY_CONTRACT not set");

        bool chainAlertAuthorized = ChainAlertRegistry(chainAlertRegistryAddr).authorizedWorkflows(workflowAddr);
        console.log("=============================================");
        console.log("ChainAlert system access");
        console.log("=============================================");
        console.log("Workflow:", workflowAddr);
        console.log("ChainAlertRegistry:", chainAlertRegistryAddr);
        console.log("authorizedWorkflows:", chainAlertAuthorized);

        if (userRecordRegistryAddr != address(0)) {
            bytes32 writerRole = UserRecordRegistry(userRecordRegistryAddr).SYSTEM_WRITER_ROLE();
            bool feature5Authorized = UserRecordRegistry(userRecordRegistryAddr).hasRole(writerRole, workflowAddr);
            console.log("UserRecordRegistry:", userRecordRegistryAddr);
            console.log("SYSTEM_WRITER_ROLE:", feature5Authorized);
        } else {
            console.log("UserRecordRegistry: not provided");
        }

        if (securityManagerAddr != address(0)) {
            bool feature6Authorized = SecurityManager(securityManagerAddr).authorisedCallers(workflowAddr);
            console.log("SecurityManager:", securityManagerAddr);
            console.log("authorisedCallers:", feature6Authorized);
        } else {
            console.log("SecurityManager: not provided");
        }

        console.log("=============================================");
    }
}
