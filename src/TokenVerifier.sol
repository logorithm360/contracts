// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title TokenVerifier
/// @notice Feature 6 V1 token safety gate (on-chain only, no Functions/JS execution).
contract TokenVerifier is Ownable {
    error ZeroAddress();
    error NotAuthorisedCaller(address caller);
    error NoCodeAtAddress(address token);
    error InvalidERC20(address token);
    error InvalidDecimals(address token, uint8 decimals);
    error ZeroTotalSupply(address token);

    enum VerificationStatus {
        NOT_VERIFIED,
        PENDING,
        SAFE,
        SUSPICIOUS,
        DANGEROUS,
        ALLOWLISTED,
        BLOCKLISTED
    }

    struct VerificationResult {
        address token;
        VerificationStatus status;
        uint256 riskScore;
        uint256 verifiedAt;
        uint256 expiresAt;
        bool isHoneypot;
        bool hasTransferTax;
        uint256 transferTaxBps;
        bool isBlacklisted;
        bytes32 lastRequestId;
    }

    mapping(address => bool) public allowlist;
    mapping(address => bool) public blocklist;
    mapping(address => uint256) public maxTransferLimits;
    mapping(address => bool) public authorisedCallers;
    mapping(address => VerificationResult) public verifications;

    event TokenAllowlisted(address indexed token, bool allowed);
    event TokenBlocklisted(address indexed token, string reason);
    event TokenBlocklistRemoved(address indexed token);
    event AuthorisedCallerUpdated(address indexed caller, bool allowed);
    event MaxTransferLimitUpdated(address indexed token, uint256 limit);
    event Layer1CheckPassed(address indexed token);
    event Layer1CheckFailed(address indexed token, bytes32 reasonCode);

    constructor() Ownable(msg.sender) {}

    modifier onlyAuthorisedCaller() {
        if (!authorisedCallers[msg.sender]) revert NotAuthorisedCaller(msg.sender);
        _;
    }

    /// @notice Deterministic Layer1 token checks. Reverts on failure.
    function verifyTokenLayer1(address _token) public returns (VerificationStatus status) {
        if (_token == address(0)) revert ZeroAddress();

        if (allowlist[_token]) {
            _upsertStatus(_token, VerificationStatus.ALLOWLISTED);
            emit Layer1CheckPassed(_token);
            return VerificationStatus.ALLOWLISTED;
        }

        if (blocklist[_token]) {
            _upsertStatus(_token, VerificationStatus.BLOCKLISTED);
            emit Layer1CheckFailed(_token, "BLOCKLISTED");
            return VerificationStatus.BLOCKLISTED;
        }

        if (_token.code.length == 0) {
            emit Layer1CheckFailed(_token, "NO_CODE");
            revert NoCodeAtAddress(_token);
        }

        try IERC20Metadata(_token).decimals() returns (uint8 dec) {
            if (dec == 0 || dec > 18) {
                emit Layer1CheckFailed(_token, "BAD_DECIMALS");
                revert InvalidDecimals(_token, dec);
            }
        } catch {
            emit Layer1CheckFailed(_token, "NO_DECIMALS");
            revert InvalidERC20(_token);
        }

        try IERC20Metadata(_token).name() returns (string memory) {}
        catch {
            emit Layer1CheckFailed(_token, "NO_NAME");
            revert InvalidERC20(_token);
        }

        try IERC20Metadata(_token).symbol() returns (string memory) {}
        catch {
            emit Layer1CheckFailed(_token, "NO_SYMBOL");
            revert InvalidERC20(_token);
        }

        uint256 supply;
        try IERC20Metadata(_token).totalSupply() returns (uint256 totalSupply_) {
            supply = totalSupply_;
        } catch {
            emit Layer1CheckFailed(_token, "NO_SUPPLY");
            revert InvalidERC20(_token);
        }

        if (supply == 0) {
            emit Layer1CheckFailed(_token, "ZERO_SUPPLY");
            revert ZeroTotalSupply(_token);
        }

        _upsertStatus(_token, VerificationStatus.SAFE);
        emit Layer1CheckPassed(_token);
        return VerificationStatus.SAFE;
    }

    /// @notice Primary token safety gate for feature sender contracts.
    function isTransferSafe(address _token, uint256 _amount) external onlyAuthorisedCaller returns (bool) {
        if (_token == address(0)) revert ZeroAddress();

        if (blocklist[_token]) {
            _upsertStatus(_token, VerificationStatus.BLOCKLISTED);
            return false;
        }

        if (allowlist[_token]) {
            _upsertStatus(_token, VerificationStatus.ALLOWLISTED);
            return _withinAmountLimit(_token, _amount);
        }

        try this.verifyTokenLayer1(_token) returns (VerificationStatus status) {
            return status != VerificationStatus.BLOCKLISTED && _withinAmountLimit(_token, _amount);
        } catch {
            return false;
        }
    }

    function getStatus(address _token) external view returns (VerificationStatus) {
        return verifications[_token].status;
    }

    function getVerdict(address _token) external view returns (VerificationResult memory) {
        return verifications[_token];
    }

    function addToAllowlist(address _token, bool _allowed) external onlyOwner {
        if (_token == address(0)) revert ZeroAddress();
        allowlist[_token] = _allowed;
        if (_allowed) {
            blocklist[_token] = false;
            _upsertStatus(_token, VerificationStatus.ALLOWLISTED);
        } else if (!blocklist[_token]) {
            _upsertStatus(_token, VerificationStatus.NOT_VERIFIED);
        }
        emit TokenAllowlisted(_token, _allowed);
    }

    function addToBlocklist(address _token, string calldata _reason) external onlyOwner {
        if (_token == address(0)) revert ZeroAddress();
        blocklist[_token] = true;
        allowlist[_token] = false;
        _upsertStatus(_token, VerificationStatus.BLOCKLISTED);
        emit TokenBlocklisted(_token, _reason);
    }

    function removeFromBlocklist(address _token) external onlyOwner {
        if (_token == address(0)) revert ZeroAddress();
        blocklist[_token] = false;
        if (!allowlist[_token]) {
            _upsertStatus(_token, VerificationStatus.NOT_VERIFIED);
        }
        emit TokenBlocklistRemoved(_token);
    }

    function setMaxTransferLimit(address _token, uint256 _limit) external onlyOwner {
        if (_token == address(0)) revert ZeroAddress();
        maxTransferLimits[_token] = _limit;
        emit MaxTransferLimitUpdated(_token, _limit);
    }

    function setAuthorisedCaller(address _caller, bool _allowed) external onlyOwner {
        if (_caller == address(0)) revert ZeroAddress();
        authorisedCallers[_caller] = _allowed;
        emit AuthorisedCallerUpdated(_caller, _allowed);
    }

    function _withinAmountLimit(address _token, uint256 _amount) internal view returns (bool) {
        uint256 limit = maxTransferLimits[_token];
        if (limit == 0) return true;
        return _amount <= limit;
    }

    function _upsertStatus(address _token, VerificationStatus _status) internal {
        VerificationResult storage v = verifications[_token];
        v.token = _token;
        v.status = _status;
        v.verifiedAt = block.timestamp;
    }
}
