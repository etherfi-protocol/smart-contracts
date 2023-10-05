// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../../test/DepositContract.sol";
import "../../../src/helpers/AddressProvider.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract DeployTestDepositContractScript is Script {

    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy contract
        DepositContract depositContract = new DepositContract();
        addressProvider.addContract(address(depositContract), "DepositContract");

        vm.stopBroadcast();
    }
}
