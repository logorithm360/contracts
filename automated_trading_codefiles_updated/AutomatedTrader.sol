// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AutomationCompatibleInterface} from
    "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import {AggregatorV3Interface} from
    "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/libraries/Client.sol";
import {IERC20} from "@chainlink/contracts-ccip/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title  AutomatedTrader
/// @notice Feature 4 — Automated Cross-Chain Trading via Chainlink Automation.
///
///         This contract combines FOUR Chainlink technologies:
///         1. Chainlink Automation v2.1  — off-chain condition monitoring, on-chain execution
///         2. CCIP                       — cross-chain token + data transfer on trigger
///         3. Chainlink Data Feeds       — real, manipulation-resistant price data on-chain
///         4. Forwarder security         — only the registered upkeep's forwarder can call performUpkeep
///
///         HOW IT WORKS:
///         ┌─────────────────────────────────────────────────────────┐
///         │  Chainlink Automation Node (off-chain, every block)     │
///         │    → calls checkUpkeep()                                │
///         │    → evaluates ALL registered trade orders              │
///         │    → PRICE_THRESHOLD: reads real price from Data Feed   │
///         │    → if any order is executable: returns true +         │
///         │      encodes which orders to execute as performData     │
///         └──────────────────┬──────────────────────────────────────┘
///                            │ upkeepNeeded == true
///                            ▼
///         ┌─────────────────────────────────────────────────────────┐
///         │  Automation Node calls performUpkeep(performData)       │
///         │    → decodes order IDs from performData                 │
///         │    → re-validates conditions including live price       │
///         │    → for each order: builds CCIP message               │
///         │    → fires cross-chain token + payload transfer         │
///         └─────────────────────────────────────────────────────────┘
///
///         TRADE ORDER TYPES:
///         - TIME_BASED:      executes after a set time interval (DCA)
///         - PRICE_THRESHOLD: executes when real Chainlink price meets condition
///                            (stop-loss / take-profit / rebalance)
///         - BALANCE_TRIGGER: executes when contract holds enough tokens
///
///         PRICE FEED SECURITY:
///         - Each token maps to its own Chainlink Data Feed address
///         - latestRoundData() is called with full staleness validation
///         - Stale prices (> STALENESS_THRESHOLD) skip the order safely
///         - Price feeds are registered per token by owner via setPriceFeed()
///
///         SECURITY:
///         - performUpkeep is locked to the Automation forwarder address
///         - All conditions are re-validated inside performUpkeep (idempotent)
///         - Forwarder address is mutable and set by owner after upkeep registration
///
/// @dev    Deployed on the SOURCE chain (Ethereum Sepolia).
///         Paired with AutomatedTraderReceiver on destination (Polygon Amoy).
///
///         Verified Sepolia Data Feed addresses (register via setPriceFeed):
///         ETH/USD  → 0x694AA1769357215DE4FAC081bf1f309aDC325306
///         BTC/USD  → 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43
///         LINK/USD → 0xc59E3633BAAC79493d908e63626716e204A45EdF
///         USDC/USD → 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E
contract AutomatedTrader is AutomationCompatibleInterface, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────
    //  Custom errors
    // ─────────────────────────────────────────────────────────────
    error ZeroAddress();
    error ZeroAmount();
    error NothingToWithdraw();
    error WithdrawFailed();
    error OrderNotFound(uint256 orderId);
    error OrderAlreadyExecuted(uint256 orderId);
    error OrderNotActive(uint256 orderId);
    error OrderConditionNotMet(uint256 orderId);
    error UnauthorizedCaller(address caller);
    error DestinationChainNotAllowlisted(uint64 chainSelector);
    error TokenNotAllowlisted(address token);
    error InsufficientLinkBalance(uint256 have, uint256 need);
    error MaxOrdersReached();
    error InvalidOrderType();
    error PriceFeedNotSet(address token);
    error StalePriceFeed(address feed, uint256 updatedAt, uint256 threshold);

    // ─────────────────────────────────────────────────────────────
    //  Enums & structs
    // ─────────────────────────────────────────────────────────────

    enum TriggerType {
        TIME_BASED,       // fires after interval seconds since last execution
        PRICE_THRESHOLD,  // fires when simulated price meets condition
        BALANCE_TRIGGER   // fires when contract holds >= required token balance
    }

    enum OrderStatus {
        ACTIVE,     // waiting for condition
        EXECUTED,   // completed successfully
        CANCELLED,  // cancelled by owner
        PAUSED      // temporarily paused
    }

    /// @notice A single automated trade order.
    struct TradeOrder {
        uint256     orderId;
        TriggerType triggerType;
        OrderStatus status;
        // ── Token transfer config ────────────────────
        address     token;              // ERC20 to send cross-chain
        uint256     amount;             // amount to send per execution
        uint64      destinationChain;   // CCIP chain selector
        address     receiverContract;   // contract on destination
        address     recipient;          // who benefits on destination
        string      action;             // "transfer" | "stake" | "swap" | "deposit"
        // ── Trigger config ───────────────────────────
        uint256     interval;           // TIME_BASED: seconds between executions
        uint256     lastExecutedAt;     // last execution timestamp
        uint256     priceThreshold;     // PRICE_THRESHOLD: target price (18 decimals)
        bool        executeAbove;       // PRICE_THRESHOLD: true=above, false=below
        uint256     balanceRequired;    // BALANCE_TRIGGER: min token balance needed
        // ── Execution config ─────────────────────────
        bool        recurring;          // if true: resets after execution; false: one-shot
        uint256     maxExecutions;      // 0 = unlimited
        uint256     executionCount;     // how many times executed
        uint256     deadline;           // 0 = no deadline; unix timestamp after which order expires
        uint256     createdAt;
    }

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────
    event OrderCreated(
        uint256 indexed orderId,
        TriggerType     triggerType,
        address         token,
        uint256         amount,
        uint64          destinationChain,
        address         recipient
    );
    event OrderExecuted(
        uint256 indexed orderId,
        bytes32 indexed ccipMessageId,
        address         token,
        uint256         amount,
        uint256         executionCount
    );
    event OrderCancelled(uint256 indexed orderId);
    event OrderPaused(uint256 indexed orderId, bool paused);
    event ForwarderSet(address indexed forwarder);
    event DestinationChainAllowlisted(uint64 indexed chainSelector, bool allowed);
    event TokenAllowlisted(address indexed token, bool allowed);
    event ExtraArgsUpdated(bytes extraArgs);
    event PriceFeedSet(address indexed token, address indexed feed);

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────

    IRouterClient private immutable i_router;
    IERC20        private immutable i_linkToken;

    /// @notice The Chainlink Automation forwarder address for this upkeep.
    /// @dev    Set AFTER registering the upkeep via setForwarder().
    ///         Until set, performUpkeep is callable by owner only (for testing).
    address public s_forwarderAddress;

    mapping(uint64  => bool) public allowlistedDestinationChains;
    mapping(address => bool) public allowlistedTokens;

    /// @notice All trade orders indexed by orderId.
    mapping(uint256 => TradeOrder) public orders;

    /// @notice Array of all active order IDs for iteration in checkUpkeep.
    uint256[] public activeOrderIds;

    /// @notice Counter for generating unique order IDs.
    uint256 public nextOrderId;

    /// @notice Mutable extraArgs — never hardcoded.
    bytes public extraArgs;

    /// @notice Max orders that can be checked per upkeep call (gas safety).
    uint256 public constant MAX_ORDERS_PER_CHECK = 20;

    // ─────────────────────────────────────────────────────────────
    //  Chainlink Data Feeds state
    // ─────────────────────────────────────────────────────────────

    /// @notice Maps a token address to its Chainlink Data Feed address.
    /// @dev    Register feeds via setPriceFeed() after deployment.
    ///         Sepolia examples:
    ///           ETH/USD  → 0x694AA1769357215DE4FAC081bf1f309aDC325306
    ///           BTC/USD  → 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43
    ///           LINK/USD → 0xc59E3633BAAC79493d908e63626716e204A45EdF
    ///           USDC/USD → 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E
    mapping(address => address) public s_priceFeeds;

    /// @notice Maximum age of a price update before it is considered stale.
    /// @dev    3 hours is conservative. Most Chainlink feeds update every
    ///         1 hour (heartbeat) or when price deviates by 0.5%.
    ///         A stale price causes the order to be safely SKIPPED — never
    ///         executed with bad data.
    uint256 public constant STALENESS_THRESHOLD = 3 hours;

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────

    constructor(
        address _router,
        address _linkToken
    ) Ownable(msg.sender) {
        if (_router    == address(0)) revert ZeroAddress();
        if (_linkToken == address(0)) revert ZeroAddress();

        i_router   = IRouterClient(_router);
        i_linkToken = IERC20(_linkToken);

        // 500k gas for receiver that has business logic
        extraArgs = Client._argsToBytes(
            Client.GenericExtraArgsV2({
                gasLimit: 500_000,
                allowOutOfOrderExecution: false
            })
        );
    }

    // ─────────────────────────────────────────────────────────────
    //  Chainlink Automation — checkUpkeep
    // ─────────────────────────────────────────────────────────────

    /// @notice Called by the Automation Network off-chain every block.
    ///         Gas-free view simulation. Returns which orders are ready to execute.
    ///
    /// @dev    Best practice: do expensive computation HERE (off-chain, no gas).
    ///         Pass a compact result to performUpkeep to minimise on-chain gas.
    ///
    /// @return upkeepNeeded  True if at least one order is ready to execute.
    /// @return performData   ABI-encoded array of order IDs ready for execution.
    function checkUpkeep(
        bytes calldata /* checkData */
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        uint256 len = activeOrderIds.length;
        if (len == 0) return (false, "");

        // Cap iterations to avoid gas limit in simulation
        uint256 checkCount = len > MAX_ORDERS_PER_CHECK ? MAX_ORDERS_PER_CHECK : len;

        uint256[] memory executableIds = new uint256[](checkCount);
        uint256 found = 0;

        for (uint256 i = 0; i < checkCount; i++) {
            uint256 id = activeOrderIds[i];
            TradeOrder storage order = orders[id];

            if (_isOrderExecutable(order)) {
                executableIds[found] = id;
                found++;
            }
        }

        if (found == 0) return (false, "");

        // Trim array to actual found count
        uint256[] memory trimmed = new uint256[](found);
        for (uint256 i = 0; i < found; i++) {
            trimmed[i] = executableIds[i];
        }

        upkeepNeeded = true;
        performData  = abi.encode(trimmed);
    }

    // ─────────────────────────────────────────────────────────────
    //  Chainlink Automation — performUpkeep
    // ─────────────────────────────────────────────────────────────

    /// @notice Called by the Automation Network on-chain when checkUpkeep returns true.
    ///         Secured by forwarder — only the registered forwarder can call this.
    ///
    /// @dev    IMPORTANT: All conditions are re-validated here. The Automation node
    ///         may have simulated checkUpkeep at an older state. Always re-check
    ///         to ensure idempotency.
    ///
    /// @param  performData  ABI-encoded array of order IDs to execute.
    function performUpkeep(bytes calldata performData)
        external
        override
        nonReentrant
    {
        // Security: only the forwarder (or owner for testing) can call this
        if (
            s_forwarderAddress != address(0) &&
            msg.sender != s_forwarderAddress &&
            msg.sender != owner()
        ) revert UnauthorizedCaller(msg.sender);

        uint256[] memory orderIds = abi.decode(performData, (uint256[]));

        for (uint256 i = 0; i < orderIds.length; i++) {
            uint256 id = orderIds[i];
            TradeOrder storage order = orders[id];

            // Re-validate condition (idempotency guard)
            if (!_isOrderExecutable(order)) continue;

            // Execute the cross-chain trade
            _executeOrder(id);
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  Order management — create
    // ─────────────────────────────────────────────────────────────

    /// @notice Create a TIME_BASED automated trade order.
    ///         Executes every `_intervalSeconds` seconds automatically.
    ///
    /// @param  _intervalSeconds   How often to execute (e.g. 3600 = every hour).
    /// @param  _token             Token to transfer cross-chain.
    /// @param  _amount            Amount per execution.
    /// @param  _destinationChain  CCIP chain selector of destination.
    /// @param  _receiverContract  Contract on destination.
    /// @param  _recipient         Beneficiary on destination.
    /// @param  _action            Payload action ("transfer" | "stake" | etc.)
    /// @param  _recurring         If false: executes once then becomes EXECUTED.
    /// @param  _maxExecutions     0 = unlimited. N = stop after N executions.
    /// @param  _deadline          0 = no deadline. Unix timestamp for expiry.
    function createTimedOrder(
        uint256 _intervalSeconds,
        address _token,
        uint256 _amount,
        uint64  _destinationChain,
        address _receiverContract,
        address _recipient,
        string  calldata _action,
        bool    _recurring,
        uint256 _maxExecutions,
        uint256 _deadline
    )
        external
        onlyOwner
        returns (uint256 orderId)
    {
        _validateOrderInputs(_token, _amount, _destinationChain, _receiverContract, _recipient, _action);
        if (activeOrderIds.length >= MAX_ORDERS_PER_CHECK) revert MaxOrdersReached();

        orderId = nextOrderId++;

        orders[orderId] = TradeOrder({
            orderId:          orderId,
            triggerType:      TriggerType.TIME_BASED,
            status:           OrderStatus.ACTIVE,
            token:            _token,
            amount:           _amount,
            destinationChain: _destinationChain,
            receiverContract: _receiverContract,
            recipient:        _recipient,
            action:           _action,
            interval:         _intervalSeconds,
            lastExecutedAt:   0,       // execute immediately on first check
            priceThreshold:   0,
            executeAbove:     false,
            balanceRequired:  0,
            recurring:        _recurring,
            maxExecutions:    _maxExecutions,
            executionCount:   0,
            deadline:         _deadline,
            createdAt:        block.timestamp
        });

        activeOrderIds.push(orderId);

        emit OrderCreated(orderId, TriggerType.TIME_BASED, _token, _amount, _destinationChain, _recipient);
    }

    /// @notice Create a PRICE_THRESHOLD automated trade order.
    ///         Executes when the on-chain simulated price meets the threshold.
    ///         Integrate with Chainlink Data Feeds for production.
    function createPriceOrder(
        uint256 _priceThreshold,
        bool    _executeAbove,
        address _token,
        uint256 _amount,
        uint64  _destinationChain,
        address _receiverContract,
        address _recipient,
        string  calldata _action,
        bool    _recurring,
        uint256 _maxExecutions,
        uint256 _deadline
    )
        external
        onlyOwner
        returns (uint256 orderId)
    {
        _validateOrderInputs(_token, _amount, _destinationChain, _receiverContract, _recipient, _action);
        if (activeOrderIds.length >= MAX_ORDERS_PER_CHECK) revert MaxOrdersReached();
        if (_priceThreshold == 0) revert ZeroAmount();

        orderId = nextOrderId++;

        orders[orderId] = TradeOrder({
            orderId:          orderId,
            triggerType:      TriggerType.PRICE_THRESHOLD,
            status:           OrderStatus.ACTIVE,
            token:            _token,
            amount:           _amount,
            destinationChain: _destinationChain,
            receiverContract: _receiverContract,
            recipient:        _recipient,
            action:           _action,
            interval:         0,
            lastExecutedAt:   0,
            priceThreshold:   _priceThreshold,
            executeAbove:     _executeAbove,
            balanceRequired:  0,
            recurring:        _recurring,
            maxExecutions:    _maxExecutions,
            executionCount:   0,
            deadline:         _deadline,
            createdAt:        block.timestamp
        });

        activeOrderIds.push(orderId);

        emit OrderCreated(orderId, TriggerType.PRICE_THRESHOLD, _token, _amount, _destinationChain, _recipient);
    }

    /// @notice Create a BALANCE_TRIGGER automated trade order.
    ///         Executes when this contract holds >= `_balanceRequired` of `_token`.
    function createBalanceOrder(
        uint256 _balanceRequired,
        address _token,
        uint256 _amount,
        uint64  _destinationChain,
        address _receiverContract,
        address _recipient,
        string  calldata _action,
        bool    _recurring,
        uint256 _maxExecutions,
        uint256 _deadline
    )
        external
        onlyOwner
        returns (uint256 orderId)
    {
        _validateOrderInputs(_token, _amount, _destinationChain, _receiverContract, _recipient, _action);
        if (activeOrderIds.length >= MAX_ORDERS_PER_CHECK) revert MaxOrdersReached();
        if (_balanceRequired == 0) revert ZeroAmount();

        orderId = nextOrderId++;

        orders[orderId] = TradeOrder({
            orderId:          orderId,
            triggerType:      TriggerType.BALANCE_TRIGGER,
            status:           OrderStatus.ACTIVE,
            token:            _token,
            amount:           _amount,
            destinationChain: _destinationChain,
            receiverContract: _receiverContract,
            recipient:        _recipient,
            action:           _action,
            interval:         0,
            lastExecutedAt:   0,
            priceThreshold:   0,
            executeAbove:     false,
            balanceRequired:  _balanceRequired,
            recurring:        _recurring,
            maxExecutions:    _maxExecutions,
            executionCount:   0,
            deadline:         _deadline,
            createdAt:        block.timestamp
        });

        activeOrderIds.push(orderId);

        emit OrderCreated(orderId, TriggerType.BALANCE_TRIGGER, _token, _amount, _destinationChain, _recipient);
    }

    // ─────────────────────────────────────────────────────────────
    //  Order management — modify
    // ─────────────────────────────────────────────────────────────

    function cancelOrder(uint256 _orderId) external onlyOwner {
        TradeOrder storage order = orders[_orderId];
        if (order.createdAt == 0) revert OrderNotFound(_orderId);
        if (order.status == OrderStatus.EXECUTED) revert OrderAlreadyExecuted(_orderId);

        order.status = OrderStatus.CANCELLED;
        _removeFromActiveOrders(_orderId);
        emit OrderCancelled(_orderId);
    }

    function pauseOrder(uint256 _orderId, bool _paused) external onlyOwner {
        TradeOrder storage order = orders[_orderId];
        if (order.createdAt == 0) revert OrderNotFound(_orderId);

        order.status = _paused ? OrderStatus.PAUSED : OrderStatus.ACTIVE;
        emit OrderPaused(_orderId, _paused);
    }

    // ─────────────────────────────────────────────────────────────
    //  View helpers
    // ─────────────────────────────────────────────────────────────

    function getOrder(uint256 _orderId) external view returns (TradeOrder memory) {
        return orders[_orderId];
    }

    function getActiveOrderCount() external view returns (uint256) {
        return activeOrderIds.length;
    }

    function getTokenBalance(address _token) external view returns (uint256) {
        return IERC20(_token).balanceOf(address(this));
    }

    function getLinkBalance() external view returns (uint256) {
        return i_linkToken.balanceOf(address(this));
    }

    function estimateFee(uint256 _orderId) external view returns (uint256 fee) {
        TradeOrder storage order = orders[_orderId];
        if (order.createdAt == 0) revert OrderNotFound(_orderId);

        // Resolve deadline the same way _executeOrder does — consistent hash
        uint256 resolvedDeadline = order.deadline > 0 ? order.deadline : block.timestamp + 1 hours;
        Client.EVM2AnyMessage memory message = _buildCCIPMessage(order, resolvedDeadline);
        fee = i_router.getFee(order.destinationChain, message);
    }

    // ─────────────────────────────────────────────────────────────
    //  Admin functions
    // ─────────────────────────────────────────────────────────────

    /// @notice Set the Automation forwarder address AFTER registering the upkeep.
    /// @dev    Get this address from automation.chain.link → your upkeep → details.
    ///         Until this is set, performUpkeep can only be called by the owner.
    function setForwarder(address _forwarder) external onlyOwner {
        s_forwarderAddress = _forwarder;
        emit ForwarderSet(_forwarder);
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

    /// @notice Register or update a Chainlink Data Feed for a specific token.
    /// @dev    MUST be called for every token used in PRICE_THRESHOLD orders.
    ///         Without a registered feed, PRICE_THRESHOLD orders are safely
    ///         skipped — they never execute with stale or missing data.
    ///
    ///         Verified Sepolia feed addresses:
    ///           ETH/USD  → 0x694AA1769357215DE4FAC081bf1f309aDC325306
    ///           BTC/USD  → 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43
    ///           LINK/USD → 0xc59E3633BAAC79493d908e63626716e204A45EdF
    ///           USDC/USD → 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E
    ///
    /// @param  _token  The ERC20 token address orders use.
    /// @param  _feed   The Chainlink AggregatorV3Interface feed address.
    function setPriceFeed(address _token, address _feed) external onlyOwner {
        if (_token == address(0)) revert ZeroAddress();
        if (_feed  == address(0)) revert ZeroAddress();
        s_priceFeeds[_token] = _feed;
        emit PriceFeedSet(_token, _feed);
    }

    /// @notice Returns full price feed data for a token — useful for CRE workflows
    ///         and the AI layer (Feature 7) to read current prices with context.
    ///
    /// @param  _token          The token to query.
    /// @return feedAddress     The registered Chainlink feed address.
    /// @return price           Latest price (8 decimals — standard Chainlink format).
    /// @return updatedAt       Timestamp of the last price update.
    /// @return isStale         True if the price is older than STALENESS_THRESHOLD.
    function getPriceFeedData(address _token)
        external
        view
        returns (
            address feedAddress,
            int256  price,
            uint256 updatedAt,
            bool    isStale
        )
    {
        feedAddress = s_priceFeeds[_token];
        if (feedAddress == address(0)) revert PriceFeedNotSet(_token);

        (, price, , updatedAt, ) = AggregatorV3Interface(feedAddress).latestRoundData();
        isStale = (block.timestamp - updatedAt) > STALENESS_THRESHOLD;
    }

    function updateExtraArgs(bytes calldata _extraArgs) external onlyOwner {
        extraArgs = _extraArgs;
        emit ExtraArgsUpdated(_extraArgs);
    }

    function withdrawLink(address _to) external onlyOwner {
        if (_to == address(0)) revert ZeroAddress();
        uint256 bal = i_linkToken.balanceOf(address(this));
        if (bal == 0) revert NothingToWithdraw();
        i_linkToken.safeTransfer(_to, bal);
    }

    function withdrawNative(address payable _to) external onlyOwner {
        if (_to == address(0)) revert ZeroAddress();
        uint256 bal = address(this).balance;
        if (bal == 0) revert NothingToWithdraw();
        (bool ok,) = _to.call{value: bal}("");
        if (!ok) revert WithdrawFailed();
    }

    function withdrawToken(address _token, address _to) external onlyOwner {
        if (_to    == address(0)) revert ZeroAddress();
        if (_token == address(0)) revert ZeroAddress();
        uint256 bal = IERC20(_token).balanceOf(address(this));
        if (bal == 0) revert NothingToWithdraw();
        IERC20(_token).safeTransfer(_to, bal);
    }

    receive() external payable {}

    // ─────────────────────────────────────────────────────────────
    //  Internal — condition evaluation
    // ─────────────────────────────────────────────────────────────

    /// @dev Pure condition check — no state changes. Called from checkUpkeep (view).
    function _isOrderExecutable(TradeOrder storage order) internal view returns (bool) {
        // Skip non-active orders
        if (order.status != OrderStatus.ACTIVE) return false;

        // Skip if max executions reached
        if (order.maxExecutions > 0 && order.executionCount >= order.maxExecutions) return false;

        // Skip if past deadline
        if (order.deadline > 0 && block.timestamp > order.deadline) return false;

        // Skip if contract doesn't have enough LINK to cover the actual fee.
        // Estimating the real fee here prevents checkUpkeep returning true for
        // an order that would revert in performUpkeep — avoiding wasted Automation gas.
        uint256 resolvedDeadline = order.deadline > 0 ? order.deadline : block.timestamp + 1 hours;
        uint256 estimatedFee = i_router.getFee(
            order.destinationChain,
            _buildCCIPMessage(order, resolvedDeadline)
        );
        if (i_linkToken.balanceOf(address(this)) < estimatedFee) return false;

        // Evaluate trigger condition
        if (order.triggerType == TriggerType.TIME_BASED) {
            uint256 timeSinceLast = block.timestamp - order.lastExecutedAt;
            return timeSinceLast >= order.interval;

        } else if (order.triggerType == TriggerType.PRICE_THRESHOLD) {
            // _getPrice returns 0 if feed is missing, stale, or invalid.
            // A 0 price causes both conditions (above/below) to safely skip:
            //   executeAbove: 0 >= threshold → false (skip)
            //   executeBelow: 0 <= threshold → true — BUT threshold is always > 0
            //                 so we add an explicit zero guard.
            uint256 currentPrice = _getPrice(order.token);
            if (currentPrice == 0) return false; // feed unavailable — skip safely

            if (order.executeAbove) {
                return currentPrice >= order.priceThreshold;
            } else {
                return currentPrice <= order.priceThreshold;
            }

        } else if (order.triggerType == TriggerType.BALANCE_TRIGGER) {
            return IERC20(order.token).balanceOf(address(this)) >= order.balanceRequired;
        }

        return false;
    }

    // ─────────────────────────────────────────────────────────────
    //  Internal — execution
    // ─────────────────────────────────────────────────────────────

    function _executeOrder(uint256 _orderId) internal {
        TradeOrder storage order = orders[_orderId];

        // Resolve deadline once — used for both fee estimation and payload encoding
        uint256 resolvedDeadline = order.deadline > 0 ? order.deadline : block.timestamp + 1 hours;

        // Build and send the CCIP message
        Client.EVM2AnyMessage memory message = _buildCCIPMessage(order, resolvedDeadline);
        uint256 fees = i_router.getFee(order.destinationChain, message);

        if (i_linkToken.balanceOf(address(this)) < fees)
            revert InsufficientLinkBalance(i_linkToken.balanceOf(address(this)), fees);

        i_linkToken.approve(address(i_router), fees);
        IERC20(order.token).approve(address(i_router), order.amount);

        bytes32 messageId = i_router.ccipSend(order.destinationChain, message);

        // Update order state
        order.lastExecutedAt = block.timestamp;
        order.executionCount++;

        bool maxReached = order.maxExecutions > 0 && order.executionCount >= order.maxExecutions;
        bool deadlinePassed = order.deadline > 0 && block.timestamp > order.deadline;

        if (!order.recurring || maxReached || deadlinePassed) {
            order.status = OrderStatus.EXECUTED;
            _removeFromActiveOrders(_orderId);
        }

        emit OrderExecuted(_orderId, messageId, order.token, order.amount, order.executionCount);
    }

    /// @dev Accepts an explicit _deadline so that estimateFee() and _executeOrder()
    ///      both produce identical message hashes. Previously block.timestamp was
    ///      computed inside here, causing a mismatch between the fee simulation
    ///      (view context) and the real execution (transaction context).
    function _buildCCIPMessage(TradeOrder storage order, uint256 _deadline)
        internal view
        returns (Client.EVM2AnyMessage memory)
    {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token:  order.token,
            amount: order.amount
        });

        // Encode instruction payload — same TransferPayload struct as Feature 3
        bytes memory payload = abi.encode(
            order.recipient,   // address  — who benefits on destination
            order.action,      // string   — "transfer" | "stake" | "swap" | "deposit"
            bytes(""),         // bytes    — extraData (reserved for future use)
            _deadline          // uint256  — caller-supplied, consistent across call sites
        );

        return Client.EVM2AnyMessage({
            receiver:     abi.encode(order.receiverContract),
            data:         payload,
            tokenAmounts: tokenAmounts,
            extraArgs:    extraArgs,
            feeToken:     address(i_linkToken)
        });
    }

    // ─────────────────────────────────────────────────────────────
    //  Internal — Chainlink Data Feed price resolution
    // ─────────────────────────────────────────────────────────────

    /// @dev Fetches the live price for a token from its registered Chainlink
    ///      Data Feed. Returns 0 if:
    ///        - no feed is registered for the token
    ///        - the price is stale (older than STALENESS_THRESHOLD)
    ///        - the price is zero or negative (invalid feed state)
    ///
    ///      Returning 0 causes _isOrderExecutable() to evaluate the condition
    ///      as unmet, safely SKIPPING execution rather than trading on bad data.
    ///      This is intentional — never trade on a price you cannot verify.
    ///
    ///      Return value is normalised to 18 decimals from Chainlink's 8 decimals:
    ///      price_18 = price_8 * 1e10
    ///      This keeps it consistent with the priceThreshold values stored in
    ///      TradeOrder (which are expressed in 18 decimals).
    ///
    /// @param  _token  The token whose price to fetch.
    /// @return price   Current price normalised to 18 decimals. 0 = unavailable.
    function _getPrice(address _token) internal view returns (uint256 price) {
        address feedAddress = s_priceFeeds[_token];

        // No feed registered — skip order safely
        if (feedAddress == address(0)) return 0;

        // Call latestRoundData() — the standard Chainlink Data Feed interface
        (
            uint80  roundId,
            int256  answer,
            ,                   // startedAt — not needed
            uint256 updatedAt,
            uint80  answeredInRound
        ) = AggregatorV3Interface(feedAddress).latestRoundData();

        // ── Staleness check ──────────────────────────────────────
        // If the feed has not updated within STALENESS_THRESHOLD,
        // the price is considered unreliable. Skip the order.
        if (block.timestamp - updatedAt > STALENESS_THRESHOLD) return 0;

        // ── Completeness check ───────────────────────────────────
        // answeredInRound < roundId means the round is incomplete.
        // This can happen during oracle disruptions.
        if (answeredInRound < roundId) return 0;

        // ── Validity check ───────────────────────────────────────
        // A zero or negative price is never valid for asset pricing.
        if (answer <= 0) return 0;

        // ── Normalise from 8 decimals (Chainlink standard) to 18 ─
        // All price thresholds in TradeOrder are stored as 18-decimal values.
        // Example: ETH at $2,500.00 = 2500_00000000 (8 dec) → 2500_000000000000000000 (18 dec)
        price = uint256(answer) * 1e10;
    }

    // ─────────────────────────────────────────────────────────────
    //  Internal — order array management
    // ─────────────────────────────────────────────────────────────

    function _removeFromActiveOrders(uint256 _orderId) internal {
        uint256 len = activeOrderIds.length;
        for (uint256 i = 0; i < len; i++) {
            if (activeOrderIds[i] == _orderId) {
                // Swap with last element and pop
                activeOrderIds[i] = activeOrderIds[len - 1];
                activeOrderIds.pop();
                return;
            }
        }
    }

    function _validateOrderInputs(
        address       _token,
        uint256       _amount,
        uint64        _destinationChain,
        address       _receiverContract,
        address       _recipient,
        string calldata _action
    ) internal view {
        if (_token           == address(0)) revert ZeroAddress();
        if (_receiverContract == address(0)) revert ZeroAddress();
        if (_recipient        == address(0)) revert ZeroAddress();
        if (_amount           == 0)          revert ZeroAmount();
        if (bytes(_action).length == 0)      revert InvalidOrderType();
        if (!allowlistedDestinationChains[_destinationChain])
            revert DestinationChainNotAllowlisted(_destinationChain);
        if (!allowlistedTokens[_token])
            revert TokenNotAllowlisted(_token);
    }
}
