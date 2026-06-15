// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../TestSetup.sol";
import "./handlers/RewardsDistributorHandler.sol";

/// @notice Stateful invariant suite for CumulativeMerkleRewardsDistributor.
///         Proves the two PR-defended invariants:
///
///         I12 - cumulative-claim monotonicity & no double-pay
///               (defense: CumulativeMerkleRewardsDistributor.sol L112-114).
///         I13 - reward-root finalization delay
///               (defense: CumulativeMerkleRewardsDistributor.sol L79).
///
///         The handler is the fuzz target; it drives set-pending / finalize /
///         claim / replay / time+block warps and maintains independent ghost
///         oracles. fail-on-revert is false so legitimate reverts (e.g. a
///         premature finalize hitting InsufficentDelay) do not fail the run;
///         the invariants assert the safety post-conditions.
///
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = false
/// forge-config: default.invariant.call-override = false
contract RewardsDistributorInvariantTest is TestSetup {
    RewardsDistributorHandler internal handler;
    address internal rdToken;

    function setUp() public {
        setUpTests();

        handler = new RewardsDistributorHandler(
            cumulativeMerkleRewardsDistributorInstance,
            admin
        );

        rdToken = cumulativeMerkleRewardsDistributorInstance.ETH_ADDRESS();

        // Fund the distributor with ETH so ETH-token claims can pay out.
        vm.deal(address(cumulativeMerkleRewardsDistributorInstance), 1_000_000 ether);

        // Restrict fuzzing to the handler's ACTION functions. Without an explicit
        // selector list the engine also targets the handler's public view getters
        // (numClaimants / claimants / callCounts / ghost*), wasting the call budget
        // on no-ops so the lifecycle (setPending -> finalize -> claim) is never
        // driven and the run is vacuous (all counters 0). Curate the selectors so
        // every call advances the state machine.
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.doSetPendingRoot.selector;
        selectors[1] = handler.doFinalize.selector;
        selectors[2] = handler.doClaim.selector;
        selectors[3] = handler.doReplayClaim.selector;
        selectors[4] = handler.doSetClaimDelay.selector;
        selectors[5] = handler.doWarp.selector;
        selectors[6] = handler.doRoll.selector;
        selectors[7] = handler.doLowerCumulativeClaim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // =====================================================================
    // I12 - cumulative-claim monotonicity & no double-pay
    // =====================================================================

    function invariant_I12_cumulative_monotonic_no_double_pay() public view {
        // Ghost flags tripped inside the handler on any violation.
        assertFalse(handler.ghost_monotonicViolated(), "I12: cumulativeClaimed decreased (non-monotonic)");
        assertFalse(handler.ghost_doublePayViolated(), "I12: replay / double-payment observed");

        // Independent end-of-run reconciliation for every claimant:
        // on-chain cumulativeClaimed == ETH actually received == ghost-tracked paid.
        uint256 n = handler.numClaimants();
        for (uint256 i = 0; i < n; i++) {
            address account = handler.claimants(i);
            uint256 cum = cumulativeMerkleRewardsDistributorInstance.cumulativeClaimed(rdToken, account);
            // Claimants start at balance 0 and never spend, so balance == total paid.
            assertEq(account.balance, cum, "I12: ETH paid != cumulativeClaimed (double-pay/replay)");
            assertEq(handler.ghostPaid(account), cum, "I12: ghost paid ledger drift vs cumulativeClaimed");
            assertEq(handler.lastSeenCumulative(account), cum, "I12: last-seen cumulative drift");
        }
    }

    // =====================================================================
    // I13 - reward-root finalization delay
    // =====================================================================

    function invariant_I13_finalization_delay_enforced() public view {
        assertFalse(
            handler.ghost_finalizeDelayViolated(),
            "I13: finalize succeeded before claimDelay elapsed"
        );
        assertFalse(
            handler.ghost_finalizeRootMismatch(),
            "I13: claimable root != root that was pending for >= claimDelay"
        );
    }

    // =====================================================================
    // Non-vacuity: the run MUST have actually exercised the merkle-delay and
    // payout logic this suite defends. Without this, the I12/I13 ghost flags
    // stay false and balances stay zero if those paths are never hit, so the
    // invariants could pass without proving anything. Asserted once at the end.
    // =====================================================================
    function afterInvariant() public {
        // I13 path: at least one root must have been finalized after its delay.
        assertGt(handler.callCounts("finalize_ok"), 0, "non-vacuity: no merkle root was ever finalized (I13 unexercised)");
        // I12 path: at least one successful claim must have paid out.
        assertGt(handler.callCounts("claim_ok"), 0, "non-vacuity: no claim ever succeeded (I12 payout unexercised)");
        // Double-pay defense: at least one replay must have been attempted AND rejected.
        assertGt(handler.callCounts("replay_revert"), 0, "non-vacuity: replay/double-pay path never exercised");
        // I12 monotonic-decrease guard: at least one strictly-lower-cumulative
        // claim must have been attempted AND rejected, positively driving the
        // `preclaimed >= cumulativeAmount` revert path.
        assertGt(handler.callCounts("lower_rejected"), 0, "non-vacuity: monotonic-decrease guard never exercised");

        // And the run must have actually moved ETH: total ghost-paid across all
        // claimants > 0 (independent of the counters above).
        uint256 totalPaid;
        uint256 n = handler.numClaimants();
        for (uint256 i = 0; i < n; i++) {
            totalPaid += handler.ghostPaid(handler.claimants(i));
        }
        assertGt(totalPaid, 0, "non-vacuity: zero ETH paid across the whole run (claims never settled)");
    }

    // =====================================================================
    // Coverage summary (soft observability, not a hard assertion).
    // =====================================================================

    function invariant_call_coverage_summary() public {
        emit log_named_uint("setPending             ", handler.callCounts("setPending"));
        emit log_named_uint("setPending_revert      ", handler.callCounts("setPending_revert"));
        emit log_named_uint("finalize_ok            ", handler.callCounts("finalize_ok"));
        emit log_named_uint("finalize_delay_revert  ", handler.callCounts("finalize_delay_revert"));
        emit log_named_uint("finalize_other_revert  ", handler.callCounts("finalize_other_revert"));
        emit log_named_uint("claim_ok               ", handler.callCounts("claim_ok"));
        emit log_named_uint("claim_revert           ", handler.callCounts("claim_revert"));
        emit log_named_uint("replay_revert          ", handler.callCounts("replay_revert"));
        emit log_named_uint("lower_rejected         ", handler.callCounts("lower_rejected"));
        emit log_named_uint("lower_unexpected_ok    ", handler.callCounts("lower_unexpected_ok"));
        emit log_named_uint("replay_unexpected_ok   ", handler.callCounts("replay_unexpected_ok"));
        emit log_named_uint("replay_skipped         ", handler.callCounts("replay_skipped"));
        emit log_named_uint("setClaimDelay          ", handler.callCounts("setClaimDelay"));
        emit log_named_uint("warp                   ", handler.callCounts("warp"));
        emit log_named_uint("roll                   ", handler.callCounts("roll"));
    }
}
