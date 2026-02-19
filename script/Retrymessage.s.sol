// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {MessagingReceiver} from "../src/MessageReceiver.sol";
import {SupportedNetworks} from "./utils/SupportedNetworks.sol";

/// @notice Manually retries processing of a stored CCIP message on any supported destination chain.
///         Emits MessageRetryRequested / MessageRetryCompleted on-chain.
///
/// Required env vars:
///   RECEIVER_CONTRACT — MessagingReceiver address on Amoy
///   MESSAGE_ID        — bytes32 message ID to retry
///
/// Run:
///   RECEIVER_CONTRACT=0x... MESSAGE_ID=0x... forge script script/Retrymessage.s.sol \
///     --rpc-url <target-network> \
///     --account deployer \
///     --broadcast \
///     -vvvv
contract RetryMessage is Script {
    function run() public {
        require(SupportedNetworks.isSupportedChainId(block.chainid), "Unsupported chain");

        address receiverAddr = vm.envAddress("RECEIVER_CONTRACT");
        bytes32 msgId = vm.envBytes32("MESSAGE_ID");

        require(receiverAddr != address(0), "RECEIVER_CONTRACT not set");
        require(msgId != bytes32(0), "MESSAGE_ID not set");

        MessagingReceiver receiver = MessagingReceiver(receiverAddr);
        MessagingReceiver.ReceivedMessage memory beforeMsg = receiver.getMessage(msgId);
        require(beforeMsg.messageId != bytes32(0), "Message not found on receiver");

        vm.startBroadcast();
        receiver.retryMessage(msgId);
        vm.stopBroadcast();

        MessagingReceiver.ReceivedMessage memory afterMsg = receiver.getMessage(msgId);

        console.log("=============================================");
        console.log("Retry executed on receiver on", SupportedNetworks.nameByChainId(block.chainid));
        console.log("Message ID: ", vm.toString(msgId));
        console.log("Status before:", uint8(beforeMsg.status));
        console.log("Status after: ", uint8(afterMsg.status));
        console.log("=============================================");
    }
}
