// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin-upgradeable/contracts/access/AccessControlUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

contract RoleRegistry is AccessControlUpgradeable, UUPSUpgradeable, Ownable2StepUpgradeable {


    //--------------------------------------------------------------------------------------
    //-------------------------------  PROTOCOL ROLES  -------------------------------------
    //--------------------------------------------------------------------------------------

    // TODO: what is the base set we want here?
    // We can always create more directly without declaring them here via `grantRole`
    bytes32 public constant PROTOCOL_PAUSER = keccak256("PROTOCOL_PAUSER");
    bytes32 public constant PROTOCOL_UNPAUSER = keccak256("PROTOCOL_UNPAUSER");
    bytes32 public constant PROTOCOL_UPGRADER = keccak256("PROTOCOL_UPGRADER");

    //--------------------------------------------------------------------------------------
    //-------------------------------  INITIALIZATION   ------------------------------------
    //--------------------------------------------------------------------------------------

    constructor() {
        _disableInitializers();
    }

    function initialize(address _superAdmin) external initializer {
        _grantRole(DEFAULT_ADMIN_ROLE, _superAdmin);

        __UUPSUpgradeable_init();
        __Ownable_init();
    }

    //--------------------------------------------------------------------------------------
    //------------------------------------  ADMIN ------------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice sets the target role to be managed by another role
    /// @dev only the overall admin has the ability to update role admins
    /// @param _targetRole is the role you are changing the admin of
    /// @param _adminRole is the role that will be the new admin of the _targetRole
    function setRoleAdmin(bytes32 _targetRole, bytes32 _adminRole) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRoleAdmin(_targetRole, _adminRole);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

}
