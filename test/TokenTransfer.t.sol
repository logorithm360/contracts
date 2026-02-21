// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {CCIPLocalSimulator, IRouterClient, LinkToken, BurnMintERC677Helper} from
    "@chainlink/local/ccip/CCIPLocalSimulator.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TokenTransferSender} from "../src/TokenTransferSender.sol";
import {TokenTransferReceiver} from "../src/TokenTransferReceiver.sol";

interface IFeeConfigurableRouter {
    function setFee(uint256 feeAmount) external;
}

/// @notice Unit tests for cross-chain token transfers via CCIPLocalSimulator.
contract TokenTransferTest is Test {
    CCIPLocalSimulator public simulator;
    IRouterClient public sourceRouter;
    IRouterClient public destRouter;
    LinkToken public linkToken;
    BurnMintERC677Helper public ccipBnM;
    uint64 public chainSelector;

    TokenTransferSender public sender;
    TokenTransferReceiver public receiver;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public attacker = makeAddr("attacker");

    uint256 constant LINK_FUND = 10 ether;
    uint256 constant NATIVE_FUND = 5 ether;
    uint256 constant MOCK_FEE = 0.01 ether;

    function setUp() public {
        simulator = new CCIPLocalSimulator();
        (
            uint64 _chainSelector,
            IRouterClient _sourceRouter,
            IRouterClient _destRouter,
            ,
            LinkToken _linkToken,
            BurnMintERC677Helper _ccipBnM,

        ) = simulator.configuration();

        chainSelector = _chainSelector;
        sourceRouter = _sourceRouter;
        destRouter = _destRouter;
        linkToken = _linkToken;
        ccipBnM = _ccipBnM;

        vm.startPrank(owner);
        sender = new TokenTransferSender(address(sourceRouter), address(linkToken), true);
        receiver = new TokenTransferReceiver(address(destRouter));

        sender.allowlistDestinationChain(chainSelector, true);
        sender.allowlistToken(address(ccipBnM), true);
        sender.allowlistToken(address(linkToken), true);

        receiver.allowlistSourceChain(chainSelector, true);
        receiver.allowlistSender(chainSelector, address(sender), true);
        vm.stopPrank();

        simulator.requestLinkFromFaucet(address(sender), LINK_FUND);

        vm.deal(owner, NATIVE_FUND);
        vm.deal(alice, NATIVE_FUND);

        ccipBnM.drip(alice);
        ccipBnM.drip(bob);

        IFeeConfigurableRouter(address(sourceRouter)).setFee(MOCK_FEE);

        vm.label(address(simulator), "CCIPLocalSimulator");
        vm.label(address(sourceRouter), "SourceRouter");
        vm.label(address(destRouter), "DestRouter");
        vm.label(address(linkToken), "LinkToken");
        vm.label(address(ccipBnM), "CCIPBnM");
        vm.label(address(sender), "TokenTransferSender");
        vm.label(address(receiver), "TokenTransferReceiver");
    }

    function _setContractReceiverGasLimit() internal {
        vm.prank(owner);
        sender.updateExtraArgs(
            Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: 300_000, allowOutOfOrderExecution: false})
            )
        );
    }

    function test_TransferToEOA_PayLink_Succeeds() public {
        uint256 amount = ccipBnM.balanceOf(alice);
        uint256 linkBefore = linkToken.balanceOf(address(sender));

        vm.startPrank(alice);
        IERC20(address(ccipBnM)).approve(address(sender), amount);
        bytes32 msgId = sender.transferTokensPayLink(chainSelector, bob, address(ccipBnM), amount);
        vm.stopPrank();

        assertNotEq(msgId, bytes32(0), "messageId should be non-zero");
        assertEq(ccipBnM.balanceOf(alice), 0, "alice should have sent all tokens");
        assertEq(ccipBnM.balanceOf(bob), amount + 1 ether, "bob should receive tokens");

        uint256 linkAfter = linkToken.balanceOf(address(sender));
        assertLt(linkAfter, linkBefore, "LINK should be deducted for fees");
    }

    function test_TransferToContract_Delivered_AndStored() public {
        _setContractReceiverGasLimit();

        uint256 amount = ccipBnM.balanceOf(alice);

        vm.startPrank(alice);
        IERC20(address(ccipBnM)).approve(address(sender), amount);
        bytes32 msgId = sender.transferTokensPayLink(chainSelector, address(receiver), address(ccipBnM), amount);
        vm.stopPrank();

        TokenTransferReceiver.ReceivedTransfer memory t = receiver.getTransfer(msgId);

        assertEq(t.messageId, msgId, "messageId mismatch");
        assertEq(t.sender, address(sender), "sender mismatch");
        assertEq(t.originSender, alice, "origin sender mismatch");
        assertEq(t.token, address(ccipBnM), "token mismatch");
        assertEq(t.amount, amount, "amount mismatch");
        assertEq(t.sourceChainSelector, chainSelector, "source selector mismatch");

        assertEq(receiver.getTokenBalance(address(ccipBnM)), amount, "receiver token balance mismatch");
        assertEq(receiver.totalReceived(address(ccipBnM)), amount, "totalReceived mismatch");
        assertEq(receiver.getTransferCount(), 1, "transfer count mismatch");
    }

    function test_TransferPayNative_Succeeds() public {
        vm.prank(owner);
        sender.setPayFeesInLink(false);

        uint256 amount = ccipBnM.balanceOf(alice);
        uint256 fee = sender.estimateFee(chainSelector, bob, address(ccipBnM), amount);

        vm.startPrank(alice);
        IERC20(address(ccipBnM)).approve(address(sender), amount);
        bytes32 msgId = sender.transferTokensPayNative{value: fee + 1}(chainSelector, bob, address(ccipBnM), amount);
        vm.stopPrank();

        assertNotEq(msgId, bytes32(0), "messageId should be non-zero");
        assertEq(ccipBnM.balanceOf(alice), 0, "alice should have sent all tokens");
    }

    function test_GetLastReceivedTransfer_ReturnsLatest() public {
        _setContractReceiverGasLimit();

        uint256 aliceAmount = ccipBnM.balanceOf(alice);
        uint256 bobAmount = ccipBnM.balanceOf(bob);

        vm.startPrank(alice);
        IERC20(address(ccipBnM)).approve(address(sender), aliceAmount);
        bytes32 id1 = sender.transferTokensPayLink(
            chainSelector,
            address(receiver),
            address(ccipBnM),
            aliceAmount
        );
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(address(ccipBnM)).approve(address(sender), bobAmount);
        bytes32 id2 = sender.transferTokensPayLink(
            chainSelector,
            address(receiver),
            address(ccipBnM),
            bobAmount
        );
        vm.stopPrank();

        TokenTransferReceiver.ReceivedTransfer memory first = receiver.getTransfer(id1);
        TokenTransferReceiver.ReceivedTransfer memory last = receiver.getLastReceivedTransfer();

        assertEq(first.amount, aliceAmount, "first amount mismatch");
        assertEq(first.originSender, alice, "first origin sender mismatch");
        assertEq(last.messageId, id2, "latest message id mismatch");
        assertEq(last.amount, bobAmount, "latest amount mismatch");
        assertEq(last.originSender, bob, "latest origin sender mismatch");
        assertEq(receiver.getTransferCount(), 2, "transfer count mismatch");
    }

    function test_EstimateFee_ReturnsNonZero() public view {
        uint256 amount = 1 ether;
        uint256 fee = sender.estimateFee(chainSelector, bob, address(ccipBnM), amount);
        assertGt(fee, 0, "fee should be non-zero");
    }

    function test_RevertWhen_DestChainNotAllowlisted() public {
        uint64 unknownChain = 9999;
        uint256 amount = ccipBnM.balanceOf(alice);

        vm.startPrank(alice);
        IERC20(address(ccipBnM)).approve(address(sender), amount);

        vm.expectRevert(
            abi.encodeWithSelector(TokenTransferSender.DestinationChainNotAllowlisted.selector, unknownChain)
        );
        sender.transferTokensPayLink(unknownChain, bob, address(ccipBnM), amount);
        vm.stopPrank();
    }

    function test_RevertWhen_TokenNotAllowlisted() public {
        address randomToken = makeAddr("randomToken");

        vm.expectRevert(
            abi.encodeWithSelector(TokenTransferSender.TokenNotAllowlisted.selector, randomToken)
        );
        vm.prank(alice);
        sender.transferTokensPayLink(chainSelector, bob, randomToken, 1 ether);
    }

    function test_RevertWhen_ZeroAmount() public {
        vm.expectRevert(TokenTransferSender.ZeroAmount.selector);
        vm.prank(alice);
        sender.transferTokensPayLink(chainSelector, bob, address(ccipBnM), 0);
    }

    function test_RevertWhen_ZeroReceiver() public {
        vm.expectRevert(TokenTransferSender.ZeroAddress.selector);
        vm.prank(alice);
        sender.transferTokensPayLink(chainSelector, address(0), address(ccipBnM), 1 ether);
    }

    function test_RevertWhen_InsufficientLink() public {
        vm.prank(owner);
        sender.withdrawLink(owner);

        uint256 amount = ccipBnM.balanceOf(alice);
        uint256 fee = sender.estimateFee(chainSelector, bob, address(ccipBnM), amount);

        vm.startPrank(alice);
        IERC20(address(ccipBnM)).approve(address(sender), amount);

        vm.expectRevert(
            abi.encodeWithSelector(TokenTransferSender.InsufficientLinkBalance.selector, 0, fee)
        );
        sender.transferTokensPayLink(chainSelector, bob, address(ccipBnM), amount);
        vm.stopPrank();
    }

    function test_RevertWhen_InsufficientNative() public {
        vm.prank(owner);
        sender.setPayFeesInLink(false);

        uint256 amount = ccipBnM.balanceOf(alice);

        vm.startPrank(alice);
        IERC20(address(ccipBnM)).approve(address(sender), amount);

        vm.expectRevert(
            abi.encodeWithSelector(TokenTransferSender.InsufficientNativeBalance.selector, 0, MOCK_FEE)
        );
        sender.transferTokensPayNative{value: 0}(chainSelector, bob, address(ccipBnM), amount);
        vm.stopPrank();
    }

    function test_RevertWhen_SourceChainNotAllowlisted_OnReceiver() public {
        _setContractReceiverGasLimit();

        vm.prank(owner);
        receiver.allowlistSourceChain(chainSelector, false);

        uint256 amount = ccipBnM.balanceOf(alice);

        vm.startPrank(alice);
        IERC20(address(ccipBnM)).approve(address(sender), amount);
        vm.expectRevert();
        sender.transferTokensPayLink(chainSelector, address(receiver), address(ccipBnM), amount);
        vm.stopPrank();
    }

    function test_RevertWhen_SenderNotAllowlisted_OnReceiver() public {
        _setContractReceiverGasLimit();

        vm.prank(owner);
        receiver.allowlistSender(chainSelector, address(sender), false);

        uint256 amount = ccipBnM.balanceOf(alice);

        vm.startPrank(alice);
        IERC20(address(ccipBnM)).approve(address(sender), amount);
        vm.expectRevert();
        sender.transferTokensPayLink(chainSelector, address(receiver), address(ccipBnM), amount);
        vm.stopPrank();
    }

    function test_RevertWhen_SenderAllowlistedOnDifferentChainOnly() public {
        _setContractReceiverGasLimit();

        uint64 otherChain = 3478487238524512106;

        vm.startPrank(owner);
        receiver.allowlistSender(chainSelector, address(sender), false);
        receiver.allowlistSender(otherChain, address(sender), true);
        vm.stopPrank();

        uint256 amount = ccipBnM.balanceOf(alice);

        vm.startPrank(alice);
        IERC20(address(ccipBnM)).approve(address(sender), amount);
        vm.expectRevert();
        sender.transferTokensPayLink(chainSelector, address(receiver), address(ccipBnM), amount);
        vm.stopPrank();
    }

    function test_RevertWhen_AttackerCallsAllowlist() public {
        vm.expectRevert();
        vm.prank(attacker);
        sender.allowlistDestinationChain(chainSelector, false);
    }

    function test_WithdrawLink_Succeeds() public {
        uint256 bal = linkToken.balanceOf(address(sender));
        assertGt(bal, 0, "sender should have LINK");

        vm.prank(owner);
        sender.withdrawLink(owner);

        assertEq(linkToken.balanceOf(address(sender)), 0, "sender LINK should be zero");
        assertEq(linkToken.balanceOf(owner), bal, "owner should receive LINK");
    }

    function test_WithdrawReceivedTokenFromReceiver_Succeeds() public {
        _setContractReceiverGasLimit();

        uint256 amount = ccipBnM.balanceOf(alice);

        vm.startPrank(alice);
        IERC20(address(ccipBnM)).approve(address(sender), amount);
        sender.transferTokensPayLink(chainSelector, address(receiver), address(ccipBnM), amount);
        vm.stopPrank();

        uint256 ownerBefore = ccipBnM.balanceOf(owner);

        vm.prank(owner);
        receiver.withdrawToken(address(ccipBnM), owner);

        assertEq(receiver.getTokenBalance(address(ccipBnM)), 0, "receiver token balance should be zero");
        assertEq(ccipBnM.balanceOf(owner), ownerBefore + amount, "owner should receive withdrawn tokens");
    }
}
