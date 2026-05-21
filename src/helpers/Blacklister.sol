// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;


import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "../interfaces/IRoleRegistry.sol";

contract Blacklister is Initializable, UUPSUpgradeable {
    IRoleRegistry public immutable roleRegistry;

    mapping(address => uint256) public blacklistedUntil;

    error BlacklistedUser(address user);
    error UserAlreadyBlacklisted(address user);

    event UserBlacklisted(address user);
    event UserUnblacklisted(address user);
    event UserBlacklistedUntil(address user, uint256 until);

    constructor(address _roleRegistry) {
        roleRegistry = IRoleRegistry(_roleRegistry);
        _disableInitializers();
    }

    function initialize() external initializer {
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address newImplementation) internal override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }

    function blacklistUserUntil(address user) external onlyGuardian {
        if (blacklistedUntil[user] > block.timestamp) revert UserAlreadyBlacklisted(user);
        blacklistedUntil[user] = block.timestamp + 1 days;
        emit UserBlacklistedUntil(user, block.timestamp + 1 days);
    }

    function setBlacklistUntil(address user, uint256 until) external onlyOperations {
        blacklistedUntil[user] = block.timestamp + until;
        emit UserBlacklistedUntil(user, block.timestamp + until);
    }

    function blacklistUser(address user) external onlyOperations {
        blacklistedUntil[user] = type(uint256).max;
        emit UserBlacklisted(user);
    }

    function unblacklistUser(address user) external onlyOperations {
        blacklistedUntil[user] = 0;
        emit UserUnblacklisted(user);
    }

    function nonBlacklisted(address user) external view {
        if (blacklistedUntil[user] > block.timestamp) revert BlacklistedUser(user);
    }

    function getImplementation() external view returns (address) { 
        return _getImplementation(); 
    }

    modifier onlyOperations() {
        roleRegistry.onlyOperatingMultisig(msg.sender);
        _;
    }

    modifier onlyGuardian() {
        roleRegistry.onlyGuardian(msg.sender);
        _;
    }
}