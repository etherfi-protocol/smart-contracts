// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "../interfaces/IRoleRegistry.sol";

contract RevokeAdmin is Initializable, UUPSUpgradeable {
    IRoleRegistry public immutable roleRegistry;

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

    function revokePauserUntilRole(address account) external onlyAdmin {
        roleRegistry.revokeFast(roleRegistry.GUARDIAN_ROLE(), account);
    }

    function revokeBlacklistUntilRole(address account) external onlyAdmin {
        roleRegistry.revokeFast(roleRegistry.GUARDIAN_ROLE(), account);
    }

    modifier onlyAdmin() {
        roleRegistry.onlyOperatingMultisig(msg.sender);
        _;
    }
}