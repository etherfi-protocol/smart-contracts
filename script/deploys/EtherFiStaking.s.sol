// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "../../src/EtherFiStaking.sol";
import "../../src/UUPSProxy.sol";


contract Deploy is Script {

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address ethfiToken = 0xFe0c30065B384F05761f15d0CC899D4F9F9Cc0eB;

        vm.startBroadcast(deployerPrivateKey);

        EtherFiStaking impl = new EtherFiStaking();
        UUPSProxy proxy = new UUPSProxy(
            address(impl), 
            abi.encodeWithSelector(EtherFiStaking.initialize.selector, address(ethfiToken))
        );

        EtherFiStaking etherfiStaking = EtherFiStaking(address(proxy));

        vm.stopBroadcast();
    }

}