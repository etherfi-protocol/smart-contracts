// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {Utils} from "../utils/utils.sol";
import {EtherFiTimelock} from "../../src/EtherFiTimelock.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {EtherFiRedemptionManagerTemp} from "../../src/EtherFiRedemptionManagerTemp.sol";
import {EtherFiRestaker} from "../../src/EtherFiRestaker.sol";
import {EtherFiRedemptionManager} from "../../src/EtherFiRedemptionManager.sol";
import {LiquidityPool} from "../../src/LiquidityPool.sol";

contract StETHWithdrawalsTransactions is Script, Utils {
    EtherFiTimelock etherFiTimelock = EtherFiTimelock(payable(0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761));
    EtherFiTimelock etherfiOperatingTimelock = EtherFiTimelock(payable(0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a));
    EtherFiRestaker etherFiRestakerInstance = EtherFiRestaker(payable(0x1B7a4C3797236A1C37f8741c0Be35c2c72736fFf));
    //--------------------------------------------------------------------------------------
    //--------------------- Previous Implementations ---------------------------------------
    //--------------------------------------------------------------------------------------
    address constant oldLiquidityPoolImpl = 0x025911766aEF6fF0C294FD831a2b5c17dC299B3f;
    address constant oldEtherFiRedemptionManagerImpl = 0xe6f40295A7500509faD08E924c91b0F050a7b84b;
    address constant oldEtherFiRestakerImpl = 0x0052F731a6BEA541843385ffBA408F52B74Cb624;

    // https://etherscan.io/address/0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0#readProxyContract
    uint16 constant oldExitFeeSplitToTreasuryInBps = 1000;
    uint16 constant oldExitFeeInBps = 30;
    uint16 constant oldLowWatermarkInBpsOfTvl = 100;
    uint64 constant oldRefillRatePerSecond = 23148;
    uint64 constant oldCapacity = 2000000000;

    //--------------------------------------------------------------------------------------
    //---------------------------- New Deployments -----------------------------------------
    //--------------------------------------------------------------------------------------
    LiquidityPool liquidityPoolImpl = LiquidityPool(payable(0xA5C1ddD9185901E3c05E0660126627E039D0a626));
    EtherFiRedemptionManagerTemp etherFiRedemptionManagerTempImpl = EtherFiRedemptionManagerTemp(payable(0x590015FDf9334594B0Ae14f29b0dEd9f1f8504Bc));
    EtherFiRestaker etherFiRestakerImpl = EtherFiRestaker(payable(0x71bEf55739F0b148E2C3e645FDE947f380C48615));
    EtherFiRedemptionManager etherFiRedemptionManagerImpl = EtherFiRedemptionManager(payable(0xE3F384Dc7002547Dd240AC1Ad69a430CCE1e292d));   

    //--------------------------------------------------------------------------------------
    //------------------------- Existing Users/Proxies -------------------------------------
    //--------------------------------------------------------------------------------------
    address constant rewardsCoordinator = 0x7750d328b314EfFa365A0402CcfD489B80B0adda; // Eigen Layer Rewards Coordinator - https://etherscan.io/address/0x7750d328b314effa365a0402ccfd489b80b0adda
    address constant etherFiRedemptionManager = 0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0;
    address constant eETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address constant weETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant stETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant liquidityPool = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address constant operatingTimelock = 0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a;
    address constant roleRegistry = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;
    address constant treasury = 0x0c83EAe1FE72c390A02E426572854931EefF93BA;
    address constant etherFiRestaker = 0x1B7a4C3797236A1C37f8741c0Be35c2c72736fFf;

    address constant ETHERFI_OPERATING_ADMIN = 0x2aCA71020De61bb532008049e1Bd41E451aE8AdC;
    address constant TIMELOCK_CONTROLLER = 0xcdd57D11476c22d265722F68390b036f3DA48c21;

    //--------------------------------------------------------------------------------------
    //-----------------------------  OLD EFRM SELECTORS  -----------------------------------
    //--------------------------------------------------------------------------------------
    bytes4 constant SET_EXIT_FEE_BASIS_POINTS_SELECTOR = 0xad0cba24;
    bytes4 constant SET_EXIT_FEE_SPLIT_TO_TREASURY_IN_BPS_SELECTOR = 0x69b095a2;
    bytes4 constant SET_LOW_WATERMARK_IN_BPS_OF_TVL_SELECTOR = 0x298f3f03;
    bytes4 constant SET_REFILL_RATE_PER_SECOND_SELECTOR = 0x2f530824;
    bytes4 constant SET_CAPACITY_SELECTOR = 0x91915ef8;

    function run() external {
        console2.log("StETH Withdrawals Transactions");
        console2.log("================================================");
        console2.log("");

        vm.startBroadcast(TIMELOCK_CONTROLLER);
        // vm.startPrank(TIMELOCK_CONTROLLER);
        scheduleCleanUpStorageOnEFRM();
        upgrade();
        // vm.stopPrank();
        vm.stopBroadcast();

        vm.startBroadcast(ETHERFI_OPERATING_ADMIN);
        // vm.startPrank(ETHERFI_OPERATING_ADMIN);
        initializeTokenParametersEFRM();
        // vm.stopPrank();
        vm.stopBroadcast();

        // console2.log("=============== ROLLBACK TRANSACTIONS ================");
        // console2.log("================================================");

        vm.startBroadcast(TIMELOCK_CONTROLLER);
        // vm.startPrank(TIMELOCK_CONTROLLER);
        rollbackUpgrade();
        // vm.stopPrank();
        vm.stopBroadcast();

        vm.startBroadcast(ETHERFI_OPERATING_ADMIN);
        // vm.startPrank(ETHERFI_OPERATING_ADMIN);
        rollbackEFRMStorage();
        // vm.stopPrank();
        vm.stopBroadcast();
    }

    function scheduleCleanUpStorageOnEFRM() public {
        bytes32 firstTxId = _upgradeEFRMToTemp();
        _clearOutSlotForUpgrade(firstTxId);
    }

    function _upgradeEFRMToTemp() internal returns (bytes32) {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        uint256[] memory values = new uint256[](1);
        
        targets[0] = address(etherFiRedemptionManager);
        data[0] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, etherFiRedemptionManagerTempImpl);

        bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));
        bytes32 operationId = etherFiTimelock.hashOperationBatch(targets, values, data, bytes32(0), timelockSalt);
        
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherFiTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0)/*=predecessor*/,
            timelockSalt,
            MIN_DELAY_TIMELOCK/*=minDelay*/
        );

        console2.log("Schedule Upgrade EFRM To Temp Tx:");
        console2.logBytes(scheduleCalldata);
        console2.log("================================================");
        console2.log("");

        bytes memory executeCalldata = abi.encodeWithSelector(
            etherFiTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0)/*=predecessor*/,
            timelockSalt
        );

        console2.log("Execute Upgrade EFRM To Temp Tx:");
        console2.logBytes(executeCalldata);
        console2.log("================================================");
        console2.log("");

        // uncomment to run against fork
        console2.log("=== SCHEDULING BATCH ===");
        console2.log("Current timestamp:", block.timestamp);
        etherFiTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_TIMELOCK);
        console2.log("Schedule of Upgrade EFRM To Temp successful");
        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("================================================");
        console2.log("");

        // console2.log("=== FAST FORWARDING TIME ===");
        // vm.warp(block.timestamp + MIN_DELAY_TIMELOCK + 1); // +1 to ensure it's past the delay
        // console2.log("New timestamp:", block.timestamp);
        // etherFiTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
        // console2.log("Execute of Upgrade EFRM To Temp successful");
        // console2.log("================================================");
        // console2.log("");
        
        return operationId;
    }

    function _clearOutSlotForUpgrade(bytes32 predecessor) internal {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        uint256[] memory values = new uint256[](1);

        targets[0] = address(etherFiRedemptionManager);
        data[0] = abi.encodeWithSelector(EtherFiRedemptionManagerTemp.clearOutSlotForUpgrade.selector);

        //--------------------------------------------------------------------------------------
        //------------------------------- SCHEDULE TX --------------------------------------
        //------------------------------------------------      --------------------------------------
        bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));
        bytes32 operationId = etherFiTimelock.hashOperationBatch(targets, values, data, predecessor, timelockSalt);
        
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherFiTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            predecessor, // Use the predecessor from the first transaction
            timelockSalt,
            MIN_DELAY_TIMELOCK/*=minDelay*/
        );

        console2.log("Schedule Clean Up Storage On EFRM Tx:");
        console2.logBytes(scheduleCalldata);
        console2.log("================================================");
        console2.log("");

        // execute
        bytes memory executeCalldata = abi.encodeWithSelector(
            etherFiTimelock.executeBatch.selector,
            targets,
            values,
            data,
            predecessor, // Use the predecessor from the first transaction
            timelockSalt
        );

        console2.log("Execute Clean Up Storage On EFRM Tx:");
        console2.logBytes(executeCalldata);
        console2.log("================================================");
        console2.log("");

        // uncomment to run against fork
        console2.log("=== SCHEDULING BATCH ===");
        console2.log("Current timestamp:", block.timestamp);
        console2.log("Predecessor:", vm.toString(predecessor));
        etherFiTimelock.scheduleBatch(targets, values, data, predecessor, timelockSalt, MIN_DELAY_TIMELOCK);
        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("================================================");
        console2.log("");
        console2.log("scheduled clearOutSlotForUpgrade Tx:");

        // console2.log("=== FAST FORWARDING TIME ===");
        // vm.warp(block.timestamp + MIN_DELAY_TIMELOCK + 1); // +1 to ensure it's past the delay
        // console2.log("New timestamp:", block.timestamp);
        // etherFiTimelock.executeBatch(targets, values, data, predecessor, timelockSalt);
    }

    function initializeTokenParametersEFRM() public {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        uint256[] memory values = new uint256[](1);

        address[] memory _tokens = new address[](2);
        _tokens[0] = eETH;
        _tokens[1] = stETH;
        uint16[] memory _exitFeeSplitToTreasuryInBps = new uint16[](2);
        _exitFeeSplitToTreasuryInBps[0] = 1000;
        _exitFeeSplitToTreasuryInBps[1] = 1000;
        uint16[] memory _exitFeeInBps = new uint16[](2);
        _exitFeeInBps[0] = 30;
        _exitFeeInBps[1] = 10;
        uint16[] memory _lowWatermarkInBpsOfTvl = new uint16[](2);
        _lowWatermarkInBpsOfTvl[0] = 100;
        _lowWatermarkInBpsOfTvl[1] = 0;
        uint256[] memory _bucketCapacity = new uint256[](2);
        _bucketCapacity[0] = 2000000000;
        _bucketCapacity[1] = 2000000000;
        uint256[] memory _bucketRefillRate = new uint256[](2);
        _bucketRefillRate[0] = 23148;
        _bucketRefillRate[1] = 5000;
        
        targets[0] = address(etherFiRedemptionManager);
        data[0] = abi.encodeWithSelector(EtherFiRedemptionManager.initializeTokenParameters.selector, _tokens, _exitFeeSplitToTreasuryInBps, _exitFeeInBps, _lowWatermarkInBpsOfTvl, _bucketCapacity, _bucketRefillRate);

        bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherfiOperatingTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0)/*=predecessor*/,
            timelockSalt,
            MIN_DELAY_OPERATING_TIMELOCK/*=minDelay*/
        );

        console2.log("Schedule Initialize Token Parameters EFRM Tx:");
        console2.logBytes(scheduleCalldata);
        console2.log("================================================");
        console2.log("");

        bytes memory executeCalldata = abi.encodeWithSelector(
            etherfiOperatingTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0)/*=predecessor*/,
            timelockSalt
        );

        console2.log("Execute Initialize Token Parameters EFRM Tx:");
        console2.logBytes(executeCalldata);
        console2.log("================================================");
        console2.log("");

        // uncomment to run against fork
        console2.log("=== SCHEDULING BATCH ===");
        etherfiOperatingTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_OPERATING_TIMELOCK);
        console2.log("Schedule of Initialize Token Parameters EFRM Tx successful");
        console2.log("================================================");
        console2.log("");

        // console2.log("=== FAST FORWARDING TIME ===");
        // vm.warp(block.timestamp + MIN_DELAY_TIMELOCK + 1); // +1 to ensure it's past the delay
        // console2.log("New timestamp:", block.timestamp);
        // etherfiOperatingTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
        // console2.log("Execute of Initialize Token Parameters EFRM Tx successful");
        // console2.log("================================================");
        // console2.log("");
    }

    function upgrade() public {
        console2.log("Executing Upgrade");
        address[] memory targets = new address[](3);
        bytes[] memory data = new bytes[](3);
        uint256[] memory values = new uint256[](3);

        targets[0] = address(liquidityPool);
        data[0] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, liquidityPoolImpl);
        
        targets[1] = address(etherFiRedemptionManager);
        data[1] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, etherFiRedemptionManagerImpl);

        targets[2] = address(etherFiRestaker);
        data[2] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, etherFiRestakerImpl);

        bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherFiTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0)/*=predecessor*/,
            timelockSalt,
            MIN_DELAY_TIMELOCK/*=minDelay*/
        );

        console2.log("Schedule Upgrade Tx:");
        console2.logBytes(scheduleCalldata);
        console2.log("================================================");
        console2.log("");

        bytes memory executeCalldata = abi.encodeWithSelector(
            etherFiTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0)/*=predecessor*/,
            timelockSalt
        );

        console2.log("Execute Upgrade Tx:");
        console2.logBytes(executeCalldata);
        console2.log("================================================");
        console2.log("");

        // uncomment to run against fork
        console2.log("=== SCHEDULING BATCH ===");
        console2.log("Current timestamp:", block.timestamp);
        etherFiTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_TIMELOCK);
        console2.log("Schedule of Upgrade Tx successful");
        console2.log("================================================");
        console2.log("");

        // console2.log("=== FAST FORWARDING TIME ===");
        // vm.warp(block.timestamp + MIN_DELAY_TIMELOCK + 1); // +1 to ensure it's past the delay
        // console2.log("New timestamp:", block.timestamp);
        // etherFiTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
        // console2.log("Execute of Upgrade Tx successful");
        // console2.log("================================================");
        // console2.log("");
    }

    function rollbackUpgrade() public {
        address[] memory targets = new address[](4);
        bytes[] memory data = new bytes[](4);
        uint256[] memory values = new uint256[](4);

        targets[0] = address(liquidityPool);
        data[0] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, oldLiquidityPoolImpl);
        
        targets[1] = address(etherFiRedemptionManager);
        data[1] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, oldEtherFiRedemptionManagerImpl);

        targets[2] = address(etherFiRestaker);
        data[2] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, oldEtherFiRestakerImpl);

        bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherFiTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0)/*=predecessor*/,
            timelockSalt,
            MIN_DELAY_TIMELOCK/*=minDelay*/
        );

        console2.log("Schedule Rollback Upgrade Tx:");
        console2.logBytes(scheduleCalldata);
        console2.log("================================================");
        console2.log("");

        bytes memory executeCalldata = abi.encodeWithSelector(
            etherFiTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0)/*=predecessor*/,
            timelockSalt
        );

        console2.log("Execute Rollback Upgrade Tx:");
        console2.logBytes(executeCalldata);
        console2.log("================================================");
        console2.log("");

        // uncomment to run against fork
        console2.log("=== SCHEDULING BATCH ===");
        console2.log("Current timestamp:", block.timestamp);
        etherFiTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_TIMELOCK);
        console2.log("Schedule of Rollback Upgrade Tx successful");
        console2.log("================================================");
        console2.log("");

        // console2.log("=== FAST FORWARDING TIME ===");
        // vm.warp(block.timestamp + MIN_DELAY_TIMELOCK + 1); // +1 to ensure it's past the delay
        // console2.log("New timestamp:", block.timestamp);   
        // etherFiTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
        // console2.log("Execute of Rollback Upgrade Tx successful");
        // console2.log("================================================");
        // console2.log("");
    }

    function rollbackEFRMStorage() public {
        address[] memory targets = new address[](5);
        bytes[] memory data = new bytes[](5);
        uint256[] memory values = new uint256[](5);

        data[0] = abi.encodeWithSelector(SET_EXIT_FEE_BASIS_POINTS_SELECTOR, oldExitFeeInBps);
        data[1] = abi.encodeWithSelector(SET_EXIT_FEE_SPLIT_TO_TREASURY_IN_BPS_SELECTOR, oldExitFeeSplitToTreasuryInBps);
        data[2] = abi.encodeWithSelector(SET_LOW_WATERMARK_IN_BPS_OF_TVL_SELECTOR, oldLowWatermarkInBpsOfTvl);
        data[3] = abi.encodeWithSelector(SET_REFILL_RATE_PER_SECOND_SELECTOR, oldRefillRatePerSecond);
        data[4] = abi.encodeWithSelector(SET_CAPACITY_SELECTOR, oldCapacity);

        for(uint256 i = 0; i < targets.length; i++) {
            targets[i] = address(etherFiRedemptionManager);
        }

        bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherfiOperatingTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0)/*=predecessor*/,
            timelockSalt,
            MIN_DELAY_OPERATING_TIMELOCK/*=minDelay*/
        );

        console2.log("Schedule Rollback EFRM Storage Tx:");
        console2.logBytes(scheduleCalldata);
        console2.log("================================================");
        console2.log("");

        bytes memory executeCalldata = abi.encodeWithSelector(
            etherfiOperatingTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0)/*=predecessor*/,
            timelockSalt
        );

        console2.log("Execute Rollback EFRM Storage Tx:");
        console2.logBytes(executeCalldata);
        console2.log("================================================");
        console2.log("");

        // uncomment to run against fork
        console2.log("=== SCHEDULING BATCH ===");
        console2.log("Current timestamp:", block.timestamp);
        etherfiOperatingTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_OPERATING_TIMELOCK);
        console2.log("Schedule of Rollback EFRM Storage Tx successful");
        console2.log("================================================");
        console2.log("");

        // console2.log("=== EXECUTING BATCH ===");
        // vm.warp(block.timestamp + MIN_DELAY_OPERATING_TIMELOCK + 1); // +1 to ensure it's past the delay
        // console2.log("New timestamp:", block.timestamp);
        // etherfiOperatingTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
        // console2.log("Execute of Rollback EFRM Storage Tx successful");
        // console2.log("================================================");
        // console2.log("");
    }
}