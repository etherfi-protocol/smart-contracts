// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


/**
 * The BucketLimiter contract is used to limit the rate of some action.
 * 
 * Buckets refill at a constant rate, and have a maximum capacity. Each time
 * the consume function is called, the bucket gets depleted by the provided
 * amount. If the bucket is empty, the consume function will return false
 * and the bucket will not be depleted. Rates are measured in units per 
 * second.
 * 
 * To limit storage usage to a single slot, the Bucket struct is packed into
 * a single word, meaning all fields are uint64.
 *
 * Examples:
 *
 * ```sol
 * BucketLimiter.Limit storage limit = BucketLimiter.create(100, 1);
 * limit.consume(10); // returns true, remaining = 90
 * limit.consume(80); // returns true, remaining = 10
 * limit.consume(20); // returns false, remaining = 10
 * // Wait 10 seconds (10 tokens get refilled)
 * limit.consume(20); // returns true, remaining = 0)
 * // Increase capacity
 * limit.setCapacity(200); // remaining = 0, capacity = 200
 * // Increase refill rate
 * limit.setRefillRate(2); // remaining = 0, capacity = 200, refillRate = 2
 * // Wait 10 seconds (20 tokens get refilled)
 * limit.consume(20); // returns true, remaining = 0
 * ```
 * 
 * Developers should notice that rate-limits are vulnerable to two attacks:
 * 1. Sybil-attacks: Rate limits should typically be global across all user
 *       accounts, otherwise an attacker can simply create many accounts to
 *       bypass the rate limit.
 * 2. DoS attacks: Rate limits should typically apply to actions with a
 *       friction such as a fee or a minimum stake time. Otherwise, an
 *       attacker can simply spam the action to deplete the rate limit.
 */
library BucketLimiter {
    struct Limit {
        // The maximum capacity of the bucket, in consumable units (eg. tokens)
        uint64 capacity;
        // The remaining capacity in the bucket, that can be consumed
        uint64 remaining;
        // The timestamp of the last time the bucket was refilled
        uint64 lastRefill;
        // The rate at which the bucket refills, in units per second
        uint64 refillRate;
    }

    /*
     * Creates a new bucket with the given capacity and refill rate.
     * 
     * @param capacity The maximum capacity of the bucket, in consumable units (eg. tokens)
     * @param refillRate The rate at which the bucket refills, in units per second
     * @return The created bucket
     */
    function create(uint64 capacity, uint64 refillRate) internal view returns (Limit memory) {
        return Limit({
            capacity: capacity,
            remaining: capacity,
            lastRefill: uint64(block.timestamp),
            refillRate: refillRate
        });
    }

    function canConsume(Limit memory limit, uint64 amount) external view returns (bool) {
        _refill(limit);
        return limit.remaining >= amount;
    }

    function consumable(Limit memory limit) external view returns (uint64) {
        _refill(limit);
        return limit.remaining;
    }

    /*
     * Consumes the given amount from the bucket, if there is sufficient capacity, and returns
     * whether the bucket had enough remaining capacity to consume the amount.
     * 
     * @param limit The bucket to consume from
     * @param amount The amount to consume
     * @return True if the bucket had enough remaining capacity to consume the amount, false otherwise
     */
    function consume(Limit storage limit, uint64 amount) internal returns (bool) {
        Limit memory _limit = limit;
        _refill(_limit);
        if (_limit.remaining < amount) {
            return false;
        }
        limit.remaining = _limit.remaining - amount;
        limit.lastRefill = _limit.lastRefill;
        return true;
    }

    /*
     * Refills the bucket based on the time elapsed since the last refill. This effectively simulates
     * the idea of the bucket continuously refilling at a constant rate.
     * 
     * @param limit The bucket to refill
     */
    function refill(Limit storage limit) internal {
        Limit memory _limit = limit;
        _refill(_limit);
        limit.remaining = _limit.remaining;
        limit.lastRefill = _limit.lastRefill;
    }

    function _refill(Limit memory limit) internal view {
        uint64 now_ = uint64(block.timestamp);

        if (now_ == limit.lastRefill) {
            return;
        }

        uint256 delta;
        unchecked {
            delta = now_ - limit.lastRefill;
        }
        uint256 tokens = delta * uint256(limit.refillRate);
        uint256 newRemaining = uint256(limit.remaining) + tokens;
        if (newRemaining > limit.capacity) {
            limit.remaining = limit.capacity;
        } else {
            limit.remaining = uint64(newRemaining);
        }
        limit.lastRefill = now_;
    }

    /*
     * Sets the capacity of the bucket. If the new capacity is less than the remaining capacity,
     * the remaining capacity is set to the new capacity.
     * 
     * @param limit The bucket to set the capacity of
     * @param capacity The new capacity
     */
    function setCapacity(Limit storage limit, uint64 capacity) internal {
        refill(limit);
        limit.capacity = capacity;
        if (limit.remaining > capacity) {
            limit.remaining = capacity;
        }
    }

    /*
     * Sets the refill rate of the bucket, in units per second.
     *
     * @param limit The bucket to set the refill rate of
     * @param refillRate The new refill rate
     */
    function setRefillRate(Limit storage limit, uint64 refillRate) internal {
        refill(limit);
        limit.refillRate = refillRate;
    }

    /*
     * Sets the remaining capacity of the bucket. If the new remaining capacity is greater than
     * the capacity, the remaining capacity is set to the capacity.
     * 
     * @param limit The bucket to set the remaining capacity of
     * @param remaining The new remaining capacity
     */
    function setRemaining(Limit storage limit, uint64 remaining) internal {
        refill(limit);
        limit.remaining = remaining;
    }
}
