// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CCIPReceiver} from "@chainlink/contracts-ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/libraries/Client.sol";
import {IERC20} from "@chainlink/contracts-ccip/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title  TokenTransferReceiver
/// @notice Feature 2 — Receives CCIP token transfers on the destination chain.
///         This contract is OPTIONAL — token-only CCIP transfers can go directly
///         to any EOA wallet. You only need this contract if you want on-chain
///         logic to run when tokens arrive (e.g. auto-stake, auto-swap, bookkeeping).
///
///         Deployed on the DESTINATION chain (Polygon Amoy).
///
/// @dev    For token-only transfers the `data` field in Any2EVMMessage is empty.
///         Tokens arrive in this contract's balance automatically by the CCIP router
///         before _ccipReceive is called — they do NOT need to be manually claimed.
///
///         CRITICAL: The sender contract must set gasLimit > 0 in extraArgs
///         when the receiver is a smart contract (not an EOA). gasLimit = 0
///         means no ccipReceive() call is made, so this contract would never
///         be triggered. Default is 200_000 for this receiver pattern.
contract TokenTransferReceiver is CCIPReceiver, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────
    //  Custom errors
    // ─────────────────────────────────────────────────────────────
    error ZeroAddress();
    error SourceChainNotAllowlisted(uint64 sourceChainSelector);
    error SenderNotAllowlisted(address sender);
    error NothingToWithdraw();
    error TransferFailed();

    // ─────────────────────────────────────────────────────────────
    //  Structs
    // ─────────────────────────────────────────────────────────────

    struct ReceivedTransfer {
        bytes32 messageId;
        uint64  sourceChainSelector;
        address sender;
        address token;
        uint256 amount;
        uint256 receivedAt;
    }

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────
    event TokensReceived(
        bytes32 indexed messageId,
        uint64  indexed sourceChainSelector,
        address indexed sender,
        address         token,
        uint256         amount
    );
    event SourceChainAllowlisted(uint64 indexed chainSelector, bool allowed);
    event SenderAllowlisted(address indexed sender, bool allowed);

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────

    mapping(uint64  => bool) public allowlistedSourceChains;
    mapping(address => bool) public allowlistedSenders;

    /// @notice Full history of every received token transfer.
    mapping(bytes32 => ReceivedTransfer) public receivedTransfers;
    bytes32[] public transferIds;

    /// @notice Tracks cumulative tokens received per token address.
    mapping(address => uint256) public totalReceived;

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────

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
        if (!allowlistedSourceChains[_chainSelector])
            revert SourceChainNotAllowlisted(_chainSelector);
        _;
    }

    modifier onlyAllowlistedSender(address _sender) {
        if (!allowlistedSenders[_sender])
            revert SenderNotAllowlisted(_sender);
        _;
    }

    // ─────────────────────────────────────────────────────────────
    //  CCIP receive — override internal function ONLY
    // ─────────────────────────────────────────────────────────────

    /// @dev Called by the CCIP router after tokens have been credited to
    ///      this contract's balance. By the time this function runs, the
    ///      tokens are already here — no manual claim needed.
    ///
    ///      Override _ccipReceive (internal), NEVER ccipReceive (external).
    ///      The base class enforces onlyRouter via ccipReceive.
    function _ccipReceive(Client.Any2EVMMessage memory message)
        internal
        override
        onlyAllowlistedSource(message.sourceChainSelector)
        onlyAllowlistedSender(abi.decode(message.sender, (address)))
    {
        // Extract the first token transfer from the message
        // For Feature 2 there will always be exactly 1 token
        address token  = message.tokenAmounts[0].token;
        uint256 amount = message.tokenAmounts[0].amount;
        address sender = abi.decode(message.sender, (address));

        // Record the transfer
        bytes32 msgId = message.messageId;
        receivedTransfers[msgId] = ReceivedTransfer({
            messageId:           msgId,
            sourceChainSelector: message.sourceChainSelector,
            sender:              sender,
            token:               token,
            amount:              amount,
            receivedAt:          block.timestamp
        });
        transferIds.push(msgId);

        // Update cumulative tracker
        totalReceived[token] += amount;

        emit TokensReceived(msgId, message.sourceChainSelector, sender, token, amount);

        // ── Application logic goes here ───────────────────────
        // Tokens are already in this contract's balance.
        // Examples of what you can do:
        //   IERC20(token).safeTransfer(beneficiary, amount);    // forward to a user
        //   IStaking(stakingPool).stake(token, amount);         // auto-stake
        //   ISwap(dex).swap(token, outputToken, amount);        // auto-swap
        // ─────────────────────────────────────────────────────
    }

    // ─────────────────────────────────────────────────────────────
    //  View helpers
    // ─────────────────────────────────────────────────────────────

    /// @notice Returns full details of a received token transfer.
    function getTransfer(bytes32 _messageId)
        external view
        returns (ReceivedTransfer memory)
    {
        return receivedTransfers[_messageId];
    }

    /// @notice Returns the most recently received transfer.
    function getLastReceivedTransfer()
        external view
        returns (ReceivedTransfer memory)
    {
        require(transferIds.length > 0, "No transfers received");
        return receivedTransfers[transferIds[transferIds.length - 1]];
    }

    /// @notice Returns the number of transfers ever received.
    function getTransferCount() external view returns (uint256) {
        return transferIds.length;
    }

    /// @notice Returns this contract's current balance of a token.
    function getTokenBalance(address _token) external view returns (uint256) {
        return IERC20(_token).balanceOf(address(this));
    }

    function getRouter() external view returns (address) {
        return address(i_ccipRouter);
    }

    // ─────────────────────────────────────────────────────────────
    //  Admin functions
    // ─────────────────────────────────────────────────────────────

    function allowlistSourceChain(uint64 _chainSelector, bool _allowed)
        external onlyOwner
    {
        allowlistedSourceChains[_chainSelector] = _allowed;
        emit SourceChainAllowlisted(_chainSelector, _allowed);
    }

    function allowlistSender(address _sender, bool _allowed)
        external onlyOwner
    {
        if (_sender == address(0)) revert ZeroAddress();
        allowlistedSenders[_sender] = _allowed;
        emit SenderAllowlisted(_sender, _allowed);
    }

    /// @notice Emergency: withdraw any token from this contract.
    function withdrawToken(address _token, address _to)
        external onlyOwner nonReentrant
    {
        if (_to    == address(0)) revert ZeroAddress();
        if (_token == address(0)) revert ZeroAddress();
        uint256 bal = IERC20(_token).balanceOf(address(this));
        if (bal == 0) revert NothingToWithdraw();
        IERC20(_token).safeTransfer(_to, bal);
    }
}
