# Cross-Chain Messaging + CRE Workflow Guide

## 1. Overview
This system provides CCIP-based cross-chain messaging across 5 supported testnets, with workflow-friendly events and retry support.

Core contracts:
- `src/MessageSender.sol`
- `src/MessageReceiver.sol`

Core workflow events:
- Sender: `MessageSent`, `LinkWithdrawn`, `NativeWithdrawn`
- Receiver: `MessageReceived`, `MessageProcessed`, `MessageProcessingFailed`, `MessageRetryRequested`, `MessageRetryCompleted`, `TokenRescued`

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

## 10. Notes
- `MessagingReceiver` sender trust is chain-aware: sender addresses are allowlisted per source chain.
- This prevents false trust from same-address collisions across different chains.
- Dependency warnings from vendored `lib/chainlink-local` code are expected and non-blocking.

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
