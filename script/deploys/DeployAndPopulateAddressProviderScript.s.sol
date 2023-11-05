// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/helpers/AddressProvider.sol";

contract DeployAndPopulateAddressProvider is Script {

    /*---- Storage variables ----*/

    struct PhaseOneAddresses {
        address auctionManagerAddress;
        address stakingManagerAddress;
        address etherFiNodesManagerAddress;
        address protocolRevenueManager;
        address tnft;
        address bnft;
        address treasury;
        address nodeOperatorManager;
        address etherFiNode;
        address earlyAdopterPool;
    }

    struct PhaseOnePointFiveAddress {
        address eETH;
        address liquidityPool;
        address membershipManager;
        address membershipNFT;
        address nftExchange;
        address regulationsManager;
        address weETH;
    }

    AddressProvider public addressProvider;
    PhaseOneAddresses public phaseOneAddresses;
    PhaseOnePointFiveAddress public phaseOnePointFiveAddress;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("DEPLOYER");
        vm.startBroadcast(deployerPrivateKey);

        addressProvider = new AddressProvider(owner);
        console.log(address(addressProvider));

        /*---- Populate Registry ----*/

        phaseOneAddresses.auctionManagerAddress = vm.envAddress("AUCTION_MANAGER_PROXY_ADDRESS");
        phaseOneAddresses.stakingManagerAddress = vm.envAddress("STAKING_MANAGER_PROXY_ADDRESS");
        phaseOneAddresses.etherFiNodesManagerAddress = vm.envAddress("ETHERFI_NODES_MANAGER_PROXY_ADDRESS");
        phaseOneAddresses.protocolRevenueManager = vm.envAddress("PROTOCOL_REVENUE_MANAGER_PROXY_ADDRESS");
        phaseOneAddresses.tnft = vm.envAddress("TNFT_PROXY_ADDRESS");
        phaseOneAddresses.bnft = vm.envAddress("BNFT_PROXY_ADDRESS");
        phaseOneAddresses.treasury = vm.envAddress("TREASURY_ADDRESS");
        phaseOneAddresses.nodeOperatorManager = vm.envAddress("NODE_OPERATOR_MANAGER_ADDRESS");
        phaseOneAddresses.etherFiNode = vm.envAddress("ETHERFI_NODE");
        phaseOneAddresses.earlyAdopterPool = vm.envAddress("EARLY_ADOPTER_POOL");
        phaseOnePointFiveAddress.eETH = vm.envAddress("EETH_PROXY_ADDRESS");
        phaseOnePointFiveAddress.liquidityPool = vm.envAddress("LIQUIDITY_POOL_PROXY_ADDRESS");
        phaseOnePointFiveAddress.membershipManager = vm.envAddress("MEMBERSHIP_MANAGER_PROXY_ADDRESS");
        phaseOnePointFiveAddress.membershipNFT = vm.envAddress("MEMBERSHIP_NFT_PROXY_ADDRESS");
        phaseOnePointFiveAddress.nftExchange = vm.envAddress("NFT_EXCHANGE");
        phaseOnePointFiveAddress.regulationsManager = vm.envAddress("REGULATIONS_MANAGER_PROXY_ADDRESS");
        phaseOnePointFiveAddress.weETH = vm.envAddress("WEETH_PROXY_ADDRESS");

        addressProvider.addContract(phaseOneAddresses.auctionManagerAddress, "AuctionManager");
        addressProvider.addContract(phaseOneAddresses.stakingManagerAddress, "StakingManager");
        addressProvider.addContract(phaseOneAddresses.etherFiNodesManagerAddress, "EtherFiNodesManager");
        addressProvider.addContract(phaseOneAddresses.protocolRevenueManager, "ProtocolRevenueManager");
        addressProvider.addContract(phaseOneAddresses.tnft, "TNFT");
        addressProvider.addContract(phaseOneAddresses.bnft, "BNFT");
        addressProvider.addContract(phaseOneAddresses.treasury, "Treasury");
        addressProvider.addContract(phaseOneAddresses.nodeOperatorManager, "NodeOperatorManager");
        addressProvider.addContract(phaseOneAddresses.etherFiNode, "EtherFiNode");
        addressProvider.addContract(phaseOneAddresses.earlyAdopterPool, "EarlyAdopterPool");
        addressProvider.addContract(phaseOnePointFiveAddress.eETH, "EETH");
        addressProvider.addContract(phaseOnePointFiveAddress.liquidityPool, "LiquidityPool");
        addressProvider.addContract(phaseOnePointFiveAddress.membershipManager, "MembershipManager");
        addressProvider.addContract(phaseOnePointFiveAddress.membershipNFT, "MembershipNFT");
        addressProvider.addContract(phaseOnePointFiveAddress.nftExchange, "NFTExchange");
        addressProvider.addContract(phaseOnePointFiveAddress.regulationsManager, "RegulationsManager");
        addressProvider.addContract(phaseOnePointFiveAddress.weETH, "WeETH");

        vm.stopBroadcast();
    }
}