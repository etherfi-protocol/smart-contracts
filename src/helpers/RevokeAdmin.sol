// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "../interfaces/IRoleRegistry.sol";

contract Blacklister is Initializable, UUPSUpgradeable {
    IRoleRegistry public immutable roleRegistry;

    error IncorrectRole();

    constructor(address _roleRegistry) {
        roleRegistry = IRoleRegistry(_roleRegistry);
        _disableInitializers();
    }

    function initialize() external initializer {
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address newImplementation) internal override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }

    function revokePauserUntilRole(address account) external onlyRevokeAdmin {
        roleRegistry.revokeFast(roleRegistry.PAUSE_UNTIL_ROLE(), account);
    }

    function revokeBlacklistUntilRole(address account) external onlyRevokeAdmin {
        roleRegistry.revokeFast(roleRegistry.BLACKLIST_UNTIL_ROLE(), account);
    }

    modifier onlyRevokeAdmin() {
        if (!roleRegistry.hasRole(roleRegistry.REVOKE_ADMIN_ROLE(), msg.sender)) revert IncorrectRole();
        _;
    }
}