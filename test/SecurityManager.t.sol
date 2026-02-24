// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {SecurityManager} from "../src/SecurityManager.sol";

contract SecurityCaller {
    SecurityManager internal security;

    constructor(address security_) {
        security = SecurityManager(security_);
    }

    function validateAction(address user, uint8 feature, bytes32 key, uint256 weight) external {
        security.validateAction(user, SecurityManager.FeatureId(feature), key, weight);
    }

    function validateTransfer(address user, uint8 feature, address token, uint256 amount) external {
        security.validateTransfer(user, SecurityManager.FeatureId(feature), token, amount);
    }

    function report(address user, uint8 feature, bytes32 reason, bytes32 ref) external {
        security.logIncident(user, SecurityManager.FeatureId(feature), reason, ref);
    }
}

contract SecurityManagerTest is Test {
    SecurityManager internal security;
    SecurityCaller internal caller;

    address internal alice = makeAddr("alice");
    address internal token = makeAddr("token");

    function setUp() public {
        security = new SecurityManager();
        caller = new SecurityCaller(address(security));
        security.authoriseCaller(address(caller), true);
    }

    function test_monitorModeAllowsButLogsViolation() public {
        security.setGlobalRateLimit(1);

        caller.validateAction(alice, 0, keccak256("one"), 1);
        caller.validateAction(alice, 0, keccak256("two"), 1);

        (,,, uint256 incidents,) = security.getSystemHealth();
        assertGt(incidents, 0);
    }

    function test_enforceModeBlocksRateLimit() public {
        security.setGlobalRateLimit(1);
        security.setEnforcementMode(SecurityManager.EnforcementMode.ENFORCE);

        caller.validateAction(alice, 0, keccak256("one"), 1);

        vm.expectRevert();
        caller.validateAction(alice, 0, keccak256("two"), 1);
    }

    function test_pauseBlocksInEnforceMode() public {
        security.setEnforcementMode(SecurityManager.EnforcementMode.ENFORCE);
        security.pause("PAUSED");

        vm.expectRevert(SecurityManager.SystemPaused.selector);
        caller.validateAction(alice, 0, keccak256("msg"), 1);
    }

    function test_amountLimitEnforced() public {
        security.setAmountLimit(token, 100);
        security.setEnforcementMode(SecurityManager.EnforcementMode.ENFORCE);

        vm.expectRevert();
        caller.validateTransfer(alice, 1, token, 101);

        caller.validateTransfer(alice, 1, token, 99);
    }

    function test_onlyAuthorisedCaller() public {
        vm.expectRevert(abi.encodeWithSelector(SecurityManager.NotAuthorisedCaller.selector, address(this)));
        security.validateAction(alice, SecurityManager.FeatureId.MESSAGE, bytes32("x"), 1);
    }
}
