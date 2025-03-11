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
    bytes32 public constant PROTOCOL_PAUSER = keccak256("PROTOCOL_PAUSER");
    bytes32 public constant PROTOCOL_UNPAUSER = keccak256("PROTOCOL_UNPAUSER");

    error OnlyProtocolUpgrader();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner) public initializer {
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        _transferOwnership(_owner);
    }

    /// @notice Checks if an account has any of the specified roles
    /// @dev Reverts if the account doesn't have at least one of the roles
    /// @param account The address to check roles for
    /// @param encodedRoles ABI encoded roles (abi.encode(ROLE_1, ROLE_2, ...))
    function checkRoles(address account, bytes memory encodedRoles) public view {
        if (!_hasAnyRoles(account, encodedRoles)) __revertEnumerableRolesUnauthorized();
    }

    /// @notice Checks if an account has a specific role
    /// @param role The role to check (as bytes32)
    /// @param account The address to check the role for
    /// @return bool True if the account has the role, false otherwise
    function hasRole(bytes32 role, address account) public view returns (bool) {
        return hasRole(account, uint256(role));
    }

    /// @notice Grants a role to an account
    /// @dev Only callable by the contract owner (handled in setRole function)
    /// @param role The role to grant (as bytes32)
    /// @param account The address to grant the role to
    function grantRole(bytes32 role, address account) public {
        setRole(account, uint256(role), true);  
    } 

    /// @notice Revokes a role from an account
    /// @dev Only callable by the contract owner (handled in setRole function)
    /// @param role The role to revoke (as bytes32)
    /// @param account The address to revoke the role from
    function revokeRole(bytes32 role, address account) public {
        setRole(account, uint256(role), false);  
    }

    /// @notice Gets all addresses that have a specific role
    /// @dev Wrapper around EnumerableRoles roleHolders function converting bytes32 to uint256
    /// @param role The role to query (as bytes32)
    /// @return address[] Array of addresses that have the specified role
    function roleHolders(bytes32 role) public view returns (address[] memory) {
        return roleHolders(uint256(role));
    }

    function onlyProtocolUpgrader(address account) public view {
        if (owner() != account) revert OnlyProtocolUpgrader();
    }

    function __revertEnumerableRolesUnauthorized() private pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, 0x99152cca) // `EnumerableRolesUnauthorized()`.
            revert(0x1c, 0x04)
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}