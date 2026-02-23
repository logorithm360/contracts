# Feature 5 CRE Event-to-Record Mapping

## 1. Goal
This document defines how CRE/indexer ingestion maps Feature 1-4 contract events into `UserRecordRegistry.RecordInput`.

## 2. Normalization Rules
- `user`: explicit initiator/origin sender when available; fallback to event caller context.
- `featureType`: map by source feature contract.
- `chainSelector`: source chain selector relevant to the event.
- `sourceContract`: contract emitting the event.
- `counterparty`: receiver/sender/recipient from event semantics.
- `messageId`: CCIP message id when available, else `bytes32(0)`.
- `assetToken`: token address if applicable, else `address(0)` with `amount=0`.
- `amount`: token amount if applicable, else `0`.
- `actionHash`: `keccak256(bytes(action))` for programmable/automated actions, else `bytes32(0)`.
- `status`: mapped enum state.
- `metadataHash`: optional hash for off-chain payload blob.
- `externalEventKey`: deterministic dedupe key from chain + tx + log index (+ event signature).

## 3. Feature 1 Mapping (Messaging)
Source contracts:
- `src/MessageSender.sol`
- `src/MessageReceiver.sol`

Event mappings:
- `MessageSent` -> `featureType=MESSAGE`, `status=SENT`
- `MessageReceived` -> `featureType=MESSAGE`, `status=RECEIVED`
- `MessageProcessed` -> `featureType=MESSAGE`, `status=PROCESSED`
- `MessageProcessingFailed` -> `featureType=MESSAGE`, `status=FAILED`
- `MessageRetryRequested` -> `featureType=MESSAGE`, `status=RETRY`
- `MessageRetryCompleted(success=true)` -> `featureType=MESSAGE`, `status=PROCESSED`
- `MessageRetryCompleted(success=false)` -> `featureType=MESSAGE`, `status=FAILED`

## 4. Feature 2 Mapping (Token Transfer)
Source contracts:
- `src/TokenTransferSender.sol`
- `src/TokenTransferReceiver.sol`

Event mappings:
- `TokensTransferred` -> `featureType=TOKEN_TRANSFER`, `status=SENT`
- `TokensReceived` -> `featureType=TOKEN_TRANSFER`, `status=RECEIVED`
- Post-processing confirmation path (if emitted/derived) -> `status=PROCESSED`

## 5. Feature 3 Mapping (Programmable Transfer)
Source contracts:
- `src/ProgrammableTokenSender.sol`
- `src/ProgrammableTokenReceiver.sol`

Event mappings:
- `ProgrammableTransferSent` -> `featureType=PROGRAMMABLE_TRANSFER`, `status=SENT`
- `TransferReceived` -> `featureType=PROGRAMMABLE_TRANSFER`, `status=RECEIVED`
- `TransferProcessed` -> `featureType=PROGRAMMABLE_TRANSFER`, `status=PROCESSED`
- `ActionRequested` -> `featureType=PROGRAMMABLE_TRANSFER`, `status=PENDING_ACTION`
- `TransferFailed` -> `featureType=PROGRAMMABLE_TRANSFER`, `status=FAILED`
- `TransferRecovered` -> `featureType=PROGRAMMABLE_TRANSFER`, `status=RECOVERED`

## 6. Feature 4 Mapping (Automated Trader)
Source contracts:
- `src/AutomatedTrader.sol`
- `src/ProgrammableTokenReceiver.sol`

Event mappings:
- `OrderCreated` -> `featureType=AUTOMATED_TRADER`, `status=CREATED`
- `OrderExecuted` -> `featureType=AUTOMATED_TRADER`, `status=SENT`
- `OrderSkipped` -> map to `status=FAILED` or metadata-only policy (recommended: store with skip reason in metadata)
- `OrderExecutionFailed` -> `featureType=AUTOMATED_TRADER`, `status=FAILED`
- Destination `TransferReceived` -> `featureType=AUTOMATED_TRADER`, `status=RECEIVED`
- Destination `TransferProcessed` -> `featureType=AUTOMATED_TRADER`, `status=PROCESSED`
- Destination `ActionRequested` -> `featureType=AUTOMATED_TRADER`, `status=PENDING_ACTION`

## 7. Dedupe Key Recommendation
Recommended key generator:
```text
externalEventKey = keccak256(
  abi.encodePacked(
    chainSelector,
    txHash,
    logIndex,
    eventSignatureHash
  )
)
```

For cross-chain correlation records, include `messageId` and phase tag in metadata hash.

## 8. CRE Pipeline Stages
1. Subscribe to feature events on supported chains.
2. Transform event payload to `RecordInput`.
3. Compute unique `externalEventKey`.
4. Write with `appendRecord` or `appendRecordsBatch`.
5. Handle duplicate replays gracefully (skip on dedupe revert).
6. Expose user timeline from registry reads.
