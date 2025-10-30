// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../../src/interfaces/IRoleRegistry.sol";
import "forge-std/Script.sol";
import "forge-std/console.sol";

/**
 * @title Set Role Script
 * @notice Script for granting or revoking roles in the EtherFi protocol
 *
 * Notice: Ensure to set ENV vars for action, roleName, and address before running and add --private-key $PRIVATE_KEY of admin(found in 1Password)
 *
 * This script allows you to:
 * 1. Grant a role to an address
 * 2. Revoke a role from an address
 * 3. Check if an address has a role
 * 4. List all addresses with a specific role
 *
 * Available roles:
 * - PROTOCOL_PAUSER: Can pause protocol contracts
 * - PROTOCOL_UNPAUSER: Can unpause protocol contracts
 * - LIQUIDITY_POOL_ADMIN_ROLE: Admin for liquidity pool
 * - LIQUIDITY_POOL_VALIDATOR_APPROVER_ROLE: Can approve validators in liquidity pool
 * - ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE: Admin for oracle executor
 * - ETHERFI_ORACLE_EXECUTOR_TASK_MANAGER_ROLE: Task manager for oracle executor
 * - EETH_OPERATING_ADMIN_ROLE: Operating admin for eETH
 * - ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE: Admin for redemption manager
 * - ETHERFI_REWARDS_ROUTER_ADMIN_ROLE: Admin for rewards router
 * - CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR_ADMIN_ROLE: Admin for merkle rewards distributor
 * - CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR_CLAIM_DELAY_SETTER_ROLE: Claim delay setter
 * - WEETH_OPERATING_ADMIN_ROLE: Operating admin for weETH
 * - WITHDRAW_REQUEST_NFT_ADMIN_ROLE: Admin for withdraw request NFT
 * - IMPLICIT_FEE_CLAIMER_ROLE: Can claim implicit fees
 * - STAKING_MANAGER_NODE_CREATOR_ROLE: Can create nodes in staking manager
 * - ETHERFI_NODES_MANAGER_ADMIN_ROLE: Admin for nodes manager
 * - ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE: EigenLayer admin for nodes manager
 * - ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE: Call forwarder for nodes manager
 * - ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE: EigenLayer admin for individual nodes
 * - ETHERFI_NODE_CALL_FORWARDER_ROLE: Call forwarder for individual nodes
 * - ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE: Executes Execution Layer Withdrawals
 *
 * Usage Examples:
 *
 * 1. Grant PROTOCOL_PAUSER role:
 *    ROLE_NAME=PROTOCOL_PAUSER ADDRESS=0x123... ACTION=grant forge script script/SetRole.s.sol:SetRole --rpc-url $RPC_URL --broadcast
 *
 * 2. Revoke PROTOCOL_PAUSER role:
 *    ROLE_NAME=PROTOCOL_PAUSER ADDRESS=0x123... ACTION=revoke forge script script/SetRole.s.sol:SetRole --rpc-url $RPC_URL --broadcast
 *
 * 3. Check if address has role:
 *    ROLE_NAME=PROTOCOL_PAUSER ADDRESS=0x123... ACTION=check forge script script/SetRole.s.sol:SetRole --rpc-url $RPC_URL
 *
 * 4. List all addresses with role:
 *    ROLE_NAME=PROTOCOL_PAUSER ACTION=list forge script script/SetRole.s.sol:SetRole --rpc-url $RPC_URL
 */
contract SetRole is Script {
    // Contract addresses - UPDATE THESE FOR YOUR DEPLOYMENT
    address constant ROLE_REGISTRY = 0x7279853cA1804d4F705d885FeA7f1662323B5Aab; // Hoodi testnet

    // Role definitions
    bytes32 constant PROTOCOL_PAUSER = keccak256("PROTOCOL_PAUSER");
    bytes32 constant PROTOCOL_UNPAUSER = keccak256("PROTOCOL_UNPAUSER");
    bytes32 constant LIQUIDITY_POOL_ADMIN_ROLE = keccak256("LIQUIDITY_POOL_ADMIN_ROLE");
    bytes32 constant LIQUIDITY_POOL_VALIDATOR_APPROVER_ROLE = keccak256("LIQUIDITY_POOL_VALIDATOR_APPROVER_ROLE");
    bytes32 constant ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE = keccak256("ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE");
    bytes32 constant ETHERFI_ORACLE_EXECUTOR_TASK_MANAGER_ROLE = keccak256("ETHERFI_ORACLE_EXECUTOR_TASK_MANAGER_ROLE");
    bytes32 constant EETH_OPERATING_ADMIN_ROLE = keccak256("EETH_OPERATING_ADMIN_ROLE");
    bytes32 constant ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE = keccak256("ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE");
    bytes32 constant ETHERFI_REWARDS_ROUTER_ADMIN_ROLE = keccak256("ETHERFI_REWARDS_ROUTER_ADMIN_ROLE");
    bytes32 constant CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR_ADMIN_ROLE = keccak256("CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR_ADMIN_ROLE");
    bytes32 constant CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR_CLAIM_DELAY_SETTER_ROLE = keccak256("CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR_CLAIM_DELAY_SETTER_ROLE");
    bytes32 constant WEETH_OPERATING_ADMIN_ROLE = keccak256("WEETH_OPERATING_ADMIN_ROLE");
    bytes32 constant WITHDRAW_REQUEST_NFT_ADMIN_ROLE = keccak256("WITHDRAW_REQUEST_NFT_ADMIN_ROLE");
    bytes32 constant IMPLICIT_FEE_CLAIMER_ROLE = keccak256("IMPLICIT_FEE_CLAIMER_ROLE");
    bytes32 constant STAKING_MANAGER_NODE_CREATOR_ROLE = keccak256("STAKING_MANAGER_NODE_CREATOR_ROLE");
    bytes32 constant ETHERFI_NODES_MANAGER_ADMIN_ROLE = keccak256("ETHERFI_NODES_MANAGER_ADMIN_ROLE");
    bytes32 constant ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE = keccak256("ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE");
    bytes32 constant ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE = keccak256("ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE");
    bytes32 constant ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE = keccak256("ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE");
    bytes32 constant ETHERFI_NODE_CALL_FORWARDER_ROLE = keccak256("ETHERFI_NODE_CALL_FORWARDER_ROLE");
    bytes32 constant ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE = keccak256("ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE");

    IRoleRegistry roleRegistry;

    function run() external {
        // Initialize contracts
        roleRegistry = IRoleRegistry(ROLE_REGISTRY);

        // Get environment variables
        string memory roleName = "ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE"; //vm.envString("ROLE_NAME");
        string memory action = "grant"; //vm.envString("ACTION");

        bytes32 role = keccak256(abi.encodePacked(roleName));
        require(role != bytes32(0), "Invalid role name");

        if (keccak256(abi.encodePacked(action)) == keccak256(abi.encodePacked("grant"))) grantRole(role);
        else if (keccak256(abi.encodePacked(action)) == keccak256(abi.encodePacked("revoke"))) revokeRole(role);
        else if (keccak256(abi.encodePacked(action)) == keccak256(abi.encodePacked("check"))) checkRole(role);
        else if (keccak256(abi.encodePacked(action)) == keccak256(abi.encodePacked("list"))) listRoleHolders(role);
        else revert("Invalid action. Use: grant, revoke, check, or list");
    }

    function grantRole(bytes32 role) internal {
        address target = vm.envAddress("ADDRESS");
        require(target != address(0), "ADDRESS environment variable required");

        vm.startBroadcast();

        console.log("Granting role", vm.toString(role));
        console.log("To address:", target);

        roleRegistry.grantRole(role, target);

        vm.stopBroadcast();

        console.log("Role granted successfully!");

        // Verify the role was granted
        bool hasRole = roleRegistry.hasRole(role, target);
        console.log("Verification - Has role:", hasRole);
    }

    function revokeRole(bytes32 role) internal {
        address target = vm.envAddress("ADDRESS");
        require(target != address(0), "ADDRESS environment variable required");

        vm.startBroadcast();

        console.log("Revoking role", vm.toString(role));
        console.log("From address:", target);

        roleRegistry.revokeRole(role, target);

        vm.stopBroadcast();

        console.log("Role revoked successfully!");

        // Verify the role was revoked
        bool hasRole = roleRegistry.hasRole(role, target);
        console.log("Verification - Has role:", hasRole);
    }

    function checkRole(bytes32 role) internal view {
        address target = vm.envAddress("ADDRESS");
        require(target != address(0), "ADDRESS environment variable required");

        bool hasRole = roleRegistry.hasRole(role, target);

        console.log("Role:", vm.toString(role));
        console.log("Address:", target);
        console.log("Has role:", hasRole);
    }

    function listRoleHolders(bytes32 role) internal view {
        address[] memory holders = roleRegistry.roleHolders(role);

        console.log("Role:", vm.toString(role));
        console.log("Number of holders:", holders.length);

        for (uint256 i = 0; i < holders.length; i++) {
            console.log("Holder", i + 1, ":", holders[i]);
        }
    }
}
