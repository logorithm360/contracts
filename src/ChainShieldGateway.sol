// SPDX-License-Identifier: MIT
pragma solidity =0.8.33;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IRouterClient} from "lib/chainlink-ccip/chains/evm/contracts/interfaces/IRouterClient.sol";
import {Client} from "lib/chainlink-ccip/chains/evm/contracts/libraries/Client.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  Interfaces for existing deployed contracts
// ─────────────────────────────────────────────────────────────────────────────

interface ISecurityManager {
    function validateTransfer(address user, uint8 feature, address token, uint256 amount) external;

    function pause(bytes32 reason) external;
    function paused() external view returns (bool);
}

interface ITokenVerifier {
    function verifyTokenLayer1(address token) external returns (uint8);
    function isTransferSafe(address token, uint256 amount) external returns (bool);
}

interface ISwapAdapter {
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient,
        uint256 slippageBps,
        uint24 poolFee
    ) external returns (uint256 amountOut);

    function passthrough(address token, uint256 amount, address recipient) external returns (uint256);
}

// ─────────────────────────────────────────────────────────────────────────────
//  ChainShieldGateway
//
//  Single on-chain entry point for ChainShield cross-chain transfers.
//
//  Full flow for every transfer:
//
//    1. SECURITY CHECK   — SecurityManager.validateTransfer()
//                          Checks rate limits, blacklist, amount caps, pause state
//
//    2. TOKEN VERIFY     — TokenVerifier.verifyTokenLayer1() + isTransferSafe()
//                          Checks token is real ERC-20, not blocked, within limits
//
//    3. SWAP             — SwapAdapter.swap() or SwapAdapter.passthrough()
//                          If tokenIn == tokenOut: passthrough (no DEX hop)
//                          If different: Uniswap V3 swap on source chain
//
//    4. CCIP BRIDGE      — Chainlink CCIP router.ccipSend()
//                          Bridges tokenOut to receiver on destination chain
//                          Pays LINK fees from contract's LINK balance
//
//  Steps 1–2 are read-only checks. No funds move until step 3.
//  If any step fails the entire call reverts — funds never leave the sender.
//
//  Feature ID 2 is used for SecurityManager (PROGRAMMABLE_TRANSFER).
// ─────────────────────────────────────────────────────────────────────────────

contract ChainShieldGateway is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Constants ────────────────────────────────────────────────────────────

    /// @dev SecurityManager feature ID for this contract (PROGRAMMABLE_TRANSFER = 2)
    uint8 public constant FEATURE_ID = 2;
    uint8 internal constant TOKEN_STATUS_SAFE = 2;
    uint8 internal constant TOKEN_STATUS_ALLOWLISTED = 5;

    // ── Immutables ───────────────────────────────────────────────────────────

    IRouterClient public immutable ccipRouter;
    IERC20 public immutable linkToken;

    // ── Storage ──────────────────────────────────────────────────────────────

    ISecurityManager public securityManager;
    ITokenVerifier public tokenVerifier;
    ISwapAdapter public swapAdapter;

    /// @dev Tracks transfer nonces per sender for frontend correlation
    mapping(address => uint256) public nonces;

    // ── Events ───────────────────────────────────────────────────────────────

    event TransferInitiated(
        bytes32 indexed ccipMessageId,
        address indexed sender,
        address indexed receiver,
        uint64 destinationChainSelector,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 nonce
    );

    event SecurityCheckPassed(address indexed sender, address tokenIn, uint256 amount);
    event TokenVerificationPassed(address indexed sender, address tokenIn, address tokenOut);
    event SwapCompleted(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    event ContractsConfigured(address securityManager, address tokenVerifier, address swapAdapter);

    // ── Errors ───────────────────────────────────────────────────────────────

    error SystemPaused();
    error SecurityCheckFailed(address user, address token, uint256 amount);
    error TokenInNotVerified(address token);
    error TokenOutNotVerified(address token);
    error TransferNotSafe(address token, uint256 amount);
    error InsufficientLinkBalance(uint256 required, uint256 available);
    error ZeroAddress();
    error ZeroAmount();
    error InvalidChainSelector(uint64 selector);
    error SwapAdapterNotSet();
    error SecurityManagerNotSet();
    error TokenVerifierNotSet();

    // ── Constructor ──────────────────────────────────────────────────────────

    /// @param _ccipRouter  Chainlink CCIP router on this chain
    /// @param _linkToken   LINK token address on this chain
    /// @param _owner       Owner address (deployer / multisig)
    constructor(address _ccipRouter, address _linkToken, address _owner) Ownable(_owner) {
        if (_ccipRouter == address(0)) revert ZeroAddress();
        if (_linkToken == address(0)) revert ZeroAddress();

        ccipRouter = IRouterClient(_ccipRouter);
        linkToken = IERC20(_linkToken);
    }

    // ── Configuration ────────────────────────────────────────────────────────

    /// @notice Wire up existing deployed security + verification contracts + new SwapAdapter
    function configureContracts(address _securityManager, address _tokenVerifier, address _swapAdapter)
        external
        onlyOwner
    {
        if (_securityManager == address(0)) revert ZeroAddress();
        if (_tokenVerifier == address(0)) revert ZeroAddress();
        if (_swapAdapter == address(0)) revert ZeroAddress();

        securityManager = ISecurityManager(_securityManager);
        tokenVerifier = ITokenVerifier(_tokenVerifier);
        swapAdapter = ISwapAdapter(_swapAdapter);

        emit ContractsConfigured(_securityManager, _tokenVerifier, _swapAdapter);
    }

    // ── Core: initiateTransfer ────────────────────────────────────────────────

    /// @notice The single function the frontend (Wagmi) calls.
    ///
    /// @param tokenIn                  Token the sender holds on source chain
    /// @param tokenOut                 Token the receiver expects on destination chain
    /// @param amountIn                 Amount of tokenIn to send
    /// @param receiver                 Receiver address on destination chain
    /// @param destinationChainSelector Chainlink CCIP chain selector for destination
    /// @param slippageBps              Slippage tolerance in basis points (max 50 = 0.5%)
    /// @param poolFee                  Uniswap pool fee tier; 0 = SwapAdapter default
    ///
    /// @return ccipMessageId           CCIP message ID for tracking on ccip.chain.link
    function initiateTransfer(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address receiver,
        uint64 destinationChainSelector,
        uint256 slippageBps,
        uint24 poolFee
    ) external nonReentrant returns (bytes32 ccipMessageId) {
        // ── Guard checks ─────────────────────────────────────────────────────

        if (tokenIn == address(0)) revert ZeroAddress();
        if (tokenOut == address(0)) revert ZeroAddress();
        if (receiver == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert ZeroAmount();
        if (destinationChainSelector == 0) revert InvalidChainSelector(0);

        if (address(securityManager) == address(0)) revert SecurityManagerNotSet();
        if (address(tokenVerifier) == address(0)) revert TokenVerifierNotSet();
        if (address(swapAdapter) == address(0)) revert SwapAdapterNotSet();

        // ── Step 1: Security check ────────────────────────────────────────────

        if (securityManager.paused()) revert SystemPaused();

        // validateTransfer reverts if check fails (ENFORCE mode) or
        // logs an incident (MONITOR mode) — either way we proceed only if it returns
        securityManager.validateTransfer(msg.sender, FEATURE_ID, tokenIn, amountIn);

        emit SecurityCheckPassed(msg.sender, tokenIn, amountIn);

        // ── Step 2: Token verification ────────────────────────────────────────

        if (!_isVerifiedTokenStatus(tokenVerifier.verifyTokenLayer1(tokenIn))) {
            revert TokenInNotVerified(tokenIn);
        }
        if (!_isVerifiedTokenStatus(tokenVerifier.verifyTokenLayer1(tokenOut))) {
            revert TokenOutNotVerified(tokenOut);
        }
        if (!tokenVerifier.isTransferSafe(tokenIn, amountIn)) {
            revert TransferNotSafe(tokenIn, amountIn);
        }

        emit TokenVerificationPassed(msg.sender, tokenIn, tokenOut);

        // ── Step 3: Pull tokenIn from sender ──────────────────────────────────

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // ── Step 4: Swap (or passthrough if same token) ───────────────────────

        uint256 amountOut;

        if (tokenIn == tokenOut) {
            // No swap needed — approve SwapAdapter to pull and pass through
            IERC20(tokenIn).forceApprove(address(swapAdapter), amountIn);
            amountOut = swapAdapter.passthrough(tokenIn, amountIn, address(this));
            IERC20(tokenIn).forceApprove(address(swapAdapter), 0);
        } else {
            // Approve SwapAdapter to pull tokenIn, swap → tokenOut lands here
            IERC20(tokenIn).forceApprove(address(swapAdapter), amountIn);
            amountOut = swapAdapter.swap(
                tokenIn,
                tokenOut,
                amountIn,
                address(this), // tokenOut lands in Gateway first
                slippageBps,
                poolFee
            );
            IERC20(tokenIn).forceApprove(address(swapAdapter), 0);
        }

        emit SwapCompleted(tokenIn, tokenOut, amountIn, amountOut);

        // ── Step 5: CCIP bridge ───────────────────────────────────────────────

        ccipMessageId = _bridgeViaCCIP(tokenOut, amountOut, receiver, destinationChainSelector);

        // ── Emit and return ───────────────────────────────────────────────────

        uint256 nonce = ++nonces[msg.sender];

        emit TransferInitiated(
            ccipMessageId, msg.sender, receiver, destinationChainSelector, tokenIn, tokenOut, amountIn, amountOut, nonce
        );
    }

    // ── Internal: CCIP bridge ─────────────────────────────────────────────────

    function _bridgeViaCCIP(address token, uint256 amount, address receiver, uint64 destinationChainSelector)
        internal
        returns (bytes32 messageId)
    {
        // Build CCIP token transfer array
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: token, amount: amount});

        // Build CCIP message — no extra data payload for basic transfers
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: "",
            tokenAmounts: tokenAmounts,
            feeToken: address(linkToken),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 200_000}))
        });

        // Check LINK fee
        uint256 fee = ccipRouter.getFee(destinationChainSelector, message);
        uint256 linkBalance = linkToken.balanceOf(address(this));
        if (linkBalance < fee) {
            revert InsufficientLinkBalance(fee, linkBalance);
        }

        // Approve router to spend tokenOut and LINK fee
        IERC20(token).forceApprove(address(ccipRouter), amount);
        linkToken.forceApprove(address(ccipRouter), fee);

        // Send via CCIP
        messageId = ccipRouter.ccipSend(destinationChainSelector, message);

        // Clear approvals
        IERC20(token).forceApprove(address(ccipRouter), 0);
        linkToken.forceApprove(address(ccipRouter), 0);
    }

    // ── Fee estimation (view) ─────────────────────────────────────────────────

    /// @notice Returns the LINK fee the gateway will pay for a given transfer.
    ///         Call this from the frontend before asking the user to sign.
    function estimateFee(address tokenOut, uint256 amountOut, address receiver, uint64 destinationChainSelector)
        external
        view
        returns (uint256 linkFee)
    {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: tokenOut, amount: amountOut});

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: "",
            tokenAmounts: tokenAmounts,
            feeToken: address(linkToken),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 200_000}))
        });

        linkFee = ccipRouter.getFee(destinationChainSelector, message);
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    /// @notice Fund this contract with LINK to pay CCIP fees.
    ///         Anyone can call this (users, owner, protocol treasury).
    function depositLink(uint256 amount) external {
        linkToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Withdraw LINK from this contract (owner only).
    function withdrawLink(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        linkToken.safeTransfer(to, amount);
    }

    /// @notice Recover any ERC-20 accidentally sent to this contract.
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Returns the gateway's current LINK balance.
    function getLinkBalance() external view returns (uint256) {
        return linkToken.balanceOf(address(this));
    }

    function _isVerifiedTokenStatus(uint8 status) internal pure returns (bool) {
        return status == TOKEN_STATUS_SAFE || status == TOKEN_STATUS_ALLOWLISTED;
    }
}
