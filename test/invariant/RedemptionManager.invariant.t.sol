// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../TestSetup.sol";
import "./handlers/RedemptionManagerHandler.sol";

/// @notice Stateful invariant suite for EtherFiRedemptionManager + BucketLimiter.
///         ETH path only - the stETH path needs a mainnet fork (Lido state,
///         Liquifier balance, EtherFiRestaker hookup) which is incompatible
///         with 256x64 invariant runs. The fork-based ERM tests already
///         cover the stETH leg.
///
///         Properties:
///         - bucket capacity never exceeds the configured cap;
///         - successful redemptions never violate the LP rate-monotonicity
///           (via PR #428's modifier on the burn path the redeem touches);
///         - the share-conservation identity inside _processETHRedemption
///           never fires its safety reverts (InvalidNumSharesBurnt /
///           InvalidTotalShares / InvalidLpBalance) under bounded fuzz;
///         - pause actually halts state changes;
///         - LP balance delta per redeem matches the ETH paid to receiver;
///         - the canRedeem -> redeem flow does not let `RateLimitExceeded`
///           fire after a positive precheck in the same block.
///
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = false
/// forge-config: default.invariant.call-override = false
contract RedemptionManagerInvariantTest is TestSetup {
    RedemptionManagerHandler internal handler;

    address public constant ETH_ADDRESS_CONST = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function setUp() public {
        setUpTests();

        // Configure the ERM ETH path. `setUpTests` deploys + initializes the
        // ERM but doesn't initialize per-token bucket / fee parameters.
        // initializeTokenParameters is admin-gated and we want a clean
        // starting state rather than reusing existing test-suite values.
        vm.startPrank(alice); // alice == admin in TestSetup
        // Capacity high enough that fuzz redemptions don't immediately drain.
        etherFiRedemptionManagerInstance.setCapacity(1000 ether, ETH_ADDRESS_CONST);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(1 ether, ETH_ADDRESS_CONST);
        etherFiRedemptionManagerInstance.setExitFeeBasisPoints(100, ETH_ADDRESS_CONST);             // 1%
        etherFiRedemptionManagerInstance.setExitFeeSplitToTreasuryInBps(5000, ETH_ADDRESS_CONST);   // 50% to treasury
        // Drop watermark to 0 so the bucket - not the watermark - is the
        // gating constraint. The watermark gate is exercised by the dedicated
        // admin_setLowWatermarkBps op.
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, ETH_ADDRESS_CONST);
        vm.stopPrank();

        // Warp forward so the bucket has actually accumulated capacity (it
        // initialises with remaining == 0 and refills based on elapsed time).
        vm.warp(block.timestamp + 2000); // 2000 * 1 ether/s, capped at 1000 ether

        handler = new RedemptionManagerHandler(
            liquidityPoolInstance,
            eETHInstance,
            weEthInstance,
            etherFiRedemptionManagerInstance,
            treasuryInstance,
            address(membershipManagerInstance),
            alice
        );

        targetContract(address(handler));
    }

    // =====================================================================
    // I-1: bucket capacity invariant
    // =====================================================================

    /// `consumable(limit)` reads through `_refill` and must not exceed
    /// `capacity` post-refill. A violation indicates a bug in the refill
    /// math or in setCapacity's clamp-down logic.
    function invariant_bucket_within_capacity() public view {
        (uint64 capacity, uint64 remaining,,) =
            _readBucket(etherFiRedemptionManagerInstance, ETH_ADDRESS_CONST);
        assertLe(remaining, capacity, "BucketLimiter.remaining exceeds capacity");
    }

    // =====================================================================
    // I-2: rate monotonicity (PR #428's nonDecreasingRate modifier)
    // =====================================================================

    /// Oracle A: `amountForShare(1e18)` non-decreasing across every observed
    /// redeem. Redeem walks through `burnEEthShares` which carries PR #428's
    /// modifier; a drop would mean the modifier was bypassed.
    function invariant_redeem_rate_non_decreasing_amountForShare() public view {
        assertFalse(
            handler.ghost_rateDrop_viaAmountForShare(),
            "redeem caused amountForShare(1e18) to drop"
        );
    }

    /// Oracle B: probe account's `eETH.balanceOf` non-decreasing.
    function invariant_redeem_rate_non_decreasing_probeBalance() public view {
        assertFalse(
            handler.ghost_rateDrop_viaProbeBalance(),
            "redeem caused probe-account eETH.balanceOf to drop"
        );
    }

    // =====================================================================
    // I-3: internal safety reverts must NEVER fire under bounded fuzz
    // =====================================================================

    function invariant_no_invalid_shares_burnt() public view {
        assertEq(
            handler.ghost_invalidSharesBurntCount(), 0,
            "InvalidNumSharesBurnt fired - liquidityPool.withdraw returned wrong share count"
        );
    }

    function invariant_no_invalid_total_shares() public view {
        assertEq(
            handler.ghost_invalidTotalSharesCount(), 0,
            "InvalidTotalShares fired - share-conservation identity broken inside _processETHRedemption"
        );
    }

    function invariant_no_invalid_lp_balance() public view {
        assertEq(
            handler.ghost_invalidLpBalanceCount(), 0,
            "InvalidLpBalance fired - LP.totalValueInLp delta != ethReceived"
        );
    }

    function invariant_no_rate_modifier_revert() public view {
        assertEq(
            handler.ghost_modifierRevertCount(), 0,
            "EETHRateDeflation fired on a redeem path - PR #428 modifier triggered"
        );
    }

    function invariant_no_panics() public view {
        assertEq(
            handler.ghost_panicRevertCount(), 0,
            "Panic surfaced on a protocol call - review input bounds"
        );
    }

    // =====================================================================
    // I-4: share conservation (post-call identity)
    // =====================================================================

    function invariant_share_conservation_holds() public view {
        assertFalse(
            handler.ghost_shareConservationViolated(),
            "share/balance conservation violated in a successful redeem - see ghost_firstFailureOp"
        );
    }

    // =====================================================================
    // I-5: pause halts state changes
    // =====================================================================

    function invariant_pause_actually_halts_redemption() public view {
        assertFalse(
            handler.ghost_pauseBypassObserved(),
            "ERM accepted a redeem while paused"
        );
    }

    // =====================================================================
    // I-6: LP solvency on the in-LP bucket (sanity, also held in #436)
    // =====================================================================

    function invariant_lp_solvent_for_in_lp() public view {
        assertGe(
            address(liquidityPoolInstance).balance,
            uint256(liquidityPoolInstance.totalValueInLp()),
            "LP balance < totalValueInLp"
        );
    }

    // =====================================================================
    // I-7: TVL decomposition (sanity)
    // =====================================================================

    function invariant_tvl_decomposition() public view {
        assertEq(
            uint256(liquidityPoolInstance.totalValueInLp())
                + uint256(liquidityPoolInstance.totalValueOutOfLp()),
            liquidityPoolInstance.getTotalPooledEther(),
            "TVL decomposition broken"
        );
    }

    // =====================================================================
    // COVERAGE SUMMARY
    // =====================================================================

    function invariant_call_coverage_summary() public {
        emit log_named_uint("redeemEth                 ", handler.callCounts("redeemEth"));
        emit log_named_uint("redeemEth_blocked         ", handler.callCounts("redeemEth_blocked"));
        emit log_named_uint("redeemEth_skipped         ", handler.callCounts("redeemEth_skipped"));
        emit log_named_uint("redeemEth_revert          ", handler.callCounts("redeemEth_revert"));
        emit log_named_uint("redeemWeEth               ", handler.callCounts("redeemWeEth"));
        emit log_named_uint("redeemWeEth_blocked       ", handler.callCounts("redeemWeEth_blocked"));
        emit log_named_uint("redeemWeEth_skipped       ", handler.callCounts("redeemWeEth_skipped"));
        emit log_named_uint("redeemWeEth_revert        ", handler.callCounts("redeemWeEth_revert"));
        emit log_named_uint("setCapacity               ", handler.callCounts("setCapacity"));
        emit log_named_uint("setRefillRate             ", handler.callCounts("setRefillRate"));
        emit log_named_uint("setExitFee                ", handler.callCounts("setExitFee"));
        emit log_named_uint("setExitFeeSplit           ", handler.callCounts("setExitFeeSplit"));
        emit log_named_uint("setLowWatermark           ", handler.callCounts("setLowWatermark"));
        emit log_named_uint("pause                     ", handler.callCounts("pause"));
        emit log_named_uint("unpause                   ", handler.callCounts("unpause"));
        emit log_named_uint("lp_deposit                ", handler.callCounts("lp_deposit"));
        emit log_named_uint("rebase                    ", handler.callCounts("rebase"));
        emit log_named_uint("advance_time              ", handler.callCounts("advance_time"));
        emit log_named_uint("modifier_revert           ", handler.ghost_modifierRevertCount());
        emit log_named_uint("panic_revert              ", handler.ghost_panicRevertCount());
    }

    // =====================================================================
    // helpers
    // =====================================================================

    /// @dev `tokenToRedemptionInfo` is the public mapping. The bucket is
    ///      the first field of `RedemptionInfo`; reading the four packed
    ///      uint64 slots requires the explicit getter via the mapping.
    function _readBucket(EtherFiRedemptionManager _erm, address token)
        internal
        view
        returns (uint64 capacity, uint64 remaining, uint64 lastRefill, uint64 refillRate)
    {
        // Mapping accessor unrolls the struct into individual returns. The
        // first return is `BucketLimiter.Limit` packed - but Solidity will
        // unroll it into the four uint64 fields.
        // Returns: limit (4 uint64s), exitFeeSplit, exitFee, lowWatermark.
        (BucketLimiter.Limit memory limit,,,) = _erm.tokenToRedemptionInfo(token);
        capacity = limit.capacity;
        remaining = limit.remaining;
        lastRefill = limit.lastRefill;
        refillRate = limit.refillRate;
    }
}
