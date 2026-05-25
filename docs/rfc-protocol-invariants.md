# RFC: Invariant-Based Supply Safety for eETH / weETH

**Status:** **Implemented** in PR #426. This document records the design and
the findings surfaced during build — including two additional candidate
invariants that were considered and rejected as redundant with existing
on-chain checks.
**Author:** Seongyun
**Date:** 2026-05-25 (initial draft) · 2026-05-25 (build findings appended)
**Related:** #423 (per-address rate limits), #424 (wrap-aware global supply
circuit breaker), #425 (rate-limiter consistency polish), **#426 (this RFC's
implementation)**

## TL;DR

Add two on-chain **conservation invariants** that revert any transaction
violating "tokens are backed by underlying ETH":

1. **Invariant 1** — weETH supply is fully backed by eETH shares held in the
   weETH proxy.
2. **Invariant 2** — on every **mint** of eETH shares, the eETH exchange rate
   does not decrease.

Per-address rate limits (#423) stay — they're the right tool for the
targeted-throttle threat. The two invariants solve a different problem
(unbacked-supply prevention) and the two layers compose.

Ships **live** (`enabled = true` at deploy). No observe→enforce rollout phase.
An OperatingMultisig-gated `setEnabled(false)` kill switch exists only for
the case where the invariant code itself has a bug blocking legitimate
traffic; normal operation never touches it.

## Motivation

PR #423 introduced per-address rate limits and removed the protocol-wide
MINT/BURN circuit breaker on eETH/weETH. Review of #423 surfaced a gap:
without a global breaker, an unbacked-mint exploit (compromised LP, future
bridge adapter, exploited mint path) has no on-chain bound — only off-chain
detection + manual pause.

#424 re-adds a global breaker with a wrap-aware transient-storage flag to
avoid the wrap/unwrap griefing surface. It works, but the design has tells:

1. **Threshold sizing per token per chain.** Operators must size MINT/BURN
   capacity and refill rate by hand. Get it wrong and either legitimate
   traffic is throttled or attacks slip through.
2. **Path-conditional exception (the wrap flag).** wrap/unwrap is
   value-neutral, so we carve it out. Every future "value-neutral" mint path
   needs the same carve-out and the same maintenance hazard.
3. **Two `capacity == 0` semantics.** Global = disabled; per-address =
   frozen. Documented in #425, but the divergence exists because we're using
   the same `BucketLimiter` primitive for two different jobs.
4. **`UnknownLimit` bricks the path.** Forget to bootstrap a bucket in the
   3CP and every deposit reverts. Operational hazard.

All four are symptoms of one root cause: **a gross-flow rate limit is the
wrong tool for catching unbacked mints.** A rate limit *slows* an exploit;
it does not *prevent* it. The exploit can still happen — it's just slower.

The right tool is a **state invariant**: at the end of every state-changing
call, assert that the protocol's accounting still adds up. If a mint happened
without matching backing, the math breaks and the transaction reverts. No
thresholds, no carve-outs, no bootstrap order.

## What the invariants are

### Invariant 1: weETH is exactly backed by eETH shares held in the proxy

For every state-changing call on `WeETH`:

```
weETH.totalSupply() == eETH.shares(address(weETHProxy))
```

**Why this holds in the current design:**

`wrap(_eETHAmount)` does two things in one call:
- Mints `liquidityPool.sharesForAmount(_eETHAmount)` weETH to the user.
- Transfers `_eETHAmount` of eETH from user to proxy. Since eETH is a
  rebase token, transferring `_eETHAmount` moves `sharesForAmount(_eETHAmount)`
  shares.

**Both increments are the same number.** weETH.totalSupply and eETH.shares(proxy)
move in lockstep. `unwrap` is the symmetric decrement.

**What this catches:**
- Any non-wrap path that mints weETH without an eETH transfer in (bridge
  compromise, exploit, future mint authority that forgot to transfer in eETH)
  → `weETH.totalSupply > eETH.shares(proxy)` → revert.
- Any non-unwrap path that drains eETH from the proxy without burning weETH
  → `weETH.totalSupply > eETH.shares(proxy)` → revert.

**Edge case — accidental eETH airdrops to proxy:**
Someone calls `eETH.transfer(weETHProxy, X)` directly. `eETH.shares(proxy)`
goes up; `weETH.totalSupply` stays. Invariant becomes `weETH.totalSupply <
eETH.shares(proxy)` (proxy over-collateralized). This is *safe* for users
(extra backing) but breaks strict equality.

**Resolution:** use the `<=` form:

```
weETH.totalSupply() <= eETH.shares(address(weETHProxy))
```

Allows over-collateralization, forbids under-collateralization. Loses some
expressivity (we no longer detect "extra eETH appeared in the proxy") but
that's not a threat — we're protecting weETH holders' claims, not auditing
proxy donations.

**Cost:** ~2 SLOADs per state-changing call (one for each side). Negligible
relative to rebase-token transfer cost.

### Invariant 2: eETH exchange-rate monotonicity (mint-side)

> **Note on scope evolution.** The original draft of this RFC proposed
> `eETH.totalShares == LP.totalShares()`. During implementation we confirmed
> LP does **not** maintain an independent share counter — every reference in
> `LiquidityPool.sol` reads `eETH.totalShares()` directly. That comparison is
> tautological. The meaningful eETH-side check we ended up shipping is a
> **mint-side rate-monotonicity invariant**, described here.

On every call that **increases** `eETH.totalShares`, the eETH exchange rate
(`totalPooledEther / totalShares`) must not decrease:

```
P1 * S0 >= P0 * S1     where  P = LP.getTotalPooledEther()
                              S = eETH.totalShares()
                              0 = before, 1 = after
```

**Why mints only?** A healthy deposit pulls ETH in and mints shares in
proportion via the OLD rate (rounded down on the shares side). The rate
stays equal or ticks UP after the mint — never down. Conversely, withdrawal
paths can legitimately drop the rate (the frozen-rate NFT/queue settlement
path uses a rate snapshotted at finalize time; if the live rate has since
drifted up, the burn at fulfillment produces a small rate drop). That's
by-design accounting, not an exploit. **Restricting the invariant to
mints catches the threat we care about without false-positives on
withdrawal-side rate drift.**

This narrowing was surfaced by the test suite — see "Findings during build"
below.

**What this catches:**
- Shares minted without proportional ETH inflow (LP compromise, future mint
  authority that forgot to wire backing in, accounting bug that produces
  shares-without-ETH on a deposit path).

**Where it lives:** as a `nonDecreasingRate` modifier on LP's 3 deposit
overloads (`deposit(referral)`, `depositToRecipient(...)`,
`deposit(user, referral)`). The modifier snapshots P0/S0 before and
P1/S1 after, then forwards both pairs to
`ProtocolInvariants.check_eETHRateMonotonic` which owns the
kill-switch policy. The check function itself short-circuits when
`S1 <= S0` (anything that isn't a mint) and when `S0 == 0` (bootstrap),
so adding the modifier accidentally to a non-mint path is a gas waste
but not a correctness hazard.

**Caveat — LP compromise:** if LP itself is compromised, the attacker
controls the rate function and can keep the invariant satisfied while
doing whatever they want. The protection here is against *non-LP-compromise*
paths that mint eETH (bugs, future bridge integrations, exploited
oracle paths). LP compromise is handled by upgrade governance and pause,
as it is today. The RFC doesn't claim to solve LP compromise.

### Invariant 3 (optional, harder): eETH backing reconciliation

The fullest version:

```
LP.totalPooledEther == sum of (
    ETH held by LP +
    ETH on validators (active + pending) +
    ETH in withdrawal queue +
    ETH in escrow / restaker
)
```

If `LP.totalPooledEther` is computed (e.g., updated by an oracle), this
should equal the sum of physically-located ETH.

**Why this is hard:**
- Validator stakes are not directly readable on-chain.
- The protocol relies on oracle updates to refresh `totalPooledEther`. Between
  refreshes, the invariant is intentionally loose.
- Slashing, accidental fees, lost-key validators create unavoidable drift.

**Disposition:** out of scope for the first iteration. The oracle-based
accounting model already implies "we trust the oracle, not the chain, for
this number." Invariant 1 and 2 sit *above* this trust assumption — they
say "given the numbers LP reports, the token contracts must be consistent
with them." That's the layer we can enforce cheaply.

Mention here only so it's clear what we're NOT proposing.

## What shipped

See `src/ProtocolInvariants.sol`, `src/interfaces/IProtocolInvariants.sol`,
and the integration points in `src/WeETH.sol` and `src/LiquidityPool.sol`.
Summary:

### Contract surface

```solidity
contract ProtocolInvariants is Initializable, UUPSUpgradeable, RolesLibrary {
    IeETH   public immutable eETH;
    address public immutable weETH;
    address public immutable liquidityPool;
    bool    public enabled;              // default true at deploy; multisig kill switch

    function check_weETH_backed() external view;
    function check_eETHRateMonotonic(uint256 P0, uint256 S0, uint256 P1, uint256 S1) external view onlyLP;
    function setEnabled(bool _enabled) external onlyOperatingMultisig;
    function weETHBackingDelta() external view returns (uint256 supply, uint256 proxyShares, bool underbacked);

    error AddressZero();
    error WeETHUnderbacked(uint256 weETHSupply, uint256 proxyShares);
    error EETHRateDeflation(uint256 P0, uint256 S0, uint256 P1, uint256 S1);
    error OnlyLiquidityPool();
}
```

### Integration

- **WeETH.** `_afterTokenTransfer` hook (Pattern B). Fires the check on
  every mint/burn (skips transfers). The hook is impossible to forget on
  new supply paths because the OZ ERC20 base calls it automatically.
  `wrap()` reordered to deposit-then-mint so the hook sees consistent
  state.
- **LiquidityPool.** `nonDecreasingRate` modifier (Pattern A) on the 3
  deposit overloads only. Snapshots `(getTotalPooledEther(), totalShares)`
  before and after, forwards both pairs to ProtocolInvariants. Modifier
  is **not** on burn paths — see Findings F2.

### Why a separate contract (not a library)

A standalone proxy gives the kill switch a stable address and a single
upgrade path, decoupled from the underlying token / LP upgrade cadence.
Library inlining would have been cheaper per-call but coupled every
invariant change to a token-proxy upgrade. The kill switch is the
load-bearing reason — it needs to live behind one storage slot that
multisig can flip in seconds.

## Operational model

The draft of this RFC sketched a 3-phase rollout (Observe → Enforce → Retire
buckets). After review, that was rejected:

- The team's position is that **releases go live with checks active**. There
  is no observe-only stage.
- A bool kill switch (`enabled`, default true at deploy) is sufficient for
  the only scenario where you'd actually want to disable an invariant
  mid-flight — the invariant code itself misfiring during an incident.
- The bool flip is gated to **OperatingMultisig**. Guardian is too low a bar
  for a switch with this blast radius, and a timelock is too slow for an
  active incident.

**Implementation note:** the kill switch lives inside `ProtocolInvariants`,
not in LP / eETH / weETH. A single `setEnabled(false)` call disables both
invariants protocol-wide. The token / LP modifiers still execute (snapshot
state, forward to ProtocolInvariants), but the check function short-circuits.
This keeps the snapshot cost (negligible) constant whether or not the
invariant is active, and centralizes the failure-recovery decision.

### What retires?

The original draft proposed retiring #424's global MINT/BURN buckets once
the invariants are stable. **Status: deferred.** The invariants and the
buckets coexist productively: invariants are precise (catch unbacked mints
of any size, path-agnostic); rate limits are coarse (catch volume-based
anomalies regardless of whether they're unbacked). The cost of running
both is small. The team can revisit retirement once production data
informs the decision.

## Risks and mitigations

### R1 — Invariant function has a bug, bricks the protocol

The blast radius is total: a buggy invariant can lock every wrap/unwrap and
every eETH deposit. The shipped mitigation is the `setEnabled(false)`
kill switch (OperatingMultisig-gated) on `ProtocolInvariants`. Flip it
off, the modifiers continue to execute but the check function short-
circuits, traffic flows. Cost of having the bool: ~1 storage slot. Cost of
NOT having it: multi-day brick during an active incident waiting for
upgrade-timelock recovery.

Defensive properties baked into the check functions:
- Reverts return clear typed errors (`WeETHUnderbacked`,
  `EETHRateDeflation`), no string concatenation, no external calls inside
  the check.
- The contract is UUPS-upgradable via `UPGRADE_TIMELOCK_ROLE` for a more
  considered repair path once the bug is understood.
- Functions are `view` — no storage writes, no callback risk.

### R2 — Rounding / off-by-one false positives

eETH share/balance math has rounding. If we get the invariant form even
slightly wrong (e.g., strict equality where `<=` is right), we get
intermittent reverts under benign protocol activity.

Mitigation: caught during build via the test suite. The broad-sweep test
run flagged 22 withdrawal-side tests asserting legitimate rate drops at the
frozen-rate fulfillment path; that surfaced the **scope narrowing of
Invariant 2 to mint paths only**. See "Findings during build" below.

### R3 — Gas cost on hot paths

Each state-changing call adds 2 SLOADs + a comparison. Bounded ~5k gas.
Wrap/unwrap are ~150k gas operations; this is ~3% overhead. Acceptable.

Optimization: the invariant function is `view`, so it can be `staticcall`-ed
or inlined if the gas matters. Real cost is 2 SLOADs (~4200 gas after
warming) per token call.

### R4 — LP compromise renders Invariant 2 useless

If LP itself is compromised, `LP.totalShares` is attacker-controlled, so
`eETH.totalShares == LP.totalShares` is satisfied trivially by the attacker.

Invariant 2 is a defense against *non-LP paths* touching eETH share state.
It does NOT defend against LP compromise. That threat is handled by
upgrade governance and pause, as it is today.

This isn't a mitigation — it's a scope clarification. The RFC doesn't claim
to solve LP compromise.

### R5 — Future state-changing methods forget the modifier

For weETH: shipped using the OZ `_afterTokenTransfer` hook (Pattern B from
the original draft). Every mint/burn already routes through it, so new
weETH supply paths are covered automatically.

For LP: shipped using the modifier pattern (Pattern A) on the 3 deposit
overloads. The check function short-circuits on `S1 <= S0`, so accidentally
adding the modifier to a burn path is a gas waste but not a correctness
hazard. Future mint paths must remember to add `nonDecreasingRate` — this
is documented in `LiquidityPool.sol`'s modifier docstring.

## What does NOT change

- **Per-address rate limits** stay exactly as built in #423. Different threat
  (targeted throttling, ops tool), different tool.
- **Pause / blacklist / withdrawal queue** stay. They handle different
  failure modes (anomalous-but-still-backed activity, sanctioned addresses,
  forced exit velocity).
- **Hypernative off-chain monitoring** stays. In fact, in Phase 1 it gets a
  new high-signal data source (`InvariantViolated` events).
- **Upgrade governance** stays. Invariants don't replace the timelock /
  multisig story for LP compromise.

## Findings during build

Three things changed materially between the original draft and what
actually shipped. Recorded here for future readers and audit firms.

### F1. Invariant 2's first form was tautological — replaced

The draft's Invariant 2 was `eETH.totalShares == LP.totalShares()`. The build
confirmed that **LP does not maintain an independent share counter** —
every reference in `LiquidityPool.sol` reads `eETH.totalShares()` directly.
So the comparison is the same value on both sides, providing zero defense.

The shipped Invariant 2 is the mint-side rate-monotonicity check described
above — a structurally different check that catches the same threat
(unbacked eETH mint) via a different on-chain property.

### F2. Rate monotonicity had to be narrowed to mint paths

The first build of Invariant 2 covered all share-changing calls
(both mints and burns). Broad-sweep testing flagged 22 withdrawal-side
tests asserting **legitimate** rate drops:

- **Frozen-rate NFT/queue settlement.** A request finalized at rate R0
  gets fulfilled later when the live rate is R1 > R0; the burn at
  fulfillment computes shares against R0, producing a small rate drop
  at the burn point. By design — protects the user from rate drift
  between request and fulfillment.
- **Rounding in `sharesForWithdrawalAmount` (ceil).** Favors the protocol
  on the burn-side but can interact with frozen-rate paths to drop the
  rate by a few wei.

The threat we want to catch — unbacked mint — only manifests when
`totalShares` **increases**. Withdrawal-side rate drift is accounting,
not exploit. So the shipped check no-ops when `S1 <= S0`, and the LP
modifier was removed from burn paths (saves ~5k gas per burn).

### F3. The phased rollout was rejected

Originally proposed: Observe → Enforce → Retire. The team's actual
operational model is to ship with checks live (`enabled = true`) and use
a single bool kill switch as the only operational lever. The 3-phase
state machine, the events-only mode, and the gradual retirement of #424
buckets are all replaced by:

- One bool, OperatingMultisig-gated.
- Default `true` at deploy.
- Coexist with #424 buckets indefinitely (no retirement path scheduled).

## Considered and rejected

During implementation we scouted two additional invariants. Both turned out
to be **redundant with existing on-chain checks** that the protocol already
enforces locally. Recording them so future reviewers don't re-derive the
same dead ends.

### R1. Withdrawal-escrow solvency

**Proposed invariant:**
```
WithdrawRequestNFT:        balance >= ethAmountLockedForWithdrawal
PriorityWithdrawalQueue:   balance >= ethAmountLockedForPriorityWithdrawal
```

**Verdict: redundant.** Both contracts already enforce exactly this check
inline at every counter-mutating point:

- `WithdrawRequestNFT._checkEthAmountLockedForWithdrawal()` called from
  `receive()`, `_claimWithdraw`, `handleRemainder`.
- `PriorityWithdrawalQueue._checkEthAmountLockedForPriorityWithdrawal()`
  called from `receive()`, `fulfillRequests`, `claimWithdraw`.

These are the **only** code paths that move the counter, so the existing
checks cover every mutation. Additionally:

- Neither contract has a `recoverETH` function, so accidental ETH egress
  outside the claim/handleRemainder paths is structurally impossible.
- Counter arithmetic is `uint128 +=/-= uint128(msg.value)` in Solidity
  0.8.27 — checked arithmetic reverts on overflow/underflow rather than
  silently corrupting.
- The `receive()` functions are `onlyLiquidityPool`-gated, so misrouted
  funding is impossible.

Adding a duplicate check to `ProtocolInvariants` would have zero security
value.

### R2. Rebase magnitude bound

**Proposed invariant:**
```
On rebase: |ΔP / P| <= MAX_PCT_PER_REBASE
```

To catch oracle compromise pushing a manipulated rate update.

**Verdict: redundant.** `EtherFiAdmin._validateRebaseApr` (around line 344
of `EtherFiAdmin.sol`) already enforces an APR-bounded variant of exactly
this, with the comment: *"Permanent invariant — protects against runaway
rebase or slashing leakage in a single report."*

Their implementation is actually **better** than the bound I was about to
propose:

- Time-normalized (computes annualized APR from `accruedRewards / TVL /
  elapsedTime` rather than a flat percent-per-rebase), which handles
  reports covering different windows correctly.
- Direction-agnostic — takes the absolute value, so it caps inflation
  AND deflation symmetrically.
- Cap (`acceptableRebaseAprInBps`) is configurable per-deployment rather
  than baked in.

Adding a flat percent-per-call bound to `ProtocolInvariants` would be both
redundant and weaker than what already exists.

## Lessons for future invariant proposals

1. **Grep `_check*` and `validate*` first.** Before proposing a new
   on-chain invariant, search the relevant contracts for existing checks
   with similar shape. The protocol's local invariants are stronger than
   they look from the outside.
2. **`ProtocolInvariants`' niche is cross-contract.** Single-contract
   invariants belong inside the contract whose state they're checking
   (locality, gas, audit clarity). `ProtocolInvariants` adds value
   specifically when the property spans two contracts that don't naturally
   share state — Invariant 1 spans weETH and eETH; Invariant 2 spans LP
   and eETH.
3. **The cross-contract niche may be the complete set.** After scouting,
   Invariant 1 and Invariant 2 may genuinely be the entire space worth
   adding for ether.fi's current architecture. New cross-contract paths
   (bridge adapter, restaker integration, new mint authority) are the
   natural triggers for the next round of invariant work.

## Decisions made

1. **Direction:** invariant-based supply safety is additive to rate limits,
   not a replacement. Both layers coexist indefinitely (no scheduled
   retirement of #424's buckets).
2. **Rollout model:** ship live with checks active. No observe-only stage.
   Single bool kill switch for emergencies, OperatingMultisig-gated.
3. **Scope:** two invariants — weETH backing (`<=`) and eETH mint-side rate
   monotonicity. Additional candidates were scouted and rejected (see above).

## Appendix — quick sanity check of Invariant 1

Replaying mentally:

| Operation | Δ weETH.totalSupply | Δ eETH.shares(proxy) | Invariant holds? |
|---|---|---|---|
| Initial state | 0 | 0 | 0 ≤ 0 ✓ |
| `wrap(100 eETH)` | +`sharesForAmount(100)` | +`sharesForAmount(100)` (eETH transfer) | ✓ |
| Rebase event (totalPooledEther grows) | 0 | 0 (shares don't move on rebase) | ✓ (invariant on shares, not balances) |
| `unwrap(50 weETH)` | -50 | -50 (eETH transfer out) | ✓ |
| Accidental `eETH.transfer(proxy, 5)` | 0 | +`sharesForAmount(5)` | ✓ (under, not over) |
| Hypothetical bridge mint(100 weETH) without eETH in | +100 | 0 | **VIOLATED** → revert |
| Hypothetical eETH skim from proxy | 0 | -`sharesForAmount(X)` | **VIOLATED** → revert |

The invariant precisely catches the two threats it's designed to catch and
ignores the benign cases.

---

## Status: closed

Implemented in PR #426. Both invariants live in production behavior the moment
#426 merges and the new LP / weETH impls are upgraded. The kill switch
(`ProtocolInvariants.setEnabled`) is the only operational lever; it exists for
emergencies and is not part of normal protocol operations.

Future invariant proposals: new cross-contract paths (bridge adapter, restaker
integration, new mint authority) are the natural triggers for a follow-up
round. See "Lessons for future invariant proposals" above before drafting.
