// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {Utils} from "../utils/utils.sol";
import {EtherFiTimelock} from "../../src/EtherFiTimelock.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";

contract StETHWithdrawalsTransactions is Script, Utils {
    EtherFiTimelock etherFiTimelock = EtherFiTimelock(payable(0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761));
    EtherFiTimelock etherfiOperatingTimelock = EtherFiTimelock(payable(0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a));
    //--------------------------------------------------------------------------------------
    //--------------------- Previous Implementations ---------------------------------------
    //--------------------------------------------------------------------------------------
    address constant oldLiquidityPoolImpl = 0x025911766aEF6fF0C294FD831a2b5c17dC299B3f;
    address constant oldEtherFiRedemptionManagerImpl = 0xe6f40295A7500509faD08E924c91b0F050a7b84b;
    address constant oldEtherFiRestakerImpl = 0x0052F731a6BEA541843385ffBA408F52B74Cb624;

    uint16 constant oldExitFeeSplitToTreasuryInBps = 1000;
    uint16 constant oldExitFeeInBps = 30;
    uint16 constant oldLowWatermarkInBpsOfTvl = 100;
    uint64 constant oldRefillRatePerSecond = 23148;
    uint64 constant oldCapacity = 2000000000;
    //--------------------------------------------------------------------------------------
    //---------------------------- New Deployments -----------------------------------------
    //--------------------------------------------------------------------------------------
    address liquidityPoolImpl;
    address etherFiRedemptionManagerTempImpl;
    address etherFiRestakerImpl;
    address etherFiRedemptionManagerImpl;   

    //--------------------------------------------------------------------------------------
    //------------------------- Existing Users/Proxies -------------------------------------
    //--------------------------------------------------------------------------------------
    address constant rewardsCoordinator = 0x7750d328b314EfFa365A0402CcfD489B80B0adda; // Eigen Layer Rewards Coordinator - https://etherscan.io/address/0x7750d328b314effa365a0402ccfd489b80b0adda
    address constant etherFiRedemptionManager = 0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0;
    address constant eETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address constant weETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant liquidityPool = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address constant operatingTimelock = 0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a;
    address constant roleRegistry = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;
    address constant treasury = 0x0c83EAe1FE72c390A02E426572854931EefF93BA;
    address constant etherFiRestaker = 0x1B7a4C3797236A1C37f8741c0Be35c2c72736fFf;

    function run() external {
        console2.log("StETH Withdrawals Transactions");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        scheduleCleanUpStorageOnEFRM();
        upgrade();
        rollback();
        vm.stopBroadcast();
    }

    function upgrade() external {
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
        // console2.log("=== SCHEDULING BATCH ===");
        // console2.log("Current timestamp:", block.timestamp);
        // etherFiTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_TIMELOCK);

        // console2.log("=== FAST FORWARDING TIME ===");
        // vm.warp(block.timestamp + MIN_DELAY_TIMELOCK + 1); // +1 to ensure it's past the delay
        // console2.log("New timestamp:", block.timestamp);
        // etherFiTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
    }

    function scheduleCleanUpStorageOnEFRM() external {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        uint256[] memory values = new uint256[](1);

        targets[0] = address(etherFiRedemptionManager);
        data[0] = abi.encodeWithSelector(EtherFiRedemptionManager.clearOutSlotForUpgrade.selector);

        //--------------------------------------------------------------------------------------
        //------------------------------- SCHEDULE TX --------------------------------------
        //------------------------------------------------      --------------------------------------
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
            bytes32(0)/*=predecessor*/,
            timelockSalt
        );

        console2.log("Execute Clean Up Storage On EFRM Tx:");
        console2.logBytes(executeCalldata);
        console2.log("================================================");
        console2.log("");

        // uncomment to run against fork
        // console2.log("=== SCHEDULING BATCH ===");
        // console2.log("Current timestamp:", block.timestamp);
        // etherFiTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_TIMELOCK);

        // console2.log("=== FAST FORWARDING TIME ===");
        // vm.warp(block.timestamp + MIN_DELAY_TIMELOCK + 1); // +1 to ensure it's past the delay
        // console2.log("New timestamp:", block.timestamp);
        // etherFiTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
    }

    function rollback() external {
        console2.log("Executing Rollback");
        _rollback_Upgrade();
        _rollback_EFRM_storage();
    }

    function _rollback_EFRM_storage() internal {
        address[] memory targets = new address[](5);
        bytes[] memory data = new bytes[](5);
        uint256[] memory values = new uint256[](5);

        // TODO: check about the remaining field in Limit 

        data[0] = abi.encodeWithSelector(EtherFiRedemptionManager.setExitFeeBasisPoints.selector, oldExitFeeInBps);
        data[1] = abi.encodeWithSelector(EtherFiRedemptionManager.setExitFeeSplitToTreasuryInBps.selector, oldExitFeeSplitToTreasuryInBps);
        data[2] = abi.encodeWithSelector(EtherFiRedemptionManager.setLowWatermarkInBpsOfTvl.selector, oldLowWatermarkInBpsOfTvl);
        data[3] = abi.encodeWithSelector(EtherFiRedemptionManager.setRefillRatePerSecond.selector, oldRefillRatePerSecond);
        data[4] = abi.encodeWithSelector(EtherFiRedemptionManager.setCapacity.selector, oldCapacity);

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
        // console2.log("=== SCHEDULING BATCH ===");
        // console2.log("Current timestamp:", block.timestamp);
        // etherfiOperatingTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_OPERATING_TIMELOCK);

        // console2.log("=== EXECUTING BATCH ===");
        // vm.warp(block.timestamp + MIN_DELAY_OPERATING_TIMELOCK + 1); // +1 to ensure it's past the delay
        // console2.log("New timestamp:", block.timestamp);
        // etherfiOperatingTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
    }

    function _rollback_Upgrade() internal {
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
        // console2.log("=== SCHEDULING BATCH ===");
        // console2.log("Current timestamp:", block.timestamp);
        // etherFiTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_TIMELOCK);

        // console2.log("=== FAST FORWARDING TIME ===");
        // vm.warp(block.timestamp + MIN_DELAY_TIMELOCK + 1); // +1 to ensure it's past the delay
        // console2.log("New timestamp:", block.timestamp);
        // etherFiTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
    }
}