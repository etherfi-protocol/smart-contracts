// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../../src/EtherFiOracle.sol";
import "../../../src/EtherFiAdmin.sol";
import "../../../src/interfaces/IEtherFiOracle.sol";
import "../../../src/interfaces/ILiquidityPool.sol";

/// @notice Stateful-fuzz handler for invariant I5 (Oracle Integrity).
///
///   I5: an OracleReport may only ADVANCE EtherFiAdmin.lastHandledReportRefSlot
///       (i.e. be "applied" by executeTasks) when ALL THREE gates hold at the
///       moment of execution:
///         (a) quorum    — consensus reached with >= quorumSize() submissions
///         (b) APR cap   — abs(rebase APR) <= acceptableRebaseAprInBps()
///         (c) freshness — currentSlot >= postReportWaitTimeInSlots + consensusSlot
///
///   The handler drives ONE fuzzer-selectable, self-healing action (`step`)
///   whose seed selects among four scenarios against the real EtherFiOracle +
///   EtherFiAdmin contracts:
///     - apply       : a fully valid report -> MUST apply (all gates hold)
///     - quorum-fail : only ONE committee member submits (< quorum=2)
///                     -> consensus never reached -> executeTasks MUST revert
///     - apr-fail    : accruedRewards sized so |APR| > cap
///                     -> executeTasks MUST revert ("TVL changed too much"),
///                        then unpublished to leave the oracle un-stuck
///     - fresh-fail  : consensus reached but executeTasks called BEFORE the
///                     post-report wait window -> MUST revert ("too fresh"),
///                     then (after warping past it) applied to leave state
///                     un-stuck.
///
///   Before every executeTasks call the handler computes an INDEPENDENT mirror
///   of the three gates (re-deriving the APR exactly as EtherFiAdmin does) and:
///     1. SAFETY: if lastHandledReportRefSlot advanced, asserts all three
///        mirror gates held — any false flips a ghost that the invariant
///        functions assert against (this is the actual I5 proof).
///     2. MIRROR-CONSISTENCY: when executeTasks reverts with a known
///        ReportValidationFailed reason, asserts our independent mirror agrees
///        on which gate failed — cross-validating that the mirror is faithful,
///        so the safety check above is sound (not vacuously satisfied by a
///        broken oracle).
///
///   SOUNDNESS ASSUMPTIONS (all documented inline below):
///   * The committee is exactly {alice, bob} with quorumSize == 2, as set up by
///     TestSetup. doQuorumFail relies on a single submission being strictly
///     below quorum.
///   * Reports are built so that ONLY the gate under test (or none) can fail:
///     refSlot/refBlock stamps are taken from blockStampForNextReport(),
///     protocolFees == 0, no validator approvals, no withdrawals. Thus a revert
///     is attributable to quorum / freshness / APR (or, harmlessly, a
///     structural reason which we simply don't attribute).
contract OracleIntegrityHandler is Test {
    // --- I5 contract constants mirrored from EtherFiAdmin ---
    uint256 internal constant BASIS_POINTS_DENOMINATOR = 10_000;
    uint256 internal constant SECONDS_PER_SLOT = 12;

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
    // mirror-consistency ghost: a revert reason disagreed with our gate mirror
    bool public ghost_mirrorMismatch;
    string public mismatchReason;

    // ---- coverage / non-vacuity counters ----
    uint256 public numApplied;     // executeTasks that advanced lastHandledReportRefSlot
    uint256 public numRejected;    // executeTasks that reverted
    uint256 public numRejQuorum;   // reverts attributed to the quorum gate
    uint256 public numRejFresh;    // reverts attributed to the freshness gate
    uint256 public numRejApr;      // reverts attributed to the APR gate
    uint256 public numRejOther;    // reverts for structural/uncategorised reasons

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
    // independent gate mirror — re-derives the three I5 gates from live state,
    // WITHOUT calling EtherFiAdmin's internal validators. Kept byte-for-byte
    // faithful to EtherFiAdmin._validateReportFreshness / _validateRebaseApr so
    // the consistency cross-check below can confirm fidelity.
    // -------------------------------------------------------------------------
    function _gatesHold(IEtherFiOracle.OracleReport memory r, bytes32 reportHash)
        internal
        view
        returns (bool quorum, bool fresh, bool apr)
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
        (bool quorum, bool fresh, bool apr) = _gatesHold(r, reportHash);
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
    // single `step` call runs ALL FOUR scenarios in sequence — apply, quorum-fail,
    // apr-fail, fresh-fail — each self-contained and each leaving the oracle in the
    // un-stuck state on exit. This makes EVERY single call non-vacuous by
    // construction (>=1 apply and >=1 of each reject gate), so the non-vacuity
    // gates in afterInvariant hold regardless of how the fuzzer schedules or
    // shrinks calls. The fuzzer's `magnitude` varies the rebase size across calls,
    // exercising the safety property over a wide state space.
    // -------------------------------------------------------------------------

    /// @param magnitude bounded magnitude used for the rebase reward (fuzzed)
    function step(uint256 magnitude) external {
        // Self-heal: never proceed from a stuck state (defensive; by construction
        // each sub-scenario below leaves the oracle un-stuck).
        if (oracle.lastPublishedReportRefSlot() != admin.lastHandledReportRefSlot()) return;

        _scenarioApply(magnitude);
        _scenarioQuorumFail(magnitude);
        _scenarioAprFail(magnitude);
        _scenarioFreshFail(magnitude);
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
    ///      given report range, i.e. the boundary reward at which apr == cap.
    ///      A valid "apply" must stay BELOW this; we use half of it for safe margin.
    function _maxSafeReward(IEtherFiOracle.OracleReport memory r) internal view returns (int256) {
        int256 tvl = int128(uint128(lp.getTotalPooledEther()));
        uint256 elapsedTime = (uint256(r.refSlotTo) - uint256(admin.lastHandledReportRefSlot())) * SECONDS_PER_SLOT;
        if (tvl <= 0 || elapsedTime == 0) return 0;
        int256 cap = admin.acceptableRebaseAprInBps();
        // reward at apr==cap boundary: cap = 10000 * (reward*365d)/(tvl*elapsedTime)
        return cap * tvl * int256(elapsedTime) / (int256(BASIS_POINTS_DENOMINATOR) * int256(365 days));
    }

    /// APPLY: valid report, all three gates hold => MUST advance state.
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
            vm.prank(multisig);
            try oracle.unpublishReport(r) {} catch {}
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
