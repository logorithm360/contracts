// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IChainRegistry} from "./interfaces/IChainRegistry.sol";

interface ITokenVerifierFeature6 {
    function isTransferSafe(address token, uint256 amount) external returns (bool);
}

interface ISecurityManagerTransferFeature6 {
    function validateTransfer(address user, uint8 feature, address token, uint256 amount) external;
    function enforcementMode() external view returns (uint8);
    function logIncident(address actor, uint8 feature, bytes32 reason, bytes32 ref) external;
}

/// @title TokenTransferSender
/// @notice Sends ERC20 token transfers cross-chain via CCIP.
/// @dev Deployed on source chain. Supports LINK fees or native fees.
contract TokenTransferSender is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
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

    event TokensTransferred(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address indexed receiver,
        address initiator,
        address token,
        uint256 tokenAmount,
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

    bytes32 private constant SERVICE_KEY_TOKEN_SENDER = keccak256("TOKEN_TRANSFER_SENDER");
    bytes32 private constant SERVICE_KEY_TOKEN_RECEIVER = keccak256("TOKEN_TRANSFER_RECEIVER");
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

        // gasLimit=0 default for EOA receivers in token-only transfers.
        extraArgs = Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 0, allowOutOfOrderExecution: false}));
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

    function transferTokensPayLink(uint64 _destinationChainSelector, address _receiver, address _token, uint256 _amount)
        external
        nonReentrant
        onlyAllowlistedDestination(_destinationChainSelector)
        onlyAllowlistedToken(_token)
        returns (bytes32 messageId)
    {
        if (_receiver == address(0)) revert ZeroAddress();
        if (_amount == 0) revert ZeroAmount();
        _validateChainRegistry(_destinationChainSelector, _receiver, _token);
        _validateSecurity(msg.sender, _token, _amount);

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        Client.EVM2AnyMessage memory message =
            _buildTokenMessage(_receiver, _token, _amount, address(I_LINK_TOKEN), msg.sender);

        uint256 fees = I_ROUTER.getFee(_destinationChainSelector, message);

        if (_token == address(I_LINK_TOKEN)) {
            uint256 totalLinkNeeded = fees + _amount;
            if (I_LINK_TOKEN.balanceOf(address(this)) < totalLinkNeeded) {
                revert InsufficientLinkBalance(I_LINK_TOKEN.balanceOf(address(this)), totalLinkNeeded);
            }
        } else if (I_LINK_TOKEN.balanceOf(address(this)) < fees) {
            revert InsufficientLinkBalance(I_LINK_TOKEN.balanceOf(address(this)), fees);
        }

        I_LINK_TOKEN.approve(address(I_ROUTER), fees);
        IERC20(_token).approve(address(I_ROUTER), _amount);

        messageId = I_ROUTER.ccipSend(_destinationChainSelector, message);

        emit TokensTransferred(
            messageId,
            _destinationChainSelector,
            _receiver,
            msg.sender,
            _token,
            _amount,
            address(I_LINK_TOKEN),
            fees,
            keccak256(extraArgs)
        );
    }

    function transferTokensPayNative(
        uint64 _destinationChainSelector,
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
        if (_amount == 0) revert ZeroAmount();
        _validateChainRegistry(_destinationChainSelector, _receiver, _token);
        _validateSecurity(msg.sender, _token, _amount);

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        Client.EVM2AnyMessage memory message = _buildTokenMessage(_receiver, _token, _amount, address(0), msg.sender);

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

        emit TokensTransferred(
            messageId,
            _destinationChainSelector,
            _receiver,
            msg.sender,
            _token,
            _amount,
            address(0),
            fees,
            keccak256(extraArgs)
        );
    }

    function estimateFee(uint64 _destinationChainSelector, address _receiver, address _token, uint256 _amount)
        external
        view
        returns (uint256 fee)
    {
        Client.EVM2AnyMessage memory message = _buildTokenMessage(
            _receiver, _token, _amount, payFeesInLink ? address(I_LINK_TOKEN) : address(0), msg.sender
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
        if (_token == address(0) || _to == address(0)) revert ZeroAddress();
        uint256 bal = IERC20(_token).balanceOf(address(this));
        if (bal == 0) revert NothingToWithdraw();
        IERC20(_token).safeTransfer(_to, bal);
        emit TokenWithdrawn(_token, _to, bal);
    }

    receive() external payable {}

    function _buildTokenMessage(
        address _receiver,
        address _token,
        uint256 _amount,
        address _feeToken,
        address _originSender
    ) internal view returns (Client.EVM2AnyMessage memory) {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: _token, amount: _amount});

        return Client.EVM2AnyMessage({
            receiver: abi.encode(_receiver),
            // CRE workflows can correlate destination delivery to the user who initiated on source chain.
            data: abi.encode(_originSender),
            tokenAmounts: tokenAmounts,
            extraArgs: extraArgs,
            feeToken: _feeToken
        });
    }

    function _validateSecurity(address _user, address _token, uint256 _amount) internal {
        if (securityManager != address(0)) {
            ISecurityManagerTransferFeature6(securityManager)
                .validateTransfer(
                    _user,
                    1, // FeatureId.TOKEN_TRANSFER
                    _token,
                    _amount
                );
        }

        if (tokenVerifier == address(0)) return;

        bool safe = ITokenVerifierFeature6(tokenVerifier).isTransferSafe(_token, _amount);
        if (safe) return;

        if (securityManager != address(0) && ISecurityManagerTransferFeature6(securityManager).enforcementMode() == 0) {
            ISecurityManagerTransferFeature6(securityManager)
                .logIncident(
                    _user,
                    1, // FeatureId.TOKEN_TRANSFER
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

        address configuredSource = chainRegistry.getServiceContract(sourceSelector, SERVICE_KEY_TOKEN_SENDER);
        if (configuredSource != address(this)) {
            _handleRegistryViolation(
                REASON_SOURCE_SERVICE_NOT_BOUND, sourceSelector, _destinationChainSelector, _token, _receiver
            );
            return;
        }

        address configuredDestination =
            chainRegistry.getServiceContract(_destinationChainSelector, SERVICE_KEY_TOKEN_RECEIVER);
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
