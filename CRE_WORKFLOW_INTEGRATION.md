# Cross-Chain Messaging and Token Transfer + CRE Workflow Guide

## 1. Overview
This system provides CCIP-based cross-chain messaging and token transfer across 5 supported testnets, with workflow-friendly events and retry support.

Core contracts:
- `src/MessageSender.sol`
- `src/MessageReceiver.sol`
- `src/TokenTransferSender.sol`
- `src/TokenTransferReceiver.sol`

Core workflow events:
- Sender: `MessageSent`, `LinkWithdrawn`, `NativeWithdrawn`
- Receiver: `MessageReceived`, `MessageProcessed`, `MessageProcessingFailed`, `MessageRetryRequested`, `MessageRetryCompleted`, `TokenRescued`
- Token sender: `TokensTransferred`, `DestinationChainAllowlisted`, `TokenAllowlisted`, `ExtraArgsUpdated`
- Token receiver: `TokensReceived`, `SourceChainAllowlisted`, `SenderAllowlisted`, `TokenWithdrawn`

## 2. Supported Networks
The scripts use `script/utils/SupportedNetworks.sol`.

Supported chains:
1. Ethereum Sepolia
2. Polygon Amoy
3. Arbitrum Sepolia
4. Base Sepolia
5. OP Sepolia

Chain selectors:
- Ethereum Sepolia: `16015286601757825753`
- Polygon Amoy: `16281711391670634445`
- Arbitrum Sepolia: `3478487238524512106`
- Base Sepolia: `10344971235874465080`
- OP Sepolia: `5224473277236331295`

## 3. Security and User Credentials
Do not collect user private keys.

Recommended model:
- Users connect their own wallet and sign transactions on source chains.
- Receiver stores message state on destination chains.
- Admin-only actions (`allowlist`, `retryMessage`, `rescueToken`) are controlled by owner keys.
- CRE stores only infrastructure secrets (RPC/API keys), never user wallet secrets.

## 4. Contract Behavior
### Sender
- `sendMessagePayLink(...)` sends via LINK fee token.
- `sendMessagePayNative(...)` sends via native token fee.
- Destination allowlist: `allowlistedDestinationChains[selector]`.

### Receiver
- Validates source chain and sender with:
  - `allowlistedSourceChains[sourceSelector]`
  - `allowlistedSendersByChain[sourceSelector][sender]`
- Defensive receive flow:
  1. Persist incoming message
  2. Try processing
  3. Mark failed if processing reverts
- Retry path:
  - `retryMessage(messageId)` emits retry lifecycle events

### Token Sender
- `transferTokensPayLink(...)` sends token transfer and pays CCIP fee in LINK.
- `transferTokensPayNative(...)` sends token transfer and pays CCIP fee in native gas.
- `TokensTransferred` now includes workflow metadata:
  - `initiator` (original source-chain user)
  - `extraArgsHash` (config snapshot used at send time)
- Security checks:
  - destination selector allowlist
  - token allowlist
  - sufficient LINK/native fees
  - receiver non-zero and amount > 0
- `extraArgs` is configurable so the same contract supports:
  - EOA receiver flow: `gasLimit = 0`
  - contract receiver flow: `gasLimit > 0` (for `ccipReceive` execution)

### Token Receiver
- Validates source chain and source sender with:
  - `allowlistedSourceChains[sourceSelector]`
  - `allowlistedSendersByChain[sourceSelector][sender]`
- Stores each received transfer in `receivedTransfers[messageId]`
- Stores `originSender` decoded from message payload for CRE user attribution.
- Tracks cumulative per-token volume in `totalReceived[token]`
- Supports owner emergency withdrawal via `withdrawToken(...)`

## 5. Environment Variables
Required RPC/API:
- `ETHEREUM_SEPOLIA_RPC_URL`
- `POLYGON_AMOY_RPC_URL`
- `ARBITRUM_SEPOLIA_RPC_URL` (for fork/workflow usage)
- `BASE_SEPOLIA_RPC_URL` (for workflow usage)
- `OP_SEPOLIA_RPC_URL` (for workflow usage)
- `ETHERSCAN_API_KEY`

Deploy Sender script (`script/Deploysender.s.sol`):
- `LOCAL_CCIP_ROUTER`
- `LOCAL_LINK_TOKEN`
- Optional: `PAY_FEES_IN_LINK`, `DESTINATION_GAS_LIMIT`

Deploy Receiver script (`script/Deployreceiver.s.sol`):
- `LOCAL_CCIP_ROUTER`
- Optional sender addresses to pre-allowlist:
  - `SEPOLIA_SENDER_CONTRACT`
  - `AMOY_SENDER_CONTRACT`
  - `ARBITRUM_SEPOLIA_SENDER_CONTRACT`
  - `BASE_SEPOLIA_SENDER_CONTRACT`
  - `OP_SEPOLIA_SENDER_CONTRACT`

Send script (`script/Sendmessage.s.sol`):
- `SENDER_CONTRACT`
- `RECEIVER_CONTRACT`
- `DESTINATION_CHAIN_SELECTOR`
- Optional: `MESSAGE_TEXT`, `PAY_NATIVE`, `NATIVE_FEE_VALUE`

Verify script (`script/Verifydelivery.s.sol`):
- `RECEIVER_CONTRACT`
- `MESSAGE_ID`

Retry script (`script/Retrymessage.s.sol`):
- `RECEIVER_CONTRACT`
- `MESSAGE_ID`

Deploy token sender script (`script/Deploytokentransfer.s.sol:DeployTokenSender`):
- `LOCAL_CCIP_ROUTER`
- `LOCAL_LINK_TOKEN`
- Optional: `LOCAL_CCIP_BNM_TOKEN`, `LOCAL_CCIP_LNM_TOKEN`
- Optional: `PAY_FEES_IN_LINK`, `TOKEN_TRANSFER_DESTINATION_GAS_LIMIT`

Deploy token receiver script (`script/Deploytokentransfer.s.sol:DeployTokenReceiver`):
- `LOCAL_CCIP_ROUTER`
- Optional sender addresses to pre-allowlist:
  - `SEPOLIA_TOKEN_SENDER_CONTRACT`
  - `AMOY_TOKEN_SENDER_CONTRACT`
  - `ARBITRUM_SEPOLIA_TOKEN_SENDER_CONTRACT`
  - `BASE_SEPOLIA_TOKEN_SENDER_CONTRACT`
  - `OP_SEPOLIA_TOKEN_SENDER_CONTRACT`

Send token script (`script/Sendtokens.s.sol:SendTokens`):
- `TOKEN_SENDER_CONTRACT`
- `TOKEN_RECEIVER_ADDRESS`
- `TOKEN_DESTINATION_CHAIN_SELECTOR`
- `TOKEN_ADDRESS`
- `TOKEN_AMOUNT`
- Optional: `TOKEN_PAY_NATIVE`, `TOKEN_NATIVE_FEE_VALUE`
- Optional: `IS_CONTRACT_RECEIVER`, `UPDATE_TOKEN_EXTRA_ARGS`, `TOKEN_TRANSFER_DESTINATION_GAS_LIMIT`

Verify token delivery script (`script/Sendtokens.s.sol:VerifyTokenDelivery`):
- `TOKEN_RECEIVER_CONTRACT`
- `MESSAGE_ID`

## 6. Deployment Flow (Per Chain)
Deploy sender on each source network:
```bash
forge script script/Deploysender.s.sol \
  --rpc-url <source-network> \
  --account deployer \
  --broadcast \
  -vvvv
```

Deploy receiver on each destination network:
```bash
forge script script/Deployreceiver.s.sol \
  --rpc-url <destination-network> \
  --account deployer \
  --broadcast \
  -vvvv
```

## 7. Operational Scripts
Send message:
```bash
SENDER_CONTRACT=0x... \
RECEIVER_CONTRACT=0x... \
DESTINATION_CHAIN_SELECTOR=16281711391670634445 \
MESSAGE_TEXT="hello from workflow" \
forge script script/Sendmessage.s.sol --rpc-url sepolia --account deployer --broadcast -vvvv
```

Verify delivery:
```bash
RECEIVER_CONTRACT=0x... MESSAGE_ID=0x... \
forge script script/Verifydelivery.s.sol --rpc-url amoy -vv
```

Retry failed processing:
```bash
RECEIVER_CONTRACT=0x... MESSAGE_ID=0x... \
forge script script/Retrymessage.s.sol --rpc-url amoy --account deployer --broadcast -vvvv
```

Token sender deploy:
```bash
forge script script/Deploytokentransfer.s.sol:DeployTokenSender \
  --rpc-url sepolia \
  --account deployer \
  --broadcast \
  -vvvv
```

Token receiver deploy:
```bash
forge script script/Deploytokentransfer.s.sol:DeployTokenReceiver \
  --rpc-url amoy \
  --account deployer \
  --broadcast \
  -vvvv
```

Send token transfer:
```bash
TOKEN_SENDER_CONTRACT=0x... \
TOKEN_RECEIVER_ADDRESS=0x... \
TOKEN_DESTINATION_CHAIN_SELECTOR=16281711391670634445 \
TOKEN_ADDRESS=0x... \
TOKEN_AMOUNT=1000000000000000000 \
forge script script/Sendtokens.s.sol:SendTokens --rpc-url sepolia --account deployer --broadcast -vvvv
```

Verify token transfer delivery:
```bash
TOKEN_RECEIVER_CONTRACT=0x... MESSAGE_ID=0x... \
forge script script/Sendtokens.s.sol:VerifyTokenDelivery --rpc-url amoy -vv
```

## 8. CRE Workflow Integration Pattern
Use CRE to subscribe to on-chain events and run actions.

Suggested workflow graph:
1. Trigger on `MessageSent` (all sender contracts)
2. Poll/subscribe destination `MessageReceived`
3. Route to:
   - `MessageProcessed` -> mark success
   - `MessageProcessingFailed` -> trigger retry policy
4. Call `retryMessage` (owner-controlled path)
5. Observe `MessageRetryCompleted` and close workflow

Token transfer workflow graph:
1. Trigger on `TokensTransferred` from `TokenTransferSender`
2. For contract receiver flows:
   - poll destination `TokensReceived`
   - persist transfer details (`messageId`, `token`, `amount`, `sourceSelector`, `sender`)
3. For EOA receiver flows:
   - confirm success on `https://ccip.chain.link` for `messageId`
   - optionally run balance checks on destination wallet
4. Mark workflow as complete after destination confirmation

### Example CRE Workflow Pseudocode
```ts
type MessageState = "sent" | "received" | "processed" | "failed" | "retrying" | "retry_failed";

async function onMessageSent(evt: { messageId: string; dstSelector: string; receiver: string }) {
  await db.upsert(evt.messageId, { state: "sent", dstSelector: evt.dstSelector, receiver: evt.receiver });
}

async function onMessageReceived(evt: { messageId: string }) {
  await db.patch(evt.messageId, { state: "received" });
}

async function onMessageProcessed(evt: { messageId: string }) {
  await db.patch(evt.messageId, { state: "processed", done: true });
}

async function onMessageFailed(evt: { messageId: string }) {
  await db.patch(evt.messageId, { state: "failed" });
  const shouldRetry = await retryPolicy.allow(evt.messageId);
  if (!shouldRetry) return;

  await db.patch(evt.messageId, { state: "retrying" });
  await cre.execute({
    action: "evm.write",
    chain: "destination",
    contractMethod: "retryMessage(bytes32)",
    args: [evt.messageId]
  });
}

async function onRetryCompleted(evt: { messageId: string; success: boolean }) {
  await db.patch(evt.messageId, {
    state: evt.success ? "processed" : "retry_failed",
    done: evt.success
  });
}
```

## 9. Testing
Local:
```bash
forge test --match-contract MessagingTest -vv
```

Fork (requires RPC env vars):
```bash
forge test --match-contract MessagingForkTest -vvv
```

Token transfer local suite:
```bash
forge test --match-contract TokenTransferTest -vv
```

Token transfer fork suite:
```bash
forge test --match-contract TokenTransferForkTest -vvv
```

## 10. Notes
- `MessagingReceiver` sender trust is chain-aware: sender addresses are allowlisted per source chain.
- This prevents false trust from same-address collisions across different chains.
- Dependency warnings from vendored `lib/chainlink-local` code are expected and non-blocking.
- Token receiver auth model is also chain-aware:
  - `allowlistedSendersByChain[sourceSelector][sender]`

## CONTRACT ADDRESS AND TRANSACTION HASH

##### sepolia
✅  [Success] Hash: 0x689959b4bd603d79d50bcf3791952a519cfe5a5df61a775b67866c51032f6b40
Contract Address: 0x294ad4C5EB57A83bf13f2A92a5EaeDCe8d07acc9
Block: 10289259
Paid: 0.000014479157460048 ETH (1534389 gas * 0.009436432 gwei)

##### amoy
✅  [Success] Hash: 0x49f41887d6017328586d0c5d9d05fdfa3dea727aa46e8dec8d6a7e5b4b888465
Contract Address: 0x91D09dED24af89B42E6881525cd647AE0Be7E874
Block: 34167941
Paid: 0.053335503956046993 POL (1480111 gas * 36.034800063 gwei)
