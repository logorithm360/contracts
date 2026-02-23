# Feature 5 Storage Usage

## 1. Prerequisites
- `source .env`
- Sepolia RPC and deployer account configured in Foundry
- Registry deployed and owner key available for writer management

## 2. Environment Variables
Required env keys used by scripts:
- `USER_RECORD_REGISTRY_CONTRACT`
- `SYSTEM_WRITER_ADDRESS`
- `PROFILE_COMMITMENT_HASH`
- `RECORD_USER`
- `RECORD_FEATURE_TYPE`
- `RECORD_CHAIN_SELECTOR`
- `RECORD_SOURCE_CONTRACT`
- `RECORD_COUNTERPARTY`
- `RECORD_MESSAGE_ID`
- `RECORD_ASSET_TOKEN`
- `RECORD_AMOUNT`
- `RECORD_ACTION_HASH`
- `RECORD_STATUS`
- `RECORD_METADATA_HASH`
- `RECORD_EXTERNAL_EVENT_KEY`

Batch mode adds indexed variants with suffixes (`_0`, `_1`, ...), plus:
- `RECORD_BATCH_COUNT`

## 3. Deploy Registry
```bash
forge script script/Deploystorage.s.sol:DeployUserRecordRegistry \
  --rpc-url sepolia \
  --account deployer \
  --broadcast \
  -vvvv
```

## 4. Grant CRE Relayer as System Writer
```bash
USER_RECORD_REGISTRY_CONTRACT=0x<registry> \
SYSTEM_WRITER_ADDRESS=0x<relayer_wallet> \
forge script script/Deploystorage.s.sol:GrantSystemWriter \
  --rpc-url sepolia \
  --account deployer \
  --broadcast \
  -vvvv
```

## 5. Update My Profile Commitment (User Wallet)
```bash
USER_RECORD_REGISTRY_CONTRACT=0x<registry> \
PROFILE_COMMITMENT_HASH=0x<bytes32_commitment_hash> \
forge script script/Deploystorage.s.sol:UpdateMyProfileCommitment \
  --rpc-url sepolia \
  --account deployer \
  --broadcast \
  -vvvv
```

## 6. Append One Record (System Writer)
Example values:
- `RECORD_FEATURE_TYPE`: `0` MESSAGE, `1` TOKEN_TRANSFER, `2` PROGRAMMABLE_TRANSFER, `3` AUTOMATED_TRADER
- `RECORD_STATUS`: `0` CREATED, `1` SENT, `2` RECEIVED, `3` PROCESSED, `4` PENDING_ACTION, `5` FAILED, `6` RETRY, `7` RECOVERED

```bash
USER_RECORD_REGISTRY_CONTRACT=0x<registry> \
RECORD_USER=0x<user_wallet> \
RECORD_FEATURE_TYPE=3 \
RECORD_CHAIN_SELECTOR=16015286601757825753 \
RECORD_SOURCE_CONTRACT=0x<source_contract> \
RECORD_COUNTERPARTY=0x<counterparty> \
RECORD_MESSAGE_ID=0x<bytes32_message_id_or_zero> \
RECORD_ASSET_TOKEN=0x<token_or_zero_if_amount_zero> \
RECORD_AMOUNT=100000000000000000 \
RECORD_ACTION_HASH=0x<keccak256_action_or_zero> \
RECORD_STATUS=1 \
RECORD_METADATA_HASH=0x<bytes32_metadata_hash_or_zero> \
RECORD_EXTERNAL_EVENT_KEY=0x<unique_dedupe_key> \
forge script script/Deploystorage.s.sol:AppendSystemRecord \
  --rpc-url sepolia \
  --account deployer \
  --broadcast \
  -vvvv
```

## 7. Append Batch Records
Set `RECORD_BATCH_COUNT` and indexed keys (`_0`, `_1`, ...):
```bash
USER_RECORD_REGISTRY_CONTRACT=0x<registry> \
RECORD_BATCH_COUNT=2 \
RECORD_USER_0=0x<user1> \
RECORD_FEATURE_TYPE_0=3 \
RECORD_CHAIN_SELECTOR_0=16015286601757825753 \
RECORD_SOURCE_CONTRACT_0=0x<src1> \
RECORD_COUNTERPARTY_0=0x<cp1> \
RECORD_MESSAGE_ID_0=0x<msg1> \
RECORD_ASSET_TOKEN_0=0x<token1> \
RECORD_AMOUNT_0=100000000000000000 \
RECORD_ACTION_HASH_0=0x<action_hash_1> \
RECORD_STATUS_0=1 \
RECORD_METADATA_HASH_0=0x<meta1> \
RECORD_EXTERNAL_EVENT_KEY_0=0x<dedupe1> \
RECORD_USER_1=0x<user2> \
RECORD_FEATURE_TYPE_1=2 \
RECORD_CHAIN_SELECTOR_1=16281711391670634445 \
RECORD_SOURCE_CONTRACT_1=0x<src2> \
RECORD_COUNTERPARTY_1=0x<cp2> \
RECORD_MESSAGE_ID_1=0x<msg2> \
RECORD_ASSET_TOKEN_1=0x<token2> \
RECORD_AMOUNT_1=200000000000000000 \
RECORD_ACTION_HASH_1=0x<action_hash_2> \
RECORD_STATUS_1=4 \
RECORD_METADATA_HASH_1=0x<meta2> \
RECORD_EXTERNAL_EVENT_KEY_1=0x<dedupe2> \
forge script script/Deploystorage.s.sol:AppendSystemRecordsBatch \
  --rpc-url sepolia \
  --account deployer \
  --broadcast \
  -vvvv
```

## 8. Read Profile
```bash
USER_RECORD_REGISTRY_CONTRACT=0x<registry> \
RECORD_USER=0x<user_wallet> \
forge script script/Deploystorage.s.sol:ReadUserProfile \
  --rpc-url sepolia \
  -vv
```

## 9. Read Paginated User Records
```bash
USER_RECORD_REGISTRY_CONTRACT=0x<registry> \
RECORD_USER=0x<user_wallet> \
READ_OFFSET=0 \
READ_LIMIT=20 \
forge script script/Deploystorage.s.sol:ReadUserRecords \
  --rpc-url sepolia \
  -vv
```

## 10. Validation Checklist
- `getUserRecordCount(user)` increments after append.
- duplicate `RECORD_EXTERNAL_EVENT_KEY` reverts.
- profile version increments on each `updateProfileCommitment`.
- unauthorized writers cannot append records.
