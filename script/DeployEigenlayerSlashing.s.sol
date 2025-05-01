// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "../src/EtherFiNode.sol";
import "../src/EtherFiNodesManager.sol";
import "../src/EtherFiRestaker.sol";
import "../src/helpers/AddressProvider.sol";
import "../src/UUPSProxy.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "forge-std/console2.sol";

contract DeployEigenlayerSlashingScript is Script {
    using Strings for string;

    UUPSProxy public liquifierProxy;

    EtherFiNode public etherFiNodeImplementation;
    EtherFiNode public etherFiNodeInstance;
    EtherFiNodesManager public etherFiNodesManagerImplementation;
    EtherFiNodesManager public etherFiNodesManagerInstance;
    EtherFiRestaker public etherFiRestakerImplementation;
    EtherFiRestaker public etherFiRestakerInstance;

    AddressProvider public addressProvider;

    address rewardsCoordinator = 0x7750d328b314EfFa365A0402CcfD489B80B0adda;

    function run() external {

        vm.startBroadcast();

        etherFiNodeImplementation = new EtherFiNode();
        etherFiNodesManagerImplementation = new EtherFiNodesManager();
        etherFiRestakerImplementation = new EtherFiRestaker(rewardsCoordinator);

        console2.log("etherFiNode Impl:", address(etherFiNodeImplementation));
        console2.log("etherFiNodesManager Impl:", address(etherFiNodesManagerImplementation));
        console2.log("etherFiRestaker Impl:", address(etherFiRestakerImplementation));

        vm.stopBroadcast();
    }
}
