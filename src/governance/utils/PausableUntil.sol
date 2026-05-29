// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@etherfi/governance/interfaces/IRoleRegistry.sol";

abstract contract PausableUntil {
    struct PausableUntilStorage {
        uint256 pausedUntil;
        uint256 pauseUntilDuration;
        // Cooldown is scoped to this contract (the pause target), NOT to the pauser.
        // Per-pauser scoping let a second pauser key bypass the cooldown and keep the
        // contract paused indefinitely (a "pause war" between rotating keys). A single
        // contract-wide timestamp makes the cooldown apply regardless of who paused.
        uint256 lastPauseTimestamp;
    }

    bytes32 private constant PAUSABLE_UNTIL_STORAGE_SLOT = 0x2c7e4bc092c2002f0baaf2f47367bc442b098266b43d189dafe4cb25f1e1fea2; // keccak256("pausableUntil.storage")

    uint256 public constant MIN_PAUSE_DURATION = 8 hours;
    uint256 public constant MAX_PAUSE_DURATION = 30 days;
    uint256 public constant PAUSER_UNTIL_COOLDOWN = 7 days;

    event PauseUntilDurationSet(uint256 pauseUntilDuration);
    event PausedUntil(uint256 pausedUntil);
    event UnpausedUntil();

    error ContractPausedUntil(uint256 pausedUntil);
    error ContractNotPausedUntil();
    error PauserCooldownStillActive();
    error InvalidPauseUntilDuration();

    function pausedUntil() external view returns (uint256) {
        return _getPausableUntilStorage().pausedUntil;
    }

    function pauseUntilDuration() external view returns (uint256) {
        return _getPausableUntilStorage().pauseUntilDuration;
    }

    function lastPauseTimestamp() external view returns (uint256) {
        return _getPausableUntilStorage().lastPauseTimestamp;
    }

    function _getPausableUntilStorage() internal pure returns (PausableUntilStorage storage $) {
        assembly {
            $.slot := PAUSABLE_UNTIL_STORAGE_SLOT
        }
    }

    function _requireNotPausedUntil() internal view {
        uint256 pausedUntil = _getPausableUntilStorage().pausedUntil;
        if (pausedUntil >= block.timestamp) revert ContractPausedUntil(pausedUntil);
    }

    function _requirePausedUntil() internal view {
        uint256 pausedUntil = _getPausableUntilStorage().pausedUntil;
        if (pausedUntil < block.timestamp) revert ContractNotPausedUntil();
    }

    function _pauseUntil() internal {
        _requireNotPausedUntil();
        PausableUntilStorage storage $ = _getPausableUntilStorage();
        uint256 pauseUntilDuration = $.pauseUntilDuration;
        if ($.lastPauseTimestamp + pauseUntilDuration + PAUSER_UNTIL_COOLDOWN > block.timestamp) revert PauserCooldownStillActive();
        $.pausedUntil = block.timestamp + pauseUntilDuration;
        $.lastPauseTimestamp = block.timestamp;
        emit PausedUntil($.pausedUntil);
    }

    function _unpauseUntil() internal {
        _requirePausedUntil();
        PausableUntilStorage storage $ = _getPausableUntilStorage();
        $.pausedUntil = 0;
        emit UnpausedUntil();
    }

    function _setPauseUntilDuration(uint256 _pauseUntilDuration) internal {
        if (_pauseUntilDuration < MIN_PAUSE_DURATION || _pauseUntilDuration > MAX_PAUSE_DURATION) revert InvalidPauseUntilDuration();
        _getPausableUntilStorage().pauseUntilDuration = _pauseUntilDuration;
        emit PauseUntilDurationSet(_pauseUntilDuration);
    }

    modifier whenNotPausedUntil() {
        _requireNotPausedUntil();
        _;
    }
}