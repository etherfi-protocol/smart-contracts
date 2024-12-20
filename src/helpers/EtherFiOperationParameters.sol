// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

contract EtherFiOperationParameters is UUPSUpgradeable, OwnableUpgradeable {
    mapping(string => mapping(address => bool)) public tagAdmins;
    mapping(string => mapping(string => string)) public tagKeyValues;

    event UpdatedAdmin(string tag, address admin, bool allowed);
    event UpdatedKeyValue(string tag, string key, string old_value, string new_value);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
    }

    function updateTagAdmin(string memory tag, address admin, bool allowed) external onlyOwner {
        tagAdmins[tag][admin] = allowed;
     
        emit UpdatedAdmin(tag, admin, allowed);
    }

    function updateTagKeyValue(string memory tag, string memory key, string memory value) external onlyAdmin(tag) {
        string memory old_value = tagKeyValues[tag][key];
        tagKeyValues[tag][key] = value;
     
        emit UpdatedKeyValue(tag, key, old_value, value);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    modifier onlyAdmin(string memory tag) {
        require(tagAdmins[tag][msg.sender], "Only admin can call");
        _;
    }
}