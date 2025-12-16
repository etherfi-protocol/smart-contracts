// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../../../lib/forge-std/src/Script.sol";
import "../../../lib/forge-std/src/console2.sol";
import "../../utils/utils.sol";
import "../../../src/LiquidityPool.sol";
import "../../../src/EtherFiTimelock.sol";

/**
 * @title Set LiquidityPool Validator Size (via Operating Timelock)
 * @notice Schedules + executes `LiquidityPool.setValidatorSizeWei()` via `OPERATING_TIMELOCK`
 *
 * Usage (fork):
 *   forge script script/el-exits/val-consolidations/setValidatorSize.s.sol:SetValidatorSizeWei \
 *     --fork-url $MAINNET_RPC_URL -vvvv
 */
contract SetValidatorSizeWei is Script, Utils {
    LiquidityPool internal constant _LIQUIDITY_POOL_INSTANCE = LiquidityPool(payable(LIQUIDITY_POOL));
    EtherFiTimelock internal constant _ETHERFI_OPERATING_TIMELOCK = EtherFiTimelock(payable(OPERATING_TIMELOCK));

    uint256 internal constant _DEFAULT_VALIDATOR_SIZE_WEI = 2001 ether;

    function run() external {
        console2.log("=== SET VALIDATOR SIZE (OPERATING TIMELOCK) ===");
        console2.log("LiquidityPool:", address(_LIQUIDITY_POOL_INSTANCE));
        console2.log("OperatingTimelock:", address(_ETHERFI_OPERATING_TIMELOCK));
        console2.log("New validatorSizeWei:", _DEFAULT_VALIDATOR_SIZE_WEI);
        console2.log("");

        _executeTimelockBatch(
            address(_LIQUIDITY_POOL_INSTANCE),
            0,
            abi.encodeWithSelector(_LIQUIDITY_POOL_INSTANCE.setValidatorSizeWei.selector, _DEFAULT_VALIDATOR_SIZE_WEI),
            "LiquidityPool.setValidatorSizeWei"
        );
    }

    function _executeTimelockBatch(
        address target,
        uint256 value,
        bytes memory callData,
        string memory operationName
    ) internal {
        address[] memory targets = new address[](1);
        targets[0] = target;

        uint256[] memory values = new uint256[](1);
        values[0] = value;

        bytes[] memory data = new bytes[](1);
        data[0] = callData;

        bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));

        // Log schedule calldata
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            _ETHERFI_OPERATING_TIMELOCK.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt,
            MIN_DELAY_OPERATING_TIMELOCK
        );
        console2.log("=== Schedule", operationName, "Tx ===");
        console2.logBytes(scheduleCalldata);
        console2.log("================================================");
        console2.log("");

        // Log execute calldata
        bytes memory executeCalldata = abi.encodeWithSelector(
            _ETHERFI_OPERATING_TIMELOCK.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt
        );
        console2.log("=== Execute", operationName, "Tx ===");
        console2.logBytes(executeCalldata);
        console2.log("================================================");
        console2.log("");

        // Schedule (fork/local simulation)
        vm.prank(address(ETHERFI_OPERATING_ADMIN));
        _ETHERFI_OPERATING_TIMELOCK.scheduleBatch(
            targets,
            values,
            data,
            bytes32(0),
            timelockSalt,
            MIN_DELAY_OPERATING_TIMELOCK
        );

        // Execute (after min delay)
        vm.warp(block.timestamp + MIN_DELAY_OPERATING_TIMELOCK + 1);
        vm.prank(address(ETHERFI_OPERATING_ADMIN));
        _ETHERFI_OPERATING_TIMELOCK.executeBatch(targets, values, data, bytes32(0), timelockSalt);
    }
}
