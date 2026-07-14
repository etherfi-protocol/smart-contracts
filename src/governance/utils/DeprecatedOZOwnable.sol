// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/utils/ContextUpgradeable.sol";

/**
 * @title DeprecatedOZOwnable
 * @notice Storage-layout placeholder that reproduces the exact storage footprint of
 *         OpenZeppelin's `OwnableUpgradeable` so an already-deployed proxy's layout is
 *         preserved after migrating ownership to the custom {Ownable} base.
 * @dev    Inherit this in the exact position where `OwnableUpgradeable` used to sit.
 *         OZ's `OwnableUpgradeable is Initializable, ContextUpgradeable` and declares
 *         `address _owner` + `uint256[49] __gap`. We mirror that here — including the
 *         `ContextUpgradeable` base, which contributes its own `uint256[50]` gap. Where the
 *         inheriting contract already pulls in `ContextUpgradeable` elsewhere (e.g. via
 *         `OwnableUpgradeable`) it collapses to a single shared instance, exactly as it did
 *         under OZ. Do not use any of this; it exists solely to keep storage slots stable.
 */
abstract contract DeprecatedOZOwnable is Initializable, ContextUpgradeable {
    address private _owner;
    uint256[49] private __gap;
}
