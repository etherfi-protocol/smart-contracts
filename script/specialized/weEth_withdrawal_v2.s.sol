// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "test/TestSetup.sol";

import "src/helpers/AddressProvider.sol";
import "../GnosisHelpers.sol";

contract Upgrade is Script, GnosisHelpers {

    address public etherFiTimelock = 0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761;
    address public addressProviderAddress = 0x8487c5F8550E3C3e7734Fe7DCF77DB2B72E4A848;
    AddressProvider public addressProvider = AddressProvider(addressProviderAddress);
    address public roleRegistry = 0x1d3Af47C1607A2EF33033693A9989D1d1013BB50;
    address public treasury = 0x0c83EAe1FE72c390A02E426572854931EefF93BA;
    address public pauser = 0x9AF1298993DC1f397973C62A5D47a284CF76844D;

    WithdrawRequestNFT withdrawRequestNFTInstance;
    LiquidityPool liquidityPoolInstance;
    EtherFiRedemptionManager etherFiRedemptionManagerInstance;

    function run() external {
        // uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        withdrawRequestNFTInstance = WithdrawRequestNFT(payable(addressProvider.getContractAddress("WithdrawRequestNFT")));
        liquidityPoolInstance = LiquidityPool(payable(addressProvider.getContractAddress("LiquidityPool")));

        vm.startBroadcast();

        deploy_upgrade();
        // agg();
        // handle_remainder();

        vm.stopBroadcast();
    }

    function deploy_upgrade() internal {
        UUPSProxy etherFiRedemptionManagerProxy = new UUPSProxy(address(new EtherFiRedemptionManager(
            addressProvider.getContractAddress("LiquidityPool"), 
            addressProvider.getContractAddress("EETH"), 
            addressProvider.getContractAddress("WeETH"), 
            treasury, 
            roleRegistry)), 
            ""
        );
        etherFiRedemptionManagerInstance = EtherFiRedemptionManager(payable(etherFiRedemptionManagerProxy));
        etherFiRedemptionManagerInstance.initialize(10_00, 1_00, 2_30, 500 ether, 0.005787037037 ether);
        // abi.encodeWithSelector(
        //         EtherFiRedemptionManager.initialize.selector,
        //         10_00, 1_00, 2_30, 500 ether, 0.005787037037 ether // 10% fee split to treasury, 1% exit fee, 1% low watermark
        //     )

        address withdrawRequestNFTImpl = address(new WithdrawRequestNFT(treasury));
        address liquidityPoolImpl = address(new LiquidityPool());
        
        predecessor = 0x0000000000000000000000000000000000000000000000000000000000000000;
        salt = keccak256(abi.encodePacked(address(withdrawRequestNFTInstance), address(liquidityPoolInstance), block.number));         
        delay = 3 days;
        
        address[] memory targets = new address[](2);
        targets[0] = address(withdrawRequestNFTInstance);
        targets[1] = address(liquidityPoolInstance);

        uint256[] memory values = new uint256[](2);
        
        bytes[] memory payloads = new bytes[](2);
        bytes memory upgradeWithdrawRequestNFTUpgradeData = abi.encodeWithSignature(
            "upgradeToAndCall(address,bytes)",
            withdrawRequestNFTImpl, 
            abi.encodeWithSelector(WithdrawRequestNFT.initializeOnUpgrade.selector, pauser, 50_00) // 50% fee split to treasury
        );
        bytes memory upgradeLiquidityPoolUpgradeData = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", liquidityPoolImpl, abi.encodeWithSelector(LiquidityPool.initializeOnUpgradeWithRedemptionManager.selector, address(etherFiRedemptionManagerInstance)));
        payloads[0] = upgradeWithdrawRequestNFTUpgradeData;
        payloads[1] = upgradeLiquidityPoolUpgradeData;

        string memory scheduleGnosisTx = _getGnosisHeader("1");
        string memory scheduleUpgrade = iToHex(abi.encodeWithSignature("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)", targets, values, payloads, predecessor, salt, delay));
        scheduleGnosisTx = string(abi.encodePacked(scheduleGnosisTx, _getGnosisTransaction(addressToHex(timelock), scheduleUpgrade, true)));

        string memory path = "./operations/20250128_upgrade_instant_withdrawal_schedule.json";
        vm.writeFile(path, scheduleGnosisTx);

        string memory executeGnosisTx = _getGnosisHeader("1");
        string memory executeUpgrade = iToHex(abi.encodeWithSignature("executeBatch(address[],uint256[],bytes[],bytes32,bytes32)", targets, values, payloads, predecessor, salt));
        executeGnosisTx = string(abi.encodePacked(executeGnosisTx, _getGnosisTransaction(addressToHex(timelock), executeUpgrade, true)));

        path = "./operations/20250128_upgrade_instant_withdrawal_execute.json";
        vm.writeFile(path, executeGnosisTx);
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
    function setUp() public {
        vm.selectFork(vm.createFork(vm.envString("MAINNET_RPC_URL")));

        withdrawRequestNFTInstance = WithdrawRequestNFT(payable(addressProvider.getContractAddress("WithdrawRequestNFT")));
        liquidityPoolInstance = LiquidityPool(payable(addressProvider.getContractAddress("LiquidityPool")));        
    }
    
    function test_UpgradeWeETHInstantWithdrawal() public {
        // startHoax(etherFiTimelock);
        deploy_upgrade();
        // agg();
        // handle_remainder();

        string memory path = "./operations/20250127_upgrade_instant_withdrawal_schedule.json";
        executeGnosisTransactionBundle(path, 0xcdd57D11476c22d265722F68390b036f3DA48c21);

        path = "./operations/20250127_upgrade_instant_withdrawal_execute.json";
        vm.warp(block.timestamp + 3 days + 1);
        executeGnosisTransactionBundle(path, 0xcdd57D11476c22d265722F68390b036f3DA48c21);

        assert(withdrawRequestNFTInstance.pauser() == pauser);
        assert(address(liquidityPoolInstance.etherFiRedemptionManager()) == address(etherFiRedemptionManagerInstance));
    }
}
