# Feature 6: Global Token Verification and Security

## Scope
Feature 6 adds a platform security layer for Features 1-5.

V1 (this phase):
- On-chain Layer1 token checks (`TokenVerifier`)
- Cross-feature policy gate (`SecurityManager`)
- Rollout modes: `MONITOR` then `ENFORCE`
- No JavaScript/Functions execution yet (reserved for `token-verification-v2` in CRE)

## Contracts
- `src/TokenVerifier.sol`
- `src/SecurityManager.sol`

## Enforcement model
- `MONITOR`:
  - Violations are logged as incidents
  - Operations continue
- `ENFORCE`:
  - Violations revert (fail-closed)

## SecurityManager API (V1)
- `setEnforcementMode(EnforcementMode mode)`
- `validateAction(address user, FeatureId feature, bytes32 actionKey, uint256 weight)`
- `validateTransfer(address user, FeatureId feature, address token, uint256 amount)`
- `authoriseCaller(address caller, bool authorised)`
- `pause(bytes32 reason) / unpause()`
- `setGlobalRateLimit(uint256 limit)`
- `setCustomRateLimit(address user, uint256 limit)`
- `setAmountLimit(address token, uint256 limit)`
- `logIncident(address actor, FeatureId feature, bytes32 reason, bytes32 ref)`
- `getSystemHealth()`
- `getRecentIncidents(uint256 count)`

Feature enum values:
- `0`: MESSAGE
- `1`: TOKEN_TRANSFER
- `2`: PROGRAMMABLE_TRANSFER
- `3`: AUTOMATED_TRADER
- `4`: STORAGE

## TokenVerifier API (V1)
- `verifyTokenLayer1(address token)`
- `isTransferSafe(address token, uint256 amount)`
- `addToAllowlist(address token, bool allowed)`
- `addToBlocklist(address token, string reason)`
- `removeFromBlocklist(address token)`
- `setMaxTransferLimit(address token, uint256 limit)`
- `setAuthorisedCaller(address caller, bool allowed)`
- `getStatus(address token)`
- `getVerdict(address token)`

Layer1 checks:
- token address has bytecode
- ERC20 metadata functions exist
- decimals in `[1..18]`
- totalSupply > 0
- blocklist/allowlist + max transfer limit

## Integration status in this branch
Implemented sender hooks:
- `src/MessageSender.sol` (`validateAction`)
- `src/TokenTransferSender.sol` (`validateTransfer` + `isTransferSafe`)
- `src/ProgrammableTokenSender.sol` (`validateAction`, `validateTransfer`, `isTransferSafe`)

Each sender has:
- `configureSecurity(address securityManager, address tokenVerifier)`
- zero addresses => security disabled (migration-safe)

## Notes for Features 4 and 5
Feature IDs for `AUTOMATED_TRADER` and `STORAGE` are already reserved in `SecurityManager`.
If those contracts are present in another branch, authorise them and wire the same gate pattern.

## V2 (CRE)
`token-verification-v2` will add:
- async deep risk analysis (JS/API)
- verdict persistence pipeline
- policy reactions driven by CRE workflows
