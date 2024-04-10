// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "src/BucketRateLimiter.sol";

contract Deploy is Script {

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        BucketRateLimiter limiter = new BucketRateLimiter();

        vm.stopBroadcast();
    }
}
