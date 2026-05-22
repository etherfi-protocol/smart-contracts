// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../interfaces/IRoleRegistry.sol";

abstract contract RolesLibrary {
    IRoleRegistry public immutable roleRegistry;

    constructor(address _roleRegistry) {
        roleRegistry = IRoleRegistry(_roleRegistry);
    }

    modifier onlyUpgradeTimelock() {
        roleRegistry.onlyUpgradeTimelock(msg.sender);
        _;
    }

    modifier onlyAdmin() {
        roleRegistry.onlyOperatingTimelock(msg.sender);
        _;
    }

    modifier onlyOperatingMultisig() {
        roleRegistry.onlyOperatingMultisig(msg.sender);
        _;
    }

    modifier onlySuperGuardian() {
        roleRegistry.onlySuperGuardian(msg.sender);
        _;
    }

    modifier onlyGuardian() {
        roleRegistry.onlyGuardian(msg.sender);
        _;
    }

    modifier onlyOracleOperations() {
        roleRegistry.onlyOracleOperations(msg.sender);
        _;
    }

    modifier onlyHousekeepingOperations() {
        roleRegistry.onlyHousekeepingOperations(msg.sender);
        _;
    }

    modifier onlyExecutorOperations() {
        roleRegistry.onlyExecutorOperations(msg.sender);
        _;
    }

    modifier onlyEigenpodOperations() {
        roleRegistry.onlyEigenpodOperations(msg.sender);
        _;
    }

    function _onlyProtocolUpgrader() internal view {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }
}