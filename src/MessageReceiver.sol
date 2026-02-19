// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title  MessagingReceiver
/// @notice Production-grade CCIP receiver contract using the defensive pattern.
///         Reception (Phase 1) is fully decoupled from business logic (Phase 2).
///         If business logic reverts, the message is stored and manually retryable.
///         Deployed on the DESTINATION chain.
/// @dev    Override _ccipReceive (internal), NEVER ccipReceive (external).
///         The base CCIPReceiver enforces onlyRouter via ccipReceive.
contract MessagingReceiver is CCIPReceiver, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────
    //  Custom errors
    // ─────────────────────────────────────────────────────────────
    error ZeroAddress();
    error SourceChainNotAllowlisted(uint64 sourceChainSelector);
    error SenderNotAllowlisted(uint64 sourceChainSelector, address sender);
    error MessageNotFound(bytes32 messageId);
    error UnauthorizedCaller(address caller);
    error NothingToWithdraw();

    // ─────────────────────────────────────────────────────────────
    //  Structs & enums
    // ─────────────────────────────────────────────────────────────

    enum MessageStatus { Unknown, Received, Processed, Failed }

    struct ReceivedMessage {
        bytes32       messageId;
        uint64        sourceChainSelector;
        address       sender;
        string        text;
        uint256       receivedAt;
        MessageStatus status;
    }

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────
    event MessageReceived(
        bytes32 indexed messageId,
        uint64  indexed sourceChainSelector,
        address indexed sender,
        string          text
    );
    event MessageProcessed(bytes32 indexed messageId);
    event MessageProcessingFailed(bytes32 indexed messageId, bytes reason);
    event MessageRetryRequested(bytes32 indexed messageId, address indexed caller);
    event MessageRetryCompleted(bytes32 indexed messageId, bool success, bytes reason);
    event SourceChainAllowlisted(uint64 indexed chainSelector, bool allowed);
    event SenderAllowlisted(uint64 indexed sourceChainSelector, address indexed sender, bool allowed);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────

    /// @notice Source chains the owner has approved.
    mapping(uint64  => bool) public allowlistedSourceChains;

    /// @notice Sender addresses the owner has approved, keyed by source chain.
    mapping(uint64 => mapping(address => bool)) public allowlistedSendersByChain;

    /// @notice All received messages indexed by CCIP messageId.
    mapping(bytes32 => ReceivedMessage) public receivedMessages;

    /// @notice Ordered list of all received messageIds for enumeration.
    bytes32[] public messageIds;

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────

    /// @param _router  CCIP router address on the destination chain.
    constructor(address _router)
        CCIPReceiver(_router)
        Ownable(msg.sender)
    {
        if (_router == address(0)) revert ZeroAddress();
    }

    // ─────────────────────────────────────────────────────────────
    //  Modifiers
    // ─────────────────────────────────────────────────────────────

    modifier onlyAllowlistedSource(uint64 _chainSelector) {
        _onlyAllowlistedSource(_chainSelector);
        _;
    }

    modifier onlyAllowlistedSender(uint64 _sourceChainSelector, address _sender) {
        _onlyAllowlistedSender(_sourceChainSelector, _sender);
        _;
    }

    modifier onlySelf() {
        _onlySelf();
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

    function _onlySelf() internal view {
        if (msg.sender != address(this)) {
            revert UnauthorizedCaller(msg.sender);
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  Core CCIP receive — DEFENSIVE PATTERN
    // ─────────────────────────────────────────────────────────────

    /// @dev Called by the CCIP router (enforced by base class onlyRouter).
    ///      NEVER override ccipReceive (external) — only this internal function.
    ///
    ///      PHASE 1: Unconditionally store the raw message (cannot fail).
    ///      PHASE 2: Run business logic in try/catch.  If it reverts, the
    ///               message remains stored as Failed and can be retried.
    function _ccipReceive(Client.Any2EVMMessage memory message)
        internal
        override
        onlyAllowlistedSource(message.sourceChainSelector)
        onlyAllowlistedSender(message.sourceChainSelector, abi.decode(message.sender, (address)))
    {
        bytes32 msgId  = message.messageId;
        address sender = abi.decode(message.sender, (address));
        string  memory text = abi.decode(message.data, (string));

        // ── PHASE 1: Store (always succeeds) ─────────────────────
        receivedMessages[msgId] = ReceivedMessage({
            messageId:           msgId,
            sourceChainSelector: message.sourceChainSelector,
            sender:              sender,
            text:                text,
            receivedAt:          block.timestamp,
            status:              MessageStatus.Received
        });
        messageIds.push(msgId);

        emit MessageReceived(msgId, message.sourceChainSelector, sender, text);

        // ── PHASE 2: Business logic (may fail safely) ─────────────
        try this.processMessage(msgId) {
            // success path — status updated inside processMessage
        } catch (bytes memory reason) {
            receivedMessages[msgId].status = MessageStatus.Failed;
            emit MessageProcessingFailed(msgId, reason);
            // Do NOT revert — message is stored, owner can retry
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  Business logic — externally retryable
    // ─────────────────────────────────────────────────────────────

    /// @notice Executes business logic for a stored message.
    ///         Callable by this contract (via try/catch) or the owner (manual retry).
    /// @dev    MUST be external for try/catch to work.
    ///         Protected by onlySelf + owner check — not callable by arbitrary addresses.
    function processMessage(bytes32 _messageId)
        external
        nonReentrant
    {
        if (msg.sender != address(this) && msg.sender != owner())
            revert UnauthorizedCaller(msg.sender);

        ReceivedMessage storage msg_ = receivedMessages[_messageId];
        if (msg_.messageId == bytes32(0)) revert MessageNotFound(_messageId);

        // ── Your application logic goes here ──────────────────────
        // Example: log the text. Replace with your actual on-chain action.
        // e.g. update a state variable, trigger a DeFi action, etc.
        // string memory text = msg_.text;
        // myProtocol.handleCrossChainInstruction(text);
        // ─────────────────────────────────────────────────────────

        msg_.status = MessageStatus.Processed;
        emit MessageProcessed(_messageId);
    }

    /// @notice Owner-triggered reprocessing entrypoint for CRE workflows.
    ///         Emits deterministic retry lifecycle events.
    function retryMessage(bytes32 _messageId) external onlyOwner {
        if (receivedMessages[_messageId].messageId == bytes32(0)) {
            revert MessageNotFound(_messageId);
        }

        emit MessageRetryRequested(_messageId, msg.sender);

        try this.processMessage(_messageId) {
            emit MessageRetryCompleted(_messageId, true, "");
        } catch (bytes memory reason) {
            receivedMessages[_messageId].status = MessageStatus.Failed;
            emit MessageRetryCompleted(_messageId, false, reason);
            emit MessageProcessingFailed(_messageId, reason);
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  View helpers
    // ─────────────────────────────────────────────────────────────

    /// @notice Returns full details of a received message.
    function getMessage(bytes32 _messageId)
        external view
        returns (ReceivedMessage memory)
    {
        return receivedMessages[_messageId];
    }

    /// @notice Returns the details of the most recently received message.
    function getLastReceivedMessage()
        external view
        returns (ReceivedMessage memory)
    {
        require(messageIds.length > 0, "No messages received");
        return receivedMessages[messageIds[messageIds.length - 1]];
    }

    /// @notice Total number of messages ever received.
    function getMessageCount() external view returns (uint256) {
        return messageIds.length;
    }

    /// @notice Returns the router address this contract listens to.
    function getRouter() public view virtual override returns (address) {
        return address(i_ccipRouter);
    }

    // ─────────────────────────────────────────────────────────────
    //  Admin functions
    // ─────────────────────────────────────────────────────────────

    /// @notice Allow or block a source chain selector.
    function allowlistSourceChain(uint64 _chainSelector, bool _allowed)
        external onlyOwner
    {
        allowlistedSourceChains[_chainSelector] = _allowed;
        emit SourceChainAllowlisted(_chainSelector, _allowed);
    }

    /// @notice Allow or block a sender address.
    function allowlistSender(uint64 _sourceChainSelector, address _sender, bool _allowed)
        external onlyOwner
    {
        if (_sender == address(0)) revert ZeroAddress();
        allowlistedSendersByChain[_sourceChainSelector][_sender] = _allowed;
        emit SenderAllowlisted(_sourceChainSelector, _sender, _allowed);
    }

    /// @notice Emergency: rescue any ERC20 token sent to this contract by mistake.
    function rescueToken(address _token, address _to, uint256 _amount)
        external onlyOwner
    {
        if (_to == address(0)) revert ZeroAddress();
        IERC20(_token).safeTransfer(_to, _amount);
        emit TokenRescued(_token, _to, _amount);
    }
}
