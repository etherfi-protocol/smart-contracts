// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/interfaces/ILiquidityPool.sol";
import {LiquidityPool} from "../../src/LiquidityPool.sol";
import "../../src/interfaces/IStakingManager.sol";
import "../../src/interfaces/IEtherFiNodesManager.sol";
import "../../src/interfaces/IAuctionManager.sol";
import "../../src/interfaces/INodeOperatorManager.sol";
import {NodeOperatorManager} from "../../src/NodeOperatorManager.sol";
import "../../src/interfaces/IEtherFiNode.sol";
import "../../src/interfaces/IRoleRegistry.sol";
import {StakingManager} from "../../src/StakingManager.sol";

/**
 * @title Staking Part 1: Setup & Get EigenPod Address
 * @notice First part of the staking process - creates everything needed before key generation
 * 
 * This script will:
 * 1. Deposit ETH to liquidity pool (if needed)
 * 2. Register you as node operator
 * 3. Create your bid
 * 4. Create EtherFi node and get EigenPod address
 * 5. Save all data to a file for Part 2
 * 
 * Usage: 
 * 1. Set environment variables in .env:
 *    PRIVATE_KEY=<your_wallet_private_key>
 *    NODE_OPERATOR_KEY=<your_node_operator_private_key> (can be same as PRIVATE_KEY)
 *    
 * 2. Run: forge script script/StakingPart1_Setup.s.sol:StakingPart1 --rpc-url https://rpc.hoodi.ethpandaops.io --broadcast
 */
contract StakingPart1 is Script {
    // Hoodi testnet addresses
    address constant LIQUIDITY_POOL = 0xA6C7D9A055Ebb433E5C6E098b0487875537852F0;
    address constant STAKING_MANAGER = 0xEcf3C0Dc644DBC7d0fbf7f69651D90f2177D0dFf;
    address constant ETHERFI_NODES_MANAGER = 0x5eF18135824b4C99f142be7714D90673c7fcE775;
    address constant AUCTION_MANAGER = 0xE3BDCE392B6363493a8Cbc4580857A3931023c9C;
    address constant NODE_OPERATOR_MANAGER = 0x51BB73660D9a12fa06e2A42BcED7D25289d4054D;
    address constant ROLE_REGISTRY = 0x8309580c86C11e61e3C57c7227f74535f6801d7C;
    
    // Role definition
    bytes32 constant STAKING_MANAGER_NODE_CREATOR_ROLE = keccak256("STAKING_MANAGER_NODE_CREATOR_ROLE");
    
    // Contract interfaces
    LiquidityPool liquidityPool;
    StakingManager stakingManager;
    IEtherFiNodesManager etherFiNodesManager;
    IAuctionManager auctionManager;
    NodeOperatorManager nodeOperatorManager;
    IRoleRegistry roleRegistry;
    
    function run() external {
        // Initialize interfaces
        liquidityPool = LiquidityPool(payable(LIQUIDITY_POOL));
        stakingManager = StakingManager(STAKING_MANAGER);
        etherFiNodesManager = IEtherFiNodesManager(payable(ETHERFI_NODES_MANAGER));
        auctionManager = IAuctionManager(AUCTION_MANAGER);
        nodeOperatorManager = NodeOperatorManager(NODE_OPERATOR_MANAGER);
        roleRegistry = IRoleRegistry(ROLE_REGISTRY);
        
        console.log("\n========== EtherFi Staking Setup - Part 1 ==========");
        console.log("This script prepares everything needed before key generation\n");
        
        // Get addresses
        address depositor = vm.addr(vm.envUint("PRIVATE_KEY"));
        address nodeOp = vm.addr(vm.envUint("NODE_OPERATOR_KEY"));
        
        console.log("Depositor address: %s", depositor);
        console.log("Node operator address: %s", nodeOp);
        console.log("Current depositor balance: %s ETH", depositor.balance / 1e18);
        
        // Step 1: Check liquidity pool balance and deposit if needed
        uint256 poolBalance = LIQUIDITY_POOL.balance;
        console.log("\nStep 1: Checking liquidity pool");
        console.log("Current pool balance: %s ETH", poolBalance / 1e18);
        
        if (poolBalance < 32 ether) {
            uint256 needed = 32 ether - poolBalance;
            console.log("Pool needs %s more ETH. Depositing...", needed / 1e18);
            
            vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
            liquidityPool.deposit{value: 32 ether}();
            vm.stopBroadcast();
            
            console.log("Deposited 32 ETH to liquidity pool");
        } else {
            console.log("Pool has sufficient liquidity");
        }
        
        // Step 2: Whitelist and register node operator
        console.log("\nStep 2: Node operator setup");
        
        // Check if already whitelisted
        if (!nodeOperatorManager.isWhitelisted(nodeOp)) {
            console.log("Whitelisting node operator...");
            
            vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
            // Add admin rights if needed
            if (!nodeOperatorManager.admins(depositor)) {
                nodeOperatorManager.updateAdmin(depositor, true);
            }
            nodeOperatorManager.addToWhitelist(nodeOp);
            vm.stopBroadcast();
        }
        
        // Register node operator if not already registered
        if (nodeOperatorManager.registered(nodeOp)) {
            console.log("Node operator already registered");
        } else {
            console.log("Registering node operator...");
            vm.startBroadcast(vm.envUint("NODE_OPERATOR_KEY"));
            nodeOperatorManager.registerNodeOperator("hoodi_testnet_validator", 1000); // 10% commission
            vm.stopBroadcast();
            console.log("Registered with 10% commission");
        }
        
        // Step 3: Create bid
        console.log("\nStep 3: Creating bid");
        vm.startBroadcast(vm.envUint("NODE_OPERATOR_KEY"));
        uint256[] memory bidIds = auctionManager.createBid{value: 0.001 ether}(1, 0.001 ether);
        uint256 bidId = bidIds[0];
        vm.stopBroadcast();
        
        console.log("Created bid with ID: %s", bidId);
        console.log("Bid amount: 0.001 ETH");
        
        // Step 4: Register as validator spawner if needed
        console.log("\nStep 4: Checking validator spawner registration");
        bool spawner = liquidityPool.validatorSpawner(depositor);
        if (spawner) {
            console.log("Registering as validator spawner...");
            vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
            liquidityPool.registerValidatorSpawner(depositor);
            vm.stopBroadcast();
            console.log("Registered successfully!");
        } else {
            console.log("Already registered as validator spawner");
        }
        
        // Step 5: Create EtherFi node and get EigenPod address
        console.log("\nStep 5: Creating EtherFi node");
        
        // Check if depositor has the required role
        if (!roleRegistry.hasRole(STAKING_MANAGER_NODE_CREATOR_ROLE, depositor)) {
            console.log("Depositor doesn't have STAKING_MANAGER_NODE_CREATOR_ROLE");
            
            // Check if we're the owner and can grant the role
            address owner = roleRegistry.owner();
            if (owner == depositor) {
                console.log("You are the RoleRegistry owner, granting role...");
                vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
                roleRegistry.grantRole(STAKING_MANAGER_NODE_CREATOR_ROLE, depositor);
                vm.stopBroadcast();
                console.log("Role granted successfully!");
            } else {
                console.log("RoleRegistry owner is: %s", owner);
                console.log("You need to ask the owner to grant you the role, or use their key");
            }
        } else {
            console.log("Depositor already has STAKING_MANAGER_NODE_CREATOR_ROLE");
        }

        console.log("Has role?",roleRegistry.hasRole(stakingManager.STAKING_MANAGER_NODE_CREATOR_ROLE(), vm.addr(vm.envUint("PRIVATE_KEY"))));
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        console.log("Role reg: %s",address(stakingManager.roleRegistry()));
        console.log("Role Reg: %s",address(roleRegistry));

        address etherFiNode = stakingManager.instantiateEtherFiNode(true);
        console.log("Here?");
        address eigenPod = address(IEtherFiNode(etherFiNode).getEigenPod());
        
        vm.stopBroadcast();
        
        // Save setup data
        console.log("\n========== SETUP COMPLETE ==========");
        console.log("SAVE THIS INFORMATION:");
        console.log("- Bid ID: %s", bidId);
        console.log("- EtherFi Node: %s", etherFiNode);
        console.log("- EigenPod Address: %s", eigenPod);
        console.log("\n========== NEXT STEPS ==========");
        console.log("1. Generate validator keys by running this exact command(you may need to download ethstaker cli):");
        console.log("\n   cd ethstaker_deposit-cli-b13dcb9-darwin-arm64 && ./deposit new-mnemonic --compounding --amount 1 --chain hoodi --withdrawal_address %s", eigenPod);
        console.log("\n2. After generating keys, extract them from the deposit_data json:");
        console.log("\n3. Set environment variables and run Part 2:");
        console.log("\n   export VALIDATOR_PUBKEY=<pubkey_from_extract_script>");
        console.log("   export VALIDATOR_SIGNATURE=<signature_from_extract_script>");
        console.log("   export BID_ID=%s", bidId);
        console.log("   export ETHERFI_NODE=%s", etherFiNode);
        console.log("\n   forge script script/StakingPart2_CreateValidator.s.sol:StakingPart2 --rpc-url https://rpc.hoodi.ethpandaops.io --broadcast");
        console.log("====================================\n");

       
    }
}