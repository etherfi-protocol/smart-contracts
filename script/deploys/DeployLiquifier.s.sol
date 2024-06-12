// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "../../src/Liquifier.sol";
import "../../src/helpers/AddressProvider.sol";
import "../../src/UUPSProxy.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract DeployLiquifierScript is Script {
    using Strings for string;
        
    UUPSProxy public liquifierProxy;

    Liquifier public liquifierImplementation;
    Liquifier public liquifierInstance;

    AddressProvider public addressProvider;

    address cbEth_Eth_Pool;
    address wbEth_Eth_Pool;
    address stEth_Eth_Pool;
    address cbEth;
    address wbEth;
    address stEth;
    address cbEthStrategy;
    address wbEthStrategy;
    address stEthStrategy;
    address eigenLayerStrategyManager;
    address lidoWithdrawalQueue;
    uint32 depositCapRefreshInterval;

    address admin;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        vm.startBroadcast(deployerPrivateKey);

        liquifierImplementation = new Liquifier();
        liquifierProxy = new UUPSProxy(payable(liquifierImplementation), "");
        liquifierInstance = Liquifier(payable(liquifierProxy));
        if(block.chainid == 1) {
            cbEth_Eth_Pool = 0x5FAE7E604FC3e24fd43A72867ceBaC94c65b404A;
            wbEth_Eth_Pool = 0xBfAb6FA95E0091ed66058ad493189D2cB29385E6;
            stEth_Eth_Pool = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
            cbEth = 0xBe9895146f7AF43049ca1c1AE358B0541Ea49704;
            wbEth = 0xa2E3356610840701BDf5611a53974510Ae27E2e1;
            stEth = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
            cbEthStrategy = 0x54945180dB7943c0ed0FEE7EdaB2Bd24620256bc;
            wbEthStrategy = 0x7CA911E83dabf90C90dD3De5411a10F1A6112184;
            stEthStrategy = 0x93c4b944D05dfe6df7645A86cd2206016c51564D;
            eigenLayerStrategyManager = 0x858646372CC42E1A627fcE94aa7A7033e7CF075A;
            lidoWithdrawalQueue = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;

            depositCapRefreshInterval = 3600; // 3600 seconds = 1 hour
    
            admin = 0x2aCA71020De61bb532008049e1Bd41E451aE8AdC;
        } else if(block.chainid == 5) {
            // liquifierInstance.initialize();
        }

    
        // function initialize(address _treasury, address _liquidityPool, address _eigenLayerStrategyManager, address _lidoWithdrawalQueue, 
        // address _stEth, address _cbEth, address _wbEth, address _cbEth_Eth_Pool, address _wbEth_Eth_Pool, address _stEth_Eth_Pool,
        // uint32 _depositCapRefreshInterval)
        // liquifierInstance.initialize(
        //     addressProvider.getContractAddress("Treasury"),
        //     addressProvider.getContractAddress("LiquidityPool"),
        //     eigenLayerStrategyManager,
        //     lidoWithdrawalQueue,
        //     stEth,
        //     cbEth,
        //     wbEth,
        //     cbEth_Eth_Pool,
        //     wbEth_Eth_Pool,
        //     stEth_Eth_Pool,
        //     depositCapRefreshInterval // deposit cap refresh interval in seconds
        // );

        liquifierInstance.updateAdmin(admin, true);

        address oracleWallet = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F; 
        liquifierInstance.updateAdmin(oracleWallet, true);
        
        liquifierInstance.registerToken(stEth, stEthStrategy, true, 0, false); // 1 ether timebound cap, 10 ether max cap
        liquifierInstance.registerToken(cbEth, cbEthStrategy, true, 0, false);
        liquifierInstance.registerToken(wbEth, wbEthStrategy, true, 0, false);

        addressProvider.addContract(address(liquifierInstance), "Liquifier");

        vm.stopBroadcast();
    }
}
