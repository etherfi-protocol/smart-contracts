// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/MembershipManager.sol";
import "../../src/MembershipNFT.sol";
import "../../src/WeETH.sol";
import "../../src/EETH.sol";
import "../../src/helpers/AddressProvider.sol";
import "../../src/NFTExchange.sol";
import "../../src/LiquidityPool.sol";
import "../../src/RegulationsManager.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/ProtocolRevenueManager.sol";
import "../../src/TNFT.sol";
import "../../src/BNFT.sol";
import "../../src/AuctionManager.sol";
import "../../src/StakingManager.sol";

contract TransferOwnership is Script {   

    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        vm.startBroadcast(deployerPrivateKey);

        address auctionManager = addressProvider.getContractAddress("AuctionManager");
        address stakingManager = addressProvider.getContractAddress("StakingManager");
        address protocolRevenueManager = addressProvider.getContractAddress("ProtocolRevenueManager");
        address tnft = addressProvider.getContractAddress("TNFT");
        address bnft = addressProvider.getContractAddress("BNFT");
        address etherfiNodesManager = addressProvider.getContractAddress("EtherFiNodesManager");
        address membershipManager = addressProvider.getContractAddress("MembershipManager");
        address membershipNFT = addressProvider.getContractAddress("MembershipNFT");
        address weETH = addressProvider.getContractAddress("WeETH");
        address eETH = addressProvider.getContractAddress("EETH");
        address nftExchange = addressProvider.getContractAddress("NFTExchange");
        address liquidityPool = addressProvider.getContractAddress("LiquidityPool");
        address regulationsManager = addressProvider.getContractAddress("RegulationsManager");

        address owner = vm.envAddress("GNOSIS");

        MembershipManager(payable(membershipManager)).transferOwnership(owner); 
        MembershipNFT(membershipNFT).transferOwnership(owner); 
        WeETH(weETH).transferOwnership(owner); 
        EETH(eETH).transferOwnership(owner); 
        NFTExchange(nftExchange).transferOwnership(owner); 
        LiquidityPool(payable(liquidityPool)).transferOwnership(owner); 
        RegulationsManager(regulationsManager).transferOwnership(owner); 
        AuctionManager(auctionManager).transferOwnership(owner); 
        StakingManager(stakingManager).transferOwnership(owner); 
        ProtocolRevenueManager(payable(protocolRevenueManager)).transferOwnership(owner); 
        TNFT(tnft).transferOwnership(owner); 
        BNFT(bnft).transferOwnership(owner); 
        EtherFiNodesManager(payable(etherfiNodesManager)).transferOwnership(owner); 
        addressProvider.setOwner(owner);

        vm.stopBroadcast();
    }
}
