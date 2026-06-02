// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title DeprecatedOZReentrancyGuard
 * @notice Storage-layout placeholder that reserves the 50 storage slots formerly occupied by
 *         OpenZeppelin's `ReentrancyGuardUpgradeable` (`uint256 _status` + `uint256[49] __gap`).
 * @dev    Inherit this in the exact position where `ReentrancyGuardUpgradeable` used to sit, so
 *         the storage layout of an already-deployed proxy is preserved after migrating the
 *         reentrancy guard to Solady's transient {ReentrancyGuardTransient} (which has no
 *         persistent storage). Declares its own gap independently — it deliberately does NOT
 *         share a base with {DeprecatedOZPausable}, because a shared ancestor would be
 *         deduplicated by C3 linearization and collapse two 50-slot regions into one in any
 *         contract that inherits both. Do not add any state to this contract.
 */
abstract contract DeprecatedOZReentrancyGuard {
    uint256[50] private __gap;
}
