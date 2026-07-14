// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../TestSetup.sol";
import "./handlers/ProtocolInvariantsHandler.sol";

/// @notice Stateful invariant suite for PR #428's two inlined invariants AND
///         the global protocol-accounting conservation laws those two
///         invariants are built on top of. Hardened against the multi-
///         reviewer findings from the original PR-#436 review:
///
///         - Rate-monotonicity is asserted via two independent oracles
///           (amountForShare(SHARE_PROBE) AND a fixed-share probe account's
///           balanceOf). F-001
///         - Protocol's own safety reverts (EETHRateDeflation, WeETHUnderbacked,
///           Panic) are explicitly counted via per-op selector capture and
///           asserted to never fire in normal-input fuzzing. F-002
///         - Bootstrap-exempt branch is COUNTED separately for organic vs
///           drain-path callers; the organic-path counter must stay 0. F-011
///         - Global-shares-conservation now includes a static-actor residual
///           check so callback-routed credits to unobserved addresses still
///           fail the assertion. F-029
///         - Independent TPE ledger asserted against on-chain
///           getTotalPooledEther so the algebraic-identity tautology is
///           replaced with a behavioral check. F-014
///         - Pause-bypass observation: any state-changing call that succeeds
///           while LP is paused flips a ghost. F-018
///
///         CAVEAT (F-019): all invariants are SINGLE-CHAIN. Global weETH
///         solvency on the full LayerZero OFT mesh is
///         `sum_chains(weETH.totalSupply) <= eETH.shares(weETH_proxy_mainnet)`
///         and is enforced by OFT rate-limits + bridge attestations, not
///         this suite.
///
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = false
/// forge-config: default.invariant.call-override = false
contract ProtocolInvariantsInvariantTest is TestSetup {
    ProtocolInvariantsHandler internal handler;

    function setUp() public {
        setUpTests();

        handler = new ProtocolInvariantsHandler(
            liquidityPoolInstance,
            eETHInstance,
            weEthInstance,
            address(etherFiRedemptionManagerInstance),
            address(withdrawRequestNFTInstance),
            address(priorityQueueInstance),
            address(membershipManagerInstance),
            treasuryInstance,
            address(liquifierInstance),     // F-009
            alice                           // F-018: alice holds OPERATION_MULTISIG_ROLE via setUpTests
        );

        targetContract(address(handler));
    }

    // =====================================================================
    // INVARIANT 1 - weETH supply at-most-fully-backed by proxy eETH shares
    // =====================================================================

    function invariant_inv1_weeth_at_most_backed_by_proxy_shares() public {
        handler.observeBackingGap();

        assertLe(
            weEthInstance.totalSupply(),
            eETHInstance.shares(address(weEthInstance)),
            "weETH underbacked across handler sequence"
        );
        assertLe(
            handler.ghost_worstWeethUnderbacking(),
            int256(0),
            "weETH underbacking observed during sequence"
        );
    }

    // =====================================================================
    // INVARIANT 2 - non-exempt LP paths never drop the eETH rate
    // (F-001: TWO INDEPENDENT ORACLES - both must agree.)
    // =====================================================================

    /// (F-001) Oracle A: `lp.amountForShare(1e18)` is a derived rate scalar
    /// computed via `Math.mulDiv(1e18, P, S, Down)` - a DIFFERENT code path
    /// from the modifier's cross-multiplication `P*S`. If the modifier had
    /// an off-by-one in the predicate, this oracle would not share the bug.
    function invariant_inv2_rate_non_decreasing_via_amountForShare() public view {
        assertFalse(
            handler.ghost_nonExemptRateDrop_viaAmountForShare(),
            "non-exempt op caused amountForShare(1e18) to drop"
        );
    }

    /// (F-001) Oracle B: a fixed-share probe account's `eETH.balanceOf` is
    /// observable end-user state. The probe holds a constant share balance
    /// (handler constructor seeds it and no handler op pranks as it), so
    /// any decrease in the probe's eETH balance reflects a rate drop.
    function invariant_inv2_rate_non_decreasing_via_probe_balance() public view {
        assertFalse(
            handler.ghost_nonExemptRateDrop_viaProbeBalance(),
            "non-exempt op caused probe-account eETH.balanceOf to drop"
        );
    }

    // =====================================================================
    // F-002 - Safety-revert counters: critical selectors should never fire
    // under properly-bounded fuzz inputs.
    // =====================================================================

    /// The LP modifier's `EETHRateDeflation()` revert should NEVER surface
    /// in a normal-input sequence. The fuzzer's bounds keep inputs in the
    /// modifier-safe range; if it fires anyway, either the bounds are
    /// wrong OR the modifier is misfiring.
    function invariant_modifier_revert_never_fires() public view {
        assertEq(
            handler.ghost_modifierRevertCount(),
            0,
            "EETHRateDeflation revert observed during normal-input fuzz"
        );
    }

    /// Same for the weETH `WeETHUnderbacked` hook.
    function invariant_weeth_hook_revert_never_fires() public view {
        assertEq(
            handler.ghost_weethHookRevertCount(),
            0,
            "WeETHUnderbacked revert observed during normal-input fuzz"
        );
    }

    /// Panic reverts (over/underflow, division-by-zero, etc.) should never
    /// fire on protocol calls. The bounds guard against this; flagging
    /// surfaces any input-space corner the bounds missed.
    function invariant_no_panic_reverts() public view {
        assertEq(
            handler.ghost_panicRevertCount(),
            0,
            "protocol call panicked during fuzz - review input bounds"
        );
    }

    // =====================================================================
    // F-011 - Bootstrap-exempt branch tracking. Organic paths should never
    // walk into S=0; the dedicated drain op may.
    // =====================================================================

    function invariant_bootstrap_exempt_only_from_drain_path() public view {
        assertFalse(
            handler.ghost_bootstrapExemptFromOrganicPath(),
            "bootstrap-exempt fired from a non-drain handler op - investigate"
        );
    }

    // =====================================================================
    // GLOBAL CONSERVATION
    // =====================================================================

    /// F-014: External-behavior version of TVL decomposition. The previous
    /// `totalValueInLp + totalValueOutOfLp == getTotalPooledEther()` is an
    /// algebraic identity. The handler maintains an independent ledger that
    /// increments on every observed deposit / burn-for-non-ETH /
    /// rebase. End-of-sequence equality with on-chain TPE is the real
    /// behavioral check.
    function invariant_tpe_matches_independent_ledger() public view {
        int256 ledger = handler.ghost_ledgerTPE();
        require(ledger >= 0, "ledger went negative");
        assertEq(
            liquidityPoolInstance.getTotalPooledEther(),
            uint256(ledger),
            "getTotalPooledEther drift vs independent handler-side ledger"
        );
    }

    function invariant_lp_solvency_in_lp_bucket() public view {
        assertGe(
            address(liquidityPoolInstance).balance,
            uint256(liquidityPoolInstance.totalValueInLp()),
            "LP cannot cover totalValueInLp"
        );
    }

    /// (F-029) Sum eETH.shares over both dynamic shareHolders AND the
    /// static actor pool; equality with `totalShares` must hold. The static-
    /// pool union catches credits to actors that were never dynamically
    /// observed (e.g., a callback-routed mint).
    function invariant_global_total_shares_conserved() public view {
        uint256 acc = handler.sumSharesAcrossAllKnown();
        assertEq(
            acc,
            eETHInstance.totalShares(),
            "eETH total-shares accounting drift across handler sequence"
        );
    }

    // =====================================================================
    // F-013 - weETH-hook-fires-on-underbacking proof
    // =====================================================================

    /// The adversarial_drainHookProof op constructs underbacking and probes
    /// a 1-wei wrap. If the wrap succeeded, the hook failed to fire.
    function invariant_weeth_hook_fires_under_drain() public view {
        assertFalse(
            handler.ghost_drainProof_hookFailedToFire(),
            "weETH hook failed to fire on an underbacked proxy"
        );
        assertEq(
            uint256(uint32(handler.ghost_drainProof_unexpectedSelector())),
            0,
            "drain-proof wrap reverted with an unexpected selector"
        );
        assertFalse(
            handler.ghost_drainProof_restoreFailed(),
            "drain-proof eETH restoration failed - accounting off"
        );
    }

    // =====================================================================
    // F-018 - Pause is a defense, not just a flag.
    // =====================================================================

    function invariant_pause_actually_halts_state_changes() public view {
        assertFalse(
            handler.ghost_pauseBypassObserved(),
            "LP accepted a state-changing call while paused"
        );
    }

    // =====================================================================
    // CALL SUMMARY - observability + coverage gates
    // =====================================================================

    /// (F-028) Coverage gate is a SOFT observation, not a hard assertion -
    /// Foundry evaluates invariants from the initial setUp state where all
    /// counts are 0, so an assertGt would fail-cascade. The summary
    /// invariant emits the counters so reviewers can verify each path
    /// reaches success during a `-vv` run.

    function invariant_call_coverage_summary() public {
        emit log_named_uint("deposit                ", handler.callCounts("deposit"));
        emit log_named_uint("deposit_revert         ", handler.callCounts("deposit_revert"));
        emit log_named_uint("wrap                   ", handler.callCounts("wrap"));
        emit log_named_uint("wrap_skipped           ", handler.callCounts("wrap_skipped"));
        emit log_named_uint("wrap_revert            ", handler.callCounts("wrap_revert"));
        emit log_named_uint("unwrap                 ", handler.callCounts("unwrap"));
        emit log_named_uint("unwrap_skipped         ", handler.callCounts("unwrap_skipped"));
        emit log_named_uint("unwrap_revert          ", handler.callCounts("unwrap_revert"));
        emit log_named_uint("burn                   ", handler.callCounts("burn"));
        emit log_named_uint("burn_skipped           ", handler.callCounts("burn_skipped"));
        emit log_named_uint("burn_revert            ", handler.callCounts("burn_revert"));
        emit log_named_uint("bForNon                ", handler.callCounts("bForNon"));
        emit log_named_uint("bForNon_skipped        ", handler.callCounts("bForNon_skipped"));
        emit log_named_uint("bForNon_revert         ", handler.callCounts("bForNon_revert"));
        emit log_named_uint("rebase_positive        ", handler.callCounts("rebase_positive"));
        emit log_named_uint("rebase_negative        ", handler.callCounts("rebase_negative"));
        emit log_named_uint("rebase_revert          ", handler.callCounts("rebase_revert"));
        emit log_named_uint("rebaseExtreme          ", handler.callCounts("rebaseExtreme"));
        emit log_named_uint("donate                 ", handler.callCounts("donate"));
        emit log_named_uint("drain                  ", handler.callCounts("drain"));
        emit log_named_uint("inflate                ", handler.callCounts("inflate"));
        emit log_named_uint("drainShares            ", handler.callCounts("drainShares"));
        emit log_named_uint("segClaim               ", handler.callCounts("segClaim"));
        emit log_named_uint("segClaim_skipped       ", handler.callCounts("segClaim_skipped"));
        emit log_named_uint("pause_lp               ", handler.callCounts("pause_lp"));
        emit log_named_uint("unpause_lp             ", handler.callCounts("unpause_lp"));
        emit log_named_uint("bootstrapExempt        ", handler.ghost_bootstrapExemptHits());
        emit log_named_uint("modifier_revert        ", handler.ghost_modifierRevertCount());
        emit log_named_uint("weeth_hook_revert      ", handler.ghost_weethHookRevertCount());
        emit log_named_uint("panic_revert           ", handler.ghost_panicRevertCount());
    }
}
