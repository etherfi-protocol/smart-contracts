// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/EETH.sol";
import "../../src/helpers/AddressProvider.sol";

contract EETHUpgrade is Script {
    
    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        address EETHProxyAddress = addressProvider.getContractAddress("EETH");
        
        vm.startBroadcast(deployerPrivateKey);

        EETH EETHInstance = EETH(EETHProxyAddress);
        EETH EETHV2Implementation = new EETH();

        uint256 totalShares = EETHInstance.totalShares();

        EETHInstance.upgradeTo(address(EETHV2Implementation));

        require(totalShares == EETHInstance.totalShares(), "EETHUpgrade: totalShares mismatch");

        vm.stopBroadcast();
    }
}