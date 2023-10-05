// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/NodeOperatorManager.sol";
import "../../src/AuctionManager.sol";
import "../../src/helpers/AddressProvider.sol";
import "../../src/UUPSProxy.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract DeployNewNodeOperatorManagerScript is Script {
    using Strings for string;
        
    UUPSProxy public nodeOperatorManagerProxy;

    NodeOperatorManager public nodeOperatorManagerImplementation;
    NodeOperatorManager public nodeOperatorManagerInstance;

    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        address AuctionManagerProxyAddress = addressProvider.getContractAddress("AuctionManager");

        vm.startBroadcast(deployerPrivateKey);

        nodeOperatorManagerImplementation = new NodeOperatorManager();
        nodeOperatorManagerProxy = new UUPSProxy(address(nodeOperatorManagerImplementation), "");
        nodeOperatorManagerInstance = NodeOperatorManager(address(nodeOperatorManagerProxy));
        nodeOperatorManagerInstance.initialize();

        AuctionManager(AuctionManagerProxyAddress).updateNodeOperatorManager(address(nodeOperatorManagerInstance));
        
        if (addressProvider.getContractAddress("NodeOperatorManager") != address(nodeOperatorManagerInstance)) {
            addressProvider.removeContract("NodeOperatorManager");
        }
        addressProvider.addContract(address(nodeOperatorManagerInstance), "NodeOperatorManager");

        vm.stopBroadcast();
    }
}
