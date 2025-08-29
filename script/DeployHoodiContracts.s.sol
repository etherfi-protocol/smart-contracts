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
        address stakingManagerProxy = 0xEcf3C0Dc644DBC7d0fbf7f69651D90f2177D0dFf;
        
        address roleRegistryProxy = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;
        address liquidityPoolProxy = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
        address eigenPodManagerProxy = 0x91E677b07F7AF907ec9a428aafA9fc14a0d3A338;
        address delegationManagerProxy = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A;
        address etherFiNodesManagerProxy = 0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F;
        address etherFiNodeProxy = 0xfD4Ff2942e183161a5920749CD5A8B0cFD4164AC;
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