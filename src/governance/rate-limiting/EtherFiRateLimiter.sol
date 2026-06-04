// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "@etherfi/governance/rate-limiting/interfaces/IEtherFiRateLimiter.sol";
import "@etherfi/governance/utils/RolesLibrary.sol";
import "@etherfi/governance/utils/Pausable.sol";
import "@etherfi/governance/utils/DeprecatedOZPausable.sol";
import "@etherfi/governance/rate-limiting/libraries/BucketLimiter.sol";

contract EtherFiRateLimiter is IEtherFiRateLimiter, Initializable, UUPSUpgradeable, DeprecatedOZPausable, Pausable {

    /// @dev Hardcoded callers for the token-only `consumeToken` entry point. Only the
    ///      eETH and weETH proxies may consume from the global mint/burn buckets; gating
    ///      is enforced via the `onlyToken` modifier rather than an admin-managed mapping
    ///      so the surface stays minimal and the trust boundary is obvious on-chain.
    address public immutable eETH;
    address public immutable weETH;

    //---------------------------------------------------------------------------
    //---------------------------  Storage  -------------------------------------
    //---------------------------------------------------------------------------
    mapping(bytes32 bucketId => BucketLimiter.Limit) limits;
    mapping(bytes32 bucketId => mapping(address consumer => bool allowed)) consumers;

    //-------------------------------------------------------------------------
    //-------------------------  Deployment  ----------------------------------
    //-------------------------------------------------------------------------
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _roleRegistry, address _eETH, address _weETH) RolesLibrary(_roleRegistry) {
        eETH = _eETH;
        weETH = _weETH;
        _disableInitializers();
    }

    function initialize() public initializer {
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

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

    //--------------------------------------------------------------------------------------
    //-----------------------------------  Core  -------------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Consumes capacity from a rate limit
    /// @param id The rate limit identifier
    /// @param amount The amount to consume in gwei
    /// @dev Reverts if the consumer is not whitelisted or if insufficient capacity is available
    function consume(bytes32 id, uint64 amount) external whenNotPaused {
        _consume(id, amount);
    }

    /// @notice Consume capacity from a global rate limit; reverts on insufficient capacity.
    /// @param id The rate limit identifier
    /// @param amount The amount to consume in gwei
    /// @dev Token-only entry point for the global mint/burn buckets. Intentionally skips
    ///      `whenNotPaused` — pausing the rate limiter must not halt token transfers;
    ///      operators pause the token contract itself for a hard stop. `onlyToken`
    ///      restricts callers to eETH/weETH, and `_consume` still enforces the consumer
    ///      whitelist, so the token must also be admin-whitelisted on the target bucket.
    ///
    ///      CAPACITY == 0 SEMANTICS: `capacity == 0` on an existing bucket reverts
    ///      LimitExceeded. To soft-disable a global rate limit without un-whitelisting
    ///      the consumer, set capacity to type(uint64).max — effectively unlimited, the
    ///      consume always succeeds.
    function consumeToken(bytes32 id, uint64 amount) external onlyToken {
        _consume(id, amount);
    }

    function _consume(bytes32 id, uint64 amount) internal {
        if (!limitExists(id)) revert UnknownLimit();
        if (!consumers[id][msg.sender]) revert InvalidConsumer();
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
    // `onlyAdmin` and `onlyOperatingMultisig` are inherited from RolesLibrary.

    modifier onlyToken() {
        if (msg.sender != eETH && msg.sender != weETH) revert OnlyToken();
        _;
    }
}
