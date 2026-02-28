// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IChainRegistry} from "./interfaces/IChainRegistry.sol";

interface ITokenVerifierProgrammableFeature6 {
    function isTransferSafe(address token, uint256 amount) external returns (bool);
}

interface ISecurityManagerProgrammableFeature6 {
    function validateAction(address user, uint8 feature, bytes32 actionKey, uint256 weight) external;
    function validateTransfer(address user, uint8 feature, address token, uint256 amount) external;
    function enforcementMode() external view returns (uint8);
    function logIncident(address actor, uint8 feature, bytes32 reason, bytes32 ref) external;
}

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
    error UnsafeToken(address token, uint256 amount);
    error InvalidResolverMode(uint8 mode);
    error RegistryPolicyBlocked(bytes32 reason);

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
    event SecurityConfigUpdated(address indexed securityManager, address indexed tokenVerifier);
    event ChainRegistryConfigured(address indexed chainRegistry, ResolverMode mode);
    event RegistryPolicyViolation(
        bytes32 indexed reason,
        uint64 indexed sourceSelector,
        uint64 indexed destinationSelector,
        address token,
        address counterparty
    );
    event LinkWithdrawn(address indexed to, uint256 amount);
    event NativeWithdrawn(address indexed to, uint256 amount);
    event TokenWithdrawn(address indexed token, address indexed to, uint256 amount);

    enum ResolverMode {
        DISABLED,
        MONITOR,
        ENFORCE
    }

    bytes32 private constant SERVICE_KEY_PROGRAMMABLE_SENDER = keccak256("PROGRAMMABLE_TRANSFER_SENDER");
    bytes32 private constant SERVICE_KEY_PROGRAMMABLE_RECEIVER = keccak256("PROGRAMMABLE_TRANSFER_RECEIVER");
    bytes32 private constant REASON_SOURCE_CHAIN_UNSUPPORTED = keccak256("SOURCE_CHAIN_UNSUPPORTED");
    bytes32 private constant REASON_DESTINATION_CHAIN_UNSUPPORTED = keccak256("DESTINATION_CHAIN_UNSUPPORTED");
    bytes32 private constant REASON_LANE_DISABLED = keccak256("LANE_DISABLED");
    bytes32 private constant REASON_TOKEN_NOT_TRANSFERABLE = keccak256("TOKEN_NOT_TRANSFERABLE");
    bytes32 private constant REASON_SOURCE_SERVICE_NOT_BOUND = keccak256("SOURCE_SERVICE_NOT_BOUND");
    bytes32 private constant REASON_DESTINATION_SERVICE_NOT_BOUND = keccak256("DESTINATION_SERVICE_NOT_BOUND");

    IRouterClient private immutable I_ROUTER;
    IERC20 private immutable I_LINK_TOKEN;

    mapping(uint64 => bool) public allowlistedDestinationChains;
    mapping(address => bool) public allowlistedTokens;

    bytes public extraArgs;
    bool public payFeesInLink;
    address public securityManager;
    address public tokenVerifier;
    IChainRegistry public chainRegistry;
    ResolverMode public resolverMode;

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
        _validateChainRegistry(_destinationChainSelector, _receiverContract, _token);
        _validateSecurity(msg.sender, _token, _amount, _payload.action);

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
        _validateChainRegistry(_destinationChainSelector, _receiverContract, _token);
        _validateSecurity(msg.sender, _token, _amount, _payload.action);

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

    /// @notice Configures Feature 6 security dependencies. Set both zero-address to disable.
    function configureSecurity(address _securityManager, address _tokenVerifier) external onlyOwner {
        securityManager = _securityManager;
        tokenVerifier = _tokenVerifier;
        emit SecurityConfigUpdated(_securityManager, _tokenVerifier);
    }

    /// @notice Configures Feature 7 chain registry and validation mode.
    function configureChainRegistry(address _chainRegistry, uint8 _mode) external onlyOwner {
        if (_mode > uint8(ResolverMode.ENFORCE)) revert InvalidResolverMode(_mode);
        if (_mode != uint8(ResolverMode.DISABLED) && _chainRegistry == address(0)) revert ZeroAddress();

        chainRegistry = IChainRegistry(_chainRegistry);
        resolverMode = ResolverMode(_mode);

        emit ChainRegistryConfigured(_chainRegistry, ResolverMode(_mode));
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

    function _validateSecurity(address _user, address _token, uint256 _amount, string calldata _action) internal {
        if (securityManager != address(0)) {
            ISecurityManagerProgrammableFeature6(securityManager)
                .validateAction(
                    _user,
                    2, // FeatureId.PROGRAMMABLE_TRANSFER
                    keccak256(bytes(_action)),
                    1
                );
            ISecurityManagerProgrammableFeature6(securityManager)
                .validateTransfer(
                    _user,
                    2, // FeatureId.PROGRAMMABLE_TRANSFER
                    _token,
                    _amount
                );
        }

        if (tokenVerifier == address(0)) return;

        bool safe = ITokenVerifierProgrammableFeature6(tokenVerifier).isTransferSafe(_token, _amount);
        if (safe) return;

        if (
            securityManager != address(0)
                && ISecurityManagerProgrammableFeature6(securityManager).enforcementMode() == 0
        ) {
            ISecurityManagerProgrammableFeature6(securityManager)
                .logIncident(
                    _user,
                    2, // FeatureId.PROGRAMMABLE_TRANSFER
                    "TOKEN_UNSAFE",
                    bytes32(uint256(uint160(_token)))
                );
            return;
        }

        revert UnsafeToken(_token, _amount);
    }

    function _validateChainRegistry(uint64 _destinationChainSelector, address _receiver, address _token) internal {
        if (resolverMode == ResolverMode.DISABLED) return;
        if (address(chainRegistry) == address(0)) {
            _handleRegistryViolation(REASON_SOURCE_CHAIN_UNSUPPORTED, 0, _destinationChainSelector, _token, _receiver);
            return;
        }

        uint64 sourceSelector = chainRegistry.getSelectorByChainId(block.chainid);
        if (sourceSelector == 0 || !chainRegistry.isChainSupported(sourceSelector)) {
            _handleRegistryViolation(
                REASON_SOURCE_CHAIN_UNSUPPORTED, sourceSelector, _destinationChainSelector, _token, _receiver
            );
            return;
        }

        if (!chainRegistry.isChainSupported(_destinationChainSelector)) {
            _handleRegistryViolation(
                REASON_DESTINATION_CHAIN_UNSUPPORTED, sourceSelector, _destinationChainSelector, _token, _receiver
            );
            return;
        }

        if (!chainRegistry.isLaneActive(sourceSelector, _destinationChainSelector)) {
            _handleRegistryViolation(REASON_LANE_DISABLED, sourceSelector, _destinationChainSelector, _token, _receiver);
            return;
        }

        if (!chainRegistry.isTokenTransferable(sourceSelector, _destinationChainSelector, _token)) {
            _handleRegistryViolation(
                REASON_TOKEN_NOT_TRANSFERABLE, sourceSelector, _destinationChainSelector, _token, _receiver
            );
            return;
        }

        address configuredSource = chainRegistry.getServiceContract(sourceSelector, SERVICE_KEY_PROGRAMMABLE_SENDER);
        if (configuredSource != address(this)) {
            _handleRegistryViolation(
                REASON_SOURCE_SERVICE_NOT_BOUND, sourceSelector, _destinationChainSelector, _token, _receiver
            );
            return;
        }

        address configuredDestination =
            chainRegistry.getServiceContract(_destinationChainSelector, SERVICE_KEY_PROGRAMMABLE_RECEIVER);
        if (configuredDestination != _receiver) {
            _handleRegistryViolation(
                REASON_DESTINATION_SERVICE_NOT_BOUND, sourceSelector, _destinationChainSelector, _token, _receiver
            );
        }
    }

    function _handleRegistryViolation(
        bytes32 _reason,
        uint64 _sourceSelector,
        uint64 _destinationSelector,
        address _token,
        address _counterparty
    ) internal {
        emit RegistryPolicyViolation(_reason, _sourceSelector, _destinationSelector, _token, _counterparty);
        if (resolverMode == ResolverMode.ENFORCE) revert RegistryPolicyBlocked(_reason);
    }
}
