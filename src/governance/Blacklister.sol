// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;


import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "@etherfi/governance/utils/RolesLibrary.sol";

contract Blacklister is Initializable, UUPSUpgradeable, RolesLibrary {

    uint256 public constant BLACKLIST_DURATION = 3 days;

    /// @dev Upper bound on a blacklist the Operating Multisig can set instantly.
    ///      Anything longer (including a permanent blacklist) must go through the
    ///      2-day Operation Timelock (`blacklistUserPermanent`), so a single compromised
    ///      multisig cannot permanently and irreversibly freeze a targeted user with no
    ///      auto-recovery. Legitimate permanent blacklists (e.g. sanctions) are still
    ///      possible, just behind the timelock. (Pillar 3: bound a compromised credential.)
    uint256 public constant MAX_MULTISIG_BLACKLIST_DURATION = 90 days;

    mapping(address => uint256) public blacklistedUntil;

    error BlacklistedUser(address user);
    error UserAlreadyBlacklisted(address user);
    error BlacklistDurationTooLong();

    event UserBlacklisted(address user);
    event UserUnblacklisted(address user);
    event UserBlacklistedUntil(address user, uint256 until);

    constructor(address _roleRegistry) RolesLibrary(_roleRegistry) {
        _disableInitializers();
    }

    function initialize() external initializer {
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    function blacklistUserUntil(address user) external onlyGuardian {
        if (blacklistedUntil[user] > block.timestamp) revert UserAlreadyBlacklisted(user);
        blacklistedUntil[user] = block.timestamp + BLACKLIST_DURATION;
        emit UserBlacklistedUntil(user, block.timestamp + BLACKLIST_DURATION);
    }

    /// @notice Operating Multisig blacklists `user` for `until` seconds from now.
    /// @dev Bounded by MAX_MULTISIG_BLACKLIST_DURATION; use `blacklistUserPermanent`
    ///      (timelock) for anything longer or permanent.
    function setBlacklistUntil(address user, uint256 until) external onlyOperatingMultisig {
        if (until > MAX_MULTISIG_BLACKLIST_DURATION) revert BlacklistDurationTooLong();
        blacklistedUntil[user] = block.timestamp + until;
        emit UserBlacklistedUntil(user, block.timestamp + until);
    }

    /// @notice Explicit permanent blacklist (Operating Multisig).
    /// @dev Kept as the deliberate "permanent" verb. NOTE (security review, PR #385):
    ///      consider moving this behind the 2-day Operation Timelock (`onlyAdmin`) so a
    ///      compromised multisig cannot instantly and irreversibly freeze a targeted user
    ///      with no auto-recovery. Left as multisig here pending a product/compliance call,
    ///      since legitimate permanent blacklists (e.g. sanctions) may need to be instant.
    function blacklistUser(address user) external onlyOperatingMultisig {
        blacklistedUntil[user] = type(uint256).max;
        emit UserBlacklisted(user);
    }

    function unblacklistUser(address user) external onlyOperatingMultisig {
        blacklistedUntil[user] = 0;
        emit UserUnblacklisted(user);
    }

    function nonBlacklisted(address user) external view {
        if (blacklistedUntil[user] > block.timestamp) revert BlacklistedUser(user);
    }

    function getImplementation() external view returns (address) { 
        return _getImplementation(); 
    }
}