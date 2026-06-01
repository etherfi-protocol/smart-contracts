// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@etherfi/governance/interfaces/IRoleRegistry.sol";

abstract contract RolesLibrary {
    //--------------------------------------------------------------------------------------
    //-----------------------------------  IMMUTABLES  -------------------------------------
    //--------------------------------------------------------------------------------------
    IRoleRegistry public immutable roleRegistry;

    //--------------------------------------------------------------------------------------
    //-----------------------------------  CONSTRUCTOR  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Constructor
     * @param _roleRegistry The address of the role registry
     */
    constructor(address _roleRegistry) {
        roleRegistry = IRoleRegistry(_roleRegistry);
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Modifier to check if the caller is the upgrade timelock
     * @dev reverts with OnlyUpgradeTimelock if the caller is not the upgrade timelock
     */
    modifier onlyUpgradeTimelock() {
        roleRegistry.onlyUpgradeTimelock(msg.sender);
        _;
    }

    /**
     * @notice Modifier to check if the caller is the operating timelock
     * @dev reverts with OnlyOperatingTimelock if the caller is not the operating timelock
     */
    modifier onlyAdmin() {
        roleRegistry.onlyOperatingTimelock(msg.sender);
        _;
    }

    /**
     * @notice Modifier to check if the caller is the operating multisig
     * @dev reverts with OnlyOperatingMultisig if the caller is not the operating multisig
     */
    modifier onlyOperatingMultisig() {
        roleRegistry.onlyOperatingMultisig(msg.sender);
        _;
    }

    /**
     * @notice Modifier to check if the caller is the super guardian
     * @dev reverts with OnlySuperGuardian if the caller is not the super guardian
     */
    modifier onlySuperGuardian() {
        roleRegistry.onlySuperGuardian(msg.sender);
        _;
    }

    /**
     * @notice Modifier to check if the caller is the guardian
     * @dev reverts with OnlyGuardian if the caller is not the guardian
     */
    modifier onlyGuardian() {
        roleRegistry.onlyGuardian(msg.sender);
        _;
    }

    /**
     * @notice Modifier to check if the caller is the oracle operations
     * @dev reverts with OnlyOracleOperations if the caller is not the oracle operations
     */
    modifier onlyOracleOperations() {
        roleRegistry.onlyOracleOperations(msg.sender);
        _;
    }

    /**
     * @notice Modifier to check if the caller is the housekeeping operations
     * @dev reverts with OnlyHousekeepingOperations if the caller is not the housekeeping operations
     */
    modifier onlyHousekeepingOperations() {
        roleRegistry.onlyHousekeepingOperations(msg.sender);
        _;
    }

    /**
     * @notice Modifier to check if the caller is the executor operations
     * @dev reverts with OnlyExecutorOperations if the caller is not the executor operations
     */
    modifier onlyExecutorOperations() {
        roleRegistry.onlyExecutorOperations(msg.sender);
        _;
    }

    /**
     * @notice Modifier to check if the caller is the eigenpod operations
     * @dev reverts with OnlyEigenpodOperations if the caller is not the eigenpod operations
     */
    modifier onlyEigenpodOperations() {
        roleRegistry.onlyEigenpodOperations(msg.sender);
        _;
    }
}