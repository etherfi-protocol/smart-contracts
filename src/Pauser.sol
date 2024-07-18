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
     * @notice Used to pause calls to `deposit` and `depositWithPermit`.
     */
    bool public isPaused;

    /**
     * @notice Minimum delay required to execute an unpause action.
     */
    uint256 public minUnpauseDelay;

    /**
     * @notice Mapping of unpause operations and the time they become executable.
     */
    mapping(bytes32 id => uint256) public unpauseExecutionTime;

    /**
     * @notice Timestamp indicating an operation has been executed.
     */
    uint256 public constant _DONE_TIMESTAMP = uint256(1);

    /**
     * @notice Global Role registry contract.
     */
    RoleRegistry public roleRegistry;

    //============================== ROLES ================================

    /**
     * @notice Contract specific roles.
     */
    bytes32 public constant PAUSER_ADMIN = keccak256("PAUSER_ADMIN");
    /**
     * @notice Protocol specific roles.
     */
    bytes32 public constant PROTOCOL_PAUSER = keccak256("PROTOCOL_PAUSER");
    bytes32 public constant PROTOCOL_UNPAUSER = keccak256("PROTOCOL_UNPAUSER");
    bytes32 public constant PROTOCOL_UPGRADER = keccak256("PROTOCOL_UPGRADER");

    //============================== ERRORS ===============================

    error Pauser__IndexOutOfBounds();

    //============================== EVENTS ===============================

    event PausablePaused(address indexed pausable);
    event PausableUnpaused(address indexed pausable);
    event PausableAdded(address indexed pausable);
    event PausableRemoved(address indexed pausable);

    event MinUnpauseDelayUpdated(uint256 oldDuration, uint256 newDuration);
    event UnpauseScheduled(bytes32 indexed id, uint256 indexed timestampProposed, uint256 timestampExecutable);
    event UnpauseExecuted(bytes32 indexed id);
    event UnpauseDeleted(bytes32 indexed id);
    

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ========================================= ADMIN FUNCTIONS =========================================

    function initialize(IPausable[] memory _pausables, uint256 _minUnpauseDelay, address _roleRegistry) public initializer {
        for (uint256 i = 0; i < _pausables.length; ++i) {
            pausables.push(_pausables[i]);
        }

        minUnpauseDelay = _minUnpauseDelay;
        emit MinUnpauseDelayUpdated(0, _minUnpauseDelay);

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

    /**
     * @notice Updates the minimum delay required to execute an unpause action.
     */
    function updateDelay(uint256 _minDelay) external onlyRole(PAUSER_ADMIN) {
        minUnpauseDelay = _minDelay;
        emit MinUnpauseDelayUpdated(minUnpauseDelay, _minDelay);
    }

    /**
     * @notice Deletes a scheduled unpause action.
    */
    function deleteUnpause(bytes32 _id) external onlyRole(PAUSER_ADMIN) {
        uint256 timestamp = unpauseExecutionTime[_id];
        require(timestamp != 0, "Unpause operation is not scheduled");
        require(timestamp != _DONE_TIMESTAMP, "Unpause already executed");

        delete unpauseExecutionTime[_id];
        emit UnpauseDeleted(_id);
    }

    // ========================================= PAUSER FUNCTIONS =========================================

    /**
     * @notice Pauses a single pausable contract.
     */
    function pauseSingle(IPausable _pausable) external onlyRole(PROTOCOL_PAUSER) {
        _pausable.pauseContract();
        emit PausablePaused(address(_pausable));
    }

    /**
     * @notice Pauses multiple pausable contracts.
     */
    function pauseMultiple(IPausable[] calldata _pausables) external onlyRole(PROTOCOL_PAUSER) {
        for (uint256 i = 0; i < _pausables.length; ++i) {
            _pausables[i].pauseContract();
            emit PausablePaused(address(_pausables[i]));
        }
    }

    /**
     * @notice Pauses all pausable contracts.
     */
    function pauseAll() external onlyRole(PROTOCOL_PAUSER) {
        for (uint256 i = 0; i < pausables.length; ++i) {
            pausables[i].pauseContract();
            emit PausablePaused(address(pausables[i]));
        }
    }

    // ========================================= UNPAUSER FUNCTIONS =========================================

    /**
     * @notice Unpauses a single pausable contract.
     */
    function scheduleUnpauseSingle(IPausable _pausable) external onlyRole(PROTOCOL_UNPAUSER) returns (bytes32) {
        bytes32 id = hashUnpauseSingle(_pausable, block.timestamp);
        _scheduleUnpause(id);
        return id;
    }

    /**
     * @notice Unpauses multiple pausable contracts.
     */
    function scheduleUnpauseMultiple(IPausable[] calldata _pausables) external onlyRole(PROTOCOL_UNPAUSER) returns (bytes32) {
        bytes32 id = hashUnpauseMultiple(_pausables, block.timestamp);
        _scheduleUnpause(id);
        return id;
    }

    /**
     * @notice Unpauses all pausable contracts.
     */
    function scheduleUnpauseAll() external onlyRole(PROTOCOL_UNPAUSER) returns (bytes32) {
        bytes32 id = hashUnpauseAll(block.timestamp);
        _scheduleUnpause(id);
        return id;
    }

    /**
     * @notice Unpauses a single pausable contract.
     * @dev The contract to unpaused and the timestamp it was proposed must be provided to find the unpause id.
     */
    function executeUnpauseSingle(IPausable _pausable, uint256 _timestampProposed) external onlyRole(PROTOCOL_UNPAUSER) {
        bytes32 id = hashUnpauseSingle(_pausable, _timestampProposed);
        _validateUnpause(id);

        _pausable.unPauseContract();
        emit PausableUnpaused(address(_pausable));

        unpauseExecutionTime[id] = _DONE_TIMESTAMP;
        emit UnpauseExecuted(id);
    }

    /**
     * @notice Unpauses multiple pausable contracts if the delay has passed.
     * @dev The contracts to unpaused and the timestamp it was proposed must be provided to find the unpause id.
     */
    function executeUnpauseMultiple(IPausable[] calldata _pausables, uint256 _timestampProposed) external onlyRole(PROTOCOL_UNPAUSER) {
        bytes32 id = hashUnpauseMultiple(_pausables, _timestampProposed);
        _validateUnpause(id);

        for (uint256 i = 0; i < _pausables.length; ++i) {
            _pausables[i].unPauseContract();
            emit PausableUnpaused(address(_pausables[i]));
        }

        unpauseExecutionTime[id] = _DONE_TIMESTAMP;
        emit UnpauseExecuted(id);
    }

    /**
     * @notice Executes a scheduled unpausing of all the contracts if the delay has passed.
     * @dev The timestamp `scheduleUnpauseAll` was called at must be provided to find the unpause id.
     */
    function executeUnpauseAll(uint256 _timestampProposed) external onlyRole(PROTOCOL_UNPAUSER) {
        bytes32 id = hashUnpauseAll(_timestampProposed);
        _validateUnpause(id);

        for (uint256 i = 0; i < pausables.length; ++i) {
            pausables[i].unPauseContract();
            emit PausableUnpaused(address(pausables[i]));
        }

        unpauseExecutionTime[id] = _DONE_TIMESTAMP;
        emit UnpauseExecuted(id);
    }

    // ========================================= SETTER FUNCTIONS =========================================

    /**
     * @notice Schedules an unpause action.
     */
    function _scheduleUnpause(bytes32 _id) internal {
        uint256 timestampExecutable = block.timestamp + minUnpauseDelay;

        unpauseExecutionTime[_id] = timestampExecutable;
        emit UnpauseScheduled(_id, block.timestamp, timestampExecutable);
    }

    /**
     * @notice Upgrades the contract to a new implementation.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(PROTOCOL_UPGRADER) {}

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
    
    /** 
     * @notice Returns `true` if the give unpause operation is executable.
     */
    function isExecutable(bytes32 _id) external view returns (bool) {
        uint256 timestamp = unpauseExecutionTime[_id];

        return (timestamp != 0 && timestamp != _DONE_TIMESTAMP && timestamp <= block.timestamp);
    }
    
    /**
     * @notice Returns the hash id of a single contract unpause with the timestamp it was proposed.
     */
    function hashUnpauseSingle(IPausable _pausable, uint256 _timestampProposedProposed) public pure returns (bytes32) {
        return keccak256(abi.encode(_pausable, _timestampProposedProposed));
    }

    /**
     * @notice Returns the hash id of an array of unpause operatons with the timestamp it was proposed.
     */
    function hashUnpauseMultiple(IPausable[] calldata _targets, uint256 _timestampProposedProposed) public pure returns (bytes32) {
        return keccak256(abi.encode(_targets, _timestampProposedProposed));
    }

    /**
     * @notice Returns the hash id of a call to pause all contracts with the timestamp it was proposed.
     */
    function hashUnpauseAll(uint256 _timestampProposedProposed) public view returns (bytes32) {
        return keccak256(abi.encode(pausables, _timestampProposedProposed));
    }

    /**
     * @notice Ensures enough time has past to execute an unpause action and that it hasn't arleady been executed.
     */
    function _validateUnpause(bytes32 _id) internal view {
        uint256 timestamp = unpauseExecutionTime[_id];

        require(timestamp != 0, "Unpause operation is not scheduled");
        require(timestamp != _DONE_TIMESTAMP, "Unpause operation already executed");
        require(timestamp <= block.timestamp, "Unpause operation not past delay");
    }

    // ========================================= MODIFIERS =========================================

    modifier onlyRole(bytes32 _role) {
        require(roleRegistry.hasRole(_role, msg.sender), "Sender requires permission");
        _;
    }
}
