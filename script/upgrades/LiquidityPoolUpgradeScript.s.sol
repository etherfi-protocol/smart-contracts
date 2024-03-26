// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/LiquidityPool.sol";
import "../../src/helpers/AddressProvider.sol";

contract LiquidityPoolUpgrade is Script {
  
    AddressProvider public addressProvider;

    address public stakingManager;
    uint256 public getTotalPooledEther;
    uint32 public numPendingDeposits;
    uint128 public totalValueOutOfLp;
    uint128 public totalValueInLp;


    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);
        
        address LiquidityPoolProxyAddress = addressProvider.getContractAddress("LiquidityPool");
        address etherFiAdminAddress = addressProvider.getContractAddress("EtherFiAdmin");
        address withdrawRequestNFTAddress = addressProvider.getContractAddress("WithdrawRequestNFT");
        address auctionManager = addressProvider.getContractAddress("AuctionManager");
        address liquifier = addressProvider.getContractAddress("Liquifier");
        
        vm.startBroadcast(deployerPrivateKey);

        LiquidityPool LiquidityPoolInstance = LiquidityPool(payable(LiquidityPoolProxyAddress));

        // Copy the states
        stakingManager = address(LiquidityPoolInstance.stakingManager());
        getTotalPooledEther = LiquidityPoolInstance.getTotalPooledEther();
        numPendingDeposits = LiquidityPoolInstance.numPendingDeposits();
        totalValueOutOfLp = LiquidityPoolInstance.totalValueOutOfLp();
        totalValueInLp = LiquidityPoolInstance.totalValueInLp();

        LiquidityPool LiquidityPoolV2Implementation = new LiquidityPool();

        require(LiquidityPoolInstance.numPendingDeposits() == 0, "numPendingDeposits should be 0");

        LiquidityPoolInstance.upgradeTo(address(LiquidityPoolV2Implementation));

        // // Phase 2
        // //Ensure these inputs are correct
        // //First parameter = the scheduling period in seconds we want to set
        // //Second parameter = the number of validators ETH source of funds currently has spun up
        // //Third parameter = the number of validators ETHER_FAN source of funds currently has spun up
        // if (block.chainid == 1) {
        //     LiquidityPoolInstance.initializeOnUpgrade(auctionManager, liquifier);
        // } else if (block.chainid == 5) {
        //     LiquidityPoolInstance.initializeOnUpgrade(auctionManager, liquifier);
        // } else {
        //     require(false, "chain is wrong");
        // }

        // // Validate the states
        // require(stakingManager == address(LiquidityPoolInstance.stakingManager()), "stakingManager");
        // require(getTotalPooledEther == LiquidityPoolInstance.getTotalPooledEther(), "getTotalPooledEther");
        // require(numPendingDeposits == LiquidityPoolInstance.numPendingDeposits(), "numPendingDeposits");
        // require(totalValueOutOfLp == LiquidityPoolInstance.totalValueOutOfLp(), "totalValueOutOfLp");
        // require(totalValueInLp == LiquidityPoolInstance.totalValueInLp(), "totalValueInLp");
        // require(LiquidityPoolInstance.admins(etherFiAdminAddress), "EtherFiAdmin should be an admin");

        vm.stopBroadcast();
    }
}