// SPDX-License-Identifier: MIT
pragma solidity =0.8.33;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  Uniswap V3 minimal interfaces
// ─────────────────────────────────────────────────────────────────────────────

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut);
}

// ─────────────────────────────────────────────────────────────────────────────
//  SwapAdapter
//
//  Wraps Uniswap V3 exactInputSingle for ChainShield's pre-bridge swap step.
//
//  Security model:
//    - Only authorised callers (ChainShieldGateway) can call `swap()`
//    - Owner can update the router address and pool fee tiers
//    - Slippage is enforced via `amountOutMinimum` computed from `maxSlippageBps`
//    - No tokens are ever held by this contract — input pulled → swapped → output
//      sent directly to `recipient` in one call
// ─────────────────────────────────────────────────────────────────────────────

contract SwapAdapter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Storage ──────────────────────────────────────────────────────────────

    ISwapRouter public swapRouter;

    /// @dev Default Uniswap V3 pool fee: 0.3 % (3000 bps)
    uint24 public defaultPoolFee = 3000;

    /// @dev Maximum allowed slippage in basis points (1 bps = 0.01%)
    ///      Owner can adjust; default is 50 bps (0.5%)
    uint256 public maxSlippageBps = 50;

    /// @dev Addresses authorised to call swap() — only ChainShieldGateway
    mapping(address => bool) public authorisedCallers;

    // ── Events ───────────────────────────────────────────────────────────────

    event Swapped(
        address indexed caller,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address recipient
    );

    event CallerAuthorised(address indexed caller, bool authorised);
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event DefaultPoolFeeUpdated(uint24 oldFee, uint24 newFee);
    event MaxSlippageUpdated(uint256 oldBps, uint256 newBps);

    // ── Errors ───────────────────────────────────────────────────────────────

    error UnauthorisedCaller(address caller);
    error ZeroAddress();
    error ZeroAmount();
    error SlippageTooHigh(uint256 provided, uint256 maximum);
    error SwapFailed(address tokenIn, address tokenOut, uint256 amountIn);

    // ── Constructor ──────────────────────────────────────────────────────────

    /// @param _router   Uniswap V3 SwapRouter address on this chain
    /// @param _owner    Contract owner (deployer / multisig)
    constructor(address _router, address _owner) Ownable(_owner) {
        if (_router == address(0)) revert ZeroAddress();
        swapRouter = ISwapRouter(_router);
    }

    // ── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyAuthorised() {
        if (!authorisedCallers[msg.sender]) revert UnauthorisedCaller(msg.sender);
        _;
    }

    // ── Core: swap ───────────────────────────────────────────────────────────

    /// @notice Swap `amountIn` of `tokenIn` for `tokenOut` and send result to `recipient`.
    ///
    /// @dev Called exclusively by ChainShieldGateway after all security checks pass.
    ///      Flow:
    ///        1. Gateway approves SwapAdapter to spend tokenIn
    ///        2. SwapAdapter pulls tokenIn from Gateway
    ///        3. SwapAdapter approves Uniswap router to spend tokenIn
    ///        4. Uniswap swaps → tokenOut sent directly to recipient (Gateway or final)
    ///
    /// @param tokenIn      Address of the token the sender holds
    /// @param tokenOut     Address of the token the receiver expects
    /// @param amountIn     Amount of tokenIn to swap
    /// @param recipient    Address to receive tokenOut (typically ChainShieldGateway)
    /// @param slippageBps  Caller-specified slippage tolerance in basis points
    /// @param poolFee      Uniswap pool fee tier (500 / 3000 / 10000); 0 = use default
    ///
    /// @return amountOut   Actual amount of tokenOut received
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient,
        uint256 slippageBps,
        uint24 poolFee
    ) external nonReentrant onlyAuthorised returns (uint256 amountOut) {
        if (tokenIn == address(0)) revert ZeroAddress();
        if (tokenOut == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert ZeroAmount();
        if (slippageBps > maxSlippageBps) revert SlippageTooHigh(slippageBps, maxSlippageBps);

        uint24 fee = poolFee == 0 ? defaultPoolFee : poolFee;

        // Pull tokenIn from the caller (ChainShieldGateway)
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Approve Uniswap router
        IERC20(tokenIn).forceApprove(address(swapRouter), amountIn);

        // Compute minimum acceptable output (slippage guard)
        // amountOutMinimum = amountIn * (10000 - slippageBps) / 10000
        // Note: this is a simplified estimate — in production you'd pull
        // an on-chain price oracle quote here instead.
        uint256 amountOutMinimum = (amountIn * (10_000 - slippageBps)) / 10_000;

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: recipient,
            deadline: block.timestamp + 5 minutes,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: 0
        });

        try swapRouter.exactInputSingle(params) returns (uint256 out) {
            amountOut = out;
        } catch {
            // Reset approval and revert cleanly
            IERC20(tokenIn).forceApprove(address(swapRouter), 0);
            revert SwapFailed(tokenIn, tokenOut, amountIn);
        }

        // Clear any dust approval
        IERC20(tokenIn).forceApprove(address(swapRouter), 0);

        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    // ── Same-token passthrough ────────────────────────────────────────────────

    /// @notice If tokenIn == tokenOut, skip the swap and just transfer.
    ///         ChainShieldGateway calls this when no conversion is needed.
    function passthrough(address token, uint256 amount, address recipient)
        external
        nonReentrant
        onlyAuthorised
        returns (uint256)
    {
        if (token == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransferFrom(msg.sender, recipient, amount);
        return amount;
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    function authoriseCaller(address caller, bool authorised) external onlyOwner {
        if (caller == address(0)) revert ZeroAddress();
        authorisedCallers[caller] = authorised;
        emit CallerAuthorised(caller, authorised);
    }

    function setRouter(address newRouter) external onlyOwner {
        if (newRouter == address(0)) revert ZeroAddress();
        emit RouterUpdated(address(swapRouter), newRouter);
        swapRouter = ISwapRouter(newRouter);
    }

    function setDefaultPoolFee(uint24 fee) external onlyOwner {
        emit DefaultPoolFeeUpdated(defaultPoolFee, fee);
        defaultPoolFee = fee;
    }

    function setMaxSlippageBps(uint256 bps) external onlyOwner {
        require(bps <= 1000, "SwapAdapter: slippage cap is 10%");
        emit MaxSlippageUpdated(maxSlippageBps, bps);
        maxSlippageBps = bps;
    }

    // ── Emergency ────────────────────────────────────────────────────────────

    /// @notice Recover any tokens accidentally sent to this contract.
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }
}
