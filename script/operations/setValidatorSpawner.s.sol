// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {EtherFiTimelock} from "../../src/EtherFiTimelock.sol";
import {LiquidityPool} from "../../src/LiquidityPool.sol";
import {Deployed} from "../deploys/Deployed.s.sol";
import {Utils} from "../utils/utils.sol";

/// @title SetValidatorSpawner
/// @notice Script to register a validator spawner via Operating Timelock
/// @dev Run: forge script script/operations/setValidatorSpawner.s.sol:SetValidatorSpawnerScript --fork-url $MAINNET_RPC_URL -vvvv
contract SetValidatorSpawnerScript is Script, Deployed, Utils {
    EtherFiTimelock constant etherFiOperatingTimelock = EtherFiTimelock(payable(OPERATING_TIMELOCK));
    LiquidityPool constant liquidityPool = LiquidityPool(payable(LIQUIDITY_POOL));

    address constant VALIDATOR_SPAWNER = 0xA8304775e435146650A7Ae65aa39B2a38F0152AE;

    function run() public {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        uint256[] memory values = new uint256[](1);

        // Register validator spawner
        targets[0] = LIQUIDITY_POOL;
        data[0] = abi.encodeWithSelector(
            LiquidityPool.registerValidatorSpawner.selector,
            VALIDATOR_SPAWNER
        );
        values[0] = 0;

        bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));

        console2.log("=== SET VALIDATOR SPAWNER ===");
        console2.log("Target:", targets[0]);
        console2.log("Validator Spawner:", VALIDATOR_SPAWNER);
        console2.log("Operating Timelock:", address(etherFiOperatingTimelock));
        console2.log("Min Delay:", MIN_DELAY_OPERATING_TIMELOCK, "seconds (8 hours)");
        console2.log("");

        // Generate schedule calldata
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherFiOperatingTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt,
            MIN_DELAY_OPERATING_TIMELOCK
        );

        console2.log("=== SCHEDULE CALLDATA ===");
        console2.log("Call to:", address(etherFiOperatingTimelock));
        console2.logBytes(scheduleCalldata);
        console2.log("");

        // Generate execute calldata
        bytes memory executeCalldata = abi.encodeWithSelector(
            etherFiOperatingTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt
        );

        console2.log("=== EXECUTE CALLDATA ===");
        console2.log("Call to:", address(etherFiOperatingTimelock));
        console2.logBytes(executeCalldata);
        console2.log("");

        console2.log("=== INNER TX DATA ===");
        console2.log("Target:", targets[0]);
        console2.logBytes(data[0]);
        console2.log("");

        console2.log("=== TIMELOCK SALT ===");
        console2.logBytes32(timelockSalt);
        console2.log("");

        runFork();
    }

    /// @notice Simulate the full flow on a fork
    function runFork() public {
        string memory forkUrl = vm.envString("MAINNET_RPC_URL");
        vm.selectFork(vm.createFork(forkUrl));

        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        uint256[] memory values = new uint256[](1);

        targets[0] = LIQUIDITY_POOL;
        data[0] = abi.encodeWithSelector(
            LiquidityPool.registerValidatorSpawner.selector,
            VALIDATOR_SPAWNER
        );
        values[0] = 0;

        bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));

        console2.log("=== SIMULATING ON FORK ===");
        console2.log("Validator Spawner before:", liquidityPool.validatorSpawner(VALIDATOR_SPAWNER) ? "registered" : "not registered");

        // Schedule
        vm.startPrank(ETHERFI_OPERATING_ADMIN);
        etherFiOperatingTimelock.scheduleBatch(
            targets,
            values,
            data,
            bytes32(0),
            timelockSalt,
            MIN_DELAY_OPERATING_TIMELOCK
        );
        console2.log("Scheduled successfully");

        // Fast forward time
        vm.warp(block.timestamp + MIN_DELAY_OPERATING_TIMELOCK + 1);
        console2.log("Time warped past delay");

        // Execute
        etherFiOperatingTimelock.executeBatch(
            targets,
            values,
            data,
            bytes32(0),
            timelockSalt
        );
        vm.stopPrank();

        console2.log("Executed successfully");
        console2.log("Validator Spawner after:", liquidityPool.validatorSpawner(VALIDATOR_SPAWNER) ? "registered" : "not registered");
        console2.log("");
        console2.log("[OK] Validator spawner registered successfully");
    }
}
