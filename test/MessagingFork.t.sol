// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test, console} from "forge-std/Test.sol";

// Fork simulator — bridges two Foundry forks via CCIP
import {CCIPLocalSimulatorFork, Register} from "@chainlink/local/ccip/CCIPLocalSimulatorFork.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MessagingSender} from "../src/MessageSender.sol";
import {MessagingReceiver} from "../src/MessageReceiver.sol";

/// @notice Fork-based integration test.
///         Tests the full CCIP routing path between Ethereum Sepolia → Polygon Amoy.
///
/// Requires .env:
///   ETHEREUM_SEPOLIA_RPC_URL=...
///   POLYGON_AMOY_RPC_URL=...
///
/// Run:  forge test --match-contract MessagingForkTest -vvv
///
/// Note: CCIPLocalSimulatorFork MUST be made persistent so it survives fork switches.
contract MessagingForkTest is Test {
    // ── Forks ──────────────────────────────────────────────────
    uint256 public sepoliaFork;
    uint256 public amoyFork;

    // ── Simulator (MUST be persistent across forks) ───────────
    CCIPLocalSimulatorFork public ccipSimulator;

    // ── Network details (from simulator registry) ──────────────
    Register.NetworkDetails public sepoliaDetails;
    Register.NetworkDetails public amoyDetails;

    // ── Contracts under test ───────────────────────────────────
    MessagingSender   public sender;   // on Sepolia
    MessagingReceiver public receiver; // on Amoy

    // ── Actors ────────────────────────────────────────────────
    address public owner = makeAddr("owner");

    // ─────────────────────────────────────────────────────────────
    //  setUp
    // ─────────────────────────────────────────────────────────────
    function setUp() public {
        // 1. Create both forks (do NOT select yet)
        sepoliaFork = vm.createFork(vm.envString("ETHEREUM_SEPOLIA_RPC_URL"));
        amoyFork    = vm.createFork(vm.envString("POLYGON_AMOY_RPC_URL"));

        // 2. Select destination (Amoy) first to deploy receiver
        vm.selectFork(amoyFork);

        // 3. Deploy CCIPLocalSimulatorFork — MUST be persistent
        ccipSimulator = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipSimulator)); // survives fork switches

        // 4. Get Amoy network details (router, chain selector, LINK, etc.)
        amoyDetails = ccipSimulator.getNetworkDetails(block.chainid);
        console.log("Amoy chain ID:", block.chainid);
        console.log("Amoy chain selector:", amoyDetails.chainSelector);

        // 5. Deploy receiver on Amoy
        vm.prank(owner);
        receiver = new MessagingReceiver(amoyDetails.routerAddress);
        vm.label(address(receiver), "MessagingReceiver [Amoy]");

        // 6. Switch to source (Sepolia)
        vm.selectFork(sepoliaFork);
        sepoliaDetails = ccipSimulator.getNetworkDetails(block.chainid);
        console.log("Sepolia chain ID:", block.chainid);
        console.log("Sepolia chain selector:", sepoliaDetails.chainSelector);

        // 7. Deploy sender on Sepolia
        vm.startPrank(owner);
        sender = new MessagingSender(
            sepoliaDetails.routerAddress,
            sepoliaDetails.linkAddress,
            true  // pay fees in LINK
        );

        // 8. Configure allowlists on sender (Sepolia side)
        sender.allowlistDestinationChain(amoyDetails.chainSelector, true);
        vm.stopPrank();

        vm.label(address(sender), "MessagingSender [Sepolia]");

        // 9. Configure allowlists on receiver (Amoy side)
        vm.selectFork(amoyFork);
        vm.startPrank(owner);
        receiver.allowlistSourceChain(sepoliaDetails.chainSelector, true);
        receiver.allowlistSender(sepoliaDetails.chainSelector, address(sender), true);
        vm.stopPrank();

        // 10. Fund sender with LINK on Sepolia
        vm.selectFork(sepoliaFork);
        ccipSimulator.requestLinkFromFaucet(address(sender), 10 ether);

        console.log("LINK balance of sender:", IERC20(sepoliaDetails.linkAddress).balanceOf(address(sender)));
    }

    // ─────────────────────────────────────────────────────────────
    //  Full end-to-end: send on Sepolia → receive on Amoy
    // ─────────────────────────────────────────────────────────────

    function test_Fork_SendAndDeliver_SepoliaToAmoy() public {
        // ── Source side (Sepolia) ──────────────────────────────
        vm.selectFork(sepoliaFork);

        string memory text = "Hello from Sepolia to Amoy!";

        vm.prank(owner);
        bytes32 msgId = sender.sendMessagePayLink(
            amoyDetails.chainSelector,
            address(receiver),
            text
        );

        assertNotEq(msgId, bytes32(0), "messageId should be non-zero");
        console.log("Sent messageId:", vm.toString(msgId));

        // ── Relay CCIP message to destination (Amoy) ──────────
        // switchChainAndRouteMessage: switches to dest fork + routes message
        ccipSimulator.switchChainAndRouteMessage(amoyFork);

        // ── Destination side (Amoy) ────────────────────────────
        vm.selectFork(amoyFork);

        MessagingReceiver.ReceivedMessage memory stored = receiver.getMessage(msgId);

        assertEq(stored.messageId,  msgId,          "messageId mismatch on receiver");
        assertEq(stored.sender,     address(sender), "sender address mismatch");
        assertEq(stored.text,       text,            "text mismatch on receiver");
        assertEq(stored.sourceChainSelector, sepoliaDetails.chainSelector, "chain selector mismatch");
        assertEq(
            uint8(stored.status),
            uint8(MessagingReceiver.MessageStatus.Processed),
            "status should be Processed"
        );

        console.log("Message delivered and processed on Amoy!");
        console.log("Received text:", stored.text);
    }

    // ─────────────────────────────────────────────────────────────
    //  Verify LINK fee is deducted on send
    // ─────────────────────────────────────────────────────────────

    function test_Fork_LinkFeeDeducted_OnSend() public {
        vm.selectFork(sepoliaFork);

        IERC20 link = IERC20(sepoliaDetails.linkAddress);
        uint256 balBefore = link.balanceOf(address(sender));

        vm.prank(owner);
        sender.sendMessagePayLink(amoyDetails.chainSelector, address(receiver), "fee test");

        uint256 balAfter = link.balanceOf(address(sender));
        assertLt(balAfter, balBefore, "LINK balance should decrease after send");
        console.log("LINK fee paid:", balBefore - balAfter);
    }

    // ─────────────────────────────────────────────────────────────
    //  Multiple messages delivered in order
    // ─────────────────────────────────────────────────────────────

    function test_Fork_MultipleMessages_DeliveredInOrder() public {
        vm.selectFork(sepoliaFork);

        // Top up LINK for multiple sends
        ccipSimulator.requestLinkFromFaucet(address(sender), 20 ether);

        string[3] memory texts = ["First", "Second", "Third"];
        bytes32[3] memory ids;

        vm.startPrank(owner);
        for (uint256 i = 0; i < 3; i++) {
            ids[i] = sender.sendMessagePayLink(
                amoyDetails.chainSelector,
                address(receiver),
                texts[i]
            );
        }
        vm.stopPrank();

        // Route all three messages
        for (uint256 i = 0; i < 3; i++) {
            ccipSimulator.switchChainAndRouteMessage(amoyFork);
            vm.selectFork(sepoliaFork); // switch back for next send routing
        }

        // Verify on destination
        vm.selectFork(amoyFork);
        assertEq(receiver.getMessageCount(), 3, "should have 3 messages");

        for (uint256 i = 0; i < 3; i++) {
            MessagingReceiver.ReceivedMessage memory msg_ = receiver.getMessage(ids[i]);
            assertEq(msg_.text, texts[i], string.concat("text mismatch at index ", vm.toString(i)));
        }

        console.log("All 3 messages delivered in order on Amoy");
    }
}
