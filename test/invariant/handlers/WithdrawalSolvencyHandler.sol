// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/StdUtils.sol";
import "forge-std/Vm.sol";

import "@etherfi/core/LiquidityPool.sol";
import "@etherfi/core/EETH.sol";
import "@etherfi/withdrawals/WithdrawRequestNFT.sol";
import "@etherfi/withdrawals/interfaces/IWithdrawRequestNFT.sol";

import "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Stateful-invariant handler for invariant I3 — Withdrawal Queue
///         Accounting / Solvency — exercised against the WithdrawRequestNFT
///         escrow path on a mainnet fork.
///
///         I3 (informal): the total outstanding withdrawal claim never exceeds
///         the protocol's redeemable ETH. The formal statement involves live
///         EigenLayer-queued withdrawals across all pods, which cannot be
///         deterministically controlled on a latest-block mainnet fork (see
///         the invariant file's header for the full reclassification rationale).
///         This handler drives the SC-checkable core that the contracts
///         actually enforce:
///
///         (P1) finalize-never-exceeds-liquidity. The protocol's finalize+lock
///              flow (`LiquidityPool.addEthAmountLockedForWithdrawal` ->
///              `_lockEth`) reverts when `totalValueInLp < lockAmount`
///              (mirrored by `EtherFiAdmin._validateWithdrawals`'
///              `finalizedWithdrawalAmount <= totalValueInLp` gate). We mirror
///              production exactly (lock the summed eETH amount of the
///              newly-finalized range, then `finalizeRequests`) and assert that
///              every SUCCESSFUL lock had `lockAmount <= totalValueInLp` at
///              lock time. A success with `lockAmount > inLpBefore` would be a
///              protocol bug.
///
///         (P2) locked-within-accounted-state. Each finalize moves `lockAmount`
///              from `totalValueInLp` to `totalValueOutOfLp` 1:1 AND adds the
///              same amount to `WithdrawRequestNFT.ethAmountLockedForWithdrawal`.
///              Each claim decrements the lock by `request.amountOfEEth` and
///              `totalValueOutOfLp` by `amountToWithdraw <= amountOfEEth`.
///              Hence `ethAmountLockedForWithdrawal <= totalValueOutOfLp`
///              is preserved (the gap only widens), and trivially
///              `lock <= getTotalPooledEther`. Asserted in the invariant file.
///
///         (P3) finalized-always-claimable. A finalized, valid, owned request
///              whose frozen rate sits inside [min,max] can always be claimed:
///              ETH was segregated to the NFT at finalize (escrow >= amount),
///              the frozen-rate share burn is bounded by the request's own
///              shares, and `totalValueOutOfLp` dwarfs any single payout. The
///              handler attempts the claim and trips `ghost_finalizedClaimFailed`
///              if a request meeting all preconditions ever reverts.
contract WithdrawalSolvencyHandler is StdUtils {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 public constant N_EOAS = 5;

    // Revert selectors from LiquidityPool, used to classify lock reverts so the
    // P1 probe can distinguish the liquidity guard (the I3 enforcement) from
    // the migration guard that precedes it.
    bytes4 internal constant SEL_INSUFFICIENT_LIQUIDITY = bytes4(keccak256("InsufficientLiquidity()"));
    bytes4 internal constant SEL_MIGRATION_NOT_COMPLETE = bytes4(keccak256("MigrationNotComplete()"));

    // Selectors used by the S3 invalidate/validate probe to classify reverts.
    bytes4 internal constant SEL_REQUEST_NOT_VALID = bytes4(keccak256("RequestNotValid()"));
    bytes4 internal constant SEL_REQUEST_NOT_FINALIZED = bytes4(keccak256("RequestNotFinalized()"));
    bytes4 internal constant SEL_CANNOT_INVALIDATE_FINALIZED = bytes4(keccak256("CannotInvalidateFinalizedRequest()"));

    LiquidityPool      public immutable lp;
    EETH               public immutable eETH;
    WithdrawRequestNFT public immutable wrn;
    address            public immutable etherFiAdminAddr;
    /// @dev holder of GUARDIAN_ROLE (invalidateRequest) — granted in the test setUp.
    address            public immutable guardian;
    /// @dev holder of OPERATION_TIMELOCK_ROLE (validateRequest).
    address            public immutable operatingTimelock;

    address[N_EOAS] public actors;

    /// @dev tokenIds minted through this handler (so we never touch the
    ///      pre-existing mainnet requests, whose legacy frozen-rate sentinel
    ///      was never pushed on this fork and would route through the
    ///      live-rate fallback).
    uint256[] public ourTokenIds;
    /// @dev mirror of each tokenId's requested eETH amount, so finalize can
    ///      size the ETH lock without re-reading the struct mapping.
    mapping(uint256 => uint96) public tokenAmount;
    /// @dev tokenIds already claimed (burned) — skip on re-selection.
    mapping(uint256 => bool) public claimed;

    // ----- I3 ghosts ------------------------------------------------------

    /// @notice (P1) Set true if a finalize+lock SUCCEEDED while the locked
    ///         amount exceeded `totalValueInLp` at lock time. Must stay false.
    bool public ghost_finalizeExceededLiquidity;
    /// @notice (P1) Set true if `_lockEth`'s liquidity guard REJECTED a lock
    ///         whose amount was actually backed (lockAmount <= inLp) — the
    ///         contract wrongly rejecting a solvent lock. Must stay false.
    ///         NOTE: `_lockEth` can emit InsufficientLiquidity from TWO sites —
    ///         the entry guard (totalValueInLp < _amount) and the post-send
    ///         `_checkTotalValueInLp`. This ghost conservatively flags EITHER
    ///         when the range was backed; the post-send variant only fires if
    ///         the LP is genuinely under-collateralized, which is itself a real
    ///         solvency violation, so catching it here is correct (the name is
    ///         narrower than the full set of conditions it guards).
    bool public ghost_lockRejectedWhileBacked;
    /// @notice (P3) Set true if a request meeting every claimability
    ///         precondition (finalized, valid, owned, frozen rate in band,
    ///         escrow sufficient) reverted on `claimWithdraw`. Must stay false.
    bool public ghost_finalizedClaimFailed;

    /// @notice (M3) Set true if a successful claimWithdraw did not move the three
    ///         balances by their exact contract-correct deltas: recipient +=
    ///         amountToWithdraw, lock -= request.amountOfEEth, totalValueOutOfLp
    ///         -= (amountToWithdraw + strandedSweep). Must stay false.
    bool public ghost_claimDeltaViolated;

    /// @notice (S3) Set true if the invalidate/validate round-trip on a
    ///         non-finalized request produced an unexpected outcome (invalidate
    ///         did not block the claim, or validate did not restore validity).
    bool public ghost_invalidateProbeFailed;
    /// @notice (S3) Set true if invalidateRequest on a FINALIZED request was NOT
    ///         rejected with CannotInvalidateFinalizedRequest. Must stay false.
    bool public ghost_finalizedInvalidateAllowed;

    /// @notice forensic crumbs for the first observed failure of either kind.
    uint256 public ghost_failTokenId;
    bytes4  public ghost_failSelector;
    uint256 public ghost_failLockAmount;
    uint256 public ghost_failInLp;
    /// @notice (M3) forensic crumbs for the first claim-delta mismatch.
    uint256 public ghost_deltaFailTokenId;
    uint256 public ghost_deltaFailExpected;
    uint256 public ghost_deltaFailActual;

    // ----- non-vacuity counters ------------------------------------------

    uint256 public ghost_requestsCreated;
    uint256 public ghost_requestsFinalized;
    uint256 public ghost_requestsClaimed;
    /// @notice number of finalize ops whose P1 bound (lockAmount <= inLp) was
    ///         positively verified through a successful lock — proves P1 was
    ///         actually exercised, not vacuously true.
    uint256 public ghost_finalizeBoundChecks;
    /// @notice number of times `_lockEth`'s liquidity guard POSITIVELY rejected
    ///         a genuinely over-backed lock (lockAmount > inLp) — proves the I3
    ///         enforcement path is actually driven, not merely regression-guarded.
    uint256 public ghost_lockBoundEnforced;
    /// @notice (M3) number of successful claims whose exact three-way deltas
    ///         were verified — proves the delta assertion is actually driven.
    uint256 public ghost_claimDeltaChecks;
    /// @notice (S3) number of completed invalidate/validate round-trips.
    uint256 public ghost_invalidateValidateProbes;
    /// @notice (S3) number of times invalidateRequest on a finalized request was
    ///         correctly rejected with CannotInvalidateFinalizedRequest.
    uint256 public ghost_finalizedInvalidateRejected;

    // ----- coverage / forensics ------------------------------------------

    mapping(bytes32 => uint256) public callCounts;

    constructor(
        LiquidityPool _lp,
        EETH _eETH,
        WithdrawRequestNFT _wrn,
        address _etherFiAdmin,
        address[N_EOAS] memory _actors,
        address _guardian,
        address _operatingTimelock
    ) {
        lp = _lp;
        eETH = _eETH;
        wrn = _wrn;
        etherFiAdminAddr = _etherFiAdmin;
        guardian = _guardian;
        operatingTimelock = _operatingTimelock;
        for (uint256 i = 0; i < N_EOAS; i++) {
            actors[i] = _actors[i];
        }
    }

    // =====================================================================
    // FUZZ OPS
    // =====================================================================

    /// @notice Deposit-backed withdrawal request through the LP, which routes
    ///         to WithdrawRequestNFT.requestWithdraw. Records the new tokenId.
    function requestWithdraw(uint256 actorSeed, uint128 amountSeed) external {
        address actor = _eoa(actorSeed);
        uint256 actorEEth = eETH.balanceOf(actor);
        // LP gates: amount in [minWithdrawAmount, maxWithdrawAmount].
        uint256 lo = lp.minWithdrawAmount();
        uint256 hiCap = lp.maxWithdrawAmount();
        if (actorEEth < lo) { callCounts["req_skipped_funds"]++; return; }
        uint256 hi = actorEEth < hiCap ? actorEEth : hiCap;
        if (hi > 30 ether) hi = 30 ether; // keep individual requests modest
        if (hi < lo) { callCounts["req_skipped_funds"]++; return; }
        uint256 amt = bound(uint256(amountSeed), lo, hi);

        vm.prank(actor);
        try lp.requestWithdraw(actor, amt) returns (uint256 tokenId) {
            ourTokenIds.push(tokenId);
            tokenAmount[tokenId] = uint96(amt);
            ghost_requestsCreated++;
            callCounts["req"]++;
        } catch {
            callCounts["req_revert"]++;
        }
    }

    /// @notice Mirror production finalize ATOMICALLY: `finalizeRequests` then
    ///         `addEthAmountLockedForWithdrawal` for the summed eETH of the
    ///         newly-finalized range, in a SINGLE frame (exactly as
    ///         `EtherFiAdmin._finalizeWithdrawals` does). Running them as one
    ///         atomic unit (via the `this._finalizeThenLock` self-call) is what
    ///         prevents an orphaned lock: if either leg reverts the other rolls
    ///         back, so a lock is never committed while `lastFinalizedRequestId`
    ///         stays put (which would let a later step re-lock the SAME id range
    ///         and double-move ETH out of the LP). Only finalizes ranges that
    ///         include at least one of OUR tokenIds, capped to a modest batch so
    ///         the checkpoint trace and per-op gas stay bounded on the fork.
    function finalizeRequests(uint256 countSeed) external {
        uint32 nextId = wrn.nextRequestId();
        uint32 lastFin = wrn.lastFinalizedRequestId();
        if (nextId <= lastFin + 1) { callCounts["finalize_skipped_none"]++; return; }

        // Advance by a bounded batch within the pending range. Cap at 80 so a
        // single finalize can clear the ~69 pre-existing mainnet pending
        // requests (letting subsequent finalizes reach OUR tokenIds within the
        // run depth) while keeping the view-loop and lock gas bounded.
        uint32 maxAdvance = nextId - 1 - lastFin;
        uint32 advance = uint32(bound(countSeed, 1, maxAdvance > 80 ? 80 : maxAdvance));
        uint32 target = lastFin + advance;

        // Sum the requested eETH for the newly-finalized (lastFin, target] range.
        // This INCLUDES any pre-existing mainnet requests caught in the range,
        // exactly as production would lock them.
        uint256 lockAmount;
        for (uint32 id = lastFin + 1; id <= target; id++) {
            IWithdrawRequestNFT.WithdrawRequest memory r = wrn.getRequest(id);
            lockAmount += uint256(r.amountOfEEth);
        }

        uint256 inLpBefore = uint256(lp.totalValueInLp());

        if (lockAmount > type(uint128).max) { callCounts["finalize_skipped_overflow"]++; return; }

        // ATOMIC finalize+lock (production order: finalize THEN lock, exactly as
        // EtherFiAdmin._finalizeWithdrawals — EtherFiAdmin.sol:427-428). Both legs
        // run inside the single `this._finalizeThenLock` frame, so the run gets
        // all-or-nothing semantics: if EITHER leg reverts, the self-call reverts
        // and BOTH state changes roll back. This is the fix for the orphaned-lock
        // bug — previously the lock was committed in its own tx and a subsequent
        // finalize revert left `ethAmountLockedForWithdrawal` bumped while
        // `lastFinalizedRequestId` stayed put, so a later fuzz step could lock the
        // SAME id range again and move extra ETH out of the LP. Production never
        // exposes that window because the two calls share one transaction.
        //
        // P1 enforcement is still observed here (success => bound must have held;
        // an InsufficientLiquidity revert => bound was genuinely violated), and is
        // additionally driven adversarially & deterministically by the dedicated
        // `probeOverLiquidityLock` op, which positively feeds the guard an
        // over-bound lock every run so the non-vacuity gate never relies on the
        // fuzzer stumbling onto one here.
        try this._finalizeThenLock(uint256(target), lockAmount) {
            // Whole unit committed: finalize landed AND (if non-zero) lock landed.
            ghost_requestsFinalized++;
            callCounts["finalize"]++;
            if (lockAmount > 0) {
                // SUCCESS path: a committed lock MUST have been backed.
                if (lockAmount > inLpBefore) {
                    ghost_finalizeExceededLiquidity = true;
                    ghost_failLockAmount = lockAmount;
                    ghost_failInLp = inLpBefore;
                }
                ghost_finalizeBoundChecks++;
            }
        } catch (bytes memory err) {
            // Atomic rollback: NEITHER finalize nor lock took effect, so there is
            // no orphaned lock to undo and `lastFinalizedRequestId` is unchanged.
            bytes4 sel = err.length >= 4 ? bytes4(err) : bytes4(0);
            if (sel == SEL_INSUFFICIENT_LIQUIDITY) {
                // The lock leg's liquidity guard fired. It MUST have been because
                // the bound was genuinely violated; a liquidity revert while the
                // range was fully backed would itself be a bug.
                if (lockAmount <= inLpBefore) {
                    ghost_lockRejectedWhileBacked = true;
                    ghost_failLockAmount = lockAmount;
                    ghost_failInLp = inLpBefore;
                } else {
                    ghost_lockBoundEnforced++; // positive: guard rejected an unbacked lock
                }
                callCounts["lock_revert_liquidity"]++;
            } else if (sel == SEL_MIGRATION_NOT_COMPLETE) {
                callCounts["lock_revert_migration"]++;
            } else {
                // finalize-leg revert (e.g. CannotFinalizeFutureRequests) or any
                // other classification — the whole unit rolled back regardless.
                callCounts["finalize_revert"]++;
            }
        }
    }

    /// @notice Atomic production-order finalize+lock, executed in a SINGLE call
    ///         frame so the caller can wrap it in try/catch for all-or-nothing
    ///         semantics (the orphaned-lock fix). Mirrors
    ///         `EtherFiAdmin._finalizeWithdrawals`: `finalizeRequests` first,
    ///         then `addEthAmountLockedForWithdrawal` for the range's summed
    ///         eETH. If the lock leg reverts, the finalize leg reverts with it —
    ///         no committed lock can outlive a failed finalize.
    /// @dev    `external` purely so it can be invoked via `this.` to get a fresh
    ///         frame that reverts atomically. Self-call-gated so the fuzzer
    ///         cannot drive it out of band (it is not in the targetSelector set
    ///         either, but the guard is defensive).
    function _finalizeThenLock(uint256 target, uint256 lockAmount) external {
        require(msg.sender == address(this), "self-only");
        vm.prank(etherFiAdminAddr);
        wrn.finalizeRequests(target);
        if (lockAmount > 0) {
            vm.prank(etherFiAdminAddr);
            lp.addEthAmountLockedForWithdrawal(uint128(lockAmount));
        }
    }

    /// @notice (P1, adversarial) Deliberately attempt to lock MORE than the LP
    ///         currently holds in-LP, and assert the contract REJECTS it. This
    ///         positively drives the I3/P1 enforcement (`_lockEth` reverts when
    ///         totalValueInLp < _amount) rather than relying on the fuzzer to
    ///         stumble onto an over-bound range. Self-contained: a single call
    ///         exercises the guard, so the non-vacuity gate
    ///         (ghost_lockBoundEnforced > 0) survives Foundry sequence-shrinking.
    ///
    ///         If the lock SUCCEEDS despite asking for more than in-LP liquidity,
    ///         that is the exact solvency violation P1 forbids -> trip the ghost.
    function probeOverLiquidityLock(uint256 overSeed) external {
        uint256 inLp = uint256(lp.totalValueInLp());
        // Ask for strictly more than in-LP liquidity (bounded so the uint128
        // cast is safe). +1 wei over is enough to violate the guard; add a fuzzed
        // margin for variety.
        uint256 over = bound(overSeed, 1, 1_000 ether);
        uint256 attempt = inLp + over;
        if (attempt > type(uint128).max) { callCounts["probe_skipped_overflow"]++; return; }

        vm.prank(etherFiAdminAddr);
        try lp.addEthAmountLockedForWithdrawal(uint128(attempt)) {
            // Should be impossible: attempt > inLp by construction.
            ghost_finalizeExceededLiquidity = true;
            ghost_failLockAmount = attempt;
            ghost_failInLp = inLp;
            callCounts["probe_unexpected_ok"]++;
        } catch (bytes memory err) {
            bytes4 sel = err.length >= 4 ? bytes4(err) : bytes4(0);
            if (sel == SEL_INSUFFICIENT_LIQUIDITY) {
                ghost_lockBoundEnforced++; // positive observation of the guard
                callCounts["probe_rejected_liquidity"]++;
            } else if (sel == SEL_MIGRATION_NOT_COMPLETE) {
                callCounts["probe_rejected_migration"]++;
            } else {
                callCounts["probe_rejected_other"]++;
            }
        }
    }

    /// @notice (P3) Claim one of OUR finalized requests. Verifies every
    ///         claimability precondition first; if all hold and the claim
    ///         reverts, trips ghost_finalizedClaimFailed.
    function claimWithdraw(uint256 idxSeed) external {
        uint256 n = ourTokenIds.length;
        if (n == 0) { callCounts["claim_skipped_empty"]++; return; }
        uint256 idx = bound(idxSeed, 0, n - 1);
        uint256 tokenId = ourTokenIds[idx];

        if (claimed[tokenId]) { callCounts["claim_skipped_claimed"]++; return; }
        if (tokenId > wrn.lastFinalizedRequestId()) { callCounts["claim_skipped_unfinalized"]++; return; }

        address ownerAddr;
        try wrn.ownerOf(tokenId) returns (address o) { ownerAddr = o; }
        catch { callCounts["claim_skipped_burned"]++; return; }
        if (ownerAddr == address(0)) { callCounts["claim_skipped_burned"]++; return; }

        IWithdrawRequestNFT.WithdrawRequest memory req = wrn.getRequest(tokenId);
        if (!req.isValid) { callCounts["claim_skipped_invalid"]++; return; }

        // For OUR tokenIds (finalized post-upgrade) the trace always returns a
        // non-zero snapshot; legacy tokenIds fall back to the live rate exactly
        // as _getClaimableAmount does (no rate-band guard exists anymore).
        uint224 frozenRate = wrn.frozenRateFor(tokenId);
        if (frozenRate == 0) {
            frozenRate = uint224(lp.amountPerShareCeil());
        }

        // Independent recompute of the payout the contract will pay.
        uint256 amountForShares = Math.mulDiv(uint256(req.shareOfEEth), uint256(frozenRate), 1e18);
        uint256 amountToWithdraw = amountForShares < uint256(req.amountOfEEth)
            ? amountForShares : uint256(req.amountOfEEth);

        // Escrow must cover the payout (it always does: lock added the full
        // amountOfEEth >= amountToWithdraw at finalize).
        if (wrn.ethAmountLockedForWithdrawal() < amountToWithdraw) {
            // Would revert InsufficientEscrow — but by construction this cannot
            // happen for a properly finalized request. Record as a claim
            // failure so a real escrow shortfall surfaces.
            ghost_finalizedClaimFailed = true;
            ghost_failTokenId = tokenId;
            callCounts["claim_escrow_short"]++;
            return;
        }
        // lp.withdraw payout decrements totalValueOutOfLp -= amountToWithdraw;
        // on a fork outOfLp is ~1.8M ETH so this never underflows, but guard
        // defensively so an unrelated underflow isn't misread as a P3 failure.
        if (uint256(lp.totalValueOutOfLp()) < amountToWithdraw) { callCounts["claim_skipped_outlp"]++; return; }

        // ---- (M3) snapshot the three balances the claim moves ----
        // Deltas confirmed from WithdrawRequestNFT._claimWithdraw (L327-360) and
        // LiquidityPool.withdraw (L297-305) + receive (L185-190):
        //   recipient           += amountToWithdraw           (L345 payout)
        //   ethAmountLocked...   -= request.amountOfEEth       (L341, the FULL escrowed
        //                                                       amount, not the payout)
        //   totalValueOutOfLp    -= amountToWithdraw           (LP.withdraw L303)
        //                        -= strandedSweep              (WRN L351-354 sweeps
        //                          balance-above-lock back to LP; LP.receive then
        //                          moves it outOfLp->inLp, L187-188)
        // where strandedSweep = (wrnBal - amountToWithdraw) - (lock - amountOfEEth),
        // which is provably >= 0 (escrow invariant wrnBal >= lock and
        // amountToWithdraw <= amountOfEEth), so the sweep fires whenever it is > 0.
        // Pack the pre-claim snapshot (in its own array to keep the claimWithdraw
        // stack frame shallow — the delta recompute lives in _checkClaimDeltas).
        // [0]=recipient bal, [1]=lock, [2]=totalValueOutOfLp, [3]=WRN bal.
        uint256[4] memory pre = [
            ownerAddr.balance,
            uint256(wrn.ethAmountLockedForWithdrawal()),
            uint256(lp.totalValueOutOfLp()),
            address(wrn).balance
        ];

        vm.prank(ownerAddr);
        try wrn.claimWithdraw(tokenId) {
            claimed[tokenId] = true;
            ghost_requestsClaimed++;
            callCounts["claim"]++;
            _checkClaimDeltas(tokenId, ownerAddr, amountToWithdraw, uint256(req.amountOfEEth), pre);
        } catch (bytes memory err) {
            // A finalized, valid, owned, in-escrow request that reverts is a
            // genuine I3 (P3) violation.
            ghost_finalizedClaimFailed = true;
            ghost_failTokenId = tokenId;
            if (err.length >= 4) {
                bytes4 sel;
                assembly { sel := mload(add(err, 32)) }
                ghost_failSelector = sel;
            }
            callCounts["claim_revert"]++;
        }
    }

    /// @notice (M3) Verify a successful claim moved the three balances by their
    ///         exact contract-correct deltas. Split out of claimWithdraw to keep
    ///         that function's stack frame shallow (avoids stack-too-deep).
    /// @param pre packed pre-claim snapshot: [0]=recipient bal, [1]=lock,
    ///        [2]=totalValueOutOfLp, [3]=WRN bal.
    /// @dev Deltas (see WithdrawRequestNFT._claimWithdraw L327-360, LiquidityPool
    ///      .withdraw L297-305 + receive L185-190):
    ///        recipient        += amountToWithdraw
    ///        lock             -= amountOfEEth (the FULL escrowed amount)
    ///        totalValueOutOfLp-= amountToWithdraw + strandedSweep
    ///      strandedSweep = (wrnBal - amountToWithdraw) - (lock - amountOfEEth),
    ///      provably >= 0 (escrow invariant wrnBal >= lock, amountToWithdraw
    ///      <= amountOfEEth), so the L351 sweep fires whenever it is > 0.
    function _checkClaimDeltas(
        uint256 tokenId,
        address ownerAddr,
        uint256 amountToWithdraw,
        uint256 amountOfEEth,
        uint256[4] memory pre
    ) internal {
        uint256 lockAfter = pre[1] - amountOfEEth;
        uint256 wrnBalAfterPay = pre[3] - amountToWithdraw;
        uint256 strandedSweep = wrnBalAfterPay > lockAfter ? wrnBalAfterPay - lockAfter : 0;

        uint256 expRecipient = pre[0] + amountToWithdraw;
        uint256 expOutOfLp = pre[2] - amountToWithdraw - strandedSweep;

        if (ownerAddr.balance != expRecipient) {
            ghost_claimDeltaViolated = true;
            ghost_deltaFailTokenId = tokenId;
            ghost_deltaFailExpected = expRecipient;
            ghost_deltaFailActual = ownerAddr.balance;
        } else if (uint256(wrn.ethAmountLockedForWithdrawal()) != lockAfter) {
            ghost_claimDeltaViolated = true;
            ghost_deltaFailTokenId = tokenId;
            ghost_deltaFailExpected = lockAfter;
            ghost_deltaFailActual = uint256(wrn.ethAmountLockedForWithdrawal());
        } else if (uint256(lp.totalValueOutOfLp()) != expOutOfLp) {
            ghost_claimDeltaViolated = true;
            ghost_deltaFailTokenId = tokenId;
            ghost_deltaFailExpected = expOutOfLp;
            ghost_deltaFailActual = uint256(lp.totalValueOutOfLp());
        } else {
            ghost_claimDeltaChecks++;
        }
    }

    /// @notice (S3) Deterministic invalidate/validate probe. Two parts, both
    ///         self-contained so they fire reliably every run:
    ///           A. Create a FRESH (not-yet-finalized) request, have the guardian
    ///              invalidateRequest it, and assert the owner can no longer claim
    ///              (claim reverts RequestNotValid). Then have the operating
    ///              timelock validateRequest it back and assert validity is
    ///              restored (the claim's RequestNotValid block is gone — only the
    ///              RequestNotFinalized block remains, since it is unfinalized).
    ///           B. Attempt invalidateRequest on a FINALIZED request
    ///              (lastFinalizedRequestId) and assert it reverts
    ///              CannotInvalidateFinalizedRequest.
    ///         Roles: invalidateRequest is onlyGuardian, validateRequest is
    ///         onlyOperatingTimelock (WithdrawRequestNFT L258/L270).
    function doInvalidateValidateProbe(uint256 actorSeed, uint128 amountSeed) external {
        // ---- Part A: round-trip on a fresh, non-finalized request ----
        address actor = _eoa(actorSeed);
        uint256 actorEEth = eETH.balanceOf(actor);
        uint256 lo = lp.minWithdrawAmount();
        uint256 hiCap = lp.maxWithdrawAmount();
        if (actorEEth >= lo) {
            uint256 hi = actorEEth < hiCap ? actorEEth : hiCap;
            if (hi > 30 ether) hi = 30 ether;
            if (hi >= lo) {
                uint256 amt = bound(uint256(amountSeed), lo, hi);
                vm.prank(actor);
                try lp.requestWithdraw(actor, amt) returns (uint256 tokenId) {
                    ourTokenIds.push(tokenId);
                    tokenAmount[tokenId] = uint96(amt);
                    ghost_requestsCreated++;
                    callCounts["req"]++;

                    // Guardian invalidates the not-yet-finalized request.
                    vm.prank(guardian);
                    try wrn.invalidateRequest(tokenId) {
                        callCounts["invalidate_ok"]++;
                        // MUST now be invalid.
                        if (wrn.getRequest(tokenId).isValid) ghost_invalidateProbeFailed = true;
                        // MUST no longer be claimable: claim reverts RequestNotValid.
                        vm.prank(actor);
                        try wrn.claimWithdraw(tokenId) {
                            ghost_invalidateProbeFailed = true; // invalidated request settled
                            callCounts["invalidated_claim_ok"]++;
                        } catch (bytes memory cerr) {
                            bytes4 csel = cerr.length >= 4 ? bytes4(cerr) : bytes4(0);
                            if (csel == SEL_REQUEST_NOT_VALID) {
                                callCounts["invalidated_claim_rejected"]++;
                            } else {
                                // Some other revert also blocks the claim, but the
                                // invalid flag should be the FIRST gate to trip.
                                ghost_invalidateProbeFailed = true;
                                callCounts["invalidated_claim_other_revert"]++;
                            }
                        }

                        // Operating timelock validates it back.
                        vm.prank(operatingTimelock);
                        try wrn.validateRequest(tokenId) {
                            callCounts["validate_ok"]++;
                            // MUST be valid again.
                            if (!wrn.getRequest(tokenId).isValid) ghost_invalidateProbeFailed = true;
                            // The RequestNotValid block MUST be gone. Claiming an
                            // unfinalized-but-valid request now reverts
                            // RequestNotFinalized (proving validity was restored).
                            vm.prank(actor);
                            try wrn.claimWithdraw(tokenId) {
                                // Unfinalized request should not settle.
                                ghost_invalidateProbeFailed = true;
                                callCounts["revalidated_claim_ok"]++;
                            } catch (bytes memory rerr) {
                                bytes4 rsel = rerr.length >= 4 ? bytes4(rerr) : bytes4(0);
                                if (rsel == SEL_REQUEST_NOT_VALID) {
                                    // Still blocked as invalid -> validate did not restore it.
                                    ghost_invalidateProbeFailed = true;
                                    callCounts["revalidated_still_invalid"]++;
                                } else {
                                    // RequestNotFinalized (or any non-validity revert): the
                                    // validity block is gone, as required.
                                    callCounts["revalidated_claim_rejected"]++;
                                }
                            }
                            ghost_invalidateValidateProbes++;
                        } catch {
                            // validateRequest of an existing invalid, non-finalized
                            // request should always succeed.
                            ghost_invalidateProbeFailed = true;
                            callCounts["validate_revert"]++;
                        }
                    } catch {
                        // invalidateRequest of a valid, non-finalized request should
                        // always succeed for the guardian.
                        ghost_invalidateProbeFailed = true;
                        callCounts["invalidate_revert"]++;
                    }
                } catch {
                    callCounts["req_revert"]++;
                }
            }
        }

        // ---- Part B: invalidate on a FINALIZED request MUST revert ----
        // invalidateRequest checks `requestId <= lastFinalizedRequestId` FIRST
        // (WithdrawRequestNFT L259), so lastFinalizedRequestId itself trips the
        // guard regardless of that request's validity/existence.
        uint32 lastFin = wrn.lastFinalizedRequestId();
        if (lastFin >= 1) {
            vm.prank(guardian);
            try wrn.invalidateRequest(uint256(lastFin)) {
                ghost_finalizedInvalidateAllowed = true;
                callCounts["invalidate_finalized_ok"]++;
            } catch (bytes memory err) {
                bytes4 sel = err.length >= 4 ? bytes4(err) : bytes4(0);
                if (sel == SEL_CANNOT_INVALIDATE_FINALIZED) {
                    ghost_finalizedInvalidateRejected++;
                    callCounts["invalidate_finalized_rejected"]++;
                } else {
                    ghost_finalizedInvalidateAllowed = true; // wrong revert reason
                    callCounts["invalidate_finalized_other"]++;
                }
            }
        }
    }

    /// @notice Positive rebase stress — keeps the rate climbing (frozen-rate
    ///         shield is irrelevant to solvency here, just adds state churn).
    ///         Bounded to <= 0.2% of TVL so it stays under the contract's
    ///         MAX_POSITIVE_REBASE_BPS (0.25%) cap and actually applies.
    ///         Caller is the etherFiAdminContract — the only address
    ///         `LiquidityPool.rebase` accepts (LiquidityPool.sol:456).
    function rebasePositive(uint128 deltaSeed) external {
        uint256 outOfLp = uint256(lp.totalValueOutOfLp());
        uint256 cap = outOfLp == 0 ? 1 ether : (outOfLp * 20) / 1e4; // <=0.2%
        if (cap == 0) cap = 1;
        if (cap > uint256(uint128(type(int128).max))) cap = uint256(uint128(type(int128).max));
        int128 delta = int128(int256(bound(uint256(deltaSeed), 0, cap)));
        vm.prank(etherFiAdminAddr);
        try lp.rebase(delta, 0) { callCounts["rebase_pos"]++; }
        catch { callCounts["rebase_pos_revert"]++; }
    }

    /// @notice Bounded NEGATIVE rebase (<= 0.5% of TVL). Bounded so the share
    ///         rate stays far above `minAmountForShare`: an extreme slash that
    ///         pushes `amountForShare(1e18) < minAmountForShare` would legitimately
    ///         block claims via `_checkMinAmountForShare` — that is a known
    ///         liveness edge, NOT a solvency bug, so we keep it out of the P3
    ///         claimability property by bounding the slash conservatively.
    function rebaseNegative(uint128 deltaSeed) external {
        uint256 outOfLp = uint256(lp.totalValueOutOfLp());
        // Keep headroom above the WRN lock so a later claim's
        // `totalValueOutOfLp -= amountToWithdraw` cannot underflow.
        uint256 lock = uint256(wrn.ethAmountLockedForWithdrawal());
        if (outOfLp <= lock) { callCounts["rebase_neg_skipped"]++; return; }
        uint256 headroom = outOfLp - lock;
        uint256 cap = (outOfLp * 50) / 1e4; // <=0.5% of TVL
        if (cap > headroom / 2) cap = headroom / 2;
        if (cap == 0) { callCounts["rebase_neg_skipped"]++; return; }
        if (cap > uint256(uint128(type(int128).max))) cap = uint256(uint128(type(int128).max));
        int128 delta = -int128(int256(bound(uint256(deltaSeed), 1, cap)));
        vm.prank(etherFiAdminAddr);
        try lp.rebase(delta, 0) { callCounts["rebase_neg"]++; }
        catch { callCounts["rebase_neg_revert"]++; }
    }

    // =====================================================================
    // VIEW HELPERS
    // =====================================================================

    function ourTokenIdsLength() external view returns (uint256) { return ourTokenIds.length; }

    function _eoa(uint256 seed) internal view returns (address) {
        return actors[seed % N_EOAS];
    }
}
