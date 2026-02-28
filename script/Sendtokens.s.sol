// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {SupportedNetworks} from "./utils/SupportedNetworks.sol";
import {TokenTransferSender} from "../src/TokenTransferSender.sol";
import {TokenTransferReceiver} from "../src/TokenTransferReceiver.sol";

abstract contract TokenScriptEnvHelper is Script {
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

/// @notice Sends cross-chain token transfers between the 5 supported networks.
///
/// Required env vars:
///   TOKEN_SENDER_CONTRACT
///   TOKEN_RECEIVER_ADDRESS
///   TOKEN_DESTINATION_CHAIN_SELECTOR
///   TOKEN_ADDRESS
///   TOKEN_AMOUNT
///
/// Optional env vars:
///   TOKEN_PAY_NATIVE=false
///   TOKEN_NATIVE_FEE_VALUE=<value>
///   IS_CONTRACT_RECEIVER=false
///   UPDATE_TOKEN_EXTRA_ARGS=true
///   TOKEN_TRANSFER_DESTINATION_GAS_LIMIT=300000 (contract) or 0 (EOA)
///
/// Example:
///   TOKEN_SENDER_CONTRACT=0x... TOKEN_RECEIVER_ADDRESS=0x... TOKEN_DESTINATION_CHAIN_SELECTOR=16281711391670634445 \
///   TOKEN_ADDRESS=0x... TOKEN_AMOUNT=1000000000000000000 \
///   forge script script/Sendtokens.s.sol:SendTokens --rpc-url sepolia --account deployer --broadcast -vvvv
contract SendTokens is TokenScriptEnvHelper {
    struct Params {
        address senderAddr;
        address receiverAddr;
        uint64 destinationSelector;
        address tokenAddr;
        uint256 amount;
        bool payNative;
        bool isContractReceiver;
        bool updateExtraArgs;
    }

    function run() public returns (bytes32 messageId) {
        require(SupportedNetworks.isSupportedChainId(block.chainid), "Unsupported source chain");

        Params memory p = _loadParams();
        TokenTransferSender sender = TokenTransferSender(payable(p.senderAddr));

        require(
            sender.allowlistedDestinationChains(p.destinationSelector),
            "Destination chain not allowlisted in token sender"
        );
        require(sender.allowlistedTokens(p.tokenAddr), "Token not allowlisted in token sender");

        uint256 gasLimit = vm.envOr("TOKEN_TRANSFER_DESTINATION_GAS_LIMIT", uint256(p.isContractReceiver ? 300_000 : 0));
        bytes memory nextExtraArgs =
            Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: gasLimit, allowOutOfOrderExecution: false}));

        uint256 estimatedFee = sender.estimateFee(p.destinationSelector, p.receiverAddr, p.tokenAddr, p.amount);
        console.log("Estimated fee:", estimatedFee);
        console.log("Pay mode:     ", p.payNative ? "native" : "LINK");
        console.log("Gas limit:    ", gasLimit);
        console.log("Token amount: ", p.amount);

        vm.startBroadcast();

        if (p.updateExtraArgs) {
            sender.updateExtraArgs(nextExtraArgs);
        }

        IERC20(p.tokenAddr).approve(p.senderAddr, p.amount);

        if (p.payNative) {
            uint256 nativeFeeValue = vm.envOr("TOKEN_NATIVE_FEE_VALUE", estimatedFee);
            messageId = sender.transferTokensPayNative{value: nativeFeeValue}(
                p.destinationSelector, p.receiverAddr, p.tokenAddr, p.amount
            );
        } else {
            messageId = sender.transferTokensPayLink(p.destinationSelector, p.receiverAddr, p.tokenAddr, p.amount);
        }

        vm.stopBroadcast();

        console.log("=============================================");
        console.log("Token transfer sent successfully");
        console.log("Message ID:     ", vm.toString(messageId));
        console.log("From network:   ", SupportedNetworks.nameByChainId(block.chainid));
        console.log("To selector:    ", p.destinationSelector);
        console.log("Sender contract:", p.senderAddr);
        console.log("Receiver:       ", p.receiverAddr);
        console.log("Token:          ", p.tokenAddr);
        console.log("Amount:         ", p.amount);
        console.log("CRE trigger event emitted: TokensTransferred");
        console.log("=============================================");
    }

    function _loadParams() internal view returns (Params memory p) {
        p.senderAddr = _loadRequiredAddress("TOKEN_SENDER_CONTRACT", "");
        p.receiverAddr = _loadRequiredAddress("TOKEN_RECEIVER_ADDRESS", "TOKEN_RECEIVER_CONTRACT");
        p.destinationSelector = uint64(vm.envUint("TOKEN_DESTINATION_CHAIN_SELECTOR"));
        p.tokenAddr = _loadRequiredAddress("TOKEN_ADDRESS", "");
        p.amount = vm.envUint("TOKEN_AMOUNT");

        p.payNative = vm.envOr("TOKEN_PAY_NATIVE", false);
        p.isContractReceiver = vm.envOr("IS_CONTRACT_RECEIVER", false);
        p.updateExtraArgs = vm.envOr("UPDATE_TOKEN_EXTRA_ARGS", true);

        require(p.senderAddr != address(0), "TOKEN_SENDER_CONTRACT not set");
        require(p.receiverAddr != address(0), "TOKEN_RECEIVER_ADDRESS not set");
        require(p.destinationSelector != 0, "TOKEN_DESTINATION_CHAIN_SELECTOR not set");
        require(p.tokenAddr != address(0), "TOKEN_ADDRESS not set");
        require(p.amount > 0, "TOKEN_AMOUNT must be > 0");
    }
}

/// @notice Verifies whether a token transfer was received and indexed on destination receiver contract.
///
/// Required env vars:
///   TOKEN_RECEIVER_CONTRACT
///   MESSAGE_ID
///
/// Example:
///   TOKEN_RECEIVER_CONTRACT=0x... MESSAGE_ID=0x... \
///   forge script script/Sendtokens.s.sol:VerifyTokenDelivery --rpc-url amoy -vv
contract VerifyTokenDelivery is TokenScriptEnvHelper {
    function run() public view {
        require(SupportedNetworks.isSupportedChainId(block.chainid), "Unsupported destination chain");

        address receiverAddr = _loadRequiredAddress("TOKEN_RECEIVER_CONTRACT", "TOKEN_RECEIVER_ADDRESS");
        bytes32 messageId = vm.envBytes32("MESSAGE_ID");

        require(receiverAddr != address(0), "TOKEN_RECEIVER_CONTRACT not set");
        require(messageId != bytes32(0), "MESSAGE_ID not set");

        TokenTransferReceiver receiver = TokenTransferReceiver(receiverAddr);
        TokenTransferReceiver.ReceivedTransfer memory transfer_ = receiver.getTransfer(messageId);

        console.log("=============================================");
        console.log("Token transfer verification on", SupportedNetworks.nameByChainId(block.chainid));
        console.log("=============================================");

        if (transfer_.messageId == bytes32(0)) {
            console.log("STATUS: NOT FOUND -> transfer has not arrived yet");
            console.log("Wait for SUCCESS on: https://ccip.chain.link");
            console.log("Total transfers on receiver:", receiver.getTransferCount());
        } else {
            console.log("STATUS: DELIVERED");
            console.log("Message ID:       ", vm.toString(transfer_.messageId));
            console.log("Source selector:  ", transfer_.sourceChainSelector);
            console.log("Source sender:    ", transfer_.sender);
            console.log("Origin sender:    ", transfer_.originSender);
            console.log("Token:            ", transfer_.token);
            console.log("Amount:           ", transfer_.amount);
            console.log("Received At:      ", transfer_.receivedAt);
            console.log("Receiver balance: ", receiver.getTokenBalance(transfer_.token));
            console.log("Total received:   ", receiver.totalReceived(transfer_.token));
            console.log("Total transfers:  ", receiver.getTransferCount());
        }

        console.log("=============================================");
    }
}
