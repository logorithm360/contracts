// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ProgrammableTokenSender
/// @notice Sends CCIP programmable token transfers (token + instruction payload).
contract ProgrammableTokenSender is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error EmptyPayload();
    error NothingToWithdraw();
    error WithdrawFailed();
    error DestinationChainNotAllowlisted(uint64 chainSelector);
    error TokenNotAllowlisted(address token);
    error InsufficientLinkBalance(uint256 have, uint256 need);
    error InsufficientNativeBalance(uint256 sent, uint256 need);
    error RefundFailed();

    struct TransferPayload {
        address recipient;
        string action;
        bytes extraData;
        uint256 deadline;
    }

    event ProgrammableTransferSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address indexed receiverContract,
        address initiator,
        address token,
        uint256 tokenAmount,
        address payloadRecipient,
        string action,
        address feeToken,
        uint256 fees,
        bytes32 extraArgsHash
    );
    event DestinationChainAllowlisted(uint64 indexed chainSelector, bool allowed);
    event TokenAllowlisted(address indexed token, bool allowed);
    event ExtraArgsUpdated(bytes extraArgs);
    event FeeConfigUpdated(bool payInLink);
    event LinkWithdrawn(address indexed to, uint256 amount);
    event NativeWithdrawn(address indexed to, uint256 amount);
    event TokenWithdrawn(address indexed token, address indexed to, uint256 amount);

    IRouterClient private immutable I_ROUTER;
    IERC20 private immutable I_LINK_TOKEN;

    mapping(uint64 => bool) public allowlistedDestinationChains;
    mapping(address => bool) public allowlistedTokens;

    bytes public extraArgs;
    bool public payFeesInLink;

    constructor(address _router, address _linkToken, bool _payFeesInLink) Ownable(msg.sender) {
        if (_router == address(0) || _linkToken == address(0)) revert ZeroAddress();

        I_ROUTER = IRouterClient(_router);
        I_LINK_TOKEN = IERC20(_linkToken);
        payFeesInLink = _payFeesInLink;

        extraArgs = Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 500_000, allowOutOfOrderExecution: false}));
    }

    modifier onlyAllowlistedDestination(uint64 _chainSelector) {
        _onlyAllowlistedDestination(_chainSelector);
        _;
    }

    modifier onlyAllowlistedToken(address _token) {
        _onlyAllowlistedToken(_token);
        _;
    }

    function _onlyAllowlistedDestination(uint64 _chainSelector) internal view {
        if (!allowlistedDestinationChains[_chainSelector]) {
            revert DestinationChainNotAllowlisted(_chainSelector);
        }
    }

    function _onlyAllowlistedToken(address _token) internal view {
        if (!allowlistedTokens[_token]) {
            revert TokenNotAllowlisted(_token);
        }
    }

    function sendPayLink(
        uint64 _destinationChainSelector,
        address _receiverContract,
        address _token,
        uint256 _amount,
        TransferPayload calldata _payload
    )
        external
        nonReentrant
        onlyAllowlistedDestination(_destinationChainSelector)
        onlyAllowlistedToken(_token)
        returns (bytes32 messageId)
    {
        _validateInputs(_receiverContract, _amount, _payload);

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        Client.EVM2AnyMessage memory message =
            _buildMessage(_receiverContract, _token, _amount, _payload, address(I_LINK_TOKEN), msg.sender);

        uint256 fees = I_ROUTER.getFee(_destinationChainSelector, message);

        uint256 linkRequired = (_token == address(I_LINK_TOKEN)) ? fees + _amount : fees;

        if (I_LINK_TOKEN.balanceOf(address(this)) < linkRequired) {
            revert InsufficientLinkBalance(I_LINK_TOKEN.balanceOf(address(this)), linkRequired);
        }

        I_LINK_TOKEN.approve(address(I_ROUTER), fees);
        IERC20(_token).approve(address(I_ROUTER), _amount);

        messageId = I_ROUTER.ccipSend(_destinationChainSelector, message);

        emit ProgrammableTransferSent(
            messageId,
            _destinationChainSelector,
            _receiverContract,
            msg.sender,
            _token,
            _amount,
            _payload.recipient,
            _payload.action,
            address(I_LINK_TOKEN),
            fees,
            keccak256(extraArgs)
        );
    }

    function sendPayNative(
        uint64 _destinationChainSelector,
        address _receiverContract,
        address _token,
        uint256 _amount,
        TransferPayload calldata _payload
    )
        external
        payable
        nonReentrant
        onlyAllowlistedDestination(_destinationChainSelector)
        onlyAllowlistedToken(_token)
        returns (bytes32 messageId)
    {
        _validateInputs(_receiverContract, _amount, _payload);

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        Client.EVM2AnyMessage memory message =
            _buildMessage(_receiverContract, _token, _amount, _payload, address(0), msg.sender);

        uint256 fees = I_ROUTER.getFee(_destinationChainSelector, message);
        if (msg.value < fees) {
            revert InsufficientNativeBalance(msg.value, fees);
        }

        IERC20(_token).approve(address(I_ROUTER), _amount);
        messageId = I_ROUTER.ccipSend{value: fees}(_destinationChainSelector, message);

        if (msg.value > fees) {
            (bool ok,) = msg.sender.call{value: msg.value - fees}("");
            if (!ok) revert RefundFailed();
        }

        emit ProgrammableTransferSent(
            messageId,
            _destinationChainSelector,
            _receiverContract,
            msg.sender,
            _token,
            _amount,
            _payload.recipient,
            _payload.action,
            address(0),
            fees,
            keccak256(extraArgs)
        );
    }

    function estimateFee(
        uint64 _destinationChainSelector,
        address _receiverContract,
        address _token,
        uint256 _amount,
        TransferPayload calldata _payload
    ) external view returns (uint256 fee) {
        Client.EVM2AnyMessage memory message = _buildMessage(
            _receiverContract, _token, _amount, _payload, payFeesInLink ? address(I_LINK_TOKEN) : address(0), msg.sender
        );

        fee = I_ROUTER.getFee(_destinationChainSelector, message);
    }

    function getRouter() external view returns (address) {
        return address(I_ROUTER);
    }

    function getLinkToken() external view returns (address) {
        return address(I_LINK_TOKEN);
    }

    function allowlistDestinationChain(uint64 _chainSelector, bool _allowed) external onlyOwner {
        allowlistedDestinationChains[_chainSelector] = _allowed;
        emit DestinationChainAllowlisted(_chainSelector, _allowed);
    }

    function allowlistToken(address _token, bool _allowed) external onlyOwner {
        if (_token == address(0)) revert ZeroAddress();
        allowlistedTokens[_token] = _allowed;
        emit TokenAllowlisted(_token, _allowed);
    }

    function updateExtraArgs(bytes calldata _extraArgs) external onlyOwner {
        extraArgs = _extraArgs;
        emit ExtraArgsUpdated(_extraArgs);
    }

    function setPayFeesInLink(bool _payInLink) external onlyOwner {
        payFeesInLink = _payInLink;
        emit FeeConfigUpdated(_payInLink);
    }

    function withdrawLink(address _to) external onlyOwner {
        if (_to == address(0)) revert ZeroAddress();
        uint256 bal = I_LINK_TOKEN.balanceOf(address(this));
        if (bal == 0) revert NothingToWithdraw();

        I_LINK_TOKEN.safeTransfer(_to, bal);
        emit LinkWithdrawn(_to, bal);
    }

    function withdrawNative(address payable _to) external onlyOwner {
        if (_to == address(0)) revert ZeroAddress();
        uint256 bal = address(this).balance;
        if (bal == 0) revert NothingToWithdraw();

        (bool ok,) = _to.call{value: bal}("");
        if (!ok) revert WithdrawFailed();
        emit NativeWithdrawn(_to, bal);
    }

    function withdrawToken(address _token, address _to) external onlyOwner {
        if (_to == address(0) || _token == address(0)) revert ZeroAddress();
        uint256 bal = IERC20(_token).balanceOf(address(this));
        if (bal == 0) revert NothingToWithdraw();

        IERC20(_token).safeTransfer(_to, bal);
        emit TokenWithdrawn(_token, _to, bal);
    }

    receive() external payable {}

    function _validateInputs(address _receiver, uint256 _amount, TransferPayload calldata _payload) internal pure {
        if (_receiver == address(0)) revert ZeroAddress();
        if (_amount == 0) revert ZeroAmount();
        if (_payload.recipient == address(0)) revert ZeroAddress();
        if (bytes(_payload.action).length == 0) revert EmptyPayload();
    }

    function _buildMessage(
        address _receiver,
        address _token,
        uint256 _amount,
        TransferPayload calldata _payload,
        address _feeToken,
        address _originSender
    ) internal view returns (Client.EVM2AnyMessage memory) {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: _token, amount: _amount});

        return Client.EVM2AnyMessage({
            receiver: abi.encode(_receiver),
            // data includes both transfer instructions and source initiator for CRE/workflow reconciliation.
            data: abi.encode(_payload, _originSender),
            tokenAmounts: tokenAmounts,
            extraArgs: extraArgs,
            feeToken: _feeToken
        });
    }
}
