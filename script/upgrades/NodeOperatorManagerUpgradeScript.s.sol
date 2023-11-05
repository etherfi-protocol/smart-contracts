// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/NodeOperatorManager.sol";
import "../../src/helpers/AddressProvider.sol";

contract NodeOperatorManagerUpgrade is Script {

    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);
        
        address NodeOperatorManagerProxyAddress = addressProvider.getContractAddress("NodeOperatorManager");
       
        vm.startBroadcast(deployerPrivateKey);

        NodeOperatorManager NodeOperatorManagerInstance = NodeOperatorManager(NodeOperatorManagerProxyAddress);
        NodeOperatorManager NodeOperatorManagerV2Implementation = new NodeOperatorManager();

        NodeOperatorManagerInstance.upgradeTo(address(NodeOperatorManagerV2Implementation));

        vm.stopBroadcast();
    }
}