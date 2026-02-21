// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ProgrammableTokenReceiver
/// @notice Receives programmable CCIP token transfers and processes payload actions.
contract ProgrammableTokenReceiver is CCIPReceiver, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error SourceChainNotAllowlisted(uint64 sourceChainSelector);
    error SenderNotAllowlisted(uint64 sourceChainSelector, address sender);
    error TransferNotFound(bytes32 messageId);
    error UnauthorizedCaller(address caller);
    error DeadlineExpired(uint256 deadline, uint256 currentTime);
    error UnsupportedAction(string action);
    error NothingToWithdraw();
    error NoTokensTransferred();

    struct TransferPayload {
        address recipient;
        string action;
        bytes extraData;
        uint256 deadline;
    }

    enum TransferStatus {
        Unknown,
        Received,
        Processed,
        Failed,
        Recovered
    }

    struct ReceivedTransfer {
        bytes32 messageId;
        uint64 sourceChainSelector;
        address senderContract;
        address originSender;
        address token;
        uint256 amount;
        TransferPayload payload;
        uint256 receivedAt;
        TransferStatus status;
    }

    event TransferReceived(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address indexed senderContract,
        address originSender,
        address token,
        uint256 amount,
        address recipient,
        string action
    );
    event TransferProcessed(bytes32 indexed messageId, string action, address recipient, uint256 amount);
    event TransferFailed(bytes32 indexed messageId, bytes reason);
    event TransferRecovered(bytes32 indexed messageId, address to, uint256 amount);
    event SourceChainAllowlisted(uint64 indexed chainSelector, bool allowed);
    event SenderAllowlisted(uint64 indexed sourceChainSelector, address indexed sender, bool allowed);
    event TokenWithdrawn(address indexed token, address indexed to, uint256 amount);

    mapping(uint64 => bool) public allowlistedSourceChains;
    mapping(uint64 => mapping(address => bool)) public allowlistedSendersByChain;

    mapping(bytes32 => ReceivedTransfer) public receivedTransfers;
    bytes32[] public transferIds;

    mapping(address => uint256) public totalReceived;
    mapping(address => uint256) public totalProcessed;

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

        bytes32 msgId = message.messageId;
        address senderContract = abi.decode(message.sender, (address));
        (TransferPayload memory payload, address originSender) = abi.decode(message.data, (TransferPayload, address));

        address token = message.destTokenAmounts[0].token;
        uint256 amount = message.destTokenAmounts[0].amount;

        receivedTransfers[msgId] = ReceivedTransfer({
            messageId: msgId,
            sourceChainSelector: message.sourceChainSelector,
            senderContract: senderContract,
            originSender: originSender,
            token: token,
            amount: amount,
            payload: payload,
            receivedAt: block.timestamp,
            status: TransferStatus.Received
        });
        transferIds.push(msgId);
        totalReceived[token] += amount;

        emit TransferReceived(
            msgId,
            message.sourceChainSelector,
            senderContract,
            originSender,
            token,
            amount,
            payload.recipient,
            payload.action
        );

        try this.processTransfer(msgId) {
        // no-op
        }
        catch (bytes memory reason) {
            receivedTransfers[msgId].status = TransferStatus.Failed;
            emit TransferFailed(msgId, reason);
        }
    }

    function processTransfer(bytes32 _messageId) external nonReentrant {
        if (msg.sender != address(this) && msg.sender != owner()) {
            revert UnauthorizedCaller(msg.sender);
        }

        ReceivedTransfer storage t = receivedTransfers[_messageId];
        if (t.messageId == bytes32(0)) revert TransferNotFound(_messageId);

        if (t.payload.deadline > 0 && block.timestamp > t.payload.deadline) {
            revert DeadlineExpired(t.payload.deadline, block.timestamp);
        }

        string memory action = t.payload.action;
        address recipient = t.payload.recipient;
        address token = t.token;
        uint256 amount = t.amount;

        if (
            _strEq(action, "transfer") || _strEq(action, "stake") || _strEq(action, "swap") || _strEq(action, "deposit")
        ) {
            // Phase 1 implementation forwards tokens directly.
            // Protocol-specific integrations can replace this branch with action handlers.
            IERC20(token).safeTransfer(recipient, amount);
        } else {
            revert UnsupportedAction(action);
        }

        t.status = TransferStatus.Processed;
        totalProcessed[token] += amount;

        emit TransferProcessed(_messageId, action, recipient, amount);
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

    function recoverLockedTokens(bytes32 _messageId, address _to) external onlyOwner nonReentrant {
        if (_to == address(0)) revert ZeroAddress();
        ReceivedTransfer storage t = receivedTransfers[_messageId];
        if (t.messageId == bytes32(0)) revert TransferNotFound(_messageId);

        address token = t.token;
        uint256 amount = t.amount;

        t.status = TransferStatus.Recovered;
        IERC20(token).safeTransfer(_to, amount);

        emit TransferRecovered(_messageId, _to, amount);
    }

    function withdrawToken(address _token, address _to) external onlyOwner nonReentrant {
        if (_token == address(0) || _to == address(0)) revert ZeroAddress();
        uint256 bal = IERC20(_token).balanceOf(address(this));
        if (bal == 0) revert NothingToWithdraw();

        IERC20(_token).safeTransfer(_to, bal);
        emit TokenWithdrawn(_token, _to, bal);
    }

    function _strEq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
