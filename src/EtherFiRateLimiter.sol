// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";

import "./interfaces/IEtherFiRateLimiter.sol";
import "./interfaces/IRoleRegistry.sol";
import "lib/BucketLimiter.sol";

contract EtherFiRateLimiter is IEtherFiRateLimiter, Initializable, UUPSUpgradeable, PausableUpgradeable {

    IRoleRegistry public immutable roleRegistry;

    //---------------------------------------------------------------------------
    //---------------------------  Storage  -------------------------------------
    //---------------------------------------------------------------------------
    mapping(bytes32 bucketId => BucketLimiter.Limit) limits;
    mapping(bytes32 bucketId => mapping(address consumer => bool allowed)) consumers;

    //---------------------------------------------------------------------------
    //----------------------------  ROLES  --------------------------------------
    //---------------------------------------------------------------------------
    bytes32 public constant ETHERFI_RATE_LIMITER_ADMIN_ROLE = keccak256("ETHERFI_RATE_LIMITER_ADMIN_ROLE");

    //-------------------------------------------------------------------------
    //-------------------------  Deployment  ----------------------------------
    //-------------------------------------------------------------------------
    constructor(address _roleRegistry) {
        roleRegistry = IRoleRegistry(_roleRegistry);
        _disableInitializers();
    }

    function initialize() public initializer {
        __UUPSUpgradeable_init();
        __Pausable_init();
    }

    function _authorizeUpgrade(address newImplementation) internal override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }

    //-------------------------------------------------------------------------
    //-----------------------------  Admin  -----------------------------------
    //-------------------------------------------------------------------------

    /// @notice Updates consumer permissions for a specific rate limit
    /// @param id The rate limit identifier
    /// @param consumer The consumer address to update
    /// @param allowed Whether the consumer is allowed to consume from this limit
    function updateConsumers(bytes32 id, address consumer, bool allowed) external onlyAdmin {
        if (!limitExists(id)) revert UnknownLimit();
        consumers[id][consumer] = allowed;
        emit ConsumerUpdated(id, consumer, allowed);
    }

    /// @notice Creates a new rate limiter with specified parameters
    /// @param id The unique identifier for the rate limit
    /// @param capacity The maximum capacity of the bucket in gwei
    /// @param refillRate The refill rate per second in gwei
    function createNewLimiter(bytes32 id, uint64 capacity, uint64 refillRate) external onlyAdmin {
        if (limitExists(id)) revert LimitAlreadyExists();

        limits[id] = BucketLimiter.create(capacity, refillRate);
        emit LimiterCreated(id, capacity, refillRate);
    }

    /// @notice Updates the capacity of an existing rate limit
    /// @param id The rate limit identifier
    /// @param capacity The new maximum capacity in gwei
    function setCapacity(bytes32 id, uint64 capacity) external onlyAdmin {
        if (!limitExists(id)) revert UnknownLimit();

        BucketLimiter.setCapacity(limits[id], capacity);
        emit CapacityUpdated(id, capacity);
    }

    /// @notice Updates the refill rate of an existing rate limit
    /// @param id The rate limit identifier
    /// @param refillRate The new refill rate per second in gwei
    function setRefillRate(bytes32 id, uint64 refillRate) external onlyAdmin {
        if (!limitExists(id)) revert UnknownLimit();

        BucketLimiter.setRefillRate(limits[id], refillRate);
        emit RefillRateUpdated(id, refillRate);
    }

    /// @notice Updates the remaining capacity of an existing rate limit
    /// @param id The rate limit identifier
    /// @param remaining The new remaining capacity in gwei
    function setRemaining(bytes32 id, uint64 remaining) external onlyAdmin {
        if (!limitExists(id)) revert UnknownLimit();

        BucketLimiter.setRemaining(limits[id], remaining);
        emit RemainingUpdated(id, remaining);
    }

    /// @notice Pauses the contract, preventing consumption operations
    function pauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_PAUSER(), msg.sender)) revert IncorrectRole();
        _pause();
    }

    /// @notice Unpauses the contract, allowing consumption operations
    function unPauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_UNPAUSER(), msg.sender)) revert IncorrectRole();
        _unpause();
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  Core  -------------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Consumes capacity from a rate limit
    /// @param id The rate limit identifier
    /// @param amount The amount to consume in gwei
    /// @dev Reverts if the consumer is not whitelisted or if insufficient capacity is available
    function consume(bytes32 id, uint64 amount) external whenNotPaused {
        if (!limitExists(id)) revert UnknownLimit();
        if (!consumers[id][msg.sender]) revert InvalidConsumer(); // must be whitelisted consumer

        // returns false if full amount cannot be consumed
        if (!BucketLimiter.consume(limits[id], amount)) revert LimitExceeded();
    }

    /// @notice Checks if a specific amount can be consumed from a rate limit
    /// @param id The rate limit identifier
    /// @param amount The amount to check in gwei
    /// @return bool True if the amount can be consumed, false otherwise
    function canConsume(bytes32 id, uint64 amount) external view returns (bool) {
        if (!limitExists(id)) revert UnknownLimit();
        return BucketLimiter.canConsume(limits[id], amount);
    }

    /// @notice Returns the current consumable capacity for a rate limit
    /// @param id The rate limit identifier
    /// @return uint64 The amount that can currently be consumed in gwei
    function consumable(bytes32 id) external view returns (uint64) {
        if (!limitExists(id)) revert UnknownLimit();
        return BucketLimiter.consumable(limits[id]);
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  View  -------------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Returns the complete state of a rate limit
    /// @param id The rate limit identifier
    /// @return capacity The maximum capacity in gwei
    /// @return remaining The current remaining capacity in gwei
    /// @return refillRate The refill rate per second in gwei
    /// @return lastRefill The timestamp of the last refill operation
    function getLimit(bytes32 id) external view returns (uint64 capacity, uint64 remaining, uint64 refillRate, uint256 lastRefill) {
        if (!limitExists(id)) revert UnknownLimit();
        BucketLimiter.Limit memory limit = limits[id];
        return (limit.capacity, limit.remaining, limit.refillRate, limit.lastRefill);
    }

    /// @notice Checks if a consumer is allowed to use a specific rate limit
    /// @param id The rate limit identifier
    /// @param consumer The consumer address to check
    /// @return bool True if the consumer is whitelisted for this limit
    function isConsumerAllowed(bytes32 id, address consumer) external view returns (bool) {
        return consumers[id][consumer];
    }

    /// @notice Checks if a rate limit exists
    /// @param id The rate limit identifier
    /// @return bool True if the rate limit has been initialized
    function limitExists(bytes32 id) public view returns (bool) {
        BucketLimiter.Limit memory limit = limits[id];
        return limit.capacity != 0 || limit.remaining != 0 || limit.lastRefill != 0 || limit.refillRate != 0;
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier onlyAdmin() {
        if (!roleRegistry.hasRole(ETHERFI_RATE_LIMITER_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        _;
    }
}