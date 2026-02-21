// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {MessagingReceiver} from "../src/MessageReceiver.sol";
import {SupportedNetworks} from "./utils/SupportedNetworks.sol";

/// @notice Reads a received message from MessagingReceiver on any supported destination chain.
///         Run AFTER Sendmessage.s.sol and after CCIP Explorer shows SUCCESS.
///
/// Required env vars:
///   RECEIVER_CONTRACT — MessagingReceiver address on Amoy
///   MESSAGE_ID        — bytes32 message ID from SendMessage output
///
/// Run (read-only, no broadcast):
///   RECEIVER_CONTRACT=0x... MESSAGE_ID=0x... forge script script/Verifydelivery.s.sol \
///     --rpc-url <target-network> \
///     -vv
contract VerifyDelivery is Script {
    function run() public view {
        require(SupportedNetworks.isSupportedChainId(block.chainid), "Unsupported chain");

        address receiverAddr = vm.envAddress("RECEIVER_CONTRACT");
        bytes32 msgId = vm.envBytes32("MESSAGE_ID");

        require(receiverAddr != address(0), "RECEIVER_CONTRACT not set");
        require(msgId != bytes32(0), "MESSAGE_ID not set");

        MessagingReceiver receiver = MessagingReceiver(receiverAddr);

        // Read message from receiver state
        MessagingReceiver.ReceivedMessage memory msg_ = receiver.getMessage(msgId);

        console.log("=============================================");
        console.log("Message verification on", SupportedNetworks.nameByChainId(block.chainid));
        console.log("=============================================");

        if (msg_.messageId == bytes32(0)) {
            console.log("STATUS: NOT FOUND -> message has not arrived yet");
            console.log("Wait for SUCCESS on: https://ccip.chain.link");
        } else {
            console.log("STATUS:       FOUND");
            console.log("Message ID:  ", vm.toString(msg_.messageId));
            console.log("Sender:      ", msg_.sender);
            console.log("Text:        ", msg_.text);
            console.log("Chain:       ", msg_.sourceChainSelector);
            console.log("Received at: ", msg_.receivedAt);

            string memory statusLabel;
            if (uint8(msg_.status) == 2) statusLabel = "Processed";
            else if (uint8(msg_.status) == 1) statusLabel = "Received";
            else if (uint8(msg_.status) == 3) statusLabel = "Failed";
            else statusLabel = "Unknown";
            console.log("Processing:  ", statusLabel);

            if (uint8(msg_.status) == 3) {
                console.log("");
                console.log("Retry command:");
                console.log(
                    string.concat(
                        "RECEIVER_CONTRACT=",
                        vm.toString(receiverAddr),
                        " MESSAGE_ID=",
                        vm.toString(msgId),
                        " forge script script/Retrymessage.s.sol --rpc-url <target-network> --account deployer --broadcast -vvvv"
                    )
                );
            }
        }

        console.log("Total messages on receiver:", receiver.getMessageCount());
        console.log("=============================================");
    }
}
