// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/WithdrawRequestNFT.sol";
import "../../src/helpers/AddressProvider.sol";

contract WithdrawRequestNFTUpgrade is Script {

    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        address proxyAddress = addressProvider.getContractAddress("WithdrawRequestNFT");

        vm.startBroadcast(deployerPrivateKey);

        WithdrawRequestNFT oracleInstance = WithdrawRequestNFT(proxyAddress);
        WithdrawRequestNFT v2Implementation = new WithdrawRequestNFT();

        oracleInstance.upgradeTo(address(v2Implementation));

        vm.stopBroadcast();
    }
}