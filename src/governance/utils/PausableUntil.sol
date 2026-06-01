// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@etherfi/governance/interfaces/IRoleRegistry.sol";

abstract contract PausableUntil {
    //--------------------------------------------------------------------------------------
    //------------------------------  STORAGE STRUCT  --------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice PausableUntilStorage
     * @dev Storage for the PausableUntil contract
     * @param pausedUntil The timestamp when the contract is paused until
     * @param pauseUntilDuration The duration for which the contract is paused until
     * @param lastPauseTimestamp The timestamp when the last pause occurred
     */
    struct PausableUntilStorage {
        uint256 pausedUntil;
        uint256 pauseUntilDuration;
        mapping(address => uint256) lastPauseTimestamp;
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  CONSTANTS  --------------------------------------
    //--------------------------------------------------------------------------------------
    bytes32 private constant PAUSABLE_UNTIL_STORAGE_SLOT = 0x2c7e4bc092c2002f0baaf2f47367bc442b098266b43d189dafe4cb25f1e1fea2; // keccak256("pausableUntil.storage")

    uint256 public constant MIN_PAUSE_DURATION = 8 hours;
    uint256 public constant MAX_PAUSE_DURATION = 30 days;
    uint256 public constant PAUSER_UNTIL_COOLDOWN = 7 days;

    //--------------------------------------------------------------------------------------
    //-----------------------------------  EVENTS  -----------------------------------------
    //--------------------------------------------------------------------------------------
    event PauseUntilDurationSet(uint256 pauseUntilDuration);
    event PausedUntil(uint256 pausedUntil);
    event UnpausedUntil();

    //--------------------------------------------------------------------------------------
    //-----------------------------------  ERRORS  -----------------------------------------
    //--------------------------------------------------------------------------------------
    error ContractPausedUntil(uint256 pausedUntil);
    error ContractNotPausedUntil();
    error PauserCooldownStillActive();
    error InvalidPauseUntilDuration();

    //--------------------------------------------------------------------------------------
    //----------------------------  INTERNAL FUNCTIONS  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Get the storage of the PausableUntil contract
     * @return $ The storage of the PausableUntil contract
     */
    function _getPausableUntilStorage() internal pure returns (PausableUntilStorage storage $) {
        assembly {
            $.slot := PAUSABLE_UNTIL_STORAGE_SLOT
        }
    }

    /**
     * @notice Require the contract to be not paused until
     */
    function _requireNotPausedUntil() internal view {
        uint256 _pausedUntil = _getPausableUntilStorage().pausedUntil;
        if (_pausedUntil >= block.timestamp) revert ContractPausedUntil(_pausedUntil);
    }

    /**
     * @notice Require the contract to be paused until
     */
    function _requirePausedUntil() internal view {
        uint256 _pausedUntil = _getPausableUntilStorage().pausedUntil;
        if (_pausedUntil < block.timestamp) revert ContractNotPausedUntil();
    }

    /**
     * @notice Pause the contract until
     * @dev only callable when contract is not paused until and pauser is not in cooldown
     */
    function _pauseUntil() internal {
        _requireNotPausedUntil();
        PausableUntilStorage storage $ = _getPausableUntilStorage();
        uint256 _pauseUntilDuration = $.pauseUntilDuration;
        if ($.lastPauseTimestamp[msg.sender] + _pauseUntilDuration + PAUSER_UNTIL_COOLDOWN > block.timestamp) revert PauserCooldownStillActive();
        $.pausedUntil = block.timestamp + _pauseUntilDuration;
        $.lastPauseTimestamp[msg.sender] = block.timestamp;
        emit PausedUntil($.pausedUntil);
    }

    /**
     * @notice Unpause the contract until
     */
    function _unpauseUntil() internal {
        _requirePausedUntil();
        PausableUntilStorage storage $ = _getPausableUntilStorage();
        $.pausedUntil = 0;
        emit UnpausedUntil();
    }

    /**
     * @notice Set the pause duration for the contract
     * @param _pauseUntilDuration The new pause duration
     */
    function _setPauseUntilDuration(uint256 _pauseUntilDuration) internal {
        if (_pauseUntilDuration < MIN_PAUSE_DURATION || _pauseUntilDuration > MAX_PAUSE_DURATION) revert InvalidPauseUntilDuration();
        _getPausableUntilStorage().pauseUntilDuration = _pauseUntilDuration;
        emit PauseUntilDurationSet(_pauseUntilDuration);
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  GETTERS  ----------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Get the timestamp when the contract is paused until
     * @return The timestamp when the contract is paused until
     */
    function pausedUntil() external view returns (uint256) {
        return _getPausableUntilStorage().pausedUntil;
    }

    /**
     * @notice Get the pause duration for the contract
     * @return The pause duration for the contract
     */
    function pauseUntilDuration() external view returns (uint256) {
        return _getPausableUntilStorage().pauseUntilDuration;
    }

    /**
     * @notice Get the last pause timestamp for a given pauser
     * @param pauser The address of the pauser
     * @return The last pause timestamp for the pauser
     */
    function lastPauseTimestamp(address pauser) external view returns (uint256) {
        return _getPausableUntilStorage().lastPauseTimestamp[pauser];
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Modifier to check if the contract is not paused until
     * @dev Only callable when the contract is not paused until
     */
    modifier whenNotPausedUntil() {
        _requireNotPausedUntil();
        _;
    }
}