// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/EtherFiOracleExecutor.sol";
import "../../src/helpers/AddressProvider.sol";

contract EtherFiAdminUpgrade is Script {

    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        address proxyAddress = addressProvider.getContractAddress("EtherFiOracleExecutor");

        vm.startBroadcast(deployerPrivateKey);

        EtherFiOracleExecutor instance = EtherFiOracleExecutor(proxyAddress);
        EtherFiOracleExecutor v2Implementation = new EtherFiOracleExecutor();

        //instance.upgradeTo(address(v2Implementation));

        vm.stopBroadcast();
    }
}