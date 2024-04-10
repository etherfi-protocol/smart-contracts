pragma solidity ^0.8.20;

import "src/interfaces/IRateLimiter.sol";
import "lib/BucketLimiter.sol";

contract BucketRateLimiter is IRateLimiter {

    BucketLimiter.Limit public limit;

    constructor() {
        limit = BucketLimiter.create(0, 0);
    }

    function updateRateLimit(address sender, address tokenIn, uint256 amountIn, uint256 amountOut) external {
        // Count both 'amountIn' and 'amountOut' as rate limit consumption
        require(BucketLimiter.consume(limit, uint64(amountIn / 1 gwei)), "BucketRateLimiter: rate limit exceeded");
        require(BucketLimiter.consume(limit, uint64(amountOut / 1 gwei)), "BucketRateLimiter: rate limit exceeded");
    }

    function setCapacity(uint64 capacity) external {
        BucketLimiter.setCapacity(limit, capacity);
    }

    function setRefillRate(uint64 refillRate) external {
        BucketLimiter.setRefillRate(limit, refillRate);
    }

}