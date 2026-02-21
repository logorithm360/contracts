# Onchain Contract Testing and Verification Guide

This document is a practical playbook for professional smart contract testing, deployment validation, and explorer verification in this project.

Scope:
- Foundry-based test strategy
- Script simulation and broadcast discipline
- Onchain post-deploy checks
- Etherscan/Polygonscan verification
- CCIP message/token delivery verification
- Failure handling and troubleshooting

## 1. Why This Matters

Onchain systems fail in production mostly due to:
- wrong environment config
- weak pre-flight checks
- missing post-deploy assertions
- nonce/RPC instability during broadcast
- unverified contracts making debugging harder

A professional workflow reduces these risks by validating at multiple layers before and after every onchain action.

## 2. Testing Layers (Professional Model)

Use a layered approach:

1. Unit tests (local simulator, deterministic)
- Fast
- No external RPC dependency
- Best for contract logic and auth models

2. Fork tests (real chain state)
- Validates integration assumptions
- Catches chain-specific behavior
- Requires stable RPC access

3. Script dry-runs (`forge script` without `--broadcast`)
- Validates env vars and control flow
- Produces full traces

4. Onchain broadcast (`--broadcast`)
- Actual deployment or execution
- Must be followed by onchain state checks

5. Explorer verification
- Makes bytecode/source match transparent
- Essential for audits, demos, and production ops

## 3. Project Test Commands

Run from `contracts/`.

### Messaging feature

```bash
forge test --match-contract MessagingTest -vv
forge test --match-contract MessagingForkTest -vvv
```

### Token transfer feature

```bash
forge test --match-contract TokenTransferTest -vv
forge test --match-contract TokenTransferForkTest -vvv
```

### Full compile check

```bash
forge build
```

## 4. Script Execution Discipline

For every script, follow this order:

1. Dry-run first
```bash
forge script <script>:<contract> --rpc-url <network> -vvvv
```

2. Broadcast second
```bash
forge script <script>:<contract> --rpc-url <network> --account deployer --broadcast -vvvv
```

3. Verify onchain state immediately with `cast call`.

4. Verify source code on explorer (`forge verify-contract`).

## 5. Core Deployment Commands

### 5.1 Deploy token sender (Sepolia)

```bash
forge script script/Deploytokentransfer.s.sol:DeployTokenSender \
  --rpc-url sepolia \
  --account deployer \
  --broadcast \
  -vvvv
```

### 5.2 Deploy token receiver (Amoy)

```bash
LOCAL_CCIP_ROUTER=0x9C32fCB86BF0f4a1A8921a9Fe46de3198bb884B2 \
SEPOLIA_TOKEN_SENDER_CONTRACT=<SEPOLIA_SENDER_ADDRESS> \
forge script script/Deploytokentransfer.s.sol:DeployTokenReceiver \
  --rpc-url amoy \
  --account deployer \
  --broadcast \
  -vvvv
```

## 6. Post-Deploy Onchain Validation (Mandatory)

After sender deployment:

```bash
SENDER=<SENDER_ADDRESS>

cast call $SENDER "getRouter()(address)" --rpc-url sepolia
cast call $SENDER "getLinkToken()(address)" --rpc-url sepolia
cast call $SENDER "allowlistedDestinationChains(uint64)(bool)" 16281711391670634445 --rpc-url sepolia
cast call $SENDER "allowlistedTokens(address)(bool)" 0x779877A7B0D9E8603169DdbD7836e478b4624789 --rpc-url sepolia
```

Check BnM/LnM allowlist status:

```bash
cast call $SENDER "allowlistedTokens(address)(bool)" 0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05 --rpc-url sepolia
cast call $SENDER "allowlistedTokens(address)(bool)" 0x466D489b6d36E7E3b824ef491C225F5830Be5EBA --rpc-url sepolia
```

If missing:

```bash
cast send $SENDER "allowlistToken(address,bool)" 0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05 true --rpc-url sepolia --account deployer
cast send $SENDER "allowlistToken(address,bool)" 0x466D489b6d36E7E3b824ef491C225F5830Be5EBA true --rpc-url sepolia --account deployer
```

## 7. Send and Verify Token Transfer

### 7.1 Send tokens

```bash
TOKEN_SENDER_CONTRACT=<SEPOLIA_SENDER_ADDRESS> \
TOKEN_RECEIVER_ADDRESS=<AMOY_RECEIVER_ADDRESS> \
TOKEN_DESTINATION_CHAIN_SELECTOR=16281711391670634445 \
TOKEN_ADDRESS=0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05 \
TOKEN_AMOUNT=1000000000000000000 \
IS_CONTRACT_RECEIVER=true \
TOKEN_PAY_NATIVE=false \
forge script script/Sendtokens.s.sol:SendTokens \
  --rpc-url sepolia \
  --account deployer \
  --broadcast \
  -vvvv
```

### 7.2 Verify delivery on destination

```bash
TOKEN_RECEIVER_CONTRACT=<AMOY_RECEIVER_ADDRESS> \
MESSAGE_ID=<MESSAGE_ID_FROM_SEND_OUTPUT> \
forge script script/Sendtokens.s.sol:VerifyTokenDelivery \
  --rpc-url amoy \
  -vv
```

Success indicators:
- `STATUS: DELIVERED`
- expected source selector
- expected sender contract
- expected amount
- receiver balance and total received updated

## 8. Explorer Verification (Source Code Verification)

Verification is by contract address + constructor args.

### 8.1 Sepolia sender verification

```bash
cd contracts
source .env

ARGS=$(cast abi-encode "constructor(address,address,bool)" \
  0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59 \
  0x779877A7B0D9E8603169DdbD7836e478b4624789 \
  true)

forge verify-contract \
  <SEPOLIA_SENDER_ADDRESS> \
  src/TokenTransferSender.sol:TokenTransferSender \
  --chain sepolia \
  --constructor-args "$ARGS" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --watch
```

### 8.2 Amoy receiver verification

```bash
ARGS=$(cast abi-encode "constructor(address)" 0x9C32fCB86BF0f4a1A8921a9Fe46de3198bb884B2)

forge verify-contract \
  <AMOY_RECEIVER_ADDRESS> \
  src/TokenTransferReceiver.sol:TokenTransferReceiver \
  --chain-id 80002 \
  --constructor-args "$ARGS" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --watch
```

Notes:
- Tx visibility and source verification are different operations.
- A tx can be mined but contract still unverified.

## 9. Common Failure Modes and Fixes

### 9.1 `nonce too low` / `EOA nonce changed unexpectedly`
Cause:
- replaying old bundle with stale nonces
Fix:
- stop using `--resume` for stale run
- rebroadcast fresh command without `--resume`

### 9.2 `dropped from the mempool`
Cause:
- RPC instability, low fee competitiveness, or provider issues
Fix:
- retry with `--slow`
- switch RPC provider if needed
- avoid mixing many pending runs

### 9.3 `ERC20: transfer amount exceeds balance`
Cause:
- wallet approved token but does not hold enough token
Fix:
- check `balanceOf` before send
- reduce `TOKEN_AMOUNT` or fund wallet first

### 9.4 `vm.env* variable not found`
Cause:
- missing env var in shell/.env
Fix:
- `source .env`
- confirm names exactly match script

### 9.5 Verify script says `NOT FOUND`
Cause:
- CCIP message not delivered yet
Fix:
- wait and rerun verify script
- confirm status on `https://ccip.chain.link`

### 9.6 Fork tests fail with DNS/RPC errors
Cause:
- network/provider unavailable
Fix:
- test local suite first
- rerun fork tests when RPC is stable

## 10. Professional Release Checklist

Before marking a feature complete:

1. `forge build` passes
2. local unit tests pass
3. fork tests pass (or explicitly documented RPC blocker)
4. dry-run traces reviewed
5. broadcast successful and confirmed onchain
6. post-deploy `cast call` checks pass
7. explorer verification status = verified
8. CCIP delivery verified with message ID
9. addresses + tx hashes documented in repo docs
10. commit grouped by purpose (contracts/scripts/tests/docs)

## 11. Recommended Logging and Artifact Hygiene

Keep these artifacts for auditability:
- `broadcast/<script>/<chainId>/run-latest.json`
- deployment tx hashes
- deployed contract addresses
- message IDs for CCIP operations

Do not commit sensitive cache secrets.

## 12. Security and Ops Notes

- Never use real user private keys in scripts.
- Keep deployer key in Foundry keystore.
- Use allowlists defensively (chains + senders + tokens).
- Verify receiver/sender addresses before every send.
- For contract receivers, use non-zero gas limit in extraArgs.
- For EOA receivers, prefer gas limit `0`.

---

This guide is designed to be used alongside:
- `CRE_WORKFLOW_INTEGRATION.md`
- script files in `script/`
- test files in `test/`
