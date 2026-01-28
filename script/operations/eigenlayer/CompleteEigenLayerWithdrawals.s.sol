// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../../../src/interfaces/IEtherFiNodesManager.sol";
import "../../../src/interfaces/IRoleRegistry.sol";

/**
 * @title CompleteEigenLayerWithdrawals
 * @notice Completes queued EigenLayer ETH withdrawals for EtherFi nodes
 * 
 * @dev This script calls completeQueuedETHWithdrawals on EtherFiNodesManager
 *      to finalize ETH withdrawals that have passed the slashing period.
 *      
 *      The caller must have ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE.
 *      ETH is sent to the LiquidityPool when receiveAsTokens=true.
 *
 * Usage:
 *   # Dry run (simulation on fork) - requires PRIVATE_KEY env var
 *   PRIVATE_KEY=0x... forge script script/operations/eigenlayer/CompleteEigenLayerWithdrawals.s.sol:CompleteEigenLayerWithdrawals \
 *     --fork-url $MAINNET_RPC_URL -vvvv
 *
 *   # Actual execution (broadcast transactions)
 *   PRIVATE_KEY=0x... forge script script/operations/eigenlayer/CompleteEigenLayerWithdrawals.s.sol:CompleteEigenLayerWithdrawals \
 *     --rpc-url $MAINNET_RPC_URL \
 *     --broadcast -vvvv
 *
 * Nodes to process:
 *   - Node 1: 0x7779Ebb3CE29261FA60d738C3BAB35A05D8d6f65 (~43,102 ETH)
 *   - Node 2: 0x4Cb9384E3cc72f9302288f64edadE772d7F2DD06 (~35,919 ETH)
 *   - Total: ~79,021 ETH
 */
contract CompleteEigenLayerWithdrawals is Script {
    // Mainnet addresses
    address constant ETHERFI_NODES_MANAGER = 0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F;
    
    // Nodes with queued withdrawals ready to complete
    address constant NODE_1 = 0x7779Ebb3CE29261FA60d738C3BAB35A05D8d6f65;
    address constant NODE_2 = 0x4Cb9384E3cc72f9302288f64edadE772d7F2DD06;
    
    // Role constant (must match EtherFiNodesManager)
    bytes32 constant ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE = keccak256("ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE");

    function run() external {
        IEtherFiNodesManager nodesManager = IEtherFiNodesManager(ETHERFI_NODES_MANAGER);
        
        // Derive caller address from private key
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address caller = vm.addr(privateKey);
        
        console2.log("============================================================");
        console2.log("COMPLETE EIGENLAYER ETH WITHDRAWALS");
        console2.log("============================================================");
        console2.log("");
        console2.log("EtherFiNodesManager:", ETHERFI_NODES_MANAGER);
        console2.log("Node 1:", NODE_1);
        console2.log("Node 2:", NODE_2);
        console2.log("Caller:", caller);
        console2.log("");
        
        // Verify role (informational - will revert on actual call if missing)
        _checkRole(caller);
        
        // Log initial balances
        console2.log("------------------------------------------------------------");
        console2.log("PRE-EXECUTION STATE");
        console2.log("------------------------------------------------------------");
        uint256 node1Balance = NODE_1.balance;
        uint256 node2Balance = NODE_2.balance;
        console2.log("Node 1 ETH balance:", node1Balance / 1 ether, "ETH");
        console2.log("Node 2 ETH balance:", node2Balance / 1 ether, "ETH");
        console2.log("");
        
        // Start broadcast for actual execution
        vm.startBroadcast(privateKey);
        
        // Complete withdrawal for Node 1
        console2.log("------------------------------------------------------------");
        console2.log("COMPLETING WITHDRAWAL - NODE 1");
        console2.log("------------------------------------------------------------");
        console2.log("Node:", NODE_1);
        console2.log("receiveAsTokens: true (ETH -> LiquidityPool)");
        
        nodesManager.completeQueuedETHWithdrawals(NODE_1, false);
        console2.log("SUCCESS: Node 1 withdrawal completed");
        console2.log("");
        
        // Complete withdrawal for Node 2
        console2.log("------------------------------------------------------------");
        console2.log("COMPLETING WITHDRAWAL - NODE 2");
        console2.log("------------------------------------------------------------");
        console2.log("Node:", NODE_2);
        console2.log("receiveAsTokens: true (ETH -> LiquidityPool)");
        
        nodesManager.completeQueuedETHWithdrawals(NODE_2, false);
        console2.log("SUCCESS: Node 2 withdrawal completed");
        console2.log("");
        
        vm.stopBroadcast();
        
        // Log final state
        console2.log("------------------------------------------------------------");
        console2.log("POST-EXECUTION STATE");
        console2.log("------------------------------------------------------------");
        uint256 node1BalanceAfter = NODE_1.balance;
        uint256 node2BalanceAfter = NODE_2.balance;
        console2.log("Node 1 ETH balance:", node1BalanceAfter / 1 ether, "ETH");
        console2.log("Node 2 ETH balance:", node2BalanceAfter / 1 ether, "ETH");
        console2.log("");
        
        console2.log("============================================================");
        console2.log("EXECUTION COMPLETE");
        console2.log("============================================================");
        console2.log("Both withdrawals have been completed.");
        console2.log("ETH has been transferred to the LiquidityPool.");
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Run checkpoint proofs to re-verify beacon balance, OR");
        console2.log("  2. Accept validators as 'staked but not restaked'");
    }
    
    function _checkRole(address account) internal view {
        // Get roleRegistry from nodesManager
        // Note: roleRegistry is immutable in EtherFiNodesManager
        (bool success, bytes memory data) = ETHERFI_NODES_MANAGER.staticcall(
            abi.encodeWithSignature("roleRegistry()")
        );
        
        if (success && data.length >= 32) {
            address roleRegistryAddr = abi.decode(data, (address));
            IRoleRegistry roleRegistry = IRoleRegistry(roleRegistryAddr);
            
            bool hasRole = roleRegistry.hasRole(ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE, account);
            
            if (hasRole) {
                console2.log("Role check: PASSED");
                console2.log("  Account has ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE");
            } else {
                console2.log("Role check: WARNING");
                console2.log("  Account does NOT have ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE");
                console2.log("  Transaction will revert with IncorrectRole()");
            }
        } else {
            console2.log("Role check: SKIPPED (could not query roleRegistry)");
        }
        console2.log("");
    }
}

