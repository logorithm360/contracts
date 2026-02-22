# Automated Trading (Feature 4)

## 1. Overview
Feature 4 adds owner-operated automated cross-chain execution on top of CCIP.

Core contracts:
- `src/AutomatedTrader.sol` (source chain automation engine)
- `src/ProgrammableTokenReceiver.sol` (destination execution receiver)

Core integrations:
- Chainlink Automation (`checkUpkeep` / `performUpkeep`)
- Chainlink CCIP (token + payload transfer)
- Chainlink Data Feeds (price-threshold trigger)

## 2. Trigger Types
`AutomatedTrader` supports 3 order trigger types:
1. `TIME_BASED`
2. `PRICE_THRESHOLD`
3. `BALANCE_TRIGGER`

Order management is owner/operator only in this iteration.

## 3. Receiver Action Model
`ProgrammableTokenReceiver` behavior:
- `transfer`: immediate token transfer + status `Processed`
- `stake/swap/deposit`:
  - normal senders: backward-compatible transfer + `Processed`
  - automated senders in manual mode: emit `ActionRequested`, set `PendingAction`, hold tokens for CRE execution

Manual mode control:
- `setManualActionSender(sourceSelector, sender, enabled)`

## 4. Key Events for CRE
Source (`AutomatedTrader`):
- `OrderCreated`
- `OrderExecuted`
- `OrderSkipped`
- `OrderExecutionFailed`
- `UpkeepExecutionStarted`
- `UpkeepExecutionFinished`

Destination (`ProgrammableTokenReceiver`):
- `TransferReceived`
- `TransferProcessed`
- `ActionRequested`
- `TransferFailed`
- `TransferRecovered`

## 5. Environment Variables
Deployment/config:
- `LOCAL_CCIP_ROUTER`
- `LOCAL_LINK_TOKEN`
- `LOCAL_CCIP_BNM_TOKEN` (optional)
- `LOCAL_CCIP_LNM_TOKEN` (optional)
- `AUTOMATED_DESTINATION_GAS_LIMIT` (optional, default `500000`)
- `AUTOMATED_MAX_PRICE_AGE` (optional, default `3600`)
- `AUTOMATED_PRICE_FEED` (optional initial feed allowlist)

Forwarder:
- `AUTOMATED_TRADER_CONTRACT`
- `AUTOMATION_FORWARDER_ADDRESS`

Receiver config:
- `AUTOMATED_RECEIVER_CONTRACT`
- `AUTOMATED_TRADER_CONTRACT`
- `AUTOMATED_SOURCE_SELECTOR` (optional, default Sepolia selector)
- `AUTOMATED_ENABLE_MANUAL_ACTION_MODE` (optional, default `true`)

Order creation:
- `AUTOMATED_TRADER_CONTRACT`
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

## 6. Scripts
All scripts are in `script/Deployautomation.s.sol`:
1. `DeployAutomatedTrader`
2. `SetAutomatedForwarder`
3. `ConfigureAutomatedSenderOnReceiver`
4. `CreateTimedOrder`
5. `CreatePriceOrder`
6. `CreateBalanceOrder`
7. `CheckAutomationStatus`

## 7. Example Flow
1. Deploy source trader on Sepolia.
2. Fund trader with LINK and transferable tokens.
3. Register upkeep in Chainlink Automation UI.
4. Set forwarder with `SetAutomatedForwarder`.
5. Configure destination receiver sender trust + manual action mode.
6. Create timed/price/balance orders.
7. Monitor:
   - source `OrderExecuted`
   - destination `TransferProcessed` or `ActionRequested`

## 8. Price Feed Notes
- Threshold is stored as 18-decimal normalized value.
- Contract validates feed freshness with `maxPriceAge`.
- Invalid/stale feeds do not revert upkeep globally; orders are skipped with reason events.

## 9. Validation Commands
```bash
forge fmt --check
forge build
forge test --match-contract AutomatedTradingTest -vvv
forge test --match-contract ProgrammableTokenTest -vvv
forge test --match-contract MessagingTest -vvv
forge test --match-contract TokenTransferTest -vvv
```
