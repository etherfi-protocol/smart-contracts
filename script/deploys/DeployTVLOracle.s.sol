// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/UUPSProxy.sol";
import "../../src/TVLOracle.sol";
import "../../src/helpers/AddressProvider.sol";

contract DeployTVLOracleScript is Script {

    /*---- Storage variables ----*/

    TVLOracle public tvlOracle;
    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        address tvlAggregatorAddress = vm.envAddress("TVL_AGGREGATOR_ADDRESS");

        addressProvider = AddressProvider(addressProviderAddress);
        
        vm.startBroadcast(deployerPrivateKey);

        // Deploy contract
        tvlOracle = new TVLOracle(tvlAggregatorAddress);
        addressProvider.addContract(address(tvlOracle), "TVLOracle");

        vm.stopBroadcast();
    }
}
