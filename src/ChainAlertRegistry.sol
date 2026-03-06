// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ChainAlertRegistry
/// @notice On-chain rule/state registry for Feature 4 monitoring and alert deduplication.
contract ChainAlertRegistry is Ownable {
    error ZeroAddress();
    error EmptyParams();
    error RuleNotFound(uint256 ruleId);
    error UnauthorizedRuleOwner(address caller, uint256 ruleId);
    error UnauthorizedWorkflow(address caller);

    enum AlertType {
        PORTFOLIO_DROP_PERCENT,
        PORTFOLIO_DROP_ABSOLUTE,
        TOKEN_CONCENTRATION,
        TOKEN_FLAGGED_SUSPICIOUS,
        TOKEN_PRICE_SPIKE,
        TOKEN_LIQUIDITY_DROP,
        TOKEN_HOLDER_CONCENTRATION,
        DCA_ORDER_FAILED,
        DCA_LOW_FUNDS,
        DCA_ORDER_PAUSED_BY_AI,
        DCA_EXECUTION_STUCK,
        WALLET_LARGE_OUTFLOW,
        WALLET_INTERACTION_WITH_FLAGGED,
        WALLET_NEW_TOKEN_RECEIVED
    }

    struct AlertRule {
        uint256 ruleId;
        address owner;
        AlertType alertType;
        bool enabled;
        uint32 cooldownSeconds;
        uint32 rearmSeconds;
        string paramsJson;
        uint64 createdAt;
        uint64 updatedAt;
    }

    struct AlertState {
        bool active;
        uint64 lastCheckedAt;
        uint64 lastTriggeredAt;
        uint64 lastResolvedAt;
        int256 lastMetric;
        bytes32 lastFingerprint;
        uint32 triggerCount;
    }

    uint256 public nextRuleId = 1;

    mapping(uint256 => AlertRule) private s_rules;
    mapping(uint256 => AlertState) private s_states;
    mapping(address => uint256[]) private s_userRuleIds;

    mapping(address => bool) public authorizedWorkflows;

    event AlertRuleUpserted(
        uint256 indexed ruleId,
        address indexed owner,
        AlertType indexed alertType,
        bool enabled,
        uint32 cooldownSeconds,
        uint32 rearmSeconds,
        bytes32 paramsHash
    );
    event AlertRuleEnabled(uint256 indexed ruleId, bool enabled, address indexed updatedBy);
    event AlertTriggered(
        uint256 indexed ruleId, uint64 indexed triggeredAt, int256 metric, bytes32 fingerprint, string reason
    );
    event AlertResolved(
        uint256 indexed ruleId, uint64 indexed resolvedAt, int256 metric, bytes32 fingerprint, string reason
    );
    event AlertSuppressed(uint256 indexed ruleId, uint64 indexed at, int256 metric, bytes32 fingerprint, string reason);
    event WorkflowAuthorizerUpdated(address indexed workflow, bool enabled, address indexed updatedBy);

    constructor() Ownable(msg.sender) {
        authorizedWorkflows[msg.sender] = true;
        emit WorkflowAuthorizerUpdated(msg.sender, true, msg.sender);
    }

    modifier onlyWorkflow() {
        if (!authorizedWorkflows[msg.sender]) revert UnauthorizedWorkflow(msg.sender);
        _;
    }

    function upsertRule(
        uint256 _ruleId,
        AlertType _alertType,
        bool _enabled,
        uint32 _cooldownSeconds,
        uint32 _rearmSeconds,
        string calldata _paramsJson
    ) external returns (uint256 ruleId) {
        if (bytes(_paramsJson).length == 0) revert EmptyParams();

        uint64 nowTs = uint64(block.timestamp);

        if (_ruleId == 0) {
            ruleId = nextRuleId;
            nextRuleId++;

            AlertRule storage created = s_rules[ruleId];
            created.ruleId = ruleId;
            created.owner = msg.sender;
            created.alertType = _alertType;
            created.enabled = _enabled;
            created.cooldownSeconds = _cooldownSeconds;
            created.rearmSeconds = _rearmSeconds;
            created.paramsJson = _paramsJson;
            created.createdAt = nowTs;
            created.updatedAt = nowTs;

            s_userRuleIds[msg.sender].push(ruleId);
        } else {
            AlertRule storage existing = s_rules[_ruleId];
            if (existing.ruleId == 0) revert RuleNotFound(_ruleId);
            if (existing.owner != msg.sender) revert UnauthorizedRuleOwner(msg.sender, _ruleId);

            existing.alertType = _alertType;
            existing.enabled = _enabled;
            existing.cooldownSeconds = _cooldownSeconds;
            existing.rearmSeconds = _rearmSeconds;
            existing.paramsJson = _paramsJson;
            existing.updatedAt = nowTs;

            ruleId = _ruleId;
        }

        emit AlertRuleUpserted(
            ruleId, msg.sender, _alertType, _enabled, _cooldownSeconds, _rearmSeconds, keccak256(bytes(_paramsJson))
        );
    }

    function setRuleEnabled(uint256 _ruleId, bool _enabled) external {
        AlertRule storage rule = s_rules[_ruleId];
        if (rule.ruleId == 0) revert RuleNotFound(_ruleId);
        if (rule.owner != msg.sender) revert UnauthorizedRuleOwner(msg.sender, _ruleId);

        rule.enabled = _enabled;
        rule.updatedAt = uint64(block.timestamp);
        emit AlertRuleEnabled(_ruleId, _enabled, msg.sender);
    }

    function setWorkflowAuthorizer(address _workflow, bool _enabled) external onlyOwner {
        if (_workflow == address(0)) revert ZeroAddress();
        authorizedWorkflows[_workflow] = _enabled;
        emit WorkflowAuthorizerUpdated(_workflow, _enabled, msg.sender);
    }

    function getRule(uint256 _ruleId) external view returns (AlertRule memory) {
        AlertRule memory rule = s_rules[_ruleId];
        if (rule.ruleId == 0) revert RuleNotFound(_ruleId);
        return rule;
    }

    function getRuleState(uint256 _ruleId) external view returns (AlertState memory) {
        if (s_rules[_ruleId].ruleId == 0) revert RuleNotFound(_ruleId);
        return s_states[_ruleId];
    }

    function getUserRuleIds(address _owner) external view returns (uint256[] memory) {
        return s_userRuleIds[_owner];
    }

    function recordEvaluation(
        uint256 _ruleId,
        int256 _metric,
        bytes32 _fingerprint,
        bool _conditionMet,
        string calldata _note
    ) external onlyWorkflow {
        AlertRule storage rule = s_rules[_ruleId];
        if (rule.ruleId == 0) revert RuleNotFound(_ruleId);

        AlertState storage state = s_states[_ruleId];
        uint64 nowTs = uint64(block.timestamp);
        state.lastCheckedAt = nowTs;
        state.lastMetric = _metric;
        state.lastFingerprint = _fingerprint;

        if (_conditionMet && !rule.enabled) {
            emit AlertSuppressed(_ruleId, nowTs, _metric, _fingerprint, _defaultReason(_note, "RULE_DISABLED"));
        }
    }

    function recordTrigger(uint256 _ruleId, int256 _metric, bytes32 _fingerprint, string calldata _reason)
        external
        onlyWorkflow
        returns (bool triggered)
    {
        AlertRule storage rule = s_rules[_ruleId];
        if (rule.ruleId == 0) revert RuleNotFound(_ruleId);

        AlertState storage state = s_states[_ruleId];
        uint64 nowTs = uint64(block.timestamp);
        state.lastCheckedAt = nowTs;
        state.lastMetric = _metric;
        state.lastFingerprint = _fingerprint;

        if (!rule.enabled) {
            emit AlertSuppressed(_ruleId, nowTs, _metric, _fingerprint, "RULE_DISABLED");
            return false;
        }

        if (state.active && nowTs < state.lastTriggeredAt + rule.cooldownSeconds) {
            emit AlertSuppressed(_ruleId, nowTs, _metric, _fingerprint, "COOLDOWN_ACTIVE");
            return false;
        }

        if (!state.active && state.lastResolvedAt > 0 && nowTs < state.lastResolvedAt + rule.rearmSeconds) {
            emit AlertSuppressed(_ruleId, nowTs, _metric, _fingerprint, "REARM_WINDOW_ACTIVE");
            return false;
        }

        state.active = true;
        state.lastTriggeredAt = nowTs;
        state.triggerCount += 1;

        emit AlertTriggered(_ruleId, nowTs, _metric, _fingerprint, _defaultReason(_reason, "TRIGGERED"));
        return true;
    }

    function recordResolve(uint256 _ruleId, int256 _metric, bytes32 _fingerprint, string calldata _reason)
        external
        onlyWorkflow
        returns (bool resolved)
    {
        AlertRule storage rule = s_rules[_ruleId];
        if (rule.ruleId == 0) revert RuleNotFound(_ruleId);

        AlertState storage state = s_states[_ruleId];
        uint64 nowTs = uint64(block.timestamp);
        state.lastCheckedAt = nowTs;
        state.lastMetric = _metric;
        state.lastFingerprint = _fingerprint;

        if (!state.active) {
            emit AlertSuppressed(_ruleId, nowTs, _metric, _fingerprint, "NOT_ACTIVE");
            return false;
        }

        state.active = false;
        state.lastResolvedAt = nowTs;

        emit AlertResolved(_ruleId, nowTs, _metric, _fingerprint, _defaultReason(_reason, "RESOLVED"));
        return true;
    }

    function _defaultReason(string calldata _reason, string memory _fallback) internal pure returns (string memory) {
        if (bytes(_reason).length > 0) return _reason;
        return _fallback;
    }
}
