// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test, console} from "forge-std/Test.sol";

// Chainlink Local Simulator — runs CCIP entirely in Anvil, no fork needed
import {CCIPLocalSimulator, IRouterClient, LinkToken} from "@chainlink/local/ccip/CCIPLocalSimulator.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {MessagingSender} from "../src/MessageSender.sol";
import {MessagingReceiver} from "../src/MessageReceiver.sol";

interface IFeeConfigurableRouter {
    function setFee(uint256 feeAmount) external;
}

/// @notice Unit test suite for cross-chain messaging.
///         Uses CCIPLocalSimulator — no RPC keys required, runs fully offline.
///
/// Run:  forge test --match-contract MessagingTest -vvv
contract MessagingTest is Test {
    // ── CCIP local infrastructure ──────────────────────────────
    CCIPLocalSimulator public simulator;
    IRouterClient public sourceRouter;
    IRouterClient public destRouter;
    LinkToken public linkToken;
    uint64 public chainSelector; // simulator uses one shared selector

    // ── Contracts under test ───────────────────────────────────
    MessagingSender public sender;
    MessagingReceiver public receiver;

    // ── Actors ────────────────────────────────────────────────
    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public attacker = makeAddr("attacker");

    // ── Test constants ─────────────────────────────────────────
    string constant HELLO_MSG = "Hello from Chain A!";
    uint256 constant LINK_FUND = 10 ether; // LINK funded to sender contract
    uint256 constant NATIVE_FUND = 5 ether; // native funded to sender contract
    uint256 constant MOCK_FEE = 0.01 ether; // mock fee for testing

    // ─────────────────────────────────────────────────────────────
    //  setUp — runs before every test
    // ─────────────────────────────────────────────────────────────
    function setUp() public {
        // 1. Deploy CCIP local simulator (provides routers, LINK, chain selector)
        simulator = new CCIPLocalSimulator();
        (
            uint64 _chainSelector,
            IRouterClient _sourceRouter,
            IRouterClient _destRouter,, // WETH9 wrappedNative (unused here)
            LinkToken _linkToken,, // ccipBnM test token (unused here)
            // ccipLnM test token (unused here)
        ) = simulator.configuration();

        chainSelector = _chainSelector;
        sourceRouter = _sourceRouter;
        destRouter = _destRouter;
        linkToken = _linkToken;

        // 2. Deploy contracts as owner
        vm.startPrank(owner);

        sender = new MessagingSender(address(sourceRouter), address(linkToken), true);
        receiver = new MessagingReceiver(address(destRouter));

        // 3. Configure allowlists (MANDATORY — contracts silently drop without these)
        sender.allowlistDestinationChain(chainSelector, true);
        receiver.allowlistSourceChain(chainSelector, true);
        receiver.allowlistSender(chainSelector, address(sender), true);

        vm.stopPrank();

        // 4. Fund sender contract with LINK (for fee payment)
        simulator.requestLinkFromFaucet(address(sender), LINK_FUND);

        // 5. Fund sender with native for native-fee tests
        vm.deal(address(sender), NATIVE_FUND);
        vm.deal(owner, NATIVE_FUND);

        // 6. Configure simulator router fee to non-zero for fee-related assertions.
        // sourceRouter and destRouter point to the same mock router in CCIPLocalSimulator.
        IFeeConfigurableRouter(address(sourceRouter)).setFee(MOCK_FEE);

        // Labels appear in forge traces
        vm.label(address(simulator), "CCIPLocalSimulator");
        vm.label(address(sourceRouter), "SourceRouter");
        vm.label(address(destRouter), "DestRouter");
        vm.label(address(linkToken), "LinkToken");
        vm.label(address(sender), "MessagingSender");
        vm.label(address(receiver), "MessagingReceiver");
        vm.label(owner, "Owner");
        vm.label(alice, "Alice");
        vm.label(attacker, "Attacker");
    }

    // ─────────────────────────────────────────────────────────────
    //  Happy-path: send via LINK fees
    // ─────────────────────────────────────────────────────────────

    function test_SendMessagePayLINK_Succeeds() public {
        uint256 linkBefore = linkToken.balanceOf(address(sender));

        vm.prank(owner);
        bytes32 msgId = sender.sendMessagePayLink(chainSelector, address(receiver), HELLO_MSG);

        // messageId must be non-zero
        assertNotEq(msgId, bytes32(0), "messageId should be non-zero");

        // LINK balance of sender should decrease (fees paid)
        uint256 linkAfter = linkToken.balanceOf(address(sender));
        assertLt(linkAfter, linkBefore, "LINK balance should decrease after send");

        console.log("LINK fees paid:", linkBefore - linkAfter);
        console.log("messageId:", vm.toString(msgId));
    }

    // ─────────────────────────────────────────────────────────────
    //  Happy-path: message arrives and is stored on receiver
    // ─────────────────────────────────────────────────────────────

    function test_MessageDelivered_ToReceiver() public {
        vm.prank(owner);
        bytes32 msgId = sender.sendMessagePayLink(chainSelector, address(receiver), HELLO_MSG);

        // In current chainlink-local, MockCCIPRouter delivers during ccipSend.

        // Verify message stored in receiver
        MessagingReceiver.ReceivedMessage memory stored = receiver.getMessage(msgId);

        assertEq(stored.messageId, msgId, "messageId mismatch");
        assertEq(stored.sender, address(sender), "sender mismatch");
        assertEq(stored.text, HELLO_MSG, "text mismatch");
        assertEq(stored.sourceChainSelector, chainSelector, "chain selector mismatch");
        assertEq(uint8(stored.status), uint8(MessagingReceiver.MessageStatus.Processed), "status should be Processed");
    }

    // ─────────────────────────────────────────────────────────────
    //  Happy-path: send via native gas fees
    // ─────────────────────────────────────────────────────────────

    function test_SendMessagePayNative_Succeeds() public {
        // Switch sender to native fee mode
        vm.prank(owner);
        sender.setPayFeesInLink(false);

        uint256 nativeBefore = address(sender).balance;

        vm.prank(owner);
        bytes32 msgId = sender.sendMessagePayNative{value: 1 ether}(chainSelector, address(receiver), HELLO_MSG);

        assertNotEq(msgId, bytes32(0), "messageId should be non-zero");

        // Some native should have been spent on fees
        // (excess is refunded, so balance reduction == fees paid)
        uint256 nativeAfter = address(sender).balance;
        assertLt(nativeAfter, nativeBefore + 1 ether, "native should have decreased by fees");
    }

    // ─────────────────────────────────────────────────────────────
    //  Happy-path: getLastReceivedMessage returns most recent
    // ─────────────────────────────────────────────────────────────

    function test_GetLastReceivedMessage_ReturnsLatest() public {
        vm.startPrank(owner);
        sender.sendMessagePayLink(chainSelector, address(receiver), "First");
        sender.sendMessagePayLink(chainSelector, address(receiver), "Second");
        vm.stopPrank();

        MessagingReceiver.ReceivedMessage memory last = receiver.getLastReceivedMessage();
        assertEq(last.text, "Second", "getLastReceivedMessage should return latest");
        assertEq(receiver.getMessageCount(), 2, "should have 2 messages");
    }

    // ─────────────────────────────────────────────────────────────
    //  Revert: destination chain not allowlisted
    // ─────────────────────────────────────────────────────────────

    function test_RevertWhen_DestChainNotAllowlisted() public {
        uint64 unknownChain = 9999;

        vm.expectRevert(abi.encodeWithSelector(MessagingSender.DestinationChainNotAllowlisted.selector, unknownChain));
        vm.prank(owner);
        sender.sendMessagePayLink(unknownChain, address(receiver), HELLO_MSG);
    }

    // ─────────────────────────────────────────────────────────────
    //  Revert: empty message text
    // ─────────────────────────────────────────────────────────────

    function test_RevertWhen_EmptyText() public {
        vm.expectRevert(MessagingSender.EmptyData.selector);
        vm.prank(owner);
        sender.sendMessagePayLink(chainSelector, address(receiver), "");
    }

    // ─────────────────────────────────────────────────────────────
    //  Revert: zero address receiver
    // ─────────────────────────────────────────────────────────────

    function test_RevertWhen_ZeroReceiver() public {
        vm.expectRevert(MessagingSender.ZeroAddress.selector);
        vm.prank(owner);
        sender.sendMessagePayLink(chainSelector, address(0), HELLO_MSG);
    }

    // ─────────────────────────────────────────────────────────────
    //  Revert: insufficient LINK balance
    // ─────────────────────────────────────────────────────────────

    function test_RevertWhen_InsufficientLink() public {
        // Drain the sender's LINK
        vm.prank(owner);
        sender.withdrawLink(owner);
        assertEq(linkToken.balanceOf(address(sender)), 0, "LINK should be drained");

        uint256 fee = sender.estimateFee(chainSelector, address(receiver), HELLO_MSG);
        vm.expectRevert(abi.encodeWithSelector(MessagingSender.InsufficientLinkBalance.selector, 0, fee));
        vm.prank(owner);
        sender.sendMessagePayLink(chainSelector, address(receiver), HELLO_MSG);
    }

    // ─────────────────────────────────────────────────────────────
    //  Revert: insufficient native balance
    // ─────────────────────────────────────────────────────────────

    function test_RevertWhen_InsufficientNative() public {
        vm.prank(owner);
        sender.setPayFeesInLink(false);

        vm.expectRevert(abi.encodeWithSelector(MessagingSender.InsufficientNativeBalance.selector, 0, MOCK_FEE));
        vm.prank(owner);
        sender.sendMessagePayNative{value: 0}(chainSelector, address(receiver), HELLO_MSG); // no ETH
    }

    // ─────────────────────────────────────────────────────────────
    //  Security: source chain not allowlisted on receiver
    // ─────────────────────────────────────────────────────────────

    function test_RevertWhen_SourceChainNotAllowlisted() public {
        // Remove allowlist for the source chain
        vm.prank(owner);
        receiver.allowlistSourceChain(chainSelector, false);

        // Delivery happens inside send; it should revert because receiver rejects the source chain.
        vm.expectRevert();
        vm.prank(owner);
        sender.sendMessagePayLink(chainSelector, address(receiver), HELLO_MSG);
    }

    // ─────────────────────────────────────────────────────────────
    //  Security: sender not allowlisted on receiver
    // ─────────────────────────────────────────────────────────────

    function test_RevertWhen_SenderNotAllowlisted() public {
        // Remove sender from allowlist
        vm.prank(owner);
        receiver.allowlistSender(chainSelector, address(sender), false);

        vm.expectRevert();
        vm.prank(owner);
        sender.sendMessagePayLink(chainSelector, address(receiver), HELLO_MSG);
    }

    function test_RevertWhen_SenderAllowlistedOnDifferentChainOnly() public {
        uint64 otherChain = 3478487238524512106; // Arbitrum Sepolia

        vm.startPrank(owner);
        receiver.allowlistSender(chainSelector, address(sender), false);
        receiver.allowlistSender(otherChain, address(sender), true);
        vm.stopPrank();

        // The mock router wraps receiver errors as ReceiverError(...), so expect generic revert.
        vm.expectRevert();
        vm.prank(owner);
        sender.sendMessagePayLink(chainSelector, address(receiver), HELLO_MSG);
    }

    // ─────────────────────────────────────────────────────────────
    //  Security: unauthorized access to admin functions
    // ─────────────────────────────────────────────────────────────

    function test_RevertWhen_AttackerCallsAllowlist() public {
        vm.expectRevert();
        vm.prank(attacker);
        sender.allowlistDestinationChain(chainSelector, false);
    }

    function test_RevertWhen_AttackerCallsWithdrawLink() public {
        vm.expectRevert();
        vm.prank(attacker);
        sender.withdrawLink(attacker);
    }

    function test_RevertWhen_AttackerCallsProcessMessage() public {
        // First deliver a real message
        vm.prank(owner);
        bytes32 msgId = sender.sendMessagePayLink(chainSelector, address(receiver), HELLO_MSG);

        // Attacker tries to call processMessage directly
        vm.expectRevert(abi.encodeWithSelector(MessagingReceiver.UnauthorizedCaller.selector, attacker));
        vm.prank(attacker);
        receiver.processMessage(msgId);
    }

    function test_RetryMessage_EmitsWorkflowEvents() public {
        vm.prank(owner);
        bytes32 msgId = sender.sendMessagePayLink(chainSelector, address(receiver), HELLO_MSG);

        vm.expectEmit(true, true, false, false);
        emit MessagingReceiver.MessageRetryRequested(msgId, owner);

        vm.expectEmit(true, false, false, true);
        emit MessagingReceiver.MessageProcessed(msgId);

        vm.expectEmit(true, false, false, true);
        emit MessagingReceiver.MessageRetryCompleted(msgId, true, "");

        vm.prank(owner);
        receiver.retryMessage(msgId);
    }

    // ─────────────────────────────────────────────────────────────
    //  Admin: allowlist management
    // ─────────────────────────────────────────────────────────────

    function test_AllowlistDestinationChain_EmitsEvent() public {
        uint64 newChain = 42161; // Arbitrum chain selector (example)

        vm.expectEmit(true, false, false, true);
        emit MessagingSender.DestinationChainAllowlisted(newChain, true);

        vm.prank(owner);
        sender.allowlistDestinationChain(newChain, true);
        assertTrue(sender.allowlistedDestinationChains(newChain));
    }

    function test_AllowlistSourceChain_EmitsEvent() public {
        uint64 newChain = 42161;

        vm.expectEmit(true, false, false, true);
        emit MessagingReceiver.SourceChainAllowlisted(newChain, true);

        vm.prank(owner);
        receiver.allowlistSourceChain(newChain, true);
        assertTrue(receiver.allowlistedSourceChains(newChain));
    }

    function test_AllowlistSender_EmitsEvent() public {
        uint64 newChain = 42161;
        address newSender = makeAddr("newSender");

        vm.expectEmit(true, true, false, true);
        emit MessagingReceiver.SenderAllowlisted(newChain, newSender, true);

        vm.prank(owner);
        receiver.allowlistSender(newChain, newSender, true);
        assertTrue(receiver.allowlistedSendersByChain(newChain, newSender));
    }

    // ─────────────────────────────────────────────────────────────
    //  Admin: extraArgs update
    // ─────────────────────────────────────────────────────────────

    function test_UpdateExtraArgs_Succeeds() public {
        bytes memory newArgs =
            Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 500_000, allowOutOfOrderExecution: true}));

        vm.expectEmit(false, false, false, true);
        emit MessagingSender.ExtraArgsUpdated(newArgs);

        vm.prank(owner);
        sender.updateExtraArgs(newArgs);
        assertEq(sender.extraArgs(), newArgs);
    }

    // ─────────────────────────────────────────────────────────────
    //  Admin: withdrawals
    // ─────────────────────────────────────────────────────────────

    function test_WithdrawLink_Succeeds() public {
        uint256 bal = linkToken.balanceOf(address(sender));
        assertGt(bal, 0, "sender should have LINK");

        vm.expectEmit(true, false, false, true);
        emit MessagingSender.LinkWithdrawn(owner, bal);

        vm.prank(owner);
        sender.withdrawLink(owner);

        assertEq(linkToken.balanceOf(address(sender)), 0, "sender LINK should be zero");
        assertEq(linkToken.balanceOf(owner), bal, "owner should receive LINK");
    }

    function test_WithdrawNative_Succeeds() public {
        uint256 bal = address(sender).balance;
        assertGt(bal, 0, "sender should have native");

        uint256 ownerBefore = owner.balance;

        vm.expectEmit(true, false, false, true);
        emit MessagingSender.NativeWithdrawn(owner, bal);

        vm.prank(owner);
        sender.withdrawNative(payable(owner));

        assertEq(address(sender).balance, 0, "sender native should be zero");
        assertEq(owner.balance, ownerBefore + bal, "owner should receive native");
    }

    function test_RevertWhen_WithdrawLinkNothingToWithdraw() public {
        vm.prank(owner);
        sender.withdrawLink(owner); // drain it

        vm.expectRevert(MessagingSender.NothingToWithdraw.selector);
        vm.prank(owner);
        sender.withdrawLink(owner); // try again
    }

    function test_RescueToken_EmitsEvent() public {
        uint256 rescueAmount = 1 ether;
        simulator.requestLinkFromFaucet(address(receiver), rescueAmount);

        uint256 ownerBefore = linkToken.balanceOf(owner);

        vm.expectEmit(true, true, false, true);
        emit MessagingReceiver.TokenRescued(address(linkToken), owner, rescueAmount);

        vm.prank(owner);
        receiver.rescueToken(address(linkToken), owner, rescueAmount);

        assertEq(linkToken.balanceOf(owner), ownerBefore + rescueAmount, "owner should receive rescued LINK");
        assertEq(linkToken.balanceOf(address(receiver)), 0, "receiver should have no LINK after rescue");
    }

    // ─────────────────────────────────────────────────────────────
    //  estimateFee view
    // ─────────────────────────────────────────────────────────────

    function test_EstimateFee_ReturnsNonZero() public view {
        uint256 fee = sender.estimateFee(chainSelector, address(receiver), HELLO_MSG);
        assertGt(fee, 0, "fee should be non-zero");
        console.log("Estimated LINK fee:", fee);
    }

    // ─────────────────────────────────────────────────────────────
    //  Fuzz: any non-empty message is sent and delivered
    // ─────────────────────────────────────────────────────────────

    function testFuzz_SendAndDeliver_AnyText(string calldata text) public {
        vm.assume(bytes(text).length > 0 && bytes(text).length <= 1000);

        simulator.requestLinkFromFaucet(address(sender), 5 ether); // top up

        vm.prank(owner);
        bytes32 msgId = sender.sendMessagePayLink(chainSelector, address(receiver), text);

        MessagingReceiver.ReceivedMessage memory stored = receiver.getMessage(msgId);
        assertEq(stored.text, text, "delivered text should match sent text");
    }
}
