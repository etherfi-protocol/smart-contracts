# MembershipManager deprecation — learnings and decisions

Companion to `2026-08-21-membership-manager-deprecation-design.md`, which carries the full design.
This is the short version: what we found, what we decided, and what someone picking this up later
needs to know.

## Findings that changed the plan

**New deposits were already impossible — we built nothing for it.** The live implementation has no
`wrapEth`, `mint`, or `topUpDepositWithEth` selector, `MembershipNFT` has no mint function at all
(only `burn`, gated to the manager), and `nextMintTokenId` is frozen at 10001. `_mintMembershipNFT`
lives only in the superseded `MembershipManagerV0.sol`. A `depositsDisabled` flag would have added
storage and a governance surface to prevent what the bytecode already prevents.

**The 765 "non-v1" rows are stale, not live.** They report `version == 0`, `tokenDeposits.amounts
== 0`, and `nft.valueOf == 0` while still carrying a non-zero `vaultShare` in `tokenData` —
leftovers from the V0 era. Skipping them costs nobody anything. The requirement they create is that
the batch must *skip* rather than *revert*, since `_withdrawAndBurn` opens with a `WrongVersion`
check.

**The 1.88 eETH surplus was not dilution.** An earlier draft claimed the stale rows sat in the
denominator of `eEthShareForVaultShare` and diluted every live holder's payout. Wrong. After
force-unwrapping all 1594 positions the obligation fell to 17294 wei, so holders were paid in full.
The stale rows carry `vaultShare` in `tokenData` but contribute nothing to `totalPooledEEthShares`,
which is what the obligation derives from. The 1.8766 eETH was unclaimable surplus all along, and
`unbackedEEth()` identified it correctly *before* the migration started.

**ERC1155 has no owner index.** `MembershipNFT` exposes only `balanceOfUser(address, uint256)`.
There is no `ownerOf` and no enumeration, so the holder set has to be rebuilt off-chain from
`TransferSingle`/`TransferBatch` logs — 20123 events reduce to 1594 held tokens across 1424
addresses. The contract cannot iterate holders itself; it can only verify a holder the caller
supplies.

## Decisions

| Decision | Why |
|---|---|
| Pay out in **eETH**, not a `WithdrawRequestNFT` | The queue route leaves every user a second action and the deprecation unfinished. eETH is the same underlying the NFT already represented, so it is an in-kind swap that completes in one transaction. |
| **`onlyOperatingTimelock`**, not the multisig | This moves other people's assets without consent. It should carry the same delay as any irreversible governance action, and the delay gives holders a window to exit voluntarily first. |
| **Skip, don't revert**, per batch item | One blacklisted holder or one stale row would otherwise block a batch of 200. Each skip is emitted with its revert reason for targeted retry. |
| **No burn fee, no unwrap penalty** | `burnFee` is already 0 on current state, and charging a forced exit is indefensible. The unwrap penalty exists to discourage voluntary early exit, which is not what this is. |
| One **`recoverTokens(token, recipient)`** instead of separate eETH and ETH sweeps | Same entrypoint covers ETH (`address(0)`), eETH, and any stray ERC20. Fewer functions, one role check, one event. |
| `recoverTokens` takes **no amount parameter** | The amount is always `recoverableAmount(token)`. For a stray token that is the full balance; for eETH it is the surplus over `outstandingEEthObligation()`. A caller-named amount would put all 898 eETH of user backing one bad parameter away — which is exactly what a generic `recoverERC20(token, amount, to)` would have done. |
| **Exact-share accounting**, bypassing `_withdraw` | `_withdraw` round-trips share → eth → share and leaves a slice of the token's share stranded in `tierVaults`. That is how the existing voluntary burn path grows dust; the migration adds none. |
| **No new storage variables** | Only constants, errors, events, and functions were added, so the upgrade is layout-compatible. `forge inspect` reports the same 30 slots ending at `__gap_3`. |
| **`forceUnwrapForEEth` on `onlyHousekeepingOperations`, sweeps on `onlyOperatingTimelock`** | The unwrap can only pay the verified holder of the token it burns, so a compromised hot key can force unwanted-but-fair exits and nothing worse. A sweep names an arbitrary recipient, so it keeps the delay. |
| **`whenNotPaused` omitted** | A stuck contract should stay drainable by governance. The tradeoff: a pause triggered by an incident will not halt the migration. |
| Too-large batch **reverts** rather than partially completing | The `gasleft() < 400_000` guard keeps the transaction atomic; the operator retries smaller. `break`-and-keep-progress would save gas but make "how far did it get" answerable only from events. At ~78k gas per token the floor carries ~5x headroom. |

## Resolved: V0 redemption

`outstandingEEthObligation()` sums `tierVaults[].totalPooledEEthShares` and ignores `tierDeposits`,
the V0 structure. **Confirmed decision: no path will re-enable V0 redemption.** V0 tokens are
permanently unredeemable — `_withdraw` and `_withdrawAndBurn` both revert `WrongVersion`, and there
is no plan to change that. The getter is therefore complete, and the sweep bound is sound. This
closes what an earlier draft listed as a standing risk.

## What the 12-agent audit changed

Twelve independent Opus agents (one per lens: access control, math, economics, execution trace,
invariants, periphery, first principles, asymmetry, boundaries, plus numerical / trust / flow gap
hunters) reviewed the new functions. Six issues had enough support to act on. Three were regressions
introduced by an earlier round of my own fixes.

**Removed the `NoneUnwrapped` revert.** Flagged independently by six agents, and they were right on
two counts. A revert-when-nothing-unwrapped guard discarded the very `NftForceUnwrapSkipped` events
that say *why* each item failed — the all-fail case, which is exactly when diagnostics matter, ended
up producing no events at all. Worse, it handed any holder a veto over a queued governance call:
transfer the NFT out before the timelock ETA, the item skips, and a single-item retry batch reverts,
burning a full delay for the price of one ERC1155 transfer. The function now returns
`(unwrapped, skipped)` and emits `ForceUnwrapBatchResult`. Detect the global-failure case by
simulating before queueing.

**A zero-value position is no longer burned for nothing.** `eEthShareForVaultShare` returns 0 for
any input once a tier's `totalPooledEEthShares` hits zero, and the burn was unconditional — so the
NFT was shredded and the row deleted while the holder was paid 0, emitted as a *successful* unwrap.
The voluntary path fails closed here via `_withdraw`'s balance check; the forced path failed open.
Now reverts `WorthlessPosition`, so it surfaces as a skip.

**The V0 guard read the wrong field.** Seven agents converged on this. `_V0_valueOf` returns
`amounts + rewards`, and `shares` is derived from `amounts` and floors to zero for small balances —
so testing `shares` alone would pass a tier still holding V0 principal. Now checks both legs.

**`outstandingEEthObligation()` skips fully drained tiers.** A tier with `totalVaultShares == 0` has
no holder who can draw from it, so counting its pooled dust as owed put a permanent floor under the
obligation and made the residual unsweepable forever. This is why the end-to-end run bottomed out at
17294 wei rather than zero.

**`ForceUnwrapHalted` on the gas-floor break.** The `break` was the one loop exit that emitted
nothing, so a batch stopped at item 5 of 50 was indistinguishable on-chain from a 5-item batch that
ran to completion — contradicting the claim that events mark where to resume.

**`sweepEther` rejects `address(this)`.** Sweeping to self succeeds through `receive()`, leaving the
balance untouched while emitting an `EtherSwept` event claiming it moved. That event is the
migration's only audit trail.

Independently confirmed as safe by multiple agents with their own arithmetic: the sweep bound cannot
cross into backed eETH at any exchange rate, reentrancy is unreachable (ERC1155 `_burn` fires no
acceptance callback, eETH never calls the recipient), the `OnlySelf` gate holds with no
delegatecall or multicall sink, duplicate and wrong-holder entries fail closed, the eETH blacklist
is enforced on sender, recipient *and* `msg.sender`, and the 400k gas floor clears the 63/64 rule
with margin.

Known limitation, not fixed: a holder can keep their position alive indefinitely by transferring the
NFT each timelock cycle. ERC1155 has no owner index, so a forced payout has to name a holder.
Closing it properly means burning unconditionally and crediting a `claimable[tokenId]` mapping the
holder pulls later — a larger redesign than this migration warrants. With the `NoneUnwrapped` revert
gone it costs governance nothing but a retry.

## Resolved: blacklisted holders

Their eETH transfer reverts, so the item is skipped; because the position was never unwrapped its
share still counts toward the obligation, so the sweep cannot take it either. Funds are safe but
frozen until the holder is unblacklisted.

**Decision: leave as is.** No designated destination, no special path. The eETH stays in the
contract against the unburned position, and the holder can be paid by re-running their item once
they are off the blacklist. This is the reason `MembershipManager` cannot be fully retired the
moment the batches finish — a non-zero `outstandingEEthObligation()` is expected, not a defect.

## A misaligned holder/token list cannot mispay

The two arrays are positional, so the obvious worry is that an off-by-one in the off-chain list
pays the wrong person. It cannot. Each pair is verified independently with
`balanceOfUser(_holders[i], _tokenIds[i]) != 1`, so there is no ordering of the two arrays that
pays an address for a token it does not hold — a wrong pair reverts inside its isolated call and is
emitted as a skip.

What a misalignment *can* do is still pay someone: if a holder owns several tokens, a rotated list
may pair them with a different one of their own tokens, and that payment is correct. Rotating a
40-item slice by one on the live fixture gives 24 paid and 16 skipped, because consecutive token ids
often belong to the same buyer. Every one of the 24 was paid for a token it genuinely held.

So the failure mode of a bad list is a partially skipped batch needing a retry, never a
misdirected payout. `test_misalignedArraysSkipAndNeverMispay` pins this. No extra enforcement is
warranted — a length check plus the per-pair ownership check is already the strongest guarantee
available, since the contract has no way to derive the holder itself.

## Contract sizes

`forge build --sizes` against the EIP-170 24576-byte runtime limit: nothing deployable is over.
`MembershipManager` is 18908 bytes with 5668 to spare. The two contracts that exceed the limit,
`ProtocolInvariantsHandler` (29310) and `FrozenRateWithdrawalHandler` (28107), are invariant-test
handlers under `test/` and are never deployed.

Worth watching: `EtherFiNodesManager` sits at 24221 bytes, only **355 bytes** of headroom. Anything
added there needs a size check before it is written, not after.

## Operational notes worth keeping

**Pin the fork block and the holder fixture to the same block.** A fixture built against an older
block silently produces skipped tokens rather than wrong payouts, which is the safe failure mode,
but it wastes a run.

**`forge test` reuses stale artifacts.** A mutation check that edits a contract and re-runs without
`--force` can report a false pass. Identical gas numbers across a supposedly changed run are the
tell. This bit us twice — once on the EigenPod work, once here.

**Anvil needs `--no-rate-limit` for this workload.** Draining 1594 positions plus verification
reads times out a default anvil, which proxies every cold storage slot upstream. Symptom is
`database error: failed to get storage ... operation timed out`, not a test assertion failure. Also
worth avoiding a second full-table read pass in the test: check outcomes from events during the
drain and spot-check a bounded sample afterwards.

**eETH is share-denominated, so exact-wei assertions fail.** Transferring N wei can credit N-1.
Payout and sweep assertions need a 1–2 wei tolerance, and `unbackedEEth()` settles at 1–2 wei
rather than 0 after a sweep. This is also *why* the sweep bound survives rebases: both
`balanceOf(MM)` and the obligation are share-denominated, so a rebase scales them by the same
factor and `mmShares >= owedShares` holds at any rate.

**Test the sweep mid-migration, not just at the end.** Sweeping only after everything is drained
cannot catch a wrong bound. `test_sweepMidMigrationStillPaysRemainingHolders` drains half, sweeps
while half are outstanding, then pays the rest and asserts each gets full value.
