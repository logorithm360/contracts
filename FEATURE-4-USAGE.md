# Feature 4 Usage Guide (Automated Trading)

This guide shows how to run Feature 4 end-to-end in practice.

## What Feature 4 does
Feature 4 lets you:
- create an automated order on Sepolia
- trigger CCIP token transfer to Amoy based on order conditions
- deliver tokens to a destination recipient address

Main contracts:
- Source: `AutomatedTrader` (Sepolia)
- Destination: `ProgrammableTokenReceiver` (Amoy)

---

## Prerequisites
- You are in `contracts/` directory
- `.env` has valid Sepolia/Amoy RPC values
- `deployer` keystore/account exists in Foundry
- You have test ETH/POL for gas
- You have LINK + BnM on Sepolia for fee/token movement

```bash
cd ~/Documents/BLOCKCHAIN/CROSS-CHAIN-TRANSACTION-AUTOMATION/cross-chain-transactions/contracts
source .env
forge build
```

---

## Step 1: Deploy or reuse contracts

### 1.1 Deploy `AutomatedTrader` on Sepolia (optional if already deployed)
```bash
LOCAL_CCIP_ROUTER=0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59 \
LOCAL_LINK_TOKEN=0x779877A7B0D9E8603169DdbD7836e478b4624789 \
LOCAL_CCIP_BNM_TOKEN=0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05 \
forge script script/Deployautomation.s.sol:DeployAutomatedTrader \
  --rpc-url sepolia \
  --account deployer \
  --broadcast \
  --slow \
  -vvvv
```

### 1.2 Deploy `ProgrammableTokenReceiver` on Amoy (optional if already deployed)
```bash
LOCAL_CCIP_ROUTER=0x9C32fCB86BF0f4a1A8921a9Fe46de3198bb884B2 \
forge script script/Deployprogrammable.s.sol:DeployProgrammableReceiver \
  --rpc-url amoy \
  --account deployer \
  --broadcast \
  --slow \
  -vvvv
```

Save addresses:
- `AUTOMATED_TRADER_CONTRACT` (Sepolia)
- `AUTOMATED_RECEIVER_CONTRACT` (Amoy)

---

## Step 2: Configure receiver trust (required)
This allows Amoy receiver to accept messages from your Sepolia trader.

```bash
AUTOMATED_RECEIVER_CONTRACT=<AMOY_RECEIVER_ADDRESS> \
AUTOMATED_TRADER_CONTRACT=<SEPOLIA_TRADER_ADDRESS> \
AUTOMATED_SOURCE_SELECTOR=16015286601757825753 \
AUTOMATED_ENABLE_MANUAL_ACTION_MODE=true \
forge script script/Deployautomation.s.sol:ConfigureAutomatedSenderOnReceiver \
  --rpc-url amoy \
  --account deployer \
  --broadcast \
  --slow \
  -vvvv
```

Verify config:
```bash
cast call <AMOY_RECEIVER_ADDRESS> \
"allowlistedSourceChains(uint64)(bool)" 16015286601757825753 --rpc-url amoy

cast call <AMOY_RECEIVER_ADDRESS> \
"allowlistedSendersByChain(uint64,address)(bool)" \
16015286601757825753 <SEPOLIA_TRADER_ADDRESS> --rpc-url amoy
```
Expected: both `true`.

---

## Step 3: Fund trader on Sepolia (required)
Trader must hold:
- LINK (for CCIP fees)
- source token (e.g., BnM)

```bash
TRADER=<SEPOLIA_TRADER_ADDRESS>

cast send 0x779877A7B0D9E8603169DdbD7836e478b4624789 \
  "transfer(address,uint256)" $TRADER 200000000000000000 \
  --rpc-url sepolia --account deployer

cast send 0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05 \
  "transfer(address,uint256)" $TRADER 100000000000000000 \
  --rpc-url sepolia --account deployer
```

Check balances:
```bash
cast call 0x779877A7B0D9E8603169DdbD7836e478b4624789 "balanceOf(address)(uint256)" $TRADER --rpc-url sepolia
cast call 0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05 "balanceOf(address)(uint256)" $TRADER --rpc-url sepolia
```

---

## Step 3.1: Map token to price feed (for price-trigger orders)
This is optional for timed/balance orders, but recommended for reusable price setup.

```bash
AUTOMATED_TRADER_CONTRACT=<SEPOLIA_TRADER_ADDRESS> \
AUTOMATED_TOKEN_ADDRESS=0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05 \
AUTOMATED_PRICE_FEED=0x694AA1769357215DE4FAC081bf1f309aDC325306 \
AUTOMATED_ALLOWLIST_PRICE_FEED=true \
forge script script/Deployautomation.s.sol:SetTokenPriceFeed \
  --rpc-url sepolia \
  --account deployer \
  --broadcast \
  --slow \
  -vvvv
```

---

## Step 4: Create a timed order
Example one-time transfer from Sepolia to Amoy.

```bash
AUTOMATED_TRADER_CONTRACT=<SEPOLIA_TRADER_ADDRESS> \
AUTOMATED_DESTINATION_SELECTOR=16281711391670634445 \
AUTOMATED_RECEIVER_CONTRACT=<AMOY_RECEIVER_ADDRESS> \
AUTOMATED_TOKEN_ADDRESS=0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05 \
AUTOMATED_TOKEN_AMOUNT=100000000000000000 \
AUTOMATED_RECIPIENT=<AMOY_RECIPIENT_ADDRESS> \
AUTOMATED_ACTION=transfer \
AUTOMATED_INTERVAL_SECONDS=60 \
AUTOMATED_RECURRING=false \
AUTOMATED_MAX_EXECUTIONS=1 \
forge script script/Deployautomation.s.sol:CreateTimedOrder \
  --rpc-url sepolia \
  --account deployer \
  --broadcast \
  --slow \
  -vvvv
```

Expected log:
- `Timed order created: <orderId>`

---

## Step 4.1: Create a price order
You can set `AUTOMATED_PRICE_FEED` explicitly, or omit it if you already mapped token -> feed in Step 3.1.

```bash
AUTOMATED_TRADER_CONTRACT=<SEPOLIA_TRADER_ADDRESS> \
AUTOMATED_DESTINATION_SELECTOR=16281711391670634445 \
AUTOMATED_RECEIVER_CONTRACT=<AMOY_RECEIVER_ADDRESS> \
AUTOMATED_TOKEN_ADDRESS=0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05 \
AUTOMATED_TOKEN_AMOUNT=100000000000000000 \
AUTOMATED_RECIPIENT=<AMOY_RECIPIENT_ADDRESS> \
AUTOMATED_ACTION=transfer \
AUTOMATED_PRICE_THRESHOLD=1900000000000000000000 \
AUTOMATED_EXECUTE_ABOVE=true \
AUTOMATED_RECURRING=false \
AUTOMATED_MAX_EXECUTIONS=1 \
forge script script/Deployautomation.s.sol:CreatePriceOrder \
  --rpc-url sepolia \
  --account deployer \
  --broadcast \
  --slow \
  -vvvv
```

---

## Step 5: Check and execute upkeep

### 5.1 Check readiness
```bash
AUTOMATED_TRADER_CONTRACT=<SEPOLIA_TRADER_ADDRESS> \
forge script script/Deployautomation.s.sol:CheckAutomationStatus --rpc-url sepolia -vv
```

If `Upkeep needed: true`, continue.

### 5.2 Trigger upkeep manually (owner path)
```bash
AUTOMATED_TRADER_CONTRACT=<SEPOLIA_TRADER_ADDRESS> \
forge script script/Deployautomation.s.sol:TriggerAutomationUpkeep \
  --rpc-url sepolia \
  --account deployer \
  --broadcast \
  --slow \
  -vvvv
```

Expected in trace/logs:
- `OrderExecuted(... ccipMessageId: 0x...)`

---

## Step 6: Verify delivery on Amoy

### 6.1 Receiver transfer count
```bash
cast call <AMOY_RECEIVER_ADDRESS> "getTransferCount()(uint256)" --rpc-url amoy
```

### 6.2 Last received transfer details
```bash
cast call <AMOY_RECEIVER_ADDRESS> \
"getLastReceivedTransfer()((bytes32,uint64,address,address,address,uint256,(address,string,bytes,uint256),uint256,uint8))" \
--rpc-url amoy
```

### 6.3 Check recipient balance on destination token
For BnM Sepolia -> Amoy, destination token is typically:
- `0xcab0EF91Bee323d1A617c0a027eE753aFd6997E4`

```bash
cast call 0xcab0EF91Bee323d1A617c0a027eE753aFd6997E4 \
"balanceOf(address)(uint256)" <AMOY_RECIPIENT_ADDRESS> --rpc-url amoy
```

---

## Get CCIP Message ID after execution
Use the tx hash from `TriggerAutomationUpkeep`:

```bash
TX=<TRIGGER_UPKEEP_TX_HASH>
TRADER=<SEPOLIA_TRADER_ADDRESS>
TOPIC=$(cast keccak "OrderExecuted(uint256,bytes32,address,uint256,uint256)")

cast receipt $TX --rpc-url sepolia --json | \
jq -r --arg t "$TOPIC" --arg a "${TRADER,,}" '
  .logs[]
  | select((.address|ascii_downcase)==$a and .topics[0]==$t)
  | .topics[2]
'
```

Search that message ID on:
- `https://ccip.chain.link`

---

## Common issues and fixes

### `nonce too low`
- do not run multiple broadcast sessions with same account
- retry with `--slow`
- use `--resume` only when a resumable deployment sequence exists

### `Deployment not found ... --resume`
- remove `--resume` for first run of that script+chain

### `getTransferCount() = 0`
- check source side first:
  - `getActiveOrderCount()`
  - `CheckAutomationStatus`
  - `TriggerAutomationUpkeep`
- ensure Amoy receiver allowlists source selector + sender
- check CCIP explorer status (`Waiting for finality` can take time)

### MetaMask shows no incoming token
- import destination token contract on Amoy
- verify with `cast call balanceOf(...)` to confirm on-chain balance

---

## Minimal repeat cycle
1. Fund trader
2. Create order
3. Check status
4. Trigger upkeep
5. Wait for CCIP finality
6. Verify count + recipient token balance
