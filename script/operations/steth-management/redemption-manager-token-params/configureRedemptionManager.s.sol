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
 * @title ConfigureRedemptionManagerForWhaleRedemption
 * @notice Configures the EtherFiRedemptionManager via OPERATING_TIMELOCK to allow
 *         large stETH redemptions, completes the earliest pending EigenLayer withdrawal,
 *         and simulates a whale eETH -> stETH redemption.
 *
 * Transactions (via OPERATING_TIMELOCK):
 *   1. setExitFeeBasisPoints(0, stETH)
 *   2. setCapacity(300_000 ether, stETH)
 *   3. setRefillRatePerSecond(300_000 ether, stETH)
 *
 * Run:
 * source .env && forge script script/operations/steth-management/redemption-manager-token-params/configureRedemptionManager.s.sol --fork-url $MAINNET_RPC_URL -vvvv
 */
contract ConfigureRedemptionManagerForWhaleRedemption is Script, Utils, Test {
    EtherFiRedemptionManager constant rm = EtherFiRedemptionManager(payable(ETHERFI_REDEMPTION_MANAGER));
    EtherFiTimelock constant operatingTimelock = EtherFiTimelock(payable(OPERATING_TIMELOCK));
    ILiquidityPool constant lp = ILiquidityPool(payable(LIQUIDITY_POOL));
    IeETH constant eEth = IeETH(EETH);
    IWeETH constant weEth = IWeETH(WEETH);
    Liquifier constant liquifier = Liquifier(payable(LIQUIFIER));
    EtherFiRestaker constant restaker = EtherFiRestaker(payable(ETHERFI_RESTAKER));

    // stETH redemption config
    uint16 constant exitFeeInBpsStETH = 0;
    uint256 constant capacityStETH = 300_000 ether;
    uint256 constant refillRateStETH = 300_000 ether;

    // Whale test config
    address constant WHALE = 0x7ee29373F075eE1d83b1b93b4fe94ae242Df5178;
    uint256 constant REDEMPTION_AMOUNT_EETH = 280_000 ether;

    function run() external {
        console2.log("====================================================");
        console2.log("=== Configure RedemptionManager for stETH Redemption");
        console2.log("====================================================");
        console2.log("");

        address stETH = address(rm.lido());
        console2.log("stETH address:", stETH);

        logCurrentConfig(stETH, "=== Current Config (stETH) ===");

        buildAndExecuteTransactions(stETH);

        verifyConfig(stETH);

        testWhaleEEthToStEthRedemption(stETH);

        console2.log("");
        console2.log("=== Configuration Complete ===");
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

        bytes32 timelockSalt = keccak256(abi.encode(targets, data, "redemption-manager-steth-config-v1", block.number));

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
            "redemption-manager-config-schedule.json",
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
            "redemption-manager-config-execute.json",
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
        console2.log("");

        logCurrentConfig(stETH, "=== Post-Config (stETH) ===");
    }

    function verifyConfig(address stETH) internal {
        console2.log("=== Verifying Config ===");

        (
            BucketLimiter.Limit memory limit,
            uint16 exitFeeSplit,
            uint16 exitFee,
            uint16 lowWM
        ) = rm.tokenToRedemptionInfo(stETH);

        assertEq(exitFee, exitFeeInBpsStETH, "exitFee mismatch");
        console2.log("  [OK] exitFeeInBps:", exitFee);

        assertEq(lowWM, 0, "lowWatermark should already be 0");
        console2.log("  [OK] lowWatermarkInBpsOfTvl (unchanged):", lowWM);

        uint64 expectedCapacity = uint64(capacityStETH / 1e12);
        assertEq(limit.capacity, expectedCapacity, "capacity mismatch");
        console2.log("  [OK] capacity (bucket units):", limit.capacity);

        uint64 expectedRefillRate = uint64(refillRateStETH / 1e12);
        assertEq(limit.refillRate, expectedRefillRate, "refillRate mismatch");
        console2.log("  [OK] refillRate (bucket units):", limit.refillRate);

        // Warp to allow bucket to refill, then verify canRedeem
        vm.warp(block.timestamp + 30 seconds);
        assertTrue(rm.canRedeem(1 ether, stETH), "should be able to redeem 1 stETH after config");
        console2.log("  [OK] canRedeem(1 ether, stETH) = true");

        console2.log("  All config verifications passed!");
        console2.log("================================================");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- WHALE FORK TEST --------------------------------------
    //--------------------------------------------------------------------------------------
    function testWhaleEEthToStEthRedemption(address stETH) internal {
        console2.log("=== Whale eETH -> stETH Redemption Test ===");
        console2.log("");

        ILido stEthToken = ILido(stETH);

        // Complete the earliest pending EigenLayer queued withdrawal to fund restaker
        _completePendingEigenLayerWithdrawals(stETH);

        uint256 restakerBalance = stEthToken.balanceOf(ETHERFI_RESTAKER);
        console2.log("  Restaker stETH after completing withdrawals:", restakerBalance / 1e18, "stETH");

        // If restaker still doesn't have enough, top up via Liquifier as fallback
        if (restakerBalance < REDEMPTION_AMOUNT_EETH + 10 ether) {
            console2.log("  Restaker needs more stETH, topping up via Liquifier...");
            _ensureRestakerStEth(stEthToken, REDEMPTION_AMOUNT_EETH + 10 ether);
        }

        // Mint eETH to whale by depositing ETH into the liquidity pool
        _mintEEthToWhale(REDEMPTION_AMOUNT_EETH);

        uint256 whaleEEthBalance = eEth.balanceOf(WHALE);
        uint256 whaleStEthBefore = stEthToken.balanceOf(WHALE);
        uint256 restakerStEthBefore = stEthToken.balanceOf(ETHERFI_RESTAKER);

        console2.log("  Whale eETH:             ", whaleEEthBalance / 1e18, "eETH");
        console2.log("  Restaker stETH:         ", restakerStEthBefore / 1e18, "stETH");

        // Warp to let the rate limiter bucket refill to capacity
        vm.warp(block.timestamp + 1 days);

        require(rm.canRedeem(REDEMPTION_AMOUNT_EETH, stETH), "Cannot redeem after config");

        // Preview redemption
        uint256 eEthShares = lp.sharesForAmount(REDEMPTION_AMOUNT_EETH);
        uint256 stEthToReceive = rm.previewRedeem(eEthShares, stETH);
        console2.log("  stETH to receive:       ", stEthToReceive / 1e18, "stETH");

        // With fee=0, whale should receive ~full eETH amount
        assertApproxEqAbs(stEthToReceive, REDEMPTION_AMOUNT_EETH, 1 ether);

        // Execute redemption
        vm.startPrank(WHALE);
        IERC20(address(eEth)).approve(address(rm), REDEMPTION_AMOUNT_EETH);
        rm.redeemEEth(REDEMPTION_AMOUNT_EETH, WHALE, stETH);
        vm.stopPrank();

        // Verify
        uint256 whaleStEthAfter = stEthToken.balanceOf(WHALE);
        uint256 restakerStEthAfter = stEthToken.balanceOf(ETHERFI_RESTAKER);

        console2.log("");
        console2.log("  === Post-Redemption ===");
        console2.log("  Whale eETH remaining:   ", eEth.balanceOf(WHALE) / 1e18, "eETH");
        console2.log("  Whale stETH received:   ", (whaleStEthAfter - whaleStEthBefore) / 1e18, "stETH");
        console2.log("  Restaker stETH left:    ", restakerStEthAfter / 1e18, "stETH");

        // Whale burned all requested eETH
        assertApproxEqAbs(eEth.balanceOf(WHALE), whaleEEthBalance - REDEMPTION_AMOUNT_EETH, 2);

        // Whale received stETH matching preview
        assertApproxEqAbs(whaleStEthAfter - whaleStEthBefore, stEthToReceive, 2);

        // Restaker stETH decreased accordingly
        assertApproxEqAbs(restakerStEthBefore - restakerStEthAfter, stEthToReceive, 2);

        console2.log("");
        console2.log("  Whale redemption test passed!");
        console2.log("================================================");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- HELPERS ----------------------------------------------
    //--------------------------------------------------------------------------------------

    function _completePendingEigenLayerWithdrawals(address stETH) internal {
        console2.log("  === Completing Pending EigenLayer Withdrawals ===");

        IDelegationManager delegationManager = restaker.eigenLayerDelegationManager();
        bytes32[] memory allRoots = restaker.pendingWithdrawalRoots();
        console2.log("  Pending withdrawal roots:", allRoots.length);

        if (allRoots.length == 0) {
            console2.log("  No pending withdrawals to complete");
            return;
        }

        // Find the earliest withdrawal (lowest startBlock) — the one expiring soonest
        uint256 earliestIdx = 0;
        uint32 earliestStartBlock = type(uint32).max;
        for (uint256 i = 0; i < allRoots.length; i++) {
            (IDelegationManager.Withdrawal memory w,) = delegationManager.getQueuedWithdrawal(allRoots[i]);
            console2.log("  Root", i, "startBlock:", w.startBlock);
            if (w.startBlock < earliestStartBlock) {
                earliestStartBlock = w.startBlock;
                earliestIdx = i;
            }
        }
        console2.log("  Using root index:", earliestIdx);

        // Warp past the withdrawal delay for the earliest root only
        uint32 delayBlocks = delegationManager.minWithdrawalDelayBlocks();
        uint256 completableAtBlock = uint256(earliestStartBlock) + uint256(delayBlocks);
        vm.roll(completableAtBlock + 1);
        vm.warp(block.timestamp + ((completableAtBlock + 1 - block.number) * 12));

        // Build array for just the earliest withdrawal
        IDelegationManager.Withdrawal[] memory withdrawals = new IDelegationManager.Withdrawal[](1);
        IERC20[][] memory tokens = new IERC20[][](1);

        {
            (IDelegationManager.Withdrawal memory w,) = delegationManager.getQueuedWithdrawal(allRoots[earliestIdx]);
            withdrawals[0] = w;

            tokens[0] = new IERC20[](w.strategies.length);
            for (uint256 j = 0; j < w.strategies.length; j++) {
                tokens[0][j] = w.strategies[j].underlyingToken();
            }
        }

        // Generate Gnosis Safe JSON for completeQueuedWithdrawals
        bytes memory completeCalldata = abi.encodeWithSelector(
            EtherFiRestaker.completeQueuedWithdrawals.selector,
            withdrawals,
            tokens
        );
        writeSafeJson(
            "script/operations/steth-management/redemption-manager-token-params",
            "complete-queued-withdrawals.json",
            ETHERFI_OPERATING_ADMIN,
            ETHERFI_RESTAKER,
            0,
            completeCalldata,
            1
        );

        // Execute on fork for testing
        uint256 stEthBefore = IERC20(stETH).balanceOf(ETHERFI_RESTAKER);

        vm.prank(ETHERFI_OPERATING_ADMIN);
        restaker.completeQueuedWithdrawals(withdrawals, tokens);

        uint256 stEthAfter = IERC20(stETH).balanceOf(ETHERFI_RESTAKER);
        console2.log("  stETH received from withdrawals:", (stEthAfter - stEthBefore) / 1e18, "stETH");
        console2.log("  Remaining pending roots:", restaker.pendingWithdrawalRoots().length);
    }

    function _mintEEthToWhale(uint256 eEthNeeded) internal {
        vm.deal(WHALE, eEthNeeded + 1 ether);

        vm.startPrank(WHALE);
        lp.deposit{value: eEthNeeded + 1 ether}(address(0));
        vm.stopPrank();

        require(eEth.balanceOf(WHALE) >= eEthNeeded, "Failed to mint enough eETH");
    }

    function _ensureRestakerStEth(ILido stEthToken, uint256 stEthNeeded) internal {
        uint256 currentBalance = stEthToken.balanceOf(ETHERFI_RESTAKER);
        if (currentBalance >= stEthNeeded) return;

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
