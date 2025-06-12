// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "../../src/Liquifier.sol";
import "../../src/EtherFiRestaker.sol";
import "../../src/helpers/AddressProvider.sol";
import "../../src/UUPSProxy.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract Deploy is Script {
    using Strings for string;
        
    UUPSProxy public liquifierProxy;

    Liquifier public liquifierInstance;

    AddressProvider public addressProvider;
    address eigenlayerRewardsCoordinator;
    address avsOperatorManager = 0x2093Bbb221f1d8C7c932c32ee28Be6dEe4a37A6a;

    address admin;

    function run() external {
        require(eigenlayerRewardsCoordinator != address(0), "must set rewardsCoordinator");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        vm.startBroadcast(deployerPrivateKey);

        EtherFiRestaker restaker = EtherFiRestaker(payable(new UUPSProxy(payable(new EtherFiRestaker(eigenlayerRewardsCoordinator, avsOperatorManager)), "")));
        restaker.initialize(
            addressProvider.getContractAddress("LiquidityPool"),
            addressProvider.getContractAddress("Liquifier")
        );

        new Liquifier();

        // addressProvider.addContract(address(liquifierInstance), "Liquifier");

        vm.stopBroadcast();
    }
}
