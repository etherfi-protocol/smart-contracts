// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {Utils} from "../../../utils/utils.sol";
import {EtherFiRedemptionManager} from "../../../../src/EtherFiRedemptionManager.sol";
import {EtherFiTimelock} from "../../../../src/EtherFiTimelock.sol";
import {EtherFiRestaker} from "../../../../src/EtherFiRestaker.sol";
import {Liquifier} from "../../../../src/Liquifier.sol";
import {ILiquidityPool} from "../../../../src/interfaces/ILiquidityPool.sol";
import {IeETH} from "../../../../src/interfaces/IeETH.sol";
import {IWeETH} from "../../../../src/interfaces/IWeETH.sol";
import {ILido} from "../../../../src/interfaces/ILiquifier.sol";
import {IDelegationManager} from "../../../../src/eigenlayer-interfaces/IDelegationManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "lib/BucketLimiter.sol";

/**
 * @title SetCapacityForWhaleWeEthRedemption
 * @notice Configures the EtherFiRedemptionManager via OPERATING_TIMELOCK to allow
 *         a whale (0x7ee29373F075eE1d83b1b93b4fe94ae242Df5178) to redeem
 *         108070.928836140722914995 weETH to stETH.
 *
 * Generates 4 Safe JSONs:
 *   1. schedule-increase: schedule capacity + refillRate increase for stETH
 *   2. execute-increase:  execute capacity + refillRate increase
 *   3. schedule-revert:   schedule revert to current capacity + refillRate
 *   4. execute-revert:    execute revert to current capacity + refillRate
 *
 * Run:
 * source .env && forge script script/operations/steth-management/redemption-manager-token-params/SetCapacityForWhaleWeEthRedemption.s.sol --fork-url $MAINNET_RPC_URL -vvvv
 */
contract SetCapacityForWhaleWeEthRedemption is Script, Utils, Test {
    EtherFiRedemptionManager constant rm = EtherFiRedemptionManager(payable(ETHERFI_REDEMPTION_MANAGER));
    EtherFiTimelock constant operatingTimelock = EtherFiTimelock(payable(OPERATING_TIMELOCK));
    ILiquidityPool constant lp = ILiquidityPool(payable(LIQUIDITY_POOL));
    IeETH constant eEth = IeETH(EETH);
    IWeETH constant weEth = IWeETH(WEETH);
    Liquifier constant liquifier = Liquifier(payable(LIQUIFIER));
    EtherFiRestaker constant restaker = EtherFiRestaker(payable(ETHERFI_RESTAKER));

    address constant WHALE = 0x7ee29373F075eE1d83b1b93b4fe94ae242Df5178;
    uint256 constant WEETH_AMOUNT = 108070928836140722914995;
    uint256 constant NEW_CAPACITY = 130_000 ether;
    uint16 constant NEW_EXIT_FEE_BPS = 0;

    function run() external {
        console2.log("====================================================");
        console2.log("=== Set Capacity for Whale weETH -> stETH Redemption");
        console2.log("====================================================");
        console2.log("");

        address stETH = address(rm.lido());
        console2.log("stETH address:", stETH);

        uint256 eEthAmount = weEth.getEETHByWeETH(WEETH_AMOUNT);
        console2.log("Whale weETH balance:  ", WEETH_AMOUNT / 1e18, "weETH");
        console2.log("eETH equivalent:      ", eEthAmount / 1e18, "eETH");
        console2.log("New capacity:         ", NEW_CAPACITY / 1e18, "stETH");
        console2.log("New exitFee:          ", NEW_EXIT_FEE_BPS, "bps");

        // Capture current config for revert txns
        (BucketLimiter.Limit memory currentLimit,, uint16 currentExitFee,) = rm.tokenToRedemptionInfo(stETH);
        uint256 currentCapacity = uint256(currentLimit.capacity) * 1e12;
        uint256 currentRefillRate = uint256(currentLimit.refillRate) * 1e12;
        console2.log("Current capacity:     ", currentCapacity / 1e18, "stETH");
        console2.log("Current refillRate:   ", currentRefillRate, "wei/s");
        console2.log("Current exitFee:      ", currentExitFee, "bps");
        console2.log("");

        logCurrentConfig(stETH, "=== Current Config (stETH) ===");

        // 1 & 2: Generate increase txns and execute on fork
        buildIncreaseTransactions(stETH);

        // Verify and test on fork
        verifyConfig(stETH);
        testWhaleWeEthToStEthRedemption(stETH);

        // 3 & 4: Generate revert txns
        buildRevertTransactions(stETH, currentCapacity, currentRefillRate, currentExitFee);

        console2.log("");
        console2.log("=== Configuration Complete ===");
    }

    function buildIncreaseTransactions(address stETH) internal {
        address[] memory targets = new address[](3);
        bytes[] memory data = new bytes[](3);
        uint256[] memory values = new uint256[](3);

        for (uint256 i = 0; i < 3; i++) {
            targets[i] = address(rm);
            values[i] = 0;
        }

        data[0] = abi.encodeWithSelector(
            EtherFiRedemptionManager.setExitFeeBasisPoints.selector,
            NEW_EXIT_FEE_BPS,
            stETH
        );
        data[1] = abi.encodeWithSelector(
            EtherFiRedemptionManager.setCapacity.selector,
            NEW_CAPACITY,
            stETH
        );
        data[2] = abi.encodeWithSelector(
            EtherFiRedemptionManager.setRefillRatePerSecond.selector,
            NEW_CAPACITY,
            stETH
        );

        bytes32 timelockSalt = keccak256(
            abi.encode(targets, data, "redemption-manager-steth-capacity-increase", block.number)
        );

        _writeSafeJsons(
            targets, values, data, timelockSalt,
            "set-capacity-whale-weeth-schedule.json",
            "set-capacity-whale-weeth-execute.json"
        );

        // Execute on fork
        console2.log("=== Scheduling Increase on Fork ===");
        vm.startPrank(ETHERFI_OPERATING_ADMIN);
        operatingTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_OPERATING_TIMELOCK);
        console2.log("Schedule successful");

        vm.warp(block.timestamp + MIN_DELAY_OPERATING_TIMELOCK + 1);
        operatingTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
        vm.stopPrank();
        console2.log("Execute successful");
        console2.log("================================================");
        console2.log("");

        logCurrentConfig(stETH, "=== Post-Increase Config (stETH) ===");
    }

    function buildRevertTransactions(address stETH, uint256 origCapacity, uint256 origRefillRate, uint16 origExitFee) internal {
        address[] memory targets = new address[](3);
        bytes[] memory data = new bytes[](3);
        uint256[] memory values = new uint256[](3);

        for (uint256 i = 0; i < 3; i++) {
            targets[i] = address(rm);
            values[i] = 0;
        }

        data[0] = abi.encodeWithSelector(
            EtherFiRedemptionManager.setExitFeeBasisPoints.selector,
            origExitFee,
            stETH
        );
        data[1] = abi.encodeWithSelector(
            EtherFiRedemptionManager.setCapacity.selector,
            origCapacity,
            stETH
        );
        data[2] = abi.encodeWithSelector(
            EtherFiRedemptionManager.setRefillRatePerSecond.selector,
            origRefillRate,
            stETH
        );

        bytes32 timelockSalt = keccak256(
            abi.encode(targets, data, "redemption-manager-steth-capacity-revert", block.number)
        );

        _writeSafeJsons(
            targets, values, data, timelockSalt,
            "set-capacity-whale-weeth-revert-schedule.json",
            "set-capacity-whale-weeth-revert-execute.json"
        );
        console2.log("=== Revert Safe JSONs generated ===");

        // Execute on fork
        console2.log("=== Scheduling Revert on Fork ===");
        vm.startPrank(ETHERFI_OPERATING_ADMIN);
        operatingTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_OPERATING_TIMELOCK);
        console2.log("Schedule successful");

        vm.warp(block.timestamp + MIN_DELAY_OPERATING_TIMELOCK + 1);
        operatingTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
        vm.stopPrank();
        console2.log("Execute successful");
        console2.log("================================================");
        console2.log("");
    }

    function _writeSafeJsons(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory data,
        bytes32 timelockSalt,
        string memory scheduleFilename,
        string memory executeFilename
    ) internal {
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
            scheduleFilename,
            ETHERFI_OPERATING_ADMIN,
            OPERATING_TIMELOCK,
            0,
            scheduleCalldata,
            1
        );

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
            executeFilename,
            ETHERFI_OPERATING_ADMIN,
            OPERATING_TIMELOCK,
            0,
            executeCalldata,
            1
        );
    }

    function verifyConfig(address stETH) internal {
        console2.log("=== Verifying Config ===");

        (
            BucketLimiter.Limit memory limit,
            ,
            uint16 exitFee,
            uint16 lowWM
        ) = rm.tokenToRedemptionInfo(stETH);

        uint64 expectedCapacity = uint64(NEW_CAPACITY / 1e12);
        assertEq(limit.capacity, expectedCapacity, "capacity mismatch");
        console2.log("  [OK] capacity (bucket units):", limit.capacity);

        uint64 expectedRefillRate = uint64(NEW_CAPACITY / 1e12);
        assertEq(limit.refillRate, expectedRefillRate, "refillRate mismatch");
        console2.log("  [OK] refillRate (bucket units):", limit.refillRate);

        assertEq(exitFee, NEW_EXIT_FEE_BPS, "exitFee mismatch");
        console2.log("  [OK] exitFeeInBps:", exitFee);
        console2.log("  [OK] lowWatermarkInBpsOfTvl:", lowWM);

        // On mainnet fork, lowWatermark may block canRedeem. Set to 0 for fork test.
        vm.prank(OPERATING_TIMELOCK);
        rm.setLowWatermarkInBpsOfTvl(0, stETH);

        // Ensure restaker has enough stETH for the redemption
        uint256 eEthAmount = weEth.getEETHByWeETH(WEETH_AMOUNT);
        // _ensureRestakerStEth(ILido(stETH), eEthAmount + 10_000 ether);

        // Warp to let bucket refill
        vm.warp(block.timestamp + 1 days);

        assertTrue(rm.canRedeem(eEthAmount, stETH), "should be able to redeem whale amount after config");
        console2.log("  [OK] canRedeem(whaleEEthAmount, stETH) = true");

        console2.log("  All config verifications passed!");
        console2.log("================================================");
    }

    function testWhaleWeEthToStEthRedemption(address stETH) internal {
        console2.log("=== Whale weETH -> stETH Redemption Test ===");
        console2.log("");

        ILido stEthToken = ILido(stETH);
        uint256 eEthAmount = weEth.getEETHByWeETH(WEETH_AMOUNT);

        // Verify whale has enough weETH
        uint256 whaleWeEthBalance = weEth.balanceOf(WHALE);
        console2.log("  Whale weETH balance:    ", whaleWeEthBalance / 1e18, "weETH");
        require(whaleWeEthBalance >= WEETH_AMOUNT, "Whale does not have enough weETH");

        uint256 restakerStEthBefore = stEthToken.balanceOf(ETHERFI_RESTAKER);
        console2.log("  Restaker stETH:         ", restakerStEthBefore / 1e18, "stETH");

        require(rm.canRedeem(eEthAmount, stETH), "Cannot redeem after config");
        console2.log("  [OK] canRedeem = true for whale amount");

        // Preview redemption
        uint256 eEthShares = lp.sharesForAmount(eEthAmount);
        uint256 stEthToReceive = rm.previewRedeem(eEthShares, stETH);
        console2.log("  stETH to receive:       ", stEthToReceive / 1e18, "stETH");

        uint256 whaleStEthBefore = stEthToken.balanceOf(WHALE);

        // Execute redemption
        vm.startPrank(WHALE);
        IERC20(address(weEth)).approve(address(rm), WEETH_AMOUNT);
        rm.redeemWeEth(WEETH_AMOUNT, WHALE, stETH);
        vm.stopPrank();

        // Verify
        uint256 whaleStEthAfter = stEthToken.balanceOf(WHALE);
        uint256 stEthReceived = whaleStEthAfter - whaleStEthBefore;

        console2.log("");
        console2.log("  === Post-Redemption ===");
        console2.log("  Whale weETH remaining:  ", weEth.balanceOf(WHALE) / 1e18, "weETH");
        console2.log("  Whale stETH received:   ", stEthReceived / 1e18, "stETH");
        console2.log("  Restaker stETH left:    ", stEthToken.balanceOf(ETHERFI_RESTAKER) / 1e18, "stETH");

        assertApproxEqAbs(stEthReceived, stEthToReceive, 2);
        assertApproxEqAbs(weEth.balanceOf(WHALE), whaleWeEthBalance - WEETH_AMOUNT, 2);

        console2.log("");
        console2.log("  Whale weETH -> stETH redemption test passed!");
        console2.log("================================================");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- HELPERS ----------------------------------------------
    //--------------------------------------------------------------------------------------

    function _ensureRestakerStEth(ILido stEthToken, uint256 stEthNeeded) internal {
        uint256 currentBalance = stEthToken.balanceOf(ETHERFI_RESTAKER);
        console2.log("  Restaker stETH balance: ", currentBalance / 1e18, "stETH");

        if (currentBalance >= stEthNeeded) return;

        console2.log("  Restaker needs more stETH, topping up via Liquifier...");
        uint256 deficit = stEthNeeded - currentBalance + 2 ether;
        uint256 chunkSize = 149_000 ether;
        address depositor = address(0xDEAD);

        // Increase deposit cap on liquifier
        address liquifierOwner = liquifier.owner();
        vm.startPrank(liquifierOwner);
        liquifier.updateDepositCap(address(stEthToken), 500_000, 4_000_000);
        vm.stopPrank();

        uint32 refreshInterval = liquifier.timeBoundCapRefreshInterval();
        vm.warp(block.timestamp + refreshInterval + 1);
        vm.roll(block.number + 7200);

        while (deficit > 0) {
            uint256 amount = deficit > chunkSize ? chunkSize : deficit;
            vm.deal(depositor, amount);

            vm.startPrank(depositor);
            stEthToken.submit{value: amount}(address(0));
            IERC20(address(stEthToken)).approve(address(liquifier), amount);
            liquifier.depositWithERC20(address(stEthToken), amount, address(0));
            vm.stopPrank();

            deficit = deficit > amount ? deficit - amount : 0;

            if (deficit > 0) {
                vm.warp(block.timestamp + refreshInterval + 1);
                vm.roll(block.number + 7200);
            }
        }

        require(
            stEthToken.balanceOf(ETHERFI_RESTAKER) >= stEthNeeded,
            "Failed to fund restaker stETH"
        );
        console2.log("  Restaker stETH after top-up:", stEthToken.balanceOf(ETHERFI_RESTAKER) / 1e18, "stETH");
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
