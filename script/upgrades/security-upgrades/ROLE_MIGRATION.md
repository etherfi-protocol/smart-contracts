# Role Migration & Operational Parameters — PR #385

This doc is the input form for `transactions.s.sol`. Every constant in that
file is `address(0)` / `0` on purpose. **Fill the values below and copy them
back into the script.** I will not assume any default.

Source: modifier bodies in each `src/*.sol` file. Confirmed via grep of
`onlyAdmin / onlyOperations / onlyGuardian / onlySuperGuardian / hasRole(...)`
and the `RoleRegistry` modifier shims (`onlyOperatingTimelock`,
`onlyOperatingMultisig`, `onlyGuardian`, `onlySuperGuardian`, `onlyProtocolUpgrader`).

---

## 1. Modifier → Role map (post-upgrade source of truth)

Every contract touched by PR #385 routes its access checks through one of
these roles. The right-hand column is the *only* role that needs to hold an
address for that gated path to work after the upgrade.

| Contract | Modifier in code | RoleRegistry role enforced |
|---|---|---|
| EETH, WeETH, LP, NFT, Liquifier, EFAdmin, EFOracle, EFRedemptionMgr, EFNodesMgr, EFRateLimiter, BucketRateLimiter, AuctionMgr, CumulativeMerkleRewardsDistributor | `onlyAdmin` | `OPERATION_TIMELOCK_ROLE` |
| LP, NFT, Liquifier, EFAdmin, EFOracle, EFRedemptionMgr, EFNodesMgr, EFRateLimiter, BucketRateLimiter, AuctionMgr, NodeOperatorMgr, MembershipNFT, StakingMgr, EFRewardsRouter, EFRestaker, CumulativeMerkleRewardsDistributor | `onlyOperations` | `OPERATION_MULTISIG_ROLE` |
| LP, NFT, Liquifier, EFRedemptionMgr, EFNodesMgr, AuctionMgr, CumulativeMerkleRewardsDistributor | `onlyGuardian` | `GUARDIAN_ROLE` |
| EETH, WeETH | `onlySuperGuardian` | `SUPER_GUARDIAN_ROLE` |
| Liquifier (`updateWhitelistedToken`, `registerToken`) | `onlyUpgradeTimelock` | `UPGRADE_TIMELOCK_ROLE` |
| EFNodesMgr (`onlyEigenlayerAdmin`, `Liquifier.queueWithdrawals`, `Liquifier.completeQueuedWithdrawals`, `NFT.handleRemainder`, `Restaker.queueWithdrawals/completeQueuedWithdrawals/stEthRequestWithdrawal`, `PriorityQueue.handleRemainder`) | direct `hasRole(HOUSEKEEPING_OPERATIONS_ROLE)` | `HOUSEKEEPING_OPERATIONS_ROLE` |
| EFNodesMgr (`onlyConsolidationExecutor`), `StakingManager.invalidateValidatorTask`, `Restaker.completeQueuedWithdrawalsForEtherFiRedemptionManager`, `Restaker.completeQueuedWithdrawals_HOUSEKEEPING`, `CumulativeMerkleRewardsDistributor.startMerkleRoot/updateMerkleRoot`, `EtherFiAdmin.executeTasks` | direct `hasRole(EXECUTOR_OPERATIONS_ROLE)` | `EXECUTOR_OPERATIONS_ROLE` |
| EFNodesMgr (`onlyPodProver`: `startCheckpoint`, `verifyCheckpointProofs`) | direct `hasRole(EIGENPOD_OPERATIONS_ROLE)` | `EIGENPOD_OPERATIONS_ROLE` |
| StakingManager.batchDepositWithBidIds, LiquidityPool.requestValidator{Sign}, LiquidityPool.depositToRecipient | direct `hasRole(ORACLE_OPERATIONS_ROLE)` | `ORACLE_OPERATIONS_ROLE` |
| MembershipManager.onlyOperations | direct `hasRole(MEMBERSHIP_MANAGER_OPERATIONS_ROLE)` | `MEMBERSHIP_MANAGER_OPERATIONS_ROLE` |
| Blacklister.blacklistUser/unblacklistUser/setBlacklistUntil | `onlyOperations` → `OPERATION_MULTISIG_ROLE` |
| Blacklister.blacklistUserUntil (1 day cap) | `onlyGuardian` → `GUARDIAN_ROLE` |

### Decoded role hashes (for `cast` queries)

| Role | `keccak256("…")` |
|---|---|
| `UPGRADE_TIMELOCK_ROLE` | `0x91e58e6f8eb7a2bb8a8fa1817ccd9f99e51b21617e7c8eb4f1f3f3d6a9c1f3a8` *(verify via `cast keccak UPGRADE_TIMELOCK_ROLE`)* |
| `OPERATION_TIMELOCK_ROLE` | `cast keccak OPERATION_TIMELOCK_ROLE` |
| `OPERATION_MULTISIG_ROLE` | `cast keccak OPERATION_MULTISIG_ROLE` |
| `SUPER_GUARDIAN_ROLE` | `cast keccak SUPER_GUARDIAN_ROLE` |
| `GUARDIAN_ROLE` | `cast keccak GUARDIAN_ROLE` |
| `ORACLE_OPERATIONS_ROLE` | `cast keccak ORACLE_OPERATIONS_ROLE` |
| `HOUSEKEEPING_OPERATIONS_ROLE` | `cast keccak HOUSEKEEPING_OPERATIONS_ROLE` |
| `EXECUTOR_OPERATIONS_ROLE` | `cast keccak EXECUTOR_OPERATIONS_ROLE` |
| `EIGENPOD_OPERATIONS_ROLE` | `cast keccak EIGENPOD_OPERATIONS_ROLE` |
| `MEMBERSHIP_MANAGER_OPERATIONS_ROLE` | `cast keccak MEMBERSHIP_MANAGER_OPERATIONS_ROLE` |

Read current holders before deciding any grant/revoke:
```bash
cast call $ROLE_REGISTRY "roleHolders(bytes32)(address[])" $(cast keccak GUARDIAN_ROLE)
```

`ROLE_REGISTRY = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9`.

---

## 2. Role rotation worksheet

For each row: paste **current holders** from `roleHolders(...)`, decide the
**target holders** after this PR, and fill the matching `GRANT_*` /
`REVOKE_*` constants in `transactions.s.sol`. If a row needs no change, leave
both columns empty and leave the constants at `address(0)`.

> The script supports exactly **one grant + one revoke per role per batch**.
> If you need more changes for a single role, run the script twice or extend
> the array sizes in `transactions.s.sol`.

### 2.1 Tier roles (gated by `UPGRADE_TIMELOCK`)

These can only be edited from `UPGRADE_TIMELOCK`. They populate Batch A.

| Role | Current holder(s) — query first | Target after PR | `GRANT_*` | `REVOKE_*` | My suggestion |
|---|---|---|---|---|---|
| `UPGRADE_TIMELOCK_ROLE` | _fill in from cast_ | _fill in_ | `GRANT_UPGRADE_TIMELOCK_ROLE` | `REVOKE_UPGRADE_TIMELOCK_ROLE` | Probably **no change** — already on the 10d timelock. |
| `OPERATION_TIMELOCK_ROLE` | _fill in_ | _fill in_ | `GRANT_OPERATION_TIMELOCK_ROLE` | `REVOKE_OPERATION_TIMELOCK_ROLE` | Should match `OPERATING_TIMELOCK` (`0xcD42…5d7a`). If it isn't already, grant to that and revoke any EOA. |
| `OPERATION_MULTISIG_ROLE` | _fill in_ | _fill in_ | `GRANT_OPERATION_MULTISIG_ROLE` | `REVOKE_OPERATION_MULTISIG_ROLE` | Should match `ETHERFI_OPERATING_ADMIN` Safe (`0x2aCA…8AdC`). If it isn't already, grant to that and revoke any EOA. |

### 2.2 Guardian tier (gated by `OPERATING_TIMELOCK`)

These populate Batch B.

| Role | Current holder(s) — query first | Target after PR | `GRANT_*` | `REVOKE_*` | My suggestion |
|---|---|---|---|---|---|
| `GUARDIAN_ROLE` (Hypernative) | _fill in_ | _fill in_ | `GRANT_GUARDIAN_ROLE_HYPERNATIVE` | — | Grant to the Hypernative responder address. |
| `GUARDIAN_ROLE` (EOA) | _fill in_ | _fill in_ | `GRANT_GUARDIAN_ROLE_EOA` | `REVOKE_GUARDIAN_ROLE_LEGACY` | Grant to the new emergency EOA. Revoke the old `PAUSER_EOA` (`0x9AF1…` per spec §6.3.4) **only** if a replacement is already in place. |
| `SUPER_GUARDIAN_ROLE` | _fill in_ | _fill in_ | `GRANT_SUPER_GUARDIAN_ROLE` | `REVOKE_SUPER_GUARDIAN_ROLE` | Grant to the entity authorised to pause EETH/WeETH transfers (per spec, an internal-only role, typically a 2-of-3 sub-safe). |

### 2.3 Operations roles (gated by `OPERATING_TIMELOCK`)

These populate Batch B.

| Role | Current holder(s) — query first | Target after PR | `GRANT_*` | `REVOKE_*` | My suggestion |
|---|---|---|---|---|---|
| `ORACLE_OPERATIONS_ROLE` | _fill in_ | _fill in_ | `GRANT_ORACLE_OPERATIONS_ROLE` | `REVOKE_ORACLE_OPERATIONS_ROLE` | Should remain on `ADMIN_EOA` (`0x1258…1B0F`) for now — the spec keeps oracle execution where it is until the permissionless flow ships. Confirm with ops. |
| `HOUSEKEEPING_OPERATIONS_ROLE` | _fill in_ | _fill in_ | `GRANT_HOUSEKEEPING_OPERATIONS_ROLE` | `REVOKE_HOUSEKEEPING_OPERATIONS_ROLE` | EigenLayer queue/complete, stETH withdrawal queue, Liquifier housekeeping — currently `ADMIN_EOA`. Spec §8.2 moves this behind `OPERATING_TIMELOCK`. Grant new, revoke `ADMIN_EOA`. |
| `EXECUTOR_OPERATIONS_ROLE` | _fill in_ | _fill in_ | `GRANT_EXECUTOR_OPERATIONS_ROLE` | `REVOKE_EXECUTOR_OPERATIONS_ROLE` | `executeTasks`, EL consolidations, merkle root publishing. Spec keeps this on `ADMIN_EOA` until permissionless execution lands. Confirm. |
| `EIGENPOD_OPERATIONS_ROLE` | _fill in_ | _fill in_ | `GRANT_EIGENPOD_OPERATIONS_ROLE` | `REVOKE_EIGENPOD_OPERATIONS_ROLE` | `startCheckpoint`, `verifyCheckpointProofs`. Currently a pod-prover EOA. Confirm holder vs. new prover. |
| `MEMBERSHIP_MANAGER_OPERATIONS_ROLE` | _fill in_ | _fill in_ | `GRANT_MEMBERSHIP_MGR_OPERATIONS_ROLE` | `REVOKE_MEMBERSHIP_MGR_OPERATIONS_ROLE` | Membership-manager operator EOA. Confirm whether it changes. |

---

## 3. Operational parameters

These are not addresses but they have the same rule: **no defaults**.
Every constant in `transactions.s.sol` is `0` and the script's `_preflight`
asserts each one is non-zero before generating calldata.

### 3.1 Rate-limiter buckets (gwei units; `uint64` cap = `~1.8e19` gwei)

`EtherFiRateLimiter` operates in gwei. `RateLimitMath.toBucketUnit` rounds up
and saturates at `type(uint64).max`.

| Bucket ID | Constant in script | What to think about | My suggestion |
|---|---|---|---|
| `EETH_MINT_LIMIT_ID` | `EETH_MINT_CAPACITY`, `EETH_MINT_REFILL_RATE` | Caps how fast eETH can be minted via deposits and fee-path mints (the infinite-mint surface). Spec §5.2.3. | Capacity ≥ one week of typical deposits with headroom. Refill rate ≈ peak daily deposits / 86400. |
| `EETH_BURN_LIMIT_ID` | `EETH_BURN_CAPACITY`, `EETH_BURN_REFILL_RATE` | Caps burns on instant exits + queued claims. | Symmetric with mint, possibly higher to avoid blocking redemptions. |
| `EETH_TRANSFER_LIMIT_ID` | `EETH_TRANSFER_CAPACITY`, `EETH_TRANSFER_REFILL_RATE` | Caps total ERC20 transfer volume per period. Apply mostly as a tripwire. | 4–10× the mint cap. |
| `WEETH_*` | `WEETH_*_CAPACITY` / `WEETH_*_REFILL_RATE` | **Must be ≤ EETH counterpart.** WeETH wrap mints eETH first; if WeETH cap > EETH cap the limiter never trips on WeETH path. | Set equal to EETH or one notch lower. |

For each: pass values in **gwei**, not wei.
`1 ETH = 1e9 gwei`. Example only — do not paste blindly — for a 50 000 ETH cap
the constant is `50_000 * 1e9 = 50_000_000_000_000 (uint64)`. For a refill
that drains a full bucket over 24 h, divide capacity by 86 400.

### 3.2 PausableUntil durations (seconds, must be in `[8 hours, 30 days]`)

Each constant sets the duration that a single `pauseContractUntil()` call
locks the contract for. Pauser can re-arm only after `duration + 7 day cooldown`.

| Constant | Contract | My suggestion |
|---|---|---|
| `PAUSE_UNTIL_EETH` | EETH | 7 days |
| `PAUSE_UNTIL_WEETH` | WeETH | 7 days |
| `PAUSE_UNTIL_LIQUIDITY_POOL` | LiquidityPool | 7 days |
| `PAUSE_UNTIL_WITHDRAW_REQUEST_NFT` | WithdrawRequestNFT | 7 days (claims are exempt, so this only blocks new requests) |
| `PAUSE_UNTIL_LIQUIFIER` | Liquifier | 7 days |
| `PAUSE_UNTIL_ETHERFI_NODES_MANAGER` | EtherFiNodesManager | 7 days |
| `PAUSE_UNTIL_ETHERFI_ADMIN` | EtherFiAdmin | 7 days |
| `PAUSE_UNTIL_ETHERFI_REDEMPTION_MGR` | EtherFiRedemptionManager | 7 days |
| `PAUSE_UNTIL_MEMBERSHIP_MANAGER` | MembershipManager | 7 days |
| `PAUSE_UNTIL_MEMBERSHIP_NFT` | MembershipNFT | 7 days |
| `PAUSE_UNTIL_AUCTION_MANAGER` | AuctionManager | 7 days |
| `PAUSE_UNTIL_NODE_OPERATOR_MANAGER` | NodeOperatorManager | 7 days |

Seconds: `7 days = 604800`. `30 days = 2_592_000` (absolute max).

---

## 4. Workflow

1. Query mainnet:
   ```bash
   export RR=0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9
   for r in UPGRADE_TIMELOCK_ROLE OPERATION_TIMELOCK_ROLE OPERATION_MULTISIG_ROLE \
            SUPER_GUARDIAN_ROLE GUARDIAN_ROLE \
            ORACLE_OPERATIONS_ROLE HOUSEKEEPING_OPERATIONS_ROLE \
            EXECUTOR_OPERATIONS_ROLE EIGENPOD_OPERATIONS_ROLE \
            MEMBERSHIP_MANAGER_OPERATIONS_ROLE; do
     echo "$r:"
     cast call $RR "roleHolders(bytes32)(address[])" "$(cast keccak $r)" --rpc-url $MAINNET_RPC_URL
   done
   ```
2. Paste the holders into §2.1–§2.3 (current column).
3. Decide target holders. Fill the suggestion column or override with the
   actual ops decision.
4. Fill the `GRANT_*` / `REVOKE_*` constants in `transactions.s.sol`.
5. Fill the operational parameters in §3 (rate-limiter and pause durations).
6. Run the script against a fork — `_preflight()` will revert if anything is
   still zero:
   ```bash
   forge script script/upgrades/security-upgrades/transactions.s.sol:SecurityUpgradesScript \
       --fork-url $MAINNET_RPC_URL -vvvv
   ```
7. Inspect `upgrade_schedule.json`, `upgrade_execute.json`, `ops_schedule.json`,
   `ops_execute.json` and hand them to the corresponding multisig.

---

## 5. Notes & caveats

- **Spec §8.2 (ADMIN_EOA deprecation)** is staged: this PR keeps oracle execution
  (`ORACLE_OPERATIONS_ROLE`, `EXECUTOR_OPERATIONS_ROLE`) on `ADMIN_EOA` because
  the permissionless `executeTasks` flow (Tier 1 #8) is not implemented yet.
  Don't preemptively revoke those without a replacement caller.
- **Tier-role grants in Batch A** require `UPGRADE_TIMELOCK` to itself hold the
  RoleRegistry role-admin position. It does. Don't change that.
- **Blacklister itself is a *contract*, not a role.** The grants/revokes for
  Guardian/Operations are what determine who can call `blacklistUserUntil` and
  `blacklistUser/unblacklistUser`.
- The script supports a single grant + a single revoke **per role per batch**.
  Multiple grants for the same role (e.g. two new guardians) need two passes,
  or extend the `GRANT_*` constants and `_maybeRoleGrant` call sites.
