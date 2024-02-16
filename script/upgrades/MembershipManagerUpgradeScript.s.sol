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
        address etherFiAdminAddress = addressProvider.getContractAddress("EtherFiAdmin");
        assert(membershipManagerProxy != address(0));
        assert(etherFiAdminAddress != address(0));


        vm.startBroadcast(deployerPrivateKey);

        MembershipManager membershipManagerInstance = MembershipManager(payable(membershipManagerProxy));
        MembershipManager membershipManagerV2Implementation = new MembershipManager();

        address treasury = membershipManagerInstance.treasury();
        uint16 pointsGrowthRate = membershipManagerInstance.pointsGrowthRate();
        (uint256 mintFeeAmount, uint256 burnFeeAmount, uint256 upgradeFeeAmount) = membershipManagerInstance.getFees();
        uint32 topUpCooltimePeriod = membershipManagerInstance.topUpCooltimePeriod();

        membershipManagerInstance.upgradeTo(address(membershipManagerV2Implementation));

        // 0.3 ether is the treshold for ether.fan rewards distribution
        // 183 days (6 months) is required for burn fee waiver
        membershipManagerInstance.initializeOnUpgrade(etherFiAdminAddress, 0.3 ether, 183);

        (uint256 _mintFeeAmount, uint256 _burnFeeAmount, uint256 _upgradeFeeAmount) = membershipManagerInstance.getFees();

        require(membershipManagerInstance.treasury() == treasury, "Treasury address should not change");
        require(membershipManagerInstance.pointsGrowthRate() == pointsGrowthRate, "Points growth rate should not change");
        require(membershipManagerInstance.topUpCooltimePeriod() == topUpCooltimePeriod, "Top up cooltime period should not change");
        require(membershipManagerInstance.admins(etherFiAdminAddress), "EtherFiAdmin should be an admin");
        require(_mintFeeAmount == mintFeeAmount, "Mint fee amount should not change");
        require(_burnFeeAmount == burnFeeAmount, "Burn fee amount should not change");
        require(_upgradeFeeAmount == upgradeFeeAmount, "Upgrade fee amount should not change");

        vm.stopBroadcast();
    }
}