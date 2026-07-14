// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../TestSetup.sol";
import "./handlers/RateLimiterHandler.sol";

/// @notice Stateful invariant suite for the GENERAL EtherFiRateLimiter,
///         proving invariant I4 (rate-limit budget conservation) for the
///         global-bucket path. This is the global rate limiter — distinct
///         from the redemption-specific BucketRateLimiter covered by the
///         RedemptionManager invariant suite.
///
///         The handler (the fuzz target) creates a set of buckets, whitelists
///         itself as a consumer, and drives consume / refill (via warp) /
///         freeze / parameter mutations / gating probes. fail-on-revert is
///         false so legitimate reverts (LimitExceeded when drained, etc.) do
///         not fail the run; every I4 sub-property is asserted as a ghost flag
///         that must NEVER trip, plus a non-vacuity check in afterInvariant().
///
///         Only the handler's `act_*` functions are fuzzed (selector-targeted)
///         so the fuzzer spends its budget on real rate-limiter actions.
///
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = false
/// forge-config: default.invariant.call-override = false
contract RateLimiterInvariantTest is TestSetup {
    RateLimiterHandler internal handler;

    function setUp() public {
        setUpTests();

        // `admin` holds OPERATION_TIMELOCK_ROLE (== onlyAdmin) in TestSetup.
        handler = new RateLimiterHandler(rateLimiterInstance, admin);

        // Restrict the fuzzer to the handler's action functions only — no
        // view getters, no constructor-style helpers — so the run exercises
        // real consume/refill/parameter ops (non-vacuity).
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.act_consume.selector;
        selectors[1] = handler.act_consumeFrozen.selector;
        selectors[2] = handler.act_drainAndRefill.selector;
        selectors[3] = handler.act_advanceTime.selector;
        selectors[4] = handler.act_consumeUnknown.selector;
        selectors[5] = handler.act_consumeUnwhitelisted.selector;
        selectors[6] = handler.act_setCapacity.selector;
        selectors[7] = handler.act_setRefillRate.selector;
        selectors[8] = handler.act_setRemaining.selector;
        selectors[9] = handler.act_revokeConsumer.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // =====================================================================
    // I4(a) — a bucket's remaining/consumable NEVER exceeds its capacity.
    // =====================================================================
    function invariant_I4a_remaining_never_exceeds_capacity() public view {
        assertFalse(handler.ghost_overfill(), "I4(a): remaining/consumable exceeded capacity (overfill)");
        // Independent end-of-run cross-check across every bucket.
        for (uint256 i = 0; i < handler.N_BUCKETS(); i++) {
            bytes32 id = handler.bucketId(i);
            (uint64 cap, uint64 rem,,) = rateLimiterInstance.getLimit(id);
            assertLe(rem, cap, "I4(a): on-chain remaining > capacity");
            assertLe(rateLimiterInstance.consumable(id), cap, "I4(a): on-chain consumable > capacity");
        }
    }

    // =====================================================================
    // I4(b) — consume succeeds IFF canConsume(amount) was true just before,
    //          and a success reduces remaining by EXACTLY `amount`.
    // =====================================================================
    function invariant_I4b_consume_iff_canConsume_and_exact_decrease() public view {
        assertFalse(handler.ghost_iffViolated(), "I4(b): consume success != canConsume(before)");
        assertFalse(handler.ghost_exactDecreaseViolated(), "I4(b): consume did not reduce remaining by exactly amount");
    }

    // =====================================================================
    // I4(c) — capacity==0 on an existing bucket => consume reverts LimitExceeded.
    // =====================================================================
    function invariant_I4c_zero_capacity_freezes_consume() public view {
        assertFalse(handler.ghost_freezeViolated(), "I4(c): consume on a frozen (cap==0) bucket did not revert LimitExceeded");
    }

    // =====================================================================
    // I4(d) — refill is monotonic, bounded, and matches the EXACT formula.
    // =====================================================================
    function invariant_I4d_refill_monotonic_and_bounded() public view {
        assertFalse(handler.ghost_refillMonotonicViolated(), "I4(d): consumable decreased as time advanced (non-monotonic refill)");
        // boundedness is folded into ghost_overfill, re-asserted here.
        assertFalse(handler.ghost_overfill(), "I4(d): refill overshot capacity");
        // Exact refill: consumable_after == min(capacity, before + refillRate*dt).
        assertFalse(handler.ghost_refillModelViolated(), "I4(d): refill did not match min(capacity, before + refillRate*dt)");
    }

    // =====================================================================
    // I4(b') — draining exactly `consumable(id)` then consuming it never
    //          reverts (canConsume was true by construction).
    // =====================================================================
    function invariant_I4b_drain_boundary_consume_succeeds() public view {
        assertFalse(handler.ghost_drainConsumeReverted(), "I4(b'): consume(consumable(id)) reverted despite canConsume==true");
    }

    // =====================================================================
    // I4(e) — gating: UnknownLimit if no bucket, InvalidConsumer if not
    //          whitelisted, and consumer revocation/re-grant behaves exactly.
    // =====================================================================
    function invariant_I4e_unknown_and_consumer_gating() public view {
        assertFalse(handler.ghost_gatingViolated(), "I4(e): UnknownLimit / InvalidConsumer gating failed");
        assertFalse(handler.ghost_revokeViolated(), "I4(e): revoked consumer succeeded, or re-grant failed to restore consume");
    }

    // =====================================================================
    // I4(f) — the admin setters land on their EXACT documented post-state and
    //          never revert on valid inputs.
    // =====================================================================
    function invariant_I4f_setter_exact_post_state() public view {
        assertFalse(handler.ghost_setterPostStateViolated(), "I4(f): a setter's post-state != documented clamp result");
        assertFalse(handler.ghost_setterReverted(), "I4(f): a setter with valid inputs + admin role reverted");
    }

    // =====================================================================
    // Non-vacuity: the fuzzer must have exercised real consume + refill.
    // =====================================================================
    function afterInvariant() public {
        emit log_named_uint("consume_ok               ", handler.consume_ok());
        emit log_named_uint("consume_rejected         ", handler.consume_rejected());
        emit log_named_uint("act_consume              ", handler.callCounts("act_consume"));
        emit log_named_uint("act_consumeFrozen        ", handler.callCounts("act_consumeFrozen"));
        emit log_named_uint("act_drainAndRefill       ", handler.callCounts("act_drainAndRefill"));
        emit log_named_uint("act_advanceTime          ", handler.callCounts("act_advanceTime"));
        emit log_named_uint("act_consumeUnknown       ", handler.callCounts("act_consumeUnknown"));
        emit log_named_uint("act_consumeUnwhitelisted ", handler.callCounts("act_consumeUnwhitelisted"));
        emit log_named_uint("act_setCapacity          ", handler.callCounts("act_setCapacity"));
        emit log_named_uint("act_setRefillRate        ", handler.callCounts("act_setRefillRate"));
        emit log_named_uint("act_setRemaining         ", handler.callCounts("act_setRemaining"));
        emit log_named_uint("act_revokeConsumer       ", handler.callCounts("act_revokeConsumer"));

        assertGt(handler.consume_ok(), 0, "non-vacuity: no successful (amount>0) consume was ever exercised");
        assertTrue(handler.refillObserved(), "non-vacuity: no real (strictly-positive) refill was ever observed");

        // Probe coverage: each deterministic-outcome probe must have run this
        // run, otherwise its ghost flag is vacuously false. With depth 128 over
        // 10 selectors each expects ~13 calls, so > 0 holds comfortably.
        assertGt(handler.callCounts("act_consumeFrozen"), 0, "coverage: freeze probe never ran");
        assertGt(handler.callCounts("act_consumeUnknown"), 0, "coverage: UnknownLimit probe never ran");
        assertGt(handler.callCounts("act_consumeUnwhitelisted"), 0, "coverage: InvalidConsumer probe never ran");
        assertGt(handler.callCounts("act_revokeConsumer"), 0, "coverage: consumer-revocation probe never ran");
        assertGt(handler.callCounts("act_setCapacity"), 0, "coverage: setCapacity never succeeded");
        assertGt(handler.callCounts("act_setRefillRate"), 0, "coverage: setRefillRate never succeeded");
        assertGt(handler.callCounts("act_setRemaining"), 0, "coverage: setRemaining never succeeded");
    }
}
