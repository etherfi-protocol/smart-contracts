# PR #485 review — EigenPod dependencies on the validator spin-up path

Scope: verify that spinning up a new validator no longer depends on an EigenPod, and that
`EtherFiNode` is the credential target when a node has no pod.

## On-chain spin-up path, after this review

| Step | Site | Credential target | State |
|---|---|---|---|
| 1. Register (1 ETH) | `StakingManager.registerBeaconValidators:174` | `withdrawalCredentialTarget` | correct |
| 2. Create (1 ETH deposit) | `StakingManager.createBeaconValidators:133` | `withdrawalCredentialTarget` | correct |
| 3. Oracle approval | `EtherFiAdmin._approveValidators:378` | pod-or-node, resolved raw | **fixed here** |
| 4. Fund to full size | `StakingManager.confirmAndFundBeaconValidators:211` | `withdrawalCredentialTarget` | correct |

`StakingManager.registerBeaconValidators` also drops its `getEigenPod() != address(0)`
precondition, so a pod-less node can enter the flow at all.

## P1 — `EtherFiAdmin._approveValidators` hardcoded the EigenPod

`src/oracle/EtherFiAdmin.sol` was not in the PR diff. It built withdrawal credentials from
`IEtherFiNode(node).getEigenPod()` directly. For a pod-less node that is `address(0)`, so it
baked `0x02 + 11 zero bytes + address(0)` credentials and computed a deposit root from them.

`EtherFiAdmin` is the only production caller of `LiquidityPool.confirmAndFundBeaconValidators`
(`EtherFiAdmin.sol:301` → `:391`). Downstream, `StakingManager.confirmAndFundBeaconValidators`
recomputes the root from `withdrawalCredentialTarget` (= the node). The two roots disagree, so
every pod-less validator reverts `IncorrectBeaconRoot` at approval and strands at 1 ETH.

Fixed: resolve the target with the same pod-or-node rule, raw rather than through the validated
`withdrawalCredentialTarget`, so legacy nodes missing from `deployedEtherFiNodes` are not newly
blocked. When both sides succeed the values are identical by construction.

## P2 — no test covered the oracle approval path (fixed)

`test/behaviour-tests/non-eigenpod-validator-lifecycle.t.sol:101,216,249` and
`non-eigenpod-credentials.t.sol:138` call `liquidityPool.confirmAndFundBeaconValidators`
directly, skipping `EtherFiAdmin`. That is why the P1 above was invisible to the suite.

Added `test/integration-tests/PodLess-Validator-Flows.t.sol`, which runs the spin-up end to end
through the real components: whitelist the node operator, submit a bid, register the validator
spawner, create a pod-less `EtherFiNode`, deposit 1 ETH against 0x02 credentials naming the node,
submit an oracle report to consensus, `EtherFiAdmin.executeTasks`, then
`executeValidatorApprovalTask` to fund the remainder. Nothing hand-builds the top-up
`DepositData` — `_approveValidators` builds it, which is the whole point.

Three tests:

- `test_podLessValidator_spinsUpAndFundsThroughOracle` — the pod-less path, asserting the node
  never gets a pod and the full validator size leaves the LP.
- `test_podBackedValidator_spinsUpAndFundsThroughOracle` — the same path with a pod, so the
  pod-less result reads as a difference in credential target and nothing else.
- `test_credentialTarget_isNodeWithoutPod_andPodWithOne` — pins the 0x02 credential layout and
  both target resolutions directly.

The suite replaces the hardcoded `AVS_OPERATOR_1/2` committee dance with `_seedFreshCommittee`,
which reads `numActiveCommitteeMembers` and adds `N+2` fresh members so they alone hold a strict
majority. That keeps report submission independent of which mainnet committee members happen to
be registered at the forked block.

## P3 — remaining hardcoded pods, all off the critical path

- `script/hoodi/StakingPart2_CreateValidator.s.sol:75` — built deposit credentials from
  `getEigenPod()`. Switched to `withdrawalCredentialTarget`.
- `script/validator-key-gen/transactions.s.sol:317` — same, in the keygen fixture helper.
  Switched to `withdrawalCredentialTarget`.
- `script/hoodi/StakingPart1_Setup.s.sol:169` — logs the pod after `instantiateEtherFiNode(true)`.
  Left alone; it deliberately creates a pod.
- `src/helpers/EtherFiViewer.sol:50-96` — every view routed through `_getEigenPod`, so all of
  them revert on a pod-less node. Moved to `src/archive/EtherFiViewer.sol`; the three import
  sites (`test/EtherFiViewer.t.sol`, the two `script/upgrades/reaudit-fixes/` scripts) now point
  at `@etherfi/archive/EtherFiViewer.sol`.

## Dismissed

- **Credential target flipping mid-life.** `EtherFiNodesManager.createEigenPod:96` is gated to
  `msg.sender == stakingManager`, and `StakingManager` only calls it inside
  `instantiateEtherFiNode`. The target really is fixed per node, as the doc comment claims.
- **Off-chain deposit-data generation.** No in-repo Python builds creation-time withdrawal
  credentials; the credential-handling scripts under `script/operations/` are all
  post-creation (consolidation, unrestaking, withdrawals). The keygen service lives outside
  this repo and must be updated to read `withdrawalCredentialTarget`.

## Verification status

- `forge build` — clean, no errors.
- `PodLess-Validator-Flows.t.sol` — 3/3 pass on a mainnet fork.
- Related suites — 274 pass across `non-eigenpod-*`, `oracle-podless-funding`,
  `EtherFiNodesManager`, and `EtherFiViewer`.

### Mutation check

The new suite was verified to catch the P1 defect rather than merely pass alongside it. With
`if (credentialTarget == address(0)) credentialTarget = node;` removed from
`EtherFiAdmin._approveValidators` and a full rebuild:

- `test_podLessValidator_spinsUpAndFundsThroughOracle` — FAILS `IncorrectBeaconRoot()`
- `test_podBackedValidator_spinsUpAndFundsThroughOracle` — still passes

Restoring the line returns all three to green. Note that `forge test` incremental compilation
silently reused the stale artifact on the first mutated run and reported a false pass; `--force`
is required for a trustworthy mutation check here.

### Known pre-existing failure, not from this work

`test/integration-tests/Validator-Flows.t.sol` fails in `setUp()` with `NotRegistered()`. Its
`_syncOracleReportState` calls `removeCommitteeMember(AVS_OPERATOR_1, ...)` against a fork of the
latest block, and those addresses are no longer registered committee members on mainnet. The file
is untouched by this branch. `_seedFreshCommittee` in the new suite is the pattern that fixes it.
