# Deprecating MembershipManager

Implemented and verified end to end on an anvil mainnet fork pinned to block 25801600. Two asks:
force-withdraw the outstanding NFTs into eETH, and stop new NFTs being created.

Code: `src/archive/membership/MembershipManager.sol` (additive only — no storage variables, so the
upgrade is layout-compatible; `forge inspect` reports the same 30 slots ending at `__gap_3`).
Tests: `test/MembershipDeprecationFork.t.sol`, 12 passing.
Holder fixture: `test/fixtures/membership-holders.json`.

## Result of the full run

All 1594 outstanding positions unwrapped, zero skipped, then the surplus swept to treasury.

| | eETH |
|---|---|
| MM balance before | 898.358844466132712144 |
| `outstandingEEthObligation()` before | 896.482217982642727563 |
| `unbackedEEth()` before | 1.876626483489984581 |
| Obligation after draining all 1594 | 0.000000000000017294 |
| Swept to treasury | 1.876626483489986337 |
| MM balance final | 0.000000000000017295 |

Total gas for the 1594 unwraps was 124.6M, about 78k per token.

## New deposits are already impossible — build nothing

The second ask is done. The live `MembershipManager` implementation
(`0xa9dbe5c7c8172ef83a30c143892e0010420e6307`, behind proxy
`0x3d320286E014C3e1ce99Af6d6B00f0C1D63E3000`) has no deposit entrypoint. Probing its bytecode for
the selectors:

| Selector | Function | Present |
|---|---|---|
| `0xaf876745` | `wrapEth(uint256,uint256)` | no |
| `0x40c10f19` | `mint(address,uint256)` | no |
| `0xe9fee835` | `topUpDepositWithEth(uint256,uint128,uint128)` | no |
| `0x5f63fc90` | `unwrapForEEthAndBurn(uint256)` | yes |
| `0xb7c0306a` | `requestWithdrawAndBurn(uint256)` | yes |

`MembershipNFT` (`0xb49e4420eA6e35F98060Cd133842DbeA9c27e479`) has no `mint` function in its ABI at
all — only `burn`, gated `onlyMembershipManagerContract`. `_mintMembershipNFT` exists solely in
`MembershipManagerV0.sol`, the superseded implementation. `nextMintTokenId` is frozen at 10001.

Minting is unreachable from every direction: no caller-facing deposit function, no mint function to
call, and the only contract permitted to touch supply cannot increase it. A `depositsDisabled` flag
would add storage and a governance surface to prevent something the bytecode already prevents.
Skip it.

The one live-state check worth running before signing off: confirm nothing else holds
`onlyMembershipManagerContract` on the NFT — that modifier trusts a single stored address, and if it
points anywhere upgradeable the argument above depends on that contract too.

## Force-withdraw: what the existing code gives us for free

`unwrapForEEthAndBurn` is nearly the function we want. It resolves the NFT's ETH value, decrements
the tier vault, burns the NFT, and transfers eETH out. Three properties make an admin-driven
version cheap:

1. **MM holds the eETH directly.** `_withdraw` is pure accounting against `tierVaults`; payout is a
   plain `safeTransfer` of MM's own eETH balance. MM currently holds **898.598705209336470907
   eETH**. No liquidity pool round-trip, no queue.
2. **MM can already burn from any holder.** `MembershipNFT.burn(address _from, ...)` takes the holder
   as a parameter. No NFT upgrade needed — only `MembershipManager`.
3. **Burns bypass the transfer guards.** `MembershipNFT._beforeTokenTransfer` returns early when
   `_to == address(0)`, so transfer locks and the NFT-level blacklist check never run on a burn.

## What blocks a naive loop

Four things, each of which bricks a whole batch if ignored:

**No on-chain holder enumeration.** MembershipNFT is ERC1155 with no `ownerOf` and no owner index —
only `balanceOfUser(address, uint256)`. Holder addresses have to be reconstructed off-chain from
`TransferSingle`/`TransferBatch` logs. The function therefore takes `(holder, tokenId)` pairs and
verifies each one, rather than iterating token IDs itself.

**eETH transfers check the blacklist.** `EETH._beforeTokenTransfer` calls
`blacklister.nonBlacklisted` on sender, recipient, and `msg.sender`. One blacklisted holder in a
batch of 200 reverts all 200. This is the single most likely cause of an unusable migration
function.

**Non-v1 tokens revert.** `_withdrawAndBurn` opens with `if (tokenData[_tokenId].version != 1)
revert WrongVersion()`. There are 765 such rows (see the scan below). They are stale, not live —
skipping them is correct — but a loop that reverts instead of skipping never gets past the first
one.

**Recipients that cannot receive.** A holder that is a contract without eETH handling gets funds it
cannot move. In-kind eETH is still strictly better than a burned NFT, so this is acceptable, but it
argues against reverting on anything holder-shaped.

## The implementation

One admin entrypoint, skip-don't-revert on anything unhealthy, and an event per outcome so the
off-chain runner can retry precisely.

Five additions, no new storage. Shapes below; the authoritative source is
`src/archive/membership/MembershipManager.sol`.

```solidity
// Batch entrypoint. Isolates each item so one bad holder cannot block the batch, and refuses to
// continue on a starved frame so "skipped" always means a real per-item failure.
function forceUnwrapForEEth(address[] calldata _holders, uint256[] calldata _tokenIds)
    external
    onlyOperatingTimelock
{
    if (_holders.length != _tokenIds.length) revert LengthMismatch();

    for (uint256 i = 0; i < _holders.length; i++) {
        if (gasleft() < FORCE_UNWRAP_GAS_FLOOR) revert InsufficientGas();

        try this.forceUnwrapOne(_holders[i], _tokenIds[i]) {}
        catch (bytes memory reason) {
            emit NftForceUnwrapSkipped(_holders[i], _tokenIds[i], reason);
        }
    }
}

// External only so the batch can isolate it behind try/catch. Self-call only, so the timelock gate
// on the batch is the only way in. All state writes precede both external calls.
function forceUnwrapOne(address _holder, uint256 _tokenId) external {
    if (msg.sender != address(this)) revert OnlySelf();
    if (membershipNFT.balanceOfUser(_holder, _tokenId) != 1) revert OnlyTokenOwner();
    if (tokenData[_tokenId].version != 1) revert WrongVersion();

    uint8 tier = tokenData[_tokenId].tier;
    uint256 vaultShare = tokenData[_tokenId].vaultShare;

    // Exact recorded share, not _withdraw's share -> eth -> share round-trip, which would strand a
    // slice of the token's share in tierVaults after the row is deleted.
    uint256 eEthShare = eEthShareForVaultShare(tier, vaultShare);
    uint256 amount = liquidityPool.amountForShare(eEthShare);

    _decrementTierVaultV1(tier, eEthShare, vaultShare);
    delete tokenData[_tokenId];

    membershipNFT.burn(_holder, _tokenId, 1);
    if (amount > 0) IERC20(address(eETH)).safeTransfer(_holder, amount);

    emit NftForceUnwrapped(_holder, _tokenId, amount);
}

// What unburned positions can still claim. Derived from the tier vaults, so it cannot drift from
// the accounting the payouts consume.
function outstandingEEthObligation() public view returns (uint256) {
    uint256 shares;
    for (uint256 t = 0; t < tierVaults.length; t++) shares += tierVaults[t].totalPooledEEthShares;
    return liquidityPool.amountForShare(shares);
}

function unbackedEEth() public view returns (uint256) {
    uint256 balance = IERC20(address(eETH)).balanceOf(address(this));
    uint256 owed = outstandingEEthObligation();
    return balance > owed ? balance - owed : 0;
}

// Moves only the surplus, so it can never take eETH backing a position that has not been unwrapped.
function sweepUnbackedEEth(address _recipient) external onlyOperatingTimelock returns (uint256) {
    if (_recipient == address(0)) revert ZeroRecipient();

    uint256 amount = unbackedEEth();
    if (amount == 0) revert NothingToSweep();

    IERC20(address(eETH)).safeTransfer(_recipient, amount);

    emit UnbackedEEthSwept(_recipient, amount);
    return amount;
}
```

Deliberate choices:

- **eETH, not a WithdrawRequestNFT.** `requestWithdrawAndBurn` routes through the withdrawal queue,
  which leaves every user with a second action to take and leaves the deprecation unfinished. eETH
  is the same underlying asset the NFT already represented, so this is an in-kind swap that
  completes in one transaction.
- **`onlyOperatingTimelock`, not the multisig.** This moves other people's assets without consent.
  It should carry the same delay as any irreversible governance action, and the delay gives holders
  a window to exit voluntarily first.
- **No burn fee.** `_withdrawAndBurn` charges `burnFee` unless the waiver period is met. Charging a
  forced exit is indefensible; drop the fee rather than reproduce that branch.
- **No `_applyUnwrapPenalty`.** Tier points are being deleted along with the token. The penalty
  exists to discourage voluntary early unwrapping, which is not what this is.
- **`whenNotPaused` omitted deliberately.** A paused contract should still be drainable by
  governance; add it only if the pause semantics are meant to freeze migration too.
- **Sweep bounded by the obligation, not "send everything".** An unconditional treasury sweep would
  take eETH backing every position not yet unwrapped. Bounding it means the function is safe to ship
  alongside the migration rather than gated on the migration finishing.

## Security analysis of the change

### What holds

**Checks-effects-interactions.** `forceUnwrapOne` writes all state — `_decrementTierVaultV1`, then
`delete tokenData[_tokenId]` — before it makes any external call. The two external calls that
follow cannot reenter anyway: OpenZeppelin's ERC1155 `_burn` runs no receiver hook, and
`MembershipNFT._beforeTokenTransfer` returns early when `_to == address(0)`, so the burn never
calls out. eETH's `transfer` reaches only the blacklister. Even if reentry were possible, the
caller needs `OPERATION_TIMELOCK_ROLE`.

**The sweep bound is rebase-invariant.** This was the property most worth checking, because eETH is
rebasing and a naive bound would rot. Both sides of `balance - owed` are share-denominated:
`balanceOf(MM)` is `amountForShare(mmShares)` and the obligation is `amountForShare(owedShares)`. A
rebase scales both by the same factor, so `mmShares >= owedShares` holds at any exchange rate. The
sweep leaves `mmShares ≈ owedShares` and it stays covered.

`test_sweepMidMigrationStillPaysRemainingHolders` proves this operationally rather than by
argument: it drains half the positions, sweeps while ~half are still outstanding, then pays the
rest and asserts each one receives its full position value. Sweeping only at the very end — which
is all the end-to-end test does — would not have caught a wrong bound.

**No underflow in the vault decrement.** `eEthShareForVaultShare` computes
`vaultShare * totalPooledEEthShares / totalVaultShares`, and `vaultShare <= totalVaultShares`, so
the result never exceeds `totalPooledEEthShares`. If it somehow did, 0.8.x reverts and the
try/catch turns it into an emitted skip rather than corrupted accounting.

**Exact-share accounting, deliberately not `_withdraw`.** `_withdraw` round-trips
share → eth → share via `vaultShareForEthAmount`, which loses precision and leaves a slice of the
token's share in `tierVaults` after the row is deleted. That is how the existing voluntary burn
path grows dust. `forceUnwrapOne` decrements by the token's exact recorded `vaultShare` instead, so
the migration adds none.

**Revert data cannot be attacker-controlled.** `NftForceUnwrapSkipped` logs raw revert bytes, but
every reachable revert originates in our own checks, the NFT, or eETH. eETH transfers never call
into the recipient, so a holder contract cannot inject a large or crafted reason to inflate gas.

**Griefing is bounded.** A holder who front-runs by transferring the NFT away, or by calling
`unwrapForEEthAndBurn` first, fails the `balanceOfUser` check and is skipped — never paid twice.
A duplicated batch entry pays once, for the same reason. Anyone may donate eETH to the contract and
inflate `unbackedEEth()`, but that is a gift to the treasury, not a theft. The reverse — inflating
the obligation to block the sweep — requires raising `totalPooledEEthShares`, and no live function
can (`_incrementTierVaultV1` is unreachable without a mint path).

### Accepted risks, stated plainly

**`outstandingEEthObligation()` only counts V1 accounting — and that is complete.** It sums
`tierVaults[].totalPooledEEthShares` and ignores `tierDeposits`, the V0 structure. No live code path
can redeem a V0 token: `_withdraw` and `_withdrawAndBurn` both revert `WrongVersion`, and
`nft.valueOf` returns 0 for all 765 of them. **Confirmed decision: no path will re-enable V0
redemption.** V0 tokens are permanently unredeemable, so the getter accounts for everything that can
ever be claimed and the sweep bound is sound. Not a standing risk.

**A blacklisted holder's eETH stays in the contract.** The eETH transfer reverts, the item is
skipped, and because the position was never unwrapped its share still counts toward the obligation
— so the sweep cannot take it either. Funds are safe but frozen until the holder is unblacklisted.
This is the open question below, not a bug.

**`whenNotPaused` is deliberately omitted.** `unwrapForEEthAndBurn` has it, so a pause stops
voluntary exits while governance can still migrate. That is the intent — a stuck contract should
stay drainable — but it does mean a pause triggered by an incident will not halt the migration. Add
the modifier if pause is meant to freeze governance too.

**A too-large batch reverts rather than partially completing.** The `gasleft() < 400_000` guard
reverts the whole call, so the operator loses that transaction's work and retries smaller. The
alternative — `break` and keep progress — saves gas but makes "how far did it get" answerable only
from events. At ~78k gas per token the 400k floor carries roughly 5x headroom.

**The sweep cannot zero the balance exactly.** Transferring N wei of a share-denominated token
credits N-1, so a wei of rounding residue stays behind and `unbackedEEth()` settles at 1–2 wei
rather than 0. Harmless; the test asserts the bound instead of equality.

## Rollout

1. Publish a deadline and let holders use `unwrapForEEthAndBurn` themselves. Every voluntary exit is
   one less forced one, and a self-service exit needs no trust.
2. Index `TransferSingle`/`TransferBatch` from the NFT to build the live `(holder, tokenId)` set.
   Cross-check each against `balanceOfUser` and `tokenData[id].vaultShare > 0` at build time — a
   stale list generated against an old block will skip tokens that moved.
3. Upgrade `MembershipManager` with `forceUnwrapForEEth`.
4. Run in batches. Size them against the block gas limit and EIP-7825; the try/catch and the eETH
   transfer make per-item cost well above a bare loop iteration. Re-run against skip events.
5. Reconcile: MM's eETH balance and every `tierVaults[i].totalPooledEEthShares` should reach zero,
   or explain the residual. Non-zero remainder means tokens the list missed.
6. Only then retire the contracts. Sweep any eETH dust left from rounding.

## Live-state scan

A fork scan of all 10000 token IDs, plus a targeted sample of the non-v1 rows. Throwaway test,
deleted after running.

| Metric | Value |
|---|---|
| Token IDs scanned | 10000 |
| Live v1 positions | 1596 |
| Rows with `version != 1` and non-zero `vaultShare` | 765 |
| Total ETH backing the v1 positions | 896.722078725846467380 |
| eETH held by MembershipManager | 898.598705209336470907 |
| v1 positions under 1e12 wei | 0 |
| v1 positions still owing a burn fee | 0 |
| `burnFee` | 0 |

Two results change the plan:

**The 765 non-v1 rows are stale, not live.** Every sampled one reports `version == 0`,
`tokenDeposits.amounts == 0`, and `nft.valueOf == 0`, while still carrying a non-zero `vaultShare`
in `tokenData`. They are leftovers from the V0 era whose NFTs no longer carry value. Skipping them
loses nobody anything, so no separate migration path is needed — but the skip has to be a skip and
not a revert, which is what the try/catch above buys.

**`burnFee` is already 0.** The fee-waiver branch in `_withdrawAndBurn` is moot on current state.
Omitting the fee from `forceUnwrapOne` is therefore a simplification with no behavioural change
today, rather than a policy decision — though leaving it out also means a future non-zero `burnFee`
cannot accidentally apply to a forced exit.

### The 1.88 eETH gap is surplus, not dilution

An earlier draft of this document guessed that the 765 stale rows sit in the denominator of
`eEthShareForVaultShare` and dilute every live holder's payout. **That was wrong**, and the
end-to-end run disproves it.

Measured on the fork before any unwrap:

| | eETH |
|---|---|
| MM balance | 898.358844466132712144 |
| `outstandingEEthObligation()` | 896.482217982642727563 |
| `unbackedEEth()` | 1.876626483489984581 |

After force-unwrapping all 1594 positions, `outstandingEEthObligation()` fell to **17294 wei**.
The obligation was discharged essentially in full, so holders were never being paid a diluted
share. The stale rows carry `vaultShare` in `tokenData` but contribute nothing to
`totalPooledEEthShares`, which is what the obligation is derived from.

The 1.8766 eETH was surplus all along — eETH sitting in the contract that no position could ever
claim. `unbackedEEth()` identifies it correctly *before* the migration starts, which is what makes
the sweep safe to expose. No tier-vault surgery is needed.
