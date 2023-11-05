// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/EtherFiOracle.sol";
import "../../src/helpers/AddressProvider.sol";

contract EtherFiOracleUpgrade is Script {

    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        address proxyAddress = addressProvider.getContractAddress("EtherFiOracle");

        vm.startBroadcast(deployerPrivateKey);

        EtherFiOracle oracleInstance = EtherFiOracle(proxyAddress);
        EtherFiOracle v2Implementation = new EtherFiOracle();

        oracleInstance.upgradeTo(address(v2Implementation));

        vm.stopBroadcast();
    }
}