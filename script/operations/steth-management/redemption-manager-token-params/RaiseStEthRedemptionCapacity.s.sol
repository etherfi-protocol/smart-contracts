// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {Utils} from "../../../utils/utils.sol";
import {EtherFiRedemptionManager} from "../../../../src/EtherFiRedemptionManager.sol";
import {EtherFiTimelock} from "../../../../src/EtherFiTimelock.sol";
import {ILido} from "../../../../src/interfaces/ILiquifier.sol";
import {IWeETH} from "../../../../src/interfaces/IWeETH.sol";
import {ILiquidityPool} from "../../../../src/interfaces/ILiquidityPool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "lib/BucketLimiter.sol";

// Raise stETH redemption capacity to 80k and pre-schedule a revert back
// to the current config.
//
// Rationale: a 60k weETH redemption equates to ~65,583 eETH. 80k stETH
// capacity gives ~14.4k headroom. setRemaining is not exposed, so
// refillRate = capacity is used to fully fill the bucket within 1 second.
//
// Role wiring:
//   - setCapacity / setRefillRatePerSecond / setExitFeeBasisPoints require
//     ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE, held by OPERATING_TIMELOCK.
//     Batched through timelock.scheduleBatch + executeBatch.
//     Delay = MIN_DELAY_OPERATING_TIMELOCK (2 days).
//
// Output (3 Safe JSONs, all signed by ETHERFI_OPERATING_ADMIN):
//   1. raise-steth-redemption-setup.json
//        Batch of 2 inner txns:
//          a. OP_TIMELOCK.scheduleBatch(increase)
//          b. OP_TIMELOCK.scheduleBatch(revert)
//        Both scheduled ops sit in the timelock queue simultaneously.
//   2. raise-steth-redemption-execute-increase.json
//        OP_TIMELOCK.executeBatch(increase) — signable after 2-day delay.
//   3. raise-steth-redemption-execute-revert.json
//        OP_TIMELOCK.executeBatch(revert)   — signable once the burst is done
//        (also after 2-day delay from the setup tx).
//
//   forge script script/operations/steth-management/redemption-manager-token-params/RaiseStEthRedemptionCapacity.s.sol --fork-url $MAINNET_RPC_URL -vvvv
contract RaiseStEthRedemptionCapacity is Script, Utils, Test {
    EtherFiRedemptionManager constant RM =
        EtherFiRedemptionManager(payable(ETHERFI_REDEMPTION_MANAGER));
    EtherFiTimelock constant OP_TIMELOCK =
        EtherFiTimelock(payable(OPERATING_TIMELOCK));

    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    // 80k stETH — covers 60k weETH (~65.6k eETH) redemption with headroom
    uint256 constant NEW_CAPACITY = 80_000 ether;
    // Equal to capacity so the bucket fully refills within 1 second of execute
    uint256 constant NEW_REFILL_RATE = 80_000 ether;
    uint16 constant NEW_EXIT_FEE_BPS = 0;

    string constant OUTPUT_DIR =
        "script/operations/steth-management/redemption-manager-token-params";

    struct IncreaseBatch {
        address[] targets;
        uint256[] values;
        bytes[] data;
        bytes32 salt;
    }

    struct RevertBatch {
        address[] targets;
        uint256[] values;
        bytes[] data;
        bytes32 salt;
        uint256 origCapacity;
        uint256 origRefillRate;
        uint16 origExitFee;
    }

    function run() external {
        console2.log("====================================================");
        console2.log("=== Raise stETH Redemption Capacity to 80k");
        console2.log("====================================================");
        console2.log("");

        _logCurrentConfig("=== Before ===");

        IncreaseBatch memory inc = _buildIncreaseBatch();
        RevertBatch memory rev = _buildRevertBatch();

        _writeSetupJson(inc, rev);
        _writeExecuteJson(
            "raise-steth-redemption-execute-increase.json",
            inc.targets, inc.values, inc.data, inc.salt
        );
        _writeExecuteJson(
            "raise-steth-redemption-execute-revert.json",
            rev.targets, rev.values, rev.data, rev.salt
        );

        // --- Fork simulation ---
        _simulateSetup(inc, rev);
        _simulateExecuteIncrease(inc);
        _logCurrentConfig("=== After (increase) ===");
        _verifyIncrease();

        _testInstantRedemption();

        _simulateExecuteRevert(rev);
        _logCurrentConfig("=== After (revert) ===");
        _verifyRevert(rev);
    }

    // ------------------------------------------------------------------
    // Batch builders
    // ------------------------------------------------------------------

    function _buildIncreaseBatch() internal view returns (IncreaseBatch memory b) {
        b.targets = new address[](3);
        b.values = new uint256[](3);
        b.data = new bytes[](3);

        for (uint256 i = 0; i < 3; i++) {
            b.targets[i] = address(RM);
            b.values[i] = 0;
        }
        b.data[0] = abi.encodeWithSelector(
            EtherFiRedemptionManager.setCapacity.selector, NEW_CAPACITY, STETH
        );
        b.data[1] = abi.encodeWithSelector(
            EtherFiRedemptionManager.setRefillRatePerSecond.selector, NEW_REFILL_RATE, STETH
        );
        b.data[2] = abi.encodeWithSelector(
            EtherFiRedemptionManager.setExitFeeBasisPoints.selector, NEW_EXIT_FEE_BPS, STETH
        );
        b.salt = keccak256(
            abi.encode(b.targets, b.data, "raise-steth-redemption-capacity", block.number)
        );
    }

    function _buildRevertBatch() internal view returns (RevertBatch memory b) {
        (BucketLimiter.Limit memory origLimit,, uint16 origExitFee,) =
            RM.tokenToRedemptionInfo(STETH);
        b.origCapacity = uint256(origLimit.capacity) * 1e12;
        b.origRefillRate = uint256(origLimit.refillRate) * 1e12;
        b.origExitFee = origExitFee;

        b.targets = new address[](3);
        b.values = new uint256[](3);
        b.data = new bytes[](3);

        for (uint256 i = 0; i < 3; i++) {
            b.targets[i] = address(RM);
            b.values[i] = 0;
        }
        b.data[0] = abi.encodeWithSelector(
            EtherFiRedemptionManager.setCapacity.selector, b.origCapacity, STETH
        );
        b.data[1] = abi.encodeWithSelector(
            EtherFiRedemptionManager.setRefillRatePerSecond.selector, b.origRefillRate, STETH
        );
        b.data[2] = abi.encodeWithSelector(
            EtherFiRedemptionManager.setExitFeeBasisPoints.selector, b.origExitFee, STETH
        );
        b.salt = keccak256(
            abi.encode(b.targets, b.data, "revert-steth-redemption-capacity", block.number)
        );
    }

    // ------------------------------------------------------------------
    // Safe JSON writers
    // ------------------------------------------------------------------

    // JSON 1: schedule(increase) + schedule(revert), in one Safe batch
    function _writeSetupJson(IncreaseBatch memory inc, RevertBatch memory rev) internal {
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory data = new bytes[](2);

        targets[0] = address(OP_TIMELOCK);
        values[0] = 0;
        data[0] = abi.encodeWithSelector(
            OP_TIMELOCK.scheduleBatch.selector,
            inc.targets, inc.values, inc.data,
            bytes32(0), inc.salt, MIN_DELAY_OPERATING_TIMELOCK
        );

        targets[1] = address(OP_TIMELOCK);
        values[1] = 0;
        data[1] = abi.encodeWithSelector(
            OP_TIMELOCK.scheduleBatch.selector,
            rev.targets, rev.values, rev.data,
            bytes32(0), rev.salt, MIN_DELAY_OPERATING_TIMELOCK
        );

        writeSafeJson(
            OUTPUT_DIR,
            "raise-steth-redemption-setup.json",
            ETHERFI_OPERATING_ADMIN,
            targets,
            values,
            data,
            1
        );
    }

    // JSON 2 / 3: single timelock.executeBatch call
    function _writeExecuteJson(
        string memory filename,
        address[] memory innerTargets,
        uint256[] memory innerValues,
        bytes[] memory innerData,
        bytes32 salt
    ) internal {
        bytes memory executeCalldata = abi.encodeWithSelector(
            OP_TIMELOCK.executeBatch.selector,
            innerTargets, innerValues, innerData,
            bytes32(0), salt
        );
        writeSafeJson(
            OUTPUT_DIR,
            filename,
            ETHERFI_OPERATING_ADMIN,
            address(OP_TIMELOCK),
            0,
            executeCalldata,
            1
        );
    }

    // ------------------------------------------------------------------
    // Fork simulation
    // ------------------------------------------------------------------

    function _simulateSetup(IncreaseBatch memory inc, RevertBatch memory rev) internal {
        console2.log("=== Simulating setup Safe batch on fork ===");
        vm.startPrank(ETHERFI_OPERATING_ADMIN);
        OP_TIMELOCK.scheduleBatch(
            inc.targets, inc.values, inc.data, bytes32(0), inc.salt, MIN_DELAY_OPERATING_TIMELOCK
        );
        OP_TIMELOCK.scheduleBatch(
            rev.targets, rev.values, rev.data, bytes32(0), rev.salt, MIN_DELAY_OPERATING_TIMELOCK
        );
        vm.stopPrank();
        console2.log("Setup (2 schedules) successful");
        console2.log("");
    }

    function _simulateExecuteIncrease(IncreaseBatch memory inc) internal {
        console2.log("=== Warping 2 days and executing increase ===");
        vm.warp(block.timestamp + MIN_DELAY_OPERATING_TIMELOCK + 1);
        vm.prank(ETHERFI_OPERATING_ADMIN);
        OP_TIMELOCK.executeBatch(inc.targets, inc.values, inc.data, bytes32(0), inc.salt);
        console2.log("Increase executed");

        // Warp 10s so the bucket refills in-memory with the NEW refillRate.
        // (Storage `remaining` won't change until a real redeem consumes.)
        vm.warp(block.timestamp + 10);
        console2.log("");
    }

    function _simulateExecuteRevert(RevertBatch memory rev) internal {
        console2.log("=== Executing revert ===");
        // Revert was scheduled at the same time as the increase, so its
        // timelock delay has already elapsed.
        vm.prank(ETHERFI_OPERATING_ADMIN);
        OP_TIMELOCK.executeBatch(rev.targets, rev.values, rev.data, bytes32(0), rev.salt);
        console2.log("Revert executed");
        console2.log("");
    }

    // ------------------------------------------------------------------
    // Verification
    // ------------------------------------------------------------------

    function _verifyIncrease() internal {
        (BucketLimiter.Limit memory limit,, uint16 exitFee,) = RM.tokenToRedemptionInfo(STETH);
        uint64 expectedBucketUnit = uint64(NEW_CAPACITY / 1e12);

        assertEq(limit.capacity, expectedBucketUnit, "capacity mismatch");
        assertEq(limit.refillRate, expectedBucketUnit, "refillRate mismatch");
        assertEq(exitFee, NEW_EXIT_FEE_BPS, "exitFee mismatch");
        assertFalse(RM.paused(), "manager should be unpaused");

        // Fund the Restaker with stETH via Lido.submit so balanceOf() is real.
        // forge's deal() doesn't work for rebasing tokens (Lido computes
        // balance from shares mapping, not from the ERC20 balance slot).
        uint256 stEthToFund = 80_000 ether;
        _fundRestakerWithStEth(stEthToFund);

        // canRedeem also checks lowWatermark; zero for fork sanity check.
        vm.prank(OPERATING_TIMELOCK);
        RM.setLowWatermarkInBpsOfTvl(0, STETH);

        uint256 eEthFor60kWeeth = 65_583 ether;
        assertTrue(
            RM.canRedeem(eEthFor60kWeeth, STETH),
            "should be able to redeem ~65.6k eETH worth after increase"
        );
        console2.log("canRedeem(65_583 eETH, stETH) = true");
    }

    function _fundRestakerWithStEth(uint256 amount) internal {
        ILido lido = ILido(STETH);
        uint256 before_ = IERC20(STETH).balanceOf(ETHERFI_RESTAKER);

        address depositor = address(0xDEAD);
        vm.deal(depositor, amount);

        vm.startPrank(depositor);
        lido.submit{value: amount}(address(0));
        // stETH leaves 1-2 wei rounding dust; transfer what we actually got.
        uint256 depositorBal = IERC20(STETH).balanceOf(depositor);
        IERC20(STETH).transfer(ETHERFI_RESTAKER, depositorBal);
        vm.stopPrank();

        uint256 after_ = IERC20(STETH).balanceOf(ETHERFI_RESTAKER);
        console2.log("Restaker stETH before:", before_ / 1e18);
        console2.log("Restaker stETH after: ", after_ / 1e18);
    }

    // Simulate a real instant redemption of weETH -> stETH from a funded
    // test address. This proves the full path works end-to-end: bucket
    // consume, fee accounting, Restaker stETH transfer.
    function _testInstantRedemption() internal {
        IWeETH weEth = IWeETH(WEETH);
        ILiquidityPool lp = ILiquidityPool(payable(LIQUIDITY_POOL));

        address redeemer = address(0xBEEF);
        uint256 weEthAmount = 60_000 ether;

        // weETH is a plain ERC20 wrapper — deal works here (unlike stETH).
        deal(WEETH, redeemer, weEthAmount);
        assertEq(IERC20(WEETH).balanceOf(redeemer), weEthAmount, "deal weETH failed");

        uint256 eEthAmount = weEth.getEETHByWeETH(weEthAmount);
        uint256 shares = lp.sharesForAmount(eEthAmount);
        uint256 previewStEth = RM.previewRedeem(shares, STETH);

        uint256 restakerStEthBefore = IERC20(STETH).balanceOf(ETHERFI_RESTAKER);
        uint256 redeemerStEthBefore = IERC20(STETH).balanceOf(redeemer);

        console2.log("=== Instant Redemption Test (weETH -> stETH) ===");
        console2.log("  redeemer weETH in:      ", weEthAmount / 1e18);
        console2.log("  eETH equivalent:        ", eEthAmount / 1e18);
        console2.log("  previewRedeem stETH out:", previewStEth / 1e18);

        vm.startPrank(redeemer);
        IERC20(WEETH).approve(address(RM), weEthAmount);
        RM.redeemWeEth(weEthAmount, redeemer, STETH);
        vm.stopPrank();

        uint256 stEthReceived =
            IERC20(STETH).balanceOf(redeemer) - redeemerStEthBefore;
        uint256 restakerDelta =
            restakerStEthBefore - IERC20(STETH).balanceOf(ETHERFI_RESTAKER);

        console2.log("  redeemer stETH received:", stEthReceived / 1e18);
        console2.log("  restaker stETH drained: ", restakerDelta / 1e18);
        console2.log("  redeemer weETH left:    ", IERC20(WEETH).balanceOf(redeemer) / 1e18);

        assertApproxEqAbs(stEthReceived, previewStEth, 2, "stETH received vs preview");
        assertEq(IERC20(WEETH).balanceOf(redeemer), 0, "redeemer weETH fully consumed");
        console2.log("Instant redemption test passed.");
        console2.log("");
    }

    function _verifyRevert(RevertBatch memory rev) internal view {
        (BucketLimiter.Limit memory limit,, uint16 exitFee,) = RM.tokenToRedemptionInfo(STETH);
        uint64 expectedCapUnit = uint64(rev.origCapacity / 1e12);
        uint64 expectedRefillUnit = uint64(rev.origRefillRate / 1e12);

        assertEq(limit.capacity, expectedCapUnit, "revert: capacity mismatch");
        assertEq(limit.refillRate, expectedRefillUnit, "revert: refillRate mismatch");
        assertEq(exitFee, rev.origExitFee, "revert: exitFee mismatch");

        console2.log("Revert restored original capacity / refillRate / exitFee.");
    }

    // ------------------------------------------------------------------
    // Logging
    // ------------------------------------------------------------------

    function _logCurrentConfig(string memory label) internal view {
        (BucketLimiter.Limit memory limit,, uint16 exitFee, uint16 lowWM) =
            RM.tokenToRedemptionInfo(STETH);
        uint256 cap = uint256(limit.capacity) * 1e12;
        uint256 rem = uint256(limit.remaining) * 1e12;
        uint256 refill = uint256(limit.refillRate) * 1e12;

        // BucketLimiter only updates `remaining` in storage on consume().
        // Compute the effective remaining after applying the pending refill.
        uint256 effectiveRem = _effectiveRemaining(limit);

        console2.log(label);
        console2.log("  paused:                      ", RM.paused());
        console2.log("  capacity (stETH):            ", cap / 1e18);
        console2.log("  remaining stored (stETH):    ", rem / 1e18);
        console2.log("  remaining effective (stETH): ", effectiveRem / 1e18);
        console2.log("  refillRate (wei/s):          ", refill);
        console2.log("  exitFeeInBps:                ", exitFee);
        console2.log("  lowWatermarkInBpsOfTvl:      ", lowWM);
        console2.log("  instantLiquidity (stETH):    ", RM.getInstantLiquidityAmount(STETH) / 1e18);
        console2.log("");
    }

    // Mirrors BucketLimiter._refill so we can show the post-refill remaining
    // without calling the external library function.
    function _effectiveRemaining(BucketLimiter.Limit memory limit)
        internal
        view
        returns (uint256)
    {
        if (block.timestamp <= limit.lastRefill) {
            return uint256(limit.remaining) * 1e12;
        }
        uint256 delta = block.timestamp - limit.lastRefill;
        uint256 tokens = delta * uint256(limit.refillRate);
        uint256 newRem = uint256(limit.remaining) + tokens;
        if (newRem > limit.capacity) newRem = limit.capacity;
        return newRem * 1e12;
    }
}
