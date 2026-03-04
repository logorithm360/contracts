// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IChainRegistry} from "./interfaces/IChainRegistry.sol";

interface ISecurityManagerFeature6 {
    function validateAction(address user, uint8 feature, bytes32 actionKey, uint256 weight) external;
}

/// @title  MessagingSender
/// @notice Production-grade CCIP sender contract.
///         Supports paying fees in LINK or native gas.
///         Deployed on the SOURCE chain.
/// @dev    All destination chains must be explicitly allowlisted by the owner.
///         extraArgs is mutable for CCIP upgrade compatibility.
contract MessagingSender is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────
    //  Custom errors
    // ─────────────────────────────────────────────────────────────
    error ZeroAddress();
    error EmptyData();
    error NothingToWithdraw();
    error WithdrawFailed();
    error DestinationChainNotAllowlisted(uint64 chainSelector);
    error InsufficientLinkBalance(uint256 have, uint256 need);
    error InsufficientNativeBalance(uint256 sent, uint256 need);
    error RefundFailed();
    error InvalidResolverMode(uint8 mode);
    error RegistryPolicyBlocked(bytes32 reason);

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────
    event MessageSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address indexed receiver,
        string text,
        address feeToken,
        uint256 fees
    );
    event DestinationChainAllowlisted(uint64 indexed chainSelector, bool allowed);
    event ExtraArgsUpdated(bytes extraArgs);
    event FeeConfigUpdated(bool payInLink);
    event SecurityConfigUpdated(address indexed securityManager, address indexed tokenVerifier);
    event ChainRegistryConfigured(address indexed chainRegistry, ResolverMode mode);
    event RegistryPolicyViolation(
        bytes32 indexed reason, uint64 indexed sourceSelector, uint64 indexed destinationSelector, address counterparty
    );
    event LinkWithdrawn(address indexed to, uint256 amount);
    event NativeWithdrawn(address indexed to, uint256 amount);

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────

    enum ResolverMode {
        DISABLED,
        MONITOR,
        ENFORCE
    }

    bytes32 private constant SERVICE_KEY_MESSAGE_SENDER = keccak256("MESSAGE_SENDER");
    bytes32 private constant SERVICE_KEY_MESSAGE_RECEIVER = keccak256("MESSAGE_RECEIVER");
    bytes32 private constant REASON_SOURCE_CHAIN_UNSUPPORTED = keccak256("SOURCE_CHAIN_UNSUPPORTED");
    bytes32 private constant REASON_DESTINATION_CHAIN_UNSUPPORTED = keccak256("DESTINATION_CHAIN_UNSUPPORTED");
    bytes32 private constant REASON_LANE_DISABLED = keccak256("LANE_DISABLED");
    bytes32 private constant REASON_SOURCE_SERVICE_NOT_BOUND = keccak256("SOURCE_SERVICE_NOT_BOUND");
    bytes32 private constant REASON_DESTINATION_SERVICE_NOT_BOUND = keccak256("DESTINATION_SERVICE_NOT_BOUND");

    /// @notice Immutable CCIP router on this chain.
    IRouterClient private immutable I_ROUTER;

    /// @notice Immutable LINK token address on this chain.
    IERC20 private immutable I_LINK_TOKEN;

    /// @notice Chains the owner has approved for outbound CCIP messages.
    mapping(uint64 => bool) public allowlistedDestinationChains;

    /// @notice Mutable extraArgs — NEVER hardcode; allows CCIP upgrade compatibility.
    bytes public extraArgs;

    /// @notice If true, fees are paid in LINK; otherwise in native gas.
    bool public payFeesInLink;

    /// @notice Feature 6 optional security manager (can be configured post-deploy).
    address public securityManager;

    /// @notice Feature 6 optional token verifier (unused in messaging, reserved for unified config).
    address public tokenVerifier;

    /// @notice Feature 7 chain registry contract.
    IChainRegistry public chainRegistry;

    /// @notice Feature 7 resolver mode.
    ResolverMode public resolverMode;

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────

    /// @param _router        CCIP router address on the source chain.
    /// @param _linkToken     LINK token address on the source chain.
    /// @param _payFeesInLink True → pay fees in LINK, false → pay in native gas.
    constructor(address _router, address _linkToken, bool _payFeesInLink) Ownable(msg.sender) {
        if (_router == address(0)) revert ZeroAddress();
        if (_linkToken == address(0)) revert ZeroAddress();

        I_ROUTER = IRouterClient(_router);
        I_LINK_TOKEN = IERC20(_linkToken);
        payFeesInLink = _payFeesInLink;

        // Default: 300_000 gas on destination, ordered execution.
        // Owner can update via updateExtraArgs() as CCIP evolves.
        extraArgs = Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 300_000, allowOutOfOrderExecution: false}));
    }

    // ─────────────────────────────────────────────────────────────
    //  Modifiers
    // ─────────────────────────────────────────────────────────────

    modifier onlyAllowlistedDestination(uint64 _chainSelector) {
        _onlyAllowlistedDestination(_chainSelector);
        _;
    }

    function _onlyAllowlistedDestination(uint64 _chainSelector) internal view {
        if (!allowlistedDestinationChains[_chainSelector]) {
            revert DestinationChainNotAllowlisted(_chainSelector);
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  Core send functions
    // ─────────────────────────────────────────────────────────────

    /// @notice Sends a plain text message cross-chain, paying fees in LINK.
    /// @param  _destinationChainSelector  CCIP chain selector of the destination.
    /// @param  _receiver                  Address of the CCIPReceiver on destination.
    /// @param  _text                      UTF-8 string to send.
    /// @return messageId                  The CCIP message ID.
    function sendMessagePayLink(uint64 _destinationChainSelector, address _receiver, string calldata _text)
        external
        nonReentrant
        onlyAllowlistedDestination(_destinationChainSelector)
        returns (bytes32 messageId)
    {
        if (_receiver == address(0)) revert ZeroAddress();
        if (bytes(_text).length == 0) revert EmptyData();
        _validateChainRegistry(_destinationChainSelector, _receiver);
        _validateSecurity(msg.sender, _text);

        Client.EVM2AnyMessage memory message = _buildMessage(_receiver, _text, address(I_LINK_TOKEN));

        uint256 fees = I_ROUTER.getFee(_destinationChainSelector, message);
        if (I_LINK_TOKEN.balanceOf(address(this)) < fees) {
            revert InsufficientLinkBalance(I_LINK_TOKEN.balanceOf(address(this)), fees);
        }

        I_LINK_TOKEN.approve(address(I_ROUTER), fees);
        messageId = I_ROUTER.ccipSend(_destinationChainSelector, message);

        emit MessageSent(messageId, _destinationChainSelector, _receiver, _text, address(I_LINK_TOKEN), fees);
    }

    /// @notice Sends a plain text message cross-chain, paying fees in native gas.
    /// @dev    Call estimateFee() first and send that amount as msg.value.
    ///         Excess native is refunded.
    /// @param  _destinationChainSelector  CCIP chain selector of the destination.
    /// @param  _receiver                  Address of the CCIPReceiver on destination.
    /// @param  _text                      UTF-8 string to send.
    /// @return messageId                  The CCIP message ID.
    function sendMessagePayNative(uint64 _destinationChainSelector, address _receiver, string calldata _text)
        external
        payable
        nonReentrant
        onlyAllowlistedDestination(_destinationChainSelector)
        returns (bytes32 messageId)
    {
        if (_receiver == address(0)) revert ZeroAddress();
        if (bytes(_text).length == 0) revert EmptyData();
        _validateChainRegistry(_destinationChainSelector, _receiver);
        _validateSecurity(msg.sender, _text);

        Client.EVM2AnyMessage memory message = _buildMessage(_receiver, _text, address(0));

        uint256 fees = I_ROUTER.getFee(_destinationChainSelector, message);
        if (msg.value < fees) {
            revert InsufficientNativeBalance(msg.value, fees);
        }

        messageId = I_ROUTER.ccipSend{value: fees}(_destinationChainSelector, message);

        // Refund excess native gas to caller
        if (msg.value > fees) {
            (bool ok,) = msg.sender.call{value: msg.value - fees}("");
            if (!ok) revert RefundFailed();
        }

        emit MessageSent(messageId, _destinationChainSelector, _receiver, _text, address(0), fees);
    }

    // ─────────────────────────────────────────────────────────────
    //  View helpers
    // ─────────────────────────────────────────────────────────────

    /// @notice Estimate the CCIP fee for a message before sending.
    /// @param  _destinationChainSelector  Target chain selector.
    /// @param  _receiver                  Receiver address on destination.
    /// @param  _text                      Payload string.
    /// @return fee  Fee in LINK (if payFeesInLink) or native (otherwise).
    function estimateFee(uint64 _destinationChainSelector, address _receiver, string calldata _text)
        external
        view
        returns (uint256 fee)
    {
        Client.EVM2AnyMessage memory message =
            _buildMessage(_receiver, _text, payFeesInLink ? address(I_LINK_TOKEN) : address(0));
        fee = I_ROUTER.getFee(_destinationChainSelector, message);
    }

    /// @notice Returns the router address used by this contract.
    function getRouter() external view returns (address) {
        return address(I_ROUTER);
    }

    /// @notice Returns the LINK token address used by this contract.
    function getLinkToken() external view returns (address) {
        return address(I_LINK_TOKEN);
    }

    // ─────────────────────────────────────────────────────────────
    //  Admin functions
    // ─────────────────────────────────────────────────────────────

    /// @notice Allow or block a destination chain selector.
    function allowlistDestinationChain(uint64 _chainSelector, bool _allowed) external onlyOwner {
        allowlistedDestinationChains[_chainSelector] = _allowed;
        emit DestinationChainAllowlisted(_chainSelector, _allowed);
    }

    /// @notice Update extraArgs to stay compatible with future CCIP upgrades.
    function updateExtraArgs(bytes calldata _extraArgs) external onlyOwner {
        extraArgs = _extraArgs;
        emit ExtraArgsUpdated(_extraArgs);
    }

    /// @notice Switch fee payment between LINK and native gas.
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

    /// @notice Emergency: withdraw any LINK stuck in this contract.
    function withdrawLink(address _to) external onlyOwner {
        if (_to == address(0)) revert ZeroAddress();
        uint256 bal = I_LINK_TOKEN.balanceOf(address(this));
        if (bal == 0) revert NothingToWithdraw();
        I_LINK_TOKEN.safeTransfer(_to, bal);
        emit LinkWithdrawn(_to, bal);
    }

    /// @notice Emergency: withdraw any native ETH stuck in this contract.
    function withdrawNative(address payable _to) external onlyOwner {
        if (_to == address(0)) revert ZeroAddress();
        uint256 bal = address(this).balance;
        if (bal == 0) revert NothingToWithdraw();
        (bool ok,) = _to.call{value: bal}("");
        if (!ok) revert WithdrawFailed();
        emit NativeWithdrawn(_to, bal);
    }

    /// @notice Accept native token deposits (for fee funding).
    receive() external payable {}

    // ─────────────────────────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────────────────────────

    function _buildMessage(address _receiver, string memory _text, address _feeToken)
        internal
        view
        returns (Client.EVM2AnyMessage memory)
    {
        return Client.EVM2AnyMessage({
            receiver: abi.encode(_receiver), // must be abi.encode
            data: abi.encode(_text),
            tokenAmounts: new Client.EVMTokenAmount[](0), // no tokens, messages only
            extraArgs: extraArgs, // mutable — never hardcoded
            feeToken: _feeToken // address(0) = native gas
        });
    }

    function _validateSecurity(address _user, string calldata _text) internal {
        if (securityManager == address(0)) return;

        ISecurityManagerFeature6(securityManager)
            .validateAction(
                _user,
                0, // FeatureId.MESSAGE
                keccak256(bytes(_text)),
                1
            );
    }

    function _validateChainRegistry(uint64 _destinationChainSelector, address _receiver) internal {
        if (resolverMode == ResolverMode.DISABLED) return;
        if (address(chainRegistry) == address(0)) {
            _handleRegistryViolation(REASON_SOURCE_CHAIN_UNSUPPORTED, 0, _destinationChainSelector, _receiver);
            return;
        }

        uint64 sourceSelector = chainRegistry.getSelectorByChainId(block.chainid);
        if (sourceSelector == 0 || !chainRegistry.isChainSupported(sourceSelector)) {
            _handleRegistryViolation(
                REASON_SOURCE_CHAIN_UNSUPPORTED, sourceSelector, _destinationChainSelector, _receiver
            );
            return;
        }

        if (!chainRegistry.isChainSupported(_destinationChainSelector)) {
            _handleRegistryViolation(
                REASON_DESTINATION_CHAIN_UNSUPPORTED, sourceSelector, _destinationChainSelector, _receiver
            );
            return;
        }

        if (!chainRegistry.isLaneActive(sourceSelector, _destinationChainSelector)) {
            _handleRegistryViolation(REASON_LANE_DISABLED, sourceSelector, _destinationChainSelector, _receiver);
            return;
        }

        address configuredSource = chainRegistry.getServiceContract(sourceSelector, SERVICE_KEY_MESSAGE_SENDER);
        if (configuredSource != address(this)) {
            _handleRegistryViolation(
                REASON_SOURCE_SERVICE_NOT_BOUND, sourceSelector, _destinationChainSelector, _receiver
            );
            return;
        }

        address configuredDestination =
            chainRegistry.getServiceContract(_destinationChainSelector, SERVICE_KEY_MESSAGE_RECEIVER);
        if (configuredDestination != _receiver) {
            _handleRegistryViolation(
                REASON_DESTINATION_SERVICE_NOT_BOUND, sourceSelector, _destinationChainSelector, _receiver
            );
        }
    }

    function _handleRegistryViolation(
        bytes32 _reason,
        uint64 _sourceSelector,
        uint64 _destinationSelector,
        address _counterparty
    ) internal {
        emit RegistryPolicyViolation(_reason, _sourceSelector, _destinationSelector, _counterparty);
        if (resolverMode == ResolverMode.ENFORCE) revert RegistryPolicyBlocked(_reason);
    }
}
