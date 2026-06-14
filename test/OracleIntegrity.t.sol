// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/interfaces/ILiquidityPool.sol";
import "./invariant/handlers/OracleIntegrityHandler.sol";

/// @notice Deterministic STATEFUL sequence test for invariant I5 (Oracle Integrity).
///
///   I5 (from protocol-ops/security/architecture/invariants.md): every applied
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
///   WHY A DETERMINISTIC SEQUENCE TEST (not a randomized invariant):
///   EtherFiOracle is a strict slot/epoch state machine — submitReport's
///   verifyReport rejects any report whose refSlot/refBlock stamps don't match
///   the live blockStampForNextReport() and whose epoch isn't finalized. Driving
///   that reliably requires precise, ordered clock control, which does not
///   survive Foundry's randomized stateful-fuzz scheduling / sequence shrinking
///   (the run goes vacuous, numApplied==0). The property itself is fully
///   exercised here by deterministically driving every scenario via the shared
///   OracleIntegrityHandler, which mirrors the three gates INDEPENDENTLY and
///   flips a ghost if a state-advancing executeTasks ever occurred while any gate
///   was violated. This matches how the rest of the oracle suite
///   (EtherFiOracle.t.sol) is tested. Non-vacuity is asserted explicitly below.
///
///   SOUNDNESS ASSUMPTIONS (also documented in the handler):
///   * committee == {alice, bob}, quorumSize == 2 (TestSetup) — a single
///     submission is strictly sub-quorum.
///   * TVL seeded > 0 so the APR formula is non-trivial; postReportWaitTimeInSlots
///     set > 0 so the freshness gate is non-vacuous.
///   * The gate mirror is asserted byte-faithful to EtherFiAdmin via the
///     mirror-consistency check, so the safety ghosts cannot be vacuously
///     satisfied by a broken mirror.
contract OracleIntegrityTest is TestSetup {
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
        // alice holds the admin role in setUpTests.
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
    }

    /// Drives the full I5 scenario set across many rounds. Each handler.step()
    /// runs all four sub-scenarios (apply / quorum-fail / apr-fail / fresh-fail),
    /// each self-contained and leaving the oracle un-stuck. After each step we
    /// assert the I5 safety ghosts have NOT tripped (no gate-violating apply ever
    /// occurred) and the gate mirror stayed consistent with the contract.
    function test_i5_oracle_integrity_stateful() public {
        uint256 ROUNDS = 24;
        for (uint256 i = 0; i < ROUNDS; i++) {
            // vary the rebase magnitude each round to exercise the APR arithmetic
            handler.step(0.05 ether + i * 0.02 ether);

            // ---- I5 SAFETY (the actual proof) ----
            assertFalse(
                handler.ghost_appliedWithoutQuorum(),
                "I5(a): a report advanced state without reaching quorum consensus"
            );
            assertFalse(
                handler.ghost_appliedAprViolation(),
                "I5(b): a report advanced state with APR above acceptableRebaseAprInBps"
            );
            assertFalse(
                handler.ghost_appliedWhileStale(),
                "I5(c): a report advanced state before the post-report wait window"
            );
            // ---- mirror fidelity: keeps the safety ghosts from being vacuous ----
            assertFalse(handler.ghost_mirrorMismatch(), handler.mismatchReason());
        }

        // ---- NON-VACUITY: the run must have actually exercised BOTH the
        // accepting path (>=1 applied) AND each rejecting gate. ----
        assertGt(handler.numApplied(), 0, "non-vacuity: no report was ever APPLIED");
        assertGt(handler.numRejected(), 0, "non-vacuity: no report was ever REJECTED");
        assertGt(handler.numRejQuorum(), 0, "non-vacuity: quorum gate never exercised");
        assertGt(handler.numRejApr(), 0, "non-vacuity: APR gate never exercised");
        assertGt(handler.numRejFresh(), 0, "non-vacuity: freshness gate never exercised");
        // structural reverts must never be miscategorised into a gate bucket
        assertEq(handler.numRejOther(), 0, "an executeTasks revert was uncategorised");

        emit log_named_uint("I5 reports APPLIED", handler.numApplied());
        emit log_named_uint("I5 quorum-gate rejections", handler.numRejQuorum());
        emit log_named_uint("I5 apr-gate rejections", handler.numRejApr());
        emit log_named_uint("I5 freshness-gate rejections", handler.numRejFresh());
    }
}
