// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/helpers/AddressProvider.sol";

contract EtherFiNodesManagerUpgrade is Script {

    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        address EtherFiNodesManagerProxyAddress = addressProvider.getContractAddress("EtherFiNodesManager");

        vm.startBroadcast(deployerPrivateKey);

        EtherFiNodesManager EtherFiNodesManagerInstance = EtherFiNodesManager(payable(EtherFiNodesManagerProxyAddress));
        EtherFiNodesManager EtherFiNodesManagerV2Implementation = new EtherFiNodesManager();

        EtherFiNodesManagerInstance.upgradeTo(address(EtherFiNodesManagerV2Implementation));
        
        vm.stopBroadcast();
    }
}