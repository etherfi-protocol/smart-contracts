// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "../../src/BucketRateLimiter.sol";
import "../../src/UUPSProxy.sol";

interface IL2SyncPool {
    function setRateLimiter(address rateLimiter) external;
}

contract Upgrade is Script {

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address limiter;

        if (block.chainid == 59144) limiter = 0x3A19866D5E0fAE0Ce19Adda617f9d2B9fD5a3975; // LINEA
        else if (block.chainid == 81457) limiter = 0x6f257089bF046a02751b60767871953F3899652e; // BLAST
        else if (block.chainid == 34443) limiter = 0x95F1138837F1158726003251B32ecd8732c76781; // MODE
        else revert("Unsupported chain id");

        vm.startBroadcast(deployerPrivateKey);

        BucketRateLimiter impl = new BucketRateLimiter();
        
        BucketRateLimiter(limiter).upgradeTo(address(impl));

        vm.stopBroadcast();
    }

}