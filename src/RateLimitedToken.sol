// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/IEtherFiRateLimiter.sol";
import "./interfaces/IRoleRegistry.sol";

/// @title  RateLimitedToken
/// @notice Token-side surface for the per-address rate-limit feature on EtherFiRateLimiter.
///         Holds the rate-limiter + role-registry immutables, the gwei conversion helper, the
///         Guardian/Multisig role modifiers used on the rate-limit entry points, and the six
///         external functions tokens expose to manage per-address buckets. eETH and weETH
///         inherit this so the rate-limit ABI and access-control split stay single-sourced —
///         a future token integration just inherits and gets the same surface for free.
abstract contract RateLimitedToken {
    IEtherFiRateLimiter public immutable rateLimiter;
    IRoleRegistry      public immutable roleRegistry;

    error LengthMismatch();

    constructor(address _rateLimiter, address _roleRegistry) {
        rateLimiter  = IEtherFiRateLimiter(_rateLimiter);
        roleRegistry = IRoleRegistry(_roleRegistry);
    }

    //--------------------------------------------------------------------------
    //                                  Math
    //--------------------------------------------------------------------------

    /// @notice Converts a wei amount to gwei (rounding up), saturating at type(uint64).max.
    /// @dev EtherFiRateLimiter operates in gwei (uint64). Practical token amounts (entire
    ///      ETH supply ≈ 1.2e17 gwei) sit well below the uint64 cap (1.8e19), so saturation
    ///      lets pathological-but-legal upstream callers (e.g. uint128/uint256 deposit paths)
    ///      reach the rate limiter without a SafeCast revert; the limiter then consumes its
    ///      max-conservative cap rather than DoS-ing the caller.
    function toBucketUnit(uint256 amount) internal pure returns (uint64) {
        uint256 gweiAmount = Math.ceilDiv(amount, 1 gwei);
        return gweiAmount > type(uint64).max ? type(uint64).max : uint64(gweiAmount);
    }

    //--------------------------------------------------------------------------
    //                           Guardian entry points
    //--------------------------------------------------------------------------

    /// @notice Guardian: create or tighten a per-user bucket. See EtherFiRateLimiter for
    ///         the tightening invariant (new capacity / refill ≤ current; freeze = `cap=0`).
    function tightenAddressRateLimit(address user, uint64 capacity, uint64 refillRate) external onlyGuardian {
        rateLimiter.tightenAddressLimit(user, capacity, refillRate);
    }

    function tightenAddressRateLimits(
        address[] calldata users,
        uint64[] calldata capacities,
        uint64[] calldata refillRates
    ) external onlyGuardian {
        if (users.length != capacities.length || users.length != refillRates.length) revert LengthMismatch();
        for (uint256 i; i < users.length; ++i) {
            rateLimiter.tightenAddressLimit(users[i], capacities[i], refillRates[i]);
        }
    }

    //--------------------------------------------------------------------------
    //                           Operations entry points
    //--------------------------------------------------------------------------

    /// @notice Operating Multisig: set or update a per-user bucket with no tightening
    ///         constraint — fully resets `remaining` to capacity (unfreeze in one call).
    function setAddressRateLimit(address user, uint64 capacity, uint64 refillRate) external onlyOperations {
        rateLimiter.setAddressLimit(user, capacity, refillRate);
    }

    function setAddressRateLimits(
        address[] calldata users,
        uint64[] calldata capacities,
        uint64[] calldata refillRates
    ) external onlyOperations {
        if (users.length != capacities.length || users.length != refillRates.length) revert LengthMismatch();
        for (uint256 i; i < users.length; ++i) {
            rateLimiter.setAddressLimit(users[i], capacities[i], refillRates[i]);
        }
    }

    /// @notice Operating Multisig: remove a per-user bucket entirely (user returns to unrestricted).
    function deleteAddressRateLimit(address user) external onlyOperations {
        rateLimiter.deleteAddressLimit(user);
    }

    function deleteAddressRateLimits(address[] calldata users) external onlyOperations {
        for (uint256 i; i < users.length; ++i) {
            rateLimiter.deleteAddressLimit(users[i]);
        }
    }

    //--------------------------------------------------------------------------
    //                                Modifiers
    //--------------------------------------------------------------------------

    modifier onlyGuardian() {
        roleRegistry.onlyGuardian(msg.sender);
        _;
    }

    modifier onlyOperations() {
        roleRegistry.onlyOperatingMultisig(msg.sender);
        _;
    }
}
