// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import "../../src/EtherFiNode.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/EtherFiRateLimiter.sol";
import "../../src/StakingManager.sol";
import "../../src/UUPSProxy.sol";
import "../../src/RoleRegistry.sol";

interface IUpgradable {
    function upgradeTo(address newImplementation) external;
}

// Interface for the OLD contract to clear whitelist before upgrade
interface ICurrentEtherFiNodesManager {
    function allowedForwardedEigenpodCalls(bytes4 selector) external view returns (bool);
    function allowedForwardedExternalCalls(bytes4 selector, address target) external view returns (bool);
    function updateAllowedForwardedEigenpodCalls(bytes4 selector, bool allowed) external;
    function updateAllowedForwardedExternalCalls(bytes4 selector, address target, bool allowed) external;
}

/**
 * @title DeployPectraUpgrade
 * @notice Complete EIP-7002 deployment script for mainnet
 * @dev Includes: Rate Limiter deployment, contract upgrades, role assignments, initialization, and whitelist cleanup
 * 
 * Steps:
 * 1. Clean up old whitelist mappings
 * 2. Deploy EtherFiRateLimiter
 * 3. Deploy new implementations (StakingManager, EtherFiNodesManager, EtherFiNode)
 * 4. Upgrade contracts
 * 5. Assign new roles
 * 6. Initialize rate limiter buckets
 * 
 * Usage: forge script script/el-exits/DeployPectraUpgrade.s.sol --rpc-url <mainnet-rpc> --broadcast --verify
 */
contract DeployPectraUpgrade is Script {
    
    // === MAINNET CONTRACT ADDRESSES ===
    // PlEASE VERIFY THE ADDRESSES BEFORE EXECUTIOIN
    address constant STAKING_MANAGER_PROXY = 0x25e821b7197B146F7713C3b89B6A4D83516B912d;
    address constant LIQUIDITY_POOL_PROXY = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address constant ETHERFI_NODES_MANAGER_PROXY = 0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F;
    address constant AUCTION_MANAGER = 0x00C452aFFee3a17d9Cecc1Bcd2B8d5C7635C4CB9;
    address constant ETHERFI_NODE_BEACON = 0x3c55986Cfee455E2533F4D29006634EcF9B7c03F;
    address constant ROLE_REGISTRY = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;
    address constant ETH_DEPOSIT_CONTRACT = 0x00000000219ab540356cBB839Cbe05303d7705Fa;
    address constant EIGEN_POD_MANAGER = 0x91E677b07F7AF907ec9a428aafA9fc14a0d3A338;
    address constant DELEGATION_MANAGER = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A;

    // === ROLE ADDRESSES ===
    // PlEASE VERIFY THE ADDRESSES BEFORE EXECUTIOIN
    address constant ETHERFI_ADMIN_EXECUTER = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;
    address constant ETHERFI_ADMIN = 0x0EF8fa4760Db8f5Cd4d993f3e3416f30f942D705;

    // === DEPLOYED CONTRACTS ===
    EtherFiRateLimiter public rateLimiterProxy;
    address public stakingManagerImpl;
    address public etherFiNodesManagerImpl;
    address public etherFiNodeImpl;

    function run() external {
        vm.startBroadcast();

        console2.log("========================================");
        console2.log("EIP-7002 Mainnet Deployment");
        console2.log("========================================");
        console2.log("Deployer:", msg.sender);
        console2.log("");

        // Step 1: Clean up old whitelist mappings
        cleanupOldWhitelist();

        // Step 2: Deploy EtherFiRateLimiter
        deployRateLimiter();

        // Step 3: Deploy new implementations
        deployImplementations();

        // Step 4: Upgrade contracts
        upgradeContracts();

        // Step 5: Assign new roles (requires admin permissions)
        assignNewRoles();

        // Step 6: Initialize rate limiter buckets
        initializeRateLimiter();

        printDeploymentSummary();

        vm.stopBroadcast();
    }

    function cleanupOldWhitelist() internal {
        console2.log("=== STEP 1: CLEANING UP OLD WHITELIST ===");
        console2.log("Clearing existing whitelist mappings before upgrade...");

        ICurrentEtherFiNodesManager oldNodesManager = ICurrentEtherFiNodesManager(ETHERFI_NODES_MANAGER_PROXY);

        // Clear known whitelisted EigenPod calls
        bytes4[] memory eigenPodSelectors = new bytes4[](2);
        eigenPodSelectors[0] = 0x0dd8dd02;
        eigenPodSelectors[1] = 0x88676cad;

        console2.log("Clearing EigenPod call whitelist...");
        for (uint i = 0; i < eigenPodSelectors.length; i++) {
            if (oldNodesManager.allowedForwardedEigenpodCalls(eigenPodSelectors[i])) {
                console2.log("  Clearing EigenPod selector:", vm.toString(eigenPodSelectors[i]));
                oldNodesManager.updateAllowedForwardedEigenpodCalls(eigenPodSelectors[i], false);
            }
        }

        // Clear known whitelisted external calls
        console2.log("Clearing external call whitelist...");
        
        // RewardsCoordinator processClaim
        bytes4 processClaimSelector = 0x3ccc861d;
        address rewardsCoordinator = 0x7750d328b314EfFa365A0402CcfD489B80B0adda;
        if (oldNodesManager.allowedForwardedExternalCalls(processClaimSelector, rewardsCoordinator)) {
            console2.log("  Clearing processClaim on RewardsCoordinator");
            oldNodesManager.updateAllowedForwardedExternalCalls(processClaimSelector, rewardsCoordinator, false);
        }

        // DelegationManager calls
        bytes4 delegateSelector = 0x0dd8dd02;
        if (oldNodesManager.allowedForwardedExternalCalls(delegateSelector, DELEGATION_MANAGER)) {
            console2.log("  Clearing delegation call on DelegationManager");
            oldNodesManager.updateAllowedForwardedExternalCalls(delegateSelector, DELEGATION_MANAGER, false);
        }

        console2.log(unicode"✓ Whitelist cleanup complete");
        console2.log("");
    }

    function deployRateLimiter() internal {
        console2.log("=== STEP 2: DEPLOYING ETHERFI RATE LIMITER ===");
        
        // Deploy implementation
        EtherFiRateLimiter rateLimiterImpl = new EtherFiRateLimiter(ROLE_REGISTRY);
        console2.log("Rate limiter implementation:", address(rateLimiterImpl));
        
        // Deploy proxy
        UUPSProxy rateLimiterProxyContract = new UUPSProxy(address(rateLimiterImpl), "");
        rateLimiterProxy = EtherFiRateLimiter(address(rateLimiterProxyContract));
        console2.log("Rate limiter proxy:", address(rateLimiterProxy));
        
        // Initialize
        rateLimiterProxy.initialize();
        console2.log(unicode"✓ Rate limiter deployed and initialized");
        console2.log("");
    }

    function deployImplementations() internal {
        console2.log("=== STEP 3: DEPLOYING NEW IMPLEMENTATIONS ===");
        
        // Deploy StakingManager implementation
        console2.log("Deploying StakingManager implementation...");
        stakingManagerImpl = address(new StakingManager(
            LIQUIDITY_POOL_PROXY,
            ETHERFI_NODES_MANAGER_PROXY,
            ETH_DEPOSIT_CONTRACT,
            AUCTION_MANAGER,
            ETHERFI_NODE_BEACON,
            ROLE_REGISTRY
        ));
        console2.log("  StakingManager implementation:", stakingManagerImpl);

        // Deploy EtherFiNodesManager implementation (with rate limiter)
        console2.log("Deploying EtherFiNodesManager implementation...");
        etherFiNodesManagerImpl = address(new EtherFiNodesManager(
            STAKING_MANAGER_PROXY,
            ROLE_REGISTRY,
            address(rateLimiterProxy) // New rate limiter integration
        ));
        console2.log("  EtherFiNodesManager implementation:", etherFiNodesManagerImpl);

        // Deploy EtherFiNode implementation
        console2.log("Deploying EtherFiNode implementation...");
        etherFiNodeImpl = address(new EtherFiNode(
            LIQUIDITY_POOL_PROXY,
            ETHERFI_NODES_MANAGER_PROXY,
            EIGEN_POD_MANAGER,
            DELEGATION_MANAGER,
            ROLE_REGISTRY
        ));
        console2.log("  EtherFiNode implementation:", etherFiNodeImpl);
        console2.log(unicode"✓ All implementations deployed");
        console2.log("");
    }

    function upgradeContracts() internal {
        console2.log("=== STEP 4: UPGRADING CONTRACTS ===");
        console2.log("NOTE: These upgrades require timelock admin permissions");
        console2.log("The following calls will need to be executed by governance:");
        console2.log("");
        
        // Print the calls that need to be made by governance
        console2.log("Required governance calls:");
        console2.log("1. StakingManager upgrade:");
        console2.log("   Target:", STAKING_MANAGER_PROXY);
        console2.log("   Data: upgradeTo(", stakingManagerImpl, ")");
        console2.log("");
        
        console2.log("2. EtherFiNodesManager upgrade:");
        console2.log("   Target:", ETHERFI_NODES_MANAGER_PROXY);
        console2.log("   Data: upgradeTo(", etherFiNodesManagerImpl, ")");
        console2.log("");
        
        console2.log("3. EtherFiNode beacon upgrade:");
        console2.log("   Target:", STAKING_MANAGER_PROXY);
        console2.log("   Data: upgradeEtherFiNode(", etherFiNodeImpl, ")");
        console2.log("");

        // For testing purposes, if we have owner permissions, do the upgrades
        // In production, remove this section and use governance
        try IUpgradable(STAKING_MANAGER_PROXY).upgradeTo(stakingManagerImpl) {
            console2.log(unicode"✓ StakingManager upgraded");
        } catch {
            console2.log(unicode"⚠ StakingManager upgrade requires governance (timelock)");
        }

        try IUpgradable(ETHERFI_NODES_MANAGER_PROXY).upgradeTo(etherFiNodesManagerImpl) {
            console2.log(unicode"✓ EtherFiNodesManager upgraded");
        } catch {
            console2.log(unicode"⚠ EtherFiNodesManager upgrade requires governance (timelock)");
        }

        try IStakingManager(STAKING_MANAGER_PROXY).upgradeEtherFiNode(etherFiNodeImpl) {
            console2.log(unicode"✓ EtherFiNode beacon upgraded");
        } catch {
            console2.log(unicode"⚠ EtherFiNode upgrade requires governance (timelock)");
        }

        console2.log("");
    }

    function assignNewRoles() internal {
        console2.log("=== STEP 5: ASSIGNING NEW ROLES ===");
        console2.log("NOTE: Role assignments require roleRegistry owner permissions");
        console2.log("");

        RoleRegistry roleRegistry = RoleRegistry(ROLE_REGISTRY);
        
        // Get the new role IDs
        EtherFiNodesManager nodesManager = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER_PROXY));
        bytes32 elTriggerExitRole = nodesManager.ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE();
        bytes32 rateLimiterAdminRole = rateLimiterProxy.ETHERFI_RATE_LIMITER_ADMIN_ROLE();

        console2.log("Role assignments needed:");
        console2.log("1. EL Trigger Exit Role:");
        console2.log("   Role:", vm.toString(elTriggerExitRole));
        console2.log("   Assignee:", ETHERFI_ADMIN_EXECUTER);
        console2.log("");
        
        console2.log("2. Rate Limiter Admin Role:");
        console2.log("   Role:", vm.toString(rateLimiterAdminRole));
        console2.log("   Assignee:", ETHERFI_ADMIN);
        console2.log("");

        // For testing purposes, if we have role permissions, assign the roles
        // In production, remove this section and use governance
        try roleRegistry.grantRole(elTriggerExitRole, ETHERFI_ADMIN_EXECUTER) {
            console2.log(unicode"✓ EL Trigger Exit role assigned to", ETHERFI_ADMIN_EXECUTER);
        } catch {
            console2.log(unicode"⚠ EL Trigger Exit role assignment requires roleRegistry owner");
        }

        try roleRegistry.grantRole(rateLimiterAdminRole, ETHERFI_ADMIN) {
            console2.log(unicode"✓ Rate Limiter Admin role assigned to", ETHERFI_ADMIN);
        } catch {
            console2.log(unicode"⚠ Rate Limiter Admin role assignment requires roleRegistry owner");
        }

        // Also need to grant standard admin roles for rate limiter management
        try roleRegistry.grantRole(nodesManager.ETHERFI_NODES_MANAGER_ADMIN_ROLE(), ETHERFI_ADMIN) {
            console2.log(unicode"✓ Nodes Manager Admin role assigned to", ETHERFI_ADMIN);
        } catch {
            console2.log(unicode"⚠ Nodes Manager Admin role assignment requires roleRegistry owner");
        }

        console2.log("");
    }

    function initializeRateLimiter() internal {
        console2.log("=== STEP 6: INITIALIZING RATE LIMITER ===");
        console2.log("NOTE: Rate limiter initialization requires admin permissions");
        console2.log("");

        EtherFiNodesManager nodesManager = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER_PROXY));
        
        // Get bucket IDs
        bytes32 unrestakingLimitId = nodesManager.UNRESTAKING_LIMIT_ID();
        bytes32 exitRequestLimitId = nodesManager.EXIT_REQUEST_LIMIT_ID();

        console2.log("Rate limiter initialization needed:");
        console2.log("1. UNRESTAKING_LIMIT_ID bucket:");
        console2.log("   ID:", vm.toString(unrestakingLimitId));
        console2.log("   Capacity: 172800000000000 (2000 ETH/day)");
        console2.log("   Refill Rate: 2000000000 (2 ETH/second)");
        console2.log("");
        
        console2.log("2. EXIT_REQUEST_LIMIT_ID bucket:");
        console2.log("   ID:", vm.toString(exitRequestLimitId));
        console2.log("   Capacity: 172800000000000 (2000 ETH/day)");
        console2.log("   Refill Rate: 2000000000 (2 ETH/second)");
        console2.log("");

        // In production, remove this section and use proper admin
        try rateLimiterProxy.createNewLimiter(unrestakingLimitId, 172_800_000_000_000, 2_000_000_000) {
            console2.log(unicode"✓ UNRESTAKING_LIMIT_ID bucket created");
        } catch {
            console2.log(unicode"⚠ UNRESTAKING_LIMIT_ID bucket creation requires rate limiter admin");
        }

        try rateLimiterProxy.createNewLimiter(exitRequestLimitId, 172_800_000_000_000, 2_000_000_000) {
            console2.log(unicode"✓ EXIT_REQUEST_LIMIT_ID bucket created");
        } catch {
            console2.log(unicode"⚠ EXIT_REQUEST_LIMIT_ID bucket creation requires rate limiter admin");
        }

        // Set up consumers
        try rateLimiterProxy.updateConsumers(unrestakingLimitId, ETHERFI_NODES_MANAGER_PROXY, true) {
            console2.log(unicode"✓ EtherFiNodesManager added as UNRESTAKING consumer");
        } catch {
            console2.log(unicode"⚠ Consumer setup requires rate limiter admin");
        }

        try rateLimiterProxy.updateConsumers(exitRequestLimitId, ETHERFI_NODES_MANAGER_PROXY, true) {
            console2.log(unicode"✓ EtherFiNodesManager added as EXIT_REQUEST consumer");
        } catch {
            console2.log(unicode"⚠ Consumer setup requires rate limiter admin");
        }

        console2.log("");
    }

    function printDeploymentSummary() internal view {
        console2.log("========================================");
        console2.log("EIP-7002 DEPLOYMENT SUMMARY");
        console2.log("========================================");
        console2.log("");
        
        console2.log("New Contracts Deployed:");
        console2.log("- EtherFiRateLimiter Proxy:", address(rateLimiterProxy));
        console2.log("");
        
        console2.log("New Implementations:");
        console2.log("- StakingManager:", stakingManagerImpl);
        console2.log("- EtherFiNodesManager:", etherFiNodesManagerImpl);
        console2.log("- EtherFiNode:", etherFiNodeImpl);
        console2.log("");
        
        console2.log("Contract Addresses (unchanged):");
        console2.log("- StakingManager Proxy:", STAKING_MANAGER_PROXY);
        console2.log("- EtherFiNodesManager Proxy:", ETHERFI_NODES_MANAGER_PROXY);
        console2.log("- Role Registry:", ROLE_REGISTRY);
        console2.log("");
        
        console2.log("New Features:");
        console2.log(unicode"✓ EL-triggered exits");
        console2.log(unicode"✓ Consolidation requests");
        console2.log(unicode"✓ Rate limiting system");
        console2.log(unicode"✓ User-specific call forwarding");
        console2.log(unicode"✓ Whitelist cleanup completed");
        console2.log("");
        
        console2.log("Required Post-Deployment Actions:");
        console2.log("1. Execute contract upgrades via governance/timelock");
        console2.log("2. Assign new roles via roleRegistry owner");
        console2.log("3. Initialize rate limiter buckets via admin");
        console2.log("");
        
        console2.log("New Roles:");
        console2.log("- ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE -> ", ETHERFI_ADMIN_EXECUTER);
        console2.log("- ETHERFI_RATE_LIMITER_ADMIN_ROLE -> ", ETHERFI_ADMIN);
        console2.log("");
        
        console2.log(unicode"✓ EIP-7002 deployment preparation complete!");
        console2.log("Ready for governance execution of upgrades and role assignments");
    }

    // Helper functions for manual execution if needed
    function onlyUpgradeContracts() external {
        vm.startBroadcast();
        console2.log("=== MANUAL CONTRACT UPGRADES ===");
        
        IUpgradable(STAKING_MANAGER_PROXY).upgradeTo(stakingManagerImpl);
        console2.log(unicode"✓ StakingManager upgraded");
        
        IUpgradable(ETHERFI_NODES_MANAGER_PROXY).upgradeTo(etherFiNodesManagerImpl);
        console2.log(unicode"✓ EtherFiNodesManager upgraded");
        
        IStakingManager(STAKING_MANAGER_PROXY).upgradeEtherFiNode(etherFiNodeImpl);
        console2.log(unicode"✓ EtherFiNode upgraded");
        
        vm.stopBroadcast();
    }

    function onlyAssignRoles() external {
        vm.startBroadcast();
        console2.log("=== MANUAL ROLE ASSIGNMENTS ===");
        
        RoleRegistry roleRegistry = RoleRegistry(ROLE_REGISTRY);
        EtherFiNodesManager nodesManager = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER_PROXY));
        
        bytes32 elTriggerExitRole = nodesManager.ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE();
        bytes32 rateLimiterAdminRole = rateLimiterProxy.ETHERFI_RATE_LIMITER_ADMIN_ROLE();
        
        roleRegistry.grantRole(elTriggerExitRole, ETHERFI_ADMIN_EXECUTER);
        roleRegistry.grantRole(rateLimiterAdminRole, ETHERFI_ADMIN);
        roleRegistry.grantRole(nodesManager.ETHERFI_NODES_MANAGER_ADMIN_ROLE(), ETHERFI_ADMIN);
        
        console2.log(unicode"✓ All roles assigned");
        vm.stopBroadcast();
    }

    function onlyInitializeRateLimiter() external {
        vm.startBroadcast();
        console2.log("=== MANUAL RATE LIMITER INITIALIZATION ===");
        
        EtherFiNodesManager nodesManager = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER_PROXY));
        
        bytes32 unrestakingLimitId = nodesManager.UNRESTAKING_LIMIT_ID();
        bytes32 exitRequestLimitId = nodesManager.EXIT_REQUEST_LIMIT_ID();
        
        rateLimiterProxy.createNewLimiter(unrestakingLimitId, 172_800_000_000_000, 2_000_000_000);
        rateLimiterProxy.createNewLimiter(exitRequestLimitId, 172_800_000_000_000, 2_000_000_000);
        
        rateLimiterProxy.updateConsumers(unrestakingLimitId, ETHERFI_NODES_MANAGER_PROXY, true);
        rateLimiterProxy.updateConsumers(exitRequestLimitId, ETHERFI_NODES_MANAGER_PROXY, true);
        
        console2.log(unicode"✓ Rate limiter initialized");
        vm.stopBroadcast();
    }
}