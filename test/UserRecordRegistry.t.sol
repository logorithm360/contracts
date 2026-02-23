// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {UserRecordRegistry} from "../src/UserRecordRegistry.sol";

contract UserRecordRegistryTest is Test {
    UserRecordRegistry internal registry;

    address internal writer = makeAddr("writer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");
    address internal sourceContract = makeAddr("sourceContract");
    address internal counterparty = makeAddr("counterparty");
    address internal token = makeAddr("token");

    uint64 internal constant SEPOLIA_SELECTOR = 16015286601757825753;

    function setUp() public {
        registry = new UserRecordRegistry();
        registry.grantSystemWriter(writer);
    }

    function test_UserCanUpdateOwnProfileCommitment() public {
        bytes32 commitment = keccak256("alice-profile-v1");

        vm.prank(alice);
        registry.updateProfileCommitment(commitment);

        UserRecordRegistry.UserProfile memory profile = registry.getProfile(alice);
        assertEq(profile.profileCommitment, commitment);
        assertEq(profile.profileVersion, 1);
        assertEq(profile.updatedAt, block.timestamp);
    }

    function test_ProfileUpdatesAreWalletScoped() public {
        vm.prank(alice);
        registry.updateProfileCommitment(keccak256("alice-v1"));

        vm.prank(bob);
        registry.updateProfileCommitment(keccak256("bob-v1"));

        UserRecordRegistry.UserProfile memory aliceProfile = registry.getProfile(alice);
        UserRecordRegistry.UserProfile memory bobProfile = registry.getProfile(bob);

        assertEq(aliceProfile.profileVersion, 1);
        assertEq(bobProfile.profileVersion, 1);
        assertNotEq(aliceProfile.profileCommitment, bobProfile.profileCommitment);
    }

    function test_SystemWriterCanAppendSingleRecord() public {
        UserRecordRegistry.RecordInput memory input = _defaultInput(alice);
        bytes32 key = keccak256("event-1");

        vm.prank(writer);
        uint256 recordId = registry.appendRecord(input, key);

        UserRecordRegistry.Record memory record = registry.getRecord(recordId);
        assertEq(record.recordId, 1);
        assertEq(record.user, alice);
        assertEq(uint8(record.featureType), uint8(UserRecordRegistry.FeatureType.AUTOMATED_TRADER));
        assertEq(uint8(record.status), uint8(UserRecordRegistry.RecordStatus.SENT));
        assertEq(record.chainSelector, SEPOLIA_SELECTOR);
        assertEq(record.sourceContract, sourceContract);
        assertEq(record.counterparty, counterparty);
        assertEq(record.assetToken, token);
        assertEq(record.amount, 1 ether);
        assertEq(record.actionHash, keccak256(bytes("transfer")));
        assertEq(record.metadataHash, keccak256(bytes("metadata")));
    }

    function test_RevertWhen_NonWriterAppendsRecord() public {
        UserRecordRegistry.RecordInput memory input = _defaultInput(alice);

        vm.expectRevert(abi.encodeWithSelector(UserRecordRegistry.UnauthorizedSystemWriter.selector, attacker));
        vm.prank(attacker);
        registry.appendRecord(input, keccak256("event-2"));
    }

    function test_RevertWhen_DuplicateExternalEventKey() public {
        UserRecordRegistry.RecordInput memory input = _defaultInput(alice);
        bytes32 key = keccak256("event-dup");

        vm.prank(writer);
        registry.appendRecord(input, key);

        vm.expectRevert(abi.encodeWithSelector(UserRecordRegistry.ExternalEventAlreadyUsed.selector, key));
        vm.prank(writer);
        registry.appendRecord(input, key);
    }

    function test_BatchAppend_WorksAndEnforcesConstraints() public {
        UserRecordRegistry.RecordInput[] memory inputs = new UserRecordRegistry.RecordInput[](2);
        bytes32[] memory keys = new bytes32[](2);

        inputs[0] = _defaultInput(alice);
        inputs[1] = _defaultInput(bob);
        keys[0] = keccak256("batch-0");
        keys[1] = keccak256("batch-1");

        vm.prank(writer);
        (uint256 first, uint256 last) = registry.appendRecordsBatch(inputs, keys);

        assertEq(first, 1);
        assertEq(last, 2);
        assertEq(registry.getUserRecordCount(alice), 1);
        assertEq(registry.getUserRecordCount(bob), 1);

        bytes32[] memory badKeys = new bytes32[](1);
        badKeys[0] = keccak256("bad");

        vm.expectRevert(UserRecordRegistry.InvalidBatchLength.selector);
        vm.prank(writer);
        registry.appendRecordsBatch(inputs, badKeys);

        uint256 tooMany = registry.MAX_BATCH_APPEND() + 1;
        UserRecordRegistry.RecordInput[] memory largeInputs = new UserRecordRegistry.RecordInput[](tooMany);
        bytes32[] memory largeKeys = new bytes32[](tooMany);
        for (uint256 i = 0; i < tooMany; i++) {
            largeInputs[i] = _defaultInput(alice);
            largeKeys[i] = keccak256(abi.encodePacked("large", i));
        }

        vm.expectRevert();
        vm.prank(writer);
        registry.appendRecordsBatch(largeInputs, largeKeys);
    }

    function test_PaginationReturnsDeterministicSlices() public {
        for (uint256 i = 0; i < 5; i++) {
            UserRecordRegistry.RecordInput memory input = _defaultInput(alice);
            input.messageId = bytes32(i + 1);
            vm.prank(writer);
            registry.appendRecord(input, keccak256(abi.encodePacked("page", i)));
        }

        uint256[] memory firstSlice = registry.getUserRecordIds(alice, 0, 2);
        uint256[] memory secondSlice = registry.getUserRecordIds(alice, 2, 2);
        uint256[] memory tailSlice = registry.getUserRecordIds(alice, 4, 3);

        assertEq(firstSlice.length, 2);
        assertEq(firstSlice[0], 1);
        assertEq(firstSlice[1], 2);

        assertEq(secondSlice.length, 2);
        assertEq(secondSlice[0], 3);
        assertEq(secondSlice[1], 4);

        assertEq(tailSlice.length, 1);
        assertEq(tailSlice[0], 5);
    }

    function test_EnumAndHashFieldsPersistCorrectly() public {
        UserRecordRegistry.RecordInput memory input = _defaultInput(alice);
        input.featureType = UserRecordRegistry.FeatureType.PROGRAMMABLE_TRANSFER;
        input.status = UserRecordRegistry.RecordStatus.PENDING_ACTION;
        input.actionHash = keccak256(bytes("stake"));
        input.metadataHash = keccak256(bytes("ipfs://cid"));

        vm.prank(writer);
        uint256 recordId = registry.appendRecord(input, keccak256("enum-hash"));

        UserRecordRegistry.Record memory record = registry.getRecord(recordId);
        assertEq(uint8(record.featureType), uint8(UserRecordRegistry.FeatureType.PROGRAMMABLE_TRANSFER));
        assertEq(uint8(record.status), uint8(UserRecordRegistry.RecordStatus.PENDING_ACTION));
        assertEq(record.actionHash, keccak256(bytes("stake")));
        assertEq(record.metadataHash, keccak256(bytes("ipfs://cid")));
    }

    function test_GasSanity_AppendSingleAndBatch() public {
        UserRecordRegistry.RecordInput memory single = _defaultInput(alice);

        uint256 gasBeforeSingle = gasleft();
        vm.prank(writer);
        registry.appendRecord(single, keccak256("gas-single"));
        uint256 gasUsedSingle = gasBeforeSingle - gasleft();

        UserRecordRegistry.RecordInput[] memory inputs = new UserRecordRegistry.RecordInput[](2);
        bytes32[] memory keys = new bytes32[](2);
        inputs[0] = _defaultInput(alice);
        inputs[1] = _defaultInput(bob);
        keys[0] = keccak256("gas-batch-0");
        keys[1] = keccak256("gas-batch-1");

        uint256 gasBeforeBatch = gasleft();
        vm.prank(writer);
        registry.appendRecordsBatch(inputs, keys);
        uint256 gasUsedBatch = gasBeforeBatch - gasleft();

        assertGt(gasUsedSingle, 0);
        assertGt(gasUsedBatch, 0);
    }

    function test_RevertWhen_InvalidInputFields() public {
        UserRecordRegistry.RecordInput memory input = _defaultInput(alice);

        input.user = address(0);
        vm.expectRevert();
        vm.prank(writer);
        registry.appendRecord(input, keccak256("invalid-user"));

        input = _defaultInput(alice);
        input.sourceContract = address(0);
        vm.expectRevert();
        vm.prank(writer);
        registry.appendRecord(input, keccak256("invalid-source"));

        input = _defaultInput(alice);
        input.counterparty = address(0);
        vm.expectRevert();
        vm.prank(writer);
        registry.appendRecord(input, keccak256("invalid-counterparty"));

        input = _defaultInput(alice);
        input.chainSelector = 0;
        vm.expectRevert(UserRecordRegistry.InvalidChainSelector.selector);
        vm.prank(writer);
        registry.appendRecord(input, keccak256("invalid-chain"));

        input = _defaultInput(alice);
        input.assetToken = address(0);
        input.amount = 1;
        vm.expectRevert();
        vm.prank(writer);
        registry.appendRecord(input, keccak256("invalid-token"));

        vm.expectRevert(UserRecordRegistry.InvalidExternalEventKey.selector);
        vm.prank(writer);
        registry.appendRecord(_defaultInput(alice), bytes32(0));
    }

    function _defaultInput(address user) internal view returns (UserRecordRegistry.RecordInput memory input) {
        input = UserRecordRegistry.RecordInput({
            user: user,
            featureType: UserRecordRegistry.FeatureType.AUTOMATED_TRADER,
            chainSelector: SEPOLIA_SELECTOR,
            sourceContract: sourceContract,
            counterparty: counterparty,
            messageId: keccak256(bytes("message-id")),
            assetToken: token,
            amount: 1 ether,
            actionHash: keccak256(bytes("transfer")),
            status: UserRecordRegistry.RecordStatus.SENT,
            metadataHash: keccak256(bytes("metadata"))
        });
    }
}
