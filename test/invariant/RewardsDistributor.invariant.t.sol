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
        emit log_named_uint("replay_unexpected_ok   ", handler.callCounts("replay_unexpected_ok"));
        emit log_named_uint("replay_skipped         ", handler.callCounts("replay_skipped"));
        emit log_named_uint("setClaimDelay          ", handler.callCounts("setClaimDelay"));
        emit log_named_uint("warp                   ", handler.callCounts("warp"));
        emit log_named_uint("roll                   ", handler.callCounts("roll"));
    }
}
