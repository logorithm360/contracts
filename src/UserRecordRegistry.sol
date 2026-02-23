// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title UserRecordRegistry
/// @notice Canonical user-level profile commitments and normalized cross-feature record snapshots.
contract UserRecordRegistry is Ownable {
    error UnauthorizedSystemWriter(address caller);
    error InvalidFeatureType(uint8 featureType);
    error InvalidRecordStatus(uint8 status);
    error InvalidChainSelector();
    error InvalidBatchLength();
    error BatchTooLarge(uint256 provided, uint256 maxAllowed);
    error RecordNotFound(uint256 recordId);
    error ExternalEventAlreadyUsed(bytes32 externalEventKey);
    error InvalidExternalEventKey();
    error ZeroAddressField(bytes32 fieldName);

    enum FeatureType {
        MESSAGE,
        TOKEN_TRANSFER,
        PROGRAMMABLE_TRANSFER,
        AUTOMATED_TRADER
    }

    enum RecordStatus {
        CREATED,
        SENT,
        RECEIVED,
        PROCESSED,
        PENDING_ACTION,
        FAILED,
        RETRY,
        RECOVERED
    }

    struct UserProfile {
        bytes32 profileCommitment;
        uint64 profileVersion;
        uint256 updatedAt;
    }

    struct Record {
        uint256 recordId;
        address user;
        FeatureType featureType;
        uint64 chainSelector;
        address sourceContract;
        address counterparty;
        bytes32 messageId;
        address assetToken;
        uint256 amount;
        bytes32 actionHash;
        RecordStatus status;
        uint256 occurredAt;
        bytes32 metadataHash;
    }

    struct RecordInput {
        address user;
        FeatureType featureType;
        uint64 chainSelector;
        address sourceContract;
        address counterparty;
        bytes32 messageId;
        address assetToken;
        uint256 amount;
        bytes32 actionHash;
        RecordStatus status;
        bytes32 metadataHash;
    }

    bytes32 public constant SYSTEM_WRITER_ROLE = keccak256("SYSTEM_WRITER_ROLE");
    uint256 public constant MAX_BATCH_APPEND = 100;

    mapping(address => UserProfile) private s_profiles;
    mapping(uint256 => Record) private s_records;
    mapping(address => uint256[]) private s_userRecordIds;
    mapping(bytes32 => bool) private s_eventKeyUsed;
    mapping(bytes32 => mapping(address => bool)) private s_roles;

    uint256 public nextRecordId = 1;

    event ProfileCommitmentUpdated(
        address indexed user,
        bytes32 indexed previousCommitment,
        bytes32 indexed newCommitment,
        uint64 profileVersion,
        uint256 updatedAt
    );

    event RecordAppended(
        uint256 indexed recordId,
        address indexed user,
        FeatureType indexed featureType,
        RecordStatus status,
        uint64 chainSelector,
        address sourceContract,
        address counterparty,
        bytes32 messageId,
        bytes32 externalEventKey
    );

    event SystemWriterRoleUpdated(address indexed writer, bool enabled, address indexed admin);

    constructor() Ownable(msg.sender) {
        s_roles[SYSTEM_WRITER_ROLE][msg.sender] = true;
        emit SystemWriterRoleUpdated(msg.sender, true, msg.sender);
    }

    modifier onlySystemWriter() {
        if (!hasRole(SYSTEM_WRITER_ROLE, msg.sender)) {
            revert UnauthorizedSystemWriter(msg.sender);
        }
        _;
    }

    function updateProfileCommitment(bytes32 newCommitment) external {
        UserProfile storage profile = s_profiles[msg.sender];
        bytes32 previousCommitment = profile.profileCommitment;

        profile.profileCommitment = newCommitment;
        profile.profileVersion += 1;
        profile.updatedAt = block.timestamp;

        emit ProfileCommitmentUpdated(
            msg.sender, previousCommitment, newCommitment, profile.profileVersion, profile.updatedAt
        );
    }

    function appendRecord(RecordInput calldata input, bytes32 externalEventKey)
        external
        onlySystemWriter
        returns (uint256 recordId)
    {
        _validateRecordInput(input, externalEventKey);
        recordId = _appendValidatedRecord(input, externalEventKey);
    }

    function appendRecordsBatch(RecordInput[] calldata inputs, bytes32[] calldata keys)
        external
        onlySystemWriter
        returns (uint256 firstRecordId, uint256 lastRecordId)
    {
        uint256 len = inputs.length;
        if (len == 0 || len != keys.length) revert InvalidBatchLength();
        if (len > MAX_BATCH_APPEND) revert BatchTooLarge(len, MAX_BATCH_APPEND);

        firstRecordId = nextRecordId;

        for (uint256 i = 0; i < len; i++) {
            _validateRecordInput(inputs[i], keys[i]);
            lastRecordId = _appendValidatedRecord(inputs[i], keys[i]);
        }
    }

    function getProfile(address user) external view returns (UserProfile memory) {
        return s_profiles[user];
    }

    function getRecord(uint256 recordId) external view returns (Record memory) {
        if (recordId == 0 || recordId >= nextRecordId) revert RecordNotFound(recordId);
        return s_records[recordId];
    }

    function getUserRecordIds(address user, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids)
    {
        uint256 len = s_userRecordIds[user].length;
        if (offset >= len || limit == 0) {
            return new uint256[](0);
        }

        uint256 end = offset + limit;
        if (end > len) end = len;

        uint256 outLen = end - offset;
        ids = new uint256[](outLen);

        for (uint256 i = 0; i < outLen; i++) {
            ids[i] = s_userRecordIds[user][offset + i];
        }
    }

    function getUserRecordCount(address user) external view returns (uint256) {
        return s_userRecordIds[user].length;
    }

    function grantSystemWriter(address writer) external onlyOwner {
        if (writer == address(0)) revert ZeroAddressField("writer");
        _setRole(SYSTEM_WRITER_ROLE, writer, true);
    }

    function revokeSystemWriter(address writer) external onlyOwner {
        if (writer == address(0)) revert ZeroAddressField("writer");
        _setRole(SYSTEM_WRITER_ROLE, writer, false);
    }

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return s_roles[role][account];
    }

    function isEventKeyUsed(bytes32 key) external view returns (bool) {
        return s_eventKeyUsed[key];
    }

    function _setRole(bytes32 role, address account, bool enabled) internal {
        s_roles[role][account] = enabled;
        emit SystemWriterRoleUpdated(account, enabled, msg.sender);
    }

    function _validateRecordInput(RecordInput calldata input, bytes32 externalEventKey) internal view {
        if (externalEventKey == bytes32(0)) revert InvalidExternalEventKey();
        if (s_eventKeyUsed[externalEventKey]) revert ExternalEventAlreadyUsed(externalEventKey);

        if (input.user == address(0)) revert ZeroAddressField("user");
        if (input.sourceContract == address(0)) revert ZeroAddressField("sourceContract");
        if (input.counterparty == address(0)) revert ZeroAddressField("counterparty");
        if (input.chainSelector == 0) revert InvalidChainSelector();

        if (uint8(input.featureType) > uint8(FeatureType.AUTOMATED_TRADER)) {
            revert InvalidFeatureType(uint8(input.featureType));
        }

        if (uint8(input.status) > uint8(RecordStatus.RECOVERED)) {
            revert InvalidRecordStatus(uint8(input.status));
        }

        if (input.amount > 0 && input.assetToken == address(0)) {
            revert ZeroAddressField("assetToken");
        }
    }

    function _appendValidatedRecord(RecordInput calldata input, bytes32 externalEventKey)
        internal
        returns (uint256 recordId)
    {
        recordId = nextRecordId;
        nextRecordId++;

        s_eventKeyUsed[externalEventKey] = true;

        Record storage record = s_records[recordId];
        record.recordId = recordId;
        record.user = input.user;
        record.featureType = input.featureType;
        record.chainSelector = input.chainSelector;
        record.sourceContract = input.sourceContract;
        record.counterparty = input.counterparty;
        record.messageId = input.messageId;
        record.assetToken = input.assetToken;
        record.amount = input.amount;
        record.actionHash = input.actionHash;
        record.status = input.status;
        record.occurredAt = block.timestamp;
        record.metadataHash = input.metadataHash;

        s_userRecordIds[input.user].push(recordId);

        emit RecordAppended(
            recordId,
            input.user,
            input.featureType,
            input.status,
            input.chainSelector,
            input.sourceContract,
            input.counterparty,
            input.messageId,
            externalEventKey
        );
    }
}
