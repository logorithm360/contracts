// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SecurityManager
/// @notice Feature 6 cross-feature security policy engine.
contract SecurityManager is Ownable, ReentrancyGuard {
    error ZeroAddress();
    error NotAuthorisedCaller(address caller);
    error SystemPaused();
    error InvalidLimit();
    error RateLimitExceeded(address user, uint256 used, uint256 limit);
    error AmountLimitExceeded(address token, uint256 amount, uint256 limit);

    enum FeatureId {
        MESSAGE,
        TOKEN_TRANSFER,
        PROGRAMMABLE_TRANSFER,
        AUTOMATED_TRADER,
        STORAGE
    }

    enum EnforcementMode {
        MONITOR,
        ENFORCE
    }

    struct RateLimitState {
        uint64 windowHour;
        uint256 used;
    }

    struct Incident {
        uint256 at;
        address actor;
        FeatureId feature;
        bytes32 reason;
        bytes32 ref;
    }

    EnforcementMode public enforcementMode = EnforcementMode.MONITOR;
    bool public paused;
    uint256 public globalRateLimitPerHour = 100;

    mapping(address => bool) public authorisedCallers;
    mapping(address => uint256) public customRateLimitPerHour;
    mapping(address => uint256) public amountLimitPerToken;
    mapping(address => RateLimitState) public rateState;

    Incident[] private s_incidents;

    event EnforcementModeUpdated(EnforcementMode mode);
    event CallerAuthorised(address indexed caller, bool authorised);
    event SystemPausedEvent(address indexed by, bytes32 reason);
    event SystemUnpausedEvent(address indexed by);
    event GlobalRateLimitUpdated(uint256 newLimit);
    event CustomRateLimitUpdated(address indexed user, uint256 newLimit);
    event AmountLimitUpdated(address indexed token, uint256 newLimit);
    event ActionValidated(address indexed user, FeatureId indexed feature, bytes32 indexed actionKey, uint256 weight);
    event TransferValidated(address indexed user, FeatureId indexed feature, address indexed token, uint256 amount);
    event PolicyViolation(
        address indexed user, FeatureId indexed feature, bytes32 indexed reason, bytes32 ref, EnforcementMode mode
    );
    event IncidentLogged(
        uint256 indexed id, address indexed actor, FeatureId indexed feature, bytes32 reason, bytes32 ref
    );

    constructor() Ownable(msg.sender) {}

    modifier onlyAuthorisedCaller() {
        if (!authorisedCallers[msg.sender]) revert NotAuthorisedCaller(msg.sender);
        _;
    }

    function validateAction(address _user, FeatureId _feature, bytes32 _actionKey, uint256 _weight)
        external
        onlyAuthorisedCaller
    {
        if (_user == address(0)) revert ZeroAddress();
        if (_weight == 0) _weight = 1;

        if (paused) {
            _handleViolation(_user, _feature, "PAUSED", _actionKey);
            if (enforcementMode == EnforcementMode.ENFORCE) revert SystemPaused();
        }

        (bool ok, uint256 used, uint256 limit) = _consumeRate(_user, _weight);
        if (!ok) {
            _handleViolation(_user, _feature, "RATE_LIMIT", _actionKey);
            if (enforcementMode == EnforcementMode.ENFORCE) revert RateLimitExceeded(_user, used, limit);
        }

        emit ActionValidated(_user, _feature, _actionKey, _weight);
    }

    function validateTransfer(address _user, FeatureId _feature, address _token, uint256 _amount)
        external
        onlyAuthorisedCaller
    {
        if (_user == address(0) || _token == address(0)) revert ZeroAddress();

        if (paused) {
            _handleViolation(_user, _feature, "PAUSED", bytes32(uint256(uint160(_token))));
            if (enforcementMode == EnforcementMode.ENFORCE) revert SystemPaused();
        }

        (bool ok, uint256 used, uint256 limit) = _consumeRate(_user, 1);
        if (!ok) {
            _handleViolation(_user, _feature, "RATE_LIMIT", bytes32(uint256(uint160(_token))));
            if (enforcementMode == EnforcementMode.ENFORCE) revert RateLimitExceeded(_user, used, limit);
        }

        uint256 tokenLimit = amountLimitPerToken[_token];
        if (tokenLimit > 0 && _amount > tokenLimit) {
            _handleViolation(_user, _feature, "AMOUNT_LIMIT", bytes32(uint256(_amount)));
            if (enforcementMode == EnforcementMode.ENFORCE) {
                revert AmountLimitExceeded(_token, _amount, tokenLimit);
            }
        }

        emit TransferValidated(_user, _feature, _token, _amount);
    }

    function logIncident(address _actor, FeatureId _feature, bytes32 _reason, bytes32 _ref)
        external
        onlyAuthorisedCaller
    {
        _recordIncident(_actor, _feature, _reason, _ref);
    }

    function getSystemHealth()
        external
        view
        returns (bool healthy, bool systemPaused, EnforcementMode mode, uint256 totalIncidents, uint256 globalLimit)
    {
        healthy = !paused;
        systemPaused = paused;
        mode = enforcementMode;
        totalIncidents = s_incidents.length;
        globalLimit = globalRateLimitPerHour;
    }

    function getRecentIncidents(uint256 _count) external view returns (Incident[] memory out) {
        uint256 len = s_incidents.length;
        if (_count == 0 || len == 0) return new Incident[](0);
        if (_count > len) _count = len;

        out = new Incident[](_count);
        for (uint256 i = 0; i < _count; i++) {
            out[i] = s_incidents[len - 1 - i];
        }
    }

    function authoriseCaller(address _caller, bool _authorised) external onlyOwner {
        if (_caller == address(0)) revert ZeroAddress();
        authorisedCallers[_caller] = _authorised;
        emit CallerAuthorised(_caller, _authorised);
    }

    function setEnforcementMode(EnforcementMode _mode) external onlyOwner {
        enforcementMode = _mode;
        emit EnforcementModeUpdated(_mode);
    }

    function pause(bytes32 _reason) external onlyOwner {
        paused = true;
        emit SystemPausedEvent(msg.sender, _reason);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit SystemUnpausedEvent(msg.sender);
    }

    function setGlobalRateLimit(uint256 _limit) external onlyOwner {
        if (_limit == 0) revert InvalidLimit();
        globalRateLimitPerHour = _limit;
        emit GlobalRateLimitUpdated(_limit);
    }

    function setCustomRateLimit(address _user, uint256 _limit) external onlyOwner {
        if (_user == address(0)) revert ZeroAddress();
        customRateLimitPerHour[_user] = _limit;
        emit CustomRateLimitUpdated(_user, _limit);
    }

    function setAmountLimit(address _token, uint256 _limit) external onlyOwner {
        if (_token == address(0)) revert ZeroAddress();
        amountLimitPerToken[_token] = _limit;
        emit AmountLimitUpdated(_token, _limit);
    }

    function _consumeRate(address _user, uint256 _weight) internal returns (bool ok, uint256 used, uint256 limit) {
        RateLimitState storage state = rateState[_user];
        uint64 currentHour = uint64(block.timestamp / 1 hours);

        if (state.windowHour != currentHour) {
            state.windowHour = currentHour;
            state.used = 0;
        }

        limit = customRateLimitPerHour[_user];
        if (limit == 0) limit = globalRateLimitPerHour;
        if (limit == 0) return (true, state.used, 0);

        used = state.used + _weight;
        state.used = used;
        ok = used <= limit;
    }

    function _handleViolation(address _user, FeatureId _feature, bytes32 _reason, bytes32 _ref) internal {
        emit PolicyViolation(_user, _feature, _reason, _ref, enforcementMode);
        _recordIncident(_user, _feature, _reason, _ref);
    }

    function _recordIncident(address _actor, FeatureId _feature, bytes32 _reason, bytes32 _ref) internal {
        s_incidents.push(Incident({at: block.timestamp, actor: _actor, feature: _feature, reason: _reason, ref: _ref}));
        emit IncidentLogged(s_incidents.length - 1, _actor, _feature, _reason, _ref);
    }
}
