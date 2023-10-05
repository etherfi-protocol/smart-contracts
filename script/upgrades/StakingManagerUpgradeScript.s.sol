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

        vm.startBroadcast(deployerPrivateKey);

        StakingManager stakingManagerInstance = StakingManager(stakingManagerProxyAddress);
        StakingManager stakingManagerV2Implementation = new StakingManager();

        stakingManagerInstance.upgradeTo(address(stakingManagerV2Implementation));
        
        vm.stopBroadcast();
    }
}