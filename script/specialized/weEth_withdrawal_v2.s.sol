// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "test/TestSetup.sol";

import "src/helpers/AddressProvider.sol";

contract Upgrade is Script {

    address public addressProviderAddress = 0x8487c5F8550E3C3e7734Fe7DCF77DB2B72E4A848;
    AddressProvider public addressProvider = AddressProvider(addressProviderAddress);
    address public roleRegistry = 0x1d3Af47C1607A2EF33033693A9989D1d1013BB50;
    address public treasury = 0x0c83EAe1FE72c390A02E426572854931EefF93BA;
    address public pauser = 0x9AF1298993DC1f397973C62A5D47a284CF76844D;

    WithdrawRequestNFT withdrawRequestNFTInstance;
    LiquidityPool liquidityPoolInstance;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        withdrawRequestNFTInstance = WithdrawRequestNFT(payable(addressProvider.getContractAddress("WithdrawRequestNFT")));
        liquidityPoolInstance = LiquidityPool(payable(addressProvider.getContractAddress("LiquidityPool")));

        vm.startBroadcast(deployerPrivateKey);

        deploy_upgrade();
        agg();
        handle_remainder();

        vm.stopBroadcast();
    }

    function deploy_upgrade() internal {
        UUPSProxy etherFiRedemptionManagerProxy = new UUPSProxy(address(new EtherFiRedemptionManager(
            addressProvider.getContractAddress("LiquidityPool"), 
            addressProvider.getContractAddress("EETH"), 
            addressProvider.getContractAddress("WeETH"), 
            treasury, 
            roleRegistry)), 
            abi.encodeWithSelector(
                EtherFiRedemptionManager.initialize.selector,
                10_00, 1_00, 1_00, 5 ether, 0.001 ether // 10% fee split to treasury, 1% exit fee, 1% low watermark
            )
        );
        EtherFiRedemptionManager etherFiRedemptionManagerInstance = EtherFiRedemptionManager(payable(etherFiRedemptionManagerProxy));
        // etherFiRedemptionManagerInstance.initialize(10_00, 1_00, 1_00, 5 ether, 0.001 ether); // 10% fee split to treasury, 1% exit fee, 1% low watermark

        withdrawRequestNFTInstance.upgradeToAndCall(
            address(new WithdrawRequestNFT(treasury)), 
            abi.encodeWithSelector(WithdrawRequestNFT.initializeOnUpgrade.selector, pauser, 50_00) // 50% fee split to treasury
        );
        // withdrawRequestNFTInstance.initializeOnUpgrade(pauser, 50_00); // 50% fee split to treasury

        liquidityPoolInstance.upgradeToAndCall(address(new LiquidityPool()), abi.encodeWithSelector(LiquidityPool.initializeOnUpgradeWithRedemptionManager.selector, address(etherFiRedemptionManagerInstance)));
        // liquidityPoolInstance.initializeOnUpgradeWithRedemptionManager(address(etherFiRedemptionManagerInstance));

        // verification
        assert(withdrawRequestNFTInstance.pauser() == pauser);
        assert(address(liquidityPoolInstance.etherFiRedemptionManager()) == address(etherFiRedemptionManagerInstance));
    }

    function agg() internal {
        uint256 numToScanPerTx = 1024;
        uint256 cnt = (withdrawRequestNFTInstance.nextRequestId() / numToScanPerTx) + 1;
        console.log(cnt);
        for (uint256 i = 0; i < cnt; i++) {
            withdrawRequestNFTInstance.aggregateSumEEthShareAmount(numToScanPerTx);
        }
    }

    function handle_remainder() internal {
        withdrawRequestNFTInstance.updateAdmin(msg.sender, true);
        withdrawRequestNFTInstance.unPauseContract();
        uint256 remainder = withdrawRequestNFTInstance.getEEthRemainderAmount();
        console.log(remainder);
        withdrawRequestNFTInstance.handleRemainder(remainder);
    }
}

contract TestUpgrade is Test, Upgrade {
    address etherFiTimelock = 0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761;
    function setUp() public {
        vm.selectFork(vm.createFork(vm.envString("MAINNET_RPC_URL")));

        withdrawRequestNFTInstance = WithdrawRequestNFT(payable(addressProvider.getContractAddress("WithdrawRequestNFT")));
        liquidityPoolInstance = LiquidityPool(payable(addressProvider.getContractAddress("LiquidityPool")));        
    }
    
    function test_UpgradeWeETHInstantWithdrawal() public {
        startHoax(etherFiTimelock);
        deploy_upgrade();
        agg();
        handle_remainder();
    }
}
