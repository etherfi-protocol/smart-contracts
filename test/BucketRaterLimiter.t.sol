// SPDX-License-Identifier: UNLICENSED
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
        limiter.setCapacity(100 ether);

        vm.expectRevert("Ownable: caller is not the owner");
        limiter.setRefillRatePerSecond(100 ether);

        vm.expectRevert("Ownable: caller is not the owner");
        limiter.updateConsumer(address(0));
    }
    
    function test_pauser() public {
        

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

}