# Feature 4 CRE Integration Guide

This document explains how to integrate **Feature 4 (AutomatedTrader + ProgrammableTokenReceiver)** with a CRE workflow as the orchestration layer.

---

## 1. Goal
Use CRE to orchestrate the full automated-trading execution lifecycle:
1. Detect source-side order execution on Sepolia.
2. Track CCIP delivery state.
3. React to destination-side `ActionRequested` when manual action mode is enabled.
4. Persist workflow state and trigger downstream actions (AI/risk/ops).

Feature 4 already exposes the required hooks via events and view functions.

---

## 2. On-Chain Components

### Source chain (Sepolia)
- `AutomatedTrader` (`src/AutomatedTrader.sol`)
- Responsible for order lifecycle + upkeep execution + CCIP send

### Destination chain (Amoy / others)
- `ProgrammableTokenReceiver` (`src/ProgrammableTokenReceiver.sol`)
- Responsible for receive/process state tracking and manual action signaling

---

## 3. Event Contracts for CRE

### 3.1 Source events (AutomatedTrader)
- `OrderCreated(orderId, triggerType, token, amount, destinationChain, recipient, priceFeed)`
- `OrderExecuted(orderId, ccipMessageId, token, amount, executionCount)`
- `OrderSkipped(orderId, reason)`
- `OrderExecutionFailed(orderId, reason)`
- `UpkeepExecutionStarted(requestedCount, caller)`
- `UpkeepExecutionFinished(requestedCount, executedCount, skippedCount)`
- `OrderCancelled(orderId)`
- `OrderPaused(orderId, paused)`

### 3.2 Destination events (ProgrammableTokenReceiver)
- `TransferReceived(messageId, sourceChainSelector, senderContract, originSender, token, amount, recipient, action)`
- `TransferProcessed(messageId, action, recipient, amount)`
- `ActionRequested(messageId, action, recipient, token, amount, extraData)`
- `TransferFailed(messageId, reason)`
- `TransferRecovered(messageId, to, amount)`

---

## 4. Canonical Correlation Keys
Use these IDs in CRE storage and logs:
- `orderId` (source execution intent)
- `ccipMessageId` / `messageId` (cross-chain delivery identity)
- `sourceChainSelector` + `senderContract` (security context)

Recommended workflow state key:
- `feature4:<ccipMessageId>`

---

## 5. CRE Workflow Topology

## 5.1 Trigger graph
1. Source trigger on `OrderExecuted`.
2. Branch A: poll destination receiver by `messageId` until found.
3. Branch B: monitor destination events for `TransferProcessed | ActionRequested | TransferFailed`.
4. Finalize workflow state and notify downstream systems.

### 5.2 Minimal states
- `SOURCE_EXECUTED`
- `DESTINATION_RECEIVED`
- `DESTINATION_PROCESSED`
- `DESTINATION_PENDING_ACTION`
- `DESTINATION_FAILED`
- `RECOVERED`

---

## 6. Security and Validation Rules in CRE
Before acting on destination events:
1. Validate expected `sourceChainSelector`.
2. Validate expected `senderContract` (must be your `AutomatedTrader`).
3. Validate token and amount ranges against policy.
4. Enforce idempotency using `ccipMessageId`.
5. Reject duplicate processing of same state transition.

For `ActionRequested`:
- treat as "funds arrived, business action deferred"
- do off-chain risk checks / policy checks before calling any destination adapter

---

## 7. Data Model for CRE Storage
Suggested record:

```json
{
  "ccipMessageId": "0x...",
  "orderId": 1,
  "source": {
    "chainSelector": "16015286601757825753",
    "trader": "0x...",
    "token": "0x...",
    "amount": "100000000000000000"
  },
  "destination": {
    "chainSelector": "16281711391670634445",
    "receiver": "0x...",
    "recipient": "0x...",
    "action": "transfer"
  },
  "status": "DESTINATION_PROCESSED",
  "timestamps": {
    "sourceExecutedAt": 0,
    "destinationReceivedAt": 0,
    "destinationFinalizedAt": 0
  },
  "meta": {
    "executionCount": 1,
    "reason": ""
  }
}
```

---

## 8. Recommended CRE Handlers

### 8.1 `onOrderExecuted`
Input: `OrderExecuted`
- persist `ccipMessageId` and source context
- enqueue destination verification job

### 8.2 `onDestinationReceived`
Input: `TransferReceived`
- mark `DESTINATION_RECEIVED`
- store token and recipient confirmation

### 8.3 `onDestinationProcessed`
Input: `TransferProcessed`
- mark `DESTINATION_PROCESSED`
- close workflow successfully

### 8.4 `onActionRequested`
Input: `ActionRequested`
- mark `DESTINATION_PENDING_ACTION`
- invoke business logic pipeline (AI/risk/policy)
- optionally call destination adapter and write action result

### 8.5 `onDestinationFailed`
Input: `TransferFailed`
- mark `DESTINATION_FAILED`
- trigger alert and remediation workflow

---

## 9. Read APIs CRE Should Use

Source (`AutomatedTrader`):
- `getOrder(orderId)`
- `getActiveOrderCount()`
- `getLinkBalance()`
- `estimateFee(orderId)`

Destination (`ProgrammableTokenReceiver`):
- `getTransfer(messageId)`
- `getTransferCount()`
- `getLastReceivedTransfer()`
- `manualActionSendersByChain(sourceSelector, sender)`

---

## 10. Integration Sequence (Operational)
1. Deploy/configure Feature 4 contracts.
2. Register CRE listeners for source + destination events.
3. Create one test timed order (`AUTOMATED_ACTION=transfer`).
4. Trigger upkeep (manual path or registered forwarder).
5. Confirm CRE saw `OrderExecuted`.
6. Confirm CRE saw destination event(s).
7. Validate CRE state machine transitions.

---

## 11. Failure Scenarios CRE Must Handle
- `OrderSkipped` with reasons (insufficient LINK, feed stale, balance too low, etc.)
- CCIP finality delay (`Waiting for finality`)
- destination delivery failure (`TransferFailed`)
- duplicated/replayed event delivery from indexers

Handling pattern:
- idempotent writes by `ccipMessageId`
- bounded retries with backoff
- terminal-state alerting (`FAILED`, `RECOVERED`)

---

## 12. Production Checklist
- [ ] Source and destination contract addresses pinned in CRE config
- [ ] Chain selectors pinned and validated
- [ ] Event listeners deployed for both chains
- [ ] Idempotency key = `ccipMessageId`
- [ ] Alerting configured for failed/skipped/finality-timeout states
- [ ] Manual action SOP documented for `ActionRequested`
- [ ] Dashboard shows end-to-end lifecycle by message id

---

## 13. Relationship to Existing Docs
- `FEATURE-4.MD`: contract internals and architecture
- `FEATURE-4-USAGE.md`: operator command runbook
- `CRE_WORKFLOW_INTEGRATION.md`: project-wide workflow overview

This file is the Feature 4-specific CRE developer integration reference.
