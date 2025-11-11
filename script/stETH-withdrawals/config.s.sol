// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {Utils} from "../utils/utils.sol";
import "../../src/EtherFiRedemptionManager.sol";
import "../../src/LiquidityPool.sol";
import "../../src/EtherFiTimelock.sol";
import "forge-std/Test.sol";

contract StETHWithdrawalsConfig is Script, Utils, Test {
    EtherFiRedemptionManager constant etherFiRedemptionManager = EtherFiRedemptionManager(payable(ETHERFI_REDEMPTION_MANAGER));
    EtherFiTimelock constant etherfiOperatingTimelock = EtherFiTimelock(payable(OPERATING_TIMELOCK));

    // ETH config
    // 2000 ETH per Day -> 2000 * 1e18 / 86400 = 23148 * 1e12
    uint256 constant refillRateETH = uint256(2000 ether) / 86400;
    uint256 constant capacityETH = 2000 ether;
    uint16 constant exitFeeSplitToTreasuryInBpsETH = 1000;
    uint16 constant exitFeeInBpsETH = 30;
    uint16 constant lowWatermarkInBpsOfTvlETH = 100;
    uint64 constant expectedRefillRateETH = uint64(refillRateETH / 1e12);
    uint64 constant expectedCapacityETH = uint64(capacityETH / 1e12);

    // stETH config
    // 5000 stETH per Day -> 5000 * 1e18 / 86400 = 57870 * 1e12
    uint256 constant refillRateStETH = uint256(5000 ether) / 86400;
    uint256 constant capacityStETH = 5000 ether;
    uint16 constant exitFeeSplitToTreasuryInBpsStETH = 1000;
    uint16 constant exitFeeInBpsStETH = 0;
    uint16 constant lowWatermarkInBpsOfTvlStETH = 0;
    uint64 constant expectedRefillRateStETH = uint64(refillRateStETH / 1e12);
    uint64 constant expectedCapacityStETH = uint64(capacityStETH / 1e12);

    function run() external {
        updateConfigs();
    }

    function updateConfigs() public {
        address[] memory targets = new address[](4);
        bytes[] memory data = new bytes[](4);
        uint256[] memory values = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) {
            targets[i] = address(etherFiRedemptionManager);
            values[i] = 0;
        }
        data[0] = abi.encodeWithSelector(EtherFiRedemptionManager.setCapacity.selector, capacityETH, address(etherFiRedemptionManager.ETH_ADDRESS()));
        data[1] = abi.encodeWithSelector(EtherFiRedemptionManager.setCapacity.selector, capacityStETH, address(etherFiRedemptionManager.lido()));
        data[2] = abi.encodeWithSelector(EtherFiRedemptionManager.setRefillRatePerSecond.selector, refillRateETH, address(etherFiRedemptionManager.ETH_ADDRESS()));
        data[3] = abi.encodeWithSelector(EtherFiRedemptionManager.setRefillRatePerSecond.selector, refillRateStETH, address(etherFiRedemptionManager.lido()));

        bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherfiOperatingTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0),
            timelockSalt,
            MIN_DELAY_OPERATING_TIMELOCK
        );
        console2.log("Schedule Update Configs EFRM Tx:");
        console2.logBytes(scheduleCalldata);
        console2.log("================================================");
        console2.log("");

        bytes memory executeCalldata = abi.encodeWithSelector(
            etherfiOperatingTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0),
            timelockSalt
        );
        console2.log("Execute Update Configs EFRM Tx:");
        console2.logBytes(executeCalldata);
        console2.log("================================================");
        console2.log("");

        // uncomment to run against fork
        console2.log("=== SCHEDULING BATCH ===");
        vm.startPrank(ETHERFI_OPERATING_ADMIN);
        etherfiOperatingTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_OPERATING_TIMELOCK);
        console2.log("Schedule of Update Configs EFRM Tx successful");
        console2.log("================================================");
        console2.log("");

        console2.log("=== FAST FORWARDING TIME ===");
        vm.warp(block.timestamp + MIN_DELAY_OPERATING_TIMELOCK + 1); // +1 to ensure it's past the delay
        etherfiOperatingTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
        vm.stopPrank();
        console2.log("Execute of Update Configs EFRM Tx successful");
        console2.log("================================================");
        console2.log("");

        // verify the configs
        (BucketLimiter.Limit memory limit, uint16 exitSplit, uint16 exitFee, uint16 lowWM) = 
            etherFiRedemptionManager.tokenToRedemptionInfo(address(etherFiRedemptionManager.lido()));
        assertEq(limit.remaining, 0);
        assertEq(limit.capacity, expectedCapacityStETH);
        assertEq(limit.refillRate, expectedRefillRateStETH);

        (BucketLimiter.Limit memory limitETH, uint16 exitSplitETH, uint16 exitFeeETH, uint16 lowWMETH) = 
            etherFiRedemptionManager.tokenToRedemptionInfo(address(etherFiRedemptionManager.ETH_ADDRESS()));
        assertEq(limitETH.remaining, 0);
        assertEq(limitETH.capacity, expectedCapacityETH);
        assertEq(limitETH.refillRate, expectedRefillRateETH);

        vm.warp(block.timestamp + 1 days + 1 seconds);
        assertEq(etherFiRedemptionManager.totalRedeemableAmount(address(etherFiRedemptionManager.lido())), capacityStETH);
        assertTrue(etherFiRedemptionManager.canRedeem(capacityStETH, address(etherFiRedemptionManager.lido())));
        assertFalse(etherFiRedemptionManager.canRedeem(capacityStETH + 1 ether, address(etherFiRedemptionManager.lido())));
    }
}