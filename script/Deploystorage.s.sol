// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {SupportedNetworks} from "./utils/SupportedNetworks.sol";
import {UserRecordRegistry} from "../src/UserRecordRegistry.sol";

/// @notice Deploys UserRecordRegistry as the primary Feature 5 registry.
contract DeployUserRecordRegistry is Script {
    function run() external returns (UserRecordRegistry registry) {
        if (SupportedNetworks.isSupportedChainId(block.chainid)) {
            console.log("Deploying UserRecordRegistry on", SupportedNetworks.nameByChainId(block.chainid));
        } else {
            console.log("Deploying UserRecordRegistry on unsupported chain ID:", block.chainid);
        }

        vm.startBroadcast();
        registry = new UserRecordRegistry();
        vm.stopBroadcast();

        console.log("UserRecordRegistry deployed at:", address(registry));
    }
}

/// @notice Grants CRE relayer/indexer write permissions.
contract GrantSystemWriter is Script {
    function run() external {
        address registryAddr = vm.envAddress("USER_RECORD_REGISTRY_CONTRACT");
        address writer = vm.envAddress("SYSTEM_WRITER_ADDRESS");
        require(registryAddr != address(0), "USER_RECORD_REGISTRY_CONTRACT not set");
        require(writer != address(0), "SYSTEM_WRITER_ADDRESS not set");

        vm.startBroadcast();
        UserRecordRegistry(registryAddr).grantSystemWriter(writer);
        vm.stopBroadcast();

        console.log("Granted SYSTEM_WRITER_ROLE:", writer);
    }
}

/// @notice User updates own profile commitment hash.
contract UpdateMyProfileCommitment is Script {
    function run() external {
        address registryAddr = vm.envAddress("USER_RECORD_REGISTRY_CONTRACT");
        bytes32 commitment = vm.envBytes32("PROFILE_COMMITMENT_HASH");
        require(registryAddr != address(0), "USER_RECORD_REGISTRY_CONTRACT not set");

        vm.startBroadcast();
        UserRecordRegistry(registryAddr).updateProfileCommitment(commitment);
        vm.stopBroadcast();

        console.log("Profile commitment updated:");
        console.logBytes32(commitment);
    }
}

/// @notice Appends one normalized record as SYSTEM_WRITER_ROLE.
contract AppendSystemRecord is Script {
    function run() external returns (uint256 recordId) {
        address registryAddr = vm.envAddress("USER_RECORD_REGISTRY_CONTRACT");
        require(registryAddr != address(0), "USER_RECORD_REGISTRY_CONTRACT not set");

        UserRecordRegistry registry = UserRecordRegistry(registryAddr);
        UserRecordRegistry.RecordInput memory input = _buildInput("", 0);
        bytes32 externalEventKey = vm.envBytes32("RECORD_EXTERNAL_EVENT_KEY");

        vm.startBroadcast();
        recordId = registry.appendRecord(input, externalEventKey);
        vm.stopBroadcast();

        console.log("Record appended with ID:", recordId);
    }

    function _buildInput(string memory prefix, uint256 idx)
        internal
        view
        returns (UserRecordRegistry.RecordInput memory input)
    {
        input = UserRecordRegistry.RecordInput({
            user: vm.envAddress(_key(prefix, "RECORD_USER", idx)),
            featureType: UserRecordRegistry.FeatureType(uint8(vm.envUint(_key(prefix, "RECORD_FEATURE_TYPE", idx)))),
            chainSelector: uint64(vm.envUint(_key(prefix, "RECORD_CHAIN_SELECTOR", idx))),
            sourceContract: vm.envAddress(_key(prefix, "RECORD_SOURCE_CONTRACT", idx)),
            counterparty: vm.envAddress(_key(prefix, "RECORD_COUNTERPARTY", idx)),
            messageId: vm.envBytes32(_key(prefix, "RECORD_MESSAGE_ID", idx)),
            assetToken: vm.envAddress(_key(prefix, "RECORD_ASSET_TOKEN", idx)),
            amount: vm.envUint(_key(prefix, "RECORD_AMOUNT", idx)),
            actionHash: vm.envBytes32(_key(prefix, "RECORD_ACTION_HASH", idx)),
            status: UserRecordRegistry.RecordStatus(uint8(vm.envUint(_key(prefix, "RECORD_STATUS", idx)))),
            metadataHash: vm.envBytes32(_key(prefix, "RECORD_METADATA_HASH", idx))
        });
    }

    function _key(string memory prefix, string memory base, uint256 idx) internal pure returns (string memory) {
        if (bytes(prefix).length == 0) {
            if (idx == 0) return base;
            return string.concat(base, "_", _uintToString(idx));
        }
        if (idx == 0) return string.concat(prefix, base);
        return string.concat(prefix, base, "_", _uintToString(idx));
    }

    function _uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}

/// @notice Appends multiple records as SYSTEM_WRITER_ROLE using indexed env keys.
/// @dev Provide RECORD_BATCH_COUNT and indexed variables like RECORD_USER_1 ... RECORD_USER_N.
contract AppendSystemRecordsBatch is Script {
    function run() external returns (uint256 firstRecordId, uint256 lastRecordId) {
        address registryAddr = vm.envAddress("USER_RECORD_REGISTRY_CONTRACT");
        uint256 count = vm.envUint("RECORD_BATCH_COUNT");
        require(registryAddr != address(0), "USER_RECORD_REGISTRY_CONTRACT not set");
        require(count > 0, "RECORD_BATCH_COUNT must be > 0");

        UserRecordRegistry.RecordInput[] memory inputs = new UserRecordRegistry.RecordInput[](count);
        bytes32[] memory keys = new bytes32[](count);

        for (uint256 i = 0; i < count; i++) {
            inputs[i] = UserRecordRegistry.RecordInput({
                user: vm.envAddress(_indexed("RECORD_USER", i)),
                featureType: UserRecordRegistry.FeatureType(uint8(vm.envUint(_indexed("RECORD_FEATURE_TYPE", i)))),
                chainSelector: uint64(vm.envUint(_indexed("RECORD_CHAIN_SELECTOR", i))),
                sourceContract: vm.envAddress(_indexed("RECORD_SOURCE_CONTRACT", i)),
                counterparty: vm.envAddress(_indexed("RECORD_COUNTERPARTY", i)),
                messageId: vm.envBytes32(_indexed("RECORD_MESSAGE_ID", i)),
                assetToken: vm.envAddress(_indexed("RECORD_ASSET_TOKEN", i)),
                amount: vm.envUint(_indexed("RECORD_AMOUNT", i)),
                actionHash: vm.envBytes32(_indexed("RECORD_ACTION_HASH", i)),
                status: UserRecordRegistry.RecordStatus(uint8(vm.envUint(_indexed("RECORD_STATUS", i)))),
                metadataHash: vm.envBytes32(_indexed("RECORD_METADATA_HASH", i))
            });
            keys[i] = vm.envBytes32(_indexed("RECORD_EXTERNAL_EVENT_KEY", i));
        }

        vm.startBroadcast();
        (firstRecordId, lastRecordId) = UserRecordRegistry(registryAddr).appendRecordsBatch(inputs, keys);
        vm.stopBroadcast();

        console.log("Batch appended. firstRecordId:", firstRecordId);
        console.log("Batch appended. lastRecordId:", lastRecordId);
        console.log("Batch count:", count);
    }

    function _indexed(string memory base, uint256 idx) internal pure returns (string memory) {
        return string.concat(base, "_", _uintToString(idx));
    }

    function _uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}

/// @notice Reads profile data for a given wallet.
contract ReadUserProfile is Script {
    function run() external view {
        address registryAddr = vm.envAddress("USER_RECORD_REGISTRY_CONTRACT");
        address user = vm.envAddress("RECORD_USER");
        require(registryAddr != address(0), "USER_RECORD_REGISTRY_CONTRACT not set");
        require(user != address(0), "RECORD_USER not set");

        UserRecordRegistry.UserProfile memory profile = UserRecordRegistry(registryAddr).getProfile(user);

        console.log("=============================================");
        console.log("User profile");
        console.log("=============================================");
        console.log("Registry:", registryAddr);
        console.log("User:", user);
        console.log("Commitment:");
        console.logBytes32(profile.profileCommitment);
        console.log("Version:", profile.profileVersion);
        console.log("Updated At:", profile.updatedAt);
        console.log("=============================================");
    }
}

/// @notice Reads paginated record IDs for a user and prints each record summary.
contract ReadUserRecords is Script {
    function run() external view {
        address registryAddr = vm.envAddress("USER_RECORD_REGISTRY_CONTRACT");
        address user = vm.envAddress("RECORD_USER");
        uint256 offset = vm.envOr("READ_OFFSET", uint256(0));
        uint256 limit = vm.envOr("READ_LIMIT", uint256(20));

        require(registryAddr != address(0), "USER_RECORD_REGISTRY_CONTRACT not set");
        require(user != address(0), "RECORD_USER not set");

        UserRecordRegistry registry = UserRecordRegistry(registryAddr);
        uint256[] memory ids = registry.getUserRecordIds(user, offset, limit);

        console.log("=============================================");
        console.log("User records");
        console.log("=============================================");
        console.log("Registry:", registryAddr);
        console.log("User:", user);
        console.log("Total count:", registry.getUserRecordCount(user));
        console.log("Returned IDs:", ids.length);

        for (uint256 i = 0; i < ids.length; i++) {
            UserRecordRegistry.Record memory record = registry.getRecord(ids[i]);
            console.log("- recordId:", record.recordId);
            console.log("  featureType:", uint8(record.featureType));
            console.log("  status:", uint8(record.status));
            console.log("  chainSelector:", record.chainSelector);
            console.log("  sourceContract:", record.sourceContract);
            console.log("  counterparty:", record.counterparty);
            console.log("  token:", record.assetToken);
            console.log("  amount:", record.amount);
            console.log("  occurredAt:", record.occurredAt);
        }

        console.log("=============================================");
    }
}
