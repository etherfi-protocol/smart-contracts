// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/StdUtils.sol";
import "forge-std/Vm.sol";

import "../../../src/LiquidityPool.sol";
import "../../../src/EETH.sol";
import "../../../src/WeETH.sol";
import "../../../src/WithdrawRequestNFT.sol";
import "../../../src/PriorityWithdrawalQueue.sol";
import "../../../src/interfaces/IPriorityWithdrawalQueue.sol";

/// @notice Stateful-invariant handler for the WithdrawRequestNFT and
///         PriorityWithdrawalQueue frozen-rate withdrawal paths — the two
///         entry points PR #428 intentionally left EXEMPT from its
///         `nonDecreasingRate` modifier.
///
///         For the exempt paths, rate-deflation is bounded not by the LP
///         modifier but by:
///           - WRN: a frozen rate snapshotted at finalize time, in
///             `[minAcceptableShareRate, maxAcceptableShareRate]`, plus
///             the `BurnExceedsShares` revert in the claim path
///             (`burnedShares <= request.shareOfEEth`).
///           - PQ: the per-claim solvency check
///             `amountForShare(shareOfEEth) + TOLERANCE >= amountWithFee`
///             plus the live `amountPerShareCeil()` rate at claim.
///
///         The handler drives long sequences of request → fulfill →
///         claim/cancel with interleaved rebases and time advances. Ghost
///         state lets the test file assert:
///           - WRN/PQ ETH solvency (`balance >= lock`) at all times.
///           - Frozen rate immutable under post-finalize rebases.
///           - Frozen rate bounded at finalize.
///           - PQ finalized-amount sum reconciles with on-chain lock.
///           - Set-membership exclusivity (pending vs finalized vs removed).
///
///         The handler intentionally:
///         - Inherits StdUtils only — no Test base.
///         - Pranks as `_alice` (a TestSetup-granted multi-role address)
///           for admin-side ops (`addToWhitelist`, `addEthAmountLockedForWithdrawal`,
///           `fulfillRequests`, etc.). The test file pre-grants whatever
///           additional roles are needed (HOUSEKEEPING_OPERATIONS_ROLE) and
///           whitelists all EOA actors on PQ before deploying the handler.
///         - Wraps every protocol call in try/catch so a single legitimate-
///           but-revertable input (e.g., bound on shareOfEEth=0 dust)
///           doesn't abort the run.
contract FrozenRateWithdrawalHandler is StdUtils {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // ---- Live contracts ----
    LiquidityPool            public immutable lp;
    EETH                     public immutable eETH;
    WeETH                    public immutable weETH;
    WithdrawRequestNFT       public immutable wrn;
    PriorityWithdrawalQueue  public immutable pq;
    address                  public immutable etherFiAdminContract;
    address                  public immutable membershipManager;
    address                  public immutable adminActor;

    // ---- Actor pool (all 5 are pre-whitelisted on PQ and pre-funded with eETH by the test setup) ----
    address[] public actors;
    uint256 public constant N_ACTORS = 5;

    // ---- Tracked WRN tokens ----
    /// @dev Every tokenId ever minted via this handler. Indexed by handler
    ///      sequence, not the WRN's own requestId — but we store the WRN
    ///      requestId so we can look it up.
    uint256[] public wrnTokenIds;
    /// @dev tokenId -> snapshot of `(amountOfEEth, shareOfEEth)` at request time
    mapping(uint256 => uint96) public wrnTokenAmount;
    mapping(uint256 => uint96) public wrnTokenShares;
    /// @dev tokenId -> recipient (the NFT owner at mint time; transfers tracked separately)
    mapping(uint256 => address) public wrnTokenOwner;
    /// @dev tokenId -> true once claimed
    mapping(uint256 => bool) public wrnTokenClaimed;

    // ---- Tracked PQ requests ----
    IPriorityWithdrawalQueue.WithdrawRequest[] public pqRequests;
    /// @dev requestId hash -> claimed
    mapping(bytes32 => bool) public pqRequestClaimed;
    /// @dev requestId hash -> cancelled (covers both pending-cancel and finalized-cancel)
    mapping(bytes32 => bool) public pqRequestCancelled;

    // ---- Ghost state for invariants ----

    /// @notice Frozen rate captured at finalize for each tokenId. Zero
    ///         means "not yet finalized via this handler". After a rebase,
    ///         we re-read `WRN.frozenRateFor(tokenId)` and verify equality
    ///         in the test assertion.
    mapping(uint256 => uint256) public ghost_wrnFrozenRateAtFinalize;

    /// @notice Set to `true` the first time any finalize-snapshotted rate
    ///         fell outside [minAcceptableShareRate, maxAcceptableShareRate].
    ///         Should be impossible (WRN reverts at finalize), so flag
    ///         flipping = WRN bounds bypassed.
    bool public ghost_frozenRateOutOfBounds;

    /// @notice Set to `true` if any claim violated the burn-bounded-by-request
    ///         identity, i.e. observed `burnedShares > request.shareOfEEth`.
    ///         WRN reverts on this internally, so it's a regression flag.
    bool public ghost_wrnBurnExceededShares;

    /// @notice Set to `true` if a post-finalize `WRN.frozenRateFor(tokenId)`
    ///         ever differs from the value snapshotted at finalize.
    bool public ghost_frozenRateMutated;

    mapping(bytes32 => uint256) public callCounts;

    /// @notice Pending count of WRN requests not yet finalized. The handler
    ///         needs this to bound `wrn_lockAndFinalize` so it doesn't try
    ///         to finalize zero requests.
    function wrnNextRequestId() external view returns (uint32) { return wrn.nextRequestId(); }

    constructor(
        LiquidityPool _lp,
        EETH _eETH,
        WeETH _weETH,
        WithdrawRequestNFT _wrn,
        PriorityWithdrawalQueue _pq,
        address _etherFiAdminContract,
        address _membershipManager,
        address _adminActor,
        address[] memory _actors
    ) {
        lp = _lp;
        eETH = _eETH;
        weETH = _weETH;
        wrn = _wrn;
        pq = _pq;
        etherFiAdminContract = _etherFiAdminContract;
        membershipManager = _membershipManager;
        adminActor = _adminActor;
        for (uint256 i = 0; i < _actors.length; i++) actors.push(_actors[i]);
    }

    // =====================================================================
    // WRN flow
    // =====================================================================

    /// @notice Mints a fresh WRN request via LP.requestWithdraw. Bounded
    ///         against `actor`'s live eETH balance, the LP `minWithdrawAmount`
    ///         floor, and the `maxWithdrawAmount` ceiling.
    function wrn_requestWithdraw(uint256 actorSeed, uint128 amount) external {
        address actor = _actor(actorSeed);
        uint256 bal = eETH.balanceOf(actor);
        uint256 minA = lp.minWithdrawAmount();
        uint256 maxA = lp.maxWithdrawAmount();
        if (bal < minA + 1) {
            callCounts["wrn_req_skipped"]++;
            return;
        }
        uint256 cap = bal < maxA ? bal : maxA;
        if (cap < minA) {
            callCounts["wrn_req_skipped"]++;
            return;
        }
        amount = uint128(bound(uint256(amount), minA, cap));

        // requestWithdraw transfers eETH from the caller to WRN. eETH approval
        // must already be set; the test setup grants type(uint256).max on
        // construction so we don't burn a handler slot on it.
        uint32 nextId = wrn.nextRequestId();
        vm.prank(actor);
        try lp.requestWithdraw(actor, uint256(amount)) returns (uint256 reqId) {
            // Record on success.
            wrnTokenIds.push(reqId);
            IWithdrawRequestNFT.WithdrawRequest memory r = wrn.getRequest(reqId);
            wrnTokenAmount[reqId] = r.amountOfEEth;
            wrnTokenShares[reqId] = r.shareOfEEth;
            wrnTokenOwner[reqId] = actor;
            callCounts["wrn_req"]++;
            // Sanity check the id is the one we expected.
            require(reqId == nextId, "wrn nextRequestId drifted");
        } catch {
            callCounts["wrn_req_revert"]++;
        }
    }

    /// @notice Admin batched step: pick a target finalize id, lock the
    ///         corresponding ETH on WRN via `LP.addEthAmountLockedForWithdrawal`,
    ///         then call `WRN.finalizeRequests(toId)` as etherFiAdmin. Records
    ///         the post-finalize frozen rate for ghost verification.
    function wrn_lockAndFinalize(uint8 advanceBy) external {
        uint32 last = wrn.lastFinalizedRequestId();
        uint32 next = wrn.nextRequestId();
        if (next <= last + 1) {
            callCounts["wrn_finalize_skipped"]++;
            return;
        }
        uint32 advance = uint32(bound(uint256(advanceBy), 1, uint256(next - last - 1)));
        uint32 target = last + advance;

        // Sum amountOfEEth for the (last, target] range so we know how much ETH to lock.
        uint256 lockAmount;
        for (uint32 id = last + 1; id <= target; id++) {
            lockAmount += uint256(wrnTokenAmount[id]);
        }

        // Lock ETH on WRN — only succeeds if LP.totalValueInLp covers it.
        if (lockAmount > 0) {
            if (uint256(lp.totalValueInLp()) < lockAmount) {
                callCounts["wrn_finalize_no_liquidity"]++;
                return;
            }
            if (lockAmount > type(uint128).max) {
                callCounts["wrn_finalize_overflow"]++;
                return;
            }
            vm.prank(etherFiAdminContract);
            try lp.addEthAmountLockedForWithdrawal(uint128(lockAmount)) {
                // ok
            } catch {
                callCounts["wrn_lock_revert"]++;
                return;
            }
        }

        // Now finalize. WRN reads `LP.amountPerShareCeil()` and pushes a checkpoint.
        uint256 rateBefore = lp.amountPerShareCeil();
        vm.prank(etherFiAdminContract);
        try wrn.finalizeRequests(uint256(target)) {
            // Snapshot the frozen rate per finalized tokenId for ghost checks.
            uint256 frozen = uint256(wrn.frozenRateFor(uint256(target)));
            // Range check the snapshot against WRN's stated bounds.
            uint256 lo = wrn.minAcceptableShareRate();
            uint256 hi = wrn.maxAcceptableShareRate();
            if (frozen < lo || frozen > hi) ghost_frozenRateOutOfBounds = true;
            for (uint32 id = last + 1; id <= target; id++) {
                ghost_wrnFrozenRateAtFinalize[uint256(id)] = uint256(wrn.frozenRateFor(uint256(id)));
            }
            require(rateBefore >= 1, "rate sanity");
            callCounts["wrn_finalize"]++;
        } catch {
            callCounts["wrn_finalize_revert"]++;
        }
    }

    /// @notice Claim a previously finalized request as its owner. Verifies
    ///         the burn-bounded-by-request property using the on-chain
    ///         frozen rate and the request's shareOfEEth.
    function wrn_claim(uint256 tokenIdx) external {
        if (wrnTokenIds.length == 0) {
            callCounts["wrn_claim_skipped"]++;
            return;
        }
        uint256 idx = bound(tokenIdx, 0, wrnTokenIds.length - 1);
        uint256 tokenId = wrnTokenIds[idx];
        if (wrnTokenClaimed[tokenId]) {
            callCounts["wrn_claim_skipped"]++;
            return;
        }
        if (uint256(wrn.lastFinalizedRequestId()) < tokenId) {
            callCounts["wrn_claim_skipped"]++;
            return;
        }

        // Compute expected burnedShares using the frozen rate; assert
        // post-call. We snapshot before to derive `burnedShares = S0 - S1`.
        address owner_ = wrnTokenOwner[tokenId];
        // ownerOf may differ if NFT was transferred outside the handler;
        // but we don't expose transfer ops here, so this should match.

        uint256 sharesBefore = eETH.totalShares();
        uint256 frozen = uint256(wrn.frozenRateFor(uint256(tokenId)));

        vm.prank(owner_);
        try wrn.claimWithdraw(uint256(tokenId)) {
            wrnTokenClaimed[tokenId] = true;
            uint256 sharesAfter = eETH.totalShares();
            uint256 burned = sharesBefore - sharesAfter;
            if (burned > uint256(wrnTokenShares[tokenId])) {
                ghost_wrnBurnExceededShares = true;
            }
            require(frozen >= 1, "rate sanity");
            callCounts["wrn_claim"]++;
        } catch {
            callCounts["wrn_claim_revert"]++;
        }
    }

    // =====================================================================
    // PQ flow
    // =====================================================================

    function pq_requestWithdraw(uint256 actorSeed, uint128 amount, uint128 amountWithFee) external {
        address actor = _actor(actorSeed);
        uint256 bal = eETH.balanceOf(actor);
        uint96 minA = pq.MIN_AMOUNT();
        uint96 maxA = pq.MAX_AMOUNT();
        if (bal < uint256(minA) + 1) {
            callCounts["pq_req_skipped"]++;
            return;
        }
        uint256 cap = bal < uint256(maxA) ? bal : uint256(maxA);
        if (cap < uint256(minA)) {
            callCounts["pq_req_skipped"]++;
            return;
        }
        amount = uint128(bound(uint256(amount), uint256(minA), cap));
        // amountWithFee must be in (0, amount].
        amountWithFee = uint128(bound(uint256(amountWithFee), 1, uint256(amount)));

        vm.prank(actor);
        try pq.requestWithdraw(uint96(amount), uint96(amountWithFee)) returns (bytes32 reqId) {
            // Reconstruct the request struct via the public events isn't
            // viable from inside the handler; re-derive instead. We need
            // shareOfEEth and creationTime — both queryable.
            // PQ stores the request only by id (hash); we need to know the
            // original fields to re-compute the id later for claim/cancel.
            // Reconstruct from what we just provided + sharesForAmount(amount).
            // creationTime = block.timestamp at the call.
            // nonce: we read PQ.nonce() AFTER the call; the request used (nonce-1).
            uint32 usedNonce = pq.nonce() - 1;
            uint96 shareOfEEth = uint96(lp.sharesForAmount(uint256(amount)));
            IPriorityWithdrawalQueue.WithdrawRequest memory r = IPriorityWithdrawalQueue.WithdrawRequest({
                user: actor,
                amountOfEEth: uint96(amount),
                shareOfEEth: shareOfEEth,
                amountWithFee: uint96(amountWithFee),
                nonce: usedNonce,
                creationTime: uint32(block.timestamp)
            });
            // Sanity: hash matches.
            require(keccak256(abi.encode(r)) == reqId, "pq req hash drift");
            pqRequests.push(r);
            callCounts["pq_req"]++;
        } catch {
            callCounts["pq_req_revert"]++;
        }
    }

    function pq_fulfill(uint256 reqIdx) external {
        if (pqRequests.length == 0) {
            callCounts["pq_fulfill_skipped"]++;
            return;
        }
        uint256 idx = bound(reqIdx, 0, pqRequests.length - 1);
        IPriorityWithdrawalQueue.WithdrawRequest memory r = pqRequests[idx];
        bytes32 id = keccak256(abi.encode(r));
        if (pqRequestClaimed[id] || pqRequestCancelled[id] || pq.isFinalized(id)) {
            callCounts["pq_fulfill_skipped"]++;
            return;
        }
        if (block.timestamp < uint256(r.creationTime) + uint256(pq.minDelay())) {
            callCounts["pq_fulfill_skipped"]++;
            return;
        }

        // Need totalValueInLp to cover the lock. Skip if not.
        if (uint256(lp.totalValueInLp()) < uint256(r.amountOfEEth)) {
            callCounts["pq_fulfill_no_liquidity"]++;
            return;
        }

        IPriorityWithdrawalQueue.WithdrawRequest[] memory batch = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        batch[0] = r;

        vm.prank(adminActor);
        try pq.fulfillRequests(batch) {
            callCounts["pq_fulfill"]++;
        } catch {
            callCounts["pq_fulfill_revert"]++;
        }
    }

    function pq_claim(uint256 reqIdx) external {
        if (pqRequests.length == 0) {
            callCounts["pq_claim_skipped"]++;
            return;
        }
        uint256 idx = bound(reqIdx, 0, pqRequests.length - 1);
        IPriorityWithdrawalQueue.WithdrawRequest memory r = pqRequests[idx];
        bytes32 id = keccak256(abi.encode(r));
        if (pqRequestClaimed[id] || pqRequestCancelled[id]) {
            callCounts["pq_claim_skipped"]++;
            return;
        }
        if (!pq.isFinalized(id)) {
            callCounts["pq_claim_skipped"]++;
            return;
        }
        if (block.timestamp < uint256(r.creationTime) + uint256(pq.minDelay())) {
            callCounts["pq_claim_skipped"]++;
            return;
        }

        vm.prank(r.user);
        try pq.claimWithdraw(r) {
            pqRequestClaimed[id] = true;
            callCounts["pq_claim"]++;
        } catch {
            callCounts["pq_claim_revert"]++;
        }
    }

    function pq_cancel(uint256 reqIdx) external {
        if (pqRequests.length == 0) {
            callCounts["pq_cancel_skipped"]++;
            return;
        }
        uint256 idx = bound(reqIdx, 0, pqRequests.length - 1);
        IPriorityWithdrawalQueue.WithdrawRequest memory r = pqRequests[idx];
        bytes32 id = keccak256(abi.encode(r));
        if (pqRequestClaimed[id] || pqRequestCancelled[id]) {
            callCounts["pq_cancel_skipped"]++;
            return;
        }
        if (block.timestamp < uint256(r.creationTime) + uint256(pq.minDelay())) {
            callCounts["pq_cancel_skipped"]++;
            return;
        }

        vm.prank(r.user);
        try pq.cancelWithdraw(r) {
            pqRequestCancelled[id] = true;
            callCounts["pq_cancel"]++;
        } catch {
            callCounts["pq_cancel_revert"]++;
        }
    }

    // =====================================================================
    // Shared noise — rebase + time
    // =====================================================================

    /// @notice EXEMPT path. After each rebase, every previously-finalized
    ///         WRN tokenId's `frozenRateFor` should still equal the value
    ///         the handler recorded at finalize time. The test file polls
    ///         `verifyFrozenRatePersistence` to update the ghost flag.
    function rebase(int128 delta) external {
        uint256 outOfLp = uint256(lp.totalValueOutOfLp());
        int256 minD;
        int256 maxD;
        if (outOfLp == 0) {
            minD = 0;
            maxD = 100 ether;
        } else {
            uint256 cap = outOfLp / 3;
            if (cap > uint256(uint128(type(int128).max))) cap = uint256(uint128(type(int128).max));
            minD = -int256(cap);
            maxD = int256(cap);
        }
        delta = int128(bound(int256(delta), minD, maxD));

        vm.prank(membershipManager);
        try lp.rebase(delta) {
            callCounts["rebase"]++;
        } catch {
            callCounts["rebase_revert"]++;
        }
    }

    /// @notice Advances `block.timestamp` so PQ requests can mature.
    function advanceTime(uint32 secondsToAdvance) external {
        secondsToAdvance = uint32(bound(uint256(secondsToAdvance), 1, 7 days));
        vm.warp(block.timestamp + uint256(secondsToAdvance));
        callCounts["advance_time"]++;
    }

    // =====================================================================
    // Read helpers + invariant verifiers (called by the test file)
    // =====================================================================

    /// @notice Sweeps every tokenId the handler has finalized and asserts
    ///         the current on-chain `frozenRateFor` matches the recorded
    ///         post-finalize value. Sets ghost_frozenRateMutated otherwise.
    ///         Called by the test file's invariant function.
    function verifyFrozenRatePersistence() external {
        for (uint256 i = 0; i < wrnTokenIds.length; i++) {
            uint256 t = wrnTokenIds[i];
            uint256 recorded = ghost_wrnFrozenRateAtFinalize[t];
            if (recorded == 0) continue; // not yet finalized via handler
            if (uint256(wrn.frozenRateFor(uint256(t))) != recorded) {
                ghost_frozenRateMutated = true;
                return;
            }
        }
    }

    /// @notice Returns the sum of `amountOfEEth` for PQ requests currently
    ///         in the finalized set (not yet claimed/cancelled). Used by
    ///         the PQ-lock-conservation invariant.
    function pqSumFinalizedAmount() external view returns (uint256 acc) {
        for (uint256 i = 0; i < pqRequests.length; i++) {
            IPriorityWithdrawalQueue.WithdrawRequest memory r = pqRequests[i];
            bytes32 id = keccak256(abi.encode(r));
            if (pq.isFinalized(id)) acc += uint256(r.amountOfEEth);
        }
    }

    /// @notice Returns the sum of `amountOfEEth` for WRN tokenIds in
    ///         (lastClaimed, lastFinalizedRequestId]. WRN's
    ///         ethAmountLockedForWithdrawal decreases by `amountOfEEth` per
    ///         claim, so the live lock is `sum(unclaimed-but-finalized) +
    ///         strandedExcess`.
    function wrnSumUnclaimedFinalizedAmount() external view returns (uint256 acc) {
        uint32 last = wrn.lastFinalizedRequestId();
        for (uint256 i = 0; i < wrnTokenIds.length; i++) {
            uint256 t = wrnTokenIds[i];
            if (t > uint256(last)) continue;
            if (wrnTokenClaimed[t]) continue;
            acc += uint256(wrnTokenAmount[t]);
        }
    }

    function wrnTokenIdsLength() external view returns (uint256) { return wrnTokenIds.length; }
    function pqRequestsLength() external view returns (uint256) { return pqRequests.length; }
    function actorsLength() external view returns (uint256) { return actors.length; }
    function actorAt(uint256 i) external view returns (address) { return actors[i]; }

    // =====================================================================
    // Internals
    // =====================================================================

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }
}
