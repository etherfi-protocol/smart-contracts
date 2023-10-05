// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/MembershipNFT.sol";
import "../../src/helpers/AddressProvider.sol";

contract MembershipNFTUpgrade is Script {
    
    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);
        
        address membershipNFTProxy = addressProvider.getContractAddress("MembershipNFT");
        address liquidityPool = addressProvider.getContractAddress("LiquidityPool");

        vm.startBroadcast(deployerPrivateKey);

        MembershipNFT membershipNFTInstance = MembershipNFT(payable(membershipNFTProxy));
        MembershipNFT membershipNFTV2Implementation = new MembershipNFT();

        membershipNFTInstance.upgradeTo(address(membershipNFTV2Implementation));

        membershipNFTInstance.setLiquidityPool(liquidityPool);
        
        vm.stopBroadcast();
    }
}