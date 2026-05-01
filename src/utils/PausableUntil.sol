// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../interfaces/IRoleRegistry.sol";

contract PausableUntil {
    struct PausableUntilStorage {
        uint256 pausedUntil;
        mapping(address => uint256) lastPauseTimestamp;
    }

    bytes32 private constant PAUSABLE_UNTIL_STORAGE_SLOT = 0x2c7e4bc092c2002f0baaf2f47367bc442b098266b43d189dafe4cb25f1e1fea2; // keccak256("pausableUntil.storage")

    function _getPausableUntilStorage() internal pure returns (PausableUntilStorage storage $) {
        assembly {
            $.slot := PAUSABLE_UNTIL_STORAGE_SLOT
        }
    }

    uint256 public constant MAX_PAUSE_DURATION = 1 days;
    uint256 public constant PAUSER_UNTIL_COOLDOWN = 1 days;

    event PausedUntil(uint256 pausedUntil);
    event UnpausedUntil();

    error ContractPausedUntil(uint256 pausedUntil);
    error ContractNotPausedUntil();
    error PauserCooldownStillActive();

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
        if ($.lastPauseTimestamp[msg.sender] + MAX_PAUSE_DURATION + PAUSER_UNTIL_COOLDOWN > block.timestamp) revert PauserCooldownStillActive();
        $.pausedUntil = block.timestamp + MAX_PAUSE_DURATION;
        $.lastPauseTimestamp[msg.sender] = block.timestamp;
        emit PausedUntil($.pausedUntil);
    }

    function _unpauseUntil() internal {
        _requirePausedUntil();
        PausableUntilStorage storage $ = _getPausableUntilStorage();
        $.pausedUntil = 0;
        emit UnpausedUntil();
    }

    modifier whenNotPausedUntil() {
        _requireNotPausedUntil();
        _;
    }
}