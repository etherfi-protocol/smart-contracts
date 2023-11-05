// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/WeETH.sol";
import "../../src/helpers/AddressProvider.sol";

contract WeEthUpgrade is Script {

    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        address weEthProxyAddress = addressProvider.getContractAddress("WeETH");

        vm.startBroadcast(deployerPrivateKey);

        WeETH weEthInstance = WeETH(weEthProxyAddress);
        WeETH weEthV2Implementation = new WeETH();

        uint256 totalSupply = weEthInstance.totalSupply();

        weEthInstance.upgradeTo(address(weEthV2Implementation));

        require(totalSupply == weEthInstance.totalSupply(), "WeEthUpgrade: totalSupply mismatch");

        vm.stopBroadcast();
    }
}