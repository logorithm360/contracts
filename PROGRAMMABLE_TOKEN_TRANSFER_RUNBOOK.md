# Programmable Token Transfer Runbook (Feature 3)

## Purpose
Operational guide for deploying, sending, verifying, and troubleshooting programmable CCIP token transfers (token + payload action).

Contracts:
- `src/ProgrammableTokenSender.sol`
- `src/ProgrammableTokenReceiver.sol`
- `script/Deployprogrammable.s.sol`
- `test/ProgrammableToken.t.sol`

## Supported Networks
- Ethereum Sepolia (`11155111`, selector `16015286601757825753`)
- Polygon Amoy (`80002`, selector `16281711391670634445`)
- Arbitrum Sepolia (`421614`, selector `3478487238524512106`)
- Base Sepolia (`84532`, selector `10344971235874465080`)
- OP Sepolia (`11155420`, selector `5224473277236331295`)

## Pre-flight Checklist
1. `forge build` passes.
2. `forge test --match-contract ProgrammableTokenTest -vv` passes.
3. Source sender has LINK for CCIP fees.
4. Source wallet has transfer token balance (for example Sepolia CCIP-BnM).
5. Receiver source chain + sender allowlists are configured.

## Required Environment Variables
Sender deploy:
- `LOCAL_CCIP_ROUTER`
- `LOCAL_LINK_TOKEN`
- Optional: `LOCAL_CCIP_BNM_TOKEN`, `LOCAL_CCIP_LNM_TOKEN`
- Optional: `PROGRAMMABLE_DESTINATION_GAS_LIMIT` (default `500000`)

Receiver deploy:
- `LOCAL_CCIP_ROUTER`
- Optional per-chain sender mappings:
  - `SEPOLIA_PROGRAMMABLE_SENDER_CONTRACT`
  - `AMOY_PROGRAMMABLE_SENDER_CONTRACT`
  - `ARBITRUM_SEPOLIA_PROGRAMMABLE_SENDER_CONTRACT`
  - `BASE_SEPOLIA_PROGRAMMABLE_SENDER_CONTRACT`
  - `OP_SEPOLIA_PROGRAMMABLE_SENDER_CONTRACT`

Send flow:
- `PROGRAMMABLE_SENDER_CONTRACT`
- `PROGRAMMABLE_RECEIVER_CONTRACT`
- `PROGRAMMABLE_DESTINATION_CHAIN_SELECTOR`
- `PROGRAMMABLE_TOKEN_ADDRESS`
- `PROGRAMMABLE_TOKEN_AMOUNT`
- `PAYLOAD_RECIPIENT`
- `PAYLOAD_ACTION` (`transfer|stake|swap|deposit`)
- Optional: `PAYLOAD_DEADLINE`
- Optional: `PROGRAMMABLE_PAY_NATIVE`, `PROGRAMMABLE_NATIVE_FEE_VALUE`
- Optional: `UPDATE_PROGRAMMABLE_EXTRA_ARGS`, `PROGRAMMABLE_DESTINATION_GAS_LIMIT`

Verify flow:
- `PROGRAMMABLE_RECEIVER_CONTRACT`
- `MESSAGE_ID`

## Canonical Commands
### 1) Deploy programmable sender (example: Sepolia)
```bash
LOCAL_CCIP_ROUTER=0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59 \
LOCAL_LINK_TOKEN=0x779877A7B0D9E8603169DdbD7836e478b4624789 \
LOCAL_CCIP_BNM_TOKEN=0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05 \
forge script script/Deployprogrammable.s.sol:DeployProgrammableSender \
  --rpc-url sepolia \
  --account deployer \
  --broadcast \
  --slow \
  -vvvv
```

### 2) Deploy programmable receiver (example: Amoy)
```bash
LOCAL_CCIP_ROUTER=0x9C32fCB86BF0f4a1A8921a9Fe46de3198bb884B2 \
SEPOLIA_PROGRAMMABLE_SENDER_CONTRACT=<SEPOLIA_PROGRAMMABLE_SENDER_ADDRESS> \
forge script script/Deployprogrammable.s.sol:DeployProgrammableReceiver \
  --rpc-url amoy \
  --account deployer \
  --broadcast \
  -vvvv
```

### 3) Send programmable transfer
```bash
PROGRAMMABLE_SENDER_CONTRACT=<SEPOLIA_PROGRAMMABLE_SENDER_ADDRESS> \
PROGRAMMABLE_RECEIVER_CONTRACT=<AMOY_PROGRAMMABLE_RECEIVER_ADDRESS> \
PROGRAMMABLE_DESTINATION_CHAIN_SELECTOR=16281711391670634445 \
PROGRAMMABLE_TOKEN_ADDRESS=0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05 \
PROGRAMMABLE_TOKEN_AMOUNT=1000000000000000000 \
PAYLOAD_RECIPIENT=<AMOY_USER_ADDRESS> \
PAYLOAD_ACTION=transfer \
forge script script/Deployprogrammable.s.sol:SendProgrammable \
  --rpc-url sepolia \
  --account deployer \
  --broadcast \
  -vvvv
```

### 4) Verify on destination
```bash
PROGRAMMABLE_RECEIVER_CONTRACT=<AMOY_PROGRAMMABLE_RECEIVER_ADDRESS> \
MESSAGE_ID=<MESSAGE_ID_FROM_SEND_OUTPUT> \
forge script script/Deployprogrammable.s.sol:VerifyProgrammable \
  --rpc-url amoy \
  -vv
```

## Success Criteria
1. Send script returns non-zero `messageId`.
2. Verify script shows `STATUS: Processed`.
3. Recipient balance increases on the destination token contract address reported by the receiver flow.

## Verify Recipient Balance
```bash
cast call <DESTINATION_TOKEN_ADDRESS> \
"balanceOf(address)(uint256)" \
<PAYLOAD_RECIPIENT> \
--rpc-url amoy
```

## Typical Failure Modes
- `ERC20: transfer amount exceeds balance`:
  source wallet does not own enough source token.
- `InsufficientLinkBalance(...)`:
  sender contract lacks LINK for CCIP fee.
- `nonce too low` with `--resume`:
  stale cached tx set; rerun without `--resume`.
- `NOT FOUND` in verify:
  message is still in-flight; wait and retry.

## Action Semantics (Current Implementation)
- `transfer`, `stake`, `swap`, `deposit` are accepted.
- Current phase implementation forwards tokens to `payload.recipient`.
- Unsupported action sets transfer status to `Failed` and keeps tokens locked for owner recovery.

## Explorer Verification Commands
### Sepolia sender
```bash
ARGS=$(cast abi-encode "constructor(address,address,bool)" \
  0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59 \
  0x779877A7B0D9E8603169DdbD7836e478b4624789 \
  true)

forge verify-contract \
  <SEPOLIA_PROGRAMMABLE_SENDER_ADDRESS> \
  src/ProgrammableTokenSender.sol:ProgrammableTokenSender \
  --chain sepolia \
  --constructor-args "$ARGS" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --watch
```

### Amoy receiver
```bash
ARGS=$(cast abi-encode "constructor(address)" 0x9C32fCB86BF0f4a1A8921a9Fe46de3198bb884B2)

forge verify-contract \
  <AMOY_PROGRAMMABLE_RECEIVER_ADDRESS> \
  src/ProgrammableTokenReceiver.sol:ProgrammableTokenReceiver \
  --chain-id 80002 \
  --constructor-args "$ARGS" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --watch
```

