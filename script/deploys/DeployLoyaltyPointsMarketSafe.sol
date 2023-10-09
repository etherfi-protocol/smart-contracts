// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/UUPSProxy.sol";
import "../../src/LoyaltyPointsMarketSafe.sol";
import "../../src/helpers/AddressProvider.sol";

contract DeployLoyaltyPointsMarketSafeScript is Script {

    LoyaltyPointsMarketSafe public lpaMarketSafe;
    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");

        addressProvider = AddressProvider(addressProviderAddress);
        
        vm.startBroadcast(deployerPrivateKey);

        lpaMarketSafe = new LoyaltyPointsMarketSafe(1500000000000);

        addressProvider.addContract(address(lpaMarketSafe), "LoyaltyPointsMarketSafeV2");

        vm.stopBroadcast();
    }
}
