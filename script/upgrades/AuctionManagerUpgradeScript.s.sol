// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/AuctionManager.sol";
import "../../src/helpers/AddressProvider.sol";

contract AuctionManagerUpgrade is Script {

    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        address AuctionManagerProxyAddress = addressProvider.getContractAddress("AuctionManager");
        
        vm.startBroadcast(deployerPrivateKey);

        AuctionManager AuctionManagerInstance = AuctionManager(AuctionManagerProxyAddress);
        AuctionManager AuctionManagerImplementation = new AuctionManager();

        AuctionManagerInstance.upgradeTo(address(AuctionManagerImplementation));

        vm.stopBroadcast();
    }
}