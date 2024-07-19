// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

import "./interfaces/IPausable.sol";
import "./RoleRegistry.sol";

contract Pauser is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    // ========================================= STATE =========================================

    /**
     * @notice List of contracts that can be paused and unpaused using:
     * - `pauseAll`
     * - `unpauseAll`
     */
    IPausable[] public pausables;

    /**
     * @notice Global Role registry contract.
     */
    RoleRegistry public roleRegistry;

    //============================== ROLES ================================

    /**
     * @notice Contract specific roles.
     */
    bytes32 public constant PAUSER_ADMIN = keccak256("PAUSER_ADMIN");

    //============================== ERRORS ===============================

    error Pauser__IndexOutOfBounds();

    //============================== EVENTS ===============================

    event PausablePaused(address indexed pausable);
    event PausableUnpaused(address indexed pausable);
    event PausableAdded(address indexed pausable);
    event PausableRemoved(address indexed pausable);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ========================================= ADMIN FUNCTIONS =========================================

    function initialize(IPausable[] memory _pausables, uint256 _minUnpauseDelay, address _roleRegistry) public initializer {
        for (uint256 i = 0; i < _pausables.length; ++i) {
            pausables.push(_pausables[i]);
        }

        roleRegistry = RoleRegistry(_roleRegistry);

        __Ownable_init();
        __UUPSUpgradeable_init();
    }

    /**
     * @notice Adds a contract to the list of pausables.
     */
    function addPausable(IPausable _pausable) external onlyRole(PAUSER_ADMIN) {
        pausables.push(_pausable);
        emit PausableAdded(address(_pausable));
    }

    /**
     * @notice Removes a contract from the list of pausables.
     */
    function removePausable(uint256 _index) external onlyRole(PAUSER_ADMIN) {
        uint256 pausablesLength = pausables.length;
        if (_index >= pausablesLength) {
            revert Pauser__IndexOutOfBounds();
        }
        address removed = address(pausables[_index]);
        pausables[_index] = pausables[pausablesLength - 1];
        pausables.pop();
        emit PausableRemoved(removed);
    }

    // ========================================= PAUSER FUNCTIONS =========================================

    /**
     * @notice Pauses a single pausable contract.
     */
    function pauseSingle(IPausable _pausable) external onlyRole(roleRegistry.PROTOCOL_PAUSER()) {
        _pausable.pauseContract();
        emit PausablePaused(address(_pausable));
    }

    /**
     * @notice Pauses multiple pausable contracts.
     */
    function pauseMultiple(IPausable[] calldata _pausables) external onlyRole(roleRegistry.PROTOCOL_PAUSER()) {
        for (uint256 i = 0; i < _pausables.length; ++i) {
            _pausables[i].pauseContract();
            emit PausablePaused(address(_pausables[i]));
        }
    }

    /**
     * @notice Pauses all pausable contracts.
     */
    function pauseAll() external onlyRole(roleRegistry.PROTOCOL_PAUSER()) {
        for (uint256 i = 0; i < pausables.length; ++i) {
            pausables[i].pauseContract();
            emit PausablePaused(address(pausables[i]));
        }
    }

    // ========================================= UNPAUSER FUNCTIONS =========================================

    /**
     * @notice Unpauses a single pausable contract.
     */
    function unpauseSingle(IPausable _pausable) external onlyRole(roleRegistry.PROTOCOL_UNPAUSER()) returns (bytes32) {
        _pausable.unPauseContract();
        emit PausableUnpaused(address(_pausable));
    }

    /**
     * @notice Unpauses multiple pausable contracts.
     */
    function unpauseMultiple(IPausable[] calldata _pausables) external onlyRole(roleRegistry.PROTOCOL_UNPAUSER()) returns (bytes32) {
        for (uint256 i = 0; i < _pausables.length; ++i) {
            _pausables[i].unPauseContract();
            emit PausableUnpaused(address(_pausables[i]));
        }
    }

    /**
     * @notice Unpauses all pausable contracts.
     */
    function unpauseAll() external onlyRole(roleRegistry.PROTOCOL_UNPAUSER()) returns (bytes32) {
        for (uint256 i = 0; i < pausables.length; ++i) {
            pausables[i].unPauseContract();
            emit PausableUnpaused(address(pausables[i]));
        }
    }

    /**
     * @notice Upgrades the contract to a new implementation.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(roleRegistry.PROTOCOL_UPGRADER()) {}

    // ========================================= GETTER FUNCTIONS =========================================

    /**
     * @notice Gets the index of a contract in the pausables array if it exists.
     */
    function getPausableIndex(address _contractAddress) external view returns (uint256) {
        for (uint256 i = 0; i < pausables.length; ++i) {
            if (address(pausables[i]) == _contractAddress) {
                return i;
            }
        }
        revert("Contract not found");
    }

    /**
     * @notice Returns the list of pausable contracts.
     */
    function getPausables() external view returns (IPausable[] memory) {
        return pausables;
    }

    // ========================================= MODIFIERS =========================================

    modifier onlyRole(bytes32 _role) {
        require(roleRegistry.hasRole(_role, msg.sender), "Sender requires permission");
        _;
    }
}
