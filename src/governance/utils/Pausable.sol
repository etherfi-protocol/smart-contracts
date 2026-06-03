// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@etherfi/governance/utils/RolesLibrary.sol";

/**
 * @title Pausable
 * @notice Shared, custom pausing base for all etherfi contracts. Replaces OpenZeppelin's
 *         `PausableUpgradeable`. Holds the paused flag in namespaced storage so it never
 *         collides with the inheriting contract's linear storage, and exposes a single
 *         `whenNotPaused` modifier as the only pause primitive contracts need to use.
 * @dev    Pause/unpause is gated by the operating multisig via {RolesLibrary}. The modifier
 *         is `virtual` so {PausableUntil} can extend it to also enforce the timed pause.
 */
abstract contract Pausable is RolesLibrary {
    //--------------------------------------------------------------------------------------
    //------------------------------  STORAGE STRUCT  --------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice PausableStorage
     * @param paused Whether the contract is indefinitely paused
     */
    struct PausableStorage {
        bool paused;
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  CONSTANTS  --------------------------------------
    //--------------------------------------------------------------------------------------
    bytes32 private constant PAUSABLE_STORAGE_SLOT = 0x78b0b9eaa76f2f3afc4ee6c17ac4a6b5c1dfd190bc39879fb866c5b50b872744; // keccak256("pausable.storage")

    //--------------------------------------------------------------------------------------
    //-----------------------------------  EVENTS  -----------------------------------------
    //--------------------------------------------------------------------------------------
    event Paused(address account);
    event Unpaused(address account);

    //--------------------------------------------------------------------------------------
    //-----------------------------------  ERRORS  -----------------------------------------
    //--------------------------------------------------------------------------------------
    error AlreadyPaused();
    error NotPaused();
    error ContractPaused();

    //--------------------------------------------------------------------------------------
    //--------------------------  PAUSING FUNCTIONS  --------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Pause the contract indefinitely
     * @dev only callable by the operating multisig
     */
    function pause() external onlyOperatingMultisig {
        PausableStorage storage $ = _getPausableStorage();
        if ($.paused) revert AlreadyPaused();
        $.paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @notice Unpause the contract
     * @dev only callable by the operating multisig
     */
    function unpause() external onlyOperatingMultisig {
        PausableStorage storage $ = _getPausableStorage();
        if (!$.paused) revert NotPaused();
        $.paused = false;
        emit Unpaused(msg.sender);
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  INTERNAL FUNCTIONS  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Get the storage of the Pausable contract
     * @return $ The storage of the Pausable contract
     */
    function _getPausableStorage() internal pure returns (PausableStorage storage $) {
        assembly {
            $.slot := PAUSABLE_STORAGE_SLOT
        }
    }

    /**
     * @notice Require the contract to be not paused
     */
    function _requireNotPaused() internal view virtual {
        if (paused()) revert ContractPaused();
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  GETTERS  ----------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Whether the contract is indefinitely paused
     * @return Whether the contract is paused
     */
    function paused() public view virtual returns (bool) {
        return _getPausableStorage().paused;
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Modifier to check if the contract is not paused
     * @dev virtual so {PausableUntil} can extend it with the timed-pause check
     */
    modifier whenNotPaused() virtual {
        _requireNotPaused();
        _;
    }
}
