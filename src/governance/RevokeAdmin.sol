// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;


import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "@etherfi/governance/utils/RolesLibrary.sol";
import "@etherfi/governance/interfaces/IRevokeAdmin.sol";

contract RevokeAdmin is Initializable, UUPSUpgradeable, RolesLibrary, IRevokeAdmin {
    //--------------------------------------------------------------------------------------
    //-----------------------------------  CONSTRUCTOR  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Constructor
     * @param _roleRegistry The address of the role registry
     */
    constructor(address _roleRegistry) RolesLibrary(_roleRegistry) {
        _disableInitializers();
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  INITIALIZER  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Initialize the contract
     */
    function initialize() external initializer {
        __UUPSUpgradeable_init();
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  REVOKE FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Revoke the super guardian role from an account
     * @param account The address of the account to revoke the role from
     * @dev Only callable by the operating multisig
     */
    function revokeSuperGuardianRole(address account) external onlyOperatingMultisig {
        _revokeFast(roleRegistry.SUPER_GUARDIAN_ROLE(), account);
    }

    /**
     * @notice Revoke the guardian role from an account
     * @param account The address of the account to revoke the role from
     * @dev Only callable by the operating multisig
     */
    function revokeGuardianRole(address account) external onlyOperatingMultisig {
        _revokeFast(roleRegistry.GUARDIAN_ROLE(), account);
    }

    /**
     * @notice Revoke the oracle operations role from an account
     * @param account The address of the account to revoke the role from
     * @dev Only callable by the operating multisig
     */
    function revokeOracleOperationsRole(address account) external onlyOperatingMultisig {
        _revokeFast(roleRegistry.ORACLE_OPERATIONS_ROLE(), account);
    }

    /**
     * @notice Revoke the housekeeping operations role from an account
     * @param account The address of the account to revoke the role from
     * @dev Only callable by the operating multisig
     */
    function revokeHousekeepingOperationsRole(address account) external onlyOperatingMultisig {
        _revokeFast(roleRegistry.HOUSEKEEPING_OPERATIONS_ROLE(), account);
    }

    /**
     * @notice Revoke the executor operations role from an account
     * @param account The address of the account to revoke the role from
     * @dev Only callable by the operating multisig
     */
    function revokeExecutorOperationsRole(address account) external onlyOperatingMultisig {
        _revokeFast(roleRegistry.EXECUTOR_OPERATIONS_ROLE(), account);
    }

    /**
     * @notice Revoke the eigenpod operations role from an account
     * @param account The address of the account to revoke the role from
     * @dev Only callable by the operating multisig
     */
    function revokeEigenpodOperationsRole(address account) external onlyOperatingMultisig {
        _revokeFast(roleRegistry.EIGENPOD_OPERATIONS_ROLE(), account);
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  INTERNAL FUNCTIONS  -----------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Revoke a role from an account quickly
     * @param role The role to revoke (as bytes32)
     * @param account The address of the account to revoke the role from
     * @dev Only callable by the revoke admin
     */
    function _revokeFast(bytes32 role, address account) internal {
        roleRegistry.revokeFast(role, account);
    }

    /**
     * @notice Authorize contract upgrades
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}
}