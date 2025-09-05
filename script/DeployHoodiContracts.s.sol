// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "../src/EtherFiNodesManager.sol";
import "../src/EtherFiNode.sol";
import "../src/EtherFiRateLimiter.sol";

interface IUpgradable {
    function upgradeTo(address newImplementation) external;
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract DeployHoodiContracts is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Known addresses on Hoodi testnet
        address stakingManagerProxy = 0xDbE50E32Ed95f539F36bA315a75377FBc35aBc12;
        address roleRegistryProxy = 0x7279853cA1804d4F705d885FeA7f1662323B5Aab;
        address liquidityPoolProxy = 0x4a8081095549e63153a61D21F92ff079fe39858E;
        address eigenPodManagerProxy = 0xcd1442415Fc5C29Aa848A49d2e232720BE07976c;
        address delegationManagerProxy = 0x867837a9722C512e0862d8c2E15b8bE220E8b87d;
        address etherFiNodesManagerProxy = 0x7579194b8265e3Aa7df451c6BD2aff5B1FC5F945;
        address etherFiNodeProxy = 0xCb77c1EDf717b551C57c15332700b213c02f1b90;
        address etherFiRateLimiterProxy = address(0x0); 
        
        // Deploy EtherFiRateLimiter first
        console.log("Deploying EtherFiRateLimiter implementation...");
        EtherFiRateLimiter rateLimiterImpl = new EtherFiRateLimiter(roleRegistryProxy);
        console.log("EtherFiRateLimiter implementation deployed at:", address(rateLimiterImpl));
        
        // Deploy new EtherFiNodesManager implementation
        console.log("Deploying new EtherFiNodesManager implementation...");
        EtherFiNodesManager newNodesManagerImpl = new EtherFiNodesManager(stakingManagerProxy, roleRegistryProxy, address(etherFiRateLimiterProxy));
        console.log("EtherFiNodesManager deployed at:", address(newNodesManagerImpl));

        // For EtherFiNode, we need several addresses. Using placeholders for now

        // Deploy new EtherFiNode implementation
        console.log("Deploying new EtherFiNode implementation...");
        EtherFiNode newNode = new EtherFiNode(
            liquidityPoolProxy,
            etherFiNodesManagerProxy,
            eigenPodManagerProxy,
            delegationManagerProxy,
            roleRegistryProxy
        );
        console.log("EtherFiNode deployed at:", address(newNode));


        console.log("Upgrading NodesManager proxy...");
        IUpgradable(etherFiNodesManagerProxy).upgradeTo(address(newNodesManagerImpl));
        console.log("  -> NodesManager proxy upgraded");

        // 4) Upgrade EtherFiNode beacon via unified interface
        console.log("Upgrading EtherFiNode beacon...");
        IUpgradable(etherFiNodeProxy).upgradeTo(address(newNode));
        console.log("  -> EtherFiNode beacon upgraded");

        vm.stopBroadcast();
        
        // Log the addresses for upgrade transactions
        console.log("\n=== Deployment Summary ===");
        console.log("New EtherFiNodesManager implementation:", address(newNodesManagerImpl));
        console.log("New EtherFiNode implementation:", address(newNode));
    }
}