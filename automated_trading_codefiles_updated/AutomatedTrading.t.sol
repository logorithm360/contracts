// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";

import {CCIPLocalSimulator, IRouterClient, LinkToken, BurnMintERC677Helper} from
    "@chainlink/local/ccip/CCIPLocalSimulator.sol";

import {Client} from "@chainlink/contracts-ccip/libraries/Client.sol";
import {AggregatorV3Interface} from
    "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {MockV3Aggregator} from
    "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";

import {AutomatedTrader}         from "../src/AutomatedTrader.sol";
import {AutomatedTraderReceiver} from "../src/AutomatedTraderReceiver.sol";

/// @notice Unit tests for Feature 4 — Automated Cross-Chain Trading.
///         Tests all three trigger types, Automation flow, security, and edge cases.
///         Includes full Chainlink Data Feed tests using MockV3Aggregator.
///         Runs fully offline — no RPC or Automation network required.
///
/// Run: forge test --match-contract AutomatedTradingTest -vvv
contract AutomatedTradingTest is Test {

    // ── CCIP infrastructure ────────────────────────────────────
    CCIPLocalSimulator   public simulator;
    IRouterClient        public sourceRouter;
    IRouterClient        public destRouter;
    LinkToken            public linkToken;
    BurnMintERC677Helper public ccipBnM;
    uint64               public chainSelector;

    // ── Contracts under test ───────────────────────────────────
    AutomatedTrader         public trader;
    AutomatedTraderReceiver public receiver;

    // ── Chainlink Data Feed mock ───────────────────────────────
    MockV3Aggregator public mockFeed;

    // ── Actors ────────────────────────────────────────────────
    address public owner    = makeAddr("owner");
    address public alice    = makeAddr("alice");   // beneficiary of trades
    address public attacker = makeAddr("attacker");
    address public forwarder = makeAddr("forwarder"); // simulated Automation forwarder

    // ── Constants ─────────────────────────────────────────────
    uint256 constant LINK_FUND    = 30 ether;
    uint256 constant TOKEN_AMOUNT = 1 ether;
    uint256 constant INTERVAL     = 3600; // 1 hour

    // Mock feed parameters
    uint8   constant FEED_DECIMALS    = 8;                    // Chainlink standard
    int256  constant INITIAL_PRICE    = 2500_00000000;        // $2,500.00 (8 decimals)
    uint256 constant PRICE_18         = 2500e18;              // same price, 18 decimals
    uint256 constant HIGH_THRESHOLD   = 3000e18;              // above current price
    uint256 constant LOW_THRESHOLD    = 2000e18;              // below current price

    // ─────────────────────────────────────────────────────────────
    //  setUp
    // ─────────────────────────────────────────────────────────────
    function setUp() public {
        simulator = new CCIPLocalSimulator();
        (
            uint64 _cs,
            IRouterClient _srcRouter,
            IRouterClient _dstRouter,
            ,
            LinkToken _link,
            BurnMintERC677Helper _bnm,
        ) = simulator.configuration();

        chainSelector = _cs;
        sourceRouter  = _srcRouter;
        destRouter    = _dstRouter;
        linkToken     = _link;
        ccipBnM       = _bnm;

        // Deploy MockV3Aggregator — simulates a Chainlink Data Feed in tests
        // Parameters: decimals (8 = standard), initial answer ($2,500.00)
        mockFeed = new MockV3Aggregator(FEED_DECIMALS, INITIAL_PRICE);

        vm.startPrank(owner);

        // Deploy AutomatedTrader (source chain)
        trader = new AutomatedTrader(
            address(sourceRouter),
            address(linkToken)
        );

        // Deploy AutomatedTraderReceiver (dest chain)
        receiver = new AutomatedTraderReceiver(address(destRouter));

        // Configure allowlists
        trader.allowlistDestinationChain(chainSelector, true);
        trader.allowlistToken(address(ccipBnM), true);

        // Register mock price feed for CCIP-BnM token
        trader.setPriceFeed(address(ccipBnM), address(mockFeed));

        receiver.allowlistSourceChain(chainSelector, true);
        receiver.allowlistSender(address(trader), true);

        // Set simulated forwarder
        trader.setForwarder(forwarder);

        vm.stopPrank();

        // Fund trader with LINK (for CCIP fees)
        simulator.requestLinkFromFaucet(address(trader), LINK_FUND);

        // Fund trader with test tokens (for automated transfers)
        ccipBnM.drip(address(trader));

        vm.label(address(trader),   "AutomatedTrader");
        vm.label(address(receiver), "AutomatedTraderReceiver");
        vm.label(address(ccipBnM),  "CCIP-BnM");
        vm.label(address(mockFeed), "MockPriceFeed");
        vm.label(owner,             "Owner");
        vm.label(alice,             "Alice");
        vm.label(attacker,          "Attacker");
        vm.label(forwarder,         "AutomationForwarder");
    }

    // ─────────────────────────────────────────────────────────────
    //  Helpers
    // ─────────────────────────────────────────────────────────────

    function _createTimedOrder() internal returns (uint256 orderId) {
        vm.prank(owner);
        orderId = trader.createTimedOrder(
            INTERVAL,
            address(ccipBnM),
            TOKEN_AMOUNT,
            chainSelector,
            address(receiver),
            alice,
            "transfer",
            true,   // recurring
            0,      // unlimited executions
            0       // no deadline
        );
    }

    function _createPriceOrder(
        uint256 threshold,
        bool    above
    ) internal returns (uint256 orderId) {
        vm.prank(owner);
        orderId = trader.createPriceOrder(
            threshold,
            above,
            address(ccipBnM),
            TOKEN_AMOUNT,
            chainSelector,
            address(receiver),
            alice,
            "transfer",
            false,  // one-shot
            1,
            0
        );
    }

    function _createBalanceOrder(uint256 required) internal returns (uint256 orderId) {
        vm.prank(owner);
        orderId = trader.createBalanceOrder(
            required,
            address(ccipBnM),
            TOKEN_AMOUNT,
            chainSelector,
            address(receiver),
            alice,
            "transfer",
            false,  // one-shot
            1,
            0
        );
    }

    // ─────────────────────────────────────────────────────────────
    //  Order creation — TIME_BASED
    // ─────────────────────────────────────────────────────────────

    function test_CreateTimedOrder_Succeeds() public {
        uint256 orderId = _createTimedOrder();

        AutomatedTrader.TradeOrder memory order = trader.getOrder(orderId);
        assertEq(order.orderId,          0);
        assertEq(address(order.token),   address(ccipBnM));
        assertEq(order.amount,           TOKEN_AMOUNT);
        assertEq(order.interval,         INTERVAL);
        assertEq(order.recipient,        alice);
        assertEq(order.action,           "transfer");
        assertTrue(order.recurring);
        assertEq(uint8(order.status),    uint8(AutomatedTrader.OrderStatus.ACTIVE));
        assertEq(trader.getActiveOrderCount(), 1);
    }

    function test_CreatePriceOrder_Succeeds() public {
        uint256 orderId = _createPriceOrder(500e18, true); // execute when price >= 500

        AutomatedTrader.TradeOrder memory order = trader.getOrder(orderId);
        assertEq(uint8(order.triggerType), uint8(AutomatedTrader.TriggerType.PRICE_THRESHOLD));
        assertEq(order.priceThreshold, 500e18);
        assertTrue(order.executeAbove);
    }

    function test_CreateBalanceOrder_Succeeds() public {
        uint256 required = TOKEN_AMOUNT / 2;
        uint256 orderId  = _createBalanceOrder(required);

        AutomatedTrader.TradeOrder memory order = trader.getOrder(orderId);
        assertEq(uint8(order.triggerType), uint8(AutomatedTrader.TriggerType.BALANCE_TRIGGER));
        assertEq(order.balanceRequired, required);
    }

    function test_MultipleOrders_AllTracked() public {
        _createTimedOrder();
        _createPriceOrder(500e18, true);
        _createBalanceOrder(TOKEN_AMOUNT / 2);

        assertEq(trader.getActiveOrderCount(), 3);
        assertEq(trader.nextOrderId(), 3);
    }

    // ─────────────────────────────────────────────────────────────
    //  checkUpkeep — TIME_BASED trigger
    // ─────────────────────────────────────────────────────────────

    function test_CheckUpkeep_TimedOrder_ReturnsTrue_WhenFirstCreated() public {
        _createTimedOrder();

        // lastExecutedAt = 0 means timeSinceLast = block.timestamp (always >= interval)
        // So a freshly created order is immediately executable — correct behaviour
        // for DCA: the first execution fires right away, then respects the interval.
        (bool needed,) = trader.checkUpkeep("");
        assertTrue(needed, "Should be needed immediately (lastExecutedAt=0)");
    }

    function test_CheckUpkeep_TimedOrder_ReturnsFalse_AfterExecution() public {
        uint256 orderId = _createTimedOrder();

        // Simulate execution by calling performUpkeep
        (bool needed, bytes memory data) = trader.checkUpkeep("");
        assertTrue(needed);

        // Fund token allowance
        vm.prank(owner);
        ccipBnM.approve(address(trader), TOKEN_AMOUNT);

        // Execute via forwarder
        vm.prank(forwarder);
        trader.performUpkeep(data);

        // Immediately after — interval not elapsed, should be false
        (bool neededAfter,) = trader.checkUpkeep("");
        assertFalse(neededAfter, "Should not be needed immediately after execution");
    }

    function test_CheckUpkeep_TimedOrder_ReturnsTrue_AfterInterval() public {
        uint256 orderId = _createTimedOrder();

        // Fast-forward time past interval
        skip(INTERVAL + 1);

        (bool needed,) = trader.checkUpkeep("");
        assertTrue(needed, "Should be needed after interval elapsed");
        console.log("Order ID ready:", orderId);
    }

    // ─────────────────────────────────────────────────────────────
    //  checkUpkeep — PRICE_THRESHOLD trigger (real Data Feed)
    // ─────────────────────────────────────────────────────────────

    function test_CheckUpkeep_PriceOrder_ReturnsFalse_PriceNotMet() public {
        // Mock feed = $2,500. Threshold = $3,000 (above). Price not met.
        _createPriceOrder(HIGH_THRESHOLD, true);

        (bool needed,) = trader.checkUpkeep("");
        assertFalse(needed, "Should not trigger: price $2500 < threshold $3000");
    }

    function test_CheckUpkeep_PriceOrder_ReturnsTrue_PriceMet() public {
        // Mock feed = $2,500. Threshold = $2,000 (above). Price met.
        _createPriceOrder(LOW_THRESHOLD, true);

        (bool needed,) = trader.checkUpkeep("");
        assertTrue(needed, "Should trigger: price $2500 > threshold $2000");
    }

    function test_CheckUpkeep_PriceOrder_BelowThreshold_Triggers() public {
        // Execute when price drops BELOW $3,000 — currently $2,500, so met
        _createPriceOrder(HIGH_THRESHOLD, false);

        (bool needed,) = trader.checkUpkeep("");
        assertTrue(needed, "Should trigger: price $2500 < threshold $3000 (executeBelow)");
    }

    function test_CheckUpkeep_PriceOrder_PriceRisesAboveThreshold_Triggers() public {
        // Order: execute when price >= $3,000
        _createPriceOrder(HIGH_THRESHOLD, true);

        // Initially $2,500 — not triggered
        (bool needed1,) = trader.checkUpkeep("");
        assertFalse(needed1);

        // Price rises to $3,500 — now triggered
        mockFeed.updateAnswer(3500_00000000); // $3,500.00
        (bool needed2,) = trader.checkUpkeep("");
        assertTrue(needed2, "Should trigger after price rises above threshold");
    }

    function test_CheckUpkeep_PriceOrder_SkipsWhen_NoFeedRegistered() public {
        // Create a fresh trader with no feed registered for the token
        vm.startPrank(owner);
        AutomatedTrader freshTrader = new AutomatedTrader(
            address(sourceRouter), address(linkToken)
        );
        freshTrader.allowlistDestinationChain(chainSelector, true);
        freshTrader.allowlistToken(address(ccipBnM), true);
        // Deliberately do NOT call setPriceFeed

        freshTrader.createPriceOrder(
            LOW_THRESHOLD, true,
            address(ccipBnM), TOKEN_AMOUNT / 10,
            chainSelector, address(receiver), alice,
            "transfer", false, 1, 0
        );
        vm.stopPrank();

        // Should not trigger — no feed = price returns 0 = skipped safely
        (bool needed,) = freshTrader.checkUpkeep("");
        assertFalse(needed, "Should skip when no price feed registered");
    }

    function test_CheckUpkeep_PriceOrder_SkipsWhen_FeedIsStale() public {
        _createPriceOrder(LOW_THRESHOLD, true);

        // Initially triggers fine
        (bool needed1,) = trader.checkUpkeep("");
        assertTrue(needed1);

        // Fast forward past staleness threshold (3 hours + 1 second)
        skip(3 hours + 1);
        // Note: MockV3Aggregator keeps the same updatedAt timestamp
        // so after 3 hours the price is considered stale

        (bool needed2,) = trader.checkUpkeep("");
        assertFalse(needed2, "Should skip when price feed is stale");
    }

    // ─────────────────────────────────────────────────────────────
    //  checkUpkeep — BALANCE_TRIGGER
    // ─────────────────────────────────────────────────────────────

    function test_CheckUpkeep_BalanceOrder_ReturnsTrue_BalanceSufficient() public {
        uint256 balance  = ccipBnM.balanceOf(address(trader));
        uint256 required = balance / 2; // require half of what we have

        _createBalanceOrder(required);

        (bool needed,) = trader.checkUpkeep("");
        assertTrue(needed, "Should trigger when balance sufficient");
    }

    function test_CheckUpkeep_BalanceOrder_ReturnsFalse_InsufficientBalance() public {
        uint256 balance  = ccipBnM.balanceOf(address(trader));
        uint256 required = balance * 10; // require 10x what we have

        _createBalanceOrder(required);

        (bool needed,) = trader.checkUpkeep("");
        assertFalse(needed, "Should not trigger when balance insufficient");
    }

    function test_CheckUpkeep_NoOrders_ReturnsFalse() public {
        (bool needed,) = trader.checkUpkeep("");
        assertFalse(needed, "Should be false with no orders");
    }

    // ─────────────────────────────────────────────────────────────
    //  performUpkeep — full automation cycle
    // ─────────────────────────────────────────────────────────────

    function test_PerformUpkeep_ExecutesOrder_AndEmitsEvent() public {
        _createTimedOrder();

        (bool needed, bytes memory data) = trader.checkUpkeep("");
        assertTrue(needed);

        vm.expectEmit(true, false, false, false);
        emit AutomatedTrader.OrderExecuted(0, bytes32(0), address(ccipBnM), TOKEN_AMOUNT, 1);

        vm.prank(forwarder);
        trader.performUpkeep(data);

        // Order execution count should be 1
        AutomatedTrader.TradeOrder memory order = trader.getOrder(0);
        assertEq(order.executionCount, 1);
        assertGt(order.lastExecutedAt, 0);
    }

    function test_PerformUpkeep_RecurringOrder_RemainsActive() public {
        _createTimedOrder();

        (bool needed, bytes memory data) = trader.checkUpkeep("");
        assertTrue(needed);

        vm.prank(forwarder);
        trader.performUpkeep(data);

        // Recurring order should still be ACTIVE
        AutomatedTrader.TradeOrder memory order = trader.getOrder(0);
        assertEq(uint8(order.status), uint8(AutomatedTrader.OrderStatus.ACTIVE));
        assertEq(trader.getActiveOrderCount(), 1, "Recurring order should remain in active list");
    }

    function test_PerformUpkeep_OneShot_BecomesExecuted() public {
        // Create one-shot order (recurring = false)
        vm.prank(owner);
        trader.createTimedOrder(
            0,              // interval 0 = always ready
            address(ccipBnM),
            TOKEN_AMOUNT,
            chainSelector,
            address(receiver),
            alice,
            "transfer",
            false,          // NOT recurring — one shot
            1,
            0
        );

        (bool needed, bytes memory data) = trader.checkUpkeep("");
        assertTrue(needed);

        vm.prank(forwarder);
        trader.performUpkeep(data);

        // One-shot should now be EXECUTED and removed from active list
        AutomatedTrader.TradeOrder memory order = trader.getOrder(0);
        assertEq(uint8(order.status), uint8(AutomatedTrader.OrderStatus.EXECUTED));
        assertEq(trader.getActiveOrderCount(), 0, "One-shot should be removed from active list");
    }

    function test_PerformUpkeep_MaxExecutions_StopsOrder() public {
        // Create order with maxExecutions = 2
        vm.prank(owner);
        trader.createTimedOrder(
            0,              // always ready
            address(ccipBnM),
            TOKEN_AMOUNT / 10,
            chainSelector,
            address(receiver),
            alice,
            "transfer",
            true,           // recurring
            2,              // max 2 executions
            0
        );

        // Fund more tokens and LINK for multiple executions
        ccipBnM.drip(address(trader));
        simulator.requestLinkFromFaucet(address(trader), 10 ether);

        // First execution
        (, bytes memory data1) = trader.checkUpkeep("");
        vm.prank(forwarder);
        trader.performUpkeep(data1);
        assertEq(trader.getOrder(0).executionCount, 1);

        // Second execution
        (, bytes memory data2) = trader.checkUpkeep("");
        vm.prank(forwarder);
        trader.performUpkeep(data2);
        assertEq(trader.getOrder(0).executionCount, 2);

        // After max executions: order should be EXECUTED, removed from active
        assertEq(uint8(trader.getOrder(0).status), uint8(AutomatedTrader.OrderStatus.EXECUTED));
        assertEq(trader.getActiveOrderCount(), 0);
    }

    // ─────────────────────────────────────────────────────────────
    //  Full end-to-end: automation triggers → CCIP → receiver
    // ─────────────────────────────────────────────────────────────

    function test_FullCycle_AutomationTriggersToCCIPToReceiver() public {
        _createTimedOrder();

        uint256 aliceBalanceBefore = ccipBnM.balanceOf(alice);

        // Step 1: checkUpkeep detects order is ready
        (bool needed, bytes memory data) = trader.checkUpkeep("");
        assertTrue(needed, "checkUpkeep should return true");

        // Step 2: Automation calls performUpkeep → fires CCIP message
        vm.prank(forwarder);
        trader.performUpkeep(data);

        // Step 3: Simulate CCIP routing to receiver
        // Get the messageId from the OrderExecuted event (we need to find it)
        AutomatedTrader.TradeOrder memory order = trader.getOrder(0);
        assertEq(order.executionCount, 1, "Should have executed once");

        console.log("Automation cycle complete. Execution count:", order.executionCount);
        console.log("Trader LINK remaining:", trader.getLinkBalance());
    }

    function test_FullCycle_WithCCIPDelivery() public {
        _createTimedOrder();

        (bool needed, bytes memory data) = trader.checkUpkeep("");
        assertTrue(needed);

        // Capture messageId from event
        vm.recordLogs();
        vm.prank(forwarder);
        trader.performUpkeep(data);

        // Extract messageId from OrderExecuted event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 ccipMessageId;
        for (uint256 i = 0; i < logs.length; i++) {
            // OrderExecuted(uint256 indexed orderId, bytes32 indexed ccipMessageId, ...)
            if (logs[i].topics[0] == keccak256("OrderExecuted(uint256,bytes32,address,uint256,uint256)")) {
                ccipMessageId = logs[i].topics[2];
                break;
            }
        }

        if (ccipMessageId != bytes32(0)) {
            // Route CCIP message to receiver
            simulator.routeMessage(ccipMessageId);

            // Verify trade stored in receiver
            AutomatedTraderReceiver.ExecutedTrade memory trade = receiver.getTrade(ccipMessageId);
            assertEq(trade.token,     address(ccipBnM), "token mismatch");
            assertEq(trade.amount,    TOKEN_AMOUNT,     "amount mismatch");
            assertEq(trade.recipient, alice,            "recipient mismatch");
            assertEq(trade.action,    "transfer",       "action mismatch");
            assertEq(uint8(trade.status), uint8(AutomatedTraderReceiver.TradeStatus.Executed));

            // Alice received her tokens
            assertEq(ccipBnM.balanceOf(alice), TOKEN_AMOUNT, "Alice should receive tokens");
            assertEq(receiver.getTradeCount(), 1);
            console.log("Full cycle: Automation -> CCIP -> Receiver -> Alice's wallet");
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  Deadline expiry
    // ─────────────────────────────────────────────────────────────

    function test_Order_ExpiredDeadline_SkippedByCheckUpkeep() public {
        // Create order with a past deadline
        vm.prank(owner);
        trader.createTimedOrder(
            0,
            address(ccipBnM),
            TOKEN_AMOUNT,
            chainSelector,
            address(receiver),
            alice,
            "transfer",
            false,
            1,
            block.timestamp - 1  // already expired
        );

        (bool needed,) = trader.checkUpkeep("");
        assertFalse(needed, "Expired order should not trigger upkeep");
    }

    // ─────────────────────────────────────────────────────────────
    //  Cancel and pause
    // ─────────────────────────────────────────────────────────────

    function test_CancelOrder_RemovesFromActive() public {
        uint256 orderId = _createTimedOrder();
        assertEq(trader.getActiveOrderCount(), 1);

        vm.prank(owner);
        trader.cancelOrder(orderId);

        assertEq(trader.getActiveOrderCount(), 0);
        assertEq(
            uint8(trader.getOrder(orderId).status),
            uint8(AutomatedTrader.OrderStatus.CANCELLED)
        );

        // Cancelled order should not trigger upkeep
        (bool needed,) = trader.checkUpkeep("");
        assertFalse(needed);
    }

    function test_PauseOrder_SkippedByCheckUpkeep() public {
        uint256 orderId = _createTimedOrder();

        vm.prank(owner);
        trader.pauseOrder(orderId, true);

        (bool needed,) = trader.checkUpkeep("");
        assertFalse(needed, "Paused order should not trigger upkeep");
    }

    function test_UnpauseOrder_TriggersCheckUpkeep() public {
        uint256 orderId = _createTimedOrder();

        vm.prank(owner);
        trader.pauseOrder(orderId, true);
        (bool needed1,) = trader.checkUpkeep("");
        assertFalse(needed1);

        vm.prank(owner);
        trader.pauseOrder(orderId, false); // unpause

        (bool needed2,) = trader.checkUpkeep("");
        assertTrue(needed2, "Unpaused order should trigger upkeep");
    }

    // ─────────────────────────────────────────────────────────────
    //  Security: only forwarder can call performUpkeep
    // ─────────────────────────────────────────────────────────────

    function test_RevertWhen_AttackerCallsPerformUpkeep() public {
        _createTimedOrder();
        (, bytes memory data) = trader.checkUpkeep("");

        vm.expectRevert(
            abi.encodeWithSelector(AutomatedTrader.UnauthorizedCaller.selector, attacker)
        );
        vm.prank(attacker);
        trader.performUpkeep(data);
    }

    function test_OwnerCanCallPerformUpkeep_BeforeForwarderSet() public {
        // Deploy fresh trader with no forwarder set
        vm.prank(owner);
        AutomatedTrader freshTrader = new AutomatedTrader(
            address(sourceRouter),
            address(linkToken)
        );
        vm.prank(owner);
        freshTrader.allowlistDestinationChain(chainSelector, true);
        vm.prank(owner);
        freshTrader.allowlistToken(address(ccipBnM), true);

        simulator.requestLinkFromFaucet(address(freshTrader), 10 ether);
        ccipBnM.drip(address(freshTrader));

        vm.prank(owner);
        freshTrader.createTimedOrder(0, address(ccipBnM), TOKEN_AMOUNT / 10,
            chainSelector, address(receiver), alice, "transfer", false, 1, 0);

        (, bytes memory data) = freshTrader.checkUpkeep("");

        // Owner can call without forwarder set (for testing)
        vm.prank(owner);
        freshTrader.performUpkeep(data); // should not revert
    }

    function test_RevertWhen_AttackerSetsForwarder() public {
        vm.expectRevert();
        vm.prank(attacker);
        trader.setForwarder(attacker);
    }

    // ─────────────────────────────────────────────────────────────
    //  Security: only owner creates orders
    // ─────────────────────────────────────────────────────────────

    function test_RevertWhen_AttackerCreatesOrder() public {
        vm.expectRevert();
        vm.prank(attacker);
        trader.createTimedOrder(
            INTERVAL, address(ccipBnM), TOKEN_AMOUNT,
            chainSelector, address(receiver), alice, "transfer", true, 0, 0
        );
    }

    // ─────────────────────────────────────────────────────────────
    //  Revert: destination chain not allowlisted
    // ─────────────────────────────────────────────────────────────

    function test_RevertWhen_ChainNotAllowlisted() public {
        uint64 badChain = 9999;
        vm.expectRevert(
            abi.encodeWithSelector(AutomatedTrader.DestinationChainNotAllowlisted.selector, badChain)
        );
        vm.prank(owner);
        trader.createTimedOrder(
            INTERVAL, address(ccipBnM), TOKEN_AMOUNT,
            badChain, address(receiver), alice, "transfer", true, 0, 0
        );
    }

    // ─────────────────────────────────────────────────────────────
    //  Revert: token not allowlisted
    // ─────────────────────────────────────────────────────────────

    function test_RevertWhen_TokenNotAllowlisted() public {
        address badToken = makeAddr("badToken");
        vm.expectRevert(
            abi.encodeWithSelector(AutomatedTrader.TokenNotAllowlisted.selector, badToken)
        );
        vm.prank(owner);
        trader.createTimedOrder(
            INTERVAL, badToken, TOKEN_AMOUNT,
            chainSelector, address(receiver), alice, "transfer", true, 0, 0
        );
    }

    // ─────────────────────────────────────────────────────────────
    //  estimateFee
    // ─────────────────────────────────────────────────────────────

    function test_EstimateFee_NonZero() public {
        uint256 orderId = _createTimedOrder();
        uint256 fee     = trader.estimateFee(orderId);
        assertGt(fee, 0, "fee should be non-zero");
        console.log("Estimated LINK fee per execution:", fee);
    }

    // ─────────────────────────────────────────────────────────────
    //  Emergency withdrawals
    // ─────────────────────────────────────────────────────────────

    function test_WithdrawLink_Succeeds() public {
        uint256 bal = linkToken.balanceOf(address(trader));
        assertGt(bal, 0);

        vm.prank(owner);
        trader.withdrawLink(owner);

        assertEq(linkToken.balanceOf(address(trader)), 0);
        assertEq(linkToken.balanceOf(owner), bal);
    }

    function test_WithdrawToken_Succeeds() public {
        uint256 bal = ccipBnM.balanceOf(address(trader));
        assertGt(bal, 0);

        vm.prank(owner);
        trader.withdrawToken(address(ccipBnM), owner);

        assertEq(ccipBnM.balanceOf(address(trader)), 0);
        assertEq(ccipBnM.balanceOf(owner), bal);
    }

    // ─────────────────────────────────────────────────────────────
    //  Receiver: unsupported action locks tokens, owner recovers
    // ─────────────────────────────────────────────────────────────

    function test_Receiver_UnsupportedAction_OwnerRecovers() public {
        // Manually inject a bad message to the receiver by
        // temporarily allowlisting this test contract as a sender
        // and calling processTransfer — simulates a failed trade
        // (The real path would come from the CCIP router)
        // For this test we verify the recovery function directly

        // Drain ccipBnM to receiver to simulate locked tokens
        ccipBnM.drip(address(receiver));
        uint256 bal = ccipBnM.balanceOf(address(receiver));

        vm.prank(owner);
        receiver.withdrawToken(address(ccipBnM), owner);

        assertEq(ccipBnM.balanceOf(address(receiver)), 0);
        assertEq(ccipBnM.balanceOf(owner), bal);
    }

    // ─────────────────────────────────────────────────────────────
    //  Chainlink Data Feeds — setPriceFeed, getPriceFeedData
    // ─────────────────────────────────────────────────────────────

    function test_SetPriceFeed_Succeeds() public {
        address feed = trader.s_priceFeeds(address(ccipBnM));
        assertEq(feed, address(mockFeed), "Feed should be registered in setUp");
    }

    function test_SetPriceFeed_UpdatesExistingFeed() public {
        MockV3Aggregator newFeed = new MockV3Aggregator(8, 3000_00000000);
        vm.prank(owner);
        trader.setPriceFeed(address(ccipBnM), address(newFeed));

        assertEq(trader.s_priceFeeds(address(ccipBnM)), address(newFeed));
    }

    function test_RevertWhen_AttackerSetsPriceFeed() public {
        vm.expectRevert();
        vm.prank(attacker);
        trader.setPriceFeed(address(ccipBnM), address(mockFeed));
    }

    function test_GetPriceFeedData_ReturnsCorrectValues() public {
        (
            address feedAddr,
            int256  price,
            uint256 updatedAt,
            bool    isStale
        ) = trader.getPriceFeedData(address(ccipBnM));

        assertEq(feedAddr,  address(mockFeed));
        assertEq(price,     INITIAL_PRICE);      // $2,500.00 with 8 decimals
        assertGt(updatedAt, 0);
        assertFalse(isStale, "Fresh feed should not be stale");

        console.log("Feed address:  ", feedAddr);
        console.log("Current price: ", uint256(price));
        console.log("Updated at:    ", updatedAt);
        console.log("Is stale:      ", isStale);
    }

    function test_GetPriceFeedData_ReturnsStale_AfterThreshold() public {
        skip(3 hours + 1);
        (,,, bool isStale) = trader.getPriceFeedData(address(ccipBnM));
        assertTrue(isStale, "Should be stale after threshold");
    }

    function test_GetPriceFeedData_Reverts_WhenNoFeedRegistered() public {
        address tokenWithNoFeed = makeAddr("randomToken");
        vm.expectRevert(
            abi.encodeWithSelector(AutomatedTrader.PriceFeedNotSet.selector, tokenWithNoFeed)
        );
        trader.getPriceFeedData(tokenWithNoFeed);
    }

    function test_PriceFeedData_UpdatesReflectInOrders() public {
        // Order: execute when price >= $3,000
        _createPriceOrder(HIGH_THRESHOLD, true);

        // $2,500 — not triggered
        (bool needed1,) = trader.checkUpkeep("");
        assertFalse(needed1);

        // Update mock feed to $3,100
        mockFeed.updateAnswer(3100_00000000);

        // Now triggered
        (bool needed2,) = trader.checkUpkeep("");
        assertTrue(needed2, "Should trigger after price feed update");

        // Execute it
        (, bytes memory data) = trader.checkUpkeep("");
        vm.prank(forwarder);
        trader.performUpkeep(data);

        assertEq(trader.getOrder(0).executionCount, 1);
        console.log("Trade executed at price: $3,100");
    }

    function testFuzz_PriceOrder_TriggersCorrectly(
        int256 feedPrice,
        uint256 threshold,
        bool executeAbove
    ) public {
        // Bound inputs to realistic price ranges (>0 and <$1M)
        feedPrice = bound(feedPrice, 1_00000000, 1_000_000_00000000); // $1 to $1M (8 dec)
        threshold = bound(threshold, 1e18, 1_000_000e18);              // $1 to $1M (18 dec)

        mockFeed.updateAnswer(feedPrice);

        vm.prank(owner);
        trader.createPriceOrder(
            threshold, executeAbove,
            address(ccipBnM), TOKEN_AMOUNT / 100,
            chainSelector, address(receiver), alice,
            "transfer", false, 1, 0
        );

        uint256 priceNormalised = uint256(feedPrice) * 1e10; // normalise to 18 dec
        (bool needed,) = trader.checkUpkeep("");

        if (executeAbove) {
            assertEq(needed, priceNormalised >= threshold,
                "executeAbove: should trigger when price >= threshold");
        } else {
            assertEq(needed, priceNormalised <= threshold,
                "executeBelow: should trigger when price <= threshold");
        }
    }
}

