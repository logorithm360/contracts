# Feature 4 Technical Documentation: Automated Trading

## 1. Purpose
Feature 4 adds an owner-operated automated trading execution layer that sends CCIP programmable token transfers based on deterministic trigger conditions.

This feature is designed to be:
- deterministic and testable (Automation-compatible)
- multi-destination (Sepolia -> Amoy / Arbitrum Sepolia / Base Sepolia / OP Sepolia)
- CRE-ready (rich events + pending action mode for off-chain orchestration)

## 2. Contracts and Responsibilities

### `src/AutomatedTrader.sol` (source chain)
Primary automation engine.

Responsibilities:
- maintain and execute trading orders
- evaluate trigger conditions (`TIME_BASED`, `PRICE_THRESHOLD`, `BALANCE_TRIGGER`)
- build CCIP token+payload messages
- send CCIP messages with LINK fee payment
- expose Chainlink Automation entrypoints (`checkUpkeep`, `performUpkeep`)

Core controls:
- destination chain allowlist
- transferable token allowlist
- price feed allowlist
- token -> price feed mapping
- max feed staleness (`maxPriceAge`)
- configurable `extraArgs`
- forwarder gating for `performUpkeep`

### `src/ProgrammableTokenReceiver.sol` (destination chain)
Destination-side execution and state tracking.

Feature-4 extension:
- `manualActionSendersByChain[sourceSelector][sender]`
- `setManualActionSender(...)`
- `ActionRequested(...)` event
- new status: `PendingAction`

Behavior:
- `transfer`: immediate token transfer + `Processed`
- `stake/swap/deposit`:
  - normal senders: backward-compatible immediate transfer path
  - manual-action senders: store transfer, emit `ActionRequested`, keep tokens locked for CRE/operator execution

## 3. Order Model
`AutomatedTrader` stores one struct per order with trigger config + execution metadata.

High-level fields:
- destination selector + receiver
- token + amount
- payload action + recipient + deadline
- trigger type + trigger params
- recurring / max executions
- active state + counters

Order creation APIs:
- `createTimedOrder(...)`
- `createPriceOrder(...)`
- `createPriceOrderForToken(...)`
- `createBalanceOrder(...)`

Operational APIs:
- `cancelOrder(...)`, `pauseOrder(...)`, `resumeOrder(...)`
- `estimateFee(orderId)`
- `getOrder(orderId)`, `getActiveOrderCount()`, `getLinkBalance()`
- `setTokenPriceFeed(token, feed, allowlistFeed)`

## 4. Trigger Evaluation Logic

### `TIME_BASED`
- first execution is immediate once order is active
- recurring executions respect `intervalSeconds`

### `PRICE_THRESHOLD`
- reads `AggregatorV3Interface.latestRoundData()`
- validates:
  - feed allowlisted
  - answer > 0
  - `block.timestamp - updatedAt <= maxPriceAge`
- normalizes price to 1e18 precision
- executes when threshold condition (`executeAbove` true/false) is met

### `BALANCE_TRIGGER`
- checks source-side token balance threshold against configured requirement

## 5. Automation Execution Flow
1. Automation calls `checkUpkeep`.
2. Contract scans active orders and builds executable order list.
3. Automation forwarder calls `performUpkeep(performData)`.
4. For each executable order:
   - evaluate trigger again (final guard)
   - estimate fee via router
   - verify LINK balance in trader contract
   - send CCIP token transfer + payload
   - update execution counters and timestamps
   - emit execution events

Failure isolation:
- one order failure does not revert all order processing
- skip/failure reasons are emitted for observability

## 6. Security and Reliability Model

### Access control
- owner/operator manages orders and configuration
- `performUpkeep` auth model:
  - owner allowed before forwarder set
  - forwarder-only after `setForwarder(...)`

### Funds model
- fees paid in LINK by `AutomatedTrader`
- contract must hold enough LINK before upkeep execution
- sender wallet must approve and fund transferable source tokens when needed

### Defensive execution
- receiver stores transfer metadata first
- manual-action mode prevents unsafe immediate action execution for advanced actions
- tokens are recoverable/retriable with existing receiver controls

## 7. CRE Integration Hooks
Feature 4 is built to connect to CRE workflows without changing core on-chain logic.

Important events:

### Source (`AutomatedTrader`)
- `OrderCreated`
- `OrderCancelled`
- `OrderPaused`
- `OrderExecuted`
- `OrderSkipped`
- `OrderExecutionFailed`
- `UpkeepExecutionStarted`
- `UpkeepExecutionFinished`

### Destination (`ProgrammableTokenReceiver`)
- `TransferReceived`
- `TransferProcessed`
- `ActionRequested`
- `TransferFailed`
- `TransferRecovered`

Recommended CRE behavior:
- subscribe to `ActionRequested`
- validate policy/risk off-chain
- execute destination adapter action
- optionally emit completion state back to workflow storage/indexer

## 8. Scripts and Operational Commands
All feature-4 scripts are in `script/Deployautomation.s.sol`:
- `DeployAutomatedTrader`
- `SetAutomatedForwarder`
- `ConfigureAutomatedSenderOnReceiver`
- `CreateTimedOrder`
- `CreatePriceOrder`
- `CreateBalanceOrder`
- `CheckAutomationStatus`
- `TriggerAutomationUpkeep` (owner-side pre-forwarder live trigger)
- `SetTokenPriceFeed`

### Environment variables
Deployment/config:
- `LOCAL_CCIP_ROUTER`
- `LOCAL_LINK_TOKEN`
- `LOCAL_CCIP_BNM_TOKEN` (optional)
- `LOCAL_CCIP_LNM_TOKEN` (optional)
- `AUTOMATED_DESTINATION_GAS_LIMIT` (optional, default `500000`)
- `AUTOMATED_MAX_PRICE_AGE` (optional, default `3600`)
- `AUTOMATED_PRICE_FEED` (optional initial feed allowlist)
- `AUTOMATED_ALLOWLIST_PRICE_FEED` (optional, default `true`)

Forwarder:
- `AUTOMATED_TRADER_CONTRACT`
- `AUTOMATION_FORWARDER_ADDRESS`

Receiver config:
- `AUTOMATED_RECEIVER_CONTRACT`
- `AUTOMATED_SOURCE_SELECTOR` (optional, default Sepolia selector)
- `AUTOMATED_ENABLE_MANUAL_ACTION_MODE` (optional, default `true`)

Order creation:
- `AUTOMATED_DESTINATION_SELECTOR`
- `AUTOMATED_RECEIVER_CONTRACT`
- `AUTOMATED_TOKEN_ADDRESS`
- `AUTOMATED_TOKEN_AMOUNT`
- `AUTOMATED_ACTION`
- `AUTOMATED_RECIPIENT`
- `AUTOMATED_INTERVAL_SECONDS` (timed)
- `AUTOMATED_PRICE_FEED` (price)
- `AUTOMATED_PRICE_THRESHOLD` (price)
- `AUTOMATED_EXECUTE_ABOVE` (price)
- `AUTOMATED_BALANCE_REQUIRED` (balance)
- `AUTOMATED_RECURRING` (optional)
- `AUTOMATED_MAX_EXECUTIONS` (optional)
- `AUTOMATED_DEADLINE` (optional)

Price-feed mapping:
- `AUTOMATED_TRADER_CONTRACT`
- `AUTOMATED_TOKEN_ADDRESS`
- `AUTOMATED_PRICE_FEED`
- `AUTOMATED_ALLOWLIST_PRICE_FEED` (optional, default `true`)

## 9. Testing Strategy

### Unit tests
Main suite: `test/AutomatedTrading.t.sol`

Coverage includes:
- timed trigger creation and interval behavior
- price trigger true/false paths
- stale/invalid feed handling
- balance trigger behavior
- forwarder authorization
- upkeep -> CCIP -> receiver full cycle
- manual-action pending mode behavior
- max-execution stop behavior
- cancel/pause semantics
- insufficient LINK skip behavior
- fee estimation non-zero

Compatibility suite updates:
- `test/ProgrammableToken.t.sol` includes manual-action mode test while preserving default behavior

### Required validation commands
Run from `contracts/`:

```bash
forge fmt --check
forge build
forge test --match-contract AutomatedTradingTest -vvv
forge test --match-contract ProgrammableTokenTest -vvv
forge test --match-contract MessagingTest -vvv
forge test --match-contract TokenTransferTest -vvv
```

## 10. Known Operational Notes
- `via_ir = true` is enabled in `foundry.toml` for stable compilation with current contract complexity.
- LINK balance in `AutomatedTrader` is mandatory for upkeep-triggered CCIP sends.
- In manual-action mode, `ActionRequested` means delivery succeeded but business action is intentionally deferred.

## 11. Recommended Deployment Sequence
1. Deploy `AutomatedTrader` on source chain.
2. Fund trader contract with LINK.
3. Allowlist destination chains/tokens/feeds.
4. Configure destination receiver sender trust + manual action mode.
5. Register upkeep and set forwarder.
6. Create orders (timed, price, balance).
7. Monitor source and destination events for execution and pending actions.
