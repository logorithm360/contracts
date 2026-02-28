// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SupportedNetworks} from "./utils/SupportedNetworks.sol";
import {ProgrammableTokenSender} from "../src/ProgrammableTokenSender.sol";
import {ProgrammableTokenReceiver} from "../src/ProgrammableTokenReceiver.sol";

abstract contract ProgrammableEnvHelper is Script {
    function _loadRequiredAddress(string memory key, string memory fallbackKey) internal view returns (address addr) {
        string memory raw = vm.envOr(key, string(""));
        if (bytes(raw).length == 0 && bytes(fallbackKey).length != 0) {
            raw = vm.envOr(fallbackKey, string(""));
        }

        require(bytes(raw).length != 0, string.concat(key, " not set"));
        require(bytes(raw)[0] != 0x24, string.concat(key, " is literal '$...'; set a concrete 0x address"));
        addr = vm.parseAddress(raw);
    }
}

/// @notice Deploys and configures ProgrammableTokenSender on one of the 5 supported testnets.
contract DeployProgrammableSender is ProgrammableEnvHelper {
    function run() public returns (ProgrammableTokenSender senderContract) {
        require(
            SupportedNetworks.isSupportedChainId(block.chainid),
            "Unsupported chain: use Sepolia/Amoy/Arb Sepolia/Base Sepolia/OP Sepolia"
        );

        uint64 localSelector = SupportedNetworks.selectorByChainId(block.chainid);
        string memory networkName = SupportedNetworks.nameByChainId(block.chainid);

        address localRouter = _loadRequiredAddress("LOCAL_CCIP_ROUTER", "");
        address localLink = _loadRequiredAddress("LOCAL_LINK_TOKEN", "");
        bool payInLink = vm.envOr("PAY_FEES_IN_LINK", true);
        uint256 destinationGasLimit = vm.envOr("PROGRAMMABLE_DESTINATION_GAS_LIMIT", uint256(500_000));
        address securityManager = vm.envOr("SECURITY_MANAGER_CONTRACT", address(0));
        address tokenVerifier = vm.envOr("TOKEN_VERIFIER_CONTRACT", address(0));
        address chainRegistry = vm.envOr("CHAIN_REGISTRY_CONTRACT", address(0));
        uint8 resolverMode = _resolverModeFromEnv();

        address localBnm = vm.envOr("LOCAL_CCIP_BNM_TOKEN", address(0));
        address localLnm = vm.envOr("LOCAL_CCIP_LNM_TOKEN", address(0));

        console.log("Deploying ProgrammableTokenSender on", networkName);
        console.log("Chain ID:      ", block.chainid);
        console.log("Chain selector:", localSelector);
        console.log("Pay fees in:   ", payInLink ? "LINK" : "native");

        vm.startBroadcast();

        senderContract = new ProgrammableTokenSender(localRouter, localLink, payInLink);

        uint64[5] memory selectors = SupportedNetworks.allSelectors();
        for (uint256 i = 0; i < selectors.length; i++) {
            if (selectors[i] != localSelector) {
                senderContract.allowlistDestinationChain(selectors[i], true);
            }
        }

        senderContract.allowlistToken(localLink, true);
        if (localBnm != address(0)) senderContract.allowlistToken(localBnm, true);
        if (localLnm != address(0)) senderContract.allowlistToken(localLnm, true);

        bytes memory programmableExtraArgs = Client._argsToBytes(
            Client.GenericExtraArgsV2({gasLimit: destinationGasLimit, allowOutOfOrderExecution: false})
        );
        senderContract.updateExtraArgs(programmableExtraArgs);

        if (securityManager != address(0) || tokenVerifier != address(0)) {
            senderContract.configureSecurity(securityManager, tokenVerifier);
        }

        if (chainRegistry != address(0) || resolverMode != 0) {
            require(chainRegistry != address(0), "CHAIN_REGISTRY_CONTRACT required when resolver mode is enabled");
            senderContract.configureChainRegistry(chainRegistry, resolverMode);
        }

        vm.stopBroadcast();

        require(senderContract.getRouter() == localRouter, "router mismatch");
        require(senderContract.getLinkToken() == localLink, "link token mismatch");

        console.log("=============================================");
        console.log("ProgrammableTokenSender deployed at:", address(senderContract));
        console.log("Router:                            ", localRouter);
        console.log("LINK token:                        ", localLink);
        console.log("Default programmable gasLimit:     ", destinationGasLimit);
        console.log("Security manager:                  ", securityManager);
        console.log("Token verifier:                    ", tokenVerifier);
        console.log("Chain registry:                    ", chainRegistry);
        console.log("Resolver mode:                     ", resolverMode);
        console.log("=============================================");
    }

    function _resolverModeFromEnv() internal view returns (uint8 mode) {
        string memory modeName = vm.envOr("CHAIN_RESOLVER_MODE", string("DISABLED"));
        bytes32 m = keccak256(bytes(modeName));
        if (m == keccak256("DISABLED")) return 0;
        if (m == keccak256("MONITOR")) return 1;
        if (m == keccak256("ENFORCE")) return 2;
        revert("Invalid CHAIN_RESOLVER_MODE");
    }
}

/// @notice Deploys and configures ProgrammableTokenReceiver on one of the 5 supported testnets.
contract DeployProgrammableReceiver is ProgrammableEnvHelper {
    function run() public returns (ProgrammableTokenReceiver receiverContract) {
        require(
            SupportedNetworks.isSupportedChainId(block.chainid),
            "Unsupported chain: use Sepolia/Amoy/Arb Sepolia/Base Sepolia/OP Sepolia"
        );

        uint64 localSelector = SupportedNetworks.selectorByChainId(block.chainid);
        string memory networkName = SupportedNetworks.nameByChainId(block.chainid);

        address localRouter = _loadRequiredAddress("LOCAL_CCIP_ROUTER", "");

        console.log("Deploying ProgrammableTokenReceiver on", networkName);
        console.log("Chain ID:      ", block.chainid);
        console.log("Chain selector:", localSelector);

        vm.startBroadcast();

        receiverContract = new ProgrammableTokenReceiver(localRouter);

        uint64[5] memory selectors = SupportedNetworks.allSelectors();
        for (uint256 i = 0; i < selectors.length; i++) {
            if (selectors[i] != localSelector) {
                receiverContract.allowlistSourceChain(selectors[i], true);

                address senderForSource = _programmableSenderBySelector(selectors[i]);
                if (senderForSource != address(0)) {
                    receiverContract.allowlistSender(selectors[i], senderForSource, true);
                }
            }
        }

        vm.stopBroadcast();

        require(receiverContract.getRouter() == localRouter, "router mismatch");

        console.log("=============================================");
        console.log("ProgrammableTokenReceiver deployed at:", address(receiverContract));
        console.log("Router:                              ", localRouter);
        console.log("=============================================");
    }

    function _programmableSenderBySelector(uint64 selector) internal view returns (address) {
        if (selector == SupportedNetworks.ETHEREUM_SEPOLIA_SELECTOR) {
            return vm.envOr("SEPOLIA_PROGRAMMABLE_SENDER_CONTRACT", address(0));
        }
        if (selector == SupportedNetworks.POLYGON_AMOY_SELECTOR) {
            return vm.envOr("AMOY_PROGRAMMABLE_SENDER_CONTRACT", address(0));
        }
        if (selector == SupportedNetworks.ARBITRUM_SEPOLIA_SELECTOR) {
            return vm.envOr("ARBITRUM_SEPOLIA_PROGRAMMABLE_SENDER_CONTRACT", address(0));
        }
        if (selector == SupportedNetworks.BASE_SEPOLIA_SELECTOR) {
            return vm.envOr("BASE_SEPOLIA_PROGRAMMABLE_SENDER_CONTRACT", address(0));
        }
        if (selector == SupportedNetworks.OP_SEPOLIA_SELECTOR) {
            return vm.envOr("OP_SEPOLIA_PROGRAMMABLE_SENDER_CONTRACT", address(0));
        }
        return address(0);
    }
}

/// @notice Sends a programmable token transfer (tokens + payload) between supported networks.
contract SendProgrammable is ProgrammableEnvHelper {
    struct Params {
        address senderAddr;
        address receiverAddr;
        uint64 destinationSelector;
        address tokenAddr;
        uint256 amount;
        address payloadRecipient;
        string action;
        bool payNative;
        bool updateExtraArgs;
        uint256 deadline;
    }

    function run() public returns (bytes32 messageId) {
        require(SupportedNetworks.isSupportedChainId(block.chainid), "Unsupported source chain");

        Params memory p = _loadParams();
        ProgrammableTokenSender sender = ProgrammableTokenSender(payable(p.senderAddr));

        require(
            sender.allowlistedDestinationChains(p.destinationSelector),
            "Destination chain not allowlisted in programmable sender"
        );
        require(sender.allowlistedTokens(p.tokenAddr), "Token not allowlisted in programmable sender");

        uint256 gasLimit = vm.envOr("PROGRAMMABLE_DESTINATION_GAS_LIMIT", uint256(500_000));
        bytes memory nextExtraArgs =
            Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: gasLimit, allowOutOfOrderExecution: false}));

        ProgrammableTokenSender.TransferPayload memory payload = ProgrammableTokenSender.TransferPayload({
            recipient: p.payloadRecipient, action: p.action, extraData: "", deadline: p.deadline
        });

        uint256 estimatedFee = sender.estimateFee(p.destinationSelector, p.receiverAddr, p.tokenAddr, p.amount, payload);

        console.log("Estimated fee:", estimatedFee);
        console.log("Pay mode:     ", p.payNative ? "native" : "LINK");
        console.log("Gas limit:    ", gasLimit);
        console.log("Token amount: ", p.amount);
        console.log("Action:       ", p.action);

        vm.startBroadcast();

        if (p.updateExtraArgs) {
            sender.updateExtraArgs(nextExtraArgs);
        }

        IERC20(p.tokenAddr).approve(p.senderAddr, p.amount);

        if (p.payNative) {
            uint256 nativeFeeValue = vm.envOr("PROGRAMMABLE_NATIVE_FEE_VALUE", estimatedFee);
            messageId = sender.sendPayNative{value: nativeFeeValue}(
                p.destinationSelector, p.receiverAddr, p.tokenAddr, p.amount, payload
            );
        } else {
            messageId = sender.sendPayLink(p.destinationSelector, p.receiverAddr, p.tokenAddr, p.amount, payload);
        }

        vm.stopBroadcast();

        console.log("=============================================");
        console.log("Programmable token transfer sent successfully");
        console.log("Message ID:     ", vm.toString(messageId));
        console.log("From network:   ", SupportedNetworks.nameByChainId(block.chainid));
        console.log("To selector:    ", p.destinationSelector);
        console.log("Sender contract:", p.senderAddr);
        console.log("Receiver:       ", p.receiverAddr);
        console.log("Token:          ", p.tokenAddr);
        console.log("Amount:         ", p.amount);
        console.log("Action:         ", p.action);
        console.log("=============================================");
    }

    function _loadParams() internal view returns (Params memory p) {
        p.senderAddr = _loadRequiredAddress("PROGRAMMABLE_SENDER_CONTRACT", "");
        p.receiverAddr = _loadRequiredAddress("PROGRAMMABLE_RECEIVER_CONTRACT", "PROGRAMMABLE_RECEIVER_ADDRESS");
        p.destinationSelector = uint64(vm.envUint("PROGRAMMABLE_DESTINATION_CHAIN_SELECTOR"));
        p.tokenAddr = _loadRequiredAddress("PROGRAMMABLE_TOKEN_ADDRESS", "");
        p.amount = vm.envUint("PROGRAMMABLE_TOKEN_AMOUNT");
        p.payloadRecipient = _loadRequiredAddress("PAYLOAD_RECIPIENT", "");
        p.action = vm.envString("PAYLOAD_ACTION");

        p.payNative = vm.envOr("PROGRAMMABLE_PAY_NATIVE", false);
        p.updateExtraArgs = vm.envOr("UPDATE_PROGRAMMABLE_EXTRA_ARGS", true);
        p.deadline = vm.envOr("PAYLOAD_DEADLINE", block.timestamp + 1 days);

        require(p.senderAddr != address(0), "PROGRAMMABLE_SENDER_CONTRACT not set");
        require(p.receiverAddr != address(0), "PROGRAMMABLE_RECEIVER_CONTRACT not set");
        require(p.destinationSelector != 0, "PROGRAMMABLE_DESTINATION_CHAIN_SELECTOR not set");
        require(p.tokenAddr != address(0), "PROGRAMMABLE_TOKEN_ADDRESS not set");
        require(p.amount > 0, "PROGRAMMABLE_TOKEN_AMOUNT must be > 0");
        require(p.payloadRecipient != address(0), "PAYLOAD_RECIPIENT not set");
        require(bytes(p.action).length > 0, "PAYLOAD_ACTION not set");
    }
}

/// @notice Verifies programmable token delivery on destination receiver contract.
contract VerifyProgrammable is ProgrammableEnvHelper {
    function run() public view {
        require(SupportedNetworks.isSupportedChainId(block.chainid), "Unsupported destination chain");

        address receiverAddr = _loadRequiredAddress("PROGRAMMABLE_RECEIVER_CONTRACT", "PROGRAMMABLE_RECEIVER_ADDRESS");
        bytes32 messageId = vm.envBytes32("MESSAGE_ID");

        require(receiverAddr != address(0), "PROGRAMMABLE_RECEIVER_CONTRACT not set");
        require(messageId != bytes32(0), "MESSAGE_ID not set");

        ProgrammableTokenReceiver receiver = ProgrammableTokenReceiver(receiverAddr);
        ProgrammableTokenReceiver.ReceivedTransfer memory t = receiver.getTransfer(messageId);

        console.log("=============================================");
        console.log("Programmable transfer verification on", SupportedNetworks.nameByChainId(block.chainid));
        console.log("=============================================");

        if (t.messageId == bytes32(0)) {
            console.log("STATUS: NOT FOUND -> transfer has not arrived yet");
            console.log("Wait for SUCCESS on: https://ccip.chain.link");
            console.log("Total transfers on receiver:", receiver.getTransferCount());
        } else {
            string memory statusLabel;
            uint8 s = uint8(t.status);
            if (s == 2) statusLabel = "Processed";
            else if (s == 1) statusLabel = "Received (pending)";
            else if (s == 3) statusLabel = "PendingAction (awaiting CRE execution)";
            else if (s == 4) statusLabel = "FAILED (tokens locked)";
            else if (s == 5) statusLabel = "Recovered";
            else statusLabel = "Unknown";

            console.log("STATUS:            ", statusLabel);
            console.log("Message ID:        ", vm.toString(t.messageId));
            console.log("Source selector:   ", t.sourceChainSelector);
            console.log("Sender contract:   ", t.senderContract);
            console.log("Origin sender:     ", t.originSender);
            console.log("Token:             ", t.token);
            console.log("Amount:            ", t.amount);
            console.log("Recipient:         ", t.payload.recipient);
            console.log("Action:            ", t.payload.action);
            console.log("Deadline:          ", t.payload.deadline);
            console.log("Received at:       ", t.receivedAt);
            console.log("Contract balance:  ", receiver.getTokenBalance(t.token));
            console.log("Total received:    ", receiver.totalReceived(t.token));
            console.log("Total processed:   ", receiver.totalProcessed(t.token));
            console.log("Total transfers:   ", receiver.getTransferCount());
        }

        console.log("=============================================");
    }
}
