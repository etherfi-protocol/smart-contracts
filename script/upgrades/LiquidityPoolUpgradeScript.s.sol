// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/LiquidityPool.sol";
import "../../src/helpers/AddressProvider.sol";

contract LiquidityPoolUpgrade is Script {
  
    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);
        
        address LiquidityPoolProxyAddress = addressProvider.getContractAddress("LiquidityPool");
        address etherFiAdminAddress = addressProvider.getContractAddress("EtherFiAdmin");

        vm.startBroadcast(deployerPrivateKey);

        LiquidityPool LiquidityPoolInstance = LiquidityPool(payable(LiquidityPoolProxyAddress));
        LiquidityPool LiquidityPoolV2Implementation = new LiquidityPool();

        LiquidityPoolInstance.upgradeTo(address(LiquidityPoolV2Implementation));

        //Ensure these inputs are correct
        //First parameter = the scheduling period in seconds we want to set
        //Second parameter = the number of validators ETH source of funds currently has spun up
        //Third parameter = the number of validators ETHER_FAN source of funds currently has spun up
        LiquidityPoolInstance.initializeOnUpgrade(900, 3, 9);
        LiquidityPoolInstance.setNumValidatorsToSpinUpPerSchedulePerBnftHolder(4);
        LiquidityPoolInstance.setEtherFiAdminContract(etherFiAdminAddress);

        // Phase 2
        address withdrawRequestNFTInstance = addressProvider.getContractAddress("WithdrawRequestNFT");
        LiquidityPoolInstance.setWithdrawRequestNFT(address(withdrawRequestNFTInstance));

        vm.stopBroadcast();
    }
}