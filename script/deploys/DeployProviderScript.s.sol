// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/helpers/AddressProvider.sol";

contract DeployAndPopulateAddressProvider is Script {

    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("DEPLOYER");
        vm.startBroadcast(deployerPrivateKey);

        addressProvider = new AddressProvider(owner);
        console.log(address(addressProvider));

        /*---- Populate Registry ----*/

        vm.stopBroadcast();
    }
}
