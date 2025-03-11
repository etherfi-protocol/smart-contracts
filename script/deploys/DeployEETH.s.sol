pragma solidity ^0.8.13;

import "forge-std/Script.sol";


import "../../src/UUPSProxy.sol";
import "../../src/EETH.sol";

contract Deploy is Script {

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");    
        
        vm.startBroadcast(deployerPrivateKey);

        new EETH();

        vm.stopBroadcast();
    }
}