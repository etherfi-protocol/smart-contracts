// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/StdUtils.sol";
import "forge-std/Vm.sol";

import "../../../src/LiquidityPool.sol";
import "../../../src/EETH.sol";
import "../../../src/WithdrawRequestNFT.sol";
import "../../../src/interfaces/IWithdrawRequestNFT.sol";

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

    LiquidityPool      public immutable lp;
    EETH               public immutable eETH;
    WithdrawRequestNFT public immutable wrn;
    address            public immutable etherFiAdminAddr;
    address            public immutable membershipManager;

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

    /// @notice forensic crumbs for the first observed failure of either kind.
    uint256 public ghost_failTokenId;
    bytes4  public ghost_failSelector;
    uint256 public ghost_failLockAmount;
    uint256 public ghost_failInLp;

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

    // ----- coverage / forensics ------------------------------------------

    mapping(bytes32 => uint256) public callCounts;

    constructor(
        LiquidityPool _lp,
        EETH _eETH,
        WithdrawRequestNFT _wrn,
        address _etherFiAdmin,
        address _membershipManager,
        address[N_EOAS] memory _actors
    ) {
        lp = _lp;
        eETH = _eETH;
        wrn = _wrn;
        etherFiAdminAddr = _etherFiAdmin;
        membershipManager = _membershipManager;
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

    /// @notice Mirror production finalize: lock the summed eETH amount of the
    ///         newly-finalized range (`addEthAmountLockedForWithdrawal`) then
    ///         `finalizeRequests`. Only finalizes ranges that include at least
    ///         one of OUR tokenIds, capped to a modest batch so the checkpoint
    ///         trace and per-op gas stay bounded on the fork.
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

        // P1 PROBE (mirrors the correct I13 doFinalize pattern): do NOT
        // pre-filter on liquidity. Attempt the lock UNCONDITIONALLY and let the
        // contract decide. LiquidityPool._lockEth (LiquidityPool.sol:598)
        // reverts InsufficientLiquidity when totalValueInLp < _amount — that
        // revert IS the I3/P1 enforcement, so we must feed it the over-bound
        // input, not refuse it.
        //   - SUCCESS  => the contract permitted the lock; P1 demands the bound
        //                 actually held (lockAmount <= inLpBefore). If a lock
        //                 ever succeeds with lockAmount > inLpBefore, _lockEth
        //                 wrongly let an unbacked lock through => trip the ghost.
        //   - REVERT   => confirm it was the liquidity guard (or the migration
        //                 guard, which precedes it) and that the bound was in
        //                 fact violated; record it as a positive enforcement
        //                 observation. A revert while lockAmount <= inLpBefore
        //                 would be the contract wrongly rejecting a backed lock.
        if (lockAmount > 0) {
            vm.prank(etherFiAdminAddr);
            try lp.addEthAmountLockedForWithdrawal(uint128(lockAmount)) {
                // SUCCESS path: P1 must hold.
                if (lockAmount > inLpBefore) {
                    ghost_finalizeExceededLiquidity = true;
                    ghost_failLockAmount = lockAmount;
                    ghost_failInLp = inLpBefore;
                }
                ghost_finalizeBoundChecks++;
            } catch (bytes memory err) {
                bytes4 sel = err.length >= 4 ? bytes4(err) : bytes4(0);
                if (sel == SEL_INSUFFICIENT_LIQUIDITY) {
                    // Enforcement fired. It MUST have been because the bound was
                    // genuinely violated; a liquidity revert while the range was
                    // fully backed would itself be a bug.
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
                    callCounts["lock_revert_other"]++;
                }
                return; // cannot finalize a range whose lock did not land
            }
        }

        vm.prank(etherFiAdminAddr);
        try wrn.finalizeRequests(uint256(target)) {
            ghost_requestsFinalized++;
            callCounts["finalize"]++;
        } catch {
            callCounts["finalize_revert"]++;
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

        // Frozen rate must resolve inside the acceptable band. For OUR tokenIds
        // (finalized post-upgrade) the trace always returns a non-zero snapshot;
        // we still defensively resolve the legacy fallback the contract uses.
        uint224 frozenRate = wrn.frozenRateFor(tokenId);
        if (frozenRate == 0) {
            uint256 live = lp.amountPerShareCeil();
            if (live < wrn.minAcceptableShareRate() || live > wrn.maxAcceptableShareRate()) {
                // Live-rate fallback out of band: the contract would revert
                // InvalidLiveRate. This is NOT a claimability-of-finalized
                // violation (it's the rate guard), so skip cleanly.
                callCounts["claim_skipped_rate"]++;
                return;
            }
            frozenRate = uint224(live);
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

        vm.prank(ownerAddr);
        try wrn.claimWithdraw(tokenId) {
            claimed[tokenId] = true;
            ghost_requestsClaimed++;
            callCounts["claim"]++;
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

    /// @notice Positive rebase stress — keeps the rate climbing (frozen-rate
    ///         shield is irrelevant to solvency here, just adds state churn).
    function rebasePositive(uint128 deltaSeed) external {
        uint256 outOfLp = uint256(lp.totalValueOutOfLp());
        uint256 cap = outOfLp == 0 ? 1 ether : (outOfLp * 50) / 1e4; // <=0.5%
        if (cap == 0) cap = 1;
        if (cap > uint256(uint128(type(int128).max))) cap = uint256(uint128(type(int128).max));
        int128 delta = int128(int256(bound(uint256(deltaSeed), 0, cap)));
        vm.prank(membershipManager);
        try lp.rebase(delta) { callCounts["rebase_pos"]++; }
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
        vm.prank(membershipManager);
        try lp.rebase(delta) { callCounts["rebase_neg"]++; }
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
