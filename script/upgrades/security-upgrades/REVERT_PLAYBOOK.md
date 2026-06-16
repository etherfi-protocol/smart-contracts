# 26Q2 Security Upgrade — Revert Playbook

**Status:** DRAFT for review (EARN-1481). Items marked **[CONFIRM]** need an owner sign-off before this is operational.
**Pairs with:** the 3CP (EARN-1480), which packages the revert tx JSONs. The oracle-node changes that complicate a revert come from EARN-1212/1213/1211/1468/1469/1470.
**Script:** `script/upgrades/security-upgrades/revert.s.sol` — fork-verified (see §8).

---

## 0. TL;DR — the one thing to know first

**The revert is NOT an emergency stop.** It re-points implementation pointers and rides the **10-day UPGRADE_TIMELOCK**, so it cannot stop an active incident. For anything time-critical, **PAUSE first** (instant, guardian-held — §4), stabilise, *then* decide whether to revert.

Decision order under pressure: **Pause → Diagnose → (Hotfix patch | Full revert) → Recover.**

---

## 1. What the revert script does — and does NOT do

The revert is deliberately **minimal-blast-radius**: it only swaps implementation pointers back. It is **not** a full state rollback.

### It reverts (24 ops, one UPGRADE_TIMELOCK batch)
- ERC1967 implementation slot on all **22 UUPS proxies + RoleRegistry** (RoleRegistry **last**, so its `onlyUpgradeTimelock` gate keeps authorizing the other reverts).
- The **EtherFiNode beacon** impl, via `StakingManager.upgradeEtherFiNode(oldImpl)` (beacon proxy, not UUPS).

### It does NOT revert (sticky state — stays as the upgrade left it)
| Sticky state | Consequence after an impl-only revert |
|---|---|
| **Legacy role revocations** (31 roles revoked in the upgrade batch) | **The biggest gap — see §6.** Old impls gate on legacy roles that now have **zero holders** → many privileged ops are bricked until re-granted. |
| New 9 RolesLibrary role grants | Still held; harmless to old impls (they don't read them). |
| `LiquidityPool.initializeOnUpgradeV2` / `WithdrawRequestNFT.initializeShareRateFreezeUpgrade` storage | Old impls don't read these slots; re-upgrade later will see init flags set (re-entry checks skip). |
| EtherFiRateLimiter buckets (created in ops batch) | Remain configured; old impls don't consume them. |
| PausableUntil durations | Slot retains value; old impls ignore it. |
| LP min/max withdraw bounds | Remain set. |
| Auction sweep (Batch 0) | Already flushed; nothing to undo. |

**Takeaway:** an impl-only revert returns the *code* to pre-upgrade but leaves *state* diverged. A **functional** revert = impl revert **+** legacy-role restoration (§6) **+** oracle-node rollback (§7).

---

## 2. Trigger conditions

### Revert IS warranted (after pausing) when the root cause is in the **new contract code** and is not safely hot-fixable in place:
- Funds-at-risk bug in a new impl (incorrect accounting, broken access gate, redemption/withdrawal mispricing).
- A core user flow is broken with no config fix (e.g., deposits/withdrawals revert for a code reason, not a missing setpoint).
- New immutable/constructor value baked wrong in a way that endangers funds and can't be re-set by an admin call.

### Revert is NOT the answer (do something else) when:
- **It's an operational setpoint**, not code — fix via the relevant admin call (rate-limit capacity, pause duration, LP bounds, `initializeTokenParameters`, daily withdrawal cap). Reverting 26 contracts to fix one number is wrong.
- **A pause already neutralises the risk** and a targeted patch (single-contract re-upgrade) is feasible — prefer the patch; it's far smaller blast radius than a 26-contract rollback.
- **The issue is in the oracle node / off-chain**, not the contracts — roll back the node, leave contracts up.
- **Post-incident, >10 days of normal operation have accrued** on new state — reverting code onto heavily-diverged state may be riskier than forward-fixing. Escalate, don't auto-revert.

**[CONFIRM]** Owner to ratify this trigger list (Stake + security).

---

## 3. Who / what authority

| Action | Authority | Safe / signer | Delay |
|---|---|---|---|
| Emergency pause | `GUARDIAN_ROLE` / `SUPER_GUARDIAN_ROLE` | Guardian holders (Hypernative key, exec-guardian safe, operating multisig) | Instant |
| **Revert (impl rollback)** | `UPGRADE_TIMELOCK` | `ETHERFI_UPGRADE_ADMIN` (`0xcdd5…`) proposes + executes | **10 days** |
| Legacy-role re-grant (§6) | `RoleRegistry` owner = `UPGRADE_TIMELOCK` | `ETHERFI_UPGRADE_ADMIN` | 10 days (same batch as revert, ideally) |
| Operational setpoint fixes | `OPERATION_TIMELOCK_ROLE` / `OPERATION_MULTISIG_ROLE` | `ETHERFI_OPERATING_ADMIN` (`0x2aCA…`) | 2 days / instant |

---

## 4. Immediate mitigation FIRST (before any revert)

1. **Pause the affected contract(s)** via a guardian `pauseContractUntil(...)` — instant, no timelock. Token-level halt: `EETH`/`WeETH` (SUPER_GUARDIAN). Flow-level: LP, WithdrawRequestNFT, EtherFiRedemptionManager, EtherFiNodesManager, etc. (GUARDIAN).
2. **Notify** on-call + security; open the incident channel.
3. **Snapshot** the bad state (tx hashes, balances, the failing call) for the post-mortem before anything changes.
4. Only then evaluate revert vs patch (§2).

> Pausing buys the 10 days the revert timelock costs. There is no instant on-chain rollback by design.

---

## 5. Step-by-step revert execution

**Ordering vs the upgrade:** the revert is a *standalone* UPGRADE_TIMELOCK batch — it is **not** a mirror of the 4 upgrade batches and does not need them un-wound in order. It simply re-points impls. RoleRegistry is reverted **last within the batch**; the EtherFiNode beacon is reverted **before** the StakingManager proxy and before RoleRegistry (so the new `onlyUpgradeTimelock` gate still authorizes it).

1. **Refresh `PRE_*` in `revert.s.sol`** from the *current* mainnet ERC1967 slots (they must equal the impls live *before* the upgrade). Template in the script header:
   `cast storage <proxy> 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url $MAINNET_RPC_URL`; beacon via `cast call <STAKING_MANAGER> "implementation()(address)"`. `_preflight()` reverts on any unset.
2. **Dry-run on a fork** (§8) — confirms proxies are currently on new impls and revert returns them to `PRE_*`.
3. **Emit the JSONs:** `revert_schedule.json` + `revert_execute.json` (both target `UPGRADE_TIMELOCK`, signed by `ETHERFI_UPGRADE_ADMIN`).
4. **Schedule** `revert_schedule.json` → wait **10 days** → **execute** `revert_execute.json`.
5. **Pair with the legacy-role re-grant** (§6) — ideally in the *same* batch so the system is functional the moment the revert lands.
6. Keep affected contracts **paused** through the 10-day window unless the pause itself is the problem.

---

## 6. Legacy-role restoration (in the revert batch)

The upgrade batch **revoked 31 legacy granular roles** and moved gating to the 9 RolesLibrary roles. The old (pre-upgrade) impls gate on those **legacy** roles (verified: master `EtherFiAdmin` uses `roleRegistry.hasRole(ETHERFI_ORACLE_EXECUTOR_TASK_MANAGER_ROLE / PROTOCOL_PAUSER / PROTOCOL_UNPAUSER, …)`). A code-only revert leaves the old contracts gating on **empty** roles → oracle pushes, validator approvals, withdrawal finalization, and pausing all brick.

**Decision (per EARN-1481): the revert batch re-grants every removed legacy role to its pre-upgrade holder**, in the same UPGRADE_TIMELOCK block, so impl-revert + role-restore land atomically.

- The holder set must be **snapshotted pre-upgrade** (the upgrade revokes them, so they can't be read back post-upgrade) and hardcoded into `revert.s.sol`, exactly like `PRE_*`.
- On-chain snapshot taken (current mainnet): **28 of the 31** legacy roles have holders (3 are already empty). ~40 `grantRole(role, holder)` calls total. Snapshot lives in the revert script as a `(role, holder)[]` table; `RoleRegistry.grantRole` is owner-gated and the owner is the UPGRADE_TIMELOCK executing the batch.
- Note RoleRegistry is reverted **last** in the batch; the re-grants run against whichever impl is live, and Solady `EnumerableRoles` storage is shared across the impl swap, so grants persist.

**[CONFIRM]** Whether the revert should also **revoke the new 9 RolesLibrary roles** (they don't exist pre-upgrade and are inert to old code, but leaving them is untidy). Default: leave them; revoke in a follow-up if desired.

---

## 6.5 Escrow value reconciliation — LP ↔ WRN / PWQ (the hard part)

**This is the part a code-only revert gets wrong, and it moves real ETH.**

### What the upgrade does (forward)
`LiquidityPool.initializeOnUpgradeV2()` performs a one-time **escrow migration**:
- reads `nftLocked` = legacy `ethAmountLockedForWithdrawal` (WRN-bound escrow held *in* the LP) and `queueLocked` = `PWQ.ethAmountLockedForPriorityWithdrawal()`;
- `totalValueInLp -= (nftLocked+queueLocked)`, `totalValueOutOfLp += (nftLocked+queueLocked)`;
- **physically `_sendFund`s** `nftLocked` ETH → WithdrawRequestNFT and `queueLocked` ETH → PriorityWithdrawalQueue;
- zeroes the legacy `ethAmountLockedForWithdrawal` slot; sets `escrowMigrationCompleted = true`.

Post-upgrade the new model keeps withdrawal escrow as **segregated ETH balances in WRN/PWQ** (+ `totalValueOutOfLp`), not in the LP's legacy slot.

**Magnitude today (pre-upgrade mainnet):** `nftLocked ≈ 20,356 ETH`, `queueLocked = 0` (PWQ has no pending priority withdrawals yet). So the live migration moves **~20,356 ETH LP→WRN, 0→PWQ** — though both values will differ at the real upgrade and must be read live.

### Why a code-only revert is wrong
Reverting impls does **not** move the ETH back or restore the legacy slot. After an impl-only revert:
- ~20,356 ETH sits in WRN; the legacy `ethAmountLockedForWithdrawal` reads **0**; `totalValueInLp` is still reduced.
- The old LP would treat the escrowed ETH as **freely available** (locked-amount = 0) → over-withdrawal / under-collateralised pending withdrawals. **Funds-integrity bug.**

### The reverse operation (what must happen)
1. Return the escrowed ETH from WRN (and PWQ) to the LP via a plain transfer — **`LP.receive()` auto-rebalances** `totalValueOutOfLp -= / totalValueInLp +=`, exactly inverting the migration's accounting. ✅ no extra accounting code needed.
2. **Restore the legacy `ethAmountLockedForWithdrawal` slot** to the WRN-bound amount (the old LP reads it). ← needs a storage write.
3. Set `escrowMigrationCompleted = false` (so a later re-upgrade can re-migrate).

### The blocker: no existing function does steps 1–3
- WRN/PWQ only *sweep dust* back to LP inside claim/cancel/fulfill flows — there is **no external "return full escrow to LP"** function.
- The new LP has **no reverse of `initializeOnUpgradeV2`**, and **no setter** for the legacy slot. The old LP has no admin setter either.
- Storage can't be poked on mainnet; it needs a contract function on a **live** impl.

### Options (analysis)
- **Option A — build a reverse-migration into the audited contracts (recommended).**
  Add `LiquidityPool.reverseEscrowMigrationV2()` (onlyUpgradeTimelock) that pulls escrow back from WRN+PWQ (via new `returnEscrowToLiquidityPool()` guarded functions on WRN/PWQ), restores the legacy slot, and clears `escrowMigrationCompleted`. Sequence it **first** in the revert batch, *before* the impl flips, while the new impls + RoleRegistry gate are still live. Atomic, exact, auditable.
  *Cost:* new code in LP + WRN + PWQ → **must be in the audit scope of this upgrade.** This is the main decision.
- **Option B — scope the revert to exclude LP / WRN / PWQ.**
  Keep the value-bearing trio on the new (working) impls; revert only the rest. Avoids the reconciliation entirely. *Cost:* doesn't help if the bug is in LP/WRN/PWQ; mixed old/new impls risk cross-ABI/role drift.
- **Option C — bespoke per-incident reconciliation Safe batch.** Hand-built recovery if A wasn't shipped. *Cost:* highest risk, under incident pressure — avoid as the primary plan.

### Critical timing constraint (independent of option)
The two escrow models track pending withdrawals differently, and the revert rides a **10-day timelock**. If withdrawals keep processing on the new system during that window, WRN/PWQ escrow **diverges** from the migrated amounts and the reverse stops being a clean inverse.
**→ On any incident that may lead to a revert, immediately PAUSE the withdrawal paths (LP / WithdrawRequestNFT / PriorityWithdrawalQueue).** A revert is only clean while the segregated escrow still equals what the migration moved. Reverting *early* (escrow unchanged) is exact; reverting *late* needs Option C.

**[CONFIRM] — primary decision for this ticket:** ship **Option A** (reverse-migration in the audited contracts) now, so a clean revert is possible? If not, the revert must be Option B (partial) or accept Option C (bespoke, risky).

---

## 7. Oracle node handling

The oracle node was updated for the new contracts (EARN-1212 et al.): the **10-field `OracleReport`** ABI and the new role model. A contract revert has direct node implications:

- After an impl revert, `EtherFiOracle` / `EtherFiAdmin` are back on **pre-upgrade ABIs and role expectations**. The updated node would submit **new-format reports the old contracts reject** (ABI mismatch), and would call paths gated by **new/legacy roles** that no longer line up.
- **Action: roll the oracle node back to the pre-upgrade release in lockstep with the contract revert.** Contracts and node must match versions; a half-revert (old contracts + new node, or vice-versa) stalls oracle reporting.
- Because reverting also strips legacy role holders (§6), the node's reporting account must be **re-granted its legacy role** before reports succeed.
- During the 10-day timelock window the contracts are still on the *new* impls, so the *new* node keeps working — **do not roll the node back until just before executing the revert.** Sequence: execute revert → roll node back → confirm a report lands.

**[CONFIRM]** Node owner to document the exact node rollback procedure (release tag, deploy steps, who runs it) and the report-success check.

---

## 8. Verification (done + how to re-run)

`revert.s.sol` is **fork-verified**: starting from a fully-upgraded fork, it returns all **23 proxies + the EtherFiNode beacon** to their pre-upgrade impls and confirms owner/paused integrity (owner() is correctly *restored* on the 16 contracts that deprecated OZ Ownable).

Re-run against any post-upgrade fork:
```bash
# point MAINNET_RPC_URL at a fork that is already on the NEW impls
MAINNET_RPC_URL=<upgraded-fork-rpc> forge script \
  script/upgrades/security-upgrades/revert.s.sol:SecurityUpgradesRevertScript --rpc-url <rpc> -vv
```
Steps: confirm-on-new-impl → snapshot → schedule+warp(10d)+execute → assert impl slots == `PRE_*` → assert owner restored/unchanged + paused unchanged.

> Verified on a Tenderly VNet that had this upgrade applied via the real Safe→timelock replay (Layer-2). On a pristine (un-upgraded) fork the script aborts at Step 0 by design — there is nothing to revert.

**Note:** this verifies the **impl rollback** only. Once §6 (legacy-role restore) is built, extend the verification to assert the legacy roles are re-granted and a representative oracle/withdrawal flow works on the reverted system.

---

## 9. Recovery loop (triage → fix → re-attempt)

1. **Stabilise:** pause + revert (+ role restore + node rollback) → protocol back on audited pre-upgrade code.
2. **Root-cause:** reproduce on a fork from the incident block; write a failing test; confirm the fix.
3. **Patch:** prefer the smallest change — a single-contract re-upgrade over re-shipping all 26 — if the blast radius allows.
4. **Re-test:** full Layer-1 (pristine fork) + Layer-2 (Safe-replay on a fresh Tenderly VNet) green, including the fixed path. Mind the **sticky state** from §1 — re-upgrading onto a once-upgraded-then-reverted system means init flags are already set and buckets/grants persist; the re-upgrade batch must tolerate that (idempotent grants, skip already-initialized, etc.).
5. **Re-ship:** new 3CP, fresh timelock cycle, same execution-day discipline.

---

## 10. Open items before sign-off
- [x] `PRE_*` impl addresses populated in `revert.s.sol` (read from live mainnet ERC1967 slots — knowable today, pre-upgrade). Refresh if any proxy impl changes before the upgrade.
- [x] Revert script fork-verified for the impl rollback (§8).
- [ ] **§6 legacy-role restoration** — build the 28-pair re-grant block into the revert batch (snapshot hardcoded). Decision made; implementation pending.
- [ ] **§6.5 escrow reconciliation** — **primary decision:** ship Option A (reverse-migration in the audited contracts)? Requires new code in LP + WRN + PWQ → audit scope. Then extend the fork verification to assert ETH + legacy slot restored.
- [ ] **§7 oracle node rollback** procedure documented by node owner.
- [ ] **§2 trigger conditions** ratified.
- [ ] Playbook reviewed + signed off + linked on EARN-1481.
