# Feature 6 Usage (V1 On-Chain)

## Goal
Enable a global security gate for Features 1-5 with:
- `TokenVerifier` for token safety checks
- `SecurityManager` for policy/rate/incident controls

V1 is on-chain only. CRE JS/API verification is V2.

## 1. Deploy Security Contracts
```bash
forge script script/Deployverification.s.sol:DeployVerification \
  --rpc-url sepolia \
  --account deployer \
  --broadcast \
  --slow \
  -vvvv
```

Capture:
- `TOKEN_VERIFIER_CONTRACT`
- `SECURITY_MANAGER_CONTRACT`

## 2. Wire Security Into Sender Deployments
When deploying sender contracts, pass these optional env vars:
- `SECURITY_MANAGER_CONTRACT`
- `TOKEN_VERIFIER_CONTRACT`

Example (Messaging sender):
```bash
SECURITY_MANAGER_CONTRACT=0x... \
TOKEN_VERIFIER_CONTRACT=0x... \
LOCAL_CCIP_ROUTER=0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59 \
LOCAL_LINK_TOKEN=0x779877A7B0D9E8603169DdbD7836e478b4624789 \
forge script script/Deploysender.s.sol:DeploySender \
  --rpc-url sepolia \
  --account deployer \
  --broadcast \
  --slow \
  -vvvv
```

Same optional vars are supported in:
- `script/Deploytokentransfer.s.sol:DeployTokenSender`
- `script/Deployprogrammable.s.sol:DeployProgrammableSender`

If both vars are unset/zero, security stays disabled (migration mode).

## 3. Authorize Feature Caller Contracts
Security and verifier only accept authorized feature contracts.

```bash
SECURITY_MANAGER_CONTRACT=0x... \
TOKEN_VERIFIER_CONTRACT=0x... \
MESSAGING_SENDER=0x... \
TOKEN_SENDER=0x... \
PROGRAMMABLE_SENDER=0x... \
forge script script/Deployverification.s.sol:AuthoriseFeatureCallers \
  --rpc-url sepolia \
  --account deployer \
  --broadcast \
  --slow \
  -vvvv
```

Optional pass-through addresses:
- `AUTOMATED_TRADER`
- `USER_RECORD_REGISTRY`

## 4. Configure Policy Limits
```bash
SECURITY_MANAGER_CONTRACT=0x... \
GLOBAL_RATE_LIMIT=100 \
TOKEN_LIMIT_TOKEN=0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05 \
TOKEN_LIMIT_AMOUNT=1000000000000000000 \
forge script script/Deployverification.s.sol:ConfigurePolicyLimits \
  --rpc-url sepolia \
  --account deployer \
  --broadcast \
  --slow \
  -vvvv
```

Optional user-specific rate limit:
- `CUSTOM_RATE_USER=0x...`
- `CUSTOM_RATE_LIMIT=20`

## 5. Manage Allowlist/Blocklist
```bash
TOKEN_VERIFIER_CONTRACT=0x... \
TOKEN_ADDRESS=0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05 \
SET_ALLOWLIST=true \
ALLOWLIST_VALUE=true \
MAX_TRANSFER_LIMIT=2000000000000000000 \
forge script script/Deployverification.s.sol:ManageAllowBlocklist \
  --rpc-url sepolia \
  --account deployer \
  --broadcast \
  --slow \
  -vvvv
```

To block:
- `SET_BLOCKLIST=true`
- `BLOCK_REASON=MANUAL_BLOCK`

To unblock:
- `CLEAR_BLOCKLIST=true`

## 6. Monitor Mode -> Enforce Mode
Default after deployment is `MONITOR` (`0`).

Switch to enforce (`1`) only after stabilization:
```bash
SECURITY_MANAGER_CONTRACT=0x... \
SECURITY_ENFORCEMENT_MODE=1 \
forge script script/Deployverification.s.sol:SetEnforcementMode \
  --rpc-url sepolia \
  --account deployer \
  --broadcast \
  --slow \
  -vvvv
```

## 7. Check Security Status
```bash
SECURITY_MANAGER_CONTRACT=0x... \
TOKEN_VERIFIER_CONTRACT=0x... \
TOKEN_ADDRESS=0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05 \
forge script script/Deployverification.s.sol:CheckSecurityStatus \
  --rpc-url sepolia \
  -vv
```

## 8. Test Commands
```bash
forge fmt --check
forge build
forge test --match-contract TokenVerifierTest -vv
forge test --match-contract SecurityManagerTest -vv
forge test --match-contract Feature6IntegrationTest -vv
forge test --match-contract MessagingTest -vv
forge test --match-contract TokenTransferTest -vv
forge test --match-contract ProgrammableTokenTest -vv
```

## Notes
- `ENFORCE` is fail-closed.
- In this branch, Feature 6 is wired to Features 1-3 sender flows.
- Feature IDs for `AUTOMATED_TRADER` and `STORAGE` are reserved and ready for wiring when those contracts are present in the same branch.
