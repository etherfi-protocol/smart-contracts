// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/ProtocolRevenueManager.sol";
import "../../src/helpers/AddressProvider.sol";

contract ProtocolRevenueManagerUpgrade is Script {
    
    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        address ProtocolRevenueManagerProxyAddress = addressProvider.getContractAddress("ProtocolRevenueManager");

        vm.startBroadcast(deployerPrivateKey);

        ProtocolRevenueManager ProtocolRevenueManagerInstance = ProtocolRevenueManager(payable(ProtocolRevenueManagerProxyAddress));
        ProtocolRevenueManager ProtocolRevenueManagerV2Implementation = new ProtocolRevenueManager();

        ProtocolRevenueManagerInstance.upgradeTo(address(ProtocolRevenueManagerV2Implementation));
        
        vm.stopBroadcast();
    }
}