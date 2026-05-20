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

    function revokeGuardianRole(address account) external onlyOperations {
        roleRegistry.revokeFast(roleRegistry.GUARDIAN_ROLE(), account);
    }

    function revokeEOA1Role(address account) external onlyOperations {
        roleRegistry.revokeFast(roleRegistry.EOA_1(), account);
    }

    function revokeEOA2Role(address account) external onlyOperations {
        roleRegistry.revokeFast(roleRegistry.EOA_2(), account);
    }

    function revokeEOA3Role(address account) external onlyOperations {
        roleRegistry.revokeFast(roleRegistry.EOA_3(), account);
    }

    function revokeEOA4Role(address account) external onlyOperations {
        roleRegistry.revokeFast(roleRegistry.EOA_4(), account);
    }

    modifier onlyOperations() {
        roleRegistry.onlyOperatingMultisig(msg.sender);
        _;
    }
}