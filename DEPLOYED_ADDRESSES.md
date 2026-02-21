# Deployed Addresses Ledger

Use this file as the canonical source of deployed infrastructure addresses and proof tx/message IDs.

Last updated: 2026-02-21

## Feature 3: Programmable Token Transfer

### Ethereum Sepolia (source)
- Chain ID: `11155111`
- Selector: `16015286601757825753`
- Router: `0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59`
- LINK: `0x779877A7B0D9E8603169DdbD7836e478b4624789`
- CCIP-BnM (source): `0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05`
- ProgrammableTokenSender: `0xc93A5d3BdA648bb99B8F6990e4E88C94241Cd838`

Recent txs:
- `updateExtraArgs`: `0x7aa04b0414ac7a7231841435d10ea6382ebe184fec836cfcf56e6ff6883272d6`
- `approve(BnM)`: `0xe941abc7e24563e451771fb566d1eb80e4ca0a8f8be5a84af9a801403e3fd0bd`
- `sendPayLink`: `0x71f5d34dcf2a5c86ba2125e2d4d10b0a160d4ce3b655911dad1def7f72b9ed5f`

Message IDs:
- `0x5236c01c1c57b2a74261935a14b54cee7e06947a7ed8212f6a952207e908ca25`

### Polygon Amoy (destination)
- Chain ID: `80002`
- Selector: `16281711391670634445`
- Router: `0x9C32fCB86BF0f4a1A8921a9Fe46de3198bb884B2`
- ProgrammableTokenReceiver: `0x7E050e0D771dBcf0BcBD6f00b8beAa781667319c`
- Sender allowlisted for Sepolia: `0xc93A5d3BdA648bb99B8F6990e4E88C94241Cd838`

Recent txs:
- `deploy receiver`: `0x689b5b3bc6f8e775a9020ed7866eb3e40fa7b7711a95ce694ca653f0143ad23a`
- `allowlistSourceChain(sepolia)`: `0x072905cbdf6d3e8668704527f0aef82c569ab14a2d478aff019b7b8f659c1c81`
- `allowlistSender(sepolia sender)`: `0xc1444ddce559832847aed7f70fba1e955d35e940d16134fe53210ee56a7bad24`

Mapped destination token observed from delivery logs:
- Amoy minted/released token: `0xcab0EF91Bee323d1A617c0a027eE753aFd6997E4`

Recipient used in latest test transfer:
- `0xb3CcDfCC821fC7693e0CbF4b352f7Ca51b33c89B`

## Template: Add New Deployments

```md
### <Network Name>
- Chain ID:
- Selector:
- Router:
- LINK:
- Contract:
- Tx hash:
- Verification URL:
```

