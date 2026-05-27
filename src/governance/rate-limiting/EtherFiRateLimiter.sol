// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";

import "@etherfi/governance/rate-limiting/interfaces/IEtherFiRateLimiter.sol";
import "@etherfi/governance/utils/RolesLibrary.sol";
import "@etherfi/governance/rate-limiting/libraries/BucketLimiter.sol";

contract EtherFiRateLimiter is IEtherFiRateLimiter, Initializable, UUPSUpgradeable, PausableUpgradeable, RolesLibrary {

    /// @dev Hardcoded callers for the per-address bucket API. Only the eETH and weETH
    ///      proxies can create/update/delete/consume per-address buckets; gating is
    ///      enforced via the `onlyToken` modifier rather than an admin-managed mapping
    ///      so the surface stays minimal and the trust boundary is obvious on-chain.
    address public immutable eETH;
    address public immutable weETH;

    //---------------------------------------------------------------------------
    //---------------------------  Storage  -------------------------------------
    //---------------------------------------------------------------------------
    mapping(bytes32 bucketId => BucketLimiter.Limit) limits;
    mapping(bytes32 bucketId => mapping(address consumer => bool allowed)) consumers;

    /// @dev token (eETH/weETH) -> user -> their rate-limit bucket. `lastRefill == 0`
    ///      is the unique "never created" sentinel because BucketLimiter.create always
    ///      stamps `lastRefill = block.timestamp` on a real chain.
    mapping(address token => mapping(address user => BucketLimiter.Limit)) addressLimits;

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
        __Pausable_init();
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

    /// @notice Pauses the contract, preventing consumption operations
    function pauseContract() external onlyOperatingMultisig {
        _pause();
    }

    /// @notice Unpauses the contract, allowing consumption operations
    function unPauseContract() external onlyOperatingMultisig {
        _unpause();
    }

    //-------------------------------------------------------------------------
    //----------------------  Per-address buckets  ----------------------------
    //-------------------------------------------------------------------------

    /// @notice Create or tighten a per-user bucket under the calling token's namespace.
    /// @dev Callable only by eETH/weETH; the token contract gates this to the Guardian.
    ///      If a bucket already exists, both `capacity` and `refillRate` must be ≤ their
    ///      current values — Guardian can only tighten, never loosen. A fresh bucket can
    ///      be created with any starting parameters because there's no looser prior state
    ///      to compare against (no bucket == unrestricted). `capacity = 0` on an existing
    ///      bucket is the tightest move and acts as a hard freeze (consume reverts).
    ///
    ///      Remaining-balance behavior: `BucketLimiter.setCapacity` / `setRefillRate`
    ///      apply any pending refill FIRST (against the previous cap/rate), then enforce
    ///      the new lower bounds. So a long-drained bucket can effectively be refreshed
    ///      to (refilled-previous-state) then capped down to `newCapacity`. Net effect:
    ///      `remaining` is bounded above by both the refilled-previous-state and the new
    ///      capacity. The user can never end up with MORE consumable than they could
    ///      have spent in one consume against the previous cap, so tightening still only
    ///      restricts the user's max burst — it cannot loosen them.
    function tightenAddressLimit(address user, uint64 capacity, uint64 refillRate) external onlyToken {
        BucketLimiter.Limit storage lim = addressLimits[msg.sender][user];
        if (lim.lastRefill == 0) {
            // `lastRefill == 0` is the "never created" sentinel — BucketLimiter.create
            // stamps block.timestamp, which is non-zero on any real chain.
            addressLimits[msg.sender][user] = BucketLimiter.create(capacity, refillRate);
        } else {
            if (capacity   > lim.capacity)   revert NotTightening();
            if (refillRate > lim.refillRate) revert NotTightening();
            BucketLimiter.setCapacity(lim, capacity);
            BucketLimiter.setRefillRate(lim, refillRate);
        }
        emit AddressLimitTightened(msg.sender, user, capacity, refillRate);
    }

    /// @notice Set or update a per-user bucket with no tightening constraint.
    /// @dev Callable only by eETH/weETH; the token contract gates this to the
    ///      Operating Multisig. This is the only path that can raise capacity or
    ///      refill rate after Guardian has tightened (or frozen) a user, and it
    ///      fully resets the bucket — `remaining` returns to the new capacity rather
    ///      than being preserved. Multisig is the trust escape hatch: a single call
    ///      here must be able to restore a user to a fully-usable state.
    function setAddressLimit(address user, uint64 capacity, uint64 refillRate) external onlyToken {
        addressLimits[msg.sender][user] = BucketLimiter.create(capacity, refillRate);
        emit AddressLimitSet(msg.sender, user, capacity, refillRate);
    }

    /// @notice Delete a per-user bucket; the user returns to the unrestricted default.
    /// @dev Callable only by eETH/weETH; the token contract gates this to the
    ///      Operating Multisig. Distinct from `tightenAddressLimit(user, 0, 0)` —
    ///      that freezes the user (consume reverts), this removes the limit entirely.
    function deleteAddressLimit(address user) external onlyToken {
        delete addressLimits[msg.sender][user];
        emit AddressLimitDeleted(msg.sender, user);
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
    /// @dev Token-only entry point for transfer/mint/burn paths. Intentionally skips
    ///      `whenNotPaused` — pausing the rate limiter must not halt token transfers;
    ///      operators pause the token contract itself for a hard stop. `onlyToken`
    ///      restricts callers to eETH/weETH, and `_consume` still enforces the consumer
    ///      whitelist, so the token must also be admin-whitelisted on the target bucket.
    ///
    ///      CAPACITY == 0 SEMANTICS: `capacity == 0` on an existing bucket reverts
    ///      LimitExceeded (symmetric with `consumeForAddressIfConfigured` below). To
    ///      soft-disable a global rate limit without un-whitelisting the consumer,
    ///      set capacity to type(uint64).max — effectively unlimited, the consume
    ///      always succeeds.
    function consumeToken(bytes32 id, uint64 amount) external onlyToken {
        _consume(id, amount);
    }

    function _consume(bytes32 id, uint64 amount) internal {
        if (!limitExists(id)) revert UnknownLimit();
        if (!consumers[id][msg.sender]) revert InvalidConsumer();
        if (!BucketLimiter.consume(limits[id], amount)) revert LimitExceeded();
    }

    /// @notice Consume from a per-address bucket; no-op if the user has no bucket configured.
    /// @dev Callable only by eETH/weETH. `lastRefill == 0` uniquely identifies "never
    ///      created" (unrestricted user) and short-circuits to a no-op.
    ///
    ///      CAPACITY == 0 SEMANTICS: `capacity == 0` on an existing bucket reverts
    ///      LimitExceeded (symmetric with `consumeToken` above). This is the
    ///      freeze path the Guardian uses via `tightenAddressLimit(user, 0, 0)`; the
    ///      Multisig clears it via `deleteAddressLimit` (returns to "never created" →
    ///      no-op) or `setAddressLimit` (creates fresh with non-zero cap). The two
    ///      distinct sentinel states — deleted (lastRefill == 0) vs frozen (cap == 0,
    ///      lastRefill > 0) — keep the Guardian/Multisig access split meaningful.
    ///
    ///      Intentionally skips `whenNotPaused`: pausing the rate limiter must not halt
    ///      token transfers.
    function consumeForAddressIfConfigured(address user, uint64 amount) external onlyToken {
        BucketLimiter.Limit storage lim = addressLimits[msg.sender][user];
        if (lim.lastRefill == 0) return;
        if (!BucketLimiter.consume(lim, amount)) revert LimitExceeded();
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

    /// @notice Returns the complete state of a per-address bucket.
    /// @dev Returns the raw struct — callers can check `lastRefill == 0` to detect
    ///      "no bucket configured" (unrestricted user).
    function getAddressLimit(address token, address user)
        external
        view
        returns (uint64 capacity, uint64 remaining, uint64 refillRate, uint256 lastRefill)
    {
        BucketLimiter.Limit memory lim = addressLimits[token][user];
        return (lim.capacity, lim.remaining, lim.refillRate, lim.lastRefill);
    }

    /// @notice Returns true if a per-address bucket has been created for (token, user).
    function addressLimitExists(address token, address user) external view returns (bool) {
        return addressLimits[token][user].lastRefill != 0;
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
