// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test, console} from "forge-std/Test.sol";

import {CCIPLocalSimulatorFork, Register} from "@chainlink/local/ccip/CCIPLocalSimulatorFork.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {TokenTransferSender} from "../src/TokenTransferSender.sol";
import {TokenTransferReceiver} from "../src/TokenTransferReceiver.sol";

/// @notice Fork integration tests for CCIP token transfer flow (Sepolia -> Amoy).
///
/// Requires .env:
///   ETHEREUM_SEPOLIA_RPC_URL=...
///   POLYGON_AMOY_RPC_URL=...
contract TokenTransferForkTest is Test {
    uint256 public sepoliaFork;
    uint256 public amoyFork;

    CCIPLocalSimulatorFork public ccipSimulator;

    Register.NetworkDetails public sepoliaDetails;
    Register.NetworkDetails public amoyDetails;

    TokenTransferSender public sender;
    TokenTransferReceiver public receiver;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");

    function setUp() public {
        sepoliaFork = vm.createFork(vm.envString("ETHEREUM_SEPOLIA_RPC_URL"));
        amoyFork = vm.createFork(vm.envString("POLYGON_AMOY_RPC_URL"));

        vm.selectFork(amoyFork);
        ccipSimulator = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipSimulator));

        amoyDetails = ccipSimulator.getNetworkDetails(block.chainid);

        vm.prank(owner);
        receiver = new TokenTransferReceiver(amoyDetails.routerAddress);

        vm.selectFork(sepoliaFork);
        sepoliaDetails = ccipSimulator.getNetworkDetails(block.chainid);

        vm.startPrank(owner);
        sender = new TokenTransferSender(sepoliaDetails.routerAddress, sepoliaDetails.linkAddress, true);
        sender.allowlistDestinationChain(amoyDetails.chainSelector, true);
        sender.allowlistToken(sepoliaDetails.ccipBnMAddress, true);

        // Contract receiver flow needs gasLimit > 0.
        sender.updateExtraArgs(
            Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 300_000, allowOutOfOrderExecution: false}))
        );
        vm.stopPrank();

        vm.selectFork(amoyFork);
        vm.startPrank(owner);
        receiver.allowlistSourceChain(sepoliaDetails.chainSelector, true);
        receiver.allowlistSender(sepoliaDetails.chainSelector, address(sender), true);
        vm.stopPrank();

        vm.selectFork(sepoliaFork);
        ccipSimulator.requestLinkFromFaucet(address(sender), 10 ether);

        // Request CCIP-BnM test tokens to Alice on Sepolia.
        vm.prank(alice);
        (bool ok,) = sepoliaDetails.ccipBnMAddress.call(abi.encodeWithSignature("drip(address)", alice));
        require(ok, "drip failed for Sepolia CCIP-BnM");

        vm.label(address(sender), "TokenTransferSender [Sepolia]");
        vm.label(address(receiver), "TokenTransferReceiver [Amoy]");
    }

    function test_Fork_TransferToContract_SepoliaToAmoy() public {
        vm.selectFork(sepoliaFork);

        uint256 amount = IERC20(sepoliaDetails.ccipBnMAddress).balanceOf(alice);
        uint256 linkBefore = IERC20(sepoliaDetails.linkAddress).balanceOf(address(sender));

        vm.startPrank(alice);
        IERC20(sepoliaDetails.ccipBnMAddress).approve(address(sender), amount);
        bytes32 msgId = sender.transferTokensPayLink(
            amoyDetails.chainSelector, address(receiver), sepoliaDetails.ccipBnMAddress, amount
        );
        vm.stopPrank();

        assertNotEq(msgId, bytes32(0), "messageId should be non-zero");

        uint256 linkAfter = IERC20(sepoliaDetails.linkAddress).balanceOf(address(sender));
        assertLt(linkAfter, linkBefore, "LINK fees should be deducted");

        ccipSimulator.switchChainAndRouteMessage(amoyFork);

        vm.selectFork(amoyFork);

        TokenTransferReceiver.ReceivedTransfer memory t = receiver.getTransfer(msgId);
        assertEq(t.messageId, msgId, "messageId mismatch on receiver");
        assertEq(t.sender, address(sender), "sender mismatch");
        assertEq(t.originSender, alice, "origin sender mismatch");
        assertEq(t.amount, amount, "amount mismatch");
        assertGt(receiver.getTokenBalance(t.token), 0, "receiver should hold transferred tokens");

        console.log("Message ID:", vm.toString(msgId));
        console.log("Received token on Amoy:", t.token);
        console.log("Received amount on Amoy:", t.amount);
    }
}
