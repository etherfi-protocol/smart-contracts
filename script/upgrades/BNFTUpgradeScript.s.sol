// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/BNFT.sol";
import "../../src/helpers/AddressProvider.sol";

contract BNFTUpgrade is Script {
  
    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);
        
        address BNFTProxyAddress = addressProvider.getContractAddress("BNFT");

        vm.startBroadcast(deployerPrivateKey);

        BNFT BNFTInstance = BNFT(BNFTProxyAddress);
        BNFT BNFTV2Implementation = new BNFT();

        BNFTInstance.upgradeTo(address(BNFTV2Implementation));

        // phase 2 upgrade initialization
        address etherFiNodesManagerAddress = addressProvider.getContractAddress("EtherFiNodesManager");
        assert(etherFiNodesManagerAddress != address(0));
        BNFTInstance.initializeOnUpgrade(etherFiNodesManagerAddress);

        vm.stopBroadcast();
    }
}
