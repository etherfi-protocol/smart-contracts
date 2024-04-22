// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "../../src/BucketRateLimiter.sol";
import "../../src/UUPSProxy.sol";

interface IL2SyncPool {
    function setRateLimiter(address rateLimiter) external;
}

contract Deploy is Script {

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address l2syncpool;

        if (block.chainid == 59144) l2syncpool = 0x823106E745A62D0C2FC4d27644c62aDE946D9CCa; // LINEA
        else if (block.chainid == 81457) l2syncpool = 0x52c4221Cb805479954CDE5accfF8C4DcaF96623B; // BLAST
        else if (block.chainid == 34443) l2syncpool = 0x52c4221Cb805479954CDE5accfF8C4DcaF96623B; // MODE
        else revert("Unsupported chain id");

        vm.startBroadcast(deployerPrivateKey);

        BucketRateLimiter impl = new BucketRateLimiter();
        UUPSProxy proxy = new UUPSProxy(address(impl), "");
        BucketRateLimiter limiter = BucketRateLimiter(address(proxy));
        limiter.initialize();

        limiter.updateConsumer(l2syncpool);
        IL2SyncPool(l2syncpool).setRateLimiter(address(limiter));

        vm.stopBroadcast();



        // TEST

        vm.startPrank(deployer);
        limiter.setCapacity(0.0002 ether);
        limiter.setRefillRatePerSecond(0.0002 ether);
        vm.stopPrank();

        vm.prank(l2syncpool);
        vm.expectRevert("BucketRateLimiter: rate limit exceeded");
        limiter.updateRateLimit(address(0), address(0), 0.0001 ether, 0.0001 ether);

        vm.prank(l2syncpool);
        vm.warp(block.timestamp + 1);
        limiter.updateRateLimit(address(0), address(0), 0.0001 ether, 0.0001 ether);
    }

}