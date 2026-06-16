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
5. The revert batch **already includes the legacy-role re-grant** (§6, built into `revert.s.sol` + fork-verified) so the system is functional the moment the revert lands — no separate role batch needed.
6. Keep affected contracts **paused** (and the oracle node paused, §7) through the 10-day window unless the pause itself is the problem. Run the escrow drain (§6.5) before executing.

---

## 6. Legacy-role restoration (in the revert batch)

The upgrade batch **revoked 31 legacy granular roles** and moved gating to the 9 RolesLibrary roles. The old (pre-upgrade) impls gate on those **legacy** roles (verified: master `EtherFiAdmin` uses `roleRegistry.hasRole(ETHERFI_ORACLE_EXECUTOR_TASK_MANAGER_ROLE / PROTOCOL_PAUSER / PROTOCOL_UNPAUSER, …)`). A code-only revert leaves the old contracts gating on **empty** roles → oracle pushes, validator approvals, withdrawal finalization, and pausing all brick.

**Decision (per EARN-1481): the revert batch re-grants every removed legacy role to its pre-upgrade holder**, in the same UPGRADE_TIMELOCK block, so impl-revert + role-restore land atomically. **✅ Implemented + fork-verified** — `revert.s.sol` now appends 39 `grantRole` calls (the `_legacyRegrants()` snapshot) after the impl reverts, and `verifyLegacyRolesRestored()` (Step 5) asserts all 39 landed.

- The holder set must be **snapshotted pre-upgrade** (the upgrade revokes them, so they can't be read back post-upgrade) and hardcoded into `revert.s.sol`, exactly like `PRE_*`.
- On-chain snapshot taken (current mainnet): **28 of the 31** legacy roles have holders (3 are already empty). ~40 `grantRole(role, holder)` calls total. Snapshot lives in the revert script as a `(role, holder)[]` table; `RoleRegistry.grantRole` is owner-gated and the owner is the UPGRADE_TIMELOCK executing the batch.
- Note RoleRegistry is reverted **last** in the batch; the re-grants run against whichever impl is live, and Solady `EnumerableRoles` storage is shared across the impl swap, so grants persist.

**[CONFIRM]** Whether the revert should also **revoke the new 9 RolesLibrary roles** (they don't exist pre-upgrade and are inert to old code, but leaving them is untidy). Default: leave them; revoke in a follow-up if desired.

---

## 6.5 Escrow value reconciliation — LP ↔ WRN / PWQ

### What the upgrade does (forward)
`LiquidityPool.initializeOnUpgradeV2()` performs a one-time **escrow migration**: it physically `_sendFund`s `nftLocked` ETH → WRN and `queueLocked` ETH → PWQ, moves the accounting (`totalValueInLp -=`, `totalValueOutOfLp +=`), zeroes the legacy `ethAmountLockedForWithdrawal` slot, and sets `escrowMigrationCompleted = true`. Post-upgrade, withdrawal escrow lives as **segregated ETH in WRN/PWQ** (their own `ethAmountLockedForWithdrawal` counters), not in the LP's legacy slot. **Magnitude today:** `nftLocked ≈ 20,356 ETH`, `queueLocked = 0` (read live at upgrade time).

### Chosen approach: DRAIN, then revert (no reverse-migration code needed)
Escrow only ever enters WRN/PWQ **at finalize time** (`EtherFiAdmin` → `LP.addEthAmountLockedForWithdrawal` for WRN; `PWQ` → `LP.transferLockedEthForPriority`). Request creation moves no ETH. So **the segregated escrow == exactly the finalized-but-unclaimed requests.** Claims are permissionless. Therefore:

> **Before executing the revert, claim every finalized request.** That drains WRN (and PWQ) escrow to **0** through the front door. Then the revert needs to move **nothing**: the legacy LP slot is already `0` (migration zeroed it), WRN/PWQ balances are `0`, and there are no pending finalized withdrawals for the old impls to service.

**Why the accounting reconciles (verified against master vs branch):**
- New-model claim: `WRN.ethAmountLockedForWithdrawal -= amountOfEEth`; `LP.withdraw(amount, share)` does `totalValueOutOfLp -= amount` + burns the share; WRN pays the owner from its own balance; **any leftover ETH is swept back to LP** (`_claimWithdraw`, so dust/negative-rebase remainder never strands in WRN).
- Draining all finalized requests therefore returns `totalValueOutOfLp` to its pre-migration level and leaves `totalValueInLp == LP.balance`, `WRN.balance == 0`, legacy `ethAmountLockedForWithdrawal == 0`.
- Post-revert the old LP reads `ethAmountLockedForWithdrawal = 0` with no pending finalized withdrawals → fully consistent; it re-accumulates the legacy slot normally as new requests finalize.

**Pause-compatibility (verified):** the whole claim path is pause-exempt — `WRN.claimWithdraw`, `LP.withdraw(amount,share)`, `eETH.burnShares`'s `rateLimiter.consumeToken` (the token path is **not** `whenNotPaused`, unlike `consume`), and `LP.receive()` are all callable while the protocol is paused. So "pause everything except EETH/WeETH, then drain via claims, then revert" works. (`eETH.burnShares` is `whenNotPaused` on EETH itself — which is why EETH/WeETH stay unpaused.)

### Edges that MUST be handled before relying on this
1. **Blacklisted finalized holders.** `_claimWithdraw` calls `blacklister.nonBlacklisted(ownerOf(tokenId))`, and a blacklisted owner also can't transfer the NFT away. A valid finalized request owned by a blacklisted address **cannot be claimed** → its escrow stays in WRN → balance ≠ 0. **Mitigation:** enumerate finalized-unclaimed requests, check owners against the blacklist; temporarily un-blacklist to drain (then re-blacklist), or explicitly send-back just that residual.
2. **EETH_BURN rate-limit capacity.** Each claim burns eETH → `consumeToken(EETH_BURN_LIMIT_ID, amount)`. A paused rate limiter is fine (token path isn't `whenNotPaused`), but the **bucket capacity/refill** can throttle a ~20k-ETH mass-drain (`LimitExceeded`). Ensure `EETH_BURN` capacity ≥ total finalized-unclaimed escrow, or raise it before draining (or drain across refill windows).
3. **Freeze finalization first.** New finalized requests keep appearing while the oracle runs. Pause `EtherFiAdmin`/oracle (part of the full pause) so the finalized set is frozen, then drain it to completion.
4. **PWQ symmetry + maturity.** `queueLocked = 0` today, but if PWQ has finalized-unclaimed requests at revert time, drain them too. PWQ `claimWithdraw` is permissionless but enforces `creationTime + minDelay` (1h) maturity — very-recently-finalized requests can't be claimed until matured.
5. **Re-upgrade (recovery loop):** `escrowMigrationCompleted` stays `true` after a revert; the old impl re-accumulates the legacy `ethAmountLockedForWithdrawal` slot. A later re-upgrade's `initializeOnUpgradeV2` would revert `AlreadyMigrated` and **skip** migrating that re-accumulated escrow. The re-attempt must reset `escrowMigrationCompleted` (or the re-upgrade impl must handle a non-zero legacy slot with the flag already set). See §9.
6. **Storage-layout** of WRN's new `ethAmountLockedForWithdrawal` slot under the old impl — low risk (it's `0` after the drain), but confirm via `UpgradeStorageIntegrity.t.sol`.

### Net result
With the drain-first sequence, **no reverse-migration contract code is required** — the prior Option A (new `reverseEscrowMigrationV2` + `returnEscrowToLiquidityPool`) is **not needed**, keeping the audit scope unchanged. The revert script stays impl-revert + legacy-role-restore; the escrow is handled operationally by draining before execution.

### Execution-day escrow sequence (slots into §5)
1. **Pause the oracle node** (stop report submission) and pause every contract except EETH/WeETH (incl. EtherFiAdmin so finalization stops). See §7.
2. Enumerate finalized-unclaimed WRN (+ PWQ matured) requests; resolve any blacklisted owners (edge 1); confirm EETH_BURN capacity (edge 2).
3. `batchClaimWithdraw` until `WRN.balance == 0 && WRN.ethAmountLockedForWithdrawal == 0` (and PWQ likewise).
4. Execute the revert batch (impl revert + legacy-role re-grants).
5. **Revert the oracle node to the pre-upgrade version** (§7), confirm its account holds the re-granted legacy role, then unpause the node.
6. Unpause contracts; verify normal flow (incl. a successful oracle report).

---

## 7. Oracle node handling

The oracle node was updated for the new contracts (EARN-1212 et al.): the **10-field `OracleReport`** ABI and the new role model. A contract revert has direct node implications:

- After an impl revert, `EtherFiOracle` / `EtherFiAdmin` are back on **pre-upgrade ABIs and role expectations**. The updated node would submit **new-format reports the old contracts reject** (ABI mismatch), and would call paths gated by **new/legacy roles** that no longer line up.

**Required oracle actions, in order:**
1. **Pause the oracle node** (stop it submitting reports / running the publish loop) as part of the incident pause, BEFORE the revert executes. A running new-version node pushing 10-field reports at old contracts would only produce failed/garbage txns. Pausing it also freezes withdrawal finalization, which is what keeps the escrow-drain set stable (§6.5).
2. **Revert the oracle node to the pre-upgrade version** (the release that matches the pre-upgrade contract ABIs/roles), in lockstep with the contract revert. Contracts and node must be on the same version; a half-revert (old contracts + new node, or vice-versa) stalls oracle reporting.
3. Because reverting also strips legacy role holders (§6), the node's reporting account must have its **legacy role re-granted** (handled by the revert batch's role-restore, §6) before reports succeed.

**Timing:** keep the node **paused** through the 10-day timelock window — during that window the contracts are still on the *new* impls, so do NOT roll the node back to the old version until just before the revert executes (else the old node hits the new contracts). Sequence: pause node (at incident) → execute revert → swap node to pre-upgrade version + confirm its account holds the legacy role → unpause node → confirm a report lands.

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

**Also verified:** the revert script's Step 5 asserts all 39 legacy `(role, holder)` re-grants landed (§6), and `test/fork-tests/RevertEscrowDrain.t.sol` (4 tests, mainnet fork) proves the escrow drain — each claim decrements WRN escrow by `amountOfEEth`, holds the `balance == escrow` invariant, sweeps leftover to LP, and reconciles LP accounting; claims work while paused; a blacklisted holder blocks the drain (§6.5 edge 1).

---

## 9. Recovery loop (triage → fix → re-attempt)

1. **Stabilise:** pause + revert (+ role restore + node rollback) → protocol back on audited pre-upgrade code.
2. **Root-cause:** reproduce on a fork from the incident block; write a failing test; confirm the fix.
3. **Patch:** prefer the smallest change — a single-contract re-upgrade over re-shipping all 26 — if the blast radius allows.
4. **Re-test:** full Layer-1 (pristine fork) + Layer-2 (Safe-replay on a fresh Tenderly VNet) green, including the fixed path. Mind the **sticky state** from §1 — re-upgrading onto a once-upgraded-then-reverted system means init flags are already set and buckets/grants persist; the re-upgrade batch must tolerate that (idempotent grants, skip already-initialized, etc.).
5. **Re-ship:** new 3CP, fresh timelock cycle, same execution-day discipline.

> ⚠️ **MUST-CARRY note for the next upgrade version built after a revert — escrow-migration flag.**
> A revert does NOT reset `LiquidityPool.escrowMigrationCompleted` (it stays `true`), and after the revert the *old* impl re-accumulates the legacy `ethAmountLockedForWithdrawal` slot as new requests finalize. So the **new upgrade version** you ship next must NOT rely on the existing one-shot `initializeOnUpgradeV2` (it would `revert AlreadyMigrated` and silently skip the escrow migration, stranding the re-accumulated legacy escrow). The next version must explicitly handle this — e.g. a fresh migration entrypoint that ignores/resets `escrowMigrationCompleted` and re-reads the legacy slot, or a deliberate flag reset in that upgrade's batch. This is not a problem for the *current* version (the drain-then-revert leaves the slot at 0); it is a design requirement for whatever upgrade follows a revert. **Bake this into the next version's migration design and its review checklist.**

---

## 10. EARN-1481 "Done when" status
- [x] **Revert script verified on a fork** (impl pointers + critical state intact) — §8; `revert.s.sol` fork-verified (impl rollback + 39 legacy re-grants) + `RevertEscrowDrain.t.sol` (4 tests) for the escrow drain.
- [x] **Trigger conditions documented** — §2 (when to revert; when explicitly NOT to). *Needs owner ratification (below).*
- [x] **Step-by-step revert process documented** — §3 (authority/signers/delays) + §5 (ordering vs upgrade batch).
- [x] **Oracle handling documented** — §7 (pause node → revert node to pre-upgrade version → re-grant legacy role → unpause; ABI/role compatibility). *Node owner to fill exact rollback runbook (below).*
- [x] **Recovery loop documented** — §9 (triage → fix → re-attempt), incl. the re-upgrade escrow-flag must-carry note.
- [ ] **Playbook reviewed / signed off & linked on the ticket** — playbook linked on EARN-1481; sign-off pending (human).

### Remaining human / ops items (do not block the documentation; tracked here)
- [ ] **§2 trigger conditions** ratified by Stake + security.
- [ ] **§7 oracle-node rollback runbook** filled in by the node owner (release tag, deploy steps, report-success check).
- [ ] **Drain operationalized** (§6.5): pre-check blacklisted finalized holders, confirm EETH_BURN capacity covers the drain, account for PWQ maturity.
- [ ] **Next-version note** (§9): the upgrade version shipped *after* a revert must handle `escrowMigrationCompleted` (not a current-version blocker).
- [ ] Final review + sign-off.
