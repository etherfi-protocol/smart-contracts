pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../src/BucketRateLimiter.sol";
import "../src/UUPSProxy.sol";

contract BucketRateLimiterTest is Test {
    BucketRateLimiter limiter;

    function setUp() public {
        address owner = address(10000);
        vm.startPrank(owner);
        BucketRateLimiter impl = new BucketRateLimiter();
        UUPSProxy proxy = new UUPSProxy(address(impl), "");
        limiter = BucketRateLimiter(address(proxy));
        limiter.initialize();

        limiter.updateConsumer(owner);
        limiter.setCapacity(200 ether);
        limiter.setRefillRatePerSecond(100 ether);
        vm.stopPrank();
    }

    function test_updateRateLimit() public {
        vm.startPrank(limiter.owner());

        vm.expectRevert("BucketRateLimiter: rate limit exceeded");
        limiter.updateRateLimit(address(0), address(0), 50 ether, 50 ether);

        vm.warp(block.timestamp + 1);

        limiter.updateRateLimit(address(0), address(0), 50 ether, 50 ether);

        vm.expectRevert("BucketRateLimiter: rate limit exceeded");
        limiter.updateRateLimit(address(0), address(0), 50 ether, 50 ether);

        vm.warp(block.timestamp + 1);

        vm.expectRevert("BucketRateLimiter: rate limit exceeded");
        limiter.updateRateLimit(address(0), address(0), 51 ether, 50 ether);

        vm.warp(block.timestamp + 1);

        limiter.updateRateLimit(address(0), address(0), 100 ether, 100 ether);

        vm.warp(block.timestamp + 3);
        vm.expectRevert("BucketRateLimiter: rate limit exceeded");
        limiter.updateRateLimit(address(0), address(0), 100 ether, 101 ether);

        vm.stopPrank();
    }

    function test_consume_tiny() public {
        vm.startPrank(limiter.owner());

        // Even 1 wei is counted
        vm.warp(block.timestamp + 1);
        limiter.updateRateLimit(address(0), address(0), 0, 1);

        vm.expectRevert("BucketRateLimiter: rate limit exceeded");
        limiter.updateRateLimit(address(0), address(0), 50 ether, 50 ether);

        vm.stopPrank();
    }

    function test_consume_per_token() public {
        vm.startPrank(limiter.owner());

        address token = address(1);
        limiter.registerToken(token, 100 ether, 100 ether);
        limiter.setCapacity(1000 ether);
        limiter.setRefillRatePerSecond(1000 ether);

        vm.warp(block.timestamp + 1);

        limiter.updateRateLimit(address(0), token, 50 ether, 50 ether);

        vm.expectRevert("BucketRateLimiter: token rate limit exceeded");
        limiter.updateRateLimit(address(0), token, 50 ether, 50 ether);

        vm.warp(block.timestamp + 1);

        vm.expectRevert("BucketRateLimiter: token rate limit exceeded");
        limiter.updateRateLimit(address(0), token, 51 ether, 50 ether);

        limiter.updateRateLimit(address(0), token, 50 ether, 50 ether);

        vm.stopPrank();
    }
    
    function test_access_control() public {
        vm.expectRevert("Ownable: caller is not the owner");
        limiter.updateAdmin(address(0), true);

        vm.expectRevert("Ownable: caller is not the owner");
        limiter.updatePauser(address(0), true);

        vm.expectRevert("Ownable: caller is not the owner");
        limiter.setCapacity(100 ether);

        vm.expectRevert("Ownable: caller is not the owner");
        limiter.setRefillRatePerSecond(100 ether);

        vm.expectRevert("Ownable: caller is not the owner");
        limiter.updateConsumer(address(0));
    }
    
    function test_pauser() public {
        address alice = address(1);
        address bob = address(2);
        address chad = address(3);

        vm.expectRevert("Ownable: caller is not the owner");
        limiter.updatePauser(alice, true);

        vm.prank(alice);
        vm.expectRevert("NOT_PAUSER");
        limiter.pauseContract();

        assertEq(limiter.pausers(alice), false);

        vm.startPrank(limiter.owner());
        limiter.updatePauser(alice, true);
        vm.stopPrank();

        assertEq(limiter.pausers(alice), true);

        vm.prank(chad);
        vm.expectRevert("NOT_PAUSER");
        limiter.pauseContract();

        vm.prank(alice);
        limiter.pauseContract();

        vm.prank(alice);
        vm.expectRevert("NOT_ADMIN");
        limiter.unPauseContract();

        vm.prank(limiter.owner());
        limiter.updateAdmin(bob, true);

        vm.prank(bob);
        limiter.unPauseContract();
    }

    // ============ canConsume Tests ============

    function test_canConsume_returnsTrue_whenWithinLimits() public {
        vm.startPrank(limiter.owner());
        vm.warp(block.timestamp + 1);
        
        assertTrue(limiter.canConsume(address(0), 50 ether, 50 ether));
        
        limiter.updateRateLimit(address(0), address(0), 50 ether, 50 ether);
        
        assertFalse(limiter.canConsume(address(0), 50 ether, 50 ether));
        
        vm.warp(block.timestamp + 1);
        assertTrue(limiter.canConsume(address(0), 50 ether, 50 ether));
        
        vm.stopPrank();
    }

    function test_canConsume_respectsTokenLimits() public {
        vm.startPrank(limiter.owner());
        address token = address(1);
        limiter.registerToken(token, 100 ether, 100 ether);
        limiter.setCapacity(1000 ether);
        limiter.setRefillRatePerSecond(1000 ether);
        
        vm.warp(block.timestamp + 1);
        
        assertTrue(limiter.canConsume(token, 50 ether, 50 ether));
        
        limiter.updateRateLimit(address(0), token, 50 ether, 50 ether);
        
        assertFalse(limiter.canConsume(token, 50 ether, 50 ether));
        
        vm.warp(block.timestamp + 1);
        assertTrue(limiter.canConsume(token, 50 ether, 50 ether));
        
        vm.stopPrank();
    }

    function test_canConsume_unregisteredToken_bypassesTokenLimit() public {
        vm.startPrank(limiter.owner());
        address unregisteredToken = address(999);
        
        vm.warp(block.timestamp + 1);
        
        assertTrue(limiter.canConsume(unregisteredToken, 50 ether, 50 ether));
        
        limiter.updateRateLimit(address(0), unregisteredToken, 50 ether, 50 ether);
        
        assertFalse(limiter.canConsume(unregisteredToken, 50 ether, 50 ether));
        
        vm.stopPrank();
    }

    function test_canConsume_checksBothLimits() public {
        vm.startPrank(limiter.owner());
        address token = address(1);
        limiter.registerToken(token, 50 ether, 50 ether);
        limiter.setCapacity(100 ether);
        limiter.setRefillRatePerSecond(100 ether);
        
        vm.warp(block.timestamp + 1);
        
        assertTrue(limiter.canConsume(token, 25 ether, 25 ether));
        
        limiter.updateRateLimit(address(0), address(0), 50 ether, 50 ether);
        
        assertFalse(limiter.canConsume(token, 25 ether, 25 ether));
        
        vm.warp(block.timestamp + 1);
        
        limiter.setCapacity(1000 ether);
        limiter.setRefillRatePerSecond(1000 ether);
        vm.warp(block.timestamp + 1);
        
        limiter.updateRateLimit(address(0), token, 50 ether, 0);
        
        assertFalse(limiter.canConsume(token, 1 ether, 0));
        
        vm.stopPrank();
    }

    // ============ Refill Behavior Tests ============

    function test_refill_overTime() public {
        vm.startPrank(limiter.owner());
        
        // Bucket starts empty after setUp (setCapacity doesn't fill it)
        // Wait for initial refill (capacity = 200 ether, refillRate = 100 ether/sec)
        // Need to wait 2 seconds to get 200 ether
        vm.warp(block.timestamp + 2);
        
        // Now should have 200 ether available
        assertTrue(limiter.canConsume(address(0), 200 ether, 0));
        
        // Consume all capacity (100 + 100 = 200 ether)
        limiter.updateRateLimit(address(0), address(0), 100 ether, 100 ether);
        
        // Should be exhausted (consumed 200 ether, capacity is 200 ether)
        assertFalse(limiter.canConsume(address(0), 1 ether, 0));
        
        // Wait 1 second - should refill 100 ether (refillRate = 100 ether/sec)
        vm.warp(block.timestamp + 1);
        assertTrue(limiter.canConsume(address(0), 100 ether, 0));
        assertFalse(limiter.canConsume(address(0), 101 ether, 0));
        
        // Consume 100 ether
        limiter.updateRateLimit(address(0), address(0), 50 ether, 50 ether);
        
        // Wait 2 seconds - should refill 200 ether (2 * 100 ether/sec), but capped at capacity (200 ether)
        vm.warp(block.timestamp + 2);
        assertTrue(limiter.canConsume(address(0), 200 ether, 0));
        assertFalse(limiter.canConsume(address(0), 201 ether, 0));
        
        vm.stopPrank();
    }

    function test_refill_cappedAtCapacity() public {
        vm.startPrank(limiter.owner());
        
        limiter.setCapacity(200 ether);
        limiter.setRefillRatePerSecond(100 ether);
        
        // Wait for initial refill
        vm.warp(block.timestamp + 2);
        
        // Consume all capacity
        limiter.updateRateLimit(address(0), address(0), 200 ether, 0);
        
        // Verify exhausted
        assertFalse(limiter.canConsume(address(0), 1 ether, 0));
        
        // Wait 10 seconds - should only refill to capacity (200 ether), not 1000 ether (10 * 100)
        vm.warp(block.timestamp + 10);
        assertTrue(limiter.canConsume(address(0), 200 ether, 0));
        assertFalse(limiter.canConsume(address(0), 201 ether, 0));
        
        vm.stopPrank();
    }

    function test_refill_zeroRefillRate() public {
        vm.startPrank(limiter.owner());
        
        limiter.setCapacity(200 ether);
        limiter.setRefillRatePerSecond(100 ether);
        
        // Wait for initial refill
        vm.warp(block.timestamp + 2);
        
        // Set refill rate to 0
        limiter.setRefillRatePerSecond(0);
        
        // Consume 100 ether
        limiter.updateRateLimit(address(0), address(0), 100 ether, 0);
        
        // Verify consumed 100 ether, 100 ether remaining
        assertTrue(limiter.canConsume(address(0), 100 ether, 0));
        assertFalse(limiter.canConsume(address(0), 101 ether, 0));
        
        // Wait a long time - should not refill (refillRate = 0)
        vm.warp(block.timestamp + 1000);
        assertTrue(limiter.canConsume(address(0), 100 ether, 0));
        assertFalse(limiter.canConsume(address(0), 101 ether, 0));
        
        vm.stopPrank();
    }

    function test_refill_largeTimeGap() public {
        vm.startPrank(limiter.owner());
        
        limiter.setCapacity(200 ether);
        limiter.setRefillRatePerSecond(100 ether);
        
        // Wait for initial refill
        vm.warp(block.timestamp + 2);
        
        limiter.updateRateLimit(address(0), address(0), 200 ether, 0);
        
        // Verify exhausted
        assertFalse(limiter.canConsume(address(0), 1 ether, 0));
        
        // Wait a very long time - should cap at capacity (200 ether), not overflow
        vm.warp(block.timestamp + 1000000);
        assertTrue(limiter.canConsume(address(0), 200 ether, 0));
        assertFalse(limiter.canConsume(address(0), 201 ether, 0));
        
        vm.stopPrank();
    }

    function test_refill_perToken() public {
        vm.startPrank(limiter.owner());
        address token = address(1);
        limiter.registerToken(token, 100 ether, 50 ether);
        limiter.setCapacity(1000 ether);
        limiter.setRefillRatePerSecond(1000 ether);
        
        vm.warp(block.timestamp + 1);
        limiter.updateRateLimit(address(0), token, 100 ether, 0);
        
        // Token limit exhausted
        assertFalse(limiter.canConsume(token, 1 ether, 0));
        
        // Wait 1 second - token should refill 50 ether
        vm.warp(block.timestamp + 1);
        assertTrue(limiter.canConsume(token, 50 ether, 0));
        assertFalse(limiter.canConsume(token, 51 ether, 0));
        
        vm.stopPrank();
    }

    // ============ setCapacity Tests ============

    function test_setCapacity_reducesRemainingIfLower() public {
        vm.startPrank(limiter.owner());
        
        limiter.setCapacity(200 ether);
        limiter.setRefillRatePerSecond(100 ether);
        
        vm.warp(block.timestamp + 1);
        limiter.updateRateLimit(address(0), address(0), 50 ether, 0);
        
        // Remaining should be 150 ether
        vm.warp(block.timestamp + 1);
        assertTrue(limiter.canConsume(address(0), 150 ether, 0));
        
        // Reduce capacity to 100 ether - remaining should be capped
        limiter.setCapacity(100 ether);
        assertTrue(limiter.canConsume(address(0), 100 ether, 0));
        assertFalse(limiter.canConsume(address(0), 101 ether, 0));
        
        vm.stopPrank();
    }

    function test_setCapacity_increasesCapacity() public {
        vm.startPrank(limiter.owner());
        
        limiter.setCapacity(100 ether);
        limiter.setRefillRatePerSecond(100 ether);
        
        // Wait for initial refill
        vm.warp(block.timestamp + 1);
        limiter.updateRateLimit(address(0), address(0), 100 ether, 0);
        
        // Verify exhausted
        assertFalse(limiter.canConsume(address(0), 1 ether, 0));
        
        // Wait 1 second for refill
        vm.warp(block.timestamp + 1);
        
        // Increase capacity (setCapacity refills first, then sets capacity)
        limiter.setCapacity(200 ether);
        
        // After setCapacity: refilled 100 ether, capacity set to 200 ether, remaining = 100 ether
        // Wait for more refill to reach new capacity
        vm.warp(block.timestamp + 1);
        // After another second: 100 + 100 = 200 ether (capped at capacity)
        assertTrue(limiter.canConsume(address(0), 200 ether, 0));
        
        vm.stopPrank();
    }

    function test_setCapacity_zeroCapacity() public {
        vm.startPrank(limiter.owner());
        
        limiter.setCapacity(0);
        
        vm.warp(block.timestamp + 1);
        assertFalse(limiter.canConsume(address(0), 1, 0));
        
        vm.expectRevert("BucketRateLimiter: rate limit exceeded");
        limiter.updateRateLimit(address(0), address(0), 1, 0);
        
        vm.stopPrank();
    }

    function test_setCapacity_refillsBeforeSetting() public {
        vm.startPrank(limiter.owner());
        
        limiter.setCapacity(200 ether);
        limiter.setRefillRatePerSecond(100 ether);
        
        // Wait for initial refill
        vm.warp(block.timestamp + 2);
        limiter.updateRateLimit(address(0), address(0), 200 ether, 0);
        
        // Verify exhausted
        assertFalse(limiter.canConsume(address(0), 1 ether, 0));
        
        // Wait 2 seconds
        vm.warp(block.timestamp + 2);
        
        // Setting capacity should refill first (2 seconds * 100 ether/sec = 200 ether),
        // then set capacity to 150 ether (capping remaining at 150)
        limiter.setCapacity(150 ether);
        
        // Should have 150 ether (refilled 200, but capped at 150)
        assertTrue(limiter.canConsume(address(0), 150 ether, 0));
        assertFalse(limiter.canConsume(address(0), 151 ether, 0));
        
        vm.stopPrank();
    }

    // ============ setRefillRatePerSecond Tests ============

    function test_setRefillRatePerSecond_changesRefillRate() public {
        vm.startPrank(limiter.owner());
        
        limiter.setCapacity(200 ether);
        limiter.setRefillRatePerSecond(50 ether);
        
        // Wait for initial refill (need 4 seconds: 200 / 50 = 4)
        vm.warp(block.timestamp + 4);
        limiter.updateRateLimit(address(0), address(0), 200 ether, 0);
        
        // Verify exhausted
        assertFalse(limiter.canConsume(address(0), 1 ether, 0));
        
        // Wait 1 second - should refill 50 ether
        vm.warp(block.timestamp + 1);
        assertTrue(limiter.canConsume(address(0), 50 ether, 0));
        assertFalse(limiter.canConsume(address(0), 51 ether, 0));
        
        // Increase refill rate
        limiter.setRefillRatePerSecond(100 ether);
        
        // Wait 1 second - should now refill 100 ether (new rate)
        vm.warp(block.timestamp + 1);
        // Previous: 50 ether, new refill: 100 ether, total: 150 ether
        assertTrue(limiter.canConsume(address(0), 150 ether, 0));
        assertFalse(limiter.canConsume(address(0), 151 ether, 0));
        
        vm.stopPrank();
    }

    function test_setRefillRatePerSecond_zeroRate() public {
        vm.startPrank(limiter.owner());
        
        limiter.setCapacity(200 ether);
        limiter.setRefillRatePerSecond(100 ether);
        
        vm.warp(block.timestamp + 2);
        limiter.updateRateLimit(address(0), address(0), 50 ether, 50 ether);
        
        assertTrue(limiter.canConsume(address(0), 100 ether, 0));
        assertFalse(limiter.canConsume(address(0), 101 ether, 0));
        
        limiter.setRefillRatePerSecond(0);
        
        vm.warp(block.timestamp + 1000);
        assertTrue(limiter.canConsume(address(0), 100 ether, 0));
        assertFalse(limiter.canConsume(address(0), 101 ether, 0));
        
        vm.stopPrank();
    }

    function test_setRefillRatePerSecond_refillsBeforeSetting() public {
        vm.startPrank(limiter.owner());
        
        limiter.setCapacity(200 ether);
        limiter.setRefillRatePerSecond(100 ether);
        
        // Wait for initial refill
        vm.warp(block.timestamp + 2);
        limiter.updateRateLimit(address(0), address(0), 200 ether, 0);
        
        // Verify exhausted
        assertFalse(limiter.canConsume(address(0), 1 ether, 0));
        
        // Wait 2 seconds
        vm.warp(block.timestamp + 2);
        
        // Setting refill rate should refill first (2 seconds * 100 ether/sec = 200 ether)
        limiter.setRefillRatePerSecond(50 ether);
        
        // Should have refilled 200 ether (2 seconds * 100 ether/sec), capped at capacity (200 ether)
        assertTrue(limiter.canConsume(address(0), 200 ether, 0));
        assertFalse(limiter.canConsume(address(0), 201 ether, 0));
        
        vm.stopPrank();
    }

    // ============ registerToken Tests ============

    function test_registerToken_createsNewLimit() public {
        vm.startPrank(limiter.owner());
        address token = address(1);
        
        limiter.registerToken(token, 100 ether, 50 ether);
        
        vm.warp(block.timestamp + 1);
        assertTrue(limiter.canConsume(token, 100 ether, 0));
        
        limiter.updateRateLimit(address(0), token, 100 ether, 0);
        
        assertFalse(limiter.canConsume(token, 1 ether, 0));
        
        vm.warp(block.timestamp + 1);
        assertTrue(limiter.canConsume(token, 50 ether, 0));
        
        vm.stopPrank();
    }

    function test_registerToken_overwritesExisting() public {
        vm.startPrank(limiter.owner());
        address token = address(1);
        
        limiter.setCapacity(1000 ether);
        limiter.setRefillRatePerSecond(1000 ether);
        
        limiter.registerToken(token, 100 ether, 50 ether);
        
        vm.warp(block.timestamp + 1);
        limiter.updateRateLimit(address(0), token, 50 ether, 0);
        
        // Verify token limit partially consumed
        assertTrue(limiter.canConsume(token, 50 ether, 0));
        assertFalse(limiter.canConsume(token, 51 ether, 0));
        
        // Overwrite with new limits (this resets the bucket)
        limiter.registerToken(token, 200 ether, 100 ether);
        
        // Should reset to new capacity (200 ether)
        vm.warp(block.timestamp + 1);
        assertTrue(limiter.canConsume(token, 200 ether, 0));
        
        limiter.updateRateLimit(address(0), token, 200 ether, 0);
        
        // Should refill at new rate (100 ether/sec)
        vm.warp(block.timestamp + 1);
        assertTrue(limiter.canConsume(token, 100 ether, 0));
        assertFalse(limiter.canConsume(token, 101 ether, 0));
        
        vm.stopPrank();
    }

    function test_registerToken_multipleTokens() public {
        vm.startPrank(limiter.owner());
        address token1 = address(1);
        address token2 = address(2);
        address token3 = address(3);
        
        limiter.setCapacity(1000 ether);
        limiter.setRefillRatePerSecond(1000 ether);
        
        limiter.registerToken(token1, 100 ether, 50 ether);
        limiter.registerToken(token2, 200 ether, 100 ether);
        limiter.registerToken(token3, 300 ether, 150 ether);
        
        vm.warp(block.timestamp + 1);
        
        // Each token should have its own limit
        assertTrue(limiter.canConsume(token1, 100 ether, 0));
        assertTrue(limiter.canConsume(token2, 200 ether, 0));
        assertTrue(limiter.canConsume(token3, 300 ether, 0));
        
        limiter.updateRateLimit(address(0), token1, 100 ether, 0);
        limiter.updateRateLimit(address(0), token2, 200 ether, 0);
        limiter.updateRateLimit(address(0), token3, 300 ether, 0);
        
        // Each should be exhausted independently
        assertFalse(limiter.canConsume(token1, 1 ether, 0));
        assertFalse(limiter.canConsume(token2, 1 ether, 0));
        assertFalse(limiter.canConsume(token3, 1 ether, 0));
        
        vm.warp(block.timestamp + 1);
        
        // Each should refill at its own rate
        assertTrue(limiter.canConsume(token1, 50 ether, 0));
        assertTrue(limiter.canConsume(token2, 100 ether, 0));
        assertTrue(limiter.canConsume(token3, 150 ether, 0));
        
        vm.stopPrank();
    }

    function test_registerToken_zeroValues() public {
        vm.startPrank(limiter.owner());
        address token = address(1);
        
        limiter.registerToken(token, 0, 0);
        
        vm.warp(block.timestamp + 1);
        assertFalse(limiter.canConsume(token, 1, 0));
        
        vm.expectRevert("BucketRateLimiter: token rate limit exceeded");
        limiter.updateRateLimit(address(0), token, 1, 0);
        
        vm.stopPrank();
    }

    // ============ setCapacityPerToken Tests ============

    function test_setCapacityPerToken_updatesTokenCapacity() public {
        vm.startPrank(limiter.owner());
        address token = address(1);
        
        limiter.registerToken(token, 100 ether, 50 ether);
        limiter.setCapacity(1000 ether);
        limiter.setRefillRatePerSecond(1000 ether);
        
        vm.warp(block.timestamp + 1);
        limiter.updateRateLimit(address(0), token, 50 ether, 0);
        
        assertTrue(limiter.canConsume(token, 50 ether, 0));
        assertFalse(limiter.canConsume(token, 51 ether, 0));
        
        limiter.setCapacityPerToken(token, 200 ether);
        
        vm.warp(block.timestamp + 1);
        assertTrue(limiter.canConsume(token, 100 ether, 0));
        assertFalse(limiter.canConsume(token, 101 ether, 0));
        
        vm.warp(block.timestamp + 1);
        assertTrue(limiter.canConsume(token, 150 ether, 0));
        assertFalse(limiter.canConsume(token, 151 ether, 0));
        
        vm.warp(block.timestamp + 1);
        assertTrue(limiter.canConsume(token, 200 ether, 0));
        assertFalse(limiter.canConsume(token, 201 ether, 0));
        
        vm.stopPrank();
    }

    function test_setCapacityPerToken_reducesTokenCapacity() public {
        vm.startPrank(limiter.owner());
        address token = address(1);
        
        limiter.registerToken(token, 200 ether, 100 ether);
        limiter.setCapacity(1000 ether);
        limiter.setRefillRatePerSecond(1000 ether);
        
        vm.warp(block.timestamp + 1);
        limiter.updateRateLimit(address(0), token, 50 ether, 0);
        
        // Reduce token capacity
        limiter.setCapacityPerToken(token, 100 ether);
        
        vm.warp(block.timestamp + 1);
        // Should be capped at 100 ether
        assertTrue(limiter.canConsume(token, 100 ether, 0));
        assertFalse(limiter.canConsume(token, 101 ether, 0));
        
        vm.stopPrank();
    }

    function test_setCapacityPerToken_refillsBeforeSetting() public {
        vm.startPrank(limiter.owner());
        address token = address(1);
        
        limiter.registerToken(token, 200 ether, 100 ether);
        limiter.setCapacity(1000 ether);
        limiter.setRefillRatePerSecond(1000 ether);
        
        vm.warp(block.timestamp + 1);
        limiter.updateRateLimit(address(0), token, 200 ether, 0);
        
        // Wait 2 seconds
        vm.warp(block.timestamp + 2);
        
        // Setting capacity should refill first
        limiter.setCapacityPerToken(token, 150 ether);
        
        // Should have refilled 200 ether, but capped at 150
        assertTrue(limiter.canConsume(token, 150 ether, 0));
        assertFalse(limiter.canConsume(token, 151 ether, 0));
        
        vm.stopPrank();
    }

    // ============ setRefillRatePerSecondPerToken Tests ============

    function test_setRefillRatePerSecondPerToken_updatesTokenRefillRate() public {
        vm.startPrank(limiter.owner());
        address token = address(1);
        
        limiter.registerToken(token, 200 ether, 50 ether);
        limiter.setCapacity(1000 ether);
        limiter.setRefillRatePerSecond(1000 ether);
        
        vm.warp(block.timestamp + 1);
        limiter.updateRateLimit(address(0), token, 200 ether, 0);
        
        // Wait 1 second - should refill 50 ether
        vm.warp(block.timestamp + 1);
        assertTrue(limiter.canConsume(token, 50 ether, 0));
        assertFalse(limiter.canConsume(token, 51 ether, 0));
        
        // Increase token refill rate
        limiter.setRefillRatePerSecondPerToken(token, 100 ether);
        
        // Wait 1 second - should now refill 100 ether
        vm.warp(block.timestamp + 1);
        assertTrue(limiter.canConsume(token, 150 ether, 0));
        assertFalse(limiter.canConsume(token, 151 ether, 0));
        
        vm.stopPrank();
    }

    function test_setRefillRatePerSecondPerToken_zeroRate() public {
        vm.startPrank(limiter.owner());
        address token = address(1);
        
        limiter.registerToken(token, 200 ether, 100 ether);
        limiter.setCapacity(1000 ether);
        limiter.setRefillRatePerSecond(1000 ether);
        
        vm.warp(block.timestamp + 1);
        limiter.updateRateLimit(address(0), token, 100 ether, 0);
        
        // Set token refill rate to 0
        limiter.setRefillRatePerSecondPerToken(token, 0);
        
        // Wait a long time - should not refill
        vm.warp(block.timestamp + 1000);
        assertTrue(limiter.canConsume(token, 100 ether, 0));
        assertFalse(limiter.canConsume(token, 101 ether, 0));
        
        vm.stopPrank();
    }

    function test_setRefillRatePerSecondPerToken_refillsBeforeSetting() public {
        vm.startPrank(limiter.owner());
        address token = address(1);
        
        limiter.registerToken(token, 200 ether, 100 ether);
        limiter.setCapacity(1000 ether);
        limiter.setRefillRatePerSecond(1000 ether);
        
        vm.warp(block.timestamp + 1);
        limiter.updateRateLimit(address(0), token, 200 ether, 0);
        
        // Wait 2 seconds
        vm.warp(block.timestamp + 2);
        
        // Setting refill rate should refill first
        limiter.setRefillRatePerSecondPerToken(token, 50 ether);
        
        // Should have refilled 200 ether (2 seconds * 100 ether/sec)
        assertTrue(limiter.canConsume(token, 200 ether, 0));
        
        vm.stopPrank();
    }

    // ============ updateConsumer Tests ============

    function test_updateConsumer_changesConsumer() public {
        vm.startPrank(limiter.owner());
        
        address newConsumer = address(999);
        limiter.updateConsumer(newConsumer);
        
        assertEq(limiter.consumer(), newConsumer);
        
        vm.stopPrank();
    }

    function test_updateConsumer_onlyConsumerCanCall() public {
        vm.startPrank(limiter.owner());
        
        address consumer = limiter.consumer();
        address nonConsumer = address(999);
        
        vm.stopPrank();
        
        vm.prank(nonConsumer);
        vm.expectRevert("NOT_CONSUMER");
        limiter.updateRateLimit(address(0), address(0), 1 ether, 0);
        
        vm.startPrank(consumer);
        vm.warp(block.timestamp + 1);
        limiter.updateRateLimit(address(0), address(0), 1 ether, 0);
        vm.stopPrank();
    }

    function test_updateConsumer_accessControl() public {
        address nonOwner = address(999);
        
        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        limiter.updateConsumer(address(999));
    }

    // ============ Admin Tests ============

    function test_updateAdmin_emitsEvent() public {
        vm.startPrank(limiter.owner());
        
        address admin = address(1);
        
        vm.expectEmit(true, false, false, false);
        emit BucketRateLimiter.UpdatedAdmin(admin, true);
        limiter.updateAdmin(admin, true);
        
        assertEq(limiter.admins(admin), true);
        
        vm.expectEmit(true, false, false, false);
        emit BucketRateLimiter.UpdatedAdmin(admin, false);
        limiter.updateAdmin(admin, false);
        
        assertEq(limiter.admins(admin), false);
        
        vm.stopPrank();
    }

    function test_updateAdmin_canPause() public {
        vm.startPrank(limiter.owner());
        
        address admin = address(1);
        limiter.updateAdmin(admin, true);
        
        vm.stopPrank();
        
        vm.prank(admin);
        limiter.pauseContract();
        
        assertTrue(limiter.paused());
        
        vm.prank(admin);
        limiter.unPauseContract();
        
        assertFalse(limiter.paused());
    }

    function test_updateAdmin_canUnpause() public {
        vm.startPrank(limiter.owner());
        
        address admin = address(1);
        limiter.updateAdmin(admin, true);
        limiter.pauseContract();
        
        vm.stopPrank();
        
        vm.prank(admin);
        limiter.unPauseContract();
        
        assertFalse(limiter.paused());
    }

    // ============ Pauser Tests ============

    function test_updatePauser_emitsEvent() public {
        vm.startPrank(limiter.owner());
        
        address pauser = address(1);
        
        vm.expectEmit(true, false, false, false);
        emit BucketRateLimiter.UpdatedPauser(pauser, true);
        limiter.updatePauser(pauser, true);
        
        assertEq(limiter.pausers(pauser), true);
        
        vm.expectEmit(true, false, false, false);
        emit BucketRateLimiter.UpdatedPauser(pauser, false);
        limiter.updatePauser(pauser, false);
        
        assertEq(limiter.pausers(pauser), false);
        
        vm.stopPrank();
    }

    function test_updatePauser_ownerCanPause() public {
        vm.startPrank(limiter.owner());
        
        limiter.pauseContract();
        assertTrue(limiter.paused());
        
        limiter.unPauseContract();
        assertFalse(limiter.paused());
        
        vm.stopPrank();
    }

    function test_updatePauser_adminCanPause() public {
        vm.startPrank(limiter.owner());
        
        address admin = address(1);
        limiter.updateAdmin(admin, true);
        
        vm.stopPrank();
        
        vm.prank(admin);
        limiter.pauseContract();
        
        assertTrue(limiter.paused());
        
        vm.stopPrank();
    }

    // ============ Pause Integration Tests ============

    function test_paused_blocksUpdateRateLimit() public {
        vm.startPrank(limiter.owner());
        
        limiter.pauseContract();
        
        vm.warp(block.timestamp + 1);
        vm.expectRevert("Pausable: paused");
        limiter.updateRateLimit(address(0), address(0), 1 ether, 0);
        
        limiter.unPauseContract();
        
        limiter.updateRateLimit(address(0), address(0), 1 ether, 0);
        
        vm.stopPrank();
    }

    function test_paused_allowsViewFunctions() public {
        vm.startPrank(limiter.owner());
        
        limiter.pauseContract();
        
        // View functions should still work
        assertFalse(limiter.canConsume(address(0), 1 ether, 0));
        
        vm.stopPrank();
    }

    // ============ Rounding Tests ============

    function test_rounding_roundsUp() public {
        vm.startPrank(limiter.owner());
        
        vm.warp(block.timestamp + 2);
        limiter.updateRateLimit(address(0), address(0), 0, 1e12 - 1);
        
        vm.warp(block.timestamp + 2);
        limiter.updateRateLimit(address(0), address(0), 200 ether, 0);
        
        assertFalse(limiter.canConsume(address(0), 1e12, 0));
        
        vm.stopPrank();
    }

    function test_rounding_exactMultiple() public {
        vm.startPrank(limiter.owner());
        
        // Exactly 1e12 should be 1 unit
        vm.warp(block.timestamp + 1);
        limiter.updateRateLimit(address(0), address(0), 0, 1e12);
        
        // Should have consumed 1 unit
        vm.warp(block.timestamp + 1);
        assertTrue(limiter.canConsume(address(0), 100 ether, 0));
        
        vm.stopPrank();
    }

    function test_rounding_combinesAmounts() public {
        vm.startPrank(limiter.owner());
        
        vm.warp(block.timestamp + 2);
        limiter.updateRateLimit(address(0), address(0), 0.5e12, 0.5e12);
        
        vm.warp(block.timestamp + 2);
        limiter.updateRateLimit(address(0), address(0), 200 ether, 0);
        
        assertFalse(limiter.canConsume(address(0), 1e12, 0));
        
        vm.stopPrank();
    }

    function test_rounding_largeValues() public {
        vm.startPrank(limiter.owner());
        
        limiter.setCapacity(1000 ether);
        limiter.setRefillRatePerSecond(1000 ether);
        
        // Test with very large values
        vm.warp(block.timestamp + 1);
        limiter.updateRateLimit(address(0), address(0), 500 ether, 500 ether);
        
        // Should consume (500 + 500) / 1e12 = 1e21 / 1e12 = 1e9 units
        vm.warp(block.timestamp + 1);
        assertTrue(limiter.canConsume(address(0), 500 ether, 0));
        
        vm.stopPrank();
    }

    // ============ Edge Cases ============

    function test_edgeCase_zeroAmounts() public {
        vm.startPrank(limiter.owner());
        
        vm.warp(block.timestamp + 2);
        
        limiter.updateRateLimit(address(0), address(0), 0, 0);
        
        assertTrue(limiter.canConsume(address(0), 200 ether, 0));
        
        vm.stopPrank();
    }

    function test_edgeCase_verySmallAmounts() public {
        vm.startPrank(limiter.owner());
        
        vm.warp(block.timestamp + 2);
        
        limiter.updateRateLimit(address(0), address(0), 1, 1);
        
        vm.warp(block.timestamp + 2);
        limiter.updateRateLimit(address(0), address(0), 200 ether, 0);
        
        assertFalse(limiter.canConsume(address(0), 1, 0));
        
        vm.stopPrank();
    }

    function test_edgeCase_maxCapacity() public {
        vm.startPrank(limiter.owner());
        
        // Set to maximum practical capacity (max uint64 * 1e12)
        uint256 maxCapacity = uint256(type(uint64).max) * 1e12;
        limiter.setCapacity(maxCapacity);
        limiter.setRefillRatePerSecond(maxCapacity);
        
        vm.warp(block.timestamp + 1);
        assertTrue(limiter.canConsume(address(0), maxCapacity, 0));
        
        vm.stopPrank();
    }

    function test_edgeCase_unregisteredTokenAfterRegistration() public {
        vm.startPrank(limiter.owner());
        address token = address(1);
        
        // Register token
        limiter.registerToken(token, 100 ether, 50 ether);
        
        vm.warp(block.timestamp + 1);
        limiter.updateRateLimit(address(0), token, 50 ether, 0);
        
        // Overwrite with zero capacity/rate (effectively unregistering)
        limiter.registerToken(token, 0, 0);
        
        // Should now be blocked
        vm.warp(block.timestamp + 1);
        assertFalse(limiter.canConsume(token, 1, 0));
        
        vm.stopPrank();
    }

    // ============ Complex Scenarios ============

    function test_complex_bothLimitsExhausted() public {
        vm.startPrank(limiter.owner());
        address token = address(1);
        
        limiter.registerToken(token, 100 ether, 50 ether);
        limiter.setCapacity(1000 ether);
        limiter.setRefillRatePerSecond(1000 ether);
        
        vm.warp(block.timestamp + 1);
        
        limiter.updateRateLimit(address(0), address(0), 50 ether, 50 ether);
        
        limiter.updateRateLimit(address(0), token, 50 ether, 50 ether);
        
        assertFalse(limiter.canConsume(token, 1 ether, 0));
        
        vm.warp(block.timestamp + 1);
        assertTrue(limiter.canConsume(token, 50 ether, 0));
        assertFalse(limiter.canConsume(token, 51 ether, 0));
        
        vm.stopPrank();
    }

    function test_complex_globalLimitBlocksTokenLimit() public {
        vm.startPrank(limiter.owner());
        address token = address(1);
        
        limiter.registerToken(token, 200 ether, 100 ether);
        limiter.setCapacity(100 ether);
        limiter.setRefillRatePerSecond(50 ether);
        
        vm.warp(block.timestamp + 1);
        
        assertFalse(limiter.canConsume(token, 101 ether, 0));
        assertTrue(limiter.canConsume(token, 50 ether, 0));
        
        limiter.updateRateLimit(address(0), token, 50 ether, 0);
        
        assertFalse(limiter.canConsume(token, 1 ether, 0));
        assertFalse(limiter.canConsume(address(0), 1 ether, 0));
        
        vm.stopPrank();
    }

    function test_complex_tokenLimitBlocksGlobalLimit() public {
        vm.startPrank(limiter.owner());
        address token = address(1);
        
        limiter.registerToken(token, 50 ether, 25 ether);
        limiter.setCapacity(200 ether);
        limiter.setRefillRatePerSecond(100 ether);
        
        vm.warp(block.timestamp + 1);
        
        // Token limit is lower, should block even though global limit allows it
        assertFalse(limiter.canConsume(token, 100 ether, 0));
        assertTrue(limiter.canConsume(token, 50 ether, 0));
        
        limiter.updateRateLimit(address(0), token, 50 ether, 0);
        
        // Token limit exhausted, global limit still has capacity
        assertFalse(limiter.canConsume(token, 1 ether, 0));
        
        vm.stopPrank();
    }

    function test_complex_multipleTokensDifferentLimits() public {
        vm.startPrank(limiter.owner());
        address token1 = address(1);
        address token2 = address(2);
        
        limiter.setCapacity(1000 ether);
        limiter.setRefillRatePerSecond(1000 ether);
        
        limiter.registerToken(token1, 100 ether, 50 ether);
        limiter.registerToken(token2, 200 ether, 100 ether);
        
        vm.warp(block.timestamp + 1);
        
        // Consume from both tokens
        limiter.updateRateLimit(address(0), token1, 100 ether, 0);
        limiter.updateRateLimit(address(0), token2, 200 ether, 0);
        
        // Both should be exhausted
        assertFalse(limiter.canConsume(token1, 1 ether, 0));
        assertFalse(limiter.canConsume(token2, 1 ether, 0));
        
        // Wait 1 second
        vm.warp(block.timestamp + 1);
        
        // Each should refill at its own rate
        assertTrue(limiter.canConsume(token1, 50 ether, 0));
        assertTrue(limiter.canConsume(token2, 100 ether, 0));
        
        vm.stopPrank();
    }

    // ============ UUPS Upgrade Tests ============

    function test_getImplementation() public {
        address impl = limiter.getImplementation();
        assertNotEq(impl, address(0));
        assertNotEq(impl, address(limiter));
    }

    function test_upgrade_onlyOwner() public {
        vm.startPrank(limiter.owner());
        
        BucketRateLimiter newImpl = new BucketRateLimiter();
        
        limiter.upgradeTo(address(newImpl));
        
        assertEq(limiter.getImplementation(), address(newImpl));
        
        vm.stopPrank();
    }

    function test_upgrade_nonOwnerReverts() public {
        address nonOwner = address(999);
        
        BucketRateLimiter newImpl = new BucketRateLimiter();
        
        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        limiter.upgradeTo(address(newImpl));
    }

    function test_upgrade_preservesState() public {
        vm.startPrank(limiter.owner());
        
        // Set some state
        limiter.setCapacity(500 ether);
        limiter.setRefillRatePerSecond(250 ether);
        address consumer = address(123);
        limiter.updateConsumer(consumer);
        
        // Upgrade
        BucketRateLimiter newImpl = new BucketRateLimiter();
        limiter.upgradeTo(address(newImpl));
        
        // State should be preserved
        assertEq(limiter.consumer(), consumer);
        
        vm.warp(block.timestamp + 1);
        assertTrue(limiter.canConsume(address(0), 250 ether, 0));
        
        vm.stopPrank();
    }
}