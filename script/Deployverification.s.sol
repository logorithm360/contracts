// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {SecurityManager} from "../src/SecurityManager.sol";
import {TokenVerifier} from "../src/TokenVerifier.sol";
import {SupportedNetworks} from "./utils/SupportedNetworks.sol";

contract DeployVerification is Script {
    function run() external returns (TokenVerifier verifier, SecurityManager security) {
        require(SupportedNetworks.isSupportedChainId(block.chainid), "Unsupported chain");

        console.log("Deploying Feature 6 contracts on", SupportedNetworks.nameByChainId(block.chainid));

        vm.startBroadcast();
        verifier = new TokenVerifier();
        security = new SecurityManager();
        security.setEnforcementMode(SecurityManager.EnforcementMode.MONITOR);
        vm.stopBroadcast();

        console.log("TokenVerifier deployed:", address(verifier));
        console.log("SecurityManager deployed:", address(security));
        console.log("Enforcement mode:", "MONITOR");
    }
}

contract SetEnforcementMode is Script {
    function run() external {
        address securityAddr = vm.envAddress("SECURITY_MANAGER_CONTRACT");
        uint256 mode = vm.envUint("SECURITY_ENFORCEMENT_MODE"); // 0 monitor, 1 enforce
        require(securityAddr != address(0), "SECURITY_MANAGER_CONTRACT not set");
        require(mode <= 1, "SECURITY_ENFORCEMENT_MODE must be 0 or 1");

        vm.startBroadcast();
        SecurityManager(securityAddr).setEnforcementMode(SecurityManager.EnforcementMode(mode));
        vm.stopBroadcast();

        console.log("Security enforcement mode set to", mode == 0 ? "MONITOR" : "ENFORCE");
    }
}

contract AuthoriseFeatureCallers is Script {
    function run() external {
        address securityAddr = vm.envAddress("SECURITY_MANAGER_CONTRACT");
        address verifierAddr = vm.envAddress("TOKEN_VERIFIER_CONTRACT");
        require(securityAddr != address(0), "SECURITY_MANAGER_CONTRACT not set");
        require(verifierAddr != address(0), "TOKEN_VERIFIER_CONTRACT not set");

        address messagingSender = vm.envOr("MESSAGING_SENDER", address(0));
        address tokenSender = vm.envOr("TOKEN_SENDER", address(0));
        address programmableSender = vm.envOr("PROGRAMMABLE_SENDER", address(0));
        address automatedTrader = vm.envOr("AUTOMATED_TRADER", address(0));
        address userRecordRegistry = vm.envOr("USER_RECORD_REGISTRY", address(0));

        vm.startBroadcast();

        _authorisePair(securityAddr, verifierAddr, messagingSender, "MESSAGING_SENDER");
        _authorisePair(securityAddr, verifierAddr, tokenSender, "TOKEN_SENDER");
        _authorisePair(securityAddr, verifierAddr, programmableSender, "PROGRAMMABLE_SENDER");
        _authorisePair(securityAddr, verifierAddr, automatedTrader, "AUTOMATED_TRADER");
        _authorisePair(securityAddr, verifierAddr, userRecordRegistry, "USER_RECORD_REGISTRY");

        vm.stopBroadcast();
    }

    function _authorisePair(address securityAddr, address verifierAddr, address callerAddr, string memory label)
        internal
    {
        if (callerAddr == address(0)) return;

        SecurityManager(securityAddr).authoriseCaller(callerAddr, true);
        TokenVerifier(verifierAddr).setAuthorisedCaller(callerAddr, true);
        console.log("Authorised", label, callerAddr);
    }
}

contract ConfigurePolicyLimits is Script {
    function run() external {
        address securityAddr = vm.envAddress("SECURITY_MANAGER_CONTRACT");
        require(securityAddr != address(0), "SECURITY_MANAGER_CONTRACT not set");

        uint256 globalRate = vm.envOr("GLOBAL_RATE_LIMIT", uint256(100));
        address customRateUser = vm.envOr("CUSTOM_RATE_USER", address(0));
        uint256 customRate = vm.envOr("CUSTOM_RATE_LIMIT", uint256(0));
        address tokenLimitToken = vm.envOr("TOKEN_LIMIT_TOKEN", address(0));
        uint256 tokenLimit = vm.envOr("TOKEN_LIMIT_AMOUNT", uint256(0));

        vm.startBroadcast();

        SecurityManager(securityAddr).setGlobalRateLimit(globalRate);

        if (customRateUser != address(0)) {
            SecurityManager(securityAddr).setCustomRateLimit(customRateUser, customRate);
        }

        if (tokenLimitToken != address(0)) {
            SecurityManager(securityAddr).setAmountLimit(tokenLimitToken, tokenLimit);
        }

        vm.stopBroadcast();

        console.log("Global rate limit:", globalRate);
        if (customRateUser != address(0)) {
            console.log("Custom rate user:", customRateUser);
            console.log("Custom rate limit:", customRate);
        }
        if (tokenLimitToken != address(0)) {
            console.log("Token limit token:", tokenLimitToken);
            console.log("Token limit amount:", tokenLimit);
        }
    }
}

contract ManageAllowBlocklist is Script {
    function run() external {
        address verifierAddr = vm.envAddress("TOKEN_VERIFIER_CONTRACT");
        address token = vm.envAddress("TOKEN_ADDRESS");
        require(verifierAddr != address(0), "TOKEN_VERIFIER_CONTRACT not set");
        require(token != address(0), "TOKEN_ADDRESS not set");

        bool setAllow = vm.envOr("SET_ALLOWLIST", false);
        bool allowValue = vm.envOr("ALLOWLIST_VALUE", true);
        bool setBlock = vm.envOr("SET_BLOCKLIST", false);
        bool clearBlock = vm.envOr("CLEAR_BLOCKLIST", false);
        string memory blockReason = vm.envOr("BLOCK_REASON", string("MANUAL_BLOCK"));
        uint256 maxTransferLimit = vm.envOr("MAX_TRANSFER_LIMIT", uint256(0));

        vm.startBroadcast();

        if (setAllow) {
            TokenVerifier(verifierAddr).addToAllowlist(token, allowValue);
        }

        if (setBlock) {
            TokenVerifier(verifierAddr).addToBlocklist(token, blockReason);
        }

        if (clearBlock) {
            TokenVerifier(verifierAddr).removeFromBlocklist(token);
        }

        if (maxTransferLimit > 0) {
            TokenVerifier(verifierAddr).setMaxTransferLimit(token, maxTransferLimit);
        }

        vm.stopBroadcast();

        console.log("Token policy updated for", token);
    }
}

contract CheckSecurityStatus is Script {
    function run() external view {
        address securityAddr = vm.envAddress("SECURITY_MANAGER_CONTRACT");
        address verifierAddr = vm.envAddress("TOKEN_VERIFIER_CONTRACT");
        address token = vm.envOr("TOKEN_ADDRESS", address(0));
        uint256 amount = vm.envOr("TOKEN_AMOUNT", uint256(0));

        require(securityAddr != address(0), "SECURITY_MANAGER_CONTRACT not set");
        require(verifierAddr != address(0), "TOKEN_VERIFIER_CONTRACT not set");

        (
            bool healthy,
            bool systemPaused,
            SecurityManager.EnforcementMode mode,
            uint256 incidents,
            uint256 globalLimit
        ) = SecurityManager(securityAddr).getSystemHealth();

        console.log("=============================================");
        console.log("Feature 6 Security status on", SupportedNetworks.nameByChainId(block.chainid));
        console.log("=============================================");
        console.log("SecurityManager:", securityAddr);
        console.log("TokenVerifier:  ", verifierAddr);
        console.log("Healthy:        ", healthy);
        console.log("Paused:         ", systemPaused);
        console.log("Mode:           ", mode == SecurityManager.EnforcementMode.MONITOR ? "MONITOR" : "ENFORCE");
        console.log("Incidents:      ", incidents);
        console.log("Global rate:    ", globalLimit);

        if (token != address(0)) {
            TokenVerifier.VerificationStatus status = TokenVerifier(verifierAddr).getStatus(token);
            console.log("Token status:   ", uint256(status));
            if (amount > 0) {
                console.log("Safety check requires authorised caller and is executed by sender contracts.");
                console.log("Token amount:   ", amount);
            }
        }

        console.log("=============================================");
    }
}
