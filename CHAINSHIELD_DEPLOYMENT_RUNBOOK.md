# ChainShield Deployment Runbook

This runbook prepares and deploys the two new ChainShield contracts:

- `src/SwapAdapter.sol`
- `src/ChainShieldGateway.sol`

It assumes deployment to **Ethereum Sepolia** using the existing infrastructure already recorded in `DEPLOYED_ADDRESSES.md`.

## 1. Required Environment Variables

These names match the existing Foundry project conventions in `foundry.toml`:

```bash
export ETHEREUM_SEPOLIA_RPC_URL="https://..."
export PRIVATE_KEY="0x..."
export ETHERSCAN_API_KEY="..."
export UNISWAP_V3_ROUTER="0x..."
```

## 2. Pre-Deploy Checks

Run these from the `contracts/` directory:

```bash
forge fmt --check src/ChainShieldGateway.sol src/SwapAdapter.sol script/DeployChainShield.s.sol
forge build
```

Optional dry-run before broadcasting:

```bash
forge script script/DeployChainShield.s.sol:DeployChainShield \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
```

## 3. Broadcast Deployment

```bash
forge script script/DeployChainShield.s.sol:DeployChainShield \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

This deploys:

- `SwapAdapter`
- `ChainShieldGateway`

and then wires:

- `ChainShieldGateway.configureContracts(SECURITY_MANAGER, TOKEN_VERIFIER, swapAdapter)`
- `SwapAdapter.authoriseCaller(gateway, true)`
- `TokenVerifier.setAuthorisedCaller(gateway, true)`

## 4. Post-Deploy Actions

Authorise the gateway inside the existing `SecurityManager`:

```bash
cast send 0xca76e3D39DA50Bf6A6d1DE9e89aD2F82C06787Fd \
  "authoriseCaller(address,bool)" <GATEWAY_ADDRESS> true \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

Fund the gateway with LINK for CCIP fees.
`depositLink(uint256)` pulls LINK with `transferFrom`, so approve the gateway first:

```bash
cast send 0x779877A7B0D9E8603169DdbD7836e478b4624789 \
  "approve(address,uint256)" <GATEWAY_ADDRESS> <AMOUNT_IN_WEI> \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY

cast send <GATEWAY_ADDRESS> \
  "depositLink(uint256)" <AMOUNT_IN_WEI> \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

Alternative:

```bash
cast send 0x779877A7B0D9E8603169DdbD7836e478b4624789 \
  "transfer(address,uint256)" <GATEWAY_ADDRESS> <AMOUNT_IN_WEI> \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

Then confirm the gateway balance:

```bash
cast call <GATEWAY_ADDRESS> \
  "getLinkBalance()(uint256)" \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL
```

Or use the repo-local helper script to do approve + deposit in one broadcast:

```bash
export CHAINSHIELD_LINK_FUND_AMOUNT=<AMOUNT_IN_WEI>

forge script script/FundChainShieldLink.s.sol:FundChainShieldLink \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

Optional override if you ever need to fund a different gateway than the current Sepolia deployment:

```bash
export CHAINSHIELD_GATEWAY=<GATEWAY_ADDRESS>
```

If the tokens you plan to use are not already permitted by `TokenVerifier`, allowlist them:

```bash
cast send 0x7F2C17f2C421C10e90783f9C2823c6Dd592b9EB4 \
  "addToAllowlist(address,bool)" <TOKEN_ADDRESS> true \
  --rpc-url $ETHEREUM_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

## 5. Record What Was Deployed

After successful deployment, update `DEPLOYED_ADDRESSES.md` with:

- `ChainShieldGateway`
- `SwapAdapter`
- deployment tx hashes
- verification links if available

## 6. Readiness Notes

- `forge build` already succeeds for the new ChainShield contracts and deploy script.
- The broader contracts repo still has Forge lint notes, but they do not block deployment.
- The deploy script currently assumes Sepolia addresses for:
  - `SecurityManager`
  - `TokenVerifier`
  - `CCIP Router`
  - `LINK`
- `Uniswap V3 Router` must be supplied via `UNISWAP_V3_ROUTER`; do not assume the mainnet router address exists on Sepolia
- The gateway still needs LINK funding after deployment before it can pay CCIP fees.
