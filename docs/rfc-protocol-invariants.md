# RFC: Invariant-Based Supply Safety for eETH / weETH

**Status:** Draft — for discussion
**Author:** Seongyun
**Date:** 2026-05-25
**Related:** #423 (per-address rate limits), #424 (wrap-aware global supply circuit breaker), #425 (rate-limiter consistency polish)

## TL;DR

Replace the bucket-based supply rate limits on eETH/weETH with on-chain
**conservation invariants** that revert any transaction violating "tokens are
backed by underlying ETH." The protocol then has a hard, path-independent
defense against unbacked-mint exploits, the wrap-flag transient-storage carve-out
in #424 becomes unnecessary, and the threshold-sizing problem disappears.

Per-address rate limits stay — they're the right tool for the targeted-throttle
threat. The invariant layer protects against unbacked supply. The two tools
solve different problems and shouldn't be conflated.

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

### Invariant 2: eETH share supply matches LP-tracked claims

For every state-changing call on `EETH`:

```
eETH.totalShares == LP.totalShares()   // (or whatever LP-side variable
                                       //  represents the share supply LP
                                       //  thinks should exist)
```

**Background:** LP is the *only* contract authorized to mint/burn eETH
shares (`mintShares` / `burnShares` are gated `onlyPoolContract`). LP holds
its own ledger of how many shares should exist. If LP and eETH agree, all
is well. If they disagree, one of them is buggy / compromised.

**This is currently true by construction.** The question is whether it
should be *enforced* by reverting on violation rather than just assumed.

**What this catches:**
- A bug or exploit that mints eETH shares directly without going through LP
  (e.g., a future feature that forgets to update LP-side accounting; an
  exploit that finds a delegatecall-y path).
- A drift between LP and eETH state due to a partial-failure path that
  updates one but not the other.

**Caveat:** this invariant is only meaningful if LP itself isn't compromised.
If LP is compromised, the attacker controls LP.totalShares too and can keep
the invariant satisfied while doing whatever they want. The protection here
is against *paths outside LP* that touch eETH share state.

**On the LP-compromise threat:** invariants don't help. The right defense is
upgrade controls (timelock, multisig) + audits + pause + Hypernative. None
of those go away with this RFC.

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

## Implementation sketch

### A new contract: `ProtocolInvariants`

```solidity
contract ProtocolInvariants {
    IeETH   public immutable eETH;
    IWeETH  public immutable weETH;
    ILiquidityPool public immutable liquidityPool;

    error WeETHUnderbacked(uint256 weETHSupply, uint256 proxyShares);
    error EETHSharesDrift(uint256 eETHTotal, uint256 lpTotal);

    /// @notice Asserts weETH is at-least-fully-backed by eETH shares
    ///         held in the weETH proxy. Cheap (~2 SLOADs).
    function assertWeETHBacked() external view {
        uint256 supply = weETH.totalSupply();
        uint256 proxyShares = eETH.shares(address(weETH));
        if (supply > proxyShares) revert WeETHUnderbacked(supply, proxyShares);
    }

    /// @notice Asserts eETH share supply matches LP's view.
    function assertEETHSharesConsistent() external view {
        uint256 eETHTotal = eETH.totalShares();
        uint256 lpTotal   = liquidityPool.totalShares(); // adjust if name differs
        if (eETHTotal != lpTotal) revert EETHSharesDrift(eETHTotal, lpTotal);
    }
}
```

### Integration points

Two natural patterns; pick one based on what the team finds clearer.

**Pattern A — modifier on token methods.** Each state-changing token method
calls `invariants.assertWeETHBacked()` (or `assertEETHSharesConsistent()`)
at the end. Pro: locality — invariant lives at the call site. Con: every
new state-changing method needs the modifier.

```solidity
modifier checkBacking() {
    _;
    invariants.assertWeETHBacked();
}

function wrap(uint256 amt) checkBacking external returns (uint256) { ... }
function unwrap(uint256 amt) checkBacking external returns (uint256) { ... }
```

**Pattern B — invariant runs in `_afterTokenTransfer` (OZ ERC20 hook).**
For weETH this is automatic — every supply change goes through the hook.
For eETH, hook into `_transferShares` / `mintShares` / `burnShares`.
Pro: impossible to forget. Con: slightly more gas per call (the SLOADs
happen even on no-op-like paths).

Recommend **Pattern B for weETH** (one hook covers everything), **Pattern A
for eETH** (only three call sites, modifier is clearer than threading
through `_transferShares`).

### What gets retired when this lands

- `WEETH_MINT_LIMIT_ID` / `WEETH_BURN_LIMIT_ID` (added in #424) — invariant
  catches the threat path-independently.
- The wrap-aware transient-storage flag in `WeETH` — no need to carve out
  wrap/unwrap, the invariant is path-agnostic.
- `EETH_MINT_LIMIT_ID` / `EETH_BURN_LIMIT_ID` — invariant 2 catches the
  threat. Only retire AFTER invariant 2 is enforce-mode (see rollout).

Per-address rate limits stay. They solve a different problem (targeted
throttling, not unbacked-mint prevention).

## Phased rollout

Conservative path that lets us validate the invariant formulas against real
mainnet activity before they can revert anything.

### Phase 0 — Spec & numerical review (1 week)

- Get a numerical-analysis eye on the exact-equality forms. eETH is a
  rebase token; share/balance conversions have rounding. Confirm
  `weETH.totalSupply() <= eETH.shares(proxy)` is exact, not approximately
  exact, under all paths (wrap, unwrap, transfers, rebase).
- Confirm `eETH.totalShares == LP.totalShares` is exact at all observable
  call boundaries (not mid-call).
- Pen-test against historical mainnet txs: replay last 6 months of weETH
  state-changing calls in a fork, assert invariants hold at every block.

**Exit criterion:** invariants verified to hold across 6 months of mainnet
history with zero false positives.

### Phase 1 — Observe mode (4 weeks on mainnet)

- Deploy `ProtocolInvariants` contract.
- Wire it into eETH and weETH **emitting events on violation, NOT reverting**:

  ```solidity
  function assertWeETHBacked() external {
      uint256 supply = weETH.totalSupply();
      uint256 proxyShares = eETH.shares(address(weETH));
      if (supply > proxyShares) emit InvariantViolated("weETHUnderbacked", supply, proxyShares);
  }
  ```

- Hypernative subscribes to `InvariantViolated` events; auto-pause if fired.
- Operations team monitors. Any violation event is an immediate triage.

**Exit criterion:** 4 weeks of mainnet activity with zero `InvariantViolated`
events.

### Phase 2 — Enforce mode (revert on violation)

- Upgrade eETH/weETH (or the invariant contract itself if hooked external)
  to revert on violation rather than emit.
- Keep the global MINT/BURN buckets (#424) live in parallel for one cycle
  as belt-and-suspenders.

**Exit criterion:** 4 weeks in enforce mode with no incidents.

### Phase 3 — Retire global rate-limit buckets

- Remove `EETH_{MINT,BURN}_LIMIT_ID`, `WEETH_{MINT,BURN}_LIMIT_ID` consumption
  from token paths.
- Remove the wrap-aware transient flag from `WeETH`.
- Keep per-address buckets.
- 3CP simplifies: no bootstrap-order requirement for global buckets.

## Risks and mitigations

### R1 — Invariant function has a bug, bricks the protocol

The blast radius is total: a buggy invariant can lock every wrap/unwrap and
every eETH transfer. The Phase-1 observe mode is specifically designed to
catch this before it can revert. Even in Phase 2, the invariant contract
itself must be:
- Pause-able by Operating Multisig (`disableInvariant()` switch).
- Upgradable by Upgrade Timelock (separate from the token upgrade path).
- Constructed with `assert` semantics, NOT `require` — i.e., reverts return
  a clear typed error, no string concatenation, no external calls in the
  invariant function.

The `disableInvariant()` switch is non-negotiable. The cost of being able
to flip it off in an emergency is approximately zero (one bool); the cost
of NOT being able to is potentially a multi-day brick.

### R2 — Rounding / off-by-one false positives

eETH share/balance math has rounding. If we get the invariant form even
slightly wrong (e.g., strict equality where `<=` is right), we get
intermittent reverts under benign rebase.

Mitigation: Phase 0 pen-test is exactly this. Replay 6 months of mainnet,
assert the invariant holds at every block under the exact form we're
proposing to ship. If it doesn't, we have the wrong form — iterate.

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

### R5 — Future state-changing methods forget the modifier (Pattern A)

If we go with Pattern A and someone adds a new state-changing method
without the modifier, the invariant doesn't run on that path.

Mitigation: prefer Pattern B (hook into `_afterTokenTransfer` / `_transferShares`)
wherever possible — the OZ template enforces hook coverage on supply changes
automatically. Pattern A only for paths that don't naturally hit a hook.

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

## Open questions

1. **Pattern A vs B for eETH.** EETH doesn't use the OZ ERC20 base —
   `_transferShares` is custom. The hook insertion point isn't free. Maybe
   Pattern A (modifier on `mintShares`, `burnShares`, `_transfer`) is the
   pragmatic call. Worth a 30-min code review with @yash / @pankaj to
   pick.

2. **Where does `ProtocolInvariants` live?** Standalone contract behind a
   proxy (upgradable, pause-able, but adds a contract to the upgrade
   surface)? Library called from eETH/weETH (cheaper, but coupled)?
   Recommend standalone contract — keeps the pause switch (R1) clean.

3. **Should invariant violations also auto-pause the token?** Vs just
   reverting the offending tx. Auto-pause is more conservative ("stop
   everything if anything weird happens") but more disruptive. Lean
   towards revert-only first, escalate to pause if we see real production
   violations.

4. **Does this extend to cross-chain weETH?** L2 weETH supply ↔ L1 OFT
   escrow balance is conceptually a similar invariant. Out of scope for
   v1 but worth flagging — Phase 4 could extend the same pattern to
   the OFT adapter.

5. **Do we want a `TotalAssetsRouter`-style aggregator** (sum across
   contracts) for Invariant 3? Hard problem; not proposing it now; flagging
   for someone-someday.

## Decision needed

Before this RFC moves further:

1. **Is the team aligned that invariant-based is the right long-term
   direction**, with rate limits demoted to a per-address tool only?
2. **Who owns the Phase 0 numerical review?** Needs someone with both
   eETH rebase-math fluency and an audit mindset.
3. **Timeline.** I'd suggest starting Phase 0 the week after #423 + #424
   + #425 land, so we have a stable baseline to replay against. Phase 1
   observe-mode could go live ~3 weeks after that.

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

## Sign-off

This RFC is not a PR. It's a direction proposal. If the team agrees with
the direction, the next step is Phase 0 — a focused 1-week scoped piece
of work to validate the invariant formulas against mainnet history. I can
own that if useful, or hand off to whoever has the eETH-math expertise.

Comments / pushback welcome inline on the issue, on the doc PR, or in DM.
