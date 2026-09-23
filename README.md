# ether.fi's Liquid Staking Protocol Contracts

Solidity contracts behind ether.fi's liquid staking on Ethereum mainnet. Users deposit ETH
into the `LiquidityPool` and receive eETH, a rebasing token, or its non-rebasing wrapper weETH.
The protocol runs validators whose withdrawal credentials point at EigenLayer EigenPods.

[Docs](https://etherfi.gitbook.io/etherfi/) ·
[Audits](audits/) ·
[Deployed addresses](https://etherfi.gitbook.io/etherfi/developers/contracts-and-integrations/deployed-contracts) ·
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
| Helpers | `src/helpers` | `AddressProvider`, `EtherFiViewer` |

`src/archive` holds retired contracts kept for storage-layout reference.

Contract addresses live in the ether.fi docs under
[Deployed Contracts](https://etherfi.gitbook.io/etherfi/developers/contracts-and-integrations/deployed-contracts).

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

## 📄 License

ether.fi is open-source and licensed under the [MIT License](LICENSE).

---

<p align="center">Built with ❤️ by the ether.fi team</p>
