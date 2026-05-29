// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@etherfi/governance/interfaces/IRoleRegistry.sol";

abstract contract PausableUntil {
    struct PausableUntilStorage {
        uint256 pausedUntil;
        uint256 pauseUntilDuration;
        mapping(address => uint256) lastPauseTimestamp;
        // Cooldown end, snapshotted at pause time against the duration in force THEN.
        // Appended field (namespaced fixed-slot storage), so it is layout-safe to add
        // on an upgrade. See `_pauseUntil` for why the snapshot matters (M1/M2).
        mapping(address => uint256) cooldownUntil;
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

    function lastPauseTimestamp(address pauser) external view returns (uint256) {
        return _getPausableUntilStorage().lastPauseTimestamp[pauser];
    }

    /// @notice Timestamp until which `pauser` is on cooldown and cannot pause again.
    /// @dev 0 means never paused (or cooldown elapsed) — the pauser can fire immediately.
    function cooldownUntil(address pauser) external view returns (uint256) {
        return _getPausableUntilStorage().cooldownUntil[pauser];
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
        uint256 duration = $.pauseUntilDuration;
        // Cooldown is snapshotted at pause time. Checking a stored `cooldownUntil` rather
        // than recomputing `lastPauseTimestamp + pauseUntilDuration + COOLDOWN` on each call
        // means:
        //  (M1) a later `setPauseUntilDuration` cannot retroactively shrink or extend an
        //       already-running pauser's cooldown — it is fixed at the duration in force
        //       when the pause was fired.
        //  (M2) a never-paused pauser has `cooldownUntil == 0`, so the first pause always
        //       succeeds regardless of `block.timestamp` (no spurious revert on chains with
        //       a low genesis timestamp).
        if ($.cooldownUntil[msg.sender] > block.timestamp) revert PauserCooldownStillActive();
        $.pausedUntil = block.timestamp + duration;
        $.lastPauseTimestamp[msg.sender] = block.timestamp;
        $.cooldownUntil[msg.sender] = block.timestamp + duration + PAUSER_UNTIL_COOLDOWN;
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