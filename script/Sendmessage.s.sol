// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {MessagingSender} from "../src/MessageSender.sol";
import {SupportedNetworks} from "./utils/SupportedNetworks.sol";

/// @notice Sends a cross-chain message between any of the 5 supported networks.
///
/// Required env vars:
///   SENDER_CONTRACT              — MessagingSender address on source chain
///   RECEIVER_CONTRACT            — MessagingReceiver address on destination chain
///   DESTINATION_CHAIN_SELECTOR   — destination CCIP chain selector
///   MESSAGE_TEXT                 — optional message text
///   PAY_NATIVE                   — optional bool (default false)
///   NATIVE_FEE_VALUE             — optional value for native fee path
///
/// Run:
///   SENDER_CONTRACT=0x... RECEIVER_CONTRACT=0x... DESTINATION_CHAIN_SELECTOR=<selector> \
///   forge script script/Sendmessage.s.sol --rpc-url sepolia --account deployer --broadcast -vvvv
contract SendMessage is Script {
    function run() public returns (bytes32 messageId) {
        require(
            SupportedNetworks.isSupportedChainId(block.chainid),
            "Unsupported source chain"
        );

        address senderAddr = vm.envAddress("SENDER_CONTRACT");
        address receiverAddr = vm.envAddress("RECEIVER_CONTRACT");
        uint64 destinationSelector = uint64(vm.envUint("DESTINATION_CHAIN_SELECTOR"));
        string memory text = vm.envOr("MESSAGE_TEXT", string("Hello cross-chain!"));
        bool payNative = vm.envOr("PAY_NATIVE", false);

        require(senderAddr != address(0), "SENDER_CONTRACT not set");
        require(receiverAddr != address(0), "RECEIVER_CONTRACT not set");
        require(destinationSelector != 0, "DESTINATION_CHAIN_SELECTOR not set");

        MessagingSender sender = MessagingSender(payable(senderAddr));

        require(
            sender.allowlistedDestinationChains(destinationSelector),
            "Destination chain not allowlisted in sender"
        );

        uint256 estimatedFee = sender.estimateFee(destinationSelector, receiverAddr, text);
        console.log("Estimated fee:", estimatedFee);

        vm.startBroadcast();

        if (payNative) {
            uint256 nativeFeeValue = vm.envOr("NATIVE_FEE_VALUE", estimatedFee);
            messageId = sender.sendMessagePayNative{value: nativeFeeValue}(destinationSelector, receiverAddr, text);
        } else {
            messageId = sender.sendMessagePayLink(destinationSelector, receiverAddr, text);
        }

        vm.stopBroadcast();

        console.log("=============================================");
        console.log("Message sent successfully");
        console.log("Message ID:     ", vm.toString(messageId));
        console.log("From network:   ", SupportedNetworks.nameByChainId(block.chainid));
        console.log("To selector:    ", destinationSelector);
        console.log("Sender contract:", senderAddr);
        console.log("Receiver:       ", receiverAddr);
        console.log("CRE trigger event emitted: MessageSent");
        console.log("=============================================");
    }
}
