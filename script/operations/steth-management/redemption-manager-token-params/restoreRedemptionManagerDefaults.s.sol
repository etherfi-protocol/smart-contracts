// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {Utils} from "../../../utils/utils.sol";
import {EtherFiRedemptionManager} from "../../../../src/EtherFiRedemptionManager.sol";
import {EtherFiTimelock} from "../../../../src/EtherFiTimelock.sol";
import {ILiquidityPool} from "../../../../src/interfaces/ILiquidityPool.sol";
import {IeETH} from "../../../../src/interfaces/IeETH.sol";
import {ILido} from "../../../../src/interfaces/ILiquifier.sol";
import {EtherFiRestaker} from "../../../../src/EtherFiRestaker.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "lib/BucketLimiter.sol";

/**
 * @title RestoreRedemptionManagerDefaults
 * @notice Restores the EtherFiRedemptionManager stETH parameters to default values
 *         via OPERATING_TIMELOCK and verifies rate limiter boundaries + refill behavior.
 *
 * Parameters:
 *   1. setExitFeeBasisPoints(10, stETH)        — 10 bps exit fee
 *   2. setCapacity(5_000 ether, stETH)         — 5,000 stETH bucket capacity
 *   3. setRefillRatePerSecond(57_870, stETH)    — ~5,000 stETH/day refill
 *
 * Run:
 * source .env && forge script script/operations/steth-management/redemption-manager-token-params/restoreRedemptionManagerDefaults.s.sol --fork-url $MAINNET_RPC_URL -vvvv
 */
contract RestoreRedemptionManagerDefaults is Script, Utils, Test {
    EtherFiRedemptionManager constant rm = EtherFiRedemptionManager(payable(ETHERFI_REDEMPTION_MANAGER));
    EtherFiTimelock constant operatingTimelock = EtherFiTimelock(payable(OPERATING_TIMELOCK));
    ILiquidityPool constant lp = ILiquidityPool(payable(LIQUIDITY_POOL));
    IeETH constant eEth = IeETH(EETH);
    EtherFiRestaker constant restaker = EtherFiRestaker(payable(ETHERFI_RESTAKER));

    // stETH default config
    uint16 constant exitFeeInBpsStETH = 10;
    uint256 constant capacityStETH = 5_000 ether;
    uint256 constant refillRateStETH = 57_870 * 1e12;

    // Test user — an address with no special roles
    address constant TEST_USER = 0x7ee29373F075eE1d83b1b93b4fe94ae242Df5178;

    function run() external {
        console2.log("====================================================");
        console2.log("=== Restore RedemptionManager stETH Defaults");
        console2.log("====================================================");

        address stETH = address(rm.lido());
        console2.log("stETH address:", stETH);

        logCurrentConfig(stETH, "=== Current Config (stETH) ===");

        buildAndExecuteTransactions(stETH);

        verifyConfig(stETH);

        testBoundariesAndRefill(stETH);

        console2.log("");
        console2.log("=== All Tests Passed ===");
    }

    function buildAndExecuteTransactions(address stETH) internal {
        address[] memory targets = new address[](3);
        bytes[] memory data = new bytes[](3);
        uint256[] memory values = new uint256[](3);

        for (uint256 i = 0; i < 3; i++) {
            targets[i] = address(rm);
            values[i] = 0;
        }

        data[0] = abi.encodeWithSelector(
            EtherFiRedemptionManager.setExitFeeBasisPoints.selector,
            exitFeeInBpsStETH,
            stETH
        );
        data[1] = abi.encodeWithSelector(
            EtherFiRedemptionManager.setCapacity.selector,
            capacityStETH,
            stETH
        );
        data[2] = abi.encodeWithSelector(
            EtherFiRedemptionManager.setRefillRatePerSecond.selector,
            refillRateStETH,
            stETH
        );

        bytes32 timelockSalt = keccak256(abi.encode(targets, data, "redemption-manager-steth-restore-defaults-v1", block.number));

        // Generate Gnosis Safe JSON — Schedule
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            operatingTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0),
            timelockSalt,
            MIN_DELAY_OPERATING_TIMELOCK
        );
        writeSafeJson(
            "script/operations/steth-management/redemption-manager-token-params",
            "restore-defaults-schedule.json",
            ETHERFI_OPERATING_ADMIN,
            OPERATING_TIMELOCK,
            0,
            scheduleCalldata,
            1
        );

        // Generate Gnosis Safe JSON — Execute
        bytes memory executeCalldata = abi.encodeWithSelector(
            operatingTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0),
            timelockSalt
        );
        writeSafeJson(
            "script/operations/steth-management/redemption-manager-token-params",
            "restore-defaults-execute.json",
            ETHERFI_OPERATING_ADMIN,
            OPERATING_TIMELOCK,
            0,
            executeCalldata,
            1
        );

        // Execute on fork for testing
        console2.log("=== Scheduling on Fork ===");
        vm.startPrank(ETHERFI_OPERATING_ADMIN);
        operatingTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_OPERATING_TIMELOCK);
        console2.log("Schedule successful");

        console2.log("=== Fast-forwarding past delay ===");
        vm.warp(block.timestamp + MIN_DELAY_OPERATING_TIMELOCK + 1);
        operatingTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
        vm.stopPrank();
        console2.log("Execute successful");
        console2.log("================================================");

        logCurrentConfig(stETH, "=== Post-Config (stETH) ===");
    }

    function verifyConfig(address stETH) internal {
        console2.log("=== Verifying Config ===");

        (
            BucketLimiter.Limit memory limit,
            ,
            uint16 exitFee,
        ) = rm.tokenToRedemptionInfo(stETH);

        assertEq(exitFee, exitFeeInBpsStETH, "exitFee mismatch");
        console2.log("  [OK] exitFeeInBps:", exitFee);

        uint64 expectedCapacity = uint64(capacityStETH / 1e12);
        assertEq(limit.capacity, expectedCapacity, "capacity mismatch");
        console2.log("  [OK] capacity (bucket units):", limit.capacity);

        uint64 expectedRefillRate = uint64(refillRateStETH / 1e12);
        assertEq(limit.refillRate, expectedRefillRate, "refillRate mismatch");
        console2.log("  [OK] refillRate (bucket units):", limit.refillRate);

        console2.log("  Config verification passed!");
        console2.log("================================================");
    }

    //--------------------------------------------------------------------------------------
    //------ BOUNDARY + REFILL TESTS -------------------------------------------------------
    //--------------------------------------------------------------------------------------

    function testBoundariesAndRefill(address stETH) internal {
        console2.log("=== Boundary & Refill Rate Tests ===");
        console2.log("");

        // Ensure lowWatermark is 0 so it doesn't block test redemptions
        vm.prank(ETHERFI_OPERATING_ADMIN);
        operatingTimelock.schedule(
            address(rm),
            0,
            abi.encodeWithSelector(EtherFiRedemptionManager.setLowWatermarkInBpsOfTvl.selector, uint16(0), stETH),
            bytes32(0),
            keccak256(abi.encode("set-low-watermark-zero", block.number)),
            MIN_DELAY_OPERATING_TIMELOCK
        );
        vm.warp(block.timestamp + MIN_DELAY_OPERATING_TIMELOCK + 1);
        vm.prank(ETHERFI_OPERATING_ADMIN);
        operatingTimelock.execute(
            address(rm),
            0,
            abi.encodeWithSelector(EtherFiRedemptionManager.setLowWatermarkInBpsOfTvl.selector, uint16(0), stETH),
            bytes32(0),
            keccak256(abi.encode("set-low-watermark-zero", block.number))
        );

        // Fund the restaker with enough stETH for test redemptions
        _ensureRestakerStEth(ILido(stETH), 10_000 ether);

        // Mint eETH to test user
        _mintEEthToUser(10_000 ether);

        // Let bucket fully refill to capacity
        vm.warp(block.timestamp + 1 days);

        // --- Test 1: Redemption within capacity succeeds ---
        console2.log("  [Test 1] Redeem within capacity (4,000 stETH)...");
        uint256 redeemAmount = 4_000 ether;
        assertTrue(rm.canRedeem(redeemAmount, stETH), "Should be able to redeem 4,000 stETH");

        vm.startPrank(TEST_USER);
        IERC20(address(eEth)).approve(address(rm), redeemAmount);
        uint256 stEthBefore = IERC20(stETH).balanceOf(TEST_USER);
        rm.redeemEEth(redeemAmount, TEST_USER, stETH);
        vm.stopPrank();

        uint256 stEthReceived = IERC20(stETH).balanceOf(TEST_USER) - stEthBefore;
        // With 10 bps fee, user should receive ~redeemAmount * 9990/10000
        uint256 expectedMin = redeemAmount * 9980 / 10000;
        assertTrue(stEthReceived >= expectedMin, "Received less stETH than expected after fee");
        console2.log("  [OK] Redeemed 4,000 eETH, received", stEthReceived / 1e18, "stETH");

        // --- Test 2: Redemption exceeding remaining bucket fails ---
        console2.log("  [Test 2] Redeem exceeding remaining bucket (2,000 stETH)...");
        assertFalse(rm.canRedeem(2_000 ether, stETH), "Should NOT be able to redeem 2,000 stETH (bucket depleted)");
        console2.log("  [OK] canRedeem(2,000 stETH) = false (bucket exhausted)");

        // --- Test 3: Redemption at exact capacity boundary ---
        console2.log("  [Test 3] Redeem remaining bucket (~1,000 stETH)...");
        // Remaining should be ~1,000 stETH (5,000 capacity - 4,000 consumed)
        assertTrue(rm.canRedeem(900 ether, stETH), "Should be able to redeem 900 stETH from remaining bucket");
        console2.log("  [OK] canRedeem(900 stETH) = true (within remaining bucket)");

        // --- Test 4: Refill over time ---
        console2.log("  [Test 4] Verify refill after waiting...");

        // refillRate = 57,870 wei/sec. To refill ~2,000 stETH (2e18 wei):
        // time = 2e18 / 57,870 ~= 34,554 seconds (~9.6 hours)
        uint256 refillWait = 35_000 seconds;
        vm.warp(block.timestamp + refillWait);

        // After refill, we should be able to redeem ~2,000 more stETH
        assertTrue(rm.canRedeem(2_000 ether, stETH), "Should be able to redeem 2,000 stETH after refill");
        console2.log("  [OK] canRedeem(2,000 stETH) = true after", refillWait, "seconds refill");

        // But should NOT be able to redeem the full capacity again (not enough time to fully refill)
        assertFalse(rm.canRedeem(4_000 ether, stETH), "Should NOT be able to redeem 4,000 stETH (not fully refilled)");
        console2.log("  [OK] canRedeem(4,000 stETH) = false (only partially refilled)");

        // --- Test 5: Full refill restores capacity ---
        console2.log("  [Test 5] Full refill restores capacity...");
        // To fully refill 5,000 stETH: 5e18 / 57,870 ~= 86,385 seconds (~24 hours)
        vm.warp(block.timestamp + 1 days);
        assertTrue(rm.canRedeem(4_999 ether, stETH), "Should be able to redeem ~5,000 stETH after full refill");
        assertFalse(rm.canRedeem(5_001 ether, stETH), "Should NOT be able to redeem > capacity");
        console2.log("  [OK] Full capacity restored after 1 day");

        console2.log("");
        console2.log("  All boundary & refill tests passed!");
        console2.log("================================================");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- HELPERS ----------------------------------------------
    //--------------------------------------------------------------------------------------

    function _mintEEthToUser(uint256 eEthNeeded) internal {
        vm.deal(TEST_USER, eEthNeeded + 1 ether);
        vm.startPrank(TEST_USER);
        lp.deposit{value: eEthNeeded + 1 ether}(address(0));
        vm.stopPrank();
        require(eEth.balanceOf(TEST_USER) >= eEthNeeded, "Failed to mint enough eETH");
    }

    function _ensureRestakerStEth(ILido stEthToken, uint256 stEthNeeded) internal {
        uint256 currentBalance = stEthToken.balanceOf(ETHERFI_RESTAKER);
        if (currentBalance >= stEthNeeded) return;

        uint256 deficit = stEthNeeded - currentBalance + 2 ether;
        address depositor = address(0xDEAD);

        vm.deal(depositor, deficit);
        vm.startPrank(depositor);
        stEthToken.submit{value: deficit}(address(0));
        IERC20(address(stEthToken)).transfer(ETHERFI_RESTAKER, stEthToken.balanceOf(depositor));
        vm.stopPrank();

        require(stEthToken.balanceOf(ETHERFI_RESTAKER) >= stEthNeeded, "Failed to fund restaker stETH");
    }

    function logCurrentConfig(address stETH, string memory label) internal view {
        (
            ,
            uint16 exitFeeSplit,
            uint16 exitFee,
            uint16 lowWM
        ) = rm.tokenToRedemptionInfo(stETH);

        console2.log(label);
        console2.log("  exitFeeInBps:           ", exitFee);
        console2.log("  exitFeeSplitToTreasury: ", exitFeeSplit);
        console2.log("  lowWatermarkInBpsOfTvl: ", lowWM);
        console2.log("  instantLiquidity:       ", rm.getInstantLiquidityAmount(stETH) / 1e18, "stETH");
        console2.log("");
    }
}
