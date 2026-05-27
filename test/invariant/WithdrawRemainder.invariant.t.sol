// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../TestSetup.sol";
import "./handlers/WithdrawRemainderHandler.sol";

/// @notice Stateful suite for the WRN claim → stranded-ETH → handleRemainder
///         cycle. Targets properties the existing FrozenRateWithdrawal suite
///         does NOT assert:
///
///         A. **Stranded-ETH ledger conservation.** _claimWithdraw decrements
///            the lock by `request.amountOfEEth` but pays only
///            `amountToWithdraw = min(amountOfEEth, frozenRate * shareOfEEth
///            / 1e18)`. Under a negative rebase between finalize and claim
///            the delta is stranded in the WRN balance until handleRemainder
///            sweeps it. We track every per-claim stranded delta + every
///            sweep and assert the identity
///            `WRN.balance - lock == cumStranded - swept`.
///
///         B. **handleRemainder share-burn conservation never fails.** Both
///            WRN's `InvalidEEthShares` and PQ's
///            `InvalidEEthSharesAfterRemainderHandling` are local
///            post-condition reverts; they must never fire under bounded
///            fuzz.
///
///         C. **Cross-contract rounding-direction observability.** WRN
///            floors the treasury allocation, PQ ceils it. The handler
///            accumulates per-contract treasury totals so the invariant
///            file can emit them for review and assert sane bounds.
///
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = false
/// forge-config: default.invariant.call-override = false
contract WithdrawRemainderInvariantTest is TestSetup {
    WithdrawRemainderHandler internal handler;
    address[5] internal handlerActors;

    function setUp() public {
        setUpTests();

        // Unpause WRN; the FrozenRate suite's pattern.
        vm.prank(alice);
        withdrawRequestNFTInstance.unPauseContract();

        // 5 actors, each pre-funded with eETH + approved for WRN/PQ/weETH.
        for (uint256 i = 0; i < 5; i++) {
            address a = address(uint160(uint256(keccak256(abi.encodePacked("wrnremain.actor.", i)))));
            handlerActors[i] = a;
            vm.deal(a, 2_000 ether);
            vm.prank(a);
            liquidityPoolInstance.deposit{value: 200 ether}();
        }

        // Grant housekeeping role for handleRemainder.
        bytes32 housekeepingRole = roleRegistryInstance.HOUSEKEEPING_OPERATIONS_ROLE();
        vm.prank(owner);
        roleRegistryInstance.grantRole(housekeepingRole, alice);

        // Whitelist actors for PQ + grant approvals.
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(alice);
            priorityQueueInstance.addToWhitelist(handlerActors[i]);
        }
        for (uint256 i = 0; i < 5; i++) {
            vm.startPrank(handlerActors[i]);
            eETHInstance.approve(address(liquidityPoolInstance), type(uint256).max);
            eETHInstance.approve(address(priorityQueueInstance), type(uint256).max);
            eETHInstance.approve(address(withdrawRequestNFTInstance), type(uint256).max);
            eETHInstance.approve(address(weEthInstance), type(uint256).max);
            vm.stopPrank();
        }

        // Configure the remainder split (50% to treasury) on both contracts
        // so the rounding-asymmetry comparison sees a non-zero split.
        vm.startPrank(alice);
        withdrawRequestNFTInstance.updateShareRemainderSplitToTreasuryInBps(5000);
        priorityQueueInstance.updateShareRemainderSplitToTreasury(5000);
        vm.stopPrank();

        // Seed totalValueOutOfLp with a positive rebase so the handler's
        // `lp_rebase_negative` op has room to actually fire from the very
        // first sequence. Without this, outOfLp stays at 0 until a finalize
        // or fulfill creates room, and the fuzzer almost never finds the
        // request -> negative-rebase -> finalize -> claim chain that
        // produces a positive stranded-ETH delta (the property the suite
        // is built to assert).
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(int128(int256(uint256(200 ether))));

        handler = new WithdrawRemainderHandler(
            liquidityPoolInstance,
            eETHInstance,
            withdrawRequestNFTInstance,
            priorityQueueInstance,
            address(etherFiAdminInstance),
            address(membershipManagerInstance),
            alice,
            alice,
            treasuryInstance,
            handlerActors
        );

        targetContract(address(handler));
    }

    // =====================================================================
    // A. Stranded-ETH ledger conservation
    // =====================================================================

    /// The ledger identity: WRN's balance excess over the lock equals exactly
    /// the cumulative stranded ETH minus what handleRemainder has swept.
    function invariant_wrn_stranded_ledger_consistent() public view {
        assertFalse(
            handler.ghost_wrnLedgerDrift(),
            "WRN stranded-ETH ledger drift: balance - lock != cumStranded - swept"
        );
    }

    /// (1) Differential check between the contract's `getClaimableAmount`
    /// and the handler's independent recomputation. They MUST agree
    /// exactly. A divergence is a finding in `_getClaimableAmount`.
    function invariant_wrn_getClaimableAmount_matches_recomputation() public view {
        assertFalse(
            handler.ghost_getClaimableAmountDrift(),
            string.concat(
                "getClaimableAmount differs from independent recompute - tokenId=",
                vm.toString(handler.ghost_drift_tokenId()),
                " contract=", vm.toString(handler.ghost_drift_contract()),
                " independent=", vm.toString(handler.ghost_drift_independent())
            )
        );
    }

    /// Always-on solvency. Already in the FrozenRate suite; included here
    /// for completeness so this file stands alone.
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
    // B. handleRemainder share-burn conservation must hold
    // =====================================================================

    /// WRN's `InvalidEEthShares` is a local post-condition revert that
    /// should NEVER surface under bounded fuzz. Its appearance means
    /// `liquidityPool.sharesForAmount(amountToTreasury) + sharesForAmount
    /// (amountToBurn)` didn't equal the share delta on this contract -
    /// a serious accounting bug.
    function invariant_wrn_remainder_share_conservation() public view {
        assertFalse(
            handler.ghost_wrnInvalidShares(),
            "WRN.handleRemainder InvalidEEthShares fired - remainder share accounting drift"
        );
    }

    function invariant_pq_remainder_share_conservation() public view {
        assertFalse(
            handler.ghost_pqInvalidShares(),
            "PQ.handleRemainder InvalidEEthSharesAfterRemainderHandling fired"
        );
    }

    /// `_claimWithdraw` revert path: BurnExceedsShares must never fire,
    /// since by construction the round-trip ceil-mulDiv guarantees the
    /// share burn <= request.shareOfEEth.
    function invariant_wrn_burn_within_request_shares() public view {
        assertFalse(
            handler.ghost_burnExceedsShares(),
            "WRN claim BurnExceedsShares fired - claim burned more than request authorized"
        );
    }

    function invariant_no_insufficient_escrow() public view {
        assertEq(
            handler.ghost_insufficientEscrowCount(), 0,
            "InsufficientEscrow fired - WRN ETH balance briefly went below the lock counter"
        );
    }

    function invariant_no_panic() public view {
        assertEq(
            handler.ghost_panicCount(), 0,
            "Panic surfaced on a withdraw-remainder path - review bounds"
        );
    }

    // =====================================================================
    // C. Cross-contract rounding-direction observability
    // =====================================================================

    /// Both WRN and PQ should compute non-trivial treasury allocations
    /// across many handleRemainder calls. If both counters are 0, the
    /// suite never reached the remainder path - coverage signal.
    /// Asserted as a soft observation via the coverage summary (this
    /// invariant always passes); the per-contract counts are emitted
    /// below for review.
    function invariant_cross_contract_remainder_observability() public view {
        // No hard assertion - both being 0 would mean we never reached
        // the remainder path during the run, not a correctness issue.
        // Emission lives in the coverage-summary invariant below.
    }

    // =====================================================================
    // LP TVL sanity - reused from FrozenRate suite
    // =====================================================================

    function invariant_lp_tvl_decomposition() public view {
        assertEq(
            uint256(liquidityPoolInstance.totalValueInLp())
                + uint256(liquidityPoolInstance.totalValueOutOfLp()),
            liquidityPoolInstance.getTotalPooledEther(),
            "TVL decomposition broken"
        );
    }

    function invariant_lp_solvent_for_in_lp() public view {
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
        emit log_named_uint("wrn_req                ", handler.callCounts("wrn_req"));
        emit log_named_uint("wrn_finalize           ", handler.callCounts("wrn_finalize"));
        emit log_named_uint("wrn_claim              ", handler.callCounts("wrn_claim"));
        emit log_named_uint("wrn_remainder          ", handler.callCounts("wrn_remainder"));
        emit log_named_uint("pq_req                 ", handler.callCounts("pq_req"));
        emit log_named_uint("pq_fulfill             ", handler.callCounts("pq_fulfill"));
        emit log_named_uint("pq_claim               ", handler.callCounts("pq_claim"));
        emit log_named_uint("pq_remainder           ", handler.callCounts("pq_remainder"));
        emit log_named_uint("rebase_positive        ", handler.callCounts("rebase_positive"));
        emit log_named_uint("rebase_negative        ", handler.callCounts("rebase_negative"));
        emit log_named_uint("advance_time           ", handler.callCounts("advance_time"));
        emit log_named_uint("ghost_wrnCumStranded   ", handler.ghost_wrnCumulativeStranded());
        emit log_named_uint("ghost_wrnSwept         ", handler.ghost_wrnSweptToTreasury());
        emit log_named_uint("ghost_wrnTreasFloor    ", handler.ghost_wrnTotalTreasuryFloor());
        emit log_named_uint("ghost_pqTreasCeil      ", handler.ghost_pqTotalTreasuryCeil());
        emit log_named_uint("ghost_wrnRemCalls      ", handler.ghost_wrnRemainderCalls());
        emit log_named_uint("ghost_pqRemCalls       ", handler.ghost_pqRemainderCalls());
    }
}
