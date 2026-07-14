// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;


import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "@etherfi/governance/utils/RolesLibrary.sol";

contract Blacklister is Initializable, UUPSUpgradeable, RolesLibrary {
    //--------------------------------------------------------------------------------------
    //-----------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------
    mapping(address => uint256) public blacklistedUntil;

    //--------------------------------------------------------------------------------------
    //-----------------------------------  CONSTANTS  --------------------------------------
    //--------------------------------------------------------------------------------------
    uint256 public constant BLACKLIST_DURATION = 3 days;

    //--------------------------------------------------------------------------------------
    //-----------------------------------  EVENTS  -----------------------------------------
    //--------------------------------------------------------------------------------------
    event UserBlacklisted(address user);
    event UserUnblacklisted(address user);
    event UserBlacklistedUntil(address user, uint256 until);

    //--------------------------------------------------------------------------------------
    //-----------------------------------  ERRORS  -----------------------------------------
    //--------------------------------------------------------------------------------------
    error InvalidUser();
    error BlacklistedUser(address user);
    error UserAlreadyBlacklisted(address user);

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
    //-------------------------------  BLACKLIST FUNCTIONS  --------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Blacklist a user until a certain timestamp
     * @param user The address of the user to blacklist
     * @dev Only callable by the guardian
     * reverts with UserAlreadyBlacklisted if the user is already blacklisted
     */

    function blacklistUserUntil(address user) external onlyGuardian {
        if (user == address(0)) revert InvalidUser();
        if (blacklistedUntil[user] > block.timestamp) revert UserAlreadyBlacklisted(user);
        blacklistedUntil[user] = block.timestamp + BLACKLIST_DURATION;
        emit UserBlacklistedUntil(user, block.timestamp + BLACKLIST_DURATION);
    }

    /**
     * @notice Set a user's blacklist duration
     * @param user The address of the user to set the blacklist duration for
     * @param until The duration until the user is blacklisted
     * @dev Only callable by the operating multisig
     * reverts with UserAlreadyBlacklisted if the user is already blacklisted
     */
    function setBlacklistUntil(address user, uint256 until) external onlyOperatingMultisig {
        if (user == address(0)) revert InvalidUser();
        blacklistedUntil[user] = block.timestamp + until;
        emit UserBlacklistedUntil(user, block.timestamp + until);
    }

    /**
     * @notice Blacklist a user indefinitely
     * @param user The address of the user to blacklist
     * @dev Only callable by the operating multisig
     * reverts with UserAlreadyBlacklisted if the user is already blacklisted
     */
    function blacklistUser(address user) external onlyOperatingMultisig {
        if (user == address(0)) revert InvalidUser();
        blacklistedUntil[user] = type(uint256).max;
        emit UserBlacklisted(user);
    }

    /**
     * @notice Unblacklist a user
     * @param user The address of the user to unblacklist
     * @dev Only callable by the operating multisig
     * reverts with UserNotBlacklisted if the user is not blacklisted
     */
    function unblacklistUser(address user) external onlyOperatingMultisig {
        blacklistedUntil[user] = 0;
        emit UserUnblacklisted(user);
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  INTERNAL FUNCTIONS  -----------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Authorize contract upgrades
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    //--------------------------------------------------------------------------------------
    //-----------------------------------  GETTERS  ----------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Check if a user is not blacklisted
     * @param user The address of the user to check
     * @dev reverts with BlacklistedUser if the user is blacklisted
     */
    function nonBlacklisted(address user) external view {
        if (blacklistedUntil[user] > block.timestamp) revert BlacklistedUser(user);
    }

    /**
     * @notice Get the implementation address
     * @return The implementation address
     */
    function getImplementation() external view returns (address) { 
        return _getImplementation(); 
    }
}