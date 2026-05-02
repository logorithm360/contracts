// SPDX-License-Identifier: MIT
pragma solidity =0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {SwapAdapter} from "../src/SwapAdapter.sol";
import {ChainShieldGateway} from "../src/ChainShieldGateway.sol";

interface ITokenVerifierAdmin {
    function setAuthorisedCaller(address caller, bool allowed) external;
}

// ─────────────────────────────────────────────────────────────────────────────
//  DeployChainShield
//
//  Deploys SwapAdapter + ChainShieldGateway and wires them to your existing
//  SecurityManager and TokenVerifier on Ethereum Sepolia.
//
//  Run:
//    forge script script/DeployChainShield.s.sol:DeployChainShield \
//      --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
//      --private-key $PRIVATE_KEY \
//      --broadcast \
//      --verify
//
//  Environment variables required:
//    ETHEREUM_SEPOLIA_RPC_URL
//    PRIVATE_KEY
//    ETHERSCAN_API_KEY   (needed when using --verify)
// ─────────────────────────────────────────────────────────────────────────────

contract DeployChainShield is Script {
    error MissingEnvAddress(string key);

    // ── Existing deployed addresses (Sepolia) ─────────────────────────────────

    address constant SECURITY_MANAGER = 0xca76e3D39DA50Bf6A6d1DE9e89aD2F82C06787Fd;

    address constant TOKEN_VERIFIER = 0x7F2C17f2C421C10e90783f9C2823c6Dd592b9EB4;

    // ── Sepolia infrastructure ────────────────────────────────────────────────

    /// @dev Chainlink CCIP Router on Ethereum Sepolia
    address constant CCIP_ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;

    /// @dev LINK token on Ethereum Sepolia
    address constant LINK_TOKEN = 0x779877A7B0D9E8603169DdbD7836e478b4624789;

    // ─────────────────────────────────────────────────────────────────────────

    function run() external {
        address swapRouter = _loadRequiredAddress("UNISWAP_V3_ROUTER");

        vm.startBroadcast();

        // 1. Deploy SwapAdapter
        SwapAdapter swapAdapter = new SwapAdapter(
            swapRouter,
            msg.sender // owner = deployer
        );
        console.log("SwapAdapter deployed at:", address(swapAdapter));

        // 2. Deploy ChainShieldGateway
        ChainShieldGateway gateway = new ChainShieldGateway(
            CCIP_ROUTER,
            LINK_TOKEN,
            msg.sender // owner = deployer
        );
        console.log("ChainShieldGateway deployed at:", address(gateway));

        // 3. Wire gateway to existing security contracts + new SwapAdapter
        gateway.configureContracts(SECURITY_MANAGER, TOKEN_VERIFIER, address(swapAdapter));
        console.log("Gateway configured with SecurityManager, TokenVerifier, SwapAdapter");

        // 4. Authorise gateway to call SwapAdapter
        swapAdapter.authoriseCaller(address(gateway), true);
        console.log("Gateway authorised as SwapAdapter caller");

        // 5. Authorise gateway in TokenVerifier for transfer-safe checks
        ITokenVerifierAdmin(TOKEN_VERIFIER).setAuthorisedCaller(address(gateway), true);
        console.log("Gateway authorised in TokenVerifier");

        // 6. Authorise gateway in SecurityManager
        //    (owner must call SecurityManager.authoriseCaller(gateway, true) separately
        //     if SecurityManager uses the same owner — shown here for completeness)
        // ISecurityManager(SECURITY_MANAGER).authoriseCaller(address(gateway), true);

        vm.stopBroadcast();

        // ── Summary ───────────────────────────────────────────────────────────
        console.log("\n=== ChainShield Deployment Summary ===");
        console.log("SwapAdapter:        ", address(swapAdapter));
        console.log("ChainShieldGateway: ", address(gateway));
        console.log("SecurityManager:    ", SECURITY_MANAGER, "(existing)");
        console.log("TokenVerifier:      ", TOKEN_VERIFIER, "(existing)");
        console.log("CCIP Router:        ", CCIP_ROUTER);
        console.log("LINK Token:         ", LINK_TOKEN);
        console.log("Uniswap V3 Router:  ", swapRouter);
        console.log("\nNext steps:");
        console.log("1. Fund ChainShieldGateway with LINK:");
        console.log(
            "   cast send <LINK_TOKEN> \"approve(address,uint256)\" <GATEWAY_ADDRESS> <amount> --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY"
        );
        console.log(
            "   cast send <GATEWAY_ADDRESS> \"depositLink(uint256)\" <amount> --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY"
        );
        console.log("2. Authorise gateway in SecurityManager:");
        console.log(
            "   cast send <SECURITY_MANAGER> \"authoriseCaller(address,bool)\" <GATEWAY_ADDRESS> true --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY"
        );
        console.log("3. Add tokenIn/tokenOut to TokenVerifier allowlist if needed");
        console.log("4. Update DEPLOYED_ADDRESSES.md");
    }

    function _loadRequiredAddress(string memory key) internal view returns (address value) {
        value = vm.envOr(key, address(0));
        if (value == address(0)) revert MissingEnvAddress(key);
    }
}
