// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title RateLimitMath
/// @notice Shared helpers for converting token amounts to the gwei unit consumed by EtherFiRateLimiter.
/// @dev Extracted out of EETH/WeETH to keep the gwei-conversion + saturation logic in one place;
///      a bug here would otherwise need to be patched in every token that integrates rate limits.
library RateLimitMath {
    /// @notice Converts a wei amount to gwei (rounding up), saturating at type(uint64).max.
    /// @dev EtherFiRateLimiter operates in gwei (uint64). Practical token amounts (entire ETH
    ///      supply ≈ 1.2e17 gwei) sit well below the uint64 cap (1.8e19), so saturation lets
    ///      pathological-but-legal upstream callers (e.g. uint128/uint256 deposit paths) reach
    ///      the rate limiter without a SafeCast revert; the limiter then consumes its max-
    ///      conservative cap rather than DoS-ing the caller.
    function toBucketUnit(uint256 amount) internal pure returns (uint64) {
        uint256 gweiAmount = Math.ceilDiv(amount, 1 gwei);
        return gweiAmount > type(uint64).max ? type(uint64).max : uint64(gweiAmount);
    }
}
