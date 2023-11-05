// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/TNFT.sol";
import "../../src/helpers/AddressProvider.sol";

contract TNFTUpgrade is Script {
   
    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        address TNFTProxyAddress = addressProvider.getContractAddress("TNFT");

        vm.startBroadcast(deployerPrivateKey);

        TNFT TNFTInstance = TNFT(TNFTProxyAddress);
        TNFT TNFTV2Implementation = new TNFT();

        TNFTInstance.upgradeTo(address(TNFTV2Implementation));

        // phase 2 upgrade initialization
        address etherFiNodesManagerAddress = addressProvider.getContractAddress("EtherFiNodesManager");
        assert(etherFiNodesManagerAddress != address(0));
        TNFTInstance.initializeOnUpgrade(etherFiNodesManagerAddress);

        vm.stopBroadcast();
    }
}
