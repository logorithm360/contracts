// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRouterClient} from "@chainlink/contracts-ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/libraries/Client.sol";
import {IERC20} from "@chainlink/contracts-ccip/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title  TokenTransferSender
/// @notice Feature 2 — Transfer/Receive Tokens.
///         Sends CCIP-supported ERC20 tokens cross-chain to an EOA or contract.
///         Supports paying CCIP fees in LINK or in native gas.
///         Deployed on the SOURCE chain (Ethereum Sepolia).
///
/// @dev    Key difference from Feature 1 (messaging):
///         - tokenAmounts array is populated with token + amount
///         - data field is empty bytes (no payload — tokens only)
///         - gasLimit is set to 0 for EOA receivers (no ccipReceive to call)
///         - gasLimit is set to >0 only when receiver is a smart contract
///         - The transferred token must be APPROVED to this contract before calling
contract TokenTransferSender is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────
    //  Custom errors
    // ─────────────────────────────────────────────────────────────
    error ZeroAddress();
    error ZeroAmount();
    error NothingToWithdraw();
    error WithdrawFailed();
    error DestinationChainNotAllowlisted(uint64 chainSelector);
    error TokenNotAllowlisted(address token);
    error InsufficientLinkBalance(uint256 have, uint256 need);
    error InsufficientNativeBalance(uint256 sent, uint256 need);
    error InsufficientTokenAllowance(uint256 have, uint256 need);
    error RefundFailed();

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────
    event TokensTransferred(
        bytes32 indexed messageId,
        uint64  indexed destinationChainSelector,
        address indexed receiver,
        address         token,
        uint256         tokenAmount,
        address         feeToken,
        uint256         fees
    );
    event DestinationChainAllowlisted(uint64 indexed chainSelector, bool allowed);
    event TokenAllowlisted(address indexed token, bool allowed);
    event ExtraArgsUpdated(bytes extraArgs);
    event FeeConfigUpdated(bool payInLink);

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────

    IRouterClient private immutable i_router;
    IERC20        private immutable i_linkToken;

    /// @notice Approved destination chain selectors.
    mapping(uint64  => bool) public allowlistedDestinationChains;

    /// @notice Approved tokens for cross-chain transfer.
    /// Only CCIP-supported tokens can be transferred — others will revert at the router.
    /// This allowlist is a first line of defense to catch user errors early.
    mapping(address => bool) public allowlistedTokens;

    /// @notice Mutable extraArgs — never hardcoded for CCIP upgrade compatibility.
    bytes public extraArgs;

    /// @notice If true, fees paid in LINK; if false, paid in native gas.
    bool public payFeesInLink;

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────

    /// @param _router        CCIP router on the source chain.
    /// @param _linkToken     LINK token on the source chain.
    /// @param _payFeesInLink True = LINK fees, false = native gas fees.
    constructor(
        address _router,
        address _linkToken,
        bool    _payFeesInLink
    ) Ownable(msg.sender) {
        if (_router    == address(0)) revert ZeroAddress();
        if (_linkToken == address(0)) revert ZeroAddress();

        i_router      = IRouterClient(_router);
        i_linkToken   = IERC20(_linkToken);
        payFeesInLink = _payFeesInLink;

        // gasLimit = 0 because for token-only transfers to EOAs there is no
        // ccipReceive() to execute on the destination side.
        // If you are sending tokens to a SMART CONTRACT receiver, update
        // extraArgs via updateExtraArgs() to set gasLimit > 0.
        extraArgs = Client._argsToBytes(
            Client.GenericExtraArgsV2({
                gasLimit: 0,
                allowOutOfOrderExecution: false
            })
        );
    }

    // ─────────────────────────────────────────────────────────────
    //  Modifiers
    // ─────────────────────────────────────────────────────────────

    modifier onlyAllowlistedDestination(uint64 _chainSelector) {
        if (!allowlistedDestinationChains[_chainSelector])
            revert DestinationChainNotAllowlisted(_chainSelector);
        _;
    }

    modifier onlyAllowlistedToken(address _token) {
        if (!allowlistedTokens[_token])
            revert TokenNotAllowlisted(_token);
        _;
    }

    // ─────────────────────────────────────────────────────────────
    //  Core transfer functions
    // ─────────────────────────────────────────────────────────────

    /// @notice Transfers ERC20 tokens cross-chain, paying CCIP fees in LINK.
    /// @dev    Caller must approve this contract to spend `_amount` of `_token`
    ///         before calling. The contract pulls the tokens from the caller,
    ///         approves them to the router, then sends.
    /// @param  _destinationChainSelector  CCIP selector of the destination chain.
    /// @param  _receiver                  Recipient address on the destination chain.
    ///                                    Can be an EOA or a smart contract.
    /// @param  _token                     Token contract address on the source chain.
    /// @param  _amount                    Amount of tokens to transfer (in token decimals).
    /// @return messageId                  CCIP message ID for tracking.
    function transferTokensPayLINK(
        uint64  _destinationChainSelector,
        address _receiver,
        address _token,
        uint256 _amount
    )
        external
        nonReentrant
        onlyAllowlistedDestination(_destinationChainSelector)
        onlyAllowlistedToken(_token)
        returns (bytes32 messageId)
    {
        if (_receiver == address(0)) revert ZeroAddress();
        if (_amount   == 0)          revert ZeroAmount();

        // Pull tokens from caller into this contract
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        // Build CCIP message
        Client.EVM2AnyMessage memory message = _buildTokenMessage(
            _receiver,
            _token,
            _amount,
            address(i_linkToken)   // fee token = LINK
        );

        uint256 fees = i_router.getFee(_destinationChainSelector, message);

        // Handle LINK fee when token being transferred IS LINK
        // (need enough LINK for both the fee AND the transfer amount)
        if (_token == address(i_linkToken)) {
            uint256 totalLinkNeeded = fees + _amount;
            if (i_linkToken.balanceOf(address(this)) < totalLinkNeeded)
                revert InsufficientLinkBalance(i_linkToken.balanceOf(address(this)), totalLinkNeeded);
        } else {
            if (i_linkToken.balanceOf(address(this)) < fees)
                revert InsufficientLinkBalance(i_linkToken.balanceOf(address(this)), fees);
        }

        // Approve router to spend both the fee LINK and the transfer token
        i_linkToken.approve(address(i_router), fees);
        IERC20(_token).approve(address(i_router), _amount);

        messageId = i_router.ccipSend(_destinationChainSelector, message);

        emit TokensTransferred(
            messageId,
            _destinationChainSelector,
            _receiver,
            _token,
            _amount,
            address(i_linkToken),
            fees
        );
    }

    /// @notice Transfers ERC20 tokens cross-chain, paying CCIP fees in native gas.
    /// @dev    Caller must approve this contract to spend `_amount` of `_token`.
    ///         Call estimateFee() first and pass that value as msg.value.
    ///         Excess native gas is refunded.
    /// @param  _destinationChainSelector  CCIP selector of the destination chain.
    /// @param  _receiver                  Recipient address on the destination chain.
    /// @param  _token                     Token contract address on the source chain.
    /// @param  _amount                    Amount of tokens to transfer.
    /// @return messageId                  CCIP message ID for tracking.
    function transferTokensPayNative(
        uint64  _destinationChainSelector,
        address _receiver,
        address _token,
        uint256 _amount
    )
        external
        payable
        nonReentrant
        onlyAllowlistedDestination(_destinationChainSelector)
        onlyAllowlistedToken(_token)
        returns (bytes32 messageId)
    {
        if (_receiver == address(0)) revert ZeroAddress();
        if (_amount   == 0)          revert ZeroAmount();

        // Pull tokens from caller
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        // Build CCIP message
        Client.EVM2AnyMessage memory message = _buildTokenMessage(
            _receiver,
            _token,
            _amount,
            address(0)   // fee token = native gas
        );

        uint256 fees = i_router.getFee(_destinationChainSelector, message);
        if (msg.value < fees)
            revert InsufficientNativeBalance(msg.value, fees);

        // Approve router to spend transfer token
        IERC20(_token).approve(address(i_router), _amount);

        messageId = i_router.ccipSend{value: fees}(_destinationChainSelector, message);

        // Refund any excess native gas to caller
        if (msg.value > fees) {
            (bool ok,) = msg.sender.call{value: msg.value - fees}("");
            if (!ok) revert RefundFailed();
        }

        emit TokensTransferred(
            messageId,
            _destinationChainSelector,
            _receiver,
            _token,
            _amount,
            address(0),
            fees
        );
    }

    // ─────────────────────────────────────────────────────────────
    //  View helpers
    // ─────────────────────────────────────────────────────────────

    /// @notice Estimates CCIP fee for a token transfer before executing.
    /// @dev    Always call this before transferTokensPayNative to know the msg.value.
    function estimateFee(
        uint64  _destinationChainSelector,
        address _receiver,
        address _token,
        uint256 _amount
    ) external view returns (uint256 fee) {
        Client.EVM2AnyMessage memory message = _buildTokenMessage(
            _receiver,
            _token,
            _amount,
            payFeesInLink ? address(i_linkToken) : address(0)
        );
        fee = i_router.getFee(_destinationChainSelector, message);
    }

    function getRouter()    external view returns (address) { return address(i_router); }
    function getLinkToken() external view returns (address) { return address(i_linkToken); }

    // ─────────────────────────────────────────────────────────────
    //  Admin functions
    // ─────────────────────────────────────────────────────────────

    function allowlistDestinationChain(uint64 _chainSelector, bool _allowed)
        external onlyOwner
    {
        allowlistedDestinationChains[_chainSelector] = _allowed;
        emit DestinationChainAllowlisted(_chainSelector, _allowed);
    }

    function allowlistToken(address _token, bool _allowed)
        external onlyOwner
    {
        if (_token == address(0)) revert ZeroAddress();
        allowlistedTokens[_token] = _allowed;
        emit TokenAllowlisted(_token, _allowed);
    }

    /// @notice Update extraArgs — required when sending to smart contract receivers.
    /// @dev    For EOA receivers keep gasLimit = 0.
    ///         For smart contract receivers set gasLimit >= 200_000.
    function updateExtraArgs(bytes calldata _extraArgs) external onlyOwner {
        extraArgs = _extraArgs;
        emit ExtraArgsUpdated(_extraArgs);
    }

    function setPayFeesInLink(bool _payInLink) external onlyOwner {
        payFeesInLink = _payInLink;
        emit FeeConfigUpdated(_payInLink);
    }

    /// @notice Emergency: withdraw LINK stuck in this contract (e.g. unused fees).
    function withdrawLink(address _to) external onlyOwner {
        if (_to == address(0)) revert ZeroAddress();
        uint256 bal = i_linkToken.balanceOf(address(this));
        if (bal == 0) revert NothingToWithdraw();
        i_linkToken.safeTransfer(_to, bal);
    }

    /// @notice Emergency: withdraw native gas stuck in this contract.
    function withdrawNative(address payable _to) external onlyOwner {
        if (_to == address(0)) revert ZeroAddress();
        uint256 bal = address(this).balance;
        if (bal == 0) revert NothingToWithdraw();
        (bool ok,) = _to.call{value: bal}("");
        if (!ok) revert WithdrawFailed();
    }

    /// @notice Emergency: withdraw any ERC20 stuck in this contract.
    function withdrawToken(address _token, address _to) external onlyOwner {
        if (_to    == address(0)) revert ZeroAddress();
        if (_token == address(0)) revert ZeroAddress();
        uint256 bal = IERC20(_token).balanceOf(address(this));
        if (bal == 0) revert NothingToWithdraw();
        IERC20(_token).safeTransfer(_to, bal);
    }

    receive() external payable {}

    // ─────────────────────────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────────────────────────

    /// @dev Builds the EVM2AnyMessage struct for a token-only transfer.
    ///      data field is intentionally empty — tokens only, no payload.
    function _buildTokenMessage(
        address _receiver,
        address _token,
        uint256 _amount,
        address _feeToken
    ) internal view returns (Client.EVM2AnyMessage memory) {
        // Build the token amounts array (single token transfer)
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token:  _token,
            amount: _amount
        });

        return Client.EVM2AnyMessage({
            receiver:     abi.encode(_receiver), // must be abi.encode
            data:         "",                    // empty — no message payload
            tokenAmounts: tokenAmounts,          // the token + amount
            extraArgs:    extraArgs,             // mutable, never hardcoded
            feeToken:     _feeToken              // address(0) = native gas
        });
    }
}
