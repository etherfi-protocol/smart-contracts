// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../TestSetup.sol";
import "./handlers/FrozenRateWithdrawalHandler.sol";

/// @notice Stateful invariant suite for the WithdrawRequestNFT and
///         PriorityWithdrawalQueue frozen-rate withdrawal paths - hardened
///         against multi-reviewer findings:
///
///         - (F-003) Write-once frozen-rate ghost catches re-finalize overwrite.
///         - (F-005) All checkpoint rates in WRN's _finalizationRates trace
///           are asserted in [min, max], not just the post-call read.
///         - (F-006) Realistic rebase bound (50 bps); extreme path is opt-in.
///         - (F-008) weETH-input PQ path now exercised.
///         - (F-010) PQ struct reconstruction drift surfaces as a ghost
///           flag, no longer silently swallowed by fail-on-revert = false.
///         - (F-016) NFT transfer + cross-owner claim covered.
///         - (F-022) Tolerance boundary explicit fuzz op.
///         - (F-023) handleRemainder paths exercised.
///         - (F-026) invalidate / validate / seize state transitions exercised.
///         - (F-027) Cancel exercises both pending and finalized branches.
///
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = false
/// forge-config: default.invariant.call-override = false
contract FrozenRateWithdrawalInvariantTest is TestSetup {
    FrozenRateWithdrawalHandler internal handler;
    address[] internal handlerActors;

    function setUp() public {
        setUpTests();

        vm.prank(alice);
        withdrawRequestNFTInstance.unPauseContract();

        for (uint256 i = 0; i < 5; i++) {
            address a = address(uint160(uint256(keccak256(abi.encodePacked("frozen.actor.", i)))));
            handlerActors.push(a);
            vm.deal(a, 1_000 ether);
            vm.prank(a);
            liquidityPoolInstance.deposit{value: 100 ether}();
        }

        // F-023 prereq: grant HOUSEKEEPING_OPERATIONS_ROLE to alice. Pre-
        // extract the role constant so it doesn't consume the vm.prank.
        bytes32 housekeepingRole = roleRegistryInstance.HOUSEKEEPING_OPERATIONS_ROLE();
        vm.prank(owner);
        roleRegistryInstance.grantRole(housekeepingRole, alice);

        vm.startPrank(alice);
        for (uint256 i = 0; i < handlerActors.length; i++) {
            priorityQueueInstance.addToWhitelist(handlerActors[i]);
        }
        vm.stopPrank();

        for (uint256 i = 0; i < handlerActors.length; i++) {
            vm.startPrank(handlerActors[i]);
            eETHInstance.approve(address(liquidityPoolInstance), type(uint256).max);
            eETHInstance.approve(address(priorityQueueInstance), type(uint256).max);
            eETHInstance.approve(address(withdrawRequestNFTInstance), type(uint256).max);
            eETHInstance.approve(address(weEthInstance), type(uint256).max);
            vm.stopPrank();
        }

        handler = new FrozenRateWithdrawalHandler(
            liquidityPoolInstance,
            eETHInstance,
            weEthInstance,
            withdrawRequestNFTInstance,
            priorityQueueInstance,
            address(etherFiAdminInstance),
            address(membershipManagerInstance),
            alice,
            alice,
            alice,
            handlerActors
        );

        targetContract(address(handler));
    }

    // =====================================================================
    // SOLVENCY
    // =====================================================================

    function invariant_wrn_balance_covers_lock() public view {
        assertGe(
            address(withdrawRequestNFTInstance).balance,
            uint256(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal()),
            "WRN balance < ethAmountLockedForWithdrawal"
        );
    }

    function invariant_pq_balance_covers_lock() public view {
        assertGe(
            address(priorityQueueInstance).balance,
            uint256(priorityQueueInstance.ethAmountLockedForPriorityWithdrawal()),
            "PQ balance < ethAmountLockedForPriorityWithdrawal"
        );
    }

    // =====================================================================
    // FROZEN-RATE INTEGRITY
    // =====================================================================

    function invariant_frozen_rate_within_bounds() public view {
        assertFalse(
            handler.ghost_frozenRateOutOfBounds(),
            "frozen rate observed outside [min, max]"
        );
    }

    function invariant_all_checkpoints_in_bounds() public view {
        (bool ok, uint256 firstOOB) = handler.verifyAllFinalizationCheckpointsInBounds();
        assertTrue(ok, string.concat("frozen rate OOB for tokenId=", vm.toString(firstOOB)));
    }

    function invariant_frozen_rate_persists_under_rebase() public {
        handler.verifyFrozenRatePersistence();
        assertFalse(
            handler.ghost_frozenRateMutated(),
            "WRN.frozenRateFor(tokenId) mutated after finalize"
        );
    }

    function invariant_wrn_burn_bounded_by_request_shares() public view {
        assertFalse(
            handler.ghost_wrnBurnExceededShares(),
            "WRN claim burned more shares than the request authorized"
        );
    }

    // =====================================================================
    // F-010 - drift ghosts
    // =====================================================================

    function invariant_pq_struct_no_drift() public view {
        assertFalse(handler.ghost_pqStructDrift(), "PQ request struct reconstruction drifted from on-chain hash");
    }

    function invariant_wrn_nextId_no_drift() public view {
        assertFalse(handler.ghost_wrnNextIdDrift(), "WRN nextRequestId drifted from handler's prediction");
    }

    // =====================================================================
    // PQ STATE MACHINE
    // =====================================================================

    function invariant_pq_finalized_eth_sum_matches_lock() public view {
        assertEq(
            handler.pqSumFinalizedAmount(),
            uint256(priorityQueueInstance.ethAmountLockedForPriorityWithdrawal()),
            "PQ finalized sum != ethAmountLockedForPriorityWithdrawal"
        );
    }

    // =====================================================================
    // WRN ETH ACCOUNTING
    // =====================================================================

    function invariant_wrn_lock_covers_unclaimed_finalized() public view {
        assertGe(
            uint256(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal()),
            handler.wrnSumUnclaimedFinalizedAmount(),
            "WRN lock < sum(unclaimed-finalized amountOfEEth)"
        );
    }

    // =====================================================================
    // LP TVL SANITY
    // =====================================================================

    function invariant_lp_tvl_decomposition() public view {
        uint256 sum = uint256(liquidityPoolInstance.totalValueInLp())
                    + uint256(liquidityPoolInstance.totalValueOutOfLp());
        assertEq(sum, liquidityPoolInstance.getTotalPooledEther(), "TVL decomposition broken");
    }

    function invariant_lp_solvency_in_lp_bucket() public view {
        assertGe(
            address(liquidityPoolInstance).balance,
            uint256(liquidityPoolInstance.totalValueInLp()),
            "LP balance < totalValueInLp"
        );
    }

    // =====================================================================
    // COVERAGE SUMMARY
    // =====================================================================

    function invariant_call_coverage_summary() public {
        emit log_named_uint("wrn_req                  ", handler.callCounts("wrn_req"));
        emit log_named_uint("wrn_finalize             ", handler.callCounts("wrn_finalize"));
        emit log_named_uint("wrn_claim                ", handler.callCounts("wrn_claim"));
        emit log_named_uint("wrn_xfer                 ", handler.callCounts("wrn_xfer"));
        emit log_named_uint("wrn_invalidate           ", handler.callCounts("wrn_invalidate"));
        emit log_named_uint("wrn_validate             ", handler.callCounts("wrn_validate"));
        emit log_named_uint("wrn_remainder            ", handler.callCounts("wrn_remainder"));
        emit log_named_uint("pq_req                   ", handler.callCounts("pq_req"));
        emit log_named_uint("pq_reqWeETH              ", handler.callCounts("pq_reqWeETH"));
        emit log_named_uint("pq_boundary              ", handler.callCounts("pq_boundary"));
        emit log_named_uint("pq_fulfill               ", handler.callCounts("pq_fulfill"));
        emit log_named_uint("pq_claim                 ", handler.callCounts("pq_claim"));
        emit log_named_uint("pq_cancel_pending        ", handler.callCounts("pq_cancel_pending"));
        emit log_named_uint("pq_cancel_finalized      ", handler.callCounts("pq_cancel_finalized"));
        emit log_named_uint("pq_cancel_not_matured    ", handler.callCounts("pq_cancel_not_matured"));
        emit log_named_uint("pq_invalidate            ", handler.callCounts("pq_invalidate"));
        emit log_named_uint("pq_remainder             ", handler.callCounts("pq_remainder"));
        emit log_named_uint("rebase_positive          ", handler.callCounts("rebase_positive"));
        emit log_named_uint("rebase_negative          ", handler.callCounts("rebase_negative"));
        emit log_named_uint("rebaseExtreme            ", handler.callCounts("rebaseExtreme"));
        emit log_named_uint("advance_time             ", handler.callCounts("advance_time"));
        emit log_named_uint("tolerance_boundary_hits  ", handler.ghost_toleranceBoundaryHits());
    }
}
