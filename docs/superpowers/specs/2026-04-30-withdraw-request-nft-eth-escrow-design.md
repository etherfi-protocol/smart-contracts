# WithdrawRequestNFT ETH Escrow at Finalization (Simplified)

**Status:** Draft
**Date:** 2026-04-30 (last revised 2026-05-01)
**Author:** pankaj@ether.fi

## 1. Problem

Today, `WithdrawRequestNFT` holds no ETH. Lifecycle:

1. **Request** — `LiquidityPool.requestWithdraw` pulls eETH from the user, transfers `amount` eETH (= `share` shares) to `WithdrawRequestNFT`, mints an NFT recording `(amountOfEEth, shareOfEEth)`.
2. **Finalize** — `EtherFiAdmin` calls `LiquidityPool.addEthAmountLockedForWithdrawal(total)` and `WithdrawRequestNFT.finalizeRequests(toId)`. **No ETH moves**; only the accounting counter `ethAmountLockedForWithdrawal` increments.
3. **Claim** — `WithdrawRequestNFT.claimWithdraw` calls `LP.withdraw(recipient, amount)`, which burns shares and sends ETH **from the LP balance**.

Because finalized claims are paid out of the live LP balance, other LP consumers (`membershipManager`, `etherFiRedemptionManager`, `priorityWithdrawalQueue`) can drain `totalValueInLp` between finalize and claim, causing finalized claims to revert with `InsufficientLiquidity`.

## 2. Goal

Segregate the ETH for finalized withdrawals at finalize time. Move ETH from `LiquidityPool` into `WithdrawRequestNFT` (and apply the same pattern to `priorityWithdrawalQueue`) so claims are paid from the segregated balance and cannot be starved by other LP consumers.

**Operating assumption:** the eETH share rate is non-decreasing in practice (validator rewards accrue positively, slashing is rare and bounded). Under this assumption, `min(amountOfEEth, amountForShare(shareOfEEth))` is always `amountOfEEth` post-request — the claim amount equals the amount implicitly priced at finalize. No per-request snapshot is required to deliver a deterministic payout. If a non-decreasing-rate assumption ever no longer holds, the design above this layer (oracle pause / bunker mode) is the right place to handle it, not per-request storage in this contract.

## 3. Non-Goals

- Per-request snapshot of payout. Not needed under the non-decreasing-rate assumption.
- Rate-drop / slashing-window protection. Out of scope; addressed at the oracle/admin layer.
- Changing economics for `membershipManager` or `etherFiRedemptionManager` — their `LP.withdraw` path is untouched.
- Changing the `IMPLICIT_FEE_CLAIMER_ROLE` / `handleRemainder` flow.
- Changing the existing `aggregateSumEEthShareAmount` scan or `totalRemainderEEthShares` semantics.

## 4. Design

### 4.1 Storage Changes

**None on `WithdrawRequestNFT.WithdrawRequest`.** No struct change. No new per-request storage.

`LiquidityPool.ethAmountLockedForWithdrawal` is **kept** but redefined: ETH currently held by `WithdrawRequestNFT` (and by `priorityWithdrawalQueue` via its own counter) earmarked for finalized-but-unclaimed requests.

### 4.2 LiquidityPool — Modify `addEthAmountLockedForWithdrawal`

Existing function on LP, called by `EtherFiAdmin` during the oracle finalize step. Today it only increments the counter. New behavior also transfers the ETH and rebalances TVL accounting so the share rate is preserved.

```solidity
// LiquidityPool
function addEthAmountLockedForWithdrawal(uint128 _amount) external {
    // existing access control unchanged (admin / etherFiAdmin role)
    if (totalValueInLp < _amount) revert InsufficientLiquidity();

    totalValueInLp     -= _amount;
    totalValueOutOfLp  += _amount;            // NFT-held ETH still counts in TVL until claim
    ethAmountLockedForWithdrawal += _amount;

    _sendFund(address(withdrawRequestNFT), _amount);
}
```

TVL invariant: `totalValueInLp - X` and `totalValueOutOfLp + X` cancel — `getTotalPooledEther()` is unchanged. `eETH.totalShares` is unchanged. Share rate is unchanged at finalize.

### 4.3 LiquidityPool — Modify `withdraw`

When the caller is `withdrawRequestNFT` or `priorityWithdrawalQueue`, the ETH is already in the caller's balance — `LP.withdraw` must do the share burn + accounting but **must not send ETH** (the caller will pay the recipient itself).

```solidity
// LiquidityPool
function withdraw(address _recipient, uint256 _amount) external nonReentrant returns (uint256) {
    uint256 share = sharesForWithdrawalAmount(_amount);
    require(
        msg.sender == address(withdrawRequestNFT) ||
        msg.sender == address(membershipManager) ||
        msg.sender == address(etherFiRedemptionManager) ||
        msg.sender == priorityWithdrawalQueue,
        "Incorrect Caller"
    );
    // Pause carve-outs unchanged.
    if (msg.sender != address(withdrawRequestNFT) && msg.sender != priorityWithdrawalQueue) {
        _requireNotPaused();
        _requireNotPausedUntil();
    }

    if (eETH.balanceOf(msg.sender) < _amount) revert InsufficientLiquidity();
    if (_amount > type(uint128).max || _amount == 0 || share == 0) revert InvalidAmount();

    bool fromSegregated = (msg.sender == address(withdrawRequestNFT) || msg.sender == priorityWithdrawalQueue);

    if (fromSegregated) {
        // ETH already lives in caller's balance. Only accounting + share burn here.
        if (msg.sender == address(withdrawRequestNFT)) {
            // NFT counter lives on LP (today's storage). Decrement it here.
            if (ethAmountLockedForWithdrawal < _amount) revert InsufficientLiquidity();
            ethAmountLockedForWithdrawal -= uint128(_amount);
        }
        // Queue caller: queue tracks its own ethAmountLockedForPriorityWithdrawal counter and
        // decrements it inside its own _claimWithdraw before calling LP.withdraw.

        totalValueOutOfLp -= uint128(_amount);   // ETH now leaves the protocol via caller
        eETH.burnShares(msg.sender, share);
        // No _sendFund — caller transfers ETH to recipient itself.
        return share;
    }

    // Unchanged path for membershipManager / etherFiRedemptionManager.
    if (totalValueInLp < _amount) revert InsufficientLiquidity();
    totalValueInLp -= uint128(_amount);
    eETH.burnShares(msg.sender, share);
    _sendFund(_recipient, _amount);
    return share;
}
```

The `_recipient` parameter is unused on the segregated path — caller's responsibility to honor it. Documented in the natspec.

### 4.4 WithdrawRequestNFT — Update `_claimWithdraw`

Existing claim flow keeps the same payout formula (deterministic under non-decreasing-rate assumption) and the same `totalRemainderEEthShares` bookkeeping. The only change: after `LP.withdraw` (which now does share burn + accounting only), send ETH from the NFT contract's balance.

```solidity
function _claimWithdraw(uint256 tokenId, address recipient) internal {
    require(ownerOf(tokenId) == msg.sender, "Not the owner of the NFT");
    IWithdrawRequestNFT.WithdrawRequest memory request = _requests[tokenId];
    require(request.isValid, "Request is not valid");

    uint256 amountToWithdraw = getClaimableAmount(tokenId);
    uint256 shareAmountToBurnForWithdrawal = liquidityPool.sharesForWithdrawalAmount(amountToWithdraw);

    _burn(tokenId);
    delete _requests[tokenId];

    totalRemainderEEthShares += request.shareOfEEth - shareAmountToBurnForWithdrawal;

    uint256 amountBurnedShare = liquidityPool.withdraw(recipient, amountToWithdraw);
    assert(amountBurnedShare == shareAmountToBurnForWithdrawal);

    // ETH is held by this contract (transferred at finalize via addEthAmountLockedForWithdrawal).
    (bool ok, ) = payable(recipient).call{value: amountToWithdraw}("");
    require(ok, "ETH transfer failed");

    emit WithdrawRequestClaimed(uint32(tokenId), amountToWithdraw, amountBurnedShare, recipient, 0);
}
```

`getClaimableAmount` is **unchanged** — still `min(amountOfEEth, amountForShare(shareOfEEth)) - fee`. Under the non-decreasing-rate assumption it equals `amountOfEEth - fee` after the request is created.

### 4.5 PriorityWithdrawalQueue — Mirror the Pattern

Three sites change in `PriorityWithdrawalQueue`, plus one new function on `LiquidityPool` to receive returned funds on cancel.

#### 4.5.1 Lock site: `fulfillRequests`

Currently increments `ethAmountLockedForPriorityWithdrawal += totalAmountToLock` at the end of the loop (line 341). Add a paired ETH transfer from LP to the queue. New LP function (mirrors §4.2 in shape, but for the priority queue counter):

```solidity
// LiquidityPool
function transferLockedEthForPriority(uint128 _amount) external {
    require(msg.sender == priorityWithdrawalQueue, "Incorrect Caller");
    if (totalValueInLp < _amount) revert InsufficientLiquidity();

    totalValueInLp     -= _amount;
    totalValueOutOfLp  += _amount;
    // Note: ethAmountLockedForWithdrawal is for NFT only. Priority queue tracks its own counter.

    _sendFund(priorityWithdrawalQueue, _amount);
}
```

`PriorityWithdrawalQueue.fulfillRequests` calls it once after the loop:

```solidity
ethAmountLockedForPriorityWithdrawal += uint128(totalAmountToLock);
liquidityPool.transferLockedEthForPriority(uint128(totalAmountToLock));
```

#### 4.5.2 Claim site: `_claimWithdraw`

Currently calls `liquidityPool.withdraw(request.user, amountToWithdraw)` which sends ETH from LP. With §4.3's branch in place, `LP.withdraw` from a `priorityWithdrawalQueue` caller now skips `_sendFund` and only does share burn + accounting. The queue must pay the user from its own balance:

```solidity
uint256 burnedShares = liquidityPool.withdraw(request.user, amountToWithdraw);
if (burnedShares != sharesToBurn) revert InvalidBurnedSharesAmount();
(bool ok, ) = payable(request.user).call{value: amountToWithdraw}("");
require(ok, "ETH transfer failed");
```

`LP.withdraw`'s segregated branch must additionally decrement the priority queue's lock counter via the same accounting it uses for the NFT path. Since LP currently tracks the NFT counter directly (`ethAmountLockedForWithdrawal`), and the priority queue tracks its own counter on its own contract, the cleanest approach is:
- LP's segregated branch decrements `totalValueOutOfLp` only (not the per-caller counter, which lives on each respective contract).
- The queue (and the NFT) decrements its own counter inside its claim function before calling `LP.withdraw`.

This means §4.3 is updated: in the segregated branch, only `totalValueOutOfLp -= _amount` and `eETH.burnShares` happen on LP; the per-caller "ethAmountLockedForX" counter stays on the caller and is decremented there.

#### 4.5.3 Cancel site: `_cancelWithdrawRequest`

Today, on cancel of a *finalized* request, the queue decrements `ethAmountLockedForPriorityWithdrawal -= amountOfEEth`. With our change, the queue is also physically holding the matching ETH — it must return it to LP:

```solidity
if (wasFinalized) {
    ethAmountLockedForPriorityWithdrawal -= uint128(request.amountOfEEth);
    liquidityPool.returnLockedEth{value: request.amountOfEEth}(request.amountOfEEth);
}
```

New LP function:

```solidity
// LiquidityPool
function returnLockedEth(uint256 _amount) external payable {
    require(msg.sender == priorityWithdrawalQueue, "Incorrect Caller");
    if (msg.value != _amount || _amount == 0) revert InvalidAmount();
    totalValueOutOfLp -= uint128(_amount);
    totalValueInLp    += uint128(_amount);
    // No share movement: cancel returns shares to the user (existing flow);
    // we only un-lock the ETH side here.
}
```

Cancel-on-non-finalized requests don't touch ETH (no ETH was locked); no change needed.

`invalidateRequests` (admin path) routes through `_cancelWithdrawRequest` and inherits the same handling. For batches, the implementation may aggregate the ETH-return into a single `returnLockedEth` call per `invalidateRequests` invocation rather than once per request, to save gas.

#### 4.5.4 Share-return correctness on cancel

`_cancelWithdrawRequest` returns `amountForShare(shareOfEEth)` eETH to the user — at the **current** rate, not the request rate (per the existing comment at line 557: "don't want user's loss while being in queue"). Our change does not affect this:
- Queue's ETH balance drops by `request.amountOfEEth` (returned to LP).
- Queue's eETH balance drops by `shareOfEEth` shares (transferred to user).
- LP's TVL is preserved (the LP/OutOfLp rebalance cancels).
- Under the non-decreasing-rate assumption, `amountForShare(shareOfEEth) >= request.amountOfEEth`, so the user is never paid less than what was locked — the `min()` cap doesn't apply on cancel because cancel returns shares, not ETH.

### 4.6 Migration

Existing `ethAmountLockedForWithdrawal` is non-zero on mainnet but the corresponding ETH is still inside LP. Need a one-shot migration to physically move it to `WithdrawRequestNFT` (and the same for `priorityWithdrawalQueue` if it has a non-zero locked counter).

`initializeOnUpgradeV2` on `LiquidityPool`, gated to UPGRADE_TIMELOCK, called once after the upgrade. Sweeps both the NFT-side counter and the priority queue counter:

```solidity
function initializeOnUpgradeV2() external onlyOwner {
    require(!escrowMigrationCompleted, "already migrated");

    uint128 nftLocked   = ethAmountLockedForWithdrawal;
    uint128 queueLocked = priorityWithdrawalQueue == address(0)
        ? 0
        : uint128(IPriorityWithdrawalQueue(priorityWithdrawalQueue).ethAmountLockedForPriorityWithdrawal());

    uint128 totalLocked = nftLocked + queueLocked;
    if (totalLocked > 0) {
        if (totalValueInLp < totalLocked) revert InsufficientLiquidity();
        totalValueInLp    -= totalLocked;
        totalValueOutOfLp += totalLocked;

        if (nftLocked > 0)   _sendFund(address(withdrawRequestNFT),   nftLocked);
        if (queueLocked > 0) _sendFund(address(priorityWithdrawalQueue), queueLocked);
    }

    escrowMigrationCompleted = true;
}
```

Properties:
- One transaction, no pagination needed (it's a single aggregate move, not per-request).
- TVL preserved by LP↔OutOfLp rebalance.
- `totalShares` unchanged (no share burn during migration, mirrors the steady-state path).
- `ethAmountLockedForWithdrawal` is **not** reset — its value continues to mean "ETH currently in NFT contract earmarked for finalized-unclaimed requests," which is now true.
- Idempotent via `escrowMigrationCompleted` flag.

### 4.7 Pause / Invalidation / Seize

- All unchanged. NFT contract's pause behavior on claims unchanged. LP pause carve-outs unchanged (segregated callers still bypass LP pause).

## 5. Access Control

| Function                                          | Caller                                  | Change |
|---------------------------------------------------|-----------------------------------------|--------|
| `LiquidityPool.addEthAmountLockedForWithdrawal`   | existing role (etherFiAdmin)            | Body changed; access unchanged. |
| `LiquidityPool.withdraw`                          | existing callers                        | Branch added for segregated callers; access unchanged. |
| `LiquidityPool.transferLockedEthForPriority`      | only `priorityWithdrawalQueue`          | New. |
| `LiquidityPool.returnLockedEth`                   | only `priorityWithdrawalQueue`          | New, payable. |
| `LiquidityPool.initializeOnUpgradeV2`             | `owner()` (UPGRADE_TIMELOCK)            | New, one-shot. Sweeps both NFT and queue locked balances. |
| `PriorityWithdrawalQueue.fulfillRequests`         | `onlyRequestManager`                    | Body adds LP transfer call; access unchanged. |
| `PriorityWithdrawalQueue._cancelWithdrawRequest`  | internal (user/`onlyRequestManager`)    | Body adds LP-return call on finalized cancel. |
| `PriorityWithdrawalQueue._claimWithdraw`          | internal                                | Body adds ETH-send-from-queue after `LP.withdraw`. |

No new roles introduced.

## 6. Edge Cases

- **`addEthAmountLockedForWithdrawal` called with `_amount > totalValueInLp`.** Reverts `InsufficientLiquidity`. Caller (EtherFiAdmin) should ensure the LP has the funds before finalizing — same expectation as today, just enforced earlier (at lock time vs. at claim time).
- **ETH transfer to `WithdrawRequestNFT` requires `receive()` to accept.** Add `receive() external payable {}` (or restrict to LP via `require(msg.sender == liquidityPool)` for safety against drift).
- **`PriorityWithdrawalQueue` must also accept ETH from LP.** Add `receive() external payable {}` with the same `require(msg.sender == liquidityPool)` guard. Without this, `LP.transferLockedEthForPriority` reverts on the `_sendFund` call.
- **Claim payout exceeds NFT contract's balance.** Under the non-decreasing-rate assumption this is impossible — `amountForShare(shareOfEEth) >= amountOfEEth` post-request, so the min always returns `amountOfEEth - fee`, which equals the amount transferred at finalize. Add a defensive `require(address(this).balance >= amountToWithdraw, "insufficient escrow")` for safety; if it ever trips, it indicates the rate-drop scenario the design explicitly does not protect against.
- **`_recipient` in `LP.withdraw` from segregated caller.** Unused on that path. Document as such; do not remove the parameter (ABI compat).
- **Reentrancy on claim ETH transfer.** Use `nonReentrant` on `_claimWithdraw` (already present). State writes (burn, delete, LP.withdraw) before the ETH `call`.

## 7. Testing Plan

Unit tests — WithdrawRequestNFT path:

- `requestWithdraw` → `addEthAmountLockedForWithdrawal(amount)` → assert NFT contract balance += amount; LP `totalValueInLp -= amount`; LP `totalValueOutOfLp += amount`; `eETH.totalShares` unchanged; share rate unchanged.
- Claim post-finalize: NFT recipient receives `amountToWithdraw`; `totalValueOutOfLp -=`; `ethAmountLockedForWithdrawal -=`; `eETH.totalShares -=` matching `sharesForWithdrawalAmount(amount)`.
- Positive rebase between finalize and claim: claim still pays `amountOfEEth - fee`, no surplus stuck (the `min()` is degenerate).
- LP solvency drained between finalize and claim (e.g., redemption manager): claim still succeeds (NFT contract pays from its own balance, LP only does share burn + counter).
- `getClaimableAmount` unchanged — same formula returns same value pre- and post-upgrade for any unclaimed request.

Unit tests — PriorityWithdrawalQueue path:

- `requestWithdraw` → `fulfillRequests([req])` → assert queue ETH balance += `amountOfEEth`; LP `totalValueInLp` decreased by same; LP `totalValueOutOfLp` increased by same; `ethAmountLockedForPriorityWithdrawal` increased by same; `eETH.totalShares` unchanged.
- Claim post-fulfill: user receives `amountWithFee`; queue ETH balance -=; queue `ethAmountLockedForPriorityWithdrawal` -=; LP `totalValueOutOfLp` -=; `eETH.totalShares` -= matching `sharesForWithdrawalAmount(amount)`.
- Cancel a finalized request: assert queue ETH balance decreases by `amountOfEEth`; LP `totalValueInLp` increases by same; LP `totalValueOutOfLp` decreases by same; queue's `ethAmountLockedForPriorityWithdrawal` decreases by same; user receives `amountForShare(shareOfEEth)` eETH; share rate unchanged across the cancel.
- Cancel a non-finalized (pending) request: no ETH movement (no ETH was ever locked); user gets shares back as today.
- Cancel after positive rebase: user gets back more eETH than `amountOfEEth` (`amountForShare(shareOfEEth) > amountOfEEth`); queue still returns exactly `amountOfEEth` ETH to LP; no leakage.
- `invalidateRequests` over a mixed batch (some finalized, some pending): aggregate ETH return matches sum over finalized requests' `amountOfEEth`; pending ones don't trigger any ETH movement.
- Adversarial: caller spoofing as queue/NFT to call `LP.returnLockedEth` / `transferLockedEthForPriority` reverts on the access-control check.

Migration tests (fork-based):

- `initializeRealisticFork(MAINNET_FORK)` — capture pre-upgrade `ethAmountLockedForWithdrawal`, NFT balance (= 0), LP balance.
- Run upgrade → `LiquidityPool.initializeOnUpgradeV2`.
- Assert: NFT balance == pre-upgrade `ethAmountLockedForWithdrawal`; LP `totalValueInLp` decreased by same; LP `totalValueOutOfLp` increased by same; `getTotalPooledEther` unchanged; `eETH.totalShares` unchanged.
- Pick an existing finalized-unclaimed request from mainnet state; simulate claim; assert payout matches the (unchanged) `getClaimableAmount` formula.

Integration tests (mainnet fork):

- Full lifecycle with concurrent activity: deposit → request → admin finalize (calls modified `addEthAmountLockedForWithdrawal`) → adversarial drain via redemption manager → user claim succeeds.

## 8. Rollout

1. Deploy new `LiquidityPool`, `WithdrawRequestNFT`, and `PriorityWithdrawalQueue` implementations.
2. Schedule timelock proposals: upgrade all three proxies, then call `LiquidityPool.initializeOnUpgradeV2` (one-shot ETH sweep covering both NFT and queue locked balances).
3. Verify on-chain invariants per §7. Specifically:
   - NFT contract balance == previous `ethAmountLockedForWithdrawal`.
   - Queue contract balance == previous `ethAmountLockedForPriorityWithdrawal`.
   - LP `totalValueInLp` decreased by the sum, `totalValueOutOfLp` increased by the sum.
   - Share rate unchanged.

## 9. Open Questions / Follow-Ups

- **`receive()` policy.** Strict `require(msg.sender == liquidityPool)` is safest on both `WithdrawRequestNFT` and `PriorityWithdrawalQueue`. Verify no protocol path delivers ETH outside the documented funding paths (`addEthAmountLockedForWithdrawal`, `transferLockedEthForPriority`, `initializeOnUpgradeV2`).
- **`getClaimableAmount` `min()` clause.** Under the non-decreasing-rate assumption it is always degenerate. Worth keeping for defense-in-depth, or simplify? Default: keep.
- **Documentation of the rate assumption.** Add a comment near `addEthAmountLockedForWithdrawal`, `transferLockedEthForPriority`, and the two `_claimWithdraw` flows explaining that under non-decreasing rate the segregated balance always covers the claim, and that rate-drop scenarios are out of scope for this layer.
- **Aggregating cancel returns in `invalidateRequests`.** Implementation may batch ETH-return into a single `returnLockedEth` call per `invalidateRequests` invocation rather than once per request. Decide based on expected batch sizes.
- **Priority queue's `cancelWithdraw` post-condition checks (`_verifyCancelPostConditions`).** Today's checks compare LP ETH and eETH share balances pre/post. With our change, LP ETH increases on a finalized cancel (return path). Update the post-condition assertions to expect this delta.
