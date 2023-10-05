// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/MembershipManager.sol";
import "../../src/helpers/AddressProvider.sol";

contract MembershipManagerUpgrade is Script {
    
    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);
        
        address membershipManagerProxy = addressProvider.getContractAddress("MembershipManager");

        vm.startBroadcast(deployerPrivateKey);

        MembershipManager membershipManagerInstance = MembershipManager(payable(membershipManagerProxy));
        MembershipManager membershipManagerV2Implementation = new MembershipManager();

        membershipManagerInstance.upgradeTo(address(membershipManagerV2Implementation));

        membershipManagerInstance.initializePhase2();
        
        vm.stopBroadcast();
    }
}