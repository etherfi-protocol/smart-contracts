// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable, Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {EnumerableRoles} from "solady/auth/EnumerableRoles.sol";

/// @title RoleRegistry - An upgradeable role-based access control system
/// @notice Provides functionality for managing and querying roles with enumeration capabilities
/// @dev Implements UUPS upgradeability pattern and uses Solady's EnumerableRoles for efficient role management
/// @author EtherFi
contract RoleRegistry is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable, EnumerableRoles {
    //--------------------------------------------------------------------------------------
    //-----------------------------------  IMMUTABLES  -------------------------------------
    //--------------------------------------------------------------------------------------
    address public immutable revokeAdmin;

    //--------------------------------------------------------------------------------------
    //-----------------------------------  CONSTANTS  --------------------------------------
    //--------------------------------------------------------------------------------------
    bytes32 public constant UPGRADE_TIMELOCK_ROLE = keccak256("UPGRADE_TIMELOCK_ROLE"); // 10 day timelock
    bytes32 public constant OPERATION_TIMELOCK_ROLE = keccak256("OPERATION_TIMELOCK_ROLE"); // 2 day timelock
    bytes32 public constant OPERATION_MULTISIG_ROLE = keccak256("OPERATION_MULTISIG_ROLE"); // 4 of 7 multisig
    bytes32 public constant SUPER_GUARDIAN_ROLE = keccak256("SUPER_GUARDIAN_ROLE"); // Guardian role for pausing eeth/weeth token transfers
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE"); // hypernative and EOA keys for emergency pausing and blacklisting
    bytes32 public constant ORACLE_OPERATIONS_ROLE = keccak256("ORACLE_OPERATIONS_ROLE"); // Oracle operations role
    bytes32 public constant HOUSEKEEPING_OPERATIONS_ROLE = keccak256("HOUSEKEEPING_OPERATIONS_ROLE"); // Housekeeping operations role
    bytes32 public constant EXECUTOR_OPERATIONS_ROLE = keccak256("EXECUTOR_OPERATIONS_ROLE"); // Executor operations role
    bytes32 public constant EIGENPOD_OPERATIONS_ROLE = keccak256("EIGENPOD_OPERATIONS_ROLE"); // Eigenpod operations role

    //--------------------------------------------------------------------------------------
    //-----------------------------------  ERRORS  -----------------------------------------
    //--------------------------------------------------------------------------------------
    error OnlyUpgradeTimelock();
    error OnlyOperatingTimelock();
    error OnlyOperatingMultisig();
    error OnlySuperGuardian();
    error OnlyGuardian();
    error OnlyOracleOperations();
    error OnlyHousekeepingOperations();
    error OnlyExecutorOperations();
    error OnlyEigenpodOperations();
    error OnlyRevokeAdmin();
    error InvalidRoleToRevoke();
    error AddressZero();

    //--------------------------------------------------------------------------------------
    //-----------------------------------  CONSTRUCTOR  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Constructor
     * @param _revokeAdmin The address of the revoke admin
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _revokeAdmin) {
        if (_revokeAdmin == address(0)) revert AddressZero();
        revokeAdmin = _revokeAdmin;
        _disableInitializers();
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  INITIALIZER  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Initialize the contract
     * @param _owner The address of the owner
     */
    function initialize(address _owner) public initializer {
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        _transferOwnership(_owner);
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  ROLE FUNCTIONS  --------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Grants a role to an account
     * @param role The role to grant (as bytes32)
     * @param account The address to grant the role to
     * @dev Only callable by the contract owner (handled in setRole function)
     */
    function grantRole(bytes32 role, address account) public {
        setRole(account, uint256(role), true);  
    } 

    /**
     * @notice Revokes a role from an account
     * @param role The role to revoke (as bytes32)
     * @param account The address to revoke the role from
     * @dev Only callable by the contract owner (handled in setRole function)
     */
    function revokeRole(bytes32 role, address account) public {
        setRole(account, uint256(role), false);  
    }

    /**
     * @notice Revokes a role from an account quickly
     * @param role The role to revoke (as bytes32)
     * @param account The address to revoke the role from
     * reverts with OnlyRevokeAdmin if the caller is not the revoke admin
     * reverts with InvalidRoleToRevoke if the role is the upgrade timelock, operating timelock, or operating multisig
     */
    function revokeFast(bytes32 role, address account) public {
        if (msg.sender != revokeAdmin) revert OnlyRevokeAdmin();
        if (role == UPGRADE_TIMELOCK_ROLE || role == OPERATION_TIMELOCK_ROLE || role == OPERATION_MULTISIG_ROLE) revert InvalidRoleToRevoke();
        _setRole(account, uint256(role), false);
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  GETTERS  ----------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Checks if an account has any of the specified roles
     * @param account The address to check roles for
     * @param encodedRoles ABI encoded roles (abi.encode(ROLE_1, ROLE_2, ...))
     * @dev Reverts if the account doesn't have at least one of the roles
     */
    function checkRoles(address account, bytes memory encodedRoles) public view {
        if (!_hasAnyRoles(account, encodedRoles)) __revertEnumerableRolesUnauthorized();
    }   

    /**
     * @notice Checks if an account has a specific role
     * @param role The role to check (as bytes32)
     * @param account The address to check the role for
     * @return bool True if the account has the role, false otherwise
     */
    function hasRole(bytes32 role, address account) public view returns (bool) {
        return hasRole(account, uint256(role));
    }

    /**
     * @notice Returns the maximum allowed role value
     * @dev This is used by EnumerableRoles._validateRole to ensure roles are within valid range
     * @return The maximum role value
     */
    function MAX_ROLE() public pure returns (uint256) {
        return type(uint256).max;
    }

    /**
     * @notice Gets all addresses that have a specific role
     * @dev Wrapper around EnumerableRoles roleHolders function converting bytes32 to uint256
     * @param role The role to query (as bytes32)
     * @return The addresses that have the specified role
     */
    function roleHolders(bytes32 role) public view returns (address[] memory) {
        return roleHolders(uint256(role));
    }

    /**
     * @notice Checks if an account is the upgrade timelock
     * @dev Reverts if the account is not the upgrade timelock
     * @param account The address to check
     */
    function onlyUpgradeTimelock(address account) public view {
        if (!hasRole(UPGRADE_TIMELOCK_ROLE, account)) revert OnlyUpgradeTimelock();
    }

    /**
     * @notice Checks if an account is the operating timelock
     * @dev Reverts if the account is not the operating timelock
     * @param account The address to check
     */
    function onlyOperatingTimelock(address account) public view {
        if (!hasRole(OPERATION_TIMELOCK_ROLE, account)) revert OnlyOperatingTimelock();
    }

    /**
     * @notice Checks if an account is the operating multisig
     * @dev Reverts if the account is not the operating multisig
     * @param account The address to check
     */
    function onlyOperatingMultisig(address account) public view {
        if (!hasRole(OPERATION_MULTISIG_ROLE, account)) revert OnlyOperatingMultisig();
    }

    /**
     * @notice Checks if an account is the super guardian
     * @dev Reverts if the account is not the super guardian
     * @param account The address to check
     */
    function onlySuperGuardian(address account) public view {
        if (!hasRole(SUPER_GUARDIAN_ROLE, account)) revert OnlySuperGuardian();
    }

    /**
     * @notice Checks if an account is the guardian
     * @dev Reverts if the account is not the guardian
     * @param account The address to check
     */
    function onlyGuardian(address account) public view {
        if (!hasRole(GUARDIAN_ROLE, account)) revert OnlyGuardian();
    }

    /**
     * @notice Checks if an account is the oracle operations
     * @dev Reverts if the account is not the oracle operations
     * @param account The address to check
     */
    function onlyOracleOperations(address account) public view {
        if (!hasRole(ORACLE_OPERATIONS_ROLE, account)) revert OnlyOracleOperations();
    }

    /**
     * @notice Checks if an account is the housekeeping operations
     * @dev Reverts if the account is not the housekeeping operations
     * @param account The address to check
     */
    function onlyHousekeepingOperations(address account) public view {
        if (!hasRole(HOUSEKEEPING_OPERATIONS_ROLE, account)) revert OnlyHousekeepingOperations();
    }

    /**
     * @notice Checks if an account is the executor operations
     * @dev Reverts if the account is not the executor operations
     * @param account The address to check
     */
    function onlyExecutorOperations(address account) public view {
        if (!hasRole(EXECUTOR_OPERATIONS_ROLE, account)) revert OnlyExecutorOperations();
    }

    /**
     * @notice Checks if an account is the eigenpod operations
     * @dev Reverts if the account is not the eigenpod operations
     * @param account The address to check
     */
    function onlyEigenpodOperations(address account) public view {
        if (!hasRole(EIGENPOD_OPERATIONS_ROLE, account)) revert OnlyEigenpodOperations();
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  INTERNAL FUNCTIONS  -----------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Reverts if the account is not authorized
     */
    function __revertEnumerableRolesUnauthorized() private pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, 0x99152cca) // `EnumerableRolesUnauthorized()`.
            revert(0x1c, 0x04)
        }
    }

    /**
     * @notice Authorize contract upgrades
     * @dev Only callable by the upgrade timelock
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override {
        onlyUpgradeTimelock(msg.sender);
    }
}