// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/StdUtils.sol";
import "forge-std/Vm.sol";

import "@etherfi/governance/rate-limiting/EtherFiRateLimiter.sol";

/// @notice Stateful-invariant handler (fuzz target) for the GENERAL
///         EtherFiRateLimiter — the global-bucket path (createNewLimiter +
///         updateConsumers + consume) plus the admin parameter surface
///         (setCapacity / setRefillRate / setRemaining) and time warps that
///         drive BucketLimiter refill. This is the GLOBAL rate limiter, NOT
///         the redemption-specific BucketRateLimiter already covered by
///         RedemptionManagerHandler.
///
///         I4 — rate-limit budget conservation. The handler is the fuzz
///         target; it whitelists ITSELF as a consumer on a fixed set of
///         buckets and drives consume/refill/parameter ops, maintaining ghost
///         flags that the invariant file asserts NEVER trip:
///
///         (a) remaining/consumable NEVER exceeds capacity (no overfill).
///         (b) consume succeeds IFF canConsume(amount) was true the same block,
///             and a success reduces remaining by EXACTLY `amount` (after the
///             refill that consume applies first).
///         (c) capacity==0 on an existing bucket => consume(amount>=1) always
///             reverts LimitExceeded (freeze semantics).
///         (d) refill is monotonic and bounded: as time passes consumable only
///             increases, capped at capacity.
///         (e) gating: consume reverts UnknownLimit if the bucket does not
///             exist, and InvalidConsumer if the caller is not whitelisted.
///
///         The bucket admin functions are onlyAdmin == onlyOperatingTimelock;
///         the handler pranks `admin`, which holds OPERATION_TIMELOCK_ROLE in
///         TestSetup. `consume` is whenNotPaused only — the handler whitelists
///         itself, so an un-pranked self-call passes the consumer check.
///
///         The per-address bucket API (tightenAddressLimit / setAddressLimit /
///         consumeForAddressIfConfigured) is `onlyToken` (eETH/weETH only) and
///         is intentionally NOT driven here — the handler is not the token
///         proxy, so it cannot reach that surface locally. Those paths share
///         the identical BucketLimiter math proven on the global bucket.
contract RateLimiterHandler is StdUtils {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    EtherFiRateLimiter public immutable rl;
    address public immutable admin;      // holds OPERATION_TIMELOCK_ROLE
    address public immutable stranger;   // never whitelisted on any bucket

    uint256 public constant N_BUCKETS = 4;
    bytes32[N_BUCKETS] public ids;

    /// @dev An id that is never created — used to prove the UnknownLimit gate.
    bytes32 public constant UNKNOWN_ID = keccak256("rate-limiter.unknown.bucket");

    bytes4 internal constant SEL_LIMIT_EXCEEDED   = bytes4(keccak256("LimitExceeded()"));
    bytes4 internal constant SEL_UNKNOWN_LIMIT    = bytes4(keccak256("UnknownLimit()"));
    bytes4 internal constant SEL_INVALID_CONSUMER = bytes4(keccak256("InvalidConsumer()"));

    // ---- Ghost / violation flags (asserted false by the invariant file) -----

    bool public ghost_overfill;                 // remaining/consumable > capacity
    bool public ghost_iffViolated;              // consume success != canConsume(before)
    bool public ghost_exactDecreaseViolated;    // remaining_after != consumable_before - amount
    bool public ghost_freezeViolated;           // cap==0 consume(>=1) did not revert LimitExceeded
    bool public ghost_refillMonotonicViolated;  // consumable decreased as time advanced
    bool public ghost_gatingViolated;           // UnknownLimit / InvalidConsumer gate failed

    // ---- Non-vacuity counters ----------------------------------------------

    uint256 public consume_ok;        // successful real consumes
    uint256 public consume_rejected;  // consume reverted LimitExceeded (budget exhausted)
    bool    public refillObserved;    // a strictly-positive refill was observed

    mapping(bytes32 => uint256) public callCounts;

    constructor(EtherFiRateLimiter _rl, address _admin) {
        rl = _rl;
        admin = _admin;
        stranger = address(uint160(uint256(keccak256("rate-limiter.stranger"))));

        // Bucket 0 is the stable "refill probe": its capacity/refillRate are
        // never mutated, so drain+warp deterministically observes refill.
        // Buckets 1..N-1 are the mutable parameter-fuzz surface.
        for (uint256 i = 0; i < N_BUCKETS; i++) {
            ids[i] = keccak256(abi.encodePacked("rate-limiter.bucket.", i));
            vm.prank(admin);
            // capacity 1e9 gwei, refillRate 1e6 gwei/s — both non-zero so
            // refill is observable and buckets start full (remaining==cap).
            rl.createNewLimiter(ids[i], uint64(1e9), uint64(1e6));
            vm.prank(admin);
            rl.updateConsumers(ids[i], address(this), true);
        }
    }

    // =====================================================================
    // CORE: consume — proves I4(b) IFF + exact-decrease, and I4(a) overfill.
    // =====================================================================

    function act_consume(uint256 bucketSeed, uint64 amount) external {
        bytes32 id = ids[bucketSeed % N_BUCKETS];
        uint64 amt = uint64(bound(uint256(amount), 0, uint256(4e9))); // can exceed cap

        // All three views run at the SAME block.timestamp as the consume that
        // follows, so the in-memory refill they apply is identical to the one
        // consume applies — making the IFF and exact-decrease checks exact.
        bool can = rl.canConsume(id, amt);
        uint64 consumableBefore = rl.consumable(id);
        (uint64 capBefore,,,) = rl.getLimit(id);

        // sanity: consumable never exceeds capacity (refill-bounded)
        if (consumableBefore > capBefore) ghost_overfill = true;

        bool success;
        // msg.sender == address(this), which is whitelisted on every bucket.
        try rl.consume(id, amt) {
            success = true;
            consume_ok++;
            (uint64 capAfter, uint64 remAfter,,) = rl.getLimit(id);
            // I4(a): never overfilled.
            if (remAfter > capAfter) ghost_overfill = true;
            // I4(b) exact decrease: remaining drops by exactly `amount`
            // relative to the refilled remaining (== consumableBefore).
            if (remAfter != consumableBefore - amt) ghost_exactDecreaseViolated = true;
        } catch (bytes memory err) {
            success = false;
            consume_rejected++;
            // The only legitimate failure on an existing, whitelisted,
            // unpaused bucket is LimitExceeded.
            if (_sel(err) != SEL_LIMIT_EXCEEDED) ghost_gatingViolated = true;
        }

        // I4(b) IFF: consume succeeds exactly when canConsume said it could.
        if (success != can) ghost_iffViolated = true;

        callCounts["act_consume"]++;
    }

    // =====================================================================
    // FREEZE: capacity==0 on an existing bucket => consume(>=1) reverts.  I4(c)
    // =====================================================================

    function act_consumeFrozen(uint256 bucketSeed, uint64 amount) external {
        // Use a mutable bucket (index >= 1) so the stable probe stays alive.
        uint256 idx = 1 + (bucketSeed % (N_BUCKETS - 1));
        bytes32 id = ids[idx];

        // Freeze it.
        vm.prank(admin);
        rl.setCapacity(id, 0);

        uint64 amt = uint64(bound(uint256(amount), 1, uint256(type(uint64).max))); // >= 1

        try rl.consume(id, amt) {
            // A non-zero consume on a zero-capacity bucket MUST revert.
            ghost_freezeViolated = true;
        } catch (bytes memory err) {
            if (_sel(err) != SEL_LIMIT_EXCEEDED) ghost_freezeViolated = true;
        }

        // Restore a usable capacity so subsequent ops on this bucket stay live.
        vm.prank(admin);
        rl.setCapacity(id, uint64(1e9));
        callCounts["act_consumeFrozen"]++;
    }

    // =====================================================================
    // REFILL: monotonic + bounded across time.  I4(d) (+ non-vacuity).
    // =====================================================================

    /// @notice Drains the stable probe bucket (0), warps, and asserts
    ///         consumable strictly increases (refill happened) and stays
    ///         capped at capacity. Deterministically exercises real refill.
    function act_drainAndRefill(uint16 secondsSeed) external {
        bytes32 id = ids[0];
        uint64 c = rl.consumable(id);
        if (c > 0) {
            try rl.consume(id, c) { consume_ok++; } catch { }
        }
        (uint64 cap,, uint64 rate,) = rl.getLimit(id);
        uint64 before = rl.consumable(id);

        uint256 dt = bound(uint256(secondsSeed), 1, 600);
        vm.warp(block.timestamp + dt);

        uint64 afterC = rl.consumable(id);
        // I4(d): monotonic — never decreases as time advances.
        if (afterC < before) ghost_refillMonotonicViolated = true;
        // I4(a)/(d): bounded by capacity.
        if (afterC > cap) ghost_overfill = true;
        // Non-vacuity: a real, strictly-positive refill occurred.
        if (rate > 0 && afterC > before) refillObserved = true;

        callCounts["act_drainAndRefill"]++;
    }

    /// @notice Advances time and checks monotonicity/boundedness across ALL
    ///         buckets at their current (fuzzed) parameters.
    function act_advanceTime(uint16 secondsSeed) external {
        uint64[N_BUCKETS] memory before;
        for (uint256 i = 0; i < N_BUCKETS; i++) before[i] = rl.consumable(ids[i]);

        uint256 dt = bound(uint256(secondsSeed), 1, 3600);
        vm.warp(block.timestamp + dt);

        for (uint256 i = 0; i < N_BUCKETS; i++) {
            (uint64 cap,, uint64 rate,) = rl.getLimit(ids[i]);
            uint64 afterC = rl.consumable(ids[i]);
            if (afterC < before[i]) ghost_refillMonotonicViolated = true;
            if (afterC > cap) ghost_overfill = true;
            if (rate > 0 && afterC > before[i]) refillObserved = true;
        }
        callCounts["act_advanceTime"]++;
    }

    // =====================================================================
    // GATING: UnknownLimit + InvalidConsumer.  I4(e)
    // =====================================================================

    function act_consumeUnknown(uint64 amount) external {
        uint64 amt = uint64(bound(uint256(amount), 0, uint256(type(uint64).max)));
        try rl.consume(UNKNOWN_ID, amt) {
            ghost_gatingViolated = true; // a non-existent bucket must revert
        } catch (bytes memory err) {
            if (_sel(err) != SEL_UNKNOWN_LIMIT) ghost_gatingViolated = true;
        }
        callCounts["act_consumeUnknown"]++;
    }

    function act_consumeUnwhitelisted(uint256 bucketSeed, uint64 amount) external {
        bytes32 id = ids[bucketSeed % N_BUCKETS];
        uint64 amt = uint64(bound(uint256(amount), 0, uint256(type(uint64).max)));
        // `stranger` is never added as a consumer on any bucket.
        vm.prank(stranger);
        try rl.consume(id, amt) {
            ghost_gatingViolated = true; // non-whitelisted caller must revert
        } catch (bytes memory err) {
            if (_sel(err) != SEL_INVALID_CONSUMER) ghost_gatingViolated = true;
        }
        callCounts["act_consumeUnwhitelisted"]++;
    }

    // =====================================================================
    // ADMIN parameter surface — evolves state the bucket math depends on.
    // Targets mutable buckets (index >= 1); bucket 0 stays a stable probe.
    // =====================================================================

    function act_setCapacity(uint256 bucketSeed, uint64 capSeed) external {
        uint256 idx = 1 + (bucketSeed % (N_BUCKETS - 1));
        uint64 cap = uint64(bound(uint256(capSeed), 0, uint256(2e9)));
        vm.prank(admin);
        try rl.setCapacity(ids[idx], cap) { callCounts["act_setCapacity"]++; } catch { }
        _checkBucketBounded(ids[idx]);
    }

    function act_setRefillRate(uint256 bucketSeed, uint64 rateSeed) external {
        uint256 idx = 1 + (bucketSeed % (N_BUCKETS - 1));
        uint64 rate = uint64(bound(uint256(rateSeed), 0, uint256(1e7)));
        vm.prank(admin);
        try rl.setRefillRate(ids[idx], rate) { callCounts["act_setRefillRate"]++; } catch { }
        _checkBucketBounded(ids[idx]);
    }

    function act_setRemaining(uint256 bucketSeed, uint64 remSeed) external {
        uint256 idx = 1 + (bucketSeed % (N_BUCKETS - 1));
        uint64 rem = uint64(bound(uint256(remSeed), 0, uint256(4e9))); // can exceed cap
        vm.prank(admin);
        try rl.setRemaining(ids[idx], rem) { callCounts["act_setRemaining"]++; } catch { }
        // setRemaining caps to capacity — assert it never overfilled.
        _checkBucketBounded(ids[idx]);
    }

    // =====================================================================
    // INTERNALS
    // =====================================================================

    function _checkBucketBounded(bytes32 id) internal {
        (uint64 cap, uint64 rem,,) = rl.getLimit(id);
        if (rem > cap) ghost_overfill = true;
        if (rl.consumable(id) > cap) ghost_overfill = true;
    }

    function _sel(bytes memory err) internal pure returns (bytes4 sel) {
        if (err.length >= 4) {
            assembly { sel := mload(add(err, 32)) }
        }
    }

    // Iterate all buckets for the invariant file's overfill cross-check.
    function bucketId(uint256 i) external view returns (bytes32) { return ids[i]; }
}
