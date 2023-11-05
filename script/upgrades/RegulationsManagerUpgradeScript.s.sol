// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/RegulationsManager.sol";
import "../../src/helpers/AddressProvider.sol";

contract RegulationsManagerUpgrade is Script {
    
    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        address RegulationsManagerProxyAddress = addressProvider.getContractAddress("RegulationsManager");

        vm.startBroadcast(deployerPrivateKey);

        RegulationsManager RegulationsManagerInstance = RegulationsManager(RegulationsManagerProxyAddress);
        RegulationsManager RegulationsManagerV2Implementation = new RegulationsManager();

        RegulationsManagerInstance.upgradeTo(address(RegulationsManagerV2Implementation));

        vm.stopBroadcast();
    }
}