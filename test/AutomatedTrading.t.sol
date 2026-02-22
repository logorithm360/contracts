// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {
    CCIPLocalSimulator,
    IRouterClient,
    LinkToken,
    BurnMintERC677Helper
} from "@chainlink/local/ccip/CCIPLocalSimulator.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {AutomatedTrader} from "../src/AutomatedTrader.sol";
import {ProgrammableTokenReceiver} from "../src/ProgrammableTokenReceiver.sol";

contract MockPriceFeed is AggregatorV3Interface {
    uint8 private immutable I_DECIMALS;
    int256 private s_answer;
    uint256 private s_updatedAt;
    uint80 private s_round;

    constructor(uint8 decimals_, int256 initialAnswer) {
        I_DECIMALS = decimals_;
        s_answer = initialAnswer;
        s_updatedAt = block.timestamp;
        s_round = 1;
    }

    function setAnswer(int256 newAnswer) external {
        s_answer = newAnswer;
        s_updatedAt = block.timestamp;
        s_round++;
    }

    function setAnswerAndTimestamp(int256 newAnswer, uint256 newTimestamp) external {
        s_answer = newAnswer;
        s_updatedAt = newTimestamp;
        s_round++;
    }

    function decimals() external view returns (uint8) {
        return I_DECIMALS;
    }

    function description() external pure returns (string memory) {
        return "MockPriceFeed";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (s_round, s_answer, s_updatedAt, s_updatedAt, s_round);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (s_round, s_answer, s_updatedAt, s_updatedAt, s_round);
    }
}

interface IFeeConfigurableRouter {
    function setFee(uint256 feeAmount) external;
}

contract AutomatedTradingTest is Test {
    CCIPLocalSimulator public simulator;
    IRouterClient public sourceRouter;
    IRouterClient public destRouter;
    LinkToken public linkToken;
    BurnMintERC677Helper public ccipBnM;
    uint64 public chainSelector;

    AutomatedTrader public trader;
    ProgrammableTokenReceiver public receiver;
    MockPriceFeed public priceFeed;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public attacker = makeAddr("attacker");
    address public forwarder = makeAddr("forwarder");

    uint256 constant LINK_FUND = 30 ether;
    uint256 constant TOKEN_AMOUNT = 0.1 ether;
    uint256 constant INTERVAL = 1 hours;
    uint256 constant MOCK_FEE = 0.01 ether;

    function setUp() public {
        simulator = new CCIPLocalSimulator();
        (
            uint64 _selector,
            IRouterClient _sourceRouter,
            IRouterClient _destRouter,,
            LinkToken _linkToken,
            BurnMintERC677Helper _ccipBnM,
        ) = simulator.configuration();

        chainSelector = _selector;
        sourceRouter = _sourceRouter;
        destRouter = _destRouter;
        linkToken = _linkToken;
        ccipBnM = _ccipBnM;

        priceFeed = new MockPriceFeed(8, 2000e8); // 2000 USD

        vm.startPrank(owner);

        trader = new AutomatedTrader(address(sourceRouter), address(linkToken));
        receiver = new ProgrammableTokenReceiver(address(destRouter));

        trader.allowlistDestinationChain(chainSelector, true);
        trader.allowlistToken(address(ccipBnM), true);
        trader.allowlistPriceFeed(address(priceFeed), true);
        trader.setForwarder(forwarder);

        receiver.allowlistSourceChain(chainSelector, true);
        receiver.allowlistSender(chainSelector, address(trader), true);

        vm.stopPrank();

        IFeeConfigurableRouter(address(sourceRouter)).setFee(MOCK_FEE);
        simulator.requestLinkFromFaucet(address(trader), LINK_FUND);
        ccipBnM.drip(address(trader));

        vm.label(address(trader), "AutomatedTrader");
        vm.label(address(receiver), "ProgrammableTokenReceiver");
    }

    function test_CreateTimedOrder_AndImmediateCheckUpkeep() public {
        _createTimedOrder("transfer", true, 0, INTERVAL);

        (bool needed,) = trader.checkUpkeep("");
        assertTrue(needed, "new timed order should be executable immediately");
    }

    function test_TimedOrder_ReTriggersAfterInterval() public {
        _createTimedOrder("transfer", true, 0, INTERVAL);

        bytes32 messageId = _runUpkeepAndGetMessageId();
        assertNotEq(messageId, bytes32(0));

        (bool neededNow,) = trader.checkUpkeep("");
        assertFalse(neededNow, "should not execute again before interval");

        skip(INTERVAL + 1);

        (bool neededLater,) = trader.checkUpkeep("");
        assertTrue(neededLater, "should execute again after interval");
    }

    function test_PriceOrder_TrueFalse() public {
        vm.startPrank(owner);
        trader.createPriceOrder(
            address(priceFeed),
            1900e18,
            true,
            address(ccipBnM),
            TOKEN_AMOUNT,
            chainSelector,
            address(receiver),
            alice,
            "transfer",
            false,
            1,
            0
        );
        vm.stopPrank();

        (bool needed,) = trader.checkUpkeep("");
        assertTrue(needed, "price >= threshold should trigger");

        // New fixture instance per test, so create another stricter order and verify not needed.
        vm.startPrank(owner);
        trader.cancelOrder(0);
        trader.createPriceOrder(
            address(priceFeed),
            2500e18,
            true,
            address(ccipBnM),
            TOKEN_AMOUNT,
            chainSelector,
            address(receiver),
            alice,
            "transfer",
            false,
            1,
            0
        );
        vm.stopPrank();

        (bool neededSecond,) = trader.checkUpkeep("");
        assertFalse(neededSecond, "price below threshold should not trigger");
    }

    function test_PriceOrder_SkipsOnStaleOrInvalidPrice() public {
        vm.warp(1000);

        vm.prank(owner);
        trader.setMaxPriceAge(30);

        priceFeed.setAnswerAndTimestamp(2000e8, block.timestamp - 60);
        vm.prank(owner);
        trader.createPriceOrder(
            address(priceFeed),
            1800e18,
            true,
            address(ccipBnM),
            TOKEN_AMOUNT,
            chainSelector,
            address(receiver),
            alice,
            "transfer",
            false,
            1,
            0
        );

        (bool staleNeeded,) = trader.checkUpkeep("");
        assertFalse(staleNeeded, "stale feed should not trigger");

        vm.prank(owner);
        trader.cancelOrder(0);

        priceFeed.setAnswer(0);
        vm.prank(owner);
        trader.createPriceOrder(
            address(priceFeed),
            1800e18,
            true,
            address(ccipBnM),
            TOKEN_AMOUNT,
            chainSelector,
            address(receiver),
            alice,
            "transfer",
            false,
            1,
            0
        );

        (bool invalidNeeded,) = trader.checkUpkeep("");
        assertFalse(invalidNeeded, "invalid feed answer should not trigger");
    }

    function test_BalanceOrder_TriggersWhenSufficient() public {
        uint256 balance = ccipBnM.balanceOf(address(trader));

        vm.prank(owner);
        trader.createBalanceOrder(
            balance / 2,
            address(ccipBnM),
            TOKEN_AMOUNT,
            chainSelector,
            address(receiver),
            alice,
            "transfer",
            false,
            1,
            0
        );

        (bool needed,) = trader.checkUpkeep("");
        assertTrue(needed, "balance order should trigger when threshold met");
    }

    function test_RevertWhen_AttackerCallsPerformUpkeep() public {
        _createTimedOrder("transfer", true, 0, INTERVAL);

        uint256[] memory orderIds = new uint256[](1);
        orderIds[0] = 0;

        vm.expectRevert(abi.encodeWithSelector(AutomatedTrader.UnauthorizedCaller.selector, attacker));
        vm.prank(attacker);
        trader.performUpkeep(abi.encode(orderIds));
    }

    function test_FullCycle_UpkeepToCCIPToReceiverProcessed() public {
        _createTimedOrder("transfer", false, 1, 0);

        uint256 aliceBefore = ccipBnM.balanceOf(alice);
        bytes32 messageId = _runUpkeepAndGetMessageId();

        ProgrammableTokenReceiver.ReceivedTransfer memory t = receiver.getTransfer(messageId);
        assertEq(uint8(t.status), uint8(ProgrammableTokenReceiver.TransferStatus.Processed));
        assertEq(t.payload.action, "transfer");
        assertEq(t.payload.recipient, alice);
        assertEq(ccipBnM.balanceOf(alice), aliceBefore + TOKEN_AMOUNT);
    }

    function test_FullCycle_NonTransferProducesActionRequestedPending() public {
        vm.prank(owner);
        receiver.setManualActionSender(chainSelector, address(trader), true);

        _createTimedOrder("stake", false, 1, 0);

        uint256 aliceBefore = ccipBnM.balanceOf(alice);
        bytes32 messageId = _runUpkeepAndGetMessageId();

        ProgrammableTokenReceiver.ReceivedTransfer memory t = receiver.getTransfer(messageId);
        assertEq(uint8(t.status), uint8(ProgrammableTokenReceiver.TransferStatus.PendingAction));
        assertEq(t.payload.action, "stake");
        assertEq(ccipBnM.balanceOf(alice), aliceBefore, "tokens should remain locked for manual action");
        assertEq(receiver.getTokenBalance(address(ccipBnM)), TOKEN_AMOUNT);
    }

    function test_MaxExecutions_StopsOrder() public {
        _createTimedOrder("transfer", true, 2, 0);

        _runUpkeepAndGetMessageId();
        _runUpkeepAndGetMessageId();

        AutomatedTrader.TradeOrder memory order = trader.getOrder(0);
        assertEq(order.executionCount, 2);
        assertEq(uint8(order.status), uint8(AutomatedTrader.OrderStatus.EXECUTED));
        assertEq(trader.getActiveOrderCount(), 0);
    }

    function test_CancelAndPauseSemantics() public {
        _createTimedOrder("transfer", true, 0, INTERVAL);

        vm.prank(owner);
        trader.pauseOrder(0, true);

        (bool neededPaused,) = trader.checkUpkeep("");
        assertFalse(neededPaused, "paused order should be skipped");

        vm.prank(owner);
        trader.pauseOrder(0, false);

        (bool neededUnpaused,) = trader.checkUpkeep("");
        assertTrue(neededUnpaused, "unpaused order should trigger again");

        vm.prank(owner);
        trader.cancelOrder(0);

        (bool neededCancelled,) = trader.checkUpkeep("");
        assertFalse(neededCancelled, "cancelled order should be skipped");
    }

    function test_InsufficientLink_SkipsWithoutGlobalRevert() public {
        _createTimedOrder("transfer", true, 0, INTERVAL);

        vm.prank(owner);
        trader.withdrawLink(owner);

        uint256[] memory orderIds = new uint256[](1);
        orderIds[0] = 0;

        vm.prank(forwarder);
        trader.performUpkeep(abi.encode(orderIds));

        AutomatedTrader.TradeOrder memory order = trader.getOrder(0);
        assertEq(order.executionCount, 0);

        (bool upkeepNeeded,) = trader.checkUpkeep("");
        assertFalse(upkeepNeeded, "without LINK balance upkeep should not be needed");
    }

    function test_EstimateFee_ReturnsNonZero() public {
        _createTimedOrder("transfer", true, 0, INTERVAL);

        uint256 fee = trader.estimateFee(0);
        assertGt(fee, 0);
    }

    function _createTimedOrder(string memory action, bool recurring, uint256 maxExec, uint256 interval_) internal {
        vm.prank(owner);
        trader.createTimedOrder(
            interval_,
            address(ccipBnM),
            TOKEN_AMOUNT,
            chainSelector,
            address(receiver),
            alice,
            action,
            recurring,
            maxExec,
            0
        );
    }

    function _runUpkeepAndGetMessageId() internal returns (bytes32 messageId) {
        (bool needed, bytes memory data) = trader.checkUpkeep("");
        assertTrue(needed, "upkeep should be needed");

        vm.recordLogs();
        vm.prank(forwarder);
        trader.performUpkeep(data);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 executedSig = keccak256("OrderExecuted(uint256,bytes32,address,uint256,uint256)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 2 && logs[i].topics[0] == executedSig) {
                messageId = logs[i].topics[2];
                break;
            }
        }

        assertNotEq(messageId, bytes32(0), "OrderExecuted messageId not found");
    }
}
