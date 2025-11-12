// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import "../../test/common/ArrayTestHelper.sol";

import "../../src/LiquidityPool.sol";
import "../../src/EtherFiRedemptionManager.sol";
import "../../script/utils/utils.sol";

// Command to run this test: forge test --match-contract StETHConfigTest

contract StETHConfigTest is Utils, Test, ArrayTestHelper {
    EtherFiRedemptionManager constant etherFiRedemptionManagerInstance = EtherFiRedemptionManager(payable(ETHERFI_REDEMPTION_MANAGER));
            // ETH config
            // 2000 ETH per Day -> 2000 * 1e18 / 86400
            uint256 constant refillRateETH = uint256(2000 ether) / 86400;
            uint256 constant capacityETH = 2000 ether;
            uint16 constant exitFeeSplitToTreasuryInBpsETH = 1000;
            uint16 constant exitFeeInBpsETH = 30;
            uint16 constant lowWatermarkInBpsOfTvlETH = 100;

            uint64 constant expectedRefillRateETH = uint64(refillRateETH / 1e12);
            uint64 constant expectedCapacityETH = uint64(capacityETH / 1e12);

            // stETH config
            // 5000 stETH per Day -> 5000 * 1e18 / 86400
            uint256 constant refillRateStETH = uint256(5000 ether) / 86400;
            uint256 constant capacityStETH = 5000 ether;
            uint16 constant exitFeeSplitToTreasuryInBpsStETH = 1000;
            uint16 constant exitFeeInBpsStETH = 0;
            uint16 constant lowWatermarkInBpsOfTvlStETH = 0;

            uint64 constant expectedRefillRateStETH = uint64(refillRateStETH / 1e12);
            uint64 constant expectedCapacityStETH = uint64(capacityStETH / 1e12);

        function setUp() public {
        vm.selectFork(vm.createFork(vm.envString("MAINNET_RPC_URL")));
        }

        function test_stETHConfig() public {
            vm.startPrank(OPERATING_TIMELOCK);
            etherFiRedemptionManagerInstance.setCapacity(capacityETH, address(etherFiRedemptionManagerInstance.ETH_ADDRESS()));
            etherFiRedemptionManagerInstance.setCapacity(capacityStETH, address(etherFiRedemptionManagerInstance.lido()));
            etherFiRedemptionManagerInstance.setRefillRatePerSecond(refillRateETH, address(etherFiRedemptionManagerInstance.ETH_ADDRESS()));
            etherFiRedemptionManagerInstance.setRefillRatePerSecond(refillRateStETH, address(etherFiRedemptionManagerInstance.lido()));
            vm.stopPrank();

            // verify the stETH config
            (BucketLimiter.Limit memory limit, uint16 exitSplit, uint16 exitFee, uint16 lowWM) = 
                etherFiRedemptionManagerInstance.tokenToRedemptionInfo(address(etherFiRedemptionManagerInstance.lido()));
            assertEq(limit.remaining, 0);
            assertEq(limit.capacity, expectedCapacityStETH);
            assertEq(limit.refillRate, expectedRefillRateStETH);

            // verify the ETH config
            (BucketLimiter.Limit memory limitETH, uint16 exitSplitETH, uint16 exitFeeETH, uint16 lowWMETH) = 
                etherFiRedemptionManagerInstance.tokenToRedemptionInfo(address(etherFiRedemptionManagerInstance.ETH_ADDRESS()));
            assertEq(limitETH.remaining, 0);
            assertEq(limitETH.capacity, expectedCapacityETH);
            assertEq(limitETH.refillRate, expectedRefillRateETH);
            assertFalse(etherFiRedemptionManagerInstance.canRedeem(5000 ether, address(etherFiRedemptionManagerInstance.lido()))); // not enough remaining

            vm.warp(block.timestamp + 1 days + 1 seconds);
            assertTrue(etherFiRedemptionManagerInstance.canRedeem(5000 ether, address(etherFiRedemptionManagerInstance.lido()))); // enough remaining
            assertFalse(etherFiRedemptionManagerInstance.canRedeem(5001 ether, address(etherFiRedemptionManagerInstance.lido())));

            assertEq(etherFiRedemptionManagerInstance.totalRedeemableAmount(address(etherFiRedemptionManagerInstance.lido())), 5000 ether);
        }
}