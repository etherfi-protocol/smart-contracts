// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/helpers/AddressProvider.sol";

contract TimelockScheduleCalldata is Script {

    ////////////////Change this////////////
    address newLiquidityPoolImplementation = address(0x02656fe285FAC5d5c756C2F03C17277Df9BAc65B);
    address newEtherFiOracleImplementation = address(0x9B9608844275e186C92AAfF115e5025fca9f22F4);
    address newEtherFiAdminImplementation = address(0x0C4a8Aa58885402dB92c2a0D3d748265ce3d63c4);
    ///////////////////////////////////////

    AddressProvider addressProvider;

    function run() external {
        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        string [3] memory names = ["LiquidityPool", "EtherFiOracle", "EtherFiAdmin"];

        for (uint i = 0; i < names.length; i++) {
            address contractAddress = addressProvider.getContractAddress(names[i]);
            console.log("Upgrade Timelock Params: ", names[i]);
            console.log("Contract Address: ", contractAddress);
            console.log("Value: ", 0);
            console.log("Data:");
            console.logBytes(abi.encodeWithSignature("upgradeTo(address)", newLiquidityPoolImplementation));
            console.log("Predecessor:");
            console.logBytes32(bytes32(0));
            console.log("Salt:");
            console.logBytes32(0x0);
            console.log("Delay: ", 259200);
            console.log("");
        }
    }
}