// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

//import "@openzeppelin/contracts/access/AccessControl.sol";
//import "@openzeppelin/contracts/access/AccessControlDefaultAdminRules.sol";
import "@openzeppelin-upgradeable/contracts/access/AccessControlUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

contract RoleRegistry is AccessControlUpgradeable, UUPSUpgradeable, Ownable2StepUpgradeable {

    bytes32 public constant PROTOCOL_PAUSER = keccak256("PROTOCOL_PAUSER");
    bytes32 public constant PROTOCOL_UNPAUSER = keccak256("PROTOCOL_UNPAUSER");

    function initialize(address _superAdmin) external initializer {
        //require(getRoleAdmin(DEFAULT_ADMIN_ROLE()) == address(0x0)
        _grantRole(DEFAULT_ADMIN_ROLE, _superAdmin);

        __UUPSUpgradeable_init();
        __Ownable_init();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

}
