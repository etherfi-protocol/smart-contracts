# Ultrareview Context — PR #385 (26Q2 Security Upgrades)

> Read this **before** reviewing any code. It defines scope, trust model, intended behaviors, and pre-flagged findings. Findings that violate this context are out of scope.

---

## 1. What we want from this review

**Primary goal:** find **logical bugs** in `src/*.sol` that cause incorrect accounting, lost funds, stuck funds, or broken invariants in a single transaction or sequence of transactions, under the trust model defined in §3.

**Secondary goal (notes only — not findings):** style, typos, dead code, gas, defense-in-depth recommendations, audit-style observations. Include as a single "Notes" section at the end, never as bugs.

**Highest-value focus areas:**
1. **Onchain validation gaps on oracle inputs.** Quorum is trusted, but offchain node software has bugs. Find anywhere a malformed or out-of-distribution report would pass current validation and cause incorrect state. Suggest additional sanity checks / onchain validations the contract could add.
2. **Depeg + Curve-pool manipulation defense in `Liquifier`** — the stETH market-value gate must hold under both slow depeg and single-block pool manipulation.
3. **Withdrawal/escrow accounting** in `LiquidityPool` / `WithdrawRequestNFT` / `PriorityWithdrawalQueue` — share-math correctness under rebase, segregated balances, partial-claim, and finalize/invalidate/re-validate sequences.
4. **eETH/weETH transfer hooks** — blacklist + pause + share math composition; any interaction that double-counts shares or skips a hook.

---

## 2. Hard scope rules — DO NOT FLAG

These are **invalid findings**. The reviewer should not raise them, even as notes, unless they produce a concrete exploit chain ending in fund loss / stuck funds.

### 2.1 Out of scope entirely
- Deployment scripts, upgrade tx ordering, role-grant order, proxy initialization sequence.
- "First call after upgrade reverts because X wasn't set" / "default value is 0 so contract is bricked until setter called."
- Foundry config, CI YAML, `.gitignore`, `script/` directory (only modified to make things compile).
- Missing test coverage. Tests are considered authoritative for what they cover; gaps are not findings.
- Gas optimization (loops, redundant SLOADs, custom errors vs strings).
- Storage layout — `test/fork-tests/UpgradeStorageIntegrity.t.sol` and `RoleMigrationStorageIntegrity.t.sol` are the source of truth. If they pass, layout is correct.

### 2.2 Trust-model invalid findings
- Zero-address checks on constructor immutables — not required, immutables are assumed set correctly.
- "Role X can grief / DoS the protocol" — all roles are trusted operators. Role-based DoS is not a finding.
- "Compromised quorum can publish bad report" — quorum is trusted. Only report-shape bugs from buggy *offchain node software* are in scope, and only via the lens of "should the contract validate this more strictly."
- "Admin can set value X to a bad value" — all configurable values are assumed to be set safely. Don't argue about the value, only about the code's behavior given safe values.
- "Weak role re-pauses forever" / similar reversible griefing.

### 2.3 Configurable values assumed safe
The reviewer should assume every configurable value is set to a value that does not cause harm. Do not flag findings of the form "if X is set to 0 / max / too tight / too loose, then bad thing happens." Specifically:
- `stalePriceWindow`, `maxPriceDeviationInBps` (Liquifier)
- `staleOracleReportBlockWindow` (EtherFiAdmin) — set to ~2 weeks
- `maxFinalizedWithdrawalAmountPerDay`, `maxNumValidatorsToApprovePerDay`
- `acceptableRebaseAprInBps`, `protocolFeeBps`
- `minAmountForShare`
- `pauseUntilDuration` (8h–3d range)
- `claimDelay` (CMRD)
- `lowWatermarkInBpsOfTvl`, redemption-rate-limiter capacity/refill
- BucketRateLimiter capacity/refill per consumer

### 2.4 Acknowledged intended behaviors — DO NOT FLAG
Each of these has been confirmed by the team as intentional:

1. `LiquidityPool.receive()` underflow-reverts when `totalValueOutOfLp < msg.value`. No anonymous donations to LP.
2. `addEthAmountLockedForWithdrawal`, `transferLockedEthForPriority`, `returnLockedEth` are **not** `nonReentrant` — by design.
3. `initializeOnUpgradeV2` is **not** `nonReentrant` — by design.
4. `WithdrawRequestNFT.validateRequest` can re-fund a previously invalidated request. The team has verified the oracle-report sum logic prevents double-funding. Treat this as a confirmed invariant.
5. `Blacklister.extendBlacklistUntil` overwrites unconditionally — by design.
6. `EtherFiAdmin.executeTasks` is permissionless — deliberate.
7. EETH and WeETH both maintain `bool paused` AND inherit `PausableUntil` — both flags coexist by design.
8. Only `BLACKLISTER_ROLE` can `unblacklistUser`; weaker `BLACKLIST_UNTIL_ROLE` cannot — by design.
9. `EtherFiRestaker.transferStETH` does **not** consume the rate limiter.
10. Per-report caps in `EtherFiAdmin` (not rolling 24h window) — by design.
11. `tokenInfos[cbEth].isWhitelisted == true` / `tokenInfos[wbEth].isWhitelisted == true` remain set while the code paths are removed — known, intentional.
12. `DEPRECATED_*` storage fields retained for slot stability — intentional.
13. Divide-by-zero in `Liquifier.quoteByMarketValue` will be patched separately with `mulDiv` + zero guards — already on the team's radar, **do not flag again**.
14. `Liquifier` reverts on stale/invalid Chainlink response — intended behavior (DoS-on-deposit is acceptable; safe-state is "no new deposits when price untrustworthy").
15. Reentrancy guard coverage, blacklist coverage per entrypoint, and pause coverage per function are all assumed correct as-implemented. Do not flag missing coverage.

---

## 3. Trust model (single source of truth)

- All `RoleRegistry` role holders are fully trusted operators (multisig, ops bot, etc.). Role-based attack scenarios are out of scope.
- The oracle **quorum** is trusted to act honestly. The only oracle-side attack surface in scope is: **buggy offchain node software produces a malformed report that satisfies current onchain checks but corrupts onchain state.** Recommendations to add tighter onchain validation against such reports are in scope and valuable.
- All external dependencies (EigenLayer, Lido, Curve, Chainlink, OZ libs) behave per their documented contracts. Their internal bugs are not in scope.
- Constructor-set immutables are correct.
- All configurable storage values will be set to safe values by operators.

---

## 4. Findings already raised — DO NOT REPEAT

These were flagged in an internal review and have been addressed, accepted, or are out of scope. Re-raising them is a false positive.

### LiquidityPool / WithdrawRequestNFT / PriorityWithdrawalQueue
- `LiquidityPool.receive()` underflow on non-accounting sender → intended (§2.4.1).
- `addEthAmountLockedForWithdrawal` / `transferLockedEthForPriority` / `returnLockedEth` not `nonReentrant` → intended (§2.4.2).
- `initializeOnUpgradeV2` not `nonReentrant` → intended (§2.4.3).
- `PriorityWithdrawalQueue.receive()` silently no-ops counter update pre-migration → out of scope (upgrade ordering).
- `validateRequest` can re-fund an invalidated request → intended invariant (§2.4.4).
- `_checkEthAmountLockedForPriorityWithdrawal` not `view` → style note only.
- `assert` vs `require` → style note only.
- `ReentrancyGuardNamespaced` not using ERC-7201 slot derivation → style note only.
- Test coverage gaps (zero-pending migration, double-init, paused-LP claim, negative-rebase claim) → out of scope (§2.1).

### EtherFiAdmin / EtherFiOracle / CumulativeMerkleRewardsDistributor
- Un-initialized `maxFinalizedWithdrawalAmountPerDay` / `maxNumValidatorsToApprovePerDay` → out of scope (§2.1).
- `executeTasks` permissionless → intended (§2.4.6).
- Per-report cap vs rolling 24h → intended (§2.4.10).
- Unbounded loop in `_validateWithdrawals` → gas-style only (§2.1).
- `finalizeWithdrawalsWhenStale` callable at block 0 on fresh proxy / bypasses APR cap → out of scope (deployment / value-config).
- `setClaimDelay` no lower bound → trust-model invalid (§2.2).
- Storage canary doesn't cover `EtherFiAdmin` / `CMRD` → out of scope (test coverage / storage layout assumed correct per integrity tests).
- `int128 + int128` overflow in `_validateProtocolFees` → trust-model adjacent; do not raise unless a concrete buggy-software report can trigger it within validation bounds.
- Stale "5% APR" comment → typo note only.
- `RoleMigrationStorageIntegrityTest` early-returns on non-mainnet → CI config, out of scope.

### Liquifier / EtherFiRestaker / BucketRateLimiter
- `quoteByMarketValue` divide-by-zero → already being fixed (§2.4.13).
- `stalePriceWindow` ≈ heartbeat → configurable, will be set safely (§2.3).
- `latestRoundData` ignoring `answeredInRound < roundId` → only flag if you can show a Chainlink-spec-conformant stale round bypasses other checks; otherwise it's defense-in-depth (note only).
- `EtherFiRestaker` constructor reads `liquifier.lido()` → out of scope (deploy order, §2.1).
- `tokenInfos[cbEth/wbEth].isWhitelisted = true` → intended (§2.4.11).
- Zero-address checks on `EtherFiRestaker` constructor → trust-model invalid (§2.2).
- `transferStETH` not rate-limited → intended (§2.4.9).
- `BucketRateLimiter.setRefillRatePerSecond` truncation < 1e12 → trust-model invalid.
- `Liquifier.initialize` carrying obsolete params → style note only.
- "avrage" typo → style note only.

### Blacklister / PausableUntil / EETH / WeETH / others
- Zero-address checks on `AuctionManager` / `NodeOperatorManager` / `MembershipNFT` / `MembershipManager` / `BNFT` / `DepositAdapter` constructors → trust-model invalid (§2.2).
- `Blacklister.extendBlacklistUntil` overwrite → intended (§2.4.5).
- `BLACKLIST_UNTIL_ROLE` cannot unblacklist → intended (§2.4.8).
- `PausableUntil.pauseUntilDuration` defaults to 0 → out of scope (deploy / value-config).
- EETH/WeETH dual pause flags → intended (§2.4.7).
- `MembershipManager` unused custom errors → style note only.
- `forge-std/console.sol` import in `MembershipNFT.sol` → style note only.
- `EtherFiRedemptionManager.getInstantLiquidityAmount` comment vs pre-migration formula → out of scope (migration ordering).

---

## 5. What WE WANT YOU TO FIND

Focus your effort here. These are areas where a fresh, deep read is highest-value:

### 5.1 Onchain validation defense against buggy oracle software
- Read every field consumed from `IOracleReport` / `IEtherFiOracle.OracleReport` in `EtherFiAdmin._validateReport` and helpers. For each field, ask: "if the offchain producer set this to a malformed value (NaN-from-JS, off-by-one, wrong unit, integer-truncated, signed-vs-unsigned flip, stale snapshot), what check catches it?" Recommend additional onchain validations where current checks would let it through.
- Cross-field consistency: are there pairs of fields that must agree (e.g., sums, counts, monotonicity) but aren't cross-checked?
- Boundary handling: empty arrays, single-element arrays, max-uint values, equal `refSlotFrom == refSlotTo`.
- `finalizeWithdrawalsWhenStale` — given anyone can call it once stale (§I2 confirmed), is there any per-call invariant that can be violated by repeated rapid calls?

### 5.2 stETH market-value gate (Liquifier)
- Curve `get_dy` is callable in the same tx as the deposit. Can an attacker move the curve quote between the Chainlink check and the actual stETH→eETH minting, profiting from the discrepancy? Walk through the exact ordering of: `latestRoundData` → `get_dy` → deviation check → minting math.
- During a real depeg, does the deviation gate allow a window where Chainlink lags behind a moving market? The team accepts revert-as-safe-state — verify there is no path that *succeeds* with stale-favorable pricing.
- stETH rebase rounding inside `depositWithERC20`: is the post-transfer `balanceOf` read used safely? Could a positive/negative rebase between `safeTransferFrom` and the read mint the wrong amount of eETH?

### 5.3 Withdrawal/escrow accounting under composition
- `LiquidityPool.withdraw` segregated vs non-segregated branches: trace every legal caller. Is there any caller where the wrong branch fires, paying from the wrong balance?
- `WithdrawRequestNFT.claimWithdraw` under: negative rebase between request and finalize; partial finalize where request crosses the finalized boundary; claim by approved-operator vs owner.
- `PriorityWithdrawalQueue` request → cancel → re-request → finalize sequencing. Off-by-one on queue indices. ETH stuck on cancel-after-finalize.
- `_checkTotalValueInLp` placement: is it called after every state mutation that could violate it? Any path that mutates `totalValueInLp` or `address(this).balance` without the check?
- `minAmountForShare` enforcement: every entrypoint that mints/burns shares — is it enforced? Bypassable via referral / membership / NFT-mediated mint?

### 5.4 eETH/weETH transfer hook composition
- Pause check + blacklist check + share-math: confirm the order is (pause → blacklist → share-math) at every entrypoint and that no internal protocol mint/burn accidentally hits a user-level check it shouldn't.
- WeETH wrap/unwrap interaction with EETH transfer hook — does wrapping a blacklisted user's eETH succeed via the wrap path?
- NFT-mediated position transfer (Membership, Withdraw) — can it move value to a blacklisted recipient?

### 5.5 `EtherFiRestaker` role-split correctness
- Each split role gates the exact set of functions that role should gate. No function ungated that mutates value. No function double-gated in a way that bricks a flow.
- Rate-limiter consumption matches the role-split intent.

### 5.6 EtherFiNodesManager + EtherFiNode small diffs
- Small diff but on the validator path. Review for: validator key registration, exit path, EigenPod ownership transitions. Particularly any change that affects which address can call EigenPod operations.

---

## 6. Output format

Structure the review as:

```
### Risk: 🟢 | 🟡 | 🔴

### Bugs (each must include: file:line, the concrete exploit/incorrect-state path, a numeric example showing the wrong outcome)

### Suggested onchain validations (additional checks against buggy offchain reports — §5.1)

### Notes (style/typo/audit-style/defense-in-depth — single section, terse one-liners)
```

Do not include: a summary of what the PR does (already known), a re-listing of files changed, generic praise.

Every bug must have a worked example with concrete inputs and the resulting incorrect state. A bug without a proof-of-concept path will be treated as a defense-in-depth note.

---

## 7. Quick reference — files most likely to contain bugs

In rough priority order:

1. `src/LiquidityPool.sol` (escrow migration, segregated withdraw, balance invariant)
2. `src/EtherFiAdmin.sol` (report validation — §5.1 focus)
3. `src/Liquifier.sol` (stETH price gate — §5.2 focus)
4. `src/WithdrawRequestNFT.sol` (validate/invalidate/claim sequencing)
5. `src/PriorityWithdrawalQueue.sol`
6. `src/EETH.sol`, `src/WeETH.sol` (hook composition)
7. `src/EtherFiRestaker.sol` (role split, rate-limiter consumption)
8. `src/EtherFiRedemptionManager.sol`
9. `src/EtherFiNode.sol`, `src/EtherFiNodesManager.sol`
10. Everything else — only spot-check unless something specifically catches your eye.
