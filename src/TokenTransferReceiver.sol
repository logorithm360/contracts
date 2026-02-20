// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TokenTransferReceiver
/// @notice Receives and records CCIP token transfers on destination chain.
contract TokenTransferReceiver is CCIPReceiver, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error SourceChainNotAllowlisted(uint64 sourceChainSelector);
    error SenderNotAllowlisted(uint64 sourceChainSelector, address sender);
    error NoTokensTransferred();
    error NothingToWithdraw();

    struct ReceivedTransfer {
        bytes32 messageId;
        uint64 sourceChainSelector;
        address sender;
        address originSender;
        address token;
        uint256 amount;
        uint256 receivedAt;
    }

    event TokensReceived(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address indexed sender,
        address originSender,
        address token,
        uint256 amount,
        uint256 runningTokenTotal,
        uint256 transferCount
    );
    event SourceChainAllowlisted(uint64 indexed chainSelector, bool allowed);
    event SenderAllowlisted(uint64 indexed sourceChainSelector, address indexed sender, bool allowed);
    event TokenWithdrawn(address indexed token, address indexed to, uint256 amount);

    mapping(uint64 => bool) public allowlistedSourceChains;
    mapping(uint64 => mapping(address => bool)) public allowlistedSendersByChain;

    mapping(bytes32 => ReceivedTransfer) public receivedTransfers;
    bytes32[] public transferIds;
    mapping(address => uint256) public totalReceived;

    constructor(address _router) CCIPReceiver(_router) Ownable(msg.sender) {
        if (_router == address(0)) revert ZeroAddress();
    }

    modifier onlyAllowlistedSource(uint64 _chainSelector) {
        _onlyAllowlistedSource(_chainSelector);
        _;
    }

    modifier onlyAllowlistedSender(uint64 _sourceChainSelector, address _sender) {
        _onlyAllowlistedSender(_sourceChainSelector, _sender);
        _;
    }

    function _onlyAllowlistedSource(uint64 _chainSelector) internal view {
        if (!allowlistedSourceChains[_chainSelector]) {
            revert SourceChainNotAllowlisted(_chainSelector);
        }
    }

    function _onlyAllowlistedSender(uint64 _sourceChainSelector, address _sender) internal view {
        if (!allowlistedSendersByChain[_sourceChainSelector][_sender]) {
            revert SenderNotAllowlisted(_sourceChainSelector, _sender);
        }
    }

    function _ccipReceive(Client.Any2EVMMessage memory message)
        internal
        override
        onlyAllowlistedSource(message.sourceChainSelector)
        onlyAllowlistedSender(message.sourceChainSelector, abi.decode(message.sender, (address)))
    {
        if (message.destTokenAmounts.length == 0) revert NoTokensTransferred();

        address token = message.destTokenAmounts[0].token;
        uint256 amount = message.destTokenAmounts[0].amount;
        address sender = abi.decode(message.sender, (address));
        address originSender = message.data.length == 0
            ? address(0)
            : abi.decode(message.data, (address));
        bytes32 msgId = message.messageId;

        receivedTransfers[msgId] = ReceivedTransfer({
            messageId: msgId,
            sourceChainSelector: message.sourceChainSelector,
            sender: sender,
            originSender: originSender,
            token: token,
            amount: amount,
            receivedAt: block.timestamp
        });
        transferIds.push(msgId);
        totalReceived[token] += amount;

        emit TokensReceived(
            msgId,
            message.sourceChainSelector,
            sender,
            originSender,
            token,
            amount,
            totalReceived[token],
            transferIds.length
        );
    }

    function getTransfer(bytes32 _messageId) external view returns (ReceivedTransfer memory) {
        return receivedTransfers[_messageId];
    }

    function getLastReceivedTransfer() external view returns (ReceivedTransfer memory) {
        require(transferIds.length > 0, "No transfers received");
        return receivedTransfers[transferIds[transferIds.length - 1]];
    }

    function getTransferCount() external view returns (uint256) {
        return transferIds.length;
    }

    function getTokenBalance(address _token) external view returns (uint256) {
        return IERC20(_token).balanceOf(address(this));
    }

    function getRouter() public view virtual override returns (address) {
        return address(i_ccipRouter);
    }

    function allowlistSourceChain(uint64 _chainSelector, bool _allowed) external onlyOwner {
        allowlistedSourceChains[_chainSelector] = _allowed;
        emit SourceChainAllowlisted(_chainSelector, _allowed);
    }

    function allowlistSender(uint64 _sourceChainSelector, address _sender, bool _allowed) external onlyOwner {
        if (_sender == address(0)) revert ZeroAddress();
        allowlistedSendersByChain[_sourceChainSelector][_sender] = _allowed;
        emit SenderAllowlisted(_sourceChainSelector, _sender, _allowed);
    }

    function withdrawToken(address _token, address _to) external onlyOwner nonReentrant {
        if (_token == address(0) || _to == address(0)) revert ZeroAddress();
        uint256 bal = IERC20(_token).balanceOf(address(this));
        if (bal == 0) revert NothingToWithdraw();
        IERC20(_token).safeTransfer(_to, bal);
        emit TokenWithdrawn(_token, _to, bal);
    }
}
