// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {ChainAlertRegistry} from "../src/ChainAlertRegistry.sol";

contract ChainAlertRegistryTest is Test {
    ChainAlertRegistry internal registry;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal workflow = makeAddr("workflow");

    function setUp() public {
        registry = new ChainAlertRegistry();
    }

    function test_UpsertCreateAndUpdateRule() public {
        vm.prank(alice);
        uint256 ruleId = registry.upsertRule(
            0, ChainAlertRegistry.AlertType.DCA_LOW_FUNDS, true, 300, 180, '{"orderIds":[1],"threshold":3}'
        );

        ChainAlertRegistry.AlertRule memory created = registry.getRule(ruleId);
        assertEq(ruleId, 1);
        assertEq(created.ruleId, 1);
        assertEq(created.owner, alice);
        assertEq(uint8(created.alertType), uint8(ChainAlertRegistry.AlertType.DCA_LOW_FUNDS));
        assertTrue(created.enabled);
        assertEq(created.cooldownSeconds, 300);
        assertEq(created.rearmSeconds, 180);

        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        uint256 updatedId = registry.upsertRule(
            ruleId, ChainAlertRegistry.AlertType.DCA_ORDER_FAILED, false, 120, 90, '{"orderIds":[1,2],"any":true}'
        );

        ChainAlertRegistry.AlertRule memory updated = registry.getRule(updatedId);
        assertEq(updatedId, ruleId);
        assertEq(uint8(updated.alertType), uint8(ChainAlertRegistry.AlertType.DCA_ORDER_FAILED));
        assertFalse(updated.enabled);
        assertEq(updated.cooldownSeconds, 120);
        assertEq(updated.rearmSeconds, 90);
        assertGt(updated.updatedAt, created.updatedAt);
    }

    function test_RevertWhen_NonOwnerUpdatesRule() public {
        vm.prank(alice);
        uint256 ruleId = registry.upsertRule(
            0,
            ChainAlertRegistry.AlertType.TOKEN_FLAGGED_SUSPICIOUS,
            true,
            60,
            60,
            '{"token":"0x0000000000000000000000000000000000000001"}'
        );

        vm.expectRevert(abi.encodeWithSelector(ChainAlertRegistry.UnauthorizedRuleOwner.selector, bob, ruleId));
        vm.prank(bob);
        registry.upsertRule(
            ruleId,
            ChainAlertRegistry.AlertType.TOKEN_FLAGGED_SUSPICIOUS,
            true,
            60,
            60,
            '{"token":"0x0000000000000000000000000000000000000002"}'
        );
    }

    function test_SetRuleEnabled() public {
        vm.prank(alice);
        uint256 ruleId = registry.upsertRule(
            0,
            ChainAlertRegistry.AlertType.WALLET_NEW_TOKEN_RECEIVED,
            true,
            120,
            120,
            '{"wallet":"0x0000000000000000000000000000000000000001"}'
        );

        vm.prank(alice);
        registry.setRuleEnabled(ruleId, false);

        ChainAlertRegistry.AlertRule memory rule = registry.getRule(ruleId);
        assertFalse(rule.enabled);
    }

    function test_RevertWhen_UnauthorizedWorkflowWriter() public {
        vm.prank(alice);
        uint256 ruleId =
            registry.upsertRule(0, ChainAlertRegistry.AlertType.DCA_ORDER_FAILED, true, 60, 60, '{"orderIds":[1]}');

        vm.expectRevert(abi.encodeWithSelector(ChainAlertRegistry.UnauthorizedWorkflow.selector, workflow));
        vm.prank(workflow);
        registry.recordTrigger(ruleId, 1, keccak256("fail"), "ORDER_FAILED");
    }

    function test_TriggerCooldownResolveAndRearm() public {
        vm.prank(alice);
        uint256 ruleId =
            registry.upsertRule(0, ChainAlertRegistry.AlertType.DCA_LOW_FUNDS, true, 60, 120, '{"threshold":3}');

        registry.setWorkflowAuthorizer(workflow, true);

        vm.prank(workflow);
        bool first = registry.recordTrigger(ruleId, 2, keccak256("first"), "LOW_FUNDS");
        assertTrue(first);

        ChainAlertRegistry.AlertState memory state = registry.getRuleState(ruleId);
        assertTrue(state.active);
        assertEq(state.triggerCount, 1);

        vm.warp(block.timestamp + 30);
        vm.prank(workflow);
        bool suppressedCooldown = registry.recordTrigger(ruleId, 1, keccak256("second"), "LOW_FUNDS");
        assertFalse(suppressedCooldown);

        vm.prank(workflow);
        bool resolved = registry.recordResolve(ruleId, 3, keccak256("resolved"), "RECOVERED");
        assertTrue(resolved);

        ChainAlertRegistry.AlertState memory resolvedState = registry.getRuleState(ruleId);
        assertFalse(resolvedState.active);
        uint64 resolvedAt = resolvedState.lastResolvedAt;

        vm.warp(block.timestamp + 30);
        vm.prank(workflow);
        bool suppressedRearm = registry.recordTrigger(ruleId, 1, keccak256("third"), "LOW_FUNDS");
        assertFalse(suppressedRearm);

        vm.warp(resolvedAt + 121);
        vm.prank(workflow);
        bool secondTrigger = registry.recordTrigger(ruleId, 1, keccak256("fourth"), "LOW_FUNDS");
        assertTrue(secondTrigger);

        ChainAlertRegistry.AlertState memory finalState = registry.getRuleState(ruleId);
        assertTrue(finalState.active);
        assertEq(finalState.triggerCount, 2);
    }

    function test_RecordResolveSuppressesWhenInactive() public {
        vm.prank(alice);
        uint256 ruleId = registry.upsertRule(
            0,
            ChainAlertRegistry.AlertType.TOKEN_LIQUIDITY_DROP,
            true,
            60,
            60,
            '{"token":"0x0000000000000000000000000000000000000001","threshold":0.4}'
        );

        registry.setWorkflowAuthorizer(workflow, true);

        vm.prank(workflow);
        bool resolved = registry.recordResolve(ruleId, 0, keccak256("none"), "NO_ACTIVE_ALERT");
        assertFalse(resolved);

        ChainAlertRegistry.AlertState memory state = registry.getRuleState(ruleId);
        assertFalse(state.active);
        assertEq(state.lastResolvedAt, 0);
    }
}
