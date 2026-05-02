# ChainShield — Full System Context Document

> **Purpose:** This document is written for an AI agent that needs complete context about the ChainShield system — what it is, why it was built, how it works, what contracts exist, what the frontend stack looks like, and what decisions were made along the way. Read this before touching any code.

---

## 1. Project Overview

**ChainShield** is a feature within a larger platform called **ChainPilot** — an AI-powered cross-chain DeFi suite built on Chainlink infrastructure. ChainPilot originally had four services: ChainShield, AutoPilot DCA, CrossVault, and ChainAlert.

This document covers the **new version of ChainShield** being rebuilt from scratch using **Next.js + Wagmi + AppKit (WalletConnect)** with **shadcn/ui + Tailwind CSS**.

### What ChainShield Does

ChainShield allows users to send tokens cross-chain securely with two core capabilities:

1. **Cross-chain token transfer** — powered by Chainlink CCIP. A sender picks a token on their chain, a receiver gets it on a destination chain.

2. **Automatic token swap before bridging** — the sender does not need to hold the exact token the receiver expects. ChainShield automatically swaps the sender's token into the receiver's expected token on the source chain first, then bridges it. Example: sender has USDC, receiver expects WETH — ChainShield swaps USDC → WETH on Sepolia, then bridges WETH to the destination chain.

### The Execution Order (Critical)

The swap always happens **before** the bridge, and both happen **only after** all security checks pass:

```
1. Security Check      ← SecurityManager.validateTransfer()
2. Token Verification  ← TokenVerifier.verifyTokenLayer1() + isTransferSafe()
3. Swap                ← SwapAdapter (Uniswap V3) on source chain
4. CCIP Bridge         ← Chainlink CCIP to destination chain
```

If any step fails, the entire transaction reverts. No funds move until steps 1 and 2 pass.

---

## 2. Why ChainShield Exists (Business Rationale)

The problem ChainShield solves: today, a user who wants to send USDC but the receiver expects WETH must manually find a DEX, swap, then manually bridge via a separate protocol. ChainShield collapses this into a single transaction.

**Key differentiators vs. competitors (Li.Fi, Socket, Across Protocol):**
- The **AI security layer** that gates every transfer — most bridges execute blindly with no intelligent verification
- The **Chainlink CCIP trust guarantee** — a battle-tested, audited cross-chain messaging protocol
- **Unified UX** — one transaction, one signature, no multi-step manual process

**What ChainShield does NOT do:**
- It does not reduce gas fees inherently — swap + bridge means the user pays gas for both steps
- It does not reduce CCIP fees — LINK fees still apply
- What it reduces is **friction, complexity, and risk of user error**

---

## 3. Technology Stack

### Frontend
| Layer | Choice | Reason |
|---|---|---|
| Framework | Next.js 14+ (App Router) | Server components, API routes, SSE support |
| Wallet | Wagmi v2 + Viem | Contract reads/writes, chain switching |
| Wallet UI | AppKit (WalletConnect) | User-chosen — supports multiple wallets cleanly |
| Styling | shadcn/ui + Tailwind CSS | User-chosen — production-grade components |
| State | TanStack Query | Bundled with Wagmi v2, handles async contract state |

### Backend / On-chain
| Layer | Choice |
|---|---|
| Cross-chain messaging | Chainlink CCIP |
| Source DEX | Uniswap V3 (Sepolia testnet) |
| Smart contract language | Solidity 0.8.33 |
| Contract framework | Foundry |
| AI verification | OpenAI (via Next.js API routes, server-side only) |

### Chains
| Chain | Chain ID | Selector | Role |
|---|---|---|---|
| Ethereum Sepolia | 11155111 | 16015286601757825753 | Source chain — all contracts deployed here |
| Polygon Amoy | 80002 | 16281711391670634445 | Destination chain |
| Arbitrum Sepolia | 421614 | — | Destination chain |
| Base Sepolia | 84532 | — | Destination chain |
| Avalanche Fuji | 43113 | — | Destination chain |

---

## 4. Smart Contract Architecture

### Overview

ChainShield uses a layered contract architecture. Two contracts are **new** (built for this version). Four contracts are **existing** (already deployed from the original ChainPilot system and reused without modification).

```
[Frontend / Wagmi]
        │
        ▼  single call
ChainShieldGateway.sol        ← NEW — orchestrates all steps
        │
        ├─► SecurityManager.sol     ← EXISTING — step 1: security check
        │
        ├─► TokenVerifier.sol       ← EXISTING — step 2: token verification
        │
        ├─► SwapAdapter.sol         ← NEW — step 3: Uniswap V3 swap
        │
        └─► Chainlink CCIP Router   ← EXISTING — step 4: cross-chain bridge
                │
                ▼
        Destination chain receiver
```

### Contract: `ChainShieldGateway.sol` (NEW)

**Purpose:** Single entry point. The frontend calls exactly one function — `initiateTransfer()`. The gateway orchestrates SecurityManager → TokenVerifier → SwapAdapter → CCIP in sequence.

**Deployed at:** Not yet deployed (new contract)

**Key function:**
```solidity
function initiateTransfer(
    address tokenIn,                   // token the sender holds
    address tokenOut,                  // token the receiver expects
    uint256 amountIn,                  // amount of tokenIn
    address receiver,                  // receiver address on destination chain
    uint64  destinationChainSelector,  // Chainlink CCIP chain selector
    uint256 slippageBps,               // slippage tolerance (max 50 = 0.5%)
    uint24  poolFee                    // Uniswap pool fee tier (0 = default 3000)
) external returns (bytes32 ccipMessageId)
```

**Other key functions:**
- `estimateFee()` — view function, returns LINK fee before user signs. Call this from frontend before prompting MetaMask.
- `depositLink()` — anyone can fund the contract with LINK to pay CCIP fees
- `getLinkBalance()` — returns current LINK balance of the contract
- `configureContracts()` — owner-only, wires SecurityManager + TokenVerifier + SwapAdapter

**Security model:**
- Uses OpenZeppelin `ReentrancyGuard` — no re-entrancy attacks
- Uses OpenZeppelin `Ownable` — admin functions owner-gated
- Uses `SafeERC20` for all token transfers — no unsafe approve patterns
- All approvals are cleared after use (`forceApprove(0)`)
- Feature ID `2` (PROGRAMMABLE_TRANSFER) is used when calling SecurityManager

**Events emitted (important for frontend tracking):**
- `TransferInitiated(ccipMessageId, sender, receiver, destinationChainSelector, tokenIn, tokenOut, amountIn, amountOut, nonce)` — primary event, contains CCIP message ID for tracking
- `SecurityCheckPassed(sender, tokenIn, amount)` — step 1 complete
- `TokenVerificationPassed(sender, tokenIn, tokenOut)` — step 2 complete
- `SwapCompleted(tokenIn, tokenOut, amountIn, amountOut)` — step 3 complete

**Errors (all custom, typed):**
- `SystemPaused` — SecurityManager is paused
- `TokenInNotVerified(token)` — tokenIn failed TokenVerifier check
- `TokenOutNotVerified(token)` — tokenOut failed TokenVerifier check
- `TransferNotSafe(token, amount)` — amount exceeds TokenVerifier limit
- `InsufficientLinkBalance(required, available)` — gateway needs more LINK
- `SecurityCheckFailed(user, token, amount)` — SecurityManager rejected
- `ZeroAddress`, `ZeroAmount`, `InvalidChainSelector` — input validation

---

### Contract: `SwapAdapter.sol` (NEW)

**Purpose:** Wraps Uniswap V3's `exactInputSingle`. Only callable by authorised addresses (ChainShieldGateway). Handles both the swap case and the same-token passthrough case.

**Deployed at:** Not yet deployed (new contract)

**Key functions:**
```solidity
// Main swap path — tokenIn != tokenOut
function swap(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    address recipient,     // where tokenOut lands (ChainShieldGateway)
    uint256 slippageBps,   // must be <= maxSlippageBps (default 50)
    uint24  poolFee        // Uniswap fee tier; 0 = use defaultPoolFee (3000)
) external returns (uint256 amountOut)

// Passthrough path — tokenIn == tokenOut, no DEX hop
function passthrough(
    address token,
    uint256 amount,
    address recipient
) external returns (uint256)
```

**Security model:**
- `onlyAuthorised` modifier — only ChainShieldGateway can call `swap()` or `passthrough()`
- `ReentrancyGuard` — no re-entrancy
- Slippage enforced on-chain: `amountOutMinimum = amountIn * (10000 - slippageBps) / 10000`
- No tokens ever held between calls — pull → swap → output in one atomic call
- `rescueTokens()` for emergency token recovery by owner

**Configuration:**
- `authoriseCaller(address, bool)` — owner grants/revokes gateway access
- `setRouter(address)` — update Uniswap router if needed
- `setDefaultPoolFee(uint24)` — change default fee tier (500 / 3000 / 10000)
- `setMaxSlippageBps(uint256)` — change max allowed slippage (hard cap: 1000 bps = 10%)

---

### Contract: `SecurityManager.sol` (EXISTING — REUSED)

**Deployed at:** `0xca76e3D39DA50Bf6A6d1DE9e89aD2F82C06787Fd` (Ethereum Sepolia)

**Purpose:** Platform-wide security gate. Called in step 1 of every ChainShield transfer. Has two enforcement modes:
- `MONITOR` — violations are logged as incidents, operations continue
- `ENFORCE` — violations revert (fail-closed)

**Relevant API for ChainShield:**
```solidity
function validateTransfer(address user, uint8 feature, address token, uint256 amount) external;
function paused() external view returns (bool);
function authoriseCaller(address caller, bool authorised) external;
```

**Feature ID used by ChainShield:** `2` (PROGRAMMABLE_TRANSFER)

**What it checks:**
- Is the system paused?
- Is the user rate-limited?
- Does the transfer amount exceed global or per-user limits?
- Is the token on any internal blocklist?

**Important:** ChainShieldGateway must be authorised in SecurityManager before it can call `validateTransfer()`. Run after deployment:
```bash
cast send 0xca76e3D39DA50Bf6A6d1DE9e89aD2F82C06787Fd \
  "authoriseCaller(address,bool)" <GATEWAY_ADDRESS> true \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

---

### Contract: `TokenVerifier.sol` (EXISTING — REUSED)

**Deployed at:** `0x7F2C17f2C421C10e90783f9C2823c6Dd592b9EB4` (Ethereum Sepolia)

**Purpose:** On-chain token safety checks. Called in step 2 of every ChainShield transfer for both tokenIn and tokenOut.

**Relevant API for ChainShield:**
```solidity
function verifyTokenLayer1(address token) external view returns (bool);
function isTransferSafe(address token, uint256 amount) external view returns (bool);
function addToAllowlist(address token, bool allowed) external;
function addToBlocklist(address token, string reason) external;
```

**Layer 1 checks performed:**
- Token address has deployed bytecode (is a real contract)
- ERC-20 metadata functions exist (`name`, `symbol`, `decimals`)
- `decimals()` returns value in range [1, 18]
- `totalSupply()` > 0
- Token is not on the internal blocklist
- Transfer amount does not exceed per-token max limit

**Important:** Both `tokenIn` AND `tokenOut` are verified before any swap or bridge happens.

---

### Contract: `ChainRegistry.sol` (EXISTING — AVAILABLE)

**Deployed at:** `0xAA8e96df95BeB248e27Ba1170eE0c58C905Ff02B` (Ethereum Sepolia)

**Purpose:** On-chain registry of supported chains, their CCIP selectors, and router addresses. The frontend can read from this to populate the chain selector dropdown rather than hardcoding.

---

### Deployed Address Reference (Ethereum Sepolia)

```
Deployer:                 0xe2a5d3EE095de5039D42B00ddc2991BD61E48D55
ChainRegistry:            0xAA8e96df95BeB248e27Ba1170eE0c58C905Ff02B
SecurityManager:          0xca76e3D39DA50Bf6A6d1DE9e89aD2F82C06787Fd
TokenVerifier:            0x7F2C17f2C421C10e90783f9C2823c6Dd592b9EB4
TokenTransferSender:      0x17314cc6E02580b979DFfb48d9e3669773EE5830
ProgrammableTokenSender:  0x2ff099d3197F1Dc49ae586ef0d0dC7a8D64FFE77
AutomatedTrader:          0xCB8D1Cb78085ca8bce16aa3cFa2f68D7d099270F
UserRecordRegistry:       0xd1446c0F237570C953fE2C4c91853911B077744e
ChainAlertRegistry:       0x32D02cA7fEd4521233aEbaAD6d36788315D3c088

CCIP Router (Sepolia):    0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59
LINK Token (Sepolia):     0x779877A7B0D9E8603169DdbD7836e478b4624789
CCIP-BnM (Sepolia):       0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05
Uniswap V3 Router:        0xE592427A0AEce92De3Edee1F18E0157C05861564

ChainShieldGateway:       <deploy and add address here>
SwapAdapter:              <deploy and add address here>
```

---

## 5. New Contracts — File Locations

The two new contracts were written and are located at:

```
chainshield-contracts/
├── src/
│   ├── ChainShieldGateway.sol       ← main orchestrator
│   ├── SwapAdapter.sol              ← Uniswap V3 wrapper
│   └── abis/
│       └── ChainShieldGateway.abi.json  ← ABI for frontend
└── script/
    └── DeployChainShield.s.sol      ← Foundry deploy script
```

---

## 6. Deploy Procedure

### Step 1 — Add contracts to your Foundry project

Copy `ChainShieldGateway.sol` and `SwapAdapter.sol` into your existing `src/` directory. The project already has the correct imports configured (`lib/openzeppelin-contracts`, `lib/chainlink-ccip`).

### Step 2 — Verify compilation

```bash
forge build
```

### Step 3 — Deploy

```bash
forge script script/DeployChainShield.s.sol:DeployChainShield \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

This deploys SwapAdapter and ChainShieldGateway, wires them together, and authorises gateway as SwapAdapter caller.

### Step 4 — Post-deploy: authorise gateway in SecurityManager

```bash
cast send 0xca76e3D39DA50Bf6A6d1DE9e89aD2F82C06787Fd \
  "authoriseCaller(address,bool)" <GATEWAY_ADDRESS> true \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

### Step 5 — Fund gateway with LINK

```bash
cast send <GATEWAY_ADDRESS> \
  "depositLink(uint256)" <AMOUNT_IN_WEI> \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

Minimum recommended: 5 LINK to start. Each CCIP transfer costs roughly 0.1–0.3 LINK in fees.

### Step 6 — Add tokenIn/tokenOut to TokenVerifier allowlist if needed

```bash
cast send 0x7F2C17f2C421C10e90783f9C2823c6Dd592b9EB4 \
  "addToAllowlist(address,bool)" <TOKEN_ADDRESS> true \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

---

## 7. Next.js Application Structure

The planned application structure for the ChainShield frontend:

```
app/
├── page.tsx                         ← landing page
├── shield/
│   ├── page.tsx                     ← ChainShield main UI (TransferForm)
│   └── status/[msgId]/
│       └── page.tsx                 ← CCIP transfer status tracker
└── api/
    ├── ai-verify/
    │   └── route.ts                 ← OpenAI risk assessment (server-side)
    ├── security-check/
    │   └── route.ts                 ← off-chain supplementary security checks
    └── token-lookup/
        └── route.ts                 ← token metadata + CCIP lane support

components/
├── shield/
│   ├── TransferForm.tsx             ← main form (token, amount, chain, receiver)
│   ├── VerificationSteps.tsx        ← live step-by-step check UI
│   ├── SwapPreview.tsx              ← shows swap rate before confirmation
│   └── TransferStatus.tsx           ← CCIP message tracking
└── shared/
    ├── WalletButton.tsx             ← AppKit connect button
    ├── ChainSelector.tsx            ← source/destination chain picker
    └── TokenSelector.tsx            ← token picker with balance display

lib/
├── contracts/
│   ├── abis/
│   │   └── ChainShieldGateway.abi.json
│   └── addresses.ts                 ← deployed addresses per chain
├── wagmi/
│   └── config.ts                    ← wagmi + AppKit configuration
├── ccip/
│   └── lanes.ts                     ← supported CCIP lanes + tokens per lane
└── ai/
    └── verifier.ts                  ← OpenAI call logic (server-side only)

hooks/
├── useChainShield.ts                ← main orchestration hook
├── useTokenBalance.ts               ← reads user token balances
├── useSwapQuote.ts                  ← fetches live swap quote
└── useTransferStatus.ts             ← polls CCIP message status
```

---

## 8. Frontend Transfer Flow (UI Perspective)

From the user's point of view, this is what happens after they fill in the form and click "Send":

```
Step 1 — Security Check
  → POST /api/security-check
  → Also calls SecurityManager.paused() via useReadContract
  → Show: ✓ Pass / ✗ Fail with reason

Step 2 — AI Verification
  → POST /api/ai-verify (server-side OpenAI call)
  → Returns: safe / warning / reject + reasoning
  → If warning: user sees risk explanation and must explicitly confirm
  → If reject: transfer blocked, reason shown

Step 3 — Token Verification
  → POST /api/token-lookup
  → Reads TokenVerifier on-chain via useReadContract
  → Confirms both tokenIn and tokenOut pass Layer 1 checks

Step 4 — Swap Preview
  → Shows: "You send 100 USDC → Receiver gets ~0.042 WETH"
  → Shows estimated slippage, price impact, LINK fee
  → User confirms slippage tolerance

Step 5 — On-chain Execution
  → useWriteContract calls ChainShieldGateway.initiateTransfer()
  → useSimulateContract first (dry-run before signing)
  → User signs via AppKit / connected wallet
  → Gateway executes: SecurityManager → TokenVerifier → SwapAdapter → CCIP

Step 6 — Status Tracking
  → Redirect to /shield/status/<ccipMessageId>
  → useTransferStatus polls CCIP Explorer API
  → Shows delivery confirmation when complete
```

---

## 9. Wagmi Hook Reference

These are the exact Wagmi hooks used and where:

| Hook | Component / Hook | Purpose |
|---|---|---|
| `useAccount` | `WalletButton` | Detect connected wallet + address |
| `useBalance` | `TokenSelector` | Show user's ERC-20 token balances |
| `useReadContract` | `useChainShield` | Read TokenVerifier, SecurityManager state |
| `useSimulateContract` | `useChainShield` | Dry-run `initiateTransfer` before signing |
| `useWriteContract` | `useChainShield` | Call `initiateTransfer()` on ChainShieldGateway |
| `useWaitForTransactionReceipt` | `TransferStatus` | Wait for source chain tx confirmation |
| `useSwitchChain` | `ChainSelector` | Prompt user to switch to source chain |
| `useReadContract` | `SwapPreview` | Call `estimateFee()` to show LINK cost |

### `useChainShield` Hook — Orchestration Logic

```typescript
// Pseudocode structure of the main hook
function useChainShield() {
  // 1. Run off-chain checks (security, AI, token lookup) via fetch
  // 2. Simulate the contract call with useSimulateContract
  // 3. Execute with useWriteContract when user confirms
  // 4. Listen for TransferInitiated event to get ccipMessageId
  // 5. Return: { status, steps, execute, ccipMessageId, error }
}
```

---

## 10. AI Verification Layer

The AI verification runs **server-side** in a Next.js API route (`/api/ai-verify`). It never runs on-chain. It is a **soft gate** — the on-chain contracts do not depend on it. Its purpose is to catch anomalies before the user signs.

**What the AI checks:**
- Is the transfer amount unusually large relative to the token's typical volume?
- Is the destination address associated with any known suspicious patterns?
- Is the slippage tolerance unusually high (potential sandwich attack setup)?
- Are there any anomalous patterns in the transfer parameters?

**Risk levels returned:**
- `safe` — proceed normally
- `warning` — show risk details to user, require explicit confirmation
- `reject` — block the transfer, explain why

**Fallback behaviour:** If the OpenAI API is unavailable or rate-limited, the AI check returns `safe` and logs the failure. The transfer proceeds with on-chain checks only. This mirrors the behaviour of the original ChainPilot system (`ai_fallback_applied` log pattern).

---

## 11. Key Design Decisions & Rationale

### Why swap on source chain, not destination chain?
Simpler, more predictable. The sender controls the source chain. Swapping on the destination would require additional contract infrastructure there, and the receiver would have to wait for the swap to complete after bridging — adding latency and complexity.

### Why reuse SecurityManager and TokenVerifier instead of building new?
They're already deployed, audited, and working. The `configureSecurity` pattern in the original codebase was explicitly designed for this — each sender contract can wire to the same shared security infrastructure. ChainShieldGateway follows this exact pattern.

### Why does ChainShieldGateway pay LINK fees (not the user)?
Simplicity for the user. Users don't need to hold LINK. The gateway is funded by the protocol. In a production version, a fee mechanism could be added where users pay a small ETH/token fee that the gateway uses to replenish its LINK balance.

### Why Uniswap V3 and not an aggregator?
For the testnet/MVP phase, Uniswap V3 is the most reliable DEX on Sepolia. The SwapAdapter is designed to be replaceable — the `setRouter()` function allows upgrading to an aggregator (1inch, Paraswap) later without changing ChainShieldGateway.

### Why AppKit over RainbowKit or ConnectKit?
User choice. AppKit (WalletConnect) was preferred for its multi-wallet support and WalletConnect protocol integration.

### Why is `slippageBps` passed by the user, not hardcoded?
Different tokens have different liquidity depth. A token pair with deep liquidity (USDC/WETH) can tolerate tight slippage (10-20 bps). A long-tail token pair might need 50 bps. The UI sets a safe default (30 bps) but allows the user to adjust.

---

## 12. Solidity Version & Dependencies

```
Solidity:       =0.8.33
Foundry:        forge, cast
```

Dependencies (from existing `foundry.toml`):
```
lib/openzeppelin-contracts  — IERC20, SafeERC20, Ownable, ReentrancyGuard
lib/chainlink-ccip          — IRouterClient, Client library
```

New interface added (inline in contracts):
```
ISwapRouter                 — Uniswap V3 SwapRouter (exactInputSingle)
```

No new library dependencies were introduced. Both new contracts use only what was already in the project.

---

## 13. What Has Been Built vs. What Remains

### Built (complete)

- [x] `SwapAdapter.sol` — Uniswap V3 wrapper, fully written
- [x] `ChainShieldGateway.sol` — main orchestrator, fully written
- [x] `DeployChainShield.s.sol` — Foundry deploy script, fully written
- [x] `ChainShieldGateway.abi.json` — ABI for frontend Wagmi integration
- [x] Full system design (contracts, Next.js structure, hook architecture, API routes)
- [x] Transfer flow defined (6-step UI flow)

### Remaining (not yet built)

- [ ] Deploy contracts to Sepolia and update `DEPLOYED_ADDRESSES.md`
- [ ] Next.js project scaffold (`npx create-next-app`)
- [ ] AppKit + Wagmi configuration (`lib/wagmi/config.ts`)
- [ ] `ChainSelector.tsx` component
- [ ] `TokenSelector.tsx` component
- [ ] `TransferForm.tsx` — main UI form
- [ ] `VerificationSteps.tsx` — live step status UI
- [ ] `SwapPreview.tsx` — swap rate + fee preview
- [ ] `useChainShield.ts` — main orchestration hook
- [ ] `/api/ai-verify` route — OpenAI integration
- [ ] `/api/security-check` route
- [ ] `/api/token-lookup` route
- [ ] `/shield/status/[msgId]` page — CCIP tracking
- [ ] `useTransferStatus.ts` — CCIP Explorer polling hook

---

## 14. Context About the Broader ChainPilot System

ChainShield is one of four services. The others (AutoPilot DCA, CrossVault, ChainAlert) exist in the original CLI-based version and will also be rebuilt as Next.js pages. The shared infrastructure (SecurityManager, TokenVerifier, ChainRegistry, ChainAlertRegistry, AutomatedTrader) supports all four services.

For ChainShield specifically, only SecurityManager and TokenVerifier are relevant. The other contracts belong to the other services.

The original system used:
- A CLI orchestrator as the user interface
- An SSE bridge server to connect CLI to a MetaMask web signer
- CRE (Chainlink Runtime Environment) workflows for AI processing
- Session-based authentication (sessionId + one-time token)

The new system replaces all of that with a standard Next.js web application. The CRE workflows are replaced by Next.js API routes. The CLI/bridge/session system is replaced by AppKit wallet connection.

---

## 15. Glossary

| Term | Definition |
|---|---|
| CCIP | Chainlink Cross-Chain Interoperability Protocol — the transport layer that moves tokens and messages between chains |
| CRE | Chainlink Runtime Environment — the decentralised compute layer from the original system (replaced by Next.js API routes in v2) |
| DON | Decentralised Oracle Network — Chainlink nodes that run CRE workflows (original system only) |
| ChainShieldGateway | The new main smart contract — single on-chain entry point for all ChainShield transfers |
| SwapAdapter | New contract wrapping Uniswap V3 — handles the pre-bridge token swap |
| SecurityManager | Existing deployed contract — platform-wide security gate, rate limits, blacklist |
| TokenVerifier | Existing deployed contract — on-chain ERC-20 token safety checks |
| ChainRegistry | Existing deployed contract — registry of supported chains and CCIP selectors |
| slippageBps | Slippage tolerance in basis points (1 bps = 0.01%). Default: 30 bps. Max: 50 bps (0.5%). |
| poolFee | Uniswap V3 fee tier: 500 (0.05%), 3000 (0.3%), 10000 (1%). Default: 3000. |
| ccipMessageId | bytes32 identifier returned by CCIP for every cross-chain message. Used to track delivery on ccip.chain.link |
| LINK fee | The LINK token cost paid to Chainlink for CCIP message delivery. Paid by ChainShieldGateway. |
| Feature ID 2 | The SecurityManager enum value for PROGRAMMABLE_TRANSFER — used by ChainShieldGateway when calling validateTransfer() |
| AppKit | WalletConnect's wallet connection UI library — replaces the original MetaMask-only web-signer |
| amountOutMinimum | The minimum acceptable swap output — computed as `amountIn * (10000 - slippageBps) / 10000` — enforced by SwapAdapter on-chain |