// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {CCIPLocalSimulator, IRouterClient, LinkToken, BurnMintERC677Helper} from
    "@chainlink/local/ccip/CCIPLocalSimulator.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ProgrammableTokenSender} from "../src/ProgrammableTokenSender.sol";
import {ProgrammableTokenReceiver} from "../src/ProgrammableTokenReceiver.sol";

interface IFeeConfigurableRouter {
    function setFee(uint256 feeAmount) external;
}

contract ProgrammableTokenTest is Test {
    CCIPLocalSimulator public simulator;
    IRouterClient public sourceRouter;
    IRouterClient public destRouter;
    LinkToken public linkToken;
    BurnMintERC677Helper public ccipBnM;
    uint64 public chainSelector;

    ProgrammableTokenSender public sender;
    ProgrammableTokenReceiver public receiver;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public attacker = makeAddr("attacker");

    uint256 constant LINK_FUND = 20 ether;
    uint256 constant NATIVE_FUND = 5 ether;
    uint256 constant MOCK_FEE = 0.01 ether;

    function setUp() public {
        simulator = new CCIPLocalSimulator();
        (
            uint64 _chainSelector,
            IRouterClient _srcRouter,
            IRouterClient _dstRouter,
            ,
            LinkToken _link,
            BurnMintERC677Helper _bnm,

        ) = simulator.configuration();

        chainSelector = _chainSelector;
        sourceRouter = _srcRouter;
        destRouter = _dstRouter;
        linkToken = _link;
        ccipBnM = _bnm;

        vm.startPrank(owner);

        sender = new ProgrammableTokenSender(address(sourceRouter), address(linkToken), true);
        receiver = new ProgrammableTokenReceiver(address(destRouter));

        sender.allowlistDestinationChain(chainSelector, true);
        sender.allowlistToken(address(ccipBnM), true);

        receiver.allowlistSourceChain(chainSelector, true);
        receiver.allowlistSender(chainSelector, address(sender), true);

        vm.stopPrank();

        simulator.requestLinkFromFaucet(address(sender), LINK_FUND);
        vm.deal(address(sender), NATIVE_FUND);
        vm.deal(owner, NATIVE_FUND);
        vm.deal(alice, NATIVE_FUND);

        ccipBnM.drip(alice);

        IFeeConfigurableRouter(address(sourceRouter)).setFee(MOCK_FEE);
    }

    function _makePayload(address recipient, string memory action)
        internal
        view
        returns (ProgrammableTokenSender.TransferPayload memory)
    {
        return ProgrammableTokenSender.TransferPayload({
            recipient: recipient,
            action: action,
            extraData: "",
            deadline: block.timestamp + 1 hours
        });
    }

    function _sendTokensWithPayload(
        address caller,
        address token,
        uint256 amount,
        address recipient,
        string memory action
    ) internal returns (bytes32 messageId) {
        ProgrammableTokenSender.TransferPayload memory payload = _makePayload(recipient, action);

        simulator.requestLinkFromFaucet(address(sender), 5 ether);

        vm.startPrank(caller);
        IERC20(token).approve(address(sender), amount);
        messageId = sender.sendPayLink(
            chainSelector,
            address(receiver),
            token,
            amount,
            payload
        );
        vm.stopPrank();
    }

    function test_TransferAction_Succeeds() public {
        uint256 amount = ccipBnM.balanceOf(alice);
        bytes32 msgId = _sendTokensWithPayload(alice, address(ccipBnM), amount, bob, "transfer");

        assertNotEq(msgId, bytes32(0));

        ProgrammableTokenReceiver.ReceivedTransfer memory t = receiver.getTransfer(msgId);
        assertEq(t.messageId, msgId);
        assertEq(t.senderContract, address(sender));
        assertEq(t.originSender, alice);
        assertEq(t.token, address(ccipBnM));
        assertEq(t.amount, amount);
        assertEq(t.payload.recipient, bob);
        assertEq(t.payload.action, "transfer");
        assertEq(uint8(t.status), uint8(ProgrammableTokenReceiver.TransferStatus.Processed));

        assertEq(ccipBnM.balanceOf(bob), amount);
        assertEq(receiver.totalReceived(address(ccipBnM)), amount);
        assertEq(receiver.totalProcessed(address(ccipBnM)), amount);
    }

    function test_StakeAction_Succeeds() public {
        uint256 amount = ccipBnM.balanceOf(alice);
        bytes32 msgId = _sendTokensWithPayload(alice, address(ccipBnM), amount, bob, "stake");

        ProgrammableTokenReceiver.ReceivedTransfer memory t = receiver.getTransfer(msgId);
        assertEq(t.payload.action, "stake");
        assertEq(uint8(t.status), uint8(ProgrammableTokenReceiver.TransferStatus.Processed));
    }

    function test_SwapAction_Succeeds() public {
        uint256 amount = ccipBnM.balanceOf(alice);
        bytes32 msgId = _sendTokensWithPayload(alice, address(ccipBnM), amount, bob, "swap");

        ProgrammableTokenReceiver.ReceivedTransfer memory t = receiver.getTransfer(msgId);
        assertEq(t.payload.action, "swap");
        assertEq(uint8(t.status), uint8(ProgrammableTokenReceiver.TransferStatus.Processed));
    }

    function test_DepositAction_Succeeds() public {
        uint256 amount = ccipBnM.balanceOf(alice);
        bytes32 msgId = _sendTokensWithPayload(alice, address(ccipBnM), amount, bob, "deposit");

        ProgrammableTokenReceiver.ReceivedTransfer memory t = receiver.getTransfer(msgId);
        assertEq(t.payload.action, "deposit");
        assertEq(uint8(t.status), uint8(ProgrammableTokenReceiver.TransferStatus.Processed));
    }

    function test_SendPayNative_Succeeds() public {
        vm.prank(owner);
        sender.setPayFeesInLink(false);

        uint256 amount = ccipBnM.balanceOf(alice);
        ProgrammableTokenSender.TransferPayload memory payload = _makePayload(bob, "transfer");

        uint256 fee = sender.estimateFee(chainSelector, address(receiver), address(ccipBnM), amount, payload);

        vm.startPrank(alice);
        ccipBnM.approve(address(sender), amount);
        bytes32 msgId = sender.sendPayNative{value: fee + 1}(
            chainSelector,
            address(receiver),
            address(ccipBnM),
            amount,
            payload
        );
        vm.stopPrank();

        assertNotEq(msgId, bytes32(0));
        assertEq(ccipBnM.balanceOf(bob), amount);
    }

    function test_UnsupportedAction_LocksTokens_OwnerCanRecover() public {
        uint256 amount = ccipBnM.balanceOf(alice);
        bytes32 msgId = _sendTokensWithPayload(alice, address(ccipBnM), amount, bob, "liquidate");

        ProgrammableTokenReceiver.ReceivedTransfer memory t = receiver.getTransfer(msgId);
        assertEq(uint8(t.status), uint8(ProgrammableTokenReceiver.TransferStatus.Failed));

        assertEq(receiver.getTokenBalance(address(ccipBnM)), amount);
        assertEq(ccipBnM.balanceOf(bob), 0);

        vm.prank(owner);
        receiver.recoverLockedTokens(msgId, bob);

        assertEq(ccipBnM.balanceOf(bob), amount);

        ProgrammableTokenReceiver.ReceivedTransfer memory recovered = receiver.getTransfer(msgId);
        assertEq(uint8(recovered.status), uint8(ProgrammableTokenReceiver.TransferStatus.Recovered));
    }

    function test_ExpiredDeadline_LocksTokens() public {
        vm.warp(2);
        uint256 amount = ccipBnM.balanceOf(alice);

        ProgrammableTokenSender.TransferPayload memory expiredPayload = ProgrammableTokenSender.TransferPayload({
            recipient: bob,
            action: "transfer",
            extraData: "",
            deadline: block.timestamp - 1
        });

        simulator.requestLinkFromFaucet(address(sender), 5 ether);

        vm.startPrank(alice);
        ccipBnM.approve(address(sender), amount);
        bytes32 msgId = sender.sendPayLink(chainSelector, address(receiver), address(ccipBnM), amount, expiredPayload);
        vm.stopPrank();

        ProgrammableTokenReceiver.ReceivedTransfer memory t = receiver.getTransfer(msgId);
        assertEq(uint8(t.status), uint8(ProgrammableTokenReceiver.TransferStatus.Failed));
        assertEq(receiver.getTokenBalance(address(ccipBnM)), amount);
        assertEq(ccipBnM.balanceOf(bob), 0);
    }

    function test_MultipleTransfers_AllTracked() public {
        ccipBnM.drip(bob);

        uint256 aliceAmt = ccipBnM.balanceOf(alice);
        uint256 bobAmt = ccipBnM.balanceOf(bob);

        bytes32 id1 = _sendTokensWithPayload(alice, address(ccipBnM), aliceAmt, alice, "transfer");
        bytes32 id2 = _sendTokensWithPayload(bob, address(ccipBnM), bobAmt, bob, "stake");

        assertEq(receiver.getTransferCount(), 2);
        assertEq(receiver.totalReceived(address(ccipBnM)), aliceAmt + bobAmt);
        assertEq(receiver.totalProcessed(address(ccipBnM)), aliceAmt + bobAmt);

        ProgrammableTokenReceiver.ReceivedTransfer memory first = receiver.getTransfer(id1);
        ProgrammableTokenReceiver.ReceivedTransfer memory last = receiver.getTransfer(id2);

        assertEq(first.payload.action, "transfer");
        assertEq(last.payload.action, "stake");
        assertEq(last.payload.recipient, bob);
    }

    function test_RevertWhen_DestChainNotAllowlisted() public {
        uint64 unknown = 9999;
        uint256 amount = ccipBnM.balanceOf(alice);
        ProgrammableTokenSender.TransferPayload memory payload = _makePayload(bob, "transfer");

        vm.startPrank(alice);
        ccipBnM.approve(address(sender), amount);
        vm.expectRevert(
            abi.encodeWithSelector(ProgrammableTokenSender.DestinationChainNotAllowlisted.selector, unknown)
        );
        sender.sendPayLink(unknown, address(receiver), address(ccipBnM), amount, payload);
        vm.stopPrank();
    }

    function test_RevertWhen_TokenNotAllowlisted() public {
        address fakeToken = makeAddr("fakeToken");
        ProgrammableTokenSender.TransferPayload memory payload = _makePayload(bob, "transfer");

        vm.expectRevert(
            abi.encodeWithSelector(ProgrammableTokenSender.TokenNotAllowlisted.selector, fakeToken)
        );
        vm.prank(alice);
        sender.sendPayLink(chainSelector, address(receiver), fakeToken, 1 ether, payload);
    }

    function test_RevertWhen_ZeroAmount() public {
        ProgrammableTokenSender.TransferPayload memory payload = _makePayload(bob, "transfer");
        vm.expectRevert(ProgrammableTokenSender.ZeroAmount.selector);
        vm.prank(alice);
        sender.sendPayLink(chainSelector, address(receiver), address(ccipBnM), 0, payload);
    }

    function test_RevertWhen_EmptyPayloadAction() public {
        ProgrammableTokenSender.TransferPayload memory payload = ProgrammableTokenSender.TransferPayload({
            recipient: bob,
            action: "",
            extraData: "",
            deadline: block.timestamp + 1 hours
        });

        vm.expectRevert(ProgrammableTokenSender.EmptyPayload.selector);
        vm.prank(alice);
        sender.sendPayLink(chainSelector, address(receiver), address(ccipBnM), 1 ether, payload);
    }

    function test_RevertWhen_ZeroPayloadRecipient() public {
        ProgrammableTokenSender.TransferPayload memory payload = ProgrammableTokenSender.TransferPayload({
            recipient: address(0),
            action: "transfer",
            extraData: "",
            deadline: block.timestamp + 1 hours
        });

        vm.expectRevert(ProgrammableTokenSender.ZeroAddress.selector);
        vm.prank(alice);
        sender.sendPayLink(chainSelector, address(receiver), address(ccipBnM), 1 ether, payload);
    }

    function test_RevertWhen_AttackerCallsProcessTransfer() public {
        uint256 amount = ccipBnM.balanceOf(alice);
        bytes32 msgId = _sendTokensWithPayload(alice, address(ccipBnM), amount, bob, "transfer");

        vm.expectRevert(
            abi.encodeWithSelector(ProgrammableTokenReceiver.UnauthorizedCaller.selector, attacker)
        );
        vm.prank(attacker);
        receiver.processTransfer(msgId);
    }

    function test_RevertWhen_AttackerCallsRecoverTokens() public {
        uint256 amount = ccipBnM.balanceOf(alice);
        bytes32 msgId = _sendTokensWithPayload(alice, address(ccipBnM), amount, bob, "liquidate");

        vm.expectRevert();
        vm.prank(attacker);
        receiver.recoverLockedTokens(msgId, attacker);
    }

    function test_EstimateFee_ReturnsNonZero() public view {
        ProgrammableTokenSender.TransferPayload memory payload = ProgrammableTokenSender.TransferPayload({
            recipient: bob,
            action: "transfer",
            extraData: "",
            deadline: block.timestamp + 1 hours
        });

        uint256 fee = sender.estimateFee(
            chainSelector,
            address(receiver),
            address(ccipBnM),
            1 ether,
            payload
        );
        assertGt(fee, 0);
    }

    function testFuzz_AnyAmount_SupportedActions(uint256 amount, uint8 actionIndex) public {
        uint256 maxBalance = ccipBnM.balanceOf(alice);
        amount = bound(amount, 1, maxBalance);
        actionIndex = uint8(bound(actionIndex, 0, 3));

        string[4] memory actions = ["transfer", "stake", "swap", "deposit"];
        string memory action = actions[actionIndex];

        bytes32 msgId = _sendTokensWithPayload(alice, address(ccipBnM), amount, bob, action);
        ProgrammableTokenReceiver.ReceivedTransfer memory t = receiver.getTransfer(msgId);

        assertEq(uint8(t.status), uint8(ProgrammableTokenReceiver.TransferStatus.Processed));
        assertEq(t.amount, amount);
    }

    function test_TransferToContract_ExtraArgsConfigurable() public {
        vm.prank(owner);
        sender.updateExtraArgs(
            Client._argsToBytes(
                Client.GenericExtraArgsV2({
                    gasLimit: 800_000,
                    allowOutOfOrderExecution: false
                })
            )
        );

        uint256 amount = ccipBnM.balanceOf(alice);
        bytes32 msgId = _sendTokensWithPayload(alice, address(ccipBnM), amount, bob, "transfer");

        ProgrammableTokenReceiver.ReceivedTransfer memory t = receiver.getTransfer(msgId);
        assertEq(t.messageId, msgId);
        assertEq(ccipBnM.balanceOf(bob), amount);
    }
}
