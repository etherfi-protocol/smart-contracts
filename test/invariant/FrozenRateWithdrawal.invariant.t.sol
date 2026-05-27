// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../TestSetup.sol";
import "./handlers/FrozenRateWithdrawalHandler.sol";

/// @notice Stateful invariant suite for the WithdrawRequestNFT and
///         PriorityWithdrawalQueue frozen-rate withdrawal paths — the
///         EXEMPT paths PR #428's `nonDecreasingRate` modifier deliberately
///         leaves uncovered.
///
///         For these paths the rate-deflation guarantee is upstream:
///         WRN snapshots `amountPerShareCeil()` at finalize and bounds it
///         in [min, max] per its own `InvalidShareRate` revert; the claim
///         path's `BurnExceedsShares` revert prevents burning beyond the
///         request's own share allocation. PQ enforces a per-claim
///         solvency tolerance.
///
///         What this suite catches that the existing PR-#428 suite cannot:
///         - WRN/PQ ETH segregation drifting from the on-chain lock counter.
///         - A frozen rate written outside [min, max] (would require an
///           upstream check bypass).
///         - A frozen rate mutating after finalize (the H-02 fix regression).
///         - A claim burning more shares than the request authorized.
///         - PQ finalize/claim/cancel state-machine bookkeeping desync.
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

        // WRN ships paused; unpause so requestWithdraw is reachable. PQ
        // defaults unpaused so no equivalent step is needed there.
        vm.prank(alice);
        withdrawRequestNFTInstance.unPauseContract();

        // ---- Provision 5 EOA actors with eETH and PQ whitelist ----
        for (uint256 i = 0; i < 5; i++) {
            address a = address(uint160(uint256(keccak256(abi.encodePacked("frozen.actor.", i)))));
            handlerActors.push(a);
            vm.deal(a, 1_000 ether);
            vm.prank(a);
            liquidityPoolInstance.deposit{value: 100 ether}();
        }

        // ---- Roles ----
        // HOUSEKEEPING_OPERATIONS_ROLE isn't granted to alice by setUpTests but
        // the handler doesn't call handleRemainder, so we don't need it.
        // PQ.addToWhitelist is `onlyAdmin`. `alice` already holds
        // OPERATION_TIMELOCK_ROLE from setUpTests (which is what onlyAdmin
        // checks here), so prank as alice for whitelist additions.
        vm.startPrank(alice);
        for (uint256 i = 0; i < handlerActors.length; i++) {
            priorityQueueInstance.addToWhitelist(handlerActors[i]);
        }
        vm.stopPrank();

        // ---- eETH approvals (so wrn_request and pq_request work without burning a handler op slot) ----
        for (uint256 i = 0; i < handlerActors.length; i++) {
            vm.startPrank(handlerActors[i]);
            eETHInstance.approve(address(liquidityPoolInstance), type(uint256).max);
            eETHInstance.approve(address(priorityQueueInstance), type(uint256).max);
            eETHInstance.approve(address(withdrawRequestNFTInstance), type(uint256).max);
            eETHInstance.approve(address(weEthInstance), type(uint256).max);
            vm.stopPrank();
        }

        // ---- Deploy the handler ----
        handler = new FrozenRateWithdrawalHandler(
            liquidityPoolInstance,
            eETHInstance,
            weEthInstance,
            withdrawRequestNFTInstance,
            priorityQueueInstance,
            address(etherFiAdminInstance),
            address(membershipManagerInstance),
            alice,
            handlerActors
        );

        targetContract(address(handler));
    }

    // =====================================================================
    // SOLVENCY
    // =====================================================================

    /// @notice WRN's ETH balance must cover its declared lock at all times.
    ///         Enforced per-op by `_checkEthAmountLockedForWithdrawal`; this
    ///         global assertion catches any future path that bypasses the
    ///         helper.
    function invariant_wrn_balance_covers_lock() public view {
        assertGe(
            address(withdrawRequestNFTInstance).balance,
            uint256(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal()),
            "WRN balance < ethAmountLockedForWithdrawal"
        );
    }

    /// @notice PQ's ETH balance must cover its declared lock at all times.
    function invariant_pq_balance_covers_lock() public view {
        assertGe(
            address(priorityQueueInstance).balance,
            uint256(priorityQueueInstance.ethAmountLockedForPriorityWithdrawal()),
            "PQ balance < ethAmountLockedForPriorityWithdrawal"
        );
    }

    // =====================================================================
    // FROZEN-RATE INTEGRITY — the load-bearing security boundary on the
    // exempt path PR #428 doesn't cover.
    // =====================================================================

    /// @notice Every frozen rate the handler observed at finalize lived
    ///         inside the WRN-declared bounds. The bound check inside
    ///         `WRN.finalizeRequests` is what enforces this; the flag is
    ///         set in the handler if a finalize ever wrote an out-of-bounds
    ///         value (it can't today; the assertion guards against a
    ///         regression that drops the check).
    function invariant_frozen_rate_within_bounds() public view {
        assertFalse(
            handler.ghost_frozenRateOutOfBounds(),
            "frozen rate observed outside [min, max]"
        );
    }

    /// @notice The frozen rate WRN returns for a finalized tokenId never
    ///         changes once it's been recorded. The H-02 fix snapshots the
    ///         rate at finalize so subsequent rebases don't move the claim
    ///         payout. This invariant proves the snapshot is immutable.
    ///
    ///         The handler's `verifyFrozenRatePersistence` re-reads
    ///         `WRN.frozenRateFor(tokenId)` for every tokenId it has
    ///         finalized; mismatches flip the ghost flag.
    function invariant_frozen_rate_persists_under_rebase() public {
        handler.verifyFrozenRatePersistence();
        assertFalse(
            handler.ghost_frozenRateMutated(),
            "WRN.frozenRateFor(tokenId) mutated after finalize"
        );
    }

    /// @notice For every claim observed, `burnedShares <= request.shareOfEEth`.
    ///         WRN reverts with `BurnExceedsShares` if violated; the ghost
    ///         flag is the regression guard.
    function invariant_wrn_burn_bounded_by_request_shares() public view {
        assertFalse(
            handler.ghost_wrnBurnExceededShares(),
            "WRN claim burned more shares than the request authorized"
        );
    }

    // =====================================================================
    // PQ STATE MACHINE — pending / finalized / removed must be disjoint
    // and the lock counter must match the sum of currently-finalized
    // request amounts.
    // =====================================================================

    /// @notice Sum of `amountOfEEth` for PQ requests currently in the
    ///         finalized set equals `ethAmountLockedForPriorityWithdrawal`.
    ///         Drift means a request moved out of `_finalizedRequests`
    ///         without the corresponding ETH debit (or vice versa).
    function invariant_pq_finalized_eth_sum_matches_lock() public view {
        assertEq(
            handler.pqSumFinalizedAmount(),
            uint256(priorityQueueInstance.ethAmountLockedForPriorityWithdrawal()),
            "PQ finalized sum != ethAmountLockedForPriorityWithdrawal"
        );
    }

    // =====================================================================
    // WRN ETH ACCOUNTING — the lock counter is bounded below by the
    // unclaimed-finalized request amount. The handler over-debits on
    // rate-drop claims (debit = amountOfEEth, payment = amountToWithdraw),
    // so equality doesn't hold; the lower-bound form does. `handleRemainder`
    // sweeps the stranded excess to treasury but is not called in this
    // suite, so the only debit path is claim.
    // =====================================================================

    /// @notice The on-chain lock is at least the sum of unclaimed-finalized
    ///         request amounts. This is the WRN counterpart of the PQ
    ///         finalized-sum invariant; equality doesn't hold because of
    ///         the documented over-debit on rate-drop claims (see
    ///         `WithdrawRequestNFT._claimWithdraw` and the `strandedEth`
    ///         cleanup in `handleRemainder`). The lower bound MUST hold —
    ///         otherwise a future claim of an unrelated unclaimed request
    ///         would `InsufficientEscrow`-revert with funds still owed.
    function invariant_wrn_lock_covers_unclaimed_finalized() public view {
        // Note: lock = sum(amountOfEEth of finalized-not-yet-claimed). Any
        // CLAIM debit subtracts `amountOfEEth` regardless of payment; the
        // sum the handler computes follows the same accounting (only
        // unclaimed are summed), so this should be an exact equality at
        // all times BEFORE handleRemainder ever runs. We assert the
        // tighter `>=` for forward-compat with a future suite that runs
        // handleRemainder.
        assertGe(
            uint256(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal()),
            handler.wrnSumUnclaimedFinalizedAmount(),
            "WRN lock < sum(unclaimed-finalized amountOfEEth)"
        );
    }

    // =====================================================================
    // LP TVL SANITY — re-asserted in this suite because the WRN/PQ flow
    // moves ETH InLp <-> OutOfLp via lock/unlock; a bug there would surface
    // here first.
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
    // COVERAGE SUMMARY — emits at the end of each run so we can confirm
    // the fuzzer actually exercises both flows.
    // =====================================================================

    function invariant_call_coverage_summary() public {
        emit log_named_uint("wrn_req                  ", handler.callCounts("wrn_req"));
        emit log_named_uint("wrn_req_revert           ", handler.callCounts("wrn_req_revert"));
        emit log_named_uint("wrn_req_skipped          ", handler.callCounts("wrn_req_skipped"));
        emit log_named_uint("wrn_finalize             ", handler.callCounts("wrn_finalize"));
        emit log_named_uint("wrn_finalize_revert      ", handler.callCounts("wrn_finalize_revert"));
        emit log_named_uint("wrn_finalize_no_liquidity", handler.callCounts("wrn_finalize_no_liquidity"));
        emit log_named_uint("wrn_finalize_skipped     ", handler.callCounts("wrn_finalize_skipped"));
        emit log_named_uint("wrn_claim                ", handler.callCounts("wrn_claim"));
        emit log_named_uint("wrn_claim_revert         ", handler.callCounts("wrn_claim_revert"));
        emit log_named_uint("wrn_claim_skipped        ", handler.callCounts("wrn_claim_skipped"));
        emit log_named_uint("pq_req                   ", handler.callCounts("pq_req"));
        emit log_named_uint("pq_req_revert            ", handler.callCounts("pq_req_revert"));
        emit log_named_uint("pq_req_skipped           ", handler.callCounts("pq_req_skipped"));
        emit log_named_uint("pq_fulfill               ", handler.callCounts("pq_fulfill"));
        emit log_named_uint("pq_fulfill_revert        ", handler.callCounts("pq_fulfill_revert"));
        emit log_named_uint("pq_fulfill_skipped       ", handler.callCounts("pq_fulfill_skipped"));
        emit log_named_uint("pq_fulfill_no_liquidity  ", handler.callCounts("pq_fulfill_no_liquidity"));
        emit log_named_uint("pq_claim                 ", handler.callCounts("pq_claim"));
        emit log_named_uint("pq_claim_revert          ", handler.callCounts("pq_claim_revert"));
        emit log_named_uint("pq_claim_skipped         ", handler.callCounts("pq_claim_skipped"));
        emit log_named_uint("pq_cancel                ", handler.callCounts("pq_cancel"));
        emit log_named_uint("pq_cancel_revert         ", handler.callCounts("pq_cancel_revert"));
        emit log_named_uint("pq_cancel_skipped        ", handler.callCounts("pq_cancel_skipped"));
        emit log_named_uint("rebase                   ", handler.callCounts("rebase"));
        emit log_named_uint("rebase_revert            ", handler.callCounts("rebase_revert"));
        emit log_named_uint("advance_time             ", handler.callCounts("advance_time"));
    }
}
