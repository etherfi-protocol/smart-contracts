// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/math/Math.sol";

import "@etherfi/rate-limiting/interfaces/IEtherFiRateLimiter.sol";

/// @title  RateLimitedToken
/// @notice Token-side helpers for the per-address rate-limit feature on EtherFiRateLimiter.
///         Holds the `rateLimiter` immutable, the gwei conversion helper, and `internal`
///         primitives for the six per-address bucket operations. eETH and weETH inherit
///         this and wrap the internals with their own role-gated `external` functions —
///         this contract intentionally exposes no `external` surface and performs no
///         access control. Access control is the inheriting token's responsibility (via
///         the modifiers in RolesLibrary), so the rate-limit semantics stay single-sourced
///         while role-gating decisions remain co-located with the rest of the token's
///         access model.
abstract contract RateLimitedToken {
    IEtherFiRateLimiter public immutable rateLimiter;

    error LengthMismatch();

    constructor(address _rateLimiter) {
        rateLimiter = IEtherFiRateLimiter(_rateLimiter);
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
    //                        Internal Guardian-side helpers
    //--------------------------------------------------------------------------

    /// @dev Token must gate this to the Guardian. See EtherFiRateLimiter for the
    ///      tightening invariant: new capacity / refill ≤ current; `cap = 0` = freeze.
    ///      Use a length-1 array for the single-user case — there's no separate
    ///      single-address entry point.
    function _tightenAddressRateLimits(
        address[] calldata users,
        uint64[] calldata capacities,
        uint64[] calldata refillRates
    ) internal {
        if (users.length != capacities.length || users.length != refillRates.length) revert LengthMismatch();
        for (uint256 i; i < users.length; ++i) {
            rateLimiter.tightenAddressLimit(users[i], capacities[i], refillRates[i]);
        }
    }

    //--------------------------------------------------------------------------
    //                       Internal Multisig-side helpers
    //--------------------------------------------------------------------------

    /// @dev Token must gate this to the Operating Multisig. Fully resets the bucket
    ///      (`remaining` returns to capacity); this is the unfreeze / raise path.
    function _setAddressRateLimits(
        address[] calldata users,
        uint64[] calldata capacities,
        uint64[] calldata refillRates
    ) internal {
        if (users.length != capacities.length || users.length != refillRates.length) revert LengthMismatch();
        for (uint256 i; i < users.length; ++i) {
            rateLimiter.setAddressLimit(users[i], capacities[i], refillRates[i]);
        }
    }

    /// @dev Token must gate this to the Operating Multisig. Deletes the bucket entirely;
    ///      the user returns to the unrestricted default.
    function _deleteAddressRateLimits(address[] calldata users) internal {
        for (uint256 i; i < users.length; ++i) {
            rateLimiter.deleteAddressLimit(users[i]);
        }
    }
}
