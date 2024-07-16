// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Auth, Authority} from "@solmate/auth/Auth.sol";
import {IPausable} from "./interfaces/IPausable.sol";

contract Pauser is Auth {
    // ========================================= STATE =========================================

    /**
     * @notice List of contracts that can be paused and unpaused using:
     * - `pauseAll`
     * - `unpauseAll`
     */
    IPausable[] internal pausables;

    /**
     * @notice Used to pause calls to `deposit` and `depositWithPermit`.
     */
    bool public isPaused;

    /**
     * @notice Maps a sender to a pausable contract.
     * @dev Used to pause and unpause using `senderPause` and `senderUnpause`.
     */
    mapping(address => IPausable) public senderToPausable;

    //============================== ERRORS ===============================

    error Pauser__IndexOutOfBounds();

    //============================== EVENTS ===============================

    event PausablePaused(address indexed pausable);
    event PausableUnpaused(address indexed pausable);
    event PausableAdded(address indexed pausable);
    event PausableRemoved(address indexed pausable);
    event SenderToPausableUpdated(address indexed sender, address indexed pausable);

    //============================== IMMUTABLES ===============================

    constructor(address _owner, Authority _authority, IPausable[] memory _pausables) Auth(_owner, _authority) {
        for (uint256 i = 0; i < _pausables.length; ++i) {
            pausables.push(_pausables[i]);
        }
    }

    // ========================================= ADMIN FUNCTIONS =========================================

    /**
     * @notice Adds a contract to the list of pausables.
     * @dev Callable by PAUSER_ADMIN_ROLE.
     */
    function addPausable(IPausable _pausable) external requiresAuth {
        pausables.push(_pausable);

        emit PausableAdded(address(_pausable));
    }

    /**
     * @notice Removes a contract from the list of pausables.
     * @dev Callable by PAUSER_ADMIN_ROLE.
     */
    function removePausable(uint256 index) external requiresAuth {
        uint256 pausablesLength = pausables.length;
        if (index >= pausablesLength) {
            revert Pauser__IndexOutOfBounds();
        }
        address removed = address(pausables[index]);
        pausables[index] = pausables[pausablesLength - 1];
        pausables.pop();

        emit PausableRemoved(removed);
    }

    /**
     * @notice Updates the index of the pausable contract that the sender can pause and unpause.
     * @dev Callable by PAUSER_ADMIN_ROLE.
     */
    function updateSenderToPausable(address sender, IPausable pausable) external requiresAuth {
        senderToPausable[sender] = pausable;

        emit SenderToPausableUpdated(sender, address(pausable));
    }

    // ========================================= GENERIC PAUSER FUNCTIONS =========================================

    /**
     * @notice Pauses a single pausable contract.
     * @dev Callable by GENERIC_PAUSER_ROLE.
     */
    function pauseSingle(IPausable pausable) external requiresAuth {
        pausable.pause();
        emit PausablePaused(address(pausable));
    }

    /**
     * @notice Unpauses a single pausable contract.
     * @dev Callable by GENERIC_UNPAUSER_ROLE.
     */
    function unpauseSingle(IPausable pausable) external requiresAuth {
        pausable.unpause();
        emit PausableUnpaused(address(pausable));
    }

    /**
     * @notice Pauses multiple pausable contracts.
     * @dev Callable by GENERIC_PAUSER_ROLE.
     */
    function pauseMultiple(IPausable[] calldata _pausables) external requiresAuth {
        for (uint256 i = 0; i < _pausables.length; ++i) {
            _pausables[i].pause();
            emit PausablePaused(address(_pausables[i]));
        }
    }

    /**
     * @notice Unpauses multiple pausable contracts.
     * @dev Callable by GENERIC_UNPAUSER_ROLE.
     */
    function unpauseMultiple(IPausable[] calldata _pausables) external requiresAuth {
        for (uint256 i = 0; i < _pausables.length; ++i) {
            _pausables[i].unpause();
            emit PausableUnpaused(address(_pausables[i]));
        }
    }

    // ========================================= PAUSABLES ALL FUNCTIONS =========================================

    /**
     * @notice Pauses all pausable contracts.
     * @dev Callable by PAUSE_ALL_ROLE.
     */
    function pauseAll() external requiresAuth {
        for (uint256 i = 0; i < pausables.length; ++i) {
            pausables[i].pause();
            emit PausablePaused(address(pausables[i]));
        }
    }

    /**
     * @notice Unpauses all pausable contracts.
     * @dev Callable by UNPAUSE_ALL_ROLE.
     */
    function unpauseAll() external requiresAuth {
        for (uint256 i = 0; i < pausables.length; ++i) {
            pausables[i].unpause();
            emit PausableUnpaused(address(pausables[i]));
        }
    }

    // ========================================= SENDER FUNCTIONS =========================================
    /**
     * @notice The below functions can be marked as publically callable, as the `senderToPausable` mapping
     *         must be updated by an admin in order for the call to succeed. The main advantage of this
     *         is needing less overhead to explicilty grant a role to pausing bots.
     *         However if security is of upmost importance, then seperate roles can be created for each function.
     */

    /**
     * @notice Pauses senders pausable contract.
     * @dev Callable by PUBLIC or SENDER_PAUSER_ROLE.
     */
    function senderPause() external requiresAuth {
        IPausable pausable = senderToPausable[msg.sender];
        pausable.pause();

        emit PausablePaused(address(pausable));
    }

    /**
     * @notice Unpauses senders pausable contract.
     * @dev Callable by PUBLIC or SENDER_UNPAUSER_ROLE.
     */
    function senderUnpause() external requiresAuth {
        IPausable pausable = senderToPausable[msg.sender];
        pausable.unpause();

        emit PausableUnpaused(address(pausable));
    }

    // ========================================= VIEW FUNCTIONS =========================================
    /**
     * @notice Returns the list of pausable contracts.
     */
    function getPausables() external view returns (IPausable[] memory) {
        return pausables;
    }
}
