// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/helpers/AddressProvider.sol";
import "../../src/Timelock.sol";

contract DeployLoyaltyPointsMarketSafeScript is Script {

    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        /*
        // minimum wait time for a timelock tx
        uint256 minWaitTime = 2 days;

        // who can propose transactions for the timelock
        // TODO: Fill out the addresses we want
        address[] memory proposers = new address[](2);
        proposers[0] = ;
        proposers[1] = admin;

        // who can execute transactions for the timelock
        // TODO: Fill out the addresses we want
        address[] memory executors = new address[](1);
        executors[0] = owner;

        vm.startBroadcast(deployerPrivateKey);

        // Last param is left blank as recommended by OZ documentation
        Timelock tl = new Timelock(minWaitTime, proposers, executors, address(0x0));

        addressProvider.addContract(address(tl), "Timelock");
        */

        vm.stopBroadcast();
    }
}
