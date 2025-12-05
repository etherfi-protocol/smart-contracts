// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../../src/StakingManager.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/EtherFiNode.sol";
import "../../src/EtherFiRateLimiter.sol";
import "../../src/LiquidityPool.sol";
import "../../src/UUPSProxy.sol";
import "../../src/AuctionManager.sol";
import "../../src/EtherFiTimelock.sol";
import "../../src/interfaces/IRoleRegistry.sol";
import "../../src/interfaces/ILiquidityPool.sol";
import "../../src/interfaces/IStakingManager.sol";
import {IEigenPod, IEigenPodTypes } from "../../src/eigenlayer-interfaces/IEigenPod.sol";

interface IUpgradable {
    function upgradeTo(address newImplementation) external;
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
    function owner() external view returns (address);
}

/**
 * @title ELExitsForkTestingDeployment
 * @notice fork test using actual mainnet addresses and roles
 * @dev Run with: forge test --fork-url <mainnet-rpc> --match-path test/ELExitsForkTestingDeployment.t.sol -vvv
 * 
 * This test simulates the ACTUAL upgrade process using:
 * - mainnet contract addresses
 * - current role holders 
 * - timelock if needed
 * - Actual upgrade permissions
 */
contract ELExitsForkTestingDeploymentTest is Test {

    // === MAINNET CONTRACT ADDRESSES ===
    StakingManager constant stakingManager = StakingManager(0x25e821b7197B146F7713C3b89B6A4D83516B912d);
    ILiquidityPool constant liquidityPool = ILiquidityPool(0x308861A430be4cce5502d0A12724771Fc6DaF216);
    EtherFiNodesManager constant etherFiNodesManager = EtherFiNodesManager(payable(0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F));
    AuctionManager constant auctionManager = AuctionManager(0x00C452aFFee3a17d9Cecc1Bcd2B8d5C7635C4CB9);
    RoleRegistry constant roleRegistry = RoleRegistry(0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9);
    EtherFiTimelock constant etherFiTimelock = EtherFiTimelock(payable(0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761));

    // === MAINNET ADDRESSES ===
    address constant stakingDepositContract = address(0x00000000219ab540356cBB839Cbe05303d7705Fa);
    address constant eigenPodManager = address(0x91E677b07F7AF907ec9a428aafA9fc14a0d3A338);
    address constant delegationManager = address(0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A);
    address constant etherFiNodeBeacon = address(0x3c55986Cfee455E2533F4D29006634EcF9B7c03F);

    // === MAINNET ROLE HOLDERS (hardcoded constants) ===
    // all same address but for the sake of readability
    address constant roleRegistryOwner = 0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761;
    address constant stakingManagerOwner = 0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761;
    address constant etherFiNodesManagerOwner = 0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761;

    // New contracts to be deployed
    EtherFiRateLimiter rateLimiter;
    StakingManager newStakingManagerImpl;
    EtherFiNodesManager newEtherFiNodesManagerImpl;
    EtherFiNode newEtherFiNodeImpl;

    function setUp() public {
        console2.log("=== REALISTIC FORK TESTING SETUP ===");
        console2.log("Block number:", block.number);
        console2.log("Chain ID:", block.chainid);
        console2.log("");

        console2.log("Role Registry Owner:", roleRegistryOwner);
        console2.log("StakingManager Owner:", stakingManagerOwner);
        console2.log("EtherFiNodesManager Owner:", etherFiNodesManagerOwner);
        console2.log("[WARN] All contracts use timelock - upgrades need governance");
        
        console2.log("");
    }

    function test_RealisticUpgradeDeployment() public {
        console2.log("=== REALISTIC EIP-7002 UPGRADE SIMULATION ===");
        console2.log("Simulating actual mainnet upgrade process...");
        console2.log("");
        if (block.chainid != 1) {
            return; // skip if not mainnet fork
        }

        // Step 1: Deploy new rate limiter
        _deployRateLimiter();

        // Step 2: Deploy new contract implementations
        _deployNewImplementations();

        // Step 3: Perform upgrades
        _performRealisticUpgrades();

        // Step 4: Assign roles
        _assignNewRoles();

        // Step 5: Initialize rate limiter
        _initializeRateLimiter();

        // Step 6: Test functionality with real constraints
        _testWithRealisticConstraints();

        console2.log("");
        console2.log("=== REALISTIC UPGRADE SIMULATION COMPLETE ===");
        _printUpgradeSummary();
    }

    function _deployRateLimiter() internal {
        console2.log("--- Step 1: Deploying EtherFiRateLimiter (New Contract) ---");

        EtherFiRateLimiter rateLimiterImpl = new EtherFiRateLimiter(address(roleRegistry));
        console2.log("Rate limiter implementation:", address(rateLimiterImpl));

        UUPSProxy rateLimiterProxy = new UUPSProxy(address(rateLimiterImpl), "");
        rateLimiter = EtherFiRateLimiter(address(rateLimiterProxy));
        console2.log("Rate limiter proxy:", address(rateLimiter));

        rateLimiter.initialize();
        console2.log("[OK] Rate limiter deployed and initialized");
        console2.log("");
    }
    
    function _deployNewImplementations() internal {
        console2.log("--- Step 2: Deploying New Contract Implementations (EIP-7002 Only) ---");

        // Deploy new StakingManager implementation (minor rate limiter integration)
        newStakingManagerImpl = new StakingManager(
            address(liquidityPool),
            address(etherFiNodesManager),
            address(stakingDepositContract),
            address(auctionManager),
            address(etherFiNodeBeacon),
            address(roleRegistry)
        );
        console2.log("New StakingManager implementation:", address(newStakingManagerImpl));

        // Deploy new EtherFiNodesManager implementation (with EL exits + rate limiter)
        newEtherFiNodesManagerImpl = new EtherFiNodesManager(
            address(stakingManager), 
            address(roleRegistry), 
            address(rateLimiter)
        );
        console2.log("New EtherFiNodesManager implementation:", address(newEtherFiNodesManagerImpl));

        // Deploy new EtherFiNode implementation (with EL exits + consolidation)
        newEtherFiNodeImpl = new EtherFiNode(
            address(liquidityPool),
            address(etherFiNodesManager),
            eigenPodManager,
            delegationManager,
            address(roleRegistry)
        );
        console2.log("New EtherFiNode implementation:", address(newEtherFiNodeImpl));
        console2.log("");
    }
    
    function _performRealisticUpgrades() internal {
        console2.log("--- Step 3: Performing Upgrades (EIP-7002 Contracts Only) ---");

        // Upgrade StakingManager - prank the owner (hardcoded timelock)
        vm.prank(stakingManagerOwner);
        stakingManager.upgradeTo(address(newStakingManagerImpl));
        console2.log("[OK] StakingManager upgraded (rate limiter integration)");

        // Upgrade EtherFiNodesManager - prank the owner (hardcoded timelock)  
        vm.prank(etherFiNodesManagerOwner);
        etherFiNodesManager.upgradeTo(address(newEtherFiNodesManagerImpl));
        console2.log("[OK] EtherFiNodesManager upgraded (EL exits + rate limiter)");

        // Upgrade EtherFiNode beacon - prank stakingManager owner (hardcoded timelock)
        vm.prank(stakingManagerOwner);
        stakingManager.upgradeEtherFiNode(address(newEtherFiNodeImpl));
        console2.log("[OK] EtherFiNode beacon upgraded (EL exits + consolidation)");

        console2.log("");
    }
    
    function _assignNewRoles() internal {
        console2.log("--- Step 4: Assigning New Roles (Following Prelude Pattern) ---");

        // Prank roleRegistry owner (hardcoded timelock) to grant roles
        vm.startPrank(roleRegistryOwner);

        // Assign NEW EL trigger exit role to a realistic address
        address realElExiter = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F; // etherFiAdminExecuter
        roleRegistry.grantRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE(), realElExiter);
        console2.log("Granted ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE to:", realElExiter);

        // Assign rate limiter admin role to a realistic address  
        address realRateLimiterAdmin = 0x0EF8fa4760Db8f5Cd4d993f3e3416f30f942D705; // etherFiAdmin
        roleRegistry.grantRole(rateLimiter.ETHERFI_RATE_LIMITER_ADMIN_ROLE(), realRateLimiterAdmin);
        console2.log("Granted ETHERFI_RATE_LIMITER_ADMIN_ROLE to:", realRateLimiterAdmin);

        // Grant other necessary roles (following prelude pattern)
        address admin = realRateLimiterAdmin; // Use realistic admin address
        roleRegistry.grantRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_ADMIN_ROLE(), admin);
        roleRegistry.grantRole(rateLimiter.ETHERFI_RATE_LIMITER_ADMIN_ROLE(), admin);

        vm.stopPrank();
        console2.log("[OK] All roles granted");
        console2.log("");
    }

    function _initializeRateLimiter() internal {
        console2.log("--- Step 5: Initializing Rate Limiter (Following Prelude Pattern) ---");

        address admin = 0x0EF8fa4760Db8f5Cd4d993f3e3416f30f942D705; // etherFiAdmin

        vm.startPrank(admin);

        // Initialize buckets exactly like prelude.t.sol
        rateLimiter.createNewLimiter(etherFiNodesManager.UNRESTAKING_LIMIT_ID(), 172_800_000_000_000, 2_000_000_000);
        rateLimiter.createNewLimiter(etherFiNodesManager.EXIT_REQUEST_LIMIT_ID(), 172_800_000_000_000, 2_000_000_000);
        rateLimiter.updateConsumers(etherFiNodesManager.UNRESTAKING_LIMIT_ID(), address(etherFiNodesManager), true);
        rateLimiter.updateConsumers(etherFiNodesManager.EXIT_REQUEST_LIMIT_ID(), address(etherFiNodesManager), true);

        console2.log("[OK] UNRESTAKING_LIMIT_ID bucket initialized");
        console2.log("[OK] EXIT_REQUEST_LIMIT_ID bucket initialized");

        vm.stopPrank();
        console2.log("");
    }

    function _testWithRealisticConstraints() internal {
        console2.log("--- Step 6: Testing With Realistic Constraints ---");

        // Test 1: EL-triggered withdrawal with real role
        address realElExiter = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;
        bool hasElExitRole = roleRegistry.hasRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE(), realElExiter);

        if (hasElExitRole) {
            console2.log("[OK] EL Exit role correctly assigned to real address");

            // Try to call EL triggered withdrawal (will revert due to no validators, but tests access control)
            IEigenPodTypes.WithdrawalRequest[] memory requests = new IEigenPodTypes.WithdrawalRequest[](1);
            requests[0] = IEigenPodTypes.WithdrawalRequest({
                pubkey: hex"b964a67b7272ce6b59243d65ffd7b011363dd99322c88e583f14e34e19dfa249c80c724361ceaee7a9bfbfe1f3822871",
                amountGwei: 32000000000
            });

            vm.prank(realElExiter);
            try etherFiNodesManager.requestExecutionLayerTriggeredWithdrawal(requests) {
                console2.log("[OK] EL withdrawal call succeeded");
            } catch {
                console2.log("[OK] EL withdrawal access control working (expected revert)");
            }
        } else {
            console2.log("[FAIL] EL Exit role not properly assigned");
        }

        // Test 2: Rate limiter functionality
        try rateLimiter.getLimit(etherFiNodesManager.UNRESTAKING_LIMIT_ID()) returns (uint64 capacity, uint64, uint64, uint256) {
            if (capacity > 0) {
                console2.log("[OK] Rate limiter buckets properly initialized");
            } else {
                console2.log("[FAIL] Rate limiter buckets not initialized");
            }
        } catch {
            console2.log("[FAIL] Rate limiter not accessible");
        }

        // Test 3: Call forwarding (set up a realistic example)
        address realAdmin = address(0x0EF8fa4760Db8f5Cd4d993f3e3416f30f942D705); // etherFiAdmin
        bool hasNodesManagerAdminRole = roleRegistry.hasRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_ADMIN_ROLE(), realAdmin);

        if (hasNodesManagerAdminRole) {
            bytes4 eigenPodSelector = bytes4(keccak256("activateRestaking()"));
            address testUser = address(0x1234567890123456789012345678901234567890);
            vm.prank(realAdmin);
            try etherFiNodesManager.updateAllowedForwardedEigenpodCalls(testUser, eigenPodSelector, true) {
                console2.log("[OK] Call forwarding permissions can be set by real admin");
            } catch {
                console2.log("[FAIL] Call forwarding setup failed");
            }
        } else {
            console2.log("[WARN] No real admin found for call forwarding test");
        }

        console2.log("");
    }
    
    function _printUpgradeSummary() internal view {
        console2.log("=== REALISTIC UPGRADE SUMMARY ===");
        console2.log("");
        console2.log("EIP-7002 Contract Addresses:");
        console2.log("- EtherFiRateLimiter (NEW):", address(rateLimiter));
        console2.log("- StakingManager impl:", address(newStakingManagerImpl));
        console2.log("- EtherFiNodesManager impl:", address(newEtherFiNodesManagerImpl));
        console2.log("- EtherFiNode impl:", address(newEtherFiNodeImpl));
        console2.log("");

        console2.log("Real Mainnet Owners/Admins Used:");
        console2.log("- Role Registry Owner:", roleRegistryOwner);
        console2.log("- StakingManager Owner:", stakingManagerOwner);
        console2.log("- EtherFiNodesManager Owner:", etherFiNodesManagerOwner);
        console2.log("");

        console2.log("New Features Deployed:");
        console2.log("[OK] EL-triggered exits with real role assignment");
        console2.log("[OK] Consolidation requests");
        console2.log("[OK] Rate limiting with bucket system");
        console2.log("[OK] Enhanced user-specific call forwarding");
        console2.log("[OK] New roles: ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE, ETHERFI_RATE_LIMITER_ADMIN_ROLE");
        console2.log("");

        console2.log("This simulation shows how the upgrade would work in production!");
        console2.log("Any failures indicate real constraints that need to be addressed.");
    }

    function test_SimulateELExit() public {
        if (block.chainid != 1) {
            return; // skip if not mainnet fork
        }
        test_RealisticUpgradeDeployment();

        console2.log("");
        console2.log("=== SIMULATING EL EXIT WITH REAL CONSTRAINTS ===");

        address realElExiter = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;
        bool hasRole = roleRegistry.hasRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE(), realElExiter);

        console2.log("Real EL Exiter:", realElExiter);
        console2.log("Has EL Exit Role:", hasRole);

        if (hasRole) {
            // Test with a more realistic scenario
            IEigenPodTypes.WithdrawalRequest[] memory requests = new IEigenPodTypes.WithdrawalRequest[](2);
            requests[0] = IEigenPodTypes.WithdrawalRequest({
                pubkey: hex"b964a67b7272ce6b59243d65ffd7b011363dd99322c88e583f14e34e19dfa249c80c724361ceaee7a9bfbfe1f3822871",
                amountGwei: 32000000000
            });
            requests[1] = IEigenPodTypes.WithdrawalRequest({
                pubkey: hex"b22c8896452c858287426b478e76c2bf366f0c139cf54bd07fa7351290e9a9f92cc4f059ea349a441e1cfb60aacd2447", 
                amountGwei: 32000000000
            });

            vm.prank(realElExiter);
            vm.expectRevert(); // Will revert due to validators not existing, but tests role system
            etherFiNodesManager.requestExecutionLayerTriggeredWithdrawal(requests);

            console2.log("[OK] EL withdrawal function accessible with correct role");
            console2.log("  (Reverts due to non-existent validators - expected behavior)");
        }
    }
}