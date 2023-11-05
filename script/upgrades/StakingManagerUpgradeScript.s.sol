// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/StakingManager.sol";
import "../../src/helpers/AddressProvider.sol";

contract StakingManagerUpgrade is Script {
    
    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        address stakingManagerProxyAddress = addressProvider.getContractAddress("StakingManager");
        address etherFiAdminAddress = addressProvider.getContractAddress("EtherFiAdmin");
        address nodeOperatorManagerAddress = addressProvider.getContractAddress("NodeOperatorManager");

        require(stakingManagerProxyAddress != address(0), "StakingManager address not set");
        require(etherFiAdminAddress != address(0), "EtherFiAdmin address not set");
        require(nodeOperatorManagerAddress != address(0), "NodeOperatorManager address not set");

        vm.startBroadcast(deployerPrivateKey);

        StakingManager stakingManagerInstance = StakingManager(stakingManagerProxyAddress);
        StakingManager stakingManagerV2Implementation = new StakingManager();

        stakingManagerInstance.upgradeTo(address(stakingManagerV2Implementation));
        stakingManagerInstance.initializeOnUpgrade(nodeOperatorManagerAddress, etherFiAdminAddress);
        
        require(stakingManagerInstance.admins(etherFiAdminAddress), "EtherFiAdmin should be an admin");

        vm.stopBroadcast();
    }
}