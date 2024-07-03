// SPDX-License-Identifier: MIT
// Custom OpenZeppelin Contract (last updated v5.0.0) (utils/Pausable.sol)

pragma solidity ^0.8.20;

import {ContextUpgradeable} from "@openzeppelin-upgradeable/contracts/utils/ContextUpgradeable.sol";
import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";

/**
 * @dev Custom contract module which allows children to implement an emergency stop
 * mechanisms that can be triggered by an authorized account.
 *
 * This module is used through inheritance. It will make available the
 * modifiers `whenNotPaused` and `whenPaused`, which can be applied to
 * the functions of your contract. Note that they will not be pausable by
 * simply including this module, only once the modifiers are put in place.
 */
abstract contract CustomPausableUpgradeable is Initializable, ContextUpgradeable {
    /// @custom:storage-location erc7201:openzeppelin.storage.Pausable
    struct PausableStorage {
        // each bit in the uint256 represents a pause flag (0 for unpaused, 1 for paused)
        uint256 _paused;
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Pausable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PausableStorageLocation = 0xcd5ed15c6e187e77e9aee88184c21f4f2182ab5827cb3b7e07fbedcd63f03300;

    function _getPausableStorage() private pure returns (PausableStorage storage $) {
        assembly {
            $.slot := PausableStorageLocation
        }
    }

    /**
     * @dev Emitted when a pause flag of `index` is set by `account`.
     */
    event Paused(address account, uint8 index);

    /**
     * @dev Emitted when a pause flag of `index` is set by `account`.
     */
    event Unpaused(address account, uint8 index);

    /**
     * @dev The operation failed because the contract method is paused.
     */
    error EnforcedPause(uint8 index);

    /**
     * @dev The operation failed because the contract method is not paused.
     */
    error ExpectedPause(uint8 index);

    /**
     * @dev Initializes the contract in unpaused state.
     */
    function __Pausable_init() internal onlyInitializing {
        __Pausable_init_unchained();
    }

    function __Pausable_init_unchained() internal onlyInitializing {
        PausableStorage storage $ = _getPausableStorage();
        // set all pause flags to 0
        $._paused = 0;
    }

    /**
     * @dev Modifier to make a function callable only when this pause flag is set to 0.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    modifier whenNotPaused(uint8 index) {
        _requireNotPaused(index);
        _;
    }

    /**
     * @dev Modifier to make a function callable only when this pause flag is set to 1.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    modifier whenPaused(uint8 index) {
        _requirePaused(index);
        _;
    }

    /**
     * @dev Returns true if the give pause flag is set to 1 and false otherwise.
     */
    function paused(uint8 index) public view virtual returns (bool) {
        PausableStorage storage $ = _getPausableStorage();

        // creates a bitmask, if index is 2, mask will be 000...00100 in binary.
        uint256 mask = 1 << index;

        // checks if the bit at the index is set to 1
        return (($._paused & mask) == mask);
    }

    /**
     * @dev Throws if the `indexed`th bit of `_paused` is 1, i.e. if the `index`th pause switch is flipped.
     */
    function _requireNotPaused(uint8 index) internal view virtual {
        if (paused(index)) {
            revert EnforcedPause(index);
        }
    }

    /**
     * @dev Throws if the `indexed`th bit of `_paused` is 0, i.e. if the `index`th pause switch is not flipped.
     */
    function _requirePaused(uint8 index) internal view virtual {
        if (!paused(index)) {
            revert ExpectedPause(index);
        }
    }

    /**
     * @dev Triggers stopped state.
     *
     * Requirements:
     *
     * - The input flag must must not already be set to paused.
     */
    function _pause(uint8 index) internal virtual whenNotPaused(index) {
        PausableStorage storage $ = _getPausableStorage();

        // creates a bitmask, if index is 2, mask will be 000...00100 in binary.
        uint256 mask = 1 << index;

        // bitwise or to set the corresponding bit to 1
        $._paused = $._paused | mask; 
        emit Paused(_msgSender(), index);
    }

    /**
     * @dev Returns to normal state.
     *
     * Requirements:
     *
     * - The input flag must must not already be set to unpaused.
     */
    function _unpause(uint8 index) internal virtual whenPaused(index) {
        PausableStorage storage $ = _getPausableStorage();

        // creates a inverted bitmask, if index is 2, mask will be 111...11011 in binary.
        uint256 invertedMask = ~(1 << index);

        // bitwise and to set the corresponding bit to 0
        $._paused = $._paused & invertedMask;
        emit Unpaused(_msgSender(), index);
    }
}
