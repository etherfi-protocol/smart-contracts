// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/ProtocolRevenueManager.sol";
import "../../src/AuctionManager.sol";
import "../../src/TNFT.sol";
import "../../src/LiquidityPool.sol";
import "../../src/MembershipManager.sol";
import "../../src/MembershipNFT.sol";
import "../../src/StakingManager.sol";
import "../../src/NFTExchange.sol";
import "../../src/RegulationsManager.sol";
import "../../src/helpers/AddressProvider.sol";
import "../../src/WithdrawRequestNFT.sol";

contract UpdateAdmins is Script {   

    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        vm.startBroadcast(deployerPrivateKey);

        address stakingManager = addressProvider.getContractAddress("StakingManager");
        address etherFiNodesManager = addressProvider.getContractAddress("EtherFiNodesManager");
        address protocolRevenueManager = addressProvider.getContractAddress("ProtocolRevenueManager");
        address auctionManager = addressProvider.getContractAddress("AuctionManager");
        address liquidityPool = addressProvider.getContractAddress("LiquidityPool");
        address regulationsManager = addressProvider.getContractAddress("RegulationsManager");
        address membershipNFT = addressProvider.getContractAddress("MembershipNFT");
        address membershipManager = addressProvider.getContractAddress("MembershipManager");
        address nftExchange = addressProvider.getContractAddress("NFTExchange");
        address withdrawRequestNFTAddress = addressProvider.getContractAddress("WithdrawRequestNFT");

        address admin = vm.envAddress("ADMIN");
        
        EtherFiNodesManager(payable(etherFiNodesManager)).updateAdmin(admin, true); 
        // ProtocolRevenueManager(payable(protocolRevenueManager)).updateAdmin(admin);  // DEPRECATED
        AuctionManager(auctionManager).updateAdmin(admin, true); 
        StakingManager(stakingManager).updateAdmin(admin, true); 
        LiquidityPool(payable(liquidityPool)).updateAdmin(admin, true);
        // RegulationsManager(regulationsManager).updateAdmin(admin, true);
        MembershipManager(payable(membershipManager)).updateAdmin(admin, true);
        MembershipNFT(membershipNFT).updateAdmin(admin, true);
        // NFTExchange(nftExchange).updateAdmin(admin); // Not in the scope of Phase 2 upgrade
        WithdrawRequestNFT(payable(withdrawRequestNFTAddress)).updateAdmin(admin, true);

        vm.stopBroadcast();
    }
}