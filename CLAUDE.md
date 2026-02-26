# EtherFi Smart Contracts

## Build & Test

```bash
forge build                                          # compile
forge test --match-test <name>                       # unit tests (no RPC needed)
forge test --match-test <name> --fork-url $MAINNET_RPC_URL  # mainnet fork tests
```

- Solidity 0.8.27, Foundry with 1500 optimizer runs
- Env vars: `MAINNET_RPC_URL`, `FORK_RPC_URL` (optional override), `VALIDATOR_DB`, `BEACON_NODE_URL`

## Project Layout

```
src/                    # Core contracts
  EtherFiNode.sol       # Per-validator-group contract, owns an EigenPod
  EtherFiNodesManager.sol # Entry point for pod operations (0x8B71...6F)
  LiquidityPool.sol     # Main ETH pool (0x3088...16)
  EtherFiRestaker.sol   # Manages stETH restaking via EigenLayer (0x1B7a...Ff)
  EtherFiRedemptionManager.sol # Instant redemptions with rate limiting (0xDadE...e0)
  StakingManager.sol    # Validator lifecycle
  WeETH.sol / EETH.sol  # Token contracts
  eigenlayer-interfaces/ # EigenLayer interface definitions (no implementations)
test/
  TestSetup.sol         # Base test with initializeRealisticFork() / initializeTestingFork()
  behaviour-tests/      # PreludeTest - validator lifecycle on mainnet fork
  integration-tests/    # Cross-contract integration tests on mainnet fork
  fork-tests/           # Additional fork-based tests
script/
  operations/           # Operational tooling (Python + Solidity for Gnosis Safe txns)
  deploys/Deployed.s.sol # All mainnet deployed addresses as constants
```

## Architecture

- Validator pubkey -> `etherFiNodeFromPubkeyHash` -> EtherFiNode -> `getEigenPod()` -> EigenPod
- `calculateValidatorPubkeyHash`: `sha256(pubkey + bytes16(0))`
- Legacy validators use integer IDs; new validators use pubkey hashes. `etherfiNodeAddress(id)` resolves both via a heuristic on upper bits.
- UUPS proxy pattern throughout. Upgrades go through timelocks.

## Key Addresses (Mainnet)

| Role | Address |
|------|---------|
| OPERATING_TIMELOCK | `0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a` |
| UPGRADE_TIMELOCK | `0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761` |
| ROLE_REGISTRY | `0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9` |
| EIGENLAYER_DELEGATION_MANAGER | `0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A` |
| EIGENLAYER_POD_MANAGER | `0x91E677b07F7AF907ec9a428aafA9fc14a0d3A338` |
| LIDO_WITHDRAWAL_QUEUE | `0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1` |

Full list in `script/deploys/Deployed.s.sol`.

## Access Control Roles

- `ETHERFI_NODES_MANAGER_POD_PROVER_ROLE` -> startCheckpoint, verifyCheckpointProofs
- `ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE` -> queueETHWithdrawal, completeQueuedETHWithdrawals
- `ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE` -> setCapacity, setRefillRate, setLowWatermark, setExitFee
- `OPERATING_TIMELOCK` holds the redemption manager admin role

## Test Setup Patterns

Two fork modes in `TestSetup.sol`:
- `initializeRealisticFork(MAINNET_FORK)` — uses real mainnet contracts at their deployed addresses. Forks at **latest block** (no pinned block), so mainnet state drifts.
- `initializeTestingFork(MAINNET_FORK)` — deploys fresh contracts on a mainnet fork.

`PreludeTest` (behaviour-tests) has its own setup: forks mainnet, upgrades contracts in-place, deploys fresh RateLimiter, grants roles to test addresses (`admin`, `eigenlayerAdmin`, `podProver`, `elExiter`).

## Mainnet Fork Test Decisions

These are hard-won lessons. Follow them when writing or fixing fork tests:

1. **Never assume zero baselines.** Mainnet contracts have live state (pending withdrawals, balances, queued operations). Always capture initial values and assert deltas relative to them.

2. **EigenPod storage slot 52** = `withdrawableRestakedExecutionLayerGwei` (uint64, packed with `proofSubmitter` address in same slot). When poking this with `vm.store`:
   - Set it BEFORE any `queueETHWithdrawal` / `completeQueuedETHWithdrawals` calls
   - Use a large value (10000+ ETH in gwei) to cover pre-existing queued withdrawals from mainnet state
   - Also `vm.deal` ETH to the EigenPod so it can actually transfer funds during withdrawal completion
   - `completeQueuedETHWithdrawals` iterates ALL eligible queued withdrawals, not just the one you queued in the test

3. **RedemptionManager lowWatermark blocks redemptions on fork.** `lowWatermarkInETH = totalPooledEther * lowWatermarkInBpsOfTvl / 10000`. On mainnet, TVL is millions of ETH, so even a 1% watermark = tens of thousands ETH. Test deposits of a few thousand ETH can never exceed this. Fix: `setLowWatermarkInBpsOfTvl(0, token)` via `OPERATING_TIMELOCK` at start of test.

4. **Rate limiter (BucketLimiter)** must also be configured in fork tests: `setCapacity()` + `setRefillRatePerSecond()` + `vm.warp(block.timestamp + 1)` to refill.

## EigenLayer Integration

- EigenPod key function selectors: `currentCheckpointTimestamp()` = `0x42ecff2a`, `lastCheckpointTimestamp()` = `0xee94d67c`, `activeValidatorCount()` = `0x2340e8d3`
- EigenPod storage slots used in tests: slot 52 = `withdrawableRestakedExecutionLayerGwei`, slot 57 = `activeValidatorCount`
- Beacon ETH strategy address: `0xbeaC0eeEeeeeEEeEeEEEEeeEEeEeeeEeeEEBEaC0`
- Withdrawal delay: `EIGENLAYER_WITHDRAWAL_DELAY_BLOCKS = 100800` blocks (~14 days)

## Operations Tooling

- Python scripts in `script/operations/` use `validator_utils.py` for shared DB/beacon utilities
- Solidity scripts in same dirs generate Gnosis Safe transactions
- DB tables: `etherfi_validators` (pubkey, id, phase, status, node_address), `MainnetValidators` (pubkey, eigen_pod_contract, etherfi_node_contract)
- Withdrawal credentials format: `0x01 + 22_zero_chars + 40_char_eigenpod_address`
