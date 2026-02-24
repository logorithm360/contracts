# Feature 5: Storage and User Detail Management

## 1. Purpose
Feature 5 adds a canonical on-chain registry for user-level records and profile commitments across Features 1-4.

The design is **non-invasive**:
- Existing contracts for messaging, token transfer, programmable transfer, and automated trading remain unchanged.
- A CRE relayer/indexer consumes emitted events and writes normalized snapshots into a dedicated registry.

## 2. Contract
Main contract:
- `src/UserRecordRegistry.sol`

## 3. Core Data Model
### 3.1 User profile
Each wallet has one profile state:
- `profileCommitment` (`bytes32`): opaque commitment hash (no plaintext PII)
- `profileVersion` (`uint64`): increments on each update
- `updatedAt` (`uint256`): block timestamp

### 3.2 Unified ledger record
Each ingested event snapshot is stored as one `Record`:
- `recordId`
- `user`
- `featureType` (`MESSAGE | TOKEN_TRANSFER | PROGRAMMABLE_TRANSFER | AUTOMATED_TRADER`)
- `chainSelector`
- `sourceContract`
- `counterparty`
- `messageId`
- `assetToken`
- `amount`
- `actionHash` (`keccak256(bytes(action))`)
- `status` (`CREATED | SENT | RECEIVED | PROCESSED | PENDING_ACTION | FAILED | RETRY | RECOVERED`)
- `occurredAt`
- `metadataHash` (optional off-chain payload hash)

## 4. Access Control and Roles
`UserRecordRegistry` uses owner-administered system writer roles:
- `owner`: grants/revokes writers
- `SYSTEM_WRITER_ROLE`: CRE relayer/indexer accounts that can append records
- `user` (wallet): can update only their own profile commitment

## 5. Idempotency and Dedupe
Every append requires `externalEventKey` (`bytes32`) supplied by the relayer.

Deduplication rule:
- `eventKeyUsed[externalEventKey] == false` required
- duplicate keys revert with `ExternalEventAlreadyUsed`

Recommended key source:
- `keccak256(chainSelector, txHash, logIndex, eventSignature)`
- or `keccak256(ccipMessageId, eventType, sourceChainSelector)`

## 6. Read Pattern
The registry is optimized for scalable reads:
- `getUserRecordCount(user)`
- `getUserRecordIds(user, offset, limit)`
- `getRecord(recordId)`

Pagination avoids unbounded array returns and keeps reads deterministic.

## 7. Integration Model with Features 1-4
Feature 5 does not require direct calls from existing contracts.

Pipeline:
1. Existing contracts emit workflow events.
2. CRE relayer maps each event into `RecordInput`.
3. Relayer writes to `UserRecordRegistry.appendRecord/appendRecordsBatch`.
4. Frontend/analytics read user histories from the registry.

## 8. Security and Privacy
- No plaintext credentials or personal data are stored on-chain.
- Profile data is commitment-hash only.
- Write surface is restricted to authorized system writers.
- Duplicate ingestion is blocked by event key dedupe.

## 9. Scripts
Feature 5 operational scripts are in:
- `script/Deploystorage.s.sol`

Included script contracts:
1. `DeployUserRecordRegistry`
2. `GrantSystemWriter`
3. `UpdateMyProfileCommitment`
4. `AppendSystemRecord`
5. `AppendSystemRecordsBatch`
6. `ReadUserProfile`
7. `ReadUserRecords`

## 10. Tests
Main test suite:
- `test/UserRecordRegistry.t.sol`

Coverage includes:
- profile ownership behavior
- writer authorization
- dedupe behavior
- batch limits
- pagination
- enum/hash persistence
- input validation
