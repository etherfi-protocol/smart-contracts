// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @notice Minimal UUPS implementation used by test setups to pre-deploy proxies
/// before the real implementations (which need other proxy addresses as
/// constructor immutables) can be constructed. Allows any caller to upgrade.
contract PlaceholderImpl is UUPSUpgradeable {
    function _authorizeUpgrade(address) internal pure override {}
}
