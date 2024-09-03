// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/EtherFiNode.sol";
import "../../src/StakingManager.sol";
import "../../src/helpers/AddressProvider.sol";

contract EtherFiNodeUpgrade is Script {

    AddressProvider public addressProvider;
    address liquidityPool;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);
        require(liquidityPool != address(0x0), "must set liquidityPool");

        address stakingManagerProxyAddress = addressProvider.getContractAddress("StakingManager");

        StakingManager stakingManager = StakingManager(stakingManagerProxyAddress);

        vm.startBroadcast(deployerPrivateKey);

        EtherFiNode etherFiNode = new EtherFiNode(liquidityPool);

        stakingManager.upgradeEtherFiNode(address(etherFiNode));

        vm.stopBroadcast();
    }
}
