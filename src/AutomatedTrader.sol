// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {
    AutomationCompatibleInterface
} from "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AutomatedTrader
/// @notice Owner-operated automated cross-chain token execution powered by Chainlink Automation and CCIP.
contract AutomatedTrader is AutomationCompatibleInterface, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error NothingToWithdraw();
    error WithdrawFailed();
    error OrderNotFound(uint256 orderId);
    error OrderAlreadyExecuted(uint256 orderId);
    error UnauthorizedCaller(address caller);
    error DestinationChainNotAllowlisted(uint64 chainSelector);
    error TokenNotAllowlisted(address token);
    error PriceFeedNotAllowlisted(address priceFeed);
    error PriceFeedNotConfigured(address token);
    error InvalidOrderType();
    error MaxOrdersReached();
    error InvalidPriceThreshold();
    error InvalidPriceFeed(address feed);
    error OrderConditionNotMet(uint256 orderId, uint8 reason);
    error InvalidMaxPriceAge();
    error InsufficientLinkBalance(uint256 have, uint256 need);

    enum TriggerType {
        TIME_BASED,
        PRICE_THRESHOLD,
        BALANCE_TRIGGER
    }

    enum OrderStatus {
        ACTIVE,
        EXECUTED,
        CANCELLED,
        PAUSED
    }

    enum SkipReason {
        NONE,
        NOT_FOUND,
        ORDER_NOT_ACTIVE,
        MAX_EXECUTIONS_REACHED,
        DEADLINE_EXPIRED,
        FEE_ESTIMATION_FAILED,
        INSUFFICIENT_LINK,
        TIME_NOT_ELAPSED,
        PRICE_FEED_NOT_SET,
        PRICE_FEED_NOT_ALLOWLISTED,
        PRICE_INVALID,
        PRICE_STALE,
        PRICE_NOT_MET,
        BALANCE_TOO_LOW
    }

    struct TradeOrder {
        uint256 orderId;
        TriggerType triggerType;
        OrderStatus status;
        address token;
        uint256 amount;
        uint64 destinationChain;
        address receiverContract;
        address recipient;
        string action;
        uint256 interval;
        uint256 lastExecutedAt;
        address priceFeed;
        uint8 priceFeedDecimals;
        uint256 priceThreshold;
        bool executeAbove;
        uint256 balanceRequired;
        bool recurring;
        uint256 maxExecutions;
        uint256 executionCount;
        uint256 deadline;
        uint256 createdAt;
        address creator;
    }

    struct CommonOrderConfig {
        address token;
        uint256 amount;
        uint64 destinationChain;
        address receiverContract;
        address recipient;
        string action;
        bool recurring;
        uint256 maxExecutions;
        uint256 deadline;
    }

    // Matches ProgrammableTokenReceiver.TransferPayload layout.
    struct ReceiverTransferPayload {
        address recipient;
        string action;
        bytes extraData;
        uint256 deadline;
    }

    event OrderCreated(
        uint256 indexed orderId,
        TriggerType triggerType,
        address token,
        uint256 amount,
        uint64 destinationChain,
        address recipient,
        address priceFeed
    );
    event OrderExecuted(
        uint256 indexed orderId, bytes32 indexed ccipMessageId, address token, uint256 amount, uint256 executionCount
    );
    event OrderExecutionFailed(uint256 indexed orderId, bytes reason);
    event OrderSkipped(uint256 indexed orderId, SkipReason reason);
    event UpkeepExecutionStarted(uint256 requestedCount, address indexed caller);
    event UpkeepExecutionFinished(uint256 requestedCount, uint256 executedCount, uint256 skippedCount);

    event OrderCancelled(uint256 indexed orderId);
    event OrderPaused(uint256 indexed orderId, bool paused);

    event ForwarderSet(address indexed forwarder);
    event DestinationChainAllowlisted(uint64 indexed chainSelector, bool allowed);
    event TokenAllowlisted(address indexed token, bool allowed);
    event PriceFeedAllowlisted(address indexed feed, bool allowed);
    event TokenPriceFeedSet(address indexed token, address indexed feed);
    event MaxPriceAgeUpdated(uint256 maxPriceAge);
    event ExtraArgsUpdated(bytes extraArgs);

    IRouterClient private immutable I_ROUTER;
    IERC20 private immutable I_LINK_TOKEN;

    address public s_forwarderAddress;

    mapping(uint64 => bool) public allowlistedDestinationChains;
    mapping(address => bool) public allowlistedTokens;
    mapping(address => bool) public allowlistedPriceFeeds;
    mapping(address => address) public tokenPriceFeeds;

    mapping(uint256 => TradeOrder) public orders;
    uint256[] public activeOrderIds;
    uint256 public nextOrderId;

    bytes public extraArgs;
    uint256 public maxPriceAge;

    uint256 public constant MAX_ORDERS_PER_CHECK = 20;

    constructor(address _router, address _linkToken) Ownable(msg.sender) {
        if (_router == address(0) || _linkToken == address(0)) revert ZeroAddress();

        I_ROUTER = IRouterClient(_router);
        I_LINK_TOKEN = IERC20(_linkToken);

        extraArgs = Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 500_000, allowOutOfOrderExecution: false}));
        maxPriceAge = 1 hours;
    }

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        uint256 len = activeOrderIds.length;
        if (len == 0) return (false, "");

        uint256 checkCount = len > MAX_ORDERS_PER_CHECK ? MAX_ORDERS_PER_CHECK : len;
        uint256[] memory executableIds = new uint256[](checkCount);
        uint256 found;

        for (uint256 i = 0; i < checkCount; i++) {
            uint256 id = activeOrderIds[i];
            (bool executable,) = _isOrderExecutable(orders[id]);
            if (executable) {
                executableIds[found] = id;
                found++;
            }
        }

        if (found == 0) return (false, "");

        uint256[] memory trimmed = new uint256[](found);
        for (uint256 i = 0; i < found; i++) {
            trimmed[i] = executableIds[i];
        }

        return (true, abi.encode(trimmed));
    }

    function performUpkeep(bytes calldata performData) external override nonReentrant {
        _enforceUpkeepCaller();

        uint256[] memory orderIds = abi.decode(performData, (uint256[]));
        emit UpkeepExecutionStarted(orderIds.length, msg.sender);

        uint256 executed;
        uint256 skipped;

        for (uint256 i = 0; i < orderIds.length; i++) {
            uint256 orderId = orderIds[i];
            TradeOrder storage order = orders[orderId];

            (bool executable, SkipReason reason) = _isOrderExecutable(order);
            if (!executable) {
                skipped++;
                emit OrderSkipped(orderId, reason);
                continue;
            }

            try this.executeOrderFromUpkeep(orderId) {
                executed++;
            } catch (bytes memory reasonData) {
                skipped++;
                emit OrderExecutionFailed(orderId, reasonData);
            }
        }

        emit UpkeepExecutionFinished(orderIds.length, executed, skipped);
    }

    function executeOrderFromUpkeep(uint256 _orderId) external returns (bytes32 messageId) {
        if (msg.sender != address(this)) revert UnauthorizedCaller(msg.sender);
        messageId = _executeOrder(_orderId);
    }

    function createTimedOrder(
        uint256 _intervalSeconds,
        address _token,
        uint256 _amount,
        uint64 _destinationChain,
        address _receiverContract,
        address _recipient,
        string calldata _action,
        bool _recurring,
        uint256 _maxExecutions,
        uint256 _deadline
    ) external onlyOwner returns (uint256 orderId) {
        _validateOrderInputs(_token, _amount, _destinationChain, _receiverContract, _recipient, _action);
        if (activeOrderIds.length >= MAX_ORDERS_PER_CHECK) revert MaxOrdersReached();

        CommonOrderConfig memory config = CommonOrderConfig({
            token: _token,
            amount: _amount,
            destinationChain: _destinationChain,
            receiverContract: _receiverContract,
            recipient: _recipient,
            action: _action,
            recurring: _recurring,
            maxExecutions: _maxExecutions,
            deadline: _deadline
        });

        orderId = nextOrderId++;
        TradeOrder storage order = orders[orderId];
        _applyCommonOrderConfig(order, orderId, TriggerType.TIME_BASED, config);
        order.interval = _intervalSeconds;

        activeOrderIds.push(orderId);

        emit OrderCreated(
            orderId,
            TriggerType.TIME_BASED,
            config.token,
            config.amount,
            config.destinationChain,
            config.recipient,
            address(0)
        );
    }

    function createPriceOrder(
        address _priceFeed,
        uint256 _priceThreshold,
        bool _executeAbove,
        address _token,
        uint256 _amount,
        uint64 _destinationChain,
        address _receiverContract,
        address _recipient,
        string calldata _action,
        bool _recurring,
        uint256 _maxExecutions,
        uint256 _deadline
    ) external onlyOwner returns (uint256 orderId) {
        orderId = _createPriceOrder(
            _priceFeed,
            _priceThreshold,
            _executeAbove,
            _token,
            _amount,
            _destinationChain,
            _receiverContract,
            _recipient,
            _action,
            _recurring,
            _maxExecutions,
            _deadline
        );
    }

    function createPriceOrderForToken(
        uint256 _priceThreshold,
        bool _executeAbove,
        address _token,
        uint256 _amount,
        uint64 _destinationChain,
        address _receiverContract,
        address _recipient,
        string calldata _action,
        bool _recurring,
        uint256 _maxExecutions,
        uint256 _deadline
    ) external onlyOwner returns (uint256 orderId) {
        address mappedFeed = tokenPriceFeeds[_token];
        if (mappedFeed == address(0)) revert PriceFeedNotConfigured(_token);

        orderId = _createPriceOrder(
            mappedFeed,
            _priceThreshold,
            _executeAbove,
            _token,
            _amount,
            _destinationChain,
            _receiverContract,
            _recipient,
            _action,
            _recurring,
            _maxExecutions,
            _deadline
        );
    }

    function _createPriceOrder(
        address _priceFeed,
        uint256 _priceThreshold,
        bool _executeAbove,
        address _token,
        uint256 _amount,
        uint64 _destinationChain,
        address _receiverContract,
        address _recipient,
        string calldata _action,
        bool _recurring,
        uint256 _maxExecutions,
        uint256 _deadline
    ) internal returns (uint256 orderId) {
        _validateOrderInputs(_token, _amount, _destinationChain, _receiverContract, _recipient, _action);
        if (_priceThreshold == 0) revert InvalidPriceThreshold();
        if (_priceFeed == address(0)) revert ZeroAddress();
        if (!allowlistedPriceFeeds[_priceFeed]) revert PriceFeedNotAllowlisted(_priceFeed);
        if (activeOrderIds.length >= MAX_ORDERS_PER_CHECK) revert MaxOrdersReached();

        CommonOrderConfig memory config = CommonOrderConfig({
            token: _token,
            amount: _amount,
            destinationChain: _destinationChain,
            receiverContract: _receiverContract,
            recipient: _recipient,
            action: _action,
            recurring: _recurring,
            maxExecutions: _maxExecutions,
            deadline: _deadline
        });

        uint8 feedDecimals;
        try AggregatorV3Interface(_priceFeed).decimals() returns (uint8 decimals_) {
            feedDecimals = decimals_;
        } catch {
            revert InvalidPriceFeed(_priceFeed);
        }

        orderId = nextOrderId++;
        TradeOrder storage order = orders[orderId];
        _applyCommonOrderConfig(order, orderId, TriggerType.PRICE_THRESHOLD, config);
        order.priceFeed = _priceFeed;
        order.priceFeedDecimals = feedDecimals;
        order.priceThreshold = _priceThreshold;
        order.executeAbove = _executeAbove;

        activeOrderIds.push(orderId);

        emit OrderCreated(
            orderId,
            TriggerType.PRICE_THRESHOLD,
            config.token,
            config.amount,
            config.destinationChain,
            config.recipient,
            _priceFeed
        );
    }

    function createBalanceOrder(
        uint256 _balanceRequired,
        address _token,
        uint256 _amount,
        uint64 _destinationChain,
        address _receiverContract,
        address _recipient,
        string calldata _action,
        bool _recurring,
        uint256 _maxExecutions,
        uint256 _deadline
    ) external onlyOwner returns (uint256 orderId) {
        _validateOrderInputs(_token, _amount, _destinationChain, _receiverContract, _recipient, _action);
        if (_balanceRequired == 0) revert ZeroAmount();
        if (activeOrderIds.length >= MAX_ORDERS_PER_CHECK) revert MaxOrdersReached();

        CommonOrderConfig memory config = CommonOrderConfig({
            token: _token,
            amount: _amount,
            destinationChain: _destinationChain,
            receiverContract: _receiverContract,
            recipient: _recipient,
            action: _action,
            recurring: _recurring,
            maxExecutions: _maxExecutions,
            deadline: _deadline
        });

        orderId = nextOrderId++;
        TradeOrder storage order = orders[orderId];
        _applyCommonOrderConfig(order, orderId, TriggerType.BALANCE_TRIGGER, config);
        order.balanceRequired = _balanceRequired;

        activeOrderIds.push(orderId);

        emit OrderCreated(
            orderId,
            TriggerType.BALANCE_TRIGGER,
            config.token,
            config.amount,
            config.destinationChain,
            config.recipient,
            address(0)
        );
    }

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

    function getOrder(uint256 _orderId) external view returns (TradeOrder memory) {
        return orders[_orderId];
    }

    function getActiveOrderCount() external view returns (uint256) {
        return activeOrderIds.length;
    }

    function getLinkBalance() external view returns (uint256) {
        return I_LINK_TOKEN.balanceOf(address(this));
    }

    function getTokenBalance(address _token) external view returns (uint256) {
        return IERC20(_token).balanceOf(address(this));
    }

    function getRouter() external view returns (address) {
        return address(I_ROUTER);
    }

    function getLinkToken() external view returns (address) {
        return address(I_LINK_TOKEN);
    }

    function estimateFee(uint256 _orderId) external view returns (uint256 fee) {
        TradeOrder storage order = orders[_orderId];
        if (order.createdAt == 0) revert OrderNotFound(_orderId);

        uint256 resolvedDeadline = _resolveDeadline(order);
        Client.EVM2AnyMessage memory message = _buildCCIPMessage(order, resolvedDeadline);
        fee = I_ROUTER.getFee(order.destinationChain, message);
    }

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

    function allowlistPriceFeed(address _feed, bool _allowed) external onlyOwner {
        if (_feed == address(0)) revert ZeroAddress();
        allowlistedPriceFeeds[_feed] = _allowed;
        emit PriceFeedAllowlisted(_feed, _allowed);
    }

    function setTokenPriceFeed(address _token, address _feed, bool _allowlistFeed) external onlyOwner {
        if (_token == address(0) || _feed == address(0)) revert ZeroAddress();
        if (!allowlistedTokens[_token]) revert TokenNotAllowlisted(_token);

        tokenPriceFeeds[_token] = _feed;
        emit TokenPriceFeedSet(_token, _feed);

        if (_allowlistFeed && !allowlistedPriceFeeds[_feed]) {
            allowlistedPriceFeeds[_feed] = true;
            emit PriceFeedAllowlisted(_feed, true);
        }
    }

    function setMaxPriceAge(uint256 _maxPriceAge) external onlyOwner {
        if (_maxPriceAge == 0) revert InvalidMaxPriceAge();
        maxPriceAge = _maxPriceAge;
        emit MaxPriceAgeUpdated(_maxPriceAge);
    }

    function updateExtraArgs(bytes calldata _extraArgs) external onlyOwner {
        extraArgs = _extraArgs;
        emit ExtraArgsUpdated(_extraArgs);
    }

    function withdrawLink(address _to) external onlyOwner {
        if (_to == address(0)) revert ZeroAddress();
        uint256 bal = I_LINK_TOKEN.balanceOf(address(this));
        if (bal == 0) revert NothingToWithdraw();
        I_LINK_TOKEN.safeTransfer(_to, bal);
    }

    function withdrawNative(address payable _to) external onlyOwner {
        if (_to == address(0)) revert ZeroAddress();
        uint256 bal = address(this).balance;
        if (bal == 0) revert NothingToWithdraw();
        (bool ok,) = _to.call{value: bal}("");
        if (!ok) revert WithdrawFailed();
    }

    function withdrawToken(address _token, address _to) external onlyOwner {
        if (_token == address(0) || _to == address(0)) revert ZeroAddress();
        uint256 bal = IERC20(_token).balanceOf(address(this));
        if (bal == 0) revert NothingToWithdraw();
        IERC20(_token).safeTransfer(_to, bal);
    }

    receive() external payable {}

    function _enforceUpkeepCaller() internal view {
        if (s_forwarderAddress == address(0)) {
            if (msg.sender != owner()) revert UnauthorizedCaller(msg.sender);
            return;
        }

        if (msg.sender != s_forwarderAddress) revert UnauthorizedCaller(msg.sender);
    }

    function _isOrderExecutable(TradeOrder storage order) internal view returns (bool, SkipReason) {
        if (order.createdAt == 0) return (false, SkipReason.NOT_FOUND);
        if (order.status != OrderStatus.ACTIVE) return (false, SkipReason.ORDER_NOT_ACTIVE);
        if (order.maxExecutions > 0 && order.executionCount >= order.maxExecutions) {
            return (false, SkipReason.MAX_EXECUTIONS_REACHED);
        }
        if (order.deadline > 0 && block.timestamp > order.deadline) return (false, SkipReason.DEADLINE_EXPIRED);

        uint256 resolvedDeadline = _resolveDeadline(order);
        uint256 estimatedFee;
        try I_ROUTER.getFee(order.destinationChain, _buildCCIPMessage(order, resolvedDeadline)) returns (uint256 fee) {
            estimatedFee = fee;
        } catch {
            return (false, SkipReason.FEE_ESTIMATION_FAILED);
        }

        if (I_LINK_TOKEN.balanceOf(address(this)) < estimatedFee) return (false, SkipReason.INSUFFICIENT_LINK);

        if (order.triggerType == TriggerType.TIME_BASED) {
            if (order.executionCount == 0) return (true, SkipReason.NONE);
            uint256 timeSinceLast = block.timestamp - order.lastExecutedAt;
            if (timeSinceLast < order.interval) return (false, SkipReason.TIME_NOT_ELAPSED);
            return (true, SkipReason.NONE);
        }

        if (order.triggerType == TriggerType.BALANCE_TRIGGER) {
            if (IERC20(order.token).balanceOf(address(this)) < order.balanceRequired) {
                return (false, SkipReason.BALANCE_TOO_LOW);
            }
            return (true, SkipReason.NONE);
        }

        if (order.priceFeed == address(0)) return (false, SkipReason.PRICE_FEED_NOT_SET);
        if (!allowlistedPriceFeeds[order.priceFeed]) return (false, SkipReason.PRICE_FEED_NOT_ALLOWLISTED);

        (bool validPrice, uint256 currentPrice, SkipReason reason) =
            _readPrice(order.priceFeed, order.priceFeedDecimals);
        if (!validPrice) return (false, reason);

        if (order.executeAbove) {
            return currentPrice >= order.priceThreshold ? (true, SkipReason.NONE) : (false, SkipReason.PRICE_NOT_MET);
        }

        return currentPrice <= order.priceThreshold ? (true, SkipReason.NONE) : (false, SkipReason.PRICE_NOT_MET);
    }

    function _readPrice(address _feed, uint8 _decimals)
        internal
        view
        returns (bool valid, uint256 scaledPrice, SkipReason reason)
    {
        try AggregatorV3Interface(_feed).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer <= 0 || updatedAt == 0) return (false, 0, SkipReason.PRICE_INVALID);
            if (maxPriceAge > 0 && block.timestamp > updatedAt + maxPriceAge) {
                return (false, 0, SkipReason.PRICE_STALE);
            }

            scaledPrice = _scalePriceTo1e18(uint256(answer), _decimals);
            return (true, scaledPrice, SkipReason.NONE);
        } catch {
            return (false, 0, SkipReason.PRICE_INVALID);
        }
    }

    function _executeOrder(uint256 _orderId) internal returns (bytes32 messageId) {
        TradeOrder storage order = orders[_orderId];
        if (order.createdAt == 0) revert OrderNotFound(_orderId);

        (bool executable, SkipReason reason) = _isOrderExecutable(order);
        if (!executable) {
            revert OrderConditionNotMet(_orderId, uint8(reason));
        }

        uint256 resolvedDeadline = _resolveDeadline(order);
        Client.EVM2AnyMessage memory message = _buildCCIPMessage(order, resolvedDeadline);

        uint256 fees = I_ROUTER.getFee(order.destinationChain, message);
        uint256 linkBalance = I_LINK_TOKEN.balanceOf(address(this));
        if (linkBalance < fees) revert InsufficientLinkBalance(linkBalance, fees);

        I_LINK_TOKEN.forceApprove(address(I_ROUTER), fees);
        IERC20(order.token).forceApprove(address(I_ROUTER), order.amount);

        messageId = I_ROUTER.ccipSend(order.destinationChain, message);

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

    function _buildCCIPMessage(TradeOrder storage order, uint256 _deadline)
        internal
        view
        returns (Client.EVM2AnyMessage memory)
    {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: order.token, amount: order.amount});

        ReceiverTransferPayload memory payload = ReceiverTransferPayload({
            recipient: order.recipient, action: order.action, extraData: bytes(""), deadline: _deadline
        });

        return Client.EVM2AnyMessage({
            receiver: abi.encode(order.receiverContract),
            data: abi.encode(payload, order.creator),
            tokenAmounts: tokenAmounts,
            extraArgs: extraArgs,
            feeToken: address(I_LINK_TOKEN)
        });
    }

    function _resolveDeadline(TradeOrder storage order) internal view returns (uint256) {
        return order.deadline > 0 ? order.deadline : block.timestamp + 1 hours;
    }

    function _removeFromActiveOrders(uint256 _orderId) internal {
        uint256 len = activeOrderIds.length;
        for (uint256 i = 0; i < len; i++) {
            if (activeOrderIds[i] == _orderId) {
                activeOrderIds[i] = activeOrderIds[len - 1];
                activeOrderIds.pop();
                return;
            }
        }
    }

    function _applyCommonOrderConfig(
        TradeOrder storage order,
        uint256 orderId,
        TriggerType triggerType,
        CommonOrderConfig memory config
    ) internal {
        order.orderId = orderId;
        order.triggerType = triggerType;
        order.status = OrderStatus.ACTIVE;
        order.token = config.token;
        order.amount = config.amount;
        order.destinationChain = config.destinationChain;
        order.receiverContract = config.receiverContract;
        order.recipient = config.recipient;
        order.action = config.action;
        order.recurring = config.recurring;
        order.maxExecutions = config.maxExecutions;
        order.deadline = config.deadline;
        order.createdAt = block.timestamp;
        order.creator = msg.sender;
    }

    function _validateOrderInputs(
        address _token,
        uint256 _amount,
        uint64 _destinationChain,
        address _receiverContract,
        address _recipient,
        string calldata _action
    ) internal view {
        if (_token == address(0) || _receiverContract == address(0) || _recipient == address(0)) {
            revert ZeroAddress();
        }
        if (_amount == 0) revert ZeroAmount();
        if (bytes(_action).length == 0) revert InvalidOrderType();
        if (!allowlistedDestinationChains[_destinationChain]) {
            revert DestinationChainNotAllowlisted(_destinationChain);
        }
        if (!allowlistedTokens[_token]) revert TokenNotAllowlisted(_token);
    }

    function _scalePriceTo1e18(uint256 value, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return value;
        if (decimals < 18) return value * (10 ** (18 - decimals));
        return value / (10 ** (decimals - 18));
    }
}
