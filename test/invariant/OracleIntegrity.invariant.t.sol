// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../TestSetup.sol";
import "@etherfi/core/interfaces/ILiquidityPool.sol";
import "./handlers/OracleIntegrityHandler.sol";

/// @notice Stateful FUZZ-INVARIANT suite for invariant I5 (Oracle Integrity).
///
///   I5 (protocol-ops/security/architecture/invariants.md): every applied
///   OracleReport — one that advances EtherFiAdmin.lastHandledReportRefSlot via
///   executeTasks — MUST satisfy ALL THREE gates at execution time:
///     (a) quorum    — consensus reached with >= EtherFiOracle.quorumSize() sigs
///     (b) APR cap   — abs(rebase APR) <= EtherFiAdmin.acceptableRebaseAprInBps()
///     (c) freshness — currentSlot >= postReportWaitTimeInSlots + consensusSlot
///   Equivalently: executeTasks reverts (ReportValidationFailed) on any report
///   failing quorum / APR / freshness, and only advances state when all hold.
///
///   Defenses under test: EtherFiAdmin._validateReport -> _validateReportFreshness
///   (consensus + refSlotFrom + postReportWaitTimeInSlots) and _validateRebaseApr
///   (|apr| > acceptableRebaseAprInBps); quorum enforced upstream in
///   EtherFiOracle.submitReport (support >= quorumSize).
///
///   HANDLER MODEL: the fuzzer drives a single `step(magnitude)` action. Each
///   call exercises all four scenarios (apply / quorum-fail / apr-fail /
///   fresh-fail) against the real EtherFiOracle + EtherFiAdmin, each leaving the
///   oracle in the un-stuck state. The fuzzed `magnitude` (and the random call
///   ordering / sequence length the invariant engine chooses) vary the rebase
///   sizes and the slot/epoch timeline across the run, so the safety property is
///   exercised over a wide state space. Before every executeTasks the handler
///   computes an INDEPENDENT, contract-faithful mirror of the three gates and
///   flips a ghost if a state-advancing report ever violated any gate (the I5
///   proof), with a mirror-consistency cross-check against the contract's own
///   revert reasons so the safety ghosts can't be vacuously satisfied.
///
///   SOUNDNESS ASSUMPTIONS (also in the handler):
///   * committee == {alice, bob}, quorumSize == 2 (TestSetup) — a single
///     submission is strictly sub-quorum.
///   * TVL seeded > 0 so the APR formula is non-trivial; postReportWaitTimeInSlots
///     set > 0 so the freshness gate is non-vacuous.
///   * A valid "apply" bounds its reward under the per-range APR-cap boundary
///     (the contract caps APR over the elapsed window), so the accepting path is
///     genuinely accepted rather than spuriously tripping the APR gate.
///
///   fail-on-revert is false: the handler INTENTIONALLY drives reverting paths
///   (sub-quorum, over-cap APR, too-fresh) and asserts the safety post-condition
///   via ghosts. Non-vacuity is enforced in afterInvariant().
///
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 30
/// forge-config: default.invariant.fail-on-revert = false
contract OracleIntegrityInvariantTest is TestSetup {
    OracleIntegrityHandler internal handler;

    function setUp() public {
        setUpTests();

        // SOUNDNESS: non-zero, stable TVL so the APR formula is non-trivial
        // (currentTVL > 0). Without it getTotalPooledEther()==0 makes APR
        // identically 0 and the APR gate could never be exercised.
        vm.deal(alice, 1_000 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 1_000 ether}();

        // SOUNDNESS: setUpTests initializes postReportWaitTimeInSlots == 0, which
        // would make the freshness gate vacuous. Set a strictly-positive window.
        vm.prank(alice);
        etherFiAdminInstance.updatePostReportWaitTimeInSlots(16);

        handler = new OracleIntegrityHandler(
            etherFiOracleInstance,
            etherFiAdminInstance,
            ILiquidityPool(address(liquidityPoolInstance)),
            alice,  // committee member A
            bob,    // committee member B
            owner,  // holds OPERATION_MULTISIG_ROLE (unpublishReport recovery)
            genesisSlotTimestamp
        );

        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = handler.step.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    // =====================================================================
    // I5 core safety invariants — proven by handler ghosts flipped ONLY if a
    // state-advancing executeTasks ever occurred while a gate was violated
    // (per an independent, contract-faithful gate mirror).
    // =====================================================================

    /// (a) No report may advance lastHandledReportRefSlot without quorum consensus.
    function invariant_i5_quorum_required() public view {
        assertFalse(
            handler.ghost_appliedWithoutQuorum(),
            "I5(a): a report advanced state without reaching quorum consensus"
        );
    }

    /// (b) No report may advance state while its |rebase APR| exceeds the cap.
    function invariant_i5_apr_capped() public view {
        assertFalse(
            handler.ghost_appliedAprViolation(),
            "I5(b): a report advanced state with APR above acceptableRebaseAprInBps"
        );
    }

    /// (c) No report may advance state before the post-report freshness window.
    function invariant_i5_freshness_enforced() public view {
        assertFalse(
            handler.ghost_appliedWhileStale(),
            "I5(c): a report advanced state before the post-report wait window"
        );
    }

    /// Mirror fidelity: every categorised ReportValidationFailed reason agrees
    /// with our independent gate mirror, keeping the safety ghosts non-vacuous.
    function invariant_i5_mirror_consistent() public view {
        assertFalse(handler.ghost_mirrorMismatch(), handler.mismatchReason());
    }

    // =====================================================================
    // Non-vacuity: the run must have actually exercised BOTH the accepting
    // path (>=1 applied) AND each rejecting gate (quorum / APR / freshness).
    // =====================================================================
    function afterInvariant() public {
        emit log_named_uint("I5 reports APPLIED", handler.numApplied());
        emit log_named_uint("I5 quorum-gate rejections", handler.numRejQuorum());
        emit log_named_uint("I5 apr-gate rejections", handler.numRejApr());
        emit log_named_uint("I5 freshness-gate rejections", handler.numRejFresh());
        assertGt(handler.numApplied(), 0, "non-vacuity: no report was ever APPLIED");
        assertGt(handler.numRejected(), 0, "non-vacuity: no report was ever REJECTED");
        assertGt(handler.numRejQuorum(), 0, "non-vacuity: quorum gate never exercised");
        assertGt(handler.numRejApr(), 0, "non-vacuity: APR gate never exercised");
        assertGt(handler.numRejFresh(), 0, "non-vacuity: freshness gate never exercised");
        assertEq(handler.numRejOther(), 0, "an executeTasks revert was uncategorised");
    }
}
