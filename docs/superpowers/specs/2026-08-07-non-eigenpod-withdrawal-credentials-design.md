# Non-EigenPod withdrawal credentials

Design for spinning up validators whose withdrawal credentials point at an
ether.fi contract instead of an EigenPod. Milestone: "Staking and AVS contract
changes are shipped for audit" of the EigenLayer consolidation project.

Covers STAKE-1824, 1825, 1826, 1827, 1829, 1830, 1831, 1832, 1833, 1834.

## Decisions taken

| Decision | Choice |
|---|---|
| Credential target for pod-less validators | `EtherFiNode` itself |
| Credential target storage | None; derived |
| New check in `LiquidityPool` | None |

### Why EtherFiNode is the credential target

`EtherFiNode` is already a `BeaconProxy` behind `etherFiNodeBeacon`, so one
`StakingManager.upgradeEtherFiNode` covers every instance. It already has
`fallback() payable`, `_sweepToLiquidityPool()`, and a manager-side `sweepFunds`.
`instantiateEtherFiNode(false)` already produces a pod-less node.

The load-bearing reason is enumeration. The oracle and DOSE already map
`pubkeyHash -> EtherFiNode`. Making the node the credential target means no
registry, no factory-event scan, and no new set for sweep and monitoring jobs to
walk. At 500k ETH and 32 ETH per validator that set would hold ~15,600 entries.

The cost is that `EtherFiNode` carries direct EIP-7002 and EIP-7251 branches
alongside its pod forwarding. That is two branches in two functions.

### Why LiquidityPool does not change

`StakingManager` reverts when a node's credential target cannot be resolved, so
an `LiquidityPool` check would duplicate it. `LiquidityPool` keeps
`_requireValidValidatorSize` and `_accountForEthSentOut` as they are.

Consequence to carry: nothing in the contracts bounds how much ETH enters the new
regime. That is an operational limit, not an on-chain one.

## The safety property

**A funded validator's credential target is fixed forever, so a node's credential
target must never change after the node is created.**

It already cannot, and no new state is needed to enforce it. A node's pod-ness is
fixed at instantiation by three existing facts:

1. `EtherFiNodesManager.createEigenPod(address node)` reverts `InvalidCaller`
   unless `msg.sender == stakingManager` (`EtherFiNodesManager.sol:95`).
2. `StakingManager`'s only call site is inside `instantiateEtherFiNode`, in the
   same transaction that deploys the node (`StakingManager.sol:111`). There is no
   post-creation path to attach a pod to an existing node.
3. `eigenPodManager.createPod()` reverts `EigenPodAlreadyExists` on a second
   call, and `disablePod` does not clear `ownerToPod`, so a pod address once set
   is permanent, including after retirement.

So `getEigenPod() == address(0)` is a stable, permanent property and the resolver
derives the target rather than storing it. A stored regime flag would be a second
source of truth for something already immutable, and could only drift from it.

It also keeps the storage layout byte-identical, verified with
`forge inspect <c> storageLayout` against master for all three contracts. These
are UUPS proxies, so an unchanged layout removes a whole class of upgrade risk.

**The invariant this rests on:** `createEigenPod` must remain reachable only from
`instantiateEtherFiNode`. Adding any other call site to `StakingManager` would
let a node's credential target change after validators are funded. A comment on
the resolver records this.

## Contract changes

### EtherFiNodesManager

One derived resolver, no new storage:

```solidity
function withdrawalCredentialTarget(address node) public view returns (address) {
    _validateNode(node);
    address pod = address(IEtherFiNode(node).getEigenPod());
    return pod == address(0) ? node : pod;
}
```

Every node deployed before this upgrade has a pod, so all of them keep resolving
to their pod with no backfill and no migration.

- `requestExecutionLayerTriggeredWithdrawal` and `requestConsolidation` take the
  per-request fee from the node rather than the pod, and emit the credential
  target in place of the pod address. The event signatures are unchanged.
- Both now require every request in a batch to belong to the node resolved from
  `requests[0]`, reverting `MixedNodeRequest` otherwise. With a pod, EigenLayer
  enforced this and reverted. The direct predeploy path has no such check: the
  predeploy accepts any pubkey from any caller and the consensus layer silently
  drops requests whose source withdrawal address is not the caller, so an
  unchecked batch would burn the fee and emit exit events for exits that never
  happen. `requestConsolidation` deliberately does not constrain the target,
  which may live outside the node.
- New `disablePod(address node)`, gated on the operating timelock because pod
  retirement is irreversible.
- New `withdrawDisabledPodETH(address node)`, gated on housekeeping operations to
  match `completeQueuedETHWithdrawals`.

### EtherFiNode

- `requestExecutionLayerTriggeredWithdrawal` forwards to the pod when there is
  one. Otherwise it calls the EIP-7002 predeploy at
  `0x00000961Ef480Eb55e80D19ad83579A64c007002` directly with calldata
  `abi.encodePacked(pubkey, amountGwei)` and the per-request fee as value. The
  predeploy authorises on `msg.sender` being the validator's withdrawal address,
  which for these validators is the node.
- `requestConsolidation` does the same against
  `0x0000BBdDc7CE488642fb579F8B00f3a590007251` with
  `bytes.concat(srcPubkey, targetPubkey)`.
- `getWithdrawalRequestFee()` and `getConsolidationRequestFee()` read the pod when
  there is one, otherwise the predeploy. Fee reads use `predeploy.staticcall("")`
  and require a 32-byte result, matching `EigenPod._getFee`.
- Any excess `msg.value` stays on the node and is swept to the LiquidityPool,
  which is where the pod path already left it, since the node is the pod's caller.
- New `disablePod()` calling `eigenPodManager.disablePod()`, since the node is the
  pod owner.
- New `withdrawDisabledPodETH()` calling
  `getEigenPod().withdrawDisabledPodETH(address(this))` then
  `_sweepToLiquidityPool()`.

### StakingManager

- `instantiateEtherFiNode(bool _createEigenPod)` is unchanged. It is the seam the
  whole project hangs off and it already supports pod-less nodes.
- All three creation paths resolve credentials through
  `withdrawalCredentialTarget` instead of `IEtherFiNode(node).getEigenPod()`:
  `createBeaconValidators`, `registerBeaconValidators` and
  `confirmAndFundBeaconValidators`. All three must agree bit-for-bit, which the
  single resolver guarantees by construction.
- `registerBeaconValidators` drops its `getEigenPod() == address(0)` revert and
  keeps the `deployedEtherFiNodes` check, which the resolver's `_validateNode`
  now also covers.

### EigenLayer interfaces

`disablePod()`, `restakingDisabled()` and `withdrawDisabledPodETH(address)` are
added to the local interface files. Signatures were taken from
`Layr-Labs/eigenlayer-contracts` branch `feat/v1.14.0-disable-burn` (PR #1758),
along with the predeploy addresses and exact calldata encoding read out of
`EigenPod.sol` on that branch, rather than from memory.

## Testing

`test/behaviour-tests/non-eigenpod-credentials.t.sol` inherits `PreludeTest` for
its mainnet-fork setUp, so the 42 existing pod-backed behaviour tests run
alongside the new ones and act as the regression signal for the old regime.

58 tests pass. Coverage:

- Resolver returns the node when there is no pod, the pod when there is one, and
  reverts `UnknownNode` for an address the protocol never deployed.
- A live mainnet node still resolves to exactly its pod.
- `createEigenPod` reverts `InvalidCaller` for privileged callers, so a target
  cannot change after instantiation.
- Full 1 ETH create then 31 ETH top-up flow against node credentials, with the
  expected credentials built literally rather than read back from the resolver.
  Deriving them from the resolver would make the test self-consistent and unable
  to catch a resolver bug.
- Deposit data built for any other target reverts `IncorrectBeaconRoot`.
- `registerBeaconValidators` still rejects undeployed nodes.
- Fees read from the predeploys when there is no pod.
- An exit on a pod-less validator reaches the EIP-7002 predeploy, asserted on the
  predeploy's balance delta.
- A batch mixing validators from two nodes reverts `MixedNodeRequest`.
- ETH on a pod-less node sweeps to the LiquidityPool.

**Verification note.** The suite was checked by mutation: dropping the pod-less
branch from the resolver fails 4 tests, including the full-flow test with
`IncorrectBeaconRoot`. Mutation runs need `forge test --force`. Test artifacts
embed implementation creation-bytecode via `new EtherFiNodesManager(...)`, and
incremental compilation does not invalidate them, so a mutated implementation is
compiled but never deployed into the fork and every test still passes.

**`disablePod` cannot be fork-tested.** v1.14.0 is not on mainnet, so the live
`EigenPodManager` has no `disablePod` selector and no fallback, meaning the call
reverts rather than silently succeeding. That distinction matters: a no-op would
let us believe a pod was retired and consolidate out of a live pod, cutting the
beacon slashing factor. The test asserts the revert today and probes
`restakingDisabled()` so it flips to the success path once v1.14.0 lands.

Pre-existing failures on master, unrelated to this change and confirmed identical
at `b4a09680`: `test/integration-tests/Validator-Flows.t.sol` fails in `setUp`
with `NotRegistered()`, and `test/LiquidityPool.t.sol` fails 16 of 119. Both are
mainnet-state drift from forking at the latest block.

## Out of scope

- Rate limiter re-sizing for drain volume (STAKE-1835), a parameter change that
  ships through 3CP rather than in this diff.
- Removing `depositIntoStrategy` from `EtherFiRestaker` (STAKE-1836).
- Certora spec updates (STAKE-1838).
- Oracle, DOSE and protocol-ops changes.
- The AVS close-out track.
