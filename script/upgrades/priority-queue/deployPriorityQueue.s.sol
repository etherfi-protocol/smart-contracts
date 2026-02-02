// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import {LiquidityPool} from "../../../src/LiquidityPool.sol";
import {PriorityWithdrawalQueue} from "../../../src/PriorityWithdrawalQueue.sol";
import {UUPSProxy} from "../../../src/UUPSProxy.sol";
import {Utils, ICreate2Factory} from "../../utils/utils.sol";
import {EtherFiRedemptionManager} from "../../../src/EtherFiRedemptionManager.sol";

contract DeployPriorityQueue is Script, Utils {
    ICreate2Factory constant factory = ICreate2Factory(0x356d1B83970CeF2018F2c9337cDdb67dff5AEF99);

    address priorityWithdrawalQueueImpl;
    address priorityWithdrawalQueueProxy;
    address liquidityPoolImpl;
    address etherFiRedemptionManagerImpl;
    bytes32 commitHashSalt = hex"45312df178d6eb8143604e47b7aa9e618779c0de"; // TODO: Update with actual commit hash
    
    uint32 constant MIN_DELAY = 1 hours; // TODO: Set appropriate min delay (e.g., 1 hours = 3600)

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

    function run() public {
        console2.log("================================================");
        console2.log("======== Deploying Priority Queue & LP =========");
        console2.log("================================================");
        console2.log("");

        vm.startBroadcast();

        // Step 1: Deploy PriorityWithdrawalQueue implementation
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

        // Step 2: Deploy PriorityWithdrawalQueue proxy with initialization
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
        }

        // Step 3: Deploy EtherFiRedemptionManager implementation
        {
            string memory contractName = "EtherFiRedemptionManager";
            bytes memory constructorArgs = abi.encode(
                LIQUIDITY_POOL,
                EETH,
                WEETH,
                TREASURY,
                ROLE_REGISTRY,
                ETHERFI_RESTAKER,
                priorityWithdrawalQueueProxy
            );
            bytes memory bytecode = abi.encodePacked(
                type(EtherFiRedemptionManager).creationCode,
                constructorArgs
            );
            etherFiRedemptionManagerImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, factory);
        }

        // Step 4: Deploy LiquidityPool implementation with predicted proxy address
        {
            string memory contractName = "LiquidityPool";
            bytes memory constructorArgs = abi.encode(priorityWithdrawalQueueProxy);
            bytes memory bytecode = abi.encodePacked(
                type(LiquidityPool).creationCode,
                constructorArgs
            );
            liquidityPoolImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, factory);
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
        console2.log("EtherFiRedemptionManager Implementation:", etherFiRedemptionManagerImpl);
        console2.log("");
        console2.log("NEXT STEPS:");
        console2.log("1. Initialize PriorityWithdrawalQueue proxy");
        console2.log("2. Upgrade LiquidityPool proxy to new implementation");
        console2.log("3. Upgrade EtherFiRedemptionManager proxy to new implementation");
        console2.log("4. Grant necessary roles in RoleRegistry");
    }
}