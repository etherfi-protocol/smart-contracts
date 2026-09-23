# ether.fi's Liquid Staking Protocol Contracts

Solidity contracts behind ether.fi's liquid staking on Ethereum mainnet. Users deposit ETH
into the `LiquidityPool` and receive eETH, a rebasing token, or its non-rebasing wrapper weETH.
The protocol runs validators whose withdrawal credentials point at EigenLayer EigenPods.

[Docs](https://etherfi.gitbook.io/etherfi/) ·
[Audits](audits/) ·
[Deployed addresses](script/deploys/Deployed.s.sol) ·
[weETH cross-chain](https://github.com/etherfi-protocol/weETH-cross-chain/)

## Contracts

| Module | Path | Contracts |
|--------|------|-----------|
| Core | `src/core` | `LiquidityPool`, `EETH`, `WeETH` |
| Staking | `src/staking` | `StakingManager`, `EtherFiNodesManager`, `EtherFiNode`, `AuctionManager`, `NodeOperatorManager` |
| Restaking | `src/restaking` | `EtherFiRestaker`, `RestakingRewardsRouter` |
| Deposits | `src/deposits` | `DepositAdapter`, `Liquifier`, `LiquidRefer` |
| Withdrawals | `src/withdrawals` | `WithdrawRequestNFT`, `PriorityWithdrawalQueue`, `EtherFiRedemptionManager`, `WeETHWithdrawAdapter` |
| Oracle | `src/oracle` | `EtherFiOracle`, `EtherFiAdmin` |
| Rewards | `src/rewards` | `EtherFiRewardsRouter`, `CumulativeMerkleRewardsDistributor` |
| Governance | `src/governance` | `RoleRegistry`, `EtherFiTimelock`, `Blacklister`, `RevokeAdmin`, rate limiting |
| Helpers | `src/helpers` | `AddressProvider`, `EtherFiViewer`, `EtherFiOperationParameters` |

`src/archive` holds retired contracts kept for storage-layout reference.

### Key mainnet addresses

| Contract | Address |
|----------|---------|
| LiquidityPool | [`0x308861A430be4cce5502d0A12724771Fc6DaF216`](https://etherscan.io/address/0x308861A430be4cce5502d0A12724771Fc6DaF216) |
| eETH | [`0x35fA164735182de50811E8e2E824cFb9B6118ac2`](https://etherscan.io/address/0x35fA164735182de50811E8e2E824cFb9B6118ac2) |
| weETH | [`0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee`](https://etherscan.io/address/0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee) |
| EtherFiNodesManager | [`0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F`](https://etherscan.io/address/0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F) |
| StakingManager | [`0x25e821b7197B146F7713C3b89B6A4D83516B912d`](https://etherscan.io/address/0x25e821b7197B146F7713C3b89B6A4D83516B912d) |
| WithdrawRequestNFT | [`0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c`](https://etherscan.io/address/0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c) |
| PriorityWithdrawalQueue | [`0x35e7D6feF6f72aDd3c3e39dEc6d9CCc29e3345FA`](https://etherscan.io/address/0x35e7D6feF6f72aDd3c3e39dEc6d9CCc29e3345FA) |
| EtherFiRedemptionManager | [`0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0`](https://etherscan.io/address/0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0) |
| EtherFiRestaker | [`0x1B7a4C3797236A1C37f8741c0Be35c2c72736fFf`](https://etherscan.io/address/0x1B7a4C3797236A1C37f8741c0Be35c2c72736fFf) |
| EtherFiOracle | [`0x57AaF0004C716388B21795431CD7D5f9D3Bb6a41`](https://etherscan.io/address/0x57AaF0004C716388B21795431CD7D5f9D3Bb6a41) |

`script/deploys/Deployed.s.sol` lists every deployed contract, timelock, and Safe.

## Architecture

- Every contract sits behind a UUPS proxy. Upgrades go through the upgrade timelock; parameter
  changes go through the operating timelock.
- `RoleRegistry` owns all role checks. Contracts ask it before running privileged functions.
- Each `EtherFiNode` owns one EigenPod. `EtherFiNodesManager` is the entry point for pod
  operations: checkpoints, withdrawals, consolidations, and exits.
- `EtherFiOracle` reports rewards and validator state. `EtherFiAdmin` applies those reports to
  the `LiquidityPool` rebase and finalizes withdrawal requests.
- `EtherFiRedemptionManager` handles instant redemptions under a bucket rate limiter.
  `WithdrawRequestNFT` and `PriorityWithdrawalQueue` handle queued withdrawals.

## Getting started

Requirements: [Foundry](https://book.getfoundry.sh/getting-started/installation) (CI pins
v1.5.1) and a mainnet RPC URL for fork tests.

```bash
git clone https://github.com/etherfi-protocol/smart-contracts.git
cd smart-contracts
git submodule update --init --recursive
forge build
```

The build uses Solidity 0.8.27 with 1500 optimizer runs.

### Tests

```bash
export MAINNET_RPC_URL=<your_rpc_url>

forge test                                   # all tests
forge test --match-test <name>               # one test
forge test --match-path "test/invariant/*"   # invariant suite
forge test --match-path "test/fork-tests/*" --fork-url $MAINNET_RPC_URL
```

| Directory | Contents |
|-----------|----------|
| `test/*.t.sol` | Unit tests per contract |
| `test/invariant` | Stateful invariant fuzzing |
| `test/integration-tests` | Cross-contract flows on a mainnet fork |
| `test/fork-tests` | Upgrade and migration checks against live state |
| `test/behaviour-tests` | Validator lifecycle on a mainnet fork |

Fork tests run against the latest block, so assert deltas against the live state you read at
setup instead of assuming zero balances.

### Formal verification

Certora specs live in `certora/specs` with run configs in `certora/config`:

```bash
certoraRun certora/config/LiquidityPoolPeg.conf
```

Configs cover `LiquidityPool` peg and share accounting, `EtherFiOracle`, and `RoleRegistry`
authority.

## Repository layout

| Path | Purpose |
|------|---------|
| `src/` | Protocol contracts |
| `test/` | Foundry tests |
| `certora/` | Formal verification specs and configs |
| `script/` | Deploy, upgrade, and operations scripts (Solidity and Python) |
| `operations/`, `proposals/` | Gnosis Safe and timelock transaction batches |
| `deployment/`, `release/` | Deployment artifacts and release records |
| `audits/` | Audit reports |

## Security

Certora, Zellic, Nethermind, Halborn, Omniscia, Decurity, Solidified, Paladin, CertiK, and
Hats Finance have audited these contracts. Reports sit in [`audits/`](audits/); the most
recent is the Certora 26Q2 Security Upgrade review (June 2026).

CI runs the Forge test suite and a storage-layout check on pull requests into `master`, which
catches upgrades that would shift proxy storage.

Report vulnerabilities through the ether.fi bug bounty program. Do not open public issues for
security bugs.

## License

MIT. See the SPDX header in each source file.
