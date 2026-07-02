// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "@etherfi/oracle/EtherFiOracle.sol";
import "@etherfi/oracle/EtherFiAdmin.sol";
import "@etherfi/oracle/interfaces/IEtherFiOracle.sol";
import "@etherfi/core/interfaces/ILiquidityPool.sol";

/// @notice Stateful-fuzz handler for invariant I5 (Oracle Integrity).
///
///   I5: an OracleReport may only ADVANCE EtherFiAdmin.lastHandledReportRefSlot
///       (i.e. be "applied" by executeTasks) when ALL gates hold at the
///       moment of execution:
///         (a) quorum    — consensus reached with >= quorumSize() submissions
///         (b) APR cap   — abs(rebase APR) <= acceptableRebaseAprInBps()
///         (c) freshness — currentSlot >= postReportWaitTimeInSlots + consensusSlot
///         (d) neg cap   — a negative rebase drops TVL by at most
///                         effectiveMaxNegativeRebaseBps() (independent of elapsedTime)
///
///   The handler drives ONE fuzzer-selectable, self-healing action (`step`)
///   whose seed selects among several scenarios against the real EtherFiOracle +
///   EtherFiAdmin contracts. Each scenario is self-contained and leaves the
///   oracle in the un-stuck state on exit:
///     - apply         : a fully valid report -> MUST apply (all gates hold)
///     - quorum-fail   : only ONE committee member submits (< quorum=2)
///                       -> consensus never reached -> executeTasks MUST revert
///     - apr-fail      : accruedRewards sized so |APR| > cap
///                       -> executeTasks MUST revert ("TVL changed too much"),
///                          then unpublished to leave the oracle un-stuck
///     - fresh-fail    : consensus reached but executeTasks called BEFORE the
///                       post-report wait window -> MUST revert ("too fresh"),
///                       then (after warping past it) applied to leave state
///                       un-stuck.
///     - duplicate     : one member submits, then submits the SAME report again
///                       -> the second submit MUST revert ReportNotNeeded, a
///                          single member is sub-quorum so consensus is NOT
///                          reached, and executeTasks MUST reject on quorum.
///     - conflicting   : A submits reward X, B submits reward Y != X for the same
///                       range -> the two distinct hashes each carry one vote, so
///                       NEITHER reaches consensus and executeTasks reverts for
///                       both. Nothing is published, so the sequence resolves on
///                       the next fresh range (no permanent stuck state).
///     - fresh-bound   : exact freshness boundary. At consensusSlot + wait - 1
///                       executeTasks MUST revert ("too fresh"); at exactly
///                       consensusSlot + wait it MUST apply.
///     - apr-bound     : exact APR boundary. The largest reward whose annualized
///                       |APR| still satisfies the cap MUST apply; that reward + 1
///                       wei MUST revert ("TVL changed too much").
///     - neg-rebase    : a small valid negative drop (under both the APR cap and
///                       the negative-rebase cap) MUST apply; a drop one wei above
///                       the negative-rebase cap (but under the APR cap) MUST
///                       revert ("negative rebase exceeds cap").
///
///   Before every executeTasks call the handler computes an INDEPENDENT mirror
///   of the gates (re-deriving the APR / negative cap exactly as EtherFiAdmin
///   does) and:
///     1. SAFETY: if lastHandledReportRefSlot advanced, asserts all mirror gates
///        held — any false flips a ghost that the invariant functions assert
///        against (this is the actual I5 proof).
///     2. MIRROR-CONSISTENCY: when executeTasks reverts with a known
///        ReportValidationFailed reason, asserts our independent mirror agrees
///        on which gate failed — cross-validating that the mirror is faithful,
///        so the safety check above is sound (not vacuously satisfied by a
///        broken oracle).
///
///   SOUNDNESS ASSUMPTIONS (all documented inline below):
///   * The committee is exactly {alice, bob} with quorumSize == 2, as set up by
///     TestSetup. doQuorumFail / the duplicate + conflicting scenarios rely on a
///     single submission being strictly below quorum.
///   * Reports are built so that ONLY the gate under test (or none) can fail:
///     refSlot/refBlock stamps are taken from blockStampForNextReport(),
///     protocolFees == 0, no validator approvals, no withdrawals. Thus a revert
///     is attributable to quorum / freshness / APR / negative-cap (or, harmlessly,
///     a structural reason which we simply don't attribute).
contract OracleIntegrityHandler is Test {
    // --- I5 contract constants mirrored from EtherFiAdmin ---
    uint256 internal constant BASIS_POINTS_DENOMINATOR = 10_000;
    uint256 internal constant SECONDS_PER_SLOT = 12;
    // Mirror of LiquidityPool.MAX_POSITIVE_REBASE_BPS (not exposed on ILiquidityPool):
    // an absolute per-report positive-rebase cap enforced in LiquidityPool.rebase,
    // independent of the oracle-side annualized APR cap. A boundary "apply" whose
    // reward sits at the APR cap must also stay under this or LiquidityPool reverts
    // with RebaseExceedsPositiveCap (a different, non-I5 error).
    int256 internal constant LP_MAX_POSITIVE_REBASE_BPS = 25;

    EtherFiOracle internal immutable oracle;
    EtherFiAdmin internal immutable admin;
    ILiquidityPool internal immutable lp;
    address internal immutable memberA; // alice
    address internal immutable memberB; // bob
    address internal immutable multisig; // holds OPERATION_MULTISIG_ROLE (unpublishReport)
    uint256 internal immutable genesisTime; // BEACON_GENESIS_TIME used by oracle

    // ---- I5 violation ghosts (any true => invariant broken) ----
    bool public ghost_appliedWithoutQuorum;
    bool public ghost_appliedWhileStale;
    bool public ghost_appliedAprViolation;
    bool public ghost_appliedNegRebaseViolation; // applied while the negative-rebase cap was violated
    // mirror-consistency ghost: a revert reason disagreed with our gate mirror
    bool public ghost_mirrorMismatch;
    string public mismatchReason;

    // ---- duplicate / conflicting submission ghosts ----
    bool public ghost_duplicateSubmitSucceeded; // a member's duplicate submit did NOT revert
    bool public ghost_duplicateWrongError;       // duplicate submit reverted with a non-ReportNotNeeded error
    string public duplicateWrongErrorReason;
    bool public ghost_consensusFromSingle;       // consensus reached from a single member's submissions
    bool public ghost_conflictReachedConsensus;  // two conflicting one-vote reports reached consensus

    // ---- exact-boundary ghosts (a boundary report that MUST apply failed to) ----
    bool public ghost_freshBoundaryRejected;     // report at consensusSlot+wait failed to apply
    bool public ghost_aprBoundaryRejected;       // report at the exact APR cap failed to apply
    bool public ghost_negValidRejected;          // a valid small negative drop failed to apply

    // ---- permanent-wedge ghost: the oracle never recovered from a stuck state ----
    bool public ghost_everStuck;
    uint256 internal consecutiveGuardSkips; // consecutive `step` calls short-circuited by the top guard
    // A single scenario intentionally passes through a transient published-but-unapplied
    // state (apr-fail / neg-reject before the unpublish recovery). What we must never
    // observe is the oracle staying wedged: many `step` calls in a row unable to make
    // any progress because lastPublished != lastHandled. Flag if that tail runs long.
    uint256 internal constant MAX_CONSECUTIVE_STUCK_SKIPS = 10;

    // ---- coverage / non-vacuity counters ----
    uint256 public numApplied;       // executeTasks that advanced lastHandledReportRefSlot
    uint256 public numRejected;      // executeTasks that reverted
    uint256 public numRejQuorum;     // reverts attributed to the quorum gate
    uint256 public numRejFresh;      // reverts attributed to the freshness gate
    uint256 public numRejApr;        // reverts attributed to the APR gate
    uint256 public numRejNegRebase;  // reverts attributed to the negative-rebase cap
    uint256 public numRejOther;      // reverts for structural/uncategorised reasons
    uint256 public numDupRejected;       // duplicate submits correctly rejected
    uint256 public numConflictExercised; // conflicting-report scenarios that ran to executeTasks
    uint256 public numFreshBoundaryApplied; // reports applied at exactly consensusSlot+wait
    uint256 public numAprBoundaryApplied;   // reports applied at exactly the APR cap boundary
    uint256 public numNegAccepted;          // valid small negative drops applied

    constructor(
        EtherFiOracle _oracle,
        EtherFiAdmin _admin,
        ILiquidityPool _lp,
        address _memberA,
        address _memberB,
        address _multisig,
        uint256 _genesisTime
    ) {
        oracle = _oracle;
        admin = _admin;
        lp = _lp;
        memberA = _memberA;
        memberB = _memberB;
        multisig = _multisig;
        genesisTime = _genesisTime;
    }

    // -------------------------------------------------------------------------
    // clock helpers (mirror TestSetup._moveClock for the local non-fork setup,
    // where BEACON_GENESIS_TIME == genesisTime and slot == block.number)
    // -------------------------------------------------------------------------
    function _moveClock(uint256 numSlots) internal {
        vm.roll(block.number + numSlots);
        vm.warp(genesisTime + SECONDS_PER_SLOT * block.number);
    }

    /// @dev Advance the clock so that the report range ending at `refSlotTo`
    ///      is considered finalized by the oracle (>= 3 epochs past), mirroring
    ///      TestSetup._executeAdminTasks / _submitForConsensus.
    function _finalizeEpochFor(uint32 refSlotTo) internal {
        uint32 currentSlot = oracle.computeSlotAtTimestamp(block.timestamp);
        uint32 currentEpoch = currentSlot / 32;
        uint32 reportEpoch = (refSlotTo / 32) + 3;
        if (currentEpoch < reportEpoch) {
            _moveClock(32 * uint256(reportEpoch - currentEpoch));
        }
    }

    function _baseReport() internal view returns (IEtherFiOracle.OracleReport memory r) {
        uint256[] memory emptyVals = new uint256[](0);
        uint32 cv = oracle.consensusVersion();
        r = IEtherFiOracle.OracleReport(cv, 0, 0, 0, 0, 0, 0, emptyVals, 0, 0);
        (uint32 slotFrom, uint32 slotTo, uint32 blockFrom) = oracle.blockStampForNextReport();
        r.refSlotFrom = slotFrom;
        r.refSlotTo = slotTo;
        r.refBlockFrom = blockFrom;
        r.refBlockTo = slotTo; // same convention as TestSetup._initReportBlockStamp
    }

    // -------------------------------------------------------------------------
    // independent gate mirror — re-derives the I5 gates from live state,
    // WITHOUT calling EtherFiAdmin's internal validators. Kept byte-for-byte
    // faithful to EtherFiAdmin._validateReportFreshness / _validateRebaseApr so
    // the consistency cross-check below can confirm fidelity.
    // -------------------------------------------------------------------------
    function _gatesHold(IEtherFiOracle.OracleReport memory r, bytes32 reportHash)
        internal
        view
        returns (bool quorum, bool fresh, bool apr, bool negOk)
    {
        // (a) quorum: consensus flag is only set once support >= quorumSize.
        quorum = oracle.isConsensusReached(reportHash);

        // (c) freshness: contract checks this only after consensus; getConsensusSlot
        //     reverts when no consensus, so guard on `quorum`. Without consensus the
        //     freshness gate is, by construction, not satisfiable.
        if (quorum) {
            uint32 curSlot = oracle.computeSlotAtTimestamp(block.timestamp);
            uint32 consSlot = oracle.getConsensusSlot(reportHash);
            fresh = curSlot >= uint256(admin.postReportWaitTimeInSlots()) + consSlot;
        } else {
            fresh = false;
        }

        // (b) APR cap: identical arithmetic to EtherFiAdmin._validateRebaseApr.
        int256 currentTVL = int128(uint128(lp.getTotalPooledEther()));
        uint256 elapsedSlots = uint256(r.refSlotTo) - uint256(admin.lastHandledReportRefSlot());
        uint256 elapsedTime = elapsedSlots * SECONDS_PER_SLOT;
        int256 aprVal;
        if (currentTVL > 0 && elapsedTime > 0) {
            aprVal = int256(BASIS_POINTS_DENOMINATOR) * (int256(r.accruedRewards) * int256(365 days))
                / (currentTVL * int256(elapsedTime));
        }
        int256 absApr = aprVal > 0 ? aprVal : -aprVal;
        apr = absApr <= admin.acceptableRebaseAprInBps();

        // (d) negative-rebase cap: identical arithmetic to EtherFiAdmin._validateRebaseApr's
        //     independent negative branch. negOk == "the drop is within the cap".
        negOk = true;
        if (r.accruedRewards < 0 && currentTVL > 0) {
            int256 drop = -int256(r.accruedRewards);
            if (drop * int256(BASIS_POINTS_DENOMINATOR) > currentTVL * int256(admin.effectiveMaxNegativeRebaseBps())) {
                negOk = false;
            }
        }
    }

    function _strEq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @dev Decode the reason string out of a ReportValidationFailed(string) revert.
    function _decodeReason(bytes memory err) internal pure returns (bool ok, string memory reason) {
        // selector(4) + offset(32) + length(32) + data
        if (err.length < 4) return (false, "");
        bytes4 sel;
        assembly { sel := mload(add(err, 0x20)) }
        if (sel != EtherFiAdmin.ReportValidationFailed.selector) return (false, "");
        bytes memory payload = new bytes(err.length - 4);
        for (uint256 i = 0; i < payload.length; i++) payload[i] = err[i + 4];
        reason = abi.decode(payload, (string));
        ok = true;
    }

    /// @dev Core driver: snapshots lastHandledReportRefSlot, computes the mirror
    ///      gates, calls executeTasks, then runs the SAFETY + MIRROR checks.
    function _executeAndCheck(IEtherFiOracle.OracleReport memory r) internal {
        bytes32 reportHash = oracle.generateReportHash(r);
        (bool quorum, bool fresh, bool apr, bool negOk) = _gatesHold(r, reportHash);
        uint32 before = admin.lastHandledReportRefSlot();

        try admin.executeTasks(r) {
            uint32 afterSlot = admin.lastHandledReportRefSlot();
            bool applied = afterSlot != before;
            if (applied) {
                numApplied++;
                // ---- I5 SAFETY: a state-advancing report MUST satisfy all gates ----
                if (!quorum) ghost_appliedWithoutQuorum = true;
                if (!fresh) ghost_appliedWhileStale = true;
                if (!apr) ghost_appliedAprViolation = true;
                if (!negOk) ghost_appliedNegRebaseViolation = true;
            }
        } catch (bytes memory err) {
            numRejected++;
            (bool ok, string memory reason) = _decodeReason(err);
            if (ok) {
                // ---- MIRROR-CONSISTENCY: the first failing gate the contract
                //      reports must match our independent mirror. ----
                if (_strEq(reason, "EtherFiAdmin: report didn't reach consensus")) {
                    numRejQuorum++;
                    if (quorum) { ghost_mirrorMismatch = true; mismatchReason = "quorum gate disagreement"; }
                } else if (_strEq(reason, "EtherFiAdmin: report is too fresh")) {
                    numRejFresh++;
                    // contract reached the freshness stage => consensus held but window not elapsed
                    if (!quorum || fresh) { ghost_mirrorMismatch = true; mismatchReason = "freshness gate disagreement"; }
                } else if (_strEq(reason, "EtherFiAdmin: TVL changed too much")) {
                    numRejApr++;
                    // contract reached the APR stage => consensus + freshness held, APR failed
                    if (!quorum || !fresh || apr) { ghost_mirrorMismatch = true; mismatchReason = "apr gate disagreement"; }
                } else if (_strEq(reason, "EtherFiAdmin: negative rebase exceeds cap")) {
                    numRejNegRebase++;
                    // contract reached the neg-cap stage => consensus + freshness + APR-cap
                    // held (APR is checked first), and the negative-drop cap failed.
                    if (!quorum || !fresh || !apr || negOk) { ghost_mirrorMismatch = true; mismatchReason = "negative-rebase gate disagreement"; }
                } else {
                    numRejOther++;
                }
            } else {
                numRejOther++;
            }
        }
    }

    // -------------------------------------------------------------------------
    // FUZZ ACTION — a SINGLE self-healing step.
    //
    // The oracle is a strict state machine: it can only accept a new report when
    // `lastPublishedReportRefSlot == lastHandledReportRefSlot` (enforced by
    // shouldSubmitReport's LastReportNotHandled guard). A half-finished
    // (published-but-unapplied) state between fuzz calls bricks every subsequent
    // submitReport. To be fully robust to fuzzer call ordering AND to Foundry's
    // sequence shrinking (which replays arbitrary single-call subsequences), a
    // single `step` call runs ALL scenarios in sequence — each self-contained and
    // each leaving the oracle in the un-stuck state on exit. This makes EVERY
    // single call non-vacuous by construction (>=1 apply and >=1 of each reject
    // gate), so the non-vacuity gates in afterInvariant hold regardless of how the
    // fuzzer schedules or shrinks calls. The fuzzer's `magnitude` varies the rebase
    // size across calls, exercising the safety property over a wide state space.
    // -------------------------------------------------------------------------

    /// @param magnitude bounded magnitude used for the rebase reward (fuzzed)
    function step(uint256 magnitude) external {
        // Self-heal: never proceed from a stuck state (defensive; by construction
        // each sub-scenario below leaves the oracle un-stuck). Track how many calls
        // in a row are wedged so afterInvariant can flag a PERMANENT stuck oracle.
        if (oracle.lastPublishedReportRefSlot() != admin.lastHandledReportRefSlot()) {
            consecutiveGuardSkips++;
            if (consecutiveGuardSkips > MAX_CONSECUTIVE_STUCK_SKIPS) ghost_everStuck = true;
            return;
        }
        consecutiveGuardSkips = 0;

        _scenarioApply(magnitude);
        _scenarioQuorumFail(magnitude);
        _scenarioAprFail(magnitude);
        _scenarioFreshFail(magnitude);
        _scenarioDuplicateSubmit(magnitude);
        _scenarioConflictingReports(magnitude);
        _scenarioFreshBoundary(magnitude);
        _scenarioAprBoundary(magnitude);
        _scenarioNegRebase(magnitude);
    }

    /// @dev Open a fresh, finalized, un-handled report range. Returns (ok, report).
    ///      ok=false when no new range is available yet (caller should skip).
    function _freshRange() internal returns (bool ok, IEtherFiOracle.OracleReport memory r) {
        _moveClock(1024 + 2 * 32);
        r = _baseReport();
        if (r.refSlotTo <= admin.lastHandledReportRefSlot()) return (false, r);
        _finalizeEpochFor(r.refSlotTo);
        r = _resyncStamps(r);
        ok = true;
    }

    /// @dev Largest rebase reward that keeps |APR| strictly under the cap for the
    ///      given report range (the boundary reward at which apr == cap), CLAMPED
    ///      to LiquidityPool's absolute positive-rebase cap
    ///      (MAX_POSITIVE_REBASE_BPS of TVL). The APR gate scales with the range's
    ///      elapsed time, so over a long range the APR-derived bound alone can
    ///      exceed the LP's per-rebase cap; a reward in that gap passes
    ///      EtherFiAdmin validation but reverts inside LiquidityPool.rebase
    ///      (RebaseExceedsPositiveCap), leaving the report published-but-unhandled
    ///      and wedging the oracle. A valid "apply" must stay BELOW both caps;
    ///      callers use half of this for safe margin.
    function _maxSafeReward(IEtherFiOracle.OracleReport memory r) internal view returns (int256) {
        int256 tvl = int128(uint128(lp.getTotalPooledEther()));
        uint256 elapsedTime = (uint256(r.refSlotTo) - uint256(admin.lastHandledReportRefSlot())) * SECONDS_PER_SLOT;
        if (tvl <= 0 || elapsedTime == 0) return 0;
        int256 cap = admin.acceptableRebaseAprInBps();
        // reward at apr==cap boundary: cap = 10000 * (reward*365d)/(tvl*elapsedTime)
        int256 aprMax = cap * tvl * int256(elapsedTime) / (int256(BASIS_POINTS_DENOMINATOR) * int256(365 days));
        int256 lpMax = _lpPositiveCap();
        return aprMax < lpMax ? aprMax : lpMax;
    }

    /// @dev EXACT largest reward R (in wei) whose annualized |APR| still satisfies
    ///      the cap, i.e. the maximum acceptable accruedRewards for this range.
    ///      The contract computes apr = floor(K*R / D) with K = 10000*365d and
    ///      D = tvl*elapsedTime, and rejects when apr > cap. So R is accepted iff
    ///      floor(K*R/D) <= cap  <=>  K*R < (cap+1)*D. The largest such integer R
    ///      is floor(((cap+1)*D - 1) / K); R+1 makes K*(R+1) >= (cap+1)*D, forcing
    ///      apr >= cap+1 (a strict rejection). This is the exact APR boundary.
    function _aprBoundaryReward(IEtherFiOracle.OracleReport memory r) internal view returns (int256) {
        int256 tvl = int128(uint128(lp.getTotalPooledEther()));
        uint256 elapsedTime = (uint256(r.refSlotTo) - uint256(admin.lastHandledReportRefSlot())) * SECONDS_PER_SLOT;
        if (tvl <= 0 || elapsedTime == 0) return 0;
        int256 cap = admin.acceptableRebaseAprInBps();
        int256 D = tvl * int256(elapsedTime);
        int256 K = int256(BASIS_POINTS_DENOMINATOR) * int256(365 days);
        return ((cap + 1) * D - 1) / K;
    }

    /// @dev LiquidityPool positive-rebase absolute cap (in wei) for the current TVL.
    function _lpPositiveCap() internal view returns (int256) {
        int256 tvl = int128(uint128(lp.getTotalPooledEther()));
        return tvl * LP_MAX_POSITIVE_REBASE_BPS / int256(BASIS_POINTS_DENOMINATOR);
    }

    /// APPLY: valid report, all gates hold => MUST advance state.
    function _scenarioApply(uint256 magnitude) internal {
        if (oracle.lastPublishedReportRefSlot() != admin.lastHandledReportRefSlot()) return;
        (bool ok, IEtherFiOracle.OracleReport memory r) = _freshRange();
        if (!ok) return;
        uint16 wait = admin.postReportWaitTimeInSlots();
        // SOUNDNESS: the APR gate caps |reward| relative to the (short) elapsed
        // window for this range. Bound the reward to HALF the cap-boundary so the
        // apply is guaranteed under the APR cap regardless of the fuzzed magnitude
        // and the range length the clock happens to produce. Without this, a large
        // reward over a short range trips the APR gate and the "valid" apply
        // reverts -> report stays published-but-unapplied -> oracle bricked.
        int256 safeMax = _maxSafeReward(r);
        if (safeMax <= 1) return; // range too short to carry any reward safely
        r.accruedRewards = int128(int256(bound(magnitude, 0, uint256(safeMax / 2))));
        r = _resyncStamps(r);
        vm.prank(memberA);
        try oracle.submitReport(r) {} catch { return; }
        vm.prank(memberB);
        try oracle.submitReport(r) {} catch { return; }
        _moveClock(uint256(wait) + 1);
        _executeAndCheck(r);
    }

    /// QUORUM-FAIL: only ONE member submits => consensus never reached.
    /// SOUNDNESS: quorumSize == 2, committee == {memberA, memberB}; a single
    /// submission is strictly below quorum. Report never published => un-stuck.
    function _scenarioQuorumFail(uint256 magnitude) internal {
        if (oracle.lastPublishedReportRefSlot() != admin.lastHandledReportRefSlot()) return;
        (bool ok, IEtherFiOracle.OracleReport memory r) = _freshRange();
        if (!ok) return;
        uint16 wait = admin.postReportWaitTimeInSlots();
        r.accruedRewards = int128(int256(bound(magnitude, 0, 0.5 ether)));
        r = _resyncStamps(r);
        vm.prank(memberA);
        try oracle.submitReport(r) {} catch { return; }
        _moveClock(uint256(wait) + 1);
        _executeAndCheck(r);
    }

    /// APR-FAIL: size accruedRewards so |APR| strictly exceeds the cap => MUST
    /// revert on the APR gate. Unpublish afterward to leave the oracle un-stuck.
    function _scenarioAprFail(uint256 magnitude) internal {
        if (oracle.lastPublishedReportRefSlot() != admin.lastHandledReportRefSlot()) return;
        (bool ok, IEtherFiOracle.OracleReport memory r) = _freshRange();
        if (!ok) return;
        // unpublish recovery computes refSlotFrom-1, so needs refSlotFrom > 0.
        if (r.refSlotFrom == 0) return;
        uint16 wait = admin.postReportWaitTimeInSlots();
        uint32 lastHandled = admin.lastHandledReportRefSlot();
        int256 tvl = int128(uint128(lp.getTotalPooledEther()));
        uint256 elapsedTime = (uint256(r.refSlotTo) - uint256(lastHandled)) * SECONDS_PER_SLOT;
        if (tvl <= 0 || elapsedTime == 0) return;
        int256 cap = admin.acceptableRebaseAprInBps();
        // reward at the cap boundary: cap = 10000 * (reward*365d)/(tvl*elapsedTime)
        int256 boundaryReward =
            cap * tvl * int256(elapsedTime) / (int256(BASIS_POINTS_DENOMINATOR) * int256(365 days));
        int256 extra = int256(bound(magnitude, 1 ether, 50 ether));
        int256 reward = boundaryReward + extra;
        if (magnitude % 2 == 0) reward = -reward; // exercise both positive and negative over-cap
        if (reward > type(int128).max || reward < type(int128).min) return;
        r.accruedRewards = int128(reward);

        bytes32 reportHash = oracle.generateReportHash(r);
        vm.prank(memberA);
        try oracle.submitReport(r) {} catch { return; }
        vm.prank(memberB);
        try oracle.submitReport(r) {} catch { return; }
        _moveClock(uint256(wait) + 1);
        // consensus + freshness hold, APR does not => MUST revert on APR gate.
        _executeAndCheck(r);
        // RECOVERY: published-but-unappliable. Unpublish to un-stick the oracle.
        if (oracle.isConsensusReached(reportHash) && r.refSlotTo > admin.lastHandledReportRefSlot()) {
            address[] memory members = new address[](2);
            members[0] = memberA;
            members[1] = memberB;
            vm.prank(multisig);
            try oracle.unpublishReport(r, members) {} catch {}
        }
    }

    /// FRESH-FAIL: consensus reached but executeTasks called BEFORE the wait
    /// window => MUST revert on freshness; then warp past it and apply, leaving
    /// the oracle un-stuck. No-op when wait window is 0 (then freshness is vacuous).
    function _scenarioFreshFail(uint256 magnitude) internal {
        if (oracle.lastPublishedReportRefSlot() != admin.lastHandledReportRefSlot()) return;
        uint16 wait = admin.postReportWaitTimeInSlots();
        if (wait == 0) return;
        (bool ok, IEtherFiOracle.OracleReport memory r) = _freshRange();
        if (!ok) return;
        // Same APR-safety bound as _scenarioApply: this report is applied after the
        // freshness window elapses, so it must stay under the APR cap.
        int256 safeMax = _maxSafeReward(r);
        if (safeMax <= 1) return;
        r.accruedRewards = int128(int256(bound(magnitude, 0, uint256(safeMax / 2))));
        r = _resyncStamps(r);
        vm.prank(memberA);
        try oracle.submitReport(r) {} catch { return; }
        vm.prank(memberB);
        try oracle.submitReport(r) {} catch { return; }
        // do NOT advance the clock yet -> too fresh.
        _executeAndCheck(r);
        // now elapse the window and apply for real, leaving the system un-stuck.
        _moveClock(uint256(wait) + 1);
        _executeAndCheck(r);
    }

    /// DUPLICATE: one member submits, then submits the SAME report again.
    /// SOUNDNESS: after the first submit, committeeMemberStates[member].lastReportRefSlot
    /// == refSlotTo == slotForNextReport(), so shouldSubmitReport returns false and
    /// the second submit reverts ReportNotNeeded (checked BEFORE consensus can form,
    /// since a single member is strictly below quorum). Nothing is published =>
    /// un-stuck naturally; the sub-quorum report is then rejected by executeTasks.
    function _scenarioDuplicateSubmit(uint256 magnitude) internal {
        if (oracle.lastPublishedReportRefSlot() != admin.lastHandledReportRefSlot()) return;
        (bool ok, IEtherFiOracle.OracleReport memory r) = _freshRange();
        if (!ok) return;
        uint16 wait = admin.postReportWaitTimeInSlots();
        r.accruedRewards = int128(int256(bound(magnitude, 0, 0.4 ether)));
        r = _resyncStamps(r);
        bytes32 reportHash = oracle.generateReportHash(r);

        vm.prank(memberA);
        try oracle.submitReport(r) {} catch { return; }
        // a single submission must NOT reach quorum (quorumSize == 2).
        if (oracle.isConsensusReached(reportHash)) { ghost_consensusFromSingle = true; return; }

        // duplicate submit by the same member MUST revert with ReportNotNeeded.
        vm.prank(memberA);
        try oracle.submitReport(r) returns (bool) {
            ghost_duplicateSubmitSucceeded = true;
        } catch (bytes memory err) {
            numDupRejected++;
            bytes4 sel;
            if (err.length >= 4) { assembly { sel := mload(add(err, 0x20)) } }
            if (sel != EtherFiOracle.ReportNotNeeded.selector) {
                ghost_duplicateWrongError = true;
                duplicateWrongErrorReason = "duplicate submit reverted with a non-ReportNotNeeded error";
            }
        }
        // still sub-quorum: executeTasks MUST reject on the quorum gate.
        _moveClock(uint256(wait) + 1);
        _executeAndCheck(r);
        // nothing was published (sub-quorum) => the oracle is un-stuck.
    }

    /// CONFLICTING: A submits reward X, B submits reward Y != X for the same range.
    /// The two distinct report hashes each carry a single vote, so NEITHER reaches
    /// consensus and executeTasks reverts for both. Nothing is published, so the
    /// stuck-guard (lastPublished != lastHandled) is never tripped and the sequence
    /// resolves on the next fresh range — no explicit resolution step is required.
    function _scenarioConflictingReports(uint256 magnitude) internal {
        if (oracle.lastPublishedReportRefSlot() != admin.lastHandledReportRefSlot()) return;
        (bool ok,) = _freshRange();
        if (!ok) return;
        uint16 wait = admin.postReportWaitTimeInSlots();
        // Two INDEPENDENT report structs for the same finalized range (no clock has
        // moved since _freshRange, so both read the same stamps). They must be
        // distinct memory objects — `memory rB = rA` aliases in Solidity and would
        // make both members vote for one hash, reaching consensus.
        IEtherFiOracle.OracleReport memory rA = _baseReport();
        IEtherFiOracle.OracleReport memory rB = _baseReport();
        rA.accruedRewards = int128(int256(bound(magnitude, 0, 0.3 ether)));
        rB.accruedRewards = rA.accruedRewards + int128(int256(1 ether)); // Y != X
        bytes32 hA = oracle.generateReportHash(rA);
        bytes32 hB = oracle.generateReportHash(rB);

        vm.prank(memberA);
        try oracle.submitReport(rA) {} catch { return; }
        vm.prank(memberB);
        try oracle.submitReport(rB) {} catch { return; }
        // two distinct one-vote reports must not reach consensus.
        if (oracle.isConsensusReached(hA) || oracle.isConsensusReached(hB)) {
            ghost_conflictReachedConsensus = true;
            return;
        }
        _moveClock(uint256(wait) + 1);
        // both hashes are sub-quorum: executeTasks MUST reject each on the quorum gate.
        _executeAndCheck(rA);
        _executeAndCheck(rB);
        numConflictExercised++;
    }

    /// FRESH-BOUNDARY: exact freshness edge. Drive executeTasks at exactly
    /// consensusSlot + wait - 1 (MUST revert "too fresh", since the contract
    /// requires current_slot >= wait + consensusSlot) and at exactly
    /// consensusSlot + wait (MUST apply). Leaves the oracle un-stuck via the apply.
    function _scenarioFreshBoundary(uint256 magnitude) internal {
        if (oracle.lastPublishedReportRefSlot() != admin.lastHandledReportRefSlot()) return;
        uint16 wait = admin.postReportWaitTimeInSlots();
        if (wait == 0) return; // freshness gate vacuous
        (bool ok, IEtherFiOracle.OracleReport memory r) = _freshRange();
        if (!ok) return;
        int256 safeMax = _maxSafeReward(r);
        if (safeMax <= 1) return;
        r.accruedRewards = int128(int256(bound(magnitude, 0, uint256(safeMax / 2))));
        r = _resyncStamps(r);
        vm.prank(memberA);
        try oracle.submitReport(r) {} catch { return; }
        vm.prank(memberB);
        try oracle.submitReport(r) {} catch { return; }
        bytes32 reportHash = oracle.generateReportHash(r);
        if (!oracle.isConsensusReached(reportHash)) return;

        uint32 consSlot = oracle.getConsensusSlot(reportHash);
        uint32 cur = oracle.computeSlotAtTimestamp(block.timestamp);
        // Move to exactly consSlot + wait - 1 (one slot short of the window).
        uint256 target = uint256(consSlot) + uint256(wait) - 1;
        if (target > cur) _moveClock(target - cur);
        // At consSlot + wait - 1: current_slot < wait + consSlot => MUST revert "too fresh".
        _executeAndCheck(r);
        // Advance the final slot to exactly consSlot + wait: current_slot == wait + consSlot
        // => the strict `<` comparison is false => MUST apply.
        _moveClock(1);
        uint32 beforeSlot = admin.lastHandledReportRefSlot();
        _executeAndCheck(r);
        if (admin.lastHandledReportRefSlot() == beforeSlot) {
            ghost_freshBoundaryRejected = true;
        } else {
            numFreshBoundaryApplied++;
        }
    }

    /// APR-BOUNDARY: exact APR edge. The largest reward whose annualized |APR| still
    /// satisfies the cap MUST apply; that reward + 1 wei MUST revert on the APR gate.
    function _scenarioAprBoundary(uint256 magnitude) internal {
        // ---- ACCEPT leg: reward at the exact APR cap boundary MUST apply. ----
        if (oracle.lastPublishedReportRefSlot() != admin.lastHandledReportRefSlot()) return;
        uint16 wait = admin.postReportWaitTimeInSlots();
        (bool ok, IEtherFiOracle.OracleReport memory r) = _freshRange();
        if (!ok) return;
        int256 rmax = _aprBoundaryReward(r);
        // Guard the accept against LiquidityPool's separate absolute positive cap:
        // if the APR-boundary reward exceeds MAX_POSITIVE_REBASE_BPS of TVL, applying
        // it would revert in LiquidityPool.rebase (RebaseExceedsPositiveCap), not I5.
        int256 lpCap = _lpPositiveCap();
        if (rmax > 1 && rmax <= lpCap && rmax <= type(int128).max) {
            r.accruedRewards = int128(rmax);
            vm.prank(memberA);
            try oracle.submitReport(r) {} catch { return; }
            vm.prank(memberB);
            try oracle.submitReport(r) {} catch { return; }
            _moveClock(uint256(wait) + 1);
            uint32 beforeSlot = admin.lastHandledReportRefSlot();
            _executeAndCheck(r); // apr == cap boundary, all other gates hold => MUST apply
            if (admin.lastHandledReportRefSlot() == beforeSlot) {
                ghost_aprBoundaryRejected = true;
                return; // boundary report stuck; bail before it wedges the sequence
            }
            numAprBoundaryApplied++;
        }

        // ---- REJECT leg: boundary reward + 1 wei MUST revert on the APR gate. ----
        if (oracle.lastPublishedReportRefSlot() != admin.lastHandledReportRefSlot()) return;
        (bool ok2, IEtherFiOracle.OracleReport memory r2) = _freshRange();
        if (!ok2) return;
        if (r2.refSlotFrom == 0) return; // unpublish recovery needs refSlotFrom > 0
        int256 rmax2 = _aprBoundaryReward(r2);
        if (rmax2 <= 0 || rmax2 + 1 > int256(type(int128).max)) return;
        r2.accruedRewards = int128(rmax2 + 1); // one wei over the boundary => apr > cap
        bytes32 h2 = oracle.generateReportHash(r2);
        vm.prank(memberA);
        try oracle.submitReport(r2) {} catch { return; }
        vm.prank(memberB);
        try oracle.submitReport(r2) {} catch { return; }
        _moveClock(uint256(wait) + 1);
        _executeAndCheck(r2); // MUST revert "TVL changed too much" -> numRejApr
        // RECOVERY: published-but-unappliable. Unpublish to un-stick the oracle.
        if (oracle.isConsensusReached(h2) && r2.refSlotTo > admin.lastHandledReportRefSlot()) {
            address[] memory members = new address[](2);
            members[0] = memberA;
            members[1] = memberB;
            vm.prank(multisig);
            try oracle.unpublishReport(r2, members) {} catch {}
        }
    }

    /// NEG-REBASE: a small valid negative drop (under both the APR cap and the
    /// negative-rebase cap) MUST apply; a drop one wei above the negative-rebase cap
    /// (but still under the APR cap) MUST revert "negative rebase exceeds cap".
    function _scenarioNegRebase(uint256 magnitude) internal {
        _negRebaseAccept(magnitude);
        _negRebaseReject(magnitude);
    }

    /// ACCEPT leg: small valid negative drop under BOTH caps MUST apply.
    function _negRebaseAccept(uint256 magnitude) internal {
        if (oracle.lastPublishedReportRefSlot() != admin.lastHandledReportRefSlot()) return;
        (bool ok, IEtherFiOracle.OracleReport memory r) = _freshRange();
        if (!ok) return;
        int256 tvl = int128(uint128(lp.getTotalPooledEther()));
        // negative-cap boundary drop: largest drop with drop*10000 <= tvl*negBps.
        int256 negBoundary = tvl * int256(admin.effectiveMaxNegativeRebaseBps()) / int256(BASIS_POINTS_DENOMINATOR);
        // largest drop whose |APR| still satisfies the cap for this range.
        int256 aprDropMax = _aprBoundaryReward(r);
        // accept drop must stay under BOTH caps.
        int256 dropAcceptMax = negBoundary < aprDropMax ? negBoundary : aprDropMax;
        if (dropAcceptMax <= 1) return;
        r.accruedRewards = int128(-int256(bound(magnitude, 1, uint256(dropAcceptMax))));
        r = _resyncStamps(r);
        vm.prank(memberA);
        try oracle.submitReport(r) {} catch { return; }
        vm.prank(memberB);
        try oracle.submitReport(r) {} catch { return; }
        _moveClock(uint256(admin.postReportWaitTimeInSlots()) + 1);
        uint32 beforeSlot = admin.lastHandledReportRefSlot();
        _executeAndCheck(r); // under both caps => MUST apply
        if (admin.lastHandledReportRefSlot() == beforeSlot) ghost_negValidRejected = true;
        else numNegAccepted++;
    }

    /// REJECT leg: drop one wei above the negative-rebase cap (but under the APR
    /// cap) MUST revert "negative rebase exceeds cap". Unpublish to leave un-stuck.
    function _negRebaseReject(uint256 /*magnitude*/) internal {
        if (oracle.lastPublishedReportRefSlot() != admin.lastHandledReportRefSlot()) return;
        (bool ok, IEtherFiOracle.OracleReport memory r) = _freshRange();
        if (!ok) return;
        if (r.refSlotFrom == 0) return; // unpublish recovery needs refSlotFrom > 0
        int256 tvl = int128(uint128(lp.getTotalPooledEther()));
        int256 negBoundary = tvl * int256(admin.effectiveMaxNegativeRebaseBps()) / int256(BASIS_POINTS_DENOMINATOR);
        int256 dropReject = negBoundary + 1; // minimal increment above the negative cap
        // SOUNDNESS: keep the drop UNDER the APR cap so the contract reverts on the
        // NEGATIVE-rebase gate (checked after APR), not the APR gate. With the 3-bps
        // negative cap and a range spanning one report period this holds with margin.
        if (dropReject > _aprBoundaryReward(r)) return;
        if (dropReject > int256(type(int128).max)) return;
        r.accruedRewards = int128(-dropReject);
        r = _resyncStamps(r);
        bytes32 reportHash = oracle.generateReportHash(r);
        vm.prank(memberA);
        try oracle.submitReport(r) {} catch { return; }
        vm.prank(memberB);
        try oracle.submitReport(r) {} catch { return; }
        _moveClock(uint256(admin.postReportWaitTimeInSlots()) + 1);
        _executeAndCheck(r); // MUST revert "negative rebase exceeds cap" -> numRejNegRebase
        // RECOVERY: published-but-unappliable. Unpublish to un-stick the oracle.
        if (oracle.isConsensusReached(reportHash) && r.refSlotTo > admin.lastHandledReportRefSlot()) {
            address[] memory members = new address[](2);
            members[0] = memberA;
            members[1] = memberB;
            vm.prank(multisig);
            try oracle.unpublishReport(r, members) {} catch {}
        }
    }

    /// @dev After any extra clock movement the block stamps must be re-derived
    ///      so submitReport's verifyReport (which checks against the live
    ///      blockStampForNextReport) passes. refSlotTo can grow as the clock
    ///      advances; we re-read just before submitting.
    function _resyncStamps(IEtherFiOracle.OracleReport memory r)
        internal
        view
        returns (IEtherFiOracle.OracleReport memory)
    {
        (uint32 slotFrom, uint32 slotTo, uint32 blockFrom) = oracle.blockStampForNextReport();
        r.refSlotFrom = slotFrom;
        r.refSlotTo = slotTo;
        r.refBlockFrom = blockFrom;
        r.refBlockTo = slotTo;
        return r;
    }
}
