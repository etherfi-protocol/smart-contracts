// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "../interfaces/IRoleRegistry.sol";

contract Blacklister is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    IRoleRegistry public immutable roleRegistry;
    bytes32 public constant BLACKLISTER_ROLE = keccak256("BLACKLISTER_ROLE");

    mapping(address => bool) public isBalcklisted;

    error BlacklistedUser(address user);
    error IncorrectRole();

    event UserBlacklisted(address user);
    event UserUnblacklisted(address user);

    constructor(address _roleRegistry) {
        roleRegistry = IRoleRegistry(_roleRegistry);
        _disableInitializers();
    }

    function initialize() external initializer {
        __UUPSUpgradeable_init();
        __Ownable_init();
    }

    function _authorizeUpgrade(address newImplementation) internal override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }

    function blacklistUser(address user) external {
        if (!roleRegistry.hasRole(BLACKLISTER_ROLE, msg.sender)) revert IncorrectRole();
        isBalcklisted[user] = true;
        emit UserBlacklisted(user);
    }

    function unblacklistUser(address user) external {
        if (!roleRegistry.hasRole(BLACKLISTER_ROLE, msg.sender)) revert IncorrectRole();
        isBalcklisted[user] = false;
        emit UserUnblacklisted(user);
    }

    function nonBlacklisted(address user) external view {
        if (isBalcklisted[user]) revert BlacklistedUser(user);
    }

    function getImplementation() external view returns (address) { 
        return _getImplementation(); 
    }
}