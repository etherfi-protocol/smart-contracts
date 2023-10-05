// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/NFTExchange.sol";
import "../../src/helpers/AddressProvider.sol";

contract NFTExchangeUpgrade is Script {

    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);
        
        address NFTExchangeProxyAddress = addressProvider.getContractAddress("NFTExchange");
       
        vm.startBroadcast(deployerPrivateKey);

        NFTExchange NFTExchangeInstance = NFTExchange(NFTExchangeProxyAddress);
        NFTExchange NFTExchangeV2Implementation = new NFTExchange();

        // NFTExchangeInstance.upgradeTo(address(NFTExchangeV2Implementation));

        vm.stopBroadcast();
    }
}