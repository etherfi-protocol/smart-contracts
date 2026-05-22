// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IRoleRegistry
 * @notice Interface for the RoleRegistry contract
 * @dev Defines the external interface for RoleRegistry with role management functions
 * @author ether.fi
 */
interface IRoleRegistry {
    /**
     * @dev Error thrown when a function is called by an account without the protocol upgrader role
     */
    error OnlyProtocolUpgrader();

    /**
     * @dev Error thrown when a function is called by an account without the upgrade timelock role
     */
    error OnlyUpgradeTimelock();

    /**
     * @notice Returns the maximum allowed role value
     * @dev This is used by EnumerableRoles._validateRole to ensure roles are within valid range
     * @return The maximum role value
     */
    function MAX_ROLE() external pure returns (uint256);

    /**
     * @notice Initializes the contract with the specified owner
     * @param _owner The address that will be set as the initial owner
     */
    function initialize(address _owner) external;

    /**
     * @notice Checks if an account has any of the specified roles
     * @dev Reverts if the account doesn't have at least one of the roles
     * @param account The address to check roles for
     * @param encodedRoles ABI encoded roles (abi.encode(ROLE_1, ROLE_2, ...))
     */
    function checkRoles(address account, bytes memory encodedRoles) external view;

    /**
     * @notice Checks if an account has a specific role
     * @param role The role to check (as bytes32)
     * @param account The address to check the role for
     * @return bool True if the account has the role, false otherwise
     */
    function hasRole(bytes32 role, address account) external view returns (bool);

    /**
     * @notice Grants a role to an account
     * @dev Only callable by the contract owner
     * @param role The role to grant (as bytes32)
     * @param account The address to grant the role to
     */
    function grantRole(bytes32 role, address account) external;

    /**
     * @notice Revokes a role from an account
     * @dev Only callable by the contract owner
     * @param role The role to revoke (as bytes32)
     * @param account The address to revoke the role from
     */
    function revokeRole(bytes32 role, address account) external;

    /**
     * @notice Revokes a role from an account quickly
     * @dev Only callable by the revoke admin
     * @param role The role to revoke (as bytes32)
     * @param account The address to revoke the role from
     */
    function revokeFast(bytes32 role, address account) external;

    /**
     * @notice Gets all addresses that have a specific role
     * @dev Wrapper around EnumerableRoles roleHolders function
     * @param role The role to query (as bytes32)
     * @return Array of addresses that have the specified role
     */
    function roleHolders(bytes32 role) external view returns (address[] memory);

    /**
     * @notice Checks if an account is the protocol upgrader
     * @dev Reverts if the account is not the protocol upgrader
     * @param account The address to check
     */
    function onlyProtocolUpgrader(address account) external view;

    /**
     * @notice Checks if an account is the upgrade timelock
     * @dev Reverts if the account is not the upgrade timelock
     * @param account The address to check
     */
    function onlyUpgradeTimelock(address account) external view;

    /**
     * @notice Checks if an account is the operating timelock
     * @dev Reverts if the account is not the operating timelock
     * @param account The address to check
     */
    function onlyOperatingTimelock(address account) external view;

    /**
     * @notice Checks if an account is the operating multisig
     * @dev Reverts if the account is not the operating multisig
     * @param account The address to check
     */
    function onlyOperatingMultisig(address account) external view;

    /**
     * @notice Checks if an account is the super guardian
     * @dev Reverts if the account is not the super guardian
     * @param account The address to check
     */
    function onlySuperGuardian(address account) external view;

    /**
     * @notice Checks if an account is the guardian
     * @dev Reverts if the account is not the guardian
     * @param account The address to check
     */
    function onlyGuardian(address account) external view;

    /**
     * @notice Checks if an account is the oracle operations
     * @dev Reverts if the account is not the oracle operations
     * @param account The address to check
     */
    function onlyOracleOperations(address account) external view;

    /**
     * @notice Checks if an account is the housekeeping operations
     * @dev Reverts if the account is not the housekeeping operations
     * @param account The address to check
     */
    function onlyHousekeepingOperations(address account) external view;

    /**
     * @notice Checks if an account is the executor operations
     * @dev Reverts if the account is not the executor operations
     * @param account The address to check
     */
    function onlyExecutorOperations(address account) external view;

    /**
     * @notice Checks if an account is the eigenpod operations
     * @dev Reverts if the account is not the eigenpod operations
     * @param account The address to check
     */
    function onlyEigenpodOperations(address account) external view;

    /**
     * @notice Returns the current owner of the contract
     * @return The address of the current owner
     */
    function owner() external view returns (address);

    function UPGRADE_TIMELOCK_ROLE() external view returns (bytes32);

    function OPERATION_TIMELOCK_ROLE() external view returns (bytes32);

    function OPERATION_MULTISIG_ROLE() external view returns (bytes32);

    function SUPER_GUARDIAN_ROLE() external view returns (bytes32);

    function GUARDIAN_ROLE() external view returns (bytes32);

    function ORACLE_OPERATIONS_ROLE() external view returns (bytes32);
    
    function HOUSEKEEPING_OPERATIONS_ROLE() external view returns (bytes32);

    function EXECUTOR_OPERATIONS_ROLE() external view returns (bytes32);

    function EIGENPOD_OPERATIONS_ROLE() external view returns (bytes32);
}
