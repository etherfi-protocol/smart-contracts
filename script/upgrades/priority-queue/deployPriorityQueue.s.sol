// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import {LiquidityPool} from "../../../src/LiquidityPool.sol";
import {PriorityWithdrawalQueue} from "../../../src/PriorityWithdrawalQueue.sol";
import {UUPSProxy} from "../../../src/UUPSProxy.sol";
import {Utils, ICreate2Factory} from "../../utils/utils.sol";

contract DeployPriorityQueue is Script, Utils {
    ICreate2Factory constant factory = ICreate2Factory(0x356d1B83970CeF2018F2c9337cDdb67dff5AEF99);

    address priorityWithdrawalQueueImpl;
    address priorityWithdrawalQueueProxy;
    address liquidityPoolImpl;

    bytes32 commitHashSalt = hex"45312df178d6eb8143604e47b7aa9e618779c0de"; // TODO: Update with actual commit hash
    
    // PriorityWithdrawalQueue config
    uint32 constant MIN_DELAY = 1 hours; // TODO: Set appropriate min delay (e.g., 1 hours = 3600)

    /// @notice Dry run to show deployment configuration without actually deploying
    /// @dev Run with --fork-url to compute Create2 addresses: forge script ... --fork-url <RPC_URL>
    function dryRun() public view {
        console2.log("================================================");
        console2.log("============= DRY RUN - CONFIG ============");
        console2.log("================================================");
        console2.log("");

        console2.log("Constructor Args for PriorityWithdrawalQueue:");
        console2.log("  _liquidityPool:", LIQUIDITY_POOL);
        console2.log("  _eETH:", EETH);
        console2.log("  _roleRegistry:", ROLE_REGISTRY);
        console2.log("  _treasury:", TREASURY);
        console2.log("  _minDelay:", MIN_DELAY);
        console2.log("");

        console2.log("Constructor Args for LiquidityPool:");
        console2.log("  _priorityWithdrawalQueue: <computed from Create2>");
        console2.log("");

        console2.log("Salt:", vm.toString(commitHashSalt));
        console2.log("");

        console2.log("To compute exact addresses, run with mainnet fork:");
        console2.log("  forge script script/upgrades/priority-queue/deployPriorityQueue.s.sol:DeployPriorityQueue --sig 'dryRunWithFork()' --fork-url <RPC_URL>");
    }

    /// @notice Dry run with fork to predict all deployment addresses
    function dryRunWithFork() public view {
        console2.log("================================================");
        console2.log("============= DRY RUN - PREDICTIONS ============");
        console2.log("================================================");
        console2.log("");

        // Predict LiquidityPool implementation address
        address predictedProxyAddress = _predictPriorityQueueProxyAddress();
        
        bytes memory lpConstructorArgs = abi.encode(predictedProxyAddress);
        bytes memory lpBytecode = abi.encodePacked(
            type(LiquidityPool).creationCode,
            lpConstructorArgs
        );
        address predictedLpImpl = factory.computeAddress(commitHashSalt, lpBytecode);

        // Predict PriorityWithdrawalQueue implementation address
        bytes memory pwqConstructorArgs = abi.encode(
            LIQUIDITY_POOL,
            EETH,
            ROLE_REGISTRY,
            TREASURY,
            MIN_DELAY
        );
        bytes memory pwqBytecode = abi.encodePacked(
            type(PriorityWithdrawalQueue).creationCode,
            pwqConstructorArgs
        );
        address predictedPwqImpl = factory.computeAddress(commitHashSalt, pwqBytecode);

        console2.log("Predicted Addresses:");
        console2.log("  LiquidityPool Implementation:", predictedLpImpl);
        console2.log("  PriorityWithdrawalQueue Implementation:", predictedPwqImpl);
        console2.log("  PriorityWithdrawalQueue Proxy:", predictedProxyAddress);
        console2.log("");
        console2.log("Constructor Args:");
        console2.log("  LiquidityPool._priorityWithdrawalQueue:", predictedProxyAddress);
        console2.log("  PriorityWithdrawalQueue._liquidityPool:", LIQUIDITY_POOL);
        console2.log("  PriorityWithdrawalQueue._eETH:", EETH);
        console2.log("  PriorityWithdrawalQueue._roleRegistry:", ROLE_REGISTRY);
        console2.log("  PriorityWithdrawalQueue._treasury:", TREASURY);
        console2.log("  PriorityWithdrawalQueue._minDelay:", MIN_DELAY);
        console2.log("");
        console2.log("Salt:", vm.toString(commitHashSalt));
    }

    function run() public {
        console2.log("================================================");
        console2.log("======== Deploying Priority Queue & LP =========");
        console2.log("================================================");
        console2.log("");

        // Step 1: Predict PriorityWithdrawalQueue proxy address
        address predictedProxyAddress = _predictPriorityQueueProxyAddress();
        console2.log("Predicted PriorityWithdrawalQueue proxy:", predictedProxyAddress);

        vm.startBroadcast();

        // Step 2: Deploy LiquidityPool implementation with predicted proxy address
        {
            string memory contractName = "LiquidityPool";
            bytes memory constructorArgs = abi.encode(predictedProxyAddress);
            bytes memory bytecode = abi.encodePacked(
                type(LiquidityPool).creationCode,
                constructorArgs
            );
            liquidityPoolImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, factory);
        }

        // Step 3: Deploy PriorityWithdrawalQueue implementation
        {
            string memory contractName = "PriorityWithdrawalQueue";
            bytes memory constructorArgs = abi.encode(
                LIQUIDITY_POOL,
                EETH,
                ROLE_REGISTRY,
                TREASURY,
                MIN_DELAY
            );
            bytes memory bytecode = abi.encodePacked(
                type(PriorityWithdrawalQueue).creationCode,
                constructorArgs
            );
            priorityWithdrawalQueueImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, factory);
        }

        // Step 4: Deploy PriorityWithdrawalQueue proxy with initialization
        {
            string memory contractName = "UUPSProxy"; // Use actual contract name for artifact lookup
            // Encode initialize() call for proxy deployment
            bytes memory initData = abi.encodeWithSelector(PriorityWithdrawalQueue.initialize.selector);
            bytes memory constructorArgs = abi.encode(priorityWithdrawalQueueImpl, initData);
            bytes memory bytecode = abi.encodePacked(
                type(UUPSProxy).creationCode,
                constructorArgs
            );
            priorityWithdrawalQueueProxy = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, factory);
            
            require(priorityWithdrawalQueueProxy == predictedProxyAddress, "Proxy address mismatch!");
        }

        vm.stopBroadcast();

        // Summary
        console2.log("");
        console2.log("================================================");
        console2.log("============== DEPLOYMENT SUMMARY ==============");
        console2.log("================================================");
        console2.log("LiquidityPool Implementation:", liquidityPoolImpl);
        console2.log("PriorityWithdrawalQueue Implementation:", priorityWithdrawalQueueImpl);
        console2.log("PriorityWithdrawalQueue Proxy:", priorityWithdrawalQueueProxy);
        console2.log("");
        console2.log("NEXT STEPS:");
        console2.log("1. Initialize PriorityWithdrawalQueue proxy");
        console2.log("2. Upgrade LiquidityPool proxy to new implementation");
        console2.log("3. Grant necessary roles in RoleRegistry");
    }

    /// @notice Predict the PriorityWithdrawalQueue proxy address before deployment
    function _predictPriorityQueueProxyAddress() internal view returns (address) {
        // First predict implementation address
        bytes memory implConstructorArgs = abi.encode(
            LIQUIDITY_POOL,
            EETH,
            ROLE_REGISTRY,
            TREASURY,
            MIN_DELAY
        );
        bytes memory implBytecode = abi.encodePacked(
            type(PriorityWithdrawalQueue).creationCode,
            implConstructorArgs
        );
        address predictedImpl = factory.computeAddress(commitHashSalt, implBytecode);

        // Then predict proxy address (with initialization data)
        bytes memory initData = abi.encodeWithSelector(PriorityWithdrawalQueue.initialize.selector);
        bytes memory proxyConstructorArgs = abi.encode(predictedImpl, initData);
        bytes memory proxyBytecode = abi.encodePacked(
            type(UUPSProxy).creationCode,
            proxyConstructorArgs
        );
        return factory.computeAddress(commitHashSalt, proxyBytecode);
    }
}