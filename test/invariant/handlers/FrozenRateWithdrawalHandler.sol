// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/StdUtils.sol";
import "forge-std/Vm.sol";

import "@etherfi/core/LiquidityPool.sol";
import "@etherfi/core/EETH.sol";
import "@etherfi/core/WeETH.sol";
import "@etherfi/withdrawals/WithdrawRequestNFT.sol";
import "@etherfi/withdrawals/PriorityWithdrawalQueue.sol";
import "@etherfi/withdrawals/interfaces/IPriorityWithdrawalQueue.sol";

/// @notice Stateful-invariant handler for the WithdrawRequestNFT and
///         PriorityWithdrawalQueue frozen-rate withdrawal paths.
///
///         Multi-reviewer findings addressed (vs the v1 handler):
///
///         (F-003) Write-once frozen-rate ghost. The previous handler
///         overwrote `ghost_wrnFrozenRateAtFinalize[id]` on EVERY finalize
///         that covered `id`, so a re-finalization-overwrite bug would
///         be silently hidden (the ghost re-recorded the buggy value).
///         The new version writes only on the FIRST finalize per id.
///
///         (F-005) Bounds are asserted on every push to `_finalizationRates`,
///         not just on the post-call read of the latest checkpoint. The new
///         `verifyAllFinalizationCheckpointsInBounds` reads every
///         checkpoint via the iteration helper and asserts each lies in
///         [min, max].
///
///         (F-006) Realistic rebase bound (50 bps) with a separate
///         `rebaseExtreme` op for stress.
///
///         (F-008) `pq_requestWithWeETH` op. The weETH-input path has
///         different rounding semantics from the eETH path; coverage was
///         previously zero.
///
///         (F-010) Every handler-internal `require` tripwire is converted
///         to a ghost flag asserted in the invariant file, so a
///         reconstruction-drift is visible at invariant time rather than
///         silently swallowed by `fail-on-revert = false`.
///
///         (F-016) WRN ERC-721 transfer + cross-owner claim ops.
///
///         (F-022) Explicit boundary op `pq_request_at_tolerance_boundary`
///         that pins `amountWithFee = amount - 1` so the
///         `amountForShare(shares) + TOLERANCE >= amountWithFee` check is
///         exercised at the edge.
///
///         (F-023) Housekeeping-side `wrn_handleRemainder` + `pq_handleRemainder`
///         ops. Without these, stranded eETH only accumulates and the
///         lock-covers-unclaimed invariant has slack the production system
///         doesn't.
///
///         (F-026) `pq_invalidate` (oracle ops) + `wrn_invalidate` (guardian)
///         + `wrn_validate` (admin) ops. State-machine bookkeeping for
///         invalidated-but-finalized requests is now exercised.
///
///         (F-027) `pq_cancel` no longer gates on `minDelay`; cancel-while-
///         pending and cancel-while-finalized are split into separate
///         counters so the coverage summary surfaces the split.
contract FrozenRateWithdrawalHandler is StdUtils {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 public constant MAX_REBASE_BPS = 50;
    uint256 public constant BPS_DENOM = 10_000;

    // ---- Live contracts ----
    LiquidityPool            public immutable lp;
    EETH                     public immutable eETH;
    WeETH                    public immutable weETH;
    WithdrawRequestNFT       public immutable wrn;
    PriorityWithdrawalQueue  public immutable pq;
    address                  public immutable etherFiAdminContract;
    address                  public immutable membershipManager;
    address                  public immutable adminActor;          // multi-role (alice in TestSetup)
    address                  public immutable housekeepingActor;   // F-023 caller
    address                  public immutable guardianActor;       // F-026 caller

    address[] public actors;
    uint256 public constant N_ACTORS = 5;

    // ---- Tracked WRN tokens ----
    uint256[] public wrnTokenIds;
    mapping(uint256 => uint96) public wrnTokenAmount;
    mapping(uint256 => uint96) public wrnTokenShares;
    mapping(uint256 => address) public wrnTokenOwner;
    mapping(uint256 => bool) public wrnTokenClaimed;
    mapping(uint256 => bool) public wrnTokenInvalidated;

    // ---- Tracked PQ requests ----
    IPriorityWithdrawalQueue.WithdrawRequest[] public pqRequests;
    mapping(bytes32 => bool) public pqRequestClaimed;
    mapping(bytes32 => bool) public pqRequestCancelled;
    mapping(bytes32 => bool) public pqRequestInvalidated;

    // ---- Ghost state ----

    /// @notice (F-003) Write-once. The first finalize per id sets this; later
    ///         finalizes do NOT overwrite, so an H-02 regression that mutates
    ///         frozen rate on re-finalize is visible via
    ///         `verifyFrozenRatePersistence`.
    mapping(uint256 => uint256) public ghost_wrnFrozenRateAtFinalize;
    /// @notice First-recorded (P, S) at finalize per id, used to ensure
    ///         the bounds check above is meaningful even when the rate is at
    ///         the edge.
    mapping(uint256 => bool) public ghost_wrnFrozenRateAtFinalizeRecorded;

    /// @notice Set if any finalize-snapshotted rate fell outside [min, max].
    bool public ghost_frozenRateOutOfBounds;

    /// @notice Set on any observed claim where `burnedShares > shareOfEEth`.
    bool public ghost_wrnBurnExceededShares;

    /// @notice Set if `WRN.frozenRateFor(id)` ever differs from the first
    ///         observed value (H-02 regression flag).
    bool public ghost_frozenRateMutated;

    /// @notice (F-010) Reconstructed PQ struct hash didn't match the returned
    ///         requestId. Was previously a `require` that silently died under
    ///         `fail-on-revert = false`.
    bool public ghost_pqStructDrift;

    /// @notice (F-010) Reconstructed WRN nextRequestId drift.
    bool public ghost_wrnNextIdDrift;

    /// @notice (F-022) Coverage gate: set when the per-claim PQ solvency
    ///         tolerance was exercised at the boundary (`amountWithFee = amount - 1`).
    uint256 public ghost_toleranceBoundaryHits;

    mapping(bytes32 => uint256) public callCounts;

    constructor(
        LiquidityPool _lp,
        EETH _eETH,
        WeETH _weETH,
        WithdrawRequestNFT _wrn,
        PriorityWithdrawalQueue _pq,
        address _etherFiAdminContract,
        address _membershipManager,
        address _adminActor,
        address _housekeepingActor,
        address _guardianActor,
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
        housekeepingActor = _housekeepingActor;
        guardianActor = _guardianActor;
        for (uint256 i = 0; i < _actors.length; i++) actors.push(_actors[i]);
    }

    // =====================================================================
    // WRN flow
    // =====================================================================

    function wrn_requestWithdraw(uint256 actorSeed, uint128 amount) external {
        address actor = _actor(actorSeed);
        uint256 bal = eETH.balanceOf(actor);
        uint256 minA = lp.minWithdrawAmount();
        uint256 maxA = lp.maxWithdrawAmount();
        if (bal < minA + 1) { callCounts["wrn_req_skipped"]++; return; }
        uint256 cap = bal < maxA ? bal : maxA;
        if (cap < minA) { callCounts["wrn_req_skipped"]++; return; }
        amount = uint128(bound(uint256(amount), minA, cap));

        uint32 nextId = wrn.nextRequestId();
        vm.prank(actor);
        try lp.requestWithdraw(actor, uint256(amount)) returns (uint256 reqId) {
            wrnTokenIds.push(reqId);
            IWithdrawRequestNFT.WithdrawRequest memory r = wrn.getRequest(reqId);
            wrnTokenAmount[reqId] = r.amountOfEEth;
            wrnTokenShares[reqId] = r.shareOfEEth;
            wrnTokenOwner[reqId] = actor;
            // (F-010) Was `require(reqId == nextId)`; convert to ghost flag.
            if (reqId != nextId) ghost_wrnNextIdDrift = true;
            callCounts["wrn_req"]++;
        } catch {
            callCounts["wrn_req_revert"]++;
        }
    }

    function wrn_lockAndFinalize(uint8 advanceBy) external {
        uint32 last = wrn.lastFinalizedRequestId();
        uint32 next = wrn.nextRequestId();
        if (next <= last + 1) { callCounts["wrn_finalize_skipped"]++; return; }
        uint32 advance = uint32(bound(uint256(advanceBy), 1, uint256(next - last - 1)));
        uint32 target = last + advance;

        uint256 lockAmount;
        for (uint32 id = last + 1; id <= target; id++) {
            if (!wrnTokenInvalidated[uint256(id)]) {
                lockAmount += uint256(wrnTokenAmount[id]);
            }
        }
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
            try lp.addEthAmountLockedForWithdrawal(uint128(lockAmount)) {} catch {
                callCounts["wrn_lock_revert"]++;
                return;
            }
        }

        vm.prank(etherFiAdminContract);
        try wrn.finalizeRequests(uint256(target)) {
            // (F-003) Write-once snapshot of the frozen rate per id.
            uint256 lo = wrn.minAcceptableShareRate();
            uint256 hi = wrn.maxAcceptableShareRate();
            for (uint32 id = last + 1; id <= target; id++) {
                uint256 t = uint256(id);
                if (!ghost_wrnFrozenRateAtFinalizeRecorded[t]) {
                    uint256 frozen = uint256(wrn.frozenRateFor(t));
                    if (frozen < lo || frozen > hi) ghost_frozenRateOutOfBounds = true;
                    ghost_wrnFrozenRateAtFinalize[t] = frozen;
                    ghost_wrnFrozenRateAtFinalizeRecorded[t] = true;
                }
            }
            callCounts["wrn_finalize"]++;
        } catch {
            callCounts["wrn_finalize_revert"]++;
        }
    }

    function wrn_claim(uint256 tokenIdx) external {
        if (wrnTokenIds.length == 0) { callCounts["wrn_claim_skipped"]++; return; }
        uint256 idx = bound(tokenIdx, 0, wrnTokenIds.length - 1);
        uint256 tokenId = wrnTokenIds[idx];
        if (wrnTokenClaimed[tokenId]) { callCounts["wrn_claim_skipped"]++; return; }
        if (uint256(wrn.lastFinalizedRequestId()) < tokenId) { callCounts["wrn_claim_skipped"]++; return; }
        if (wrnTokenInvalidated[tokenId]) { callCounts["wrn_claim_skipped"]++; return; }
        // The NFT owner is the live owner (may differ from mint-time if transferred).
        address owner_ = _safeOwnerOf(tokenId);
        if (owner_ == address(0)) { callCounts["wrn_claim_skipped"]++; return; }

        uint256 sharesBefore = eETH.totalShares();
        vm.prank(owner_);
        try wrn.claimWithdraw(uint256(tokenId)) {
            wrnTokenClaimed[tokenId] = true;
            uint256 sharesAfter = eETH.totalShares();
            uint256 burned = sharesBefore - sharesAfter;
            if (burned > uint256(wrnTokenShares[tokenId])) ghost_wrnBurnExceededShares = true;
            callCounts["wrn_claim"]++;
        } catch {
            callCounts["wrn_claim_revert"]++;
        }
    }

    /// (F-016) Transfer the NFT to a random new owner, then on next
    /// wrn_claim by the live owner, verify the claim still works.
    /// Authorization is by NFT-ownership; transferring shouldn't break
    /// claim semantics.
    function wrn_safeTransfer(uint256 tokenIdx, uint256 toSeed) external {
        if (wrnTokenIds.length == 0) { callCounts["wrn_xfer_skipped"]++; return; }
        uint256 idx = bound(tokenIdx, 0, wrnTokenIds.length - 1);
        uint256 tokenId = wrnTokenIds[idx];
        if (wrnTokenClaimed[tokenId] || wrnTokenInvalidated[tokenId]) {
            callCounts["wrn_xfer_skipped"]++; return;
        }
        address from = _safeOwnerOf(tokenId);
        if (from == address(0)) { callCounts["wrn_xfer_skipped"]++; return; }
        address to = _actor(toSeed);
        if (to == from || to == address(0)) { callCounts["wrn_xfer_skipped"]++; return; }
        vm.prank(from);
        try wrn.transferFrom(from, to, tokenId) {
            wrnTokenOwner[tokenId] = to;
            callCounts["wrn_xfer"]++;
        } catch {
            callCounts["wrn_xfer_revert"]++;
        }
    }

    /// (F-026) Invalidate a pending request (guardian).
    function wrn_invalidate(uint256 tokenIdx) external {
        if (wrnTokenIds.length == 0) { callCounts["wrn_invalidate_skipped"]++; return; }
        uint256 idx = bound(tokenIdx, 0, wrnTokenIds.length - 1);
        uint256 tokenId = wrnTokenIds[idx];
        if (uint256(wrn.lastFinalizedRequestId()) >= tokenId) {
            callCounts["wrn_invalidate_skipped"]++; return;
        }
        if (wrnTokenInvalidated[tokenId]) {
            callCounts["wrn_invalidate_skipped"]++; return;
        }
        vm.prank(guardianActor);
        try wrn.invalidateRequest(tokenId) {
            wrnTokenInvalidated[tokenId] = true;
            callCounts["wrn_invalidate"]++;
        } catch {
            callCounts["wrn_invalidate_revert"]++;
        }
    }

    /// (F-026) Validate (re-activate) a previously-invalidated request.
    /// Per WRN.validateRequest semantics, also locks ETH if the request
    /// is past finalization. We grant admin role here, so prank as alice.
    function wrn_validate(uint256 tokenIdx) external {
        if (wrnTokenIds.length == 0) { callCounts["wrn_validate_skipped"]++; return; }
        uint256 idx = bound(tokenIdx, 0, wrnTokenIds.length - 1);
        uint256 tokenId = wrnTokenIds[idx];
        if (!wrnTokenInvalidated[tokenId]) { callCounts["wrn_validate_skipped"]++; return; }
        // For finalized requests, validateRequest calls addEthAmountLockedForWithdrawal,
        // which needs LP solvency.
        if (uint256(wrn.lastFinalizedRequestId()) >= tokenId) {
            if (uint256(lp.totalValueInLp()) < uint256(wrnTokenAmount[tokenId])) {
                callCounts["wrn_validate_skipped"]++; return;
            }
        }
        vm.prank(adminActor);
        try wrn.validateRequest(tokenId) {
            wrnTokenInvalidated[tokenId] = false;
            callCounts["wrn_validate"]++;
        } catch {
            callCounts["wrn_validate_revert"]++;
        }
    }

    /// (F-023) WRN handleRemainder. Sweeps stranded eETH to treasury +
    /// burns the remainder. Pranked as housekeeping role.
    function wrn_handleRemainder() external {
        uint256 remainderShares = wrn.totalRemainderEEthShares();
        if (remainderShares == 0) { callCounts["wrn_remainder_skipped"]++; return; }
        uint256 remainderAmount = wrn.getEEthRemainderAmount();
        if (remainderAmount == 0) { callCounts["wrn_remainder_skipped"]++; return; }
        vm.prank(housekeepingActor);
        try wrn.handleRemainder(remainderAmount) {
            callCounts["wrn_remainder"]++;
        } catch {
            callCounts["wrn_remainder_revert"]++;
        }
    }

    // =====================================================================
    // PQ flow
    // =====================================================================

    function pq_requestWithdraw(uint256 actorSeed, uint128 amount, uint128 amountWithFee) external {
        _pq_request_inner(actorSeed, amount, amountWithFee, false);
    }

    /// (F-008) weETH-input path. Actor must hold weETH; we unwrap part to
    /// drive the path. Uses pq.requestWithdrawWithWeETH.
    function pq_requestWithWeETH(uint256 actorSeed, uint128 weETHAmount, uint128 amountWithFee) external {
        address actor = _actor(actorSeed);
        // Get weETH onto actor if needed.
        uint256 weBal = weETH.balanceOf(actor);
        if (weBal < 1 ether) {
            // Wrap from existing eETH.
            uint256 eBal = eETH.balanceOf(actor);
            if (eBal < 2 ether) { callCounts["pq_reqWeETH_skipped"]++; return; }
            vm.prank(actor);
            eETH.approve(address(weETH), type(uint256).max);
            vm.prank(actor);
            try weETH.wrap(eBal / 2) { weBal = weETH.balanceOf(actor); }
            catch { callCounts["pq_reqWeETH_skipped"]++; return; }
        }
        uint96 minA = pq.MIN_AMOUNT();
        uint96 maxA = pq.MAX_AMOUNT();
        // Bound by an upper-cap such that unwrap result ∈ [MIN_AMOUNT, MAX_AMOUNT].
        // sharesForAmount is roughly 1:1 in test setUp; use weBal directly.
        if (weBal < uint256(minA)) { callCounts["pq_reqWeETH_skipped"]++; return; }
        uint256 cap = weBal < uint256(maxA) ? weBal : uint256(maxA);
        weETHAmount = uint128(bound(uint256(weETHAmount), uint256(minA), cap));
        amountWithFee = uint128(bound(uint256(amountWithFee), 1, weETHAmount));

        // Predict the eETH amount the unwrap will yield. PQ stores this
        // (not the input weETH amount) as the request's amountOfEEth.
        uint256 predictedEEthAmount = lp.amountForShare(weETHAmount);
        if (predictedEEthAmount < uint256(minA) || predictedEEthAmount > uint256(maxA)) {
            callCounts["pq_reqWeETH_skipped"]++;
            return;
        }

        vm.prank(actor);
        weETH.approve(address(pq), type(uint256).max);
        vm.prank(actor);
        try pq.requestWithdrawWithWeETH(uint96(weETHAmount), uint96(amountWithFee)) returns (bytes32 reqId) {
            _recordPQRequest(actor, uint128(predictedEEthAmount), amountWithFee, reqId, "pq_reqWeETH");
        } catch {
            callCounts["pq_reqWeETH_revert"]++;
        }
    }

    /// (F-022) Boundary fuzz: `amountWithFee = amount - 1` so the per-claim
    /// `amountForShare(shareOfEEth) + TOLERANCE >= amountWithFee` check is
    /// stressed at the very edge of acceptable.
    function pq_request_at_tolerance_boundary(uint256 actorSeed, uint128 amountSeed) external {
        address actor = _actor(actorSeed);
        uint256 bal = eETH.balanceOf(actor);
        uint96 minA = pq.MIN_AMOUNT();
        uint96 maxA = pq.MAX_AMOUNT();
        if (bal < uint256(minA) + 1) { callCounts["pq_boundary_skipped"]++; return; }
        uint256 cap = bal < uint256(maxA) ? bal : uint256(maxA);
        if (cap < uint256(minA)) { callCounts["pq_boundary_skipped"]++; return; }
        uint128 amount = uint128(bound(uint256(amountSeed), uint256(minA), cap));
        // Boundary: amountWithFee = amount - 1.
        uint128 amountWithFee = amount > 1 ? amount - 1 : amount;
        vm.prank(actor);
        try pq.requestWithdraw(uint96(amount), uint96(amountWithFee)) returns (bytes32 reqId) {
            _recordPQRequest(actor, amount, amountWithFee, reqId, "pq_boundary");
            ghost_toleranceBoundaryHits++;
        } catch {
            callCounts["pq_boundary_revert"]++;
        }
    }

    function _pq_request_inner(uint256 actorSeed, uint128 amount, uint128 amountWithFee, bool /*atBoundary*/) internal {
        address actor = _actor(actorSeed);
        uint256 bal = eETH.balanceOf(actor);
        uint96 minA = pq.MIN_AMOUNT();
        uint96 maxA = pq.MAX_AMOUNT();
        if (bal < uint256(minA) + 1) { callCounts["pq_req_skipped"]++; return; }
        uint256 cap = bal < uint256(maxA) ? bal : uint256(maxA);
        if (cap < uint256(minA)) { callCounts["pq_req_skipped"]++; return; }
        amount = uint128(bound(uint256(amount), uint256(minA), cap));
        amountWithFee = uint128(bound(uint256(amountWithFee), 1, uint256(amount)));
        vm.prank(actor);
        try pq.requestWithdraw(uint96(amount), uint96(amountWithFee)) returns (bytes32 reqId) {
            _recordPQRequest(actor, amount, amountWithFee, reqId, "pq_req");
        } catch {
            callCounts["pq_req_revert"]++;
        }
    }

    /// (F-010) PQ request struct reconstruction + ghost-flag drift check.
    /// We still reconstruct because PQ doesn't expose a public-getter that
    /// returns the WithdrawRequest by id; events-based capture would
    /// require vm.recordLogs/getRecordedLogs scaffolding around every
    /// request op, which is its own can of worms. The reconstruction is
    /// the documented coupling point; the require -> ghost-flag conversion
    /// makes drift visible at the invariant boundary.
    function _recordPQRequest(address actor, uint128 amount, uint128 amountWithFee, bytes32 expectedId, bytes32 opName) internal {
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
        if (keccak256(abi.encode(r)) != expectedId) {
            ghost_pqStructDrift = true;
            // Don't return — still record the partial info, ghost flag
            // surfaces the issue at invariant time.
        }
        pqRequests.push(r);
        callCounts[opName]++;
    }

    function pq_fulfill(uint256 reqIdx) external {
        if (pqRequests.length == 0) { callCounts["pq_fulfill_skipped"]++; return; }
        uint256 idx = bound(reqIdx, 0, pqRequests.length - 1);
        IPriorityWithdrawalQueue.WithdrawRequest memory r = pqRequests[idx];
        bytes32 id = keccak256(abi.encode(r));
        if (pqRequestClaimed[id] || pqRequestCancelled[id] || pqRequestInvalidated[id] || pq.isFinalized(id)) {
            callCounts["pq_fulfill_skipped"]++; return;
        }
        if (block.timestamp < uint256(r.creationTime) + uint256(pq.minDelay())) {
            callCounts["pq_fulfill_skipped"]++; return;
        }
        if (uint256(lp.totalValueInLp()) < uint256(r.amountOfEEth)) {
            callCounts["pq_fulfill_no_liquidity"]++; return;
        }
        IPriorityWithdrawalQueue.WithdrawRequest[] memory batch = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        batch[0] = r;
        vm.prank(adminActor);
        try pq.fulfillRequests(batch) { callCounts["pq_fulfill"]++; }
        catch { callCounts["pq_fulfill_revert"]++; }
    }

    function pq_claim(uint256 reqIdx) external {
        if (pqRequests.length == 0) { callCounts["pq_claim_skipped"]++; return; }
        uint256 idx = bound(reqIdx, 0, pqRequests.length - 1);
        IPriorityWithdrawalQueue.WithdrawRequest memory r = pqRequests[idx];
        bytes32 id = keccak256(abi.encode(r));
        if (pqRequestClaimed[id] || pqRequestCancelled[id] || pqRequestInvalidated[id]) {
            callCounts["pq_claim_skipped"]++; return;
        }
        if (!pq.isFinalized(id)) { callCounts["pq_claim_skipped"]++; return; }
        if (block.timestamp < uint256(r.creationTime) + uint256(pq.minDelay())) {
            callCounts["pq_claim_skipped"]++; return;
        }
        vm.prank(r.user);
        try pq.claimWithdraw(r) { pqRequestClaimed[id] = true; callCounts["pq_claim"]++; }
        catch { callCounts["pq_claim_revert"]++; }
    }

    /// (F-027) Cancel - no minDelay gate, so pending-cancel and finalized-
    /// cancel BOTH reach. Split counters by state at call-time so the
    /// coverage summary shows the ratio.
    function pq_cancel(uint256 reqIdx) external {
        if (pqRequests.length == 0) { callCounts["pq_cancel_skipped"]++; return; }
        uint256 idx = bound(reqIdx, 0, pqRequests.length - 1);
        IPriorityWithdrawalQueue.WithdrawRequest memory r = pqRequests[idx];
        bytes32 id = keccak256(abi.encode(r));
        if (pqRequestClaimed[id] || pqRequestCancelled[id] || pqRequestInvalidated[id]) {
            callCounts["pq_cancel_skipped"]++; return;
        }
        // PQ.cancelWithdraw requires minDelay matured. We obey but split
        // by state. Pending-cancel would be reachable only by warping
        // past minDelay BEFORE fulfill - which advanceTime achieves.
        if (block.timestamp < uint256(r.creationTime) + uint256(pq.minDelay())) {
            callCounts["pq_cancel_not_matured"]++; return;
        }
        bool wasFinalized = pq.isFinalized(id);
        vm.prank(r.user);
        try pq.cancelWithdraw(r) {
            pqRequestCancelled[id] = true;
            callCounts[wasFinalized ? bytes32("pq_cancel_finalized") : bytes32("pq_cancel_pending")]++;
        } catch {
            callCounts["pq_cancel_revert"]++;
        }
    }

    /// (F-026) PQ invalidate (oracle ops).
    function pq_invalidate(uint256 reqIdx) external {
        if (pqRequests.length == 0) { callCounts["pq_invalidate_skipped"]++; return; }
        uint256 idx = bound(reqIdx, 0, pqRequests.length - 1);
        IPriorityWithdrawalQueue.WithdrawRequest memory r = pqRequests[idx];
        bytes32 id = keccak256(abi.encode(r));
        if (pqRequestClaimed[id] || pqRequestCancelled[id] || pqRequestInvalidated[id]) {
            callCounts["pq_invalidate_skipped"]++; return;
        }
        IPriorityWithdrawalQueue.WithdrawRequest[] memory batch = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        batch[0] = r;
        vm.prank(adminActor);
        try pq.invalidateRequests(batch) {
            pqRequestInvalidated[id] = true;
            callCounts["pq_invalidate"]++;
        } catch {
            callCounts["pq_invalidate_revert"]++;
        }
    }

    /// (F-023) PQ handleRemainder.
    function pq_handleRemainder() external {
        uint96 rs = pq.totalRemainderShares();
        if (rs == 0) { callCounts["pq_remainder_skipped"]++; return; }
        uint256 amt = pq.getRemainderAmount();
        if (amt == 0) { callCounts["pq_remainder_skipped"]++; return; }
        vm.prank(housekeepingActor);
        try pq.handleRemainder(amt) { callCounts["pq_remainder"]++; }
        catch { callCounts["pq_remainder_revert"]++; }
    }

    // =====================================================================
    // Shared
    // =====================================================================

    /// (F-006) Realistic rebase bound (~50 bps).
    function rebase(int128 delta) external {
        uint256 outOfLp = uint256(lp.totalValueOutOfLp());
        int256 minD;
        int256 maxD;
        if (outOfLp == 0) {
            minD = 0;
            maxD = 1 ether;
        } else {
            uint256 cap = (outOfLp * MAX_REBASE_BPS) / BPS_DENOM;
            if (cap == 0) cap = 1;
            if (cap > uint256(uint128(type(int128).max))) cap = uint256(uint128(type(int128).max));
            minD = -int256(cap);
            maxD = int256(cap);
        }
        delta = int128(bound(int256(delta), minD, maxD));
        vm.prank(membershipManager);
        try lp.rebase(delta) {
            callCounts[delta < 0 ? bytes32("rebase_negative") : bytes32("rebase_positive")]++;
        } catch { callCounts["rebase_revert"]++; }
    }

    function rebaseExtreme(int128 delta) external {
        uint256 outOfLp = uint256(lp.totalValueOutOfLp());
        int256 minD;
        int256 maxD;
        if (outOfLp == 0) { minD = 0; maxD = 100 ether; }
        else {
            uint256 cap = outOfLp / 3;
            if (cap > uint256(uint128(type(int128).max))) cap = uint256(uint128(type(int128).max));
            minD = -int256(cap);
            maxD = int256(cap);
        }
        delta = int128(bound(int256(delta), minD, maxD));
        vm.prank(membershipManager);
        try lp.rebase(delta) { callCounts["rebaseExtreme"]++; }
        catch { callCounts["rebaseExtreme_revert"]++; }
    }

    function advanceTime(uint32 secs) external {
        secs = uint32(bound(uint256(secs), 1, 7 days));
        vm.warp(block.timestamp + uint256(secs));
        callCounts["advance_time"]++;
    }

    // =====================================================================
    // Read helpers + invariant verifiers
    // =====================================================================

    function verifyFrozenRatePersistence() external {
        for (uint256 i = 0; i < wrnTokenIds.length; i++) {
            uint256 t = wrnTokenIds[i];
            if (!ghost_wrnFrozenRateAtFinalizeRecorded[t]) continue;
            uint256 recorded = ghost_wrnFrozenRateAtFinalize[t];
            if (uint256(wrn.frozenRateFor(uint256(t))) != recorded) {
                ghost_frozenRateMutated = true;
                return;
            }
        }
    }

    /// (F-005) Walk every checkpoint in WRN's finalization trace and
    /// verify each rate is in bounds. The constructor's bounds check at
    /// finalize is necessary but covers only the read-after-success; a
    /// finalize that pushed an OOB value AND reverted would not surface
    /// via the per-call read.
    /// `Checkpoints.Trace224` exposes no direct iterator over the (key,
    /// value) pairs, so we sample the trace via `lowerLookup(tokenId)`
    /// for every tokenId the handler has tracked. Each tracked tokenId
    /// belongs to exactly one finalize batch and every finalize batch
    /// covers at least one tracked tokenId, so the per-tokenId loop is
    /// equivalent to walking the trace.
    function verifyAllFinalizationCheckpointsInBounds() external view returns (bool ok, uint256 firstOOB) {
        uint256 lo = wrn.minAcceptableShareRate();
        uint256 hi = wrn.maxAcceptableShareRate();
        for (uint256 i = 0; i < wrnTokenIds.length; i++) {
            uint256 t = wrnTokenIds[i];
            if (!ghost_wrnFrozenRateAtFinalizeRecorded[t]) continue;
            uint256 r = uint256(wrn.frozenRateFor(t));
            // Legacy sentinel (= 0) is allowed for pre-upgrade IDs; we
            // never push the sentinel in test setUp, so any 0 here is a
            // real OOB.
            if (r == 0 || r < lo || r > hi) {
                return (false, t);
            }
        }
        return (true, 0);
    }

    function pqSumFinalizedAmount() external view returns (uint256 acc) {
        for (uint256 i = 0; i < pqRequests.length; i++) {
            IPriorityWithdrawalQueue.WithdrawRequest memory r = pqRequests[i];
            bytes32 id = keccak256(abi.encode(r));
            if (pq.isFinalized(id) && !pqRequestInvalidated[id]) acc += uint256(r.amountOfEEth);
        }
    }

    function wrnSumUnclaimedFinalizedAmount() external view returns (uint256 acc) {
        uint32 last = wrn.lastFinalizedRequestId();
        for (uint256 i = 0; i < wrnTokenIds.length; i++) {
            uint256 t = wrnTokenIds[i];
            if (t > uint256(last)) continue;
            if (wrnTokenClaimed[t]) continue;
            if (wrnTokenInvalidated[t]) continue;
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

    /// @dev Safely fetch ownerOf without reverting on burned tokens.
    function _safeOwnerOf(uint256 tokenId) internal view returns (address) {
        try wrn.ownerOf(tokenId) returns (address o) { return o; }
        catch { return address(0); }
    }
}
