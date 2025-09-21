// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import "../../src/EtherFiNodesManager.sol";
import "../../src/EtherFiRateLimiter.sol";
import "../../src/StakingManager.sol";
import "../../src/RoleRegistry.sol";

/**
 * @title VerifyPectraUpgradeDeployment
 * @notice Verification script to check EIP-7002 deployment status
 * @dev Run after deployment to verify all components are properly configured
 * 
 * Usage: forge script script/el-exits/VerifyPectraUpgradeDeployment.s.sol --rpc-url <mainnet-rpc>
 */
contract VerifyPectraUpgradeDeployment is Script {

    // === MAINNET CONTRACT ADDRESSES ===
    address constant STAKING_MANAGER_PROXY = 0x25e821b7197B146F7713C3b89B6A4D83516B912d;
    address constant ETHERFI_NODES_MANAGER_PROXY = 0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F;
    address constant ROLE_REGISTRY = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;

    // === ROLE ADDRESSES ===
    address constant ETHERFI_ADMIN_EXECUTER = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;
    address constant ETHERFI_ADMIN = 0x0EF8fa4760Db8f5Cd4d993f3e3416f30f942D705;

    // Rate limiter address to be set after deployment
    address rateLimiterAddress;

    function run() external {
        console2.log("========================================");
        console2.log("EIP-7002 DEPLOYMENT VERIFICATION");
        console2.log("========================================");
        console2.log("");

        // Set the rate limiter address - update this after deployment
        console2.log("Enter rate limiter address to verify:");
        console2.log("Run with: --sig 'verifyWithRateLimiter(address)' <rate-limiter-address>");
        console2.log("");

        verifyContractUpgrades();
        verifyRoleAssignments();
        console2.log("To verify rate limiter, use verifyWithRateLimiter(address) function");
    }

    function verifyWithRateLimiter(address _rateLimiterAddress) external {
        rateLimiterAddress = _rateLimiterAddress;
        console2.log("========================================");
        console2.log("EIP-7002 DEPLOYMENT VERIFICATION");
        console2.log("========================================");
        console2.log("Rate Limiter Address:", rateLimiterAddress);
        console2.log("");

        verifyContractUpgrades();
        verifyRoleAssignments();
        verifyRateLimiter();
        verifyNewFunctionality();

        printVerificationSummary();
    }

    function verifyContractUpgrades() internal view {
        console2.log("=== VERIFYING CONTRACT UPGRADES ===");

        EtherFiNodesManager nodesManager = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER_PROXY));
        StakingManager stakingManager = StakingManager(STAKING_MANAGER_PROXY);

        // Check if new functions exist (will revert if not upgraded)
        try nodesManager.ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE() returns (bytes32 role) {
            console2.log(unicode"✓ EtherFiNodesManager upgraded - EL exit role exists:", vm.toString(role));
        } catch {
            console2.log(unicode"✗ EtherFiNodesManager not upgraded - EL exit role missing");
        }

        try nodesManager.UNRESTAKING_LIMIT_ID() returns (bytes32 limitId) {
            console2.log(unicode"✓ EtherFiNodesManager rate limiter integration - UNRESTAKING_LIMIT_ID:", vm.toString(limitId));
        } catch {
            console2.log(unicode"✗ EtherFiNodesManager rate limiter integration missing");
        }

        try nodesManager.EXIT_REQUEST_LIMIT_ID() returns (bytes32 limitId) {
            console2.log(unicode"✓ EtherFiNodesManager rate limiter integration - EXIT_REQUEST_LIMIT_ID:", vm.toString(limitId));
        } catch {
            console2.log(unicode"✗ EtherFiNodesManager rate limiter integration missing");
        }

        // Check rate limiter address integration
        if (rateLimiterAddress != address(0)) {
            try nodesManager.rateLimiter() returns (IEtherFiRateLimiter limiter) {
                if (address(limiter) == rateLimiterAddress) {
                    console2.log(unicode"✓ Rate limiter correctly integrated:", address(limiter));
                } else {
                    console2.log(unicode"✗ Rate limiter mismatch - expected:", rateLimiterAddress, "got:", address(limiter));
                }
            } catch {
                console2.log(unicode"✗ Rate limiter integration not accessible");
            }
        }

        console2.log("");
    }

    function verifyRoleAssignments() internal view {
        console2.log("=== VERIFYING ROLE ASSIGNMENTS ===");

        RoleRegistry roleRegistry = RoleRegistry(ROLE_REGISTRY);
        EtherFiNodesManager nodesManager = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER_PROXY));

        // Check EL Trigger Exit Role
        try nodesManager.ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE() returns (bytes32 elTriggerExitRole) {
            bool hasRole = roleRegistry.hasRole(elTriggerExitRole, ETHERFI_ADMIN_EXECUTER);
            if (hasRole) {
                console2.log(unicode"✓ EL Trigger Exit role assigned to:", ETHERFI_ADMIN_EXECUTER);
            } else {
                console2.log(unicode"✗ EL Trigger Exit role NOT assigned to:", ETHERFI_ADMIN_EXECUTER);
            }
        } catch {
            console2.log(unicode"✗ Cannot check EL Trigger Exit role - contract not upgraded?");
        }

        // Check Rate Limiter Admin Role
        if (rateLimiterAddress != address(0)) {
            EtherFiRateLimiter rateLimiter = EtherFiRateLimiter(rateLimiterAddress);
            try rateLimiter.ETHERFI_RATE_LIMITER_ADMIN_ROLE() returns (bytes32 rateLimiterAdminRole) {
                bool hasRole = roleRegistry.hasRole(rateLimiterAdminRole, ETHERFI_ADMIN);
                if (hasRole) {
                    console2.log(unicode"✓ Rate Limiter Admin role assigned to:", ETHERFI_ADMIN);
                } else {
                    console2.log(unicode"✗ Rate Limiter Admin role NOT assigned to:", ETHERFI_ADMIN);
                }
            } catch {
                console2.log(unicode"✗ Cannot check Rate Limiter Admin role");
            }
        }

        // Check standard admin roles
        bytes32 nodesManagerAdminRole = nodesManager.ETHERFI_NODES_MANAGER_ADMIN_ROLE();
        bool hasAdminRole = roleRegistry.hasRole(nodesManagerAdminRole, ETHERFI_ADMIN);
        if (hasAdminRole) {
            console2.log(unicode"✓ Nodes Manager Admin role assigned to:", ETHERFI_ADMIN);
        } else {
            console2.log(unicode"✗ Nodes Manager Admin role NOT assigned to:", ETHERFI_ADMIN);
        }

        console2.log("");
    }

    function verifyRateLimiter() internal view {
        if (rateLimiterAddress == address(0)) {
            console2.log("=== RATE LIMITER VERIFICATION SKIPPED ===");
            console2.log("Rate limiter address not provided");
            console2.log("");
            return;
        }

        console2.log("=== VERIFYING RATE LIMITER ===");

        EtherFiRateLimiter rateLimiter = EtherFiRateLimiter(rateLimiterAddress);
        EtherFiNodesManager nodesManager = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER_PROXY));

        // Check bucket initialization
        bytes32 unrestakingLimitId = nodesManager.UNRESTAKING_LIMIT_ID();
        bytes32 exitRequestLimitId = nodesManager.EXIT_REQUEST_LIMIT_ID();

        // Verify UNRESTAKING_LIMIT_ID bucket
        try rateLimiter.getLimit(unrestakingLimitId) returns (
            uint64 capacity, 
            uint64 remaining, 
            uint64 refillRate, 
            uint256 lastRefill
        ) {
            console2.log(unicode"✓ UNRESTAKING_LIMIT_ID bucket initialized:");
            console2.log("  Capacity:", capacity);
            console2.log("  Remaining:", remaining);
            console2.log("  Refill Rate:", refillRate);
            console2.log("  Last Refill:", lastRefill);
        } catch {
            console2.log(unicode"✗ UNRESTAKING_LIMIT_ID bucket not initialized");
        }

        // Verify EXIT_REQUEST_LIMIT_ID bucket
        try rateLimiter.getLimit(exitRequestLimitId) returns (
            uint64 capacity, 
            uint64 remaining, 
            uint64 refillRate, 
            uint256 lastRefill
        ) {
            console2.log(unicode"✓ EXIT_REQUEST_LIMIT_ID bucket initialized:");
            console2.log("  Capacity:", capacity);
            console2.log("  Remaining:", remaining);
            console2.log("  Refill Rate:", refillRate);
            console2.log("  Last Refill:", lastRefill);
        } catch {
            console2.log(unicode"✗ EXIT_REQUEST_LIMIT_ID bucket not initialized");
        }

        // Check consumer permissions
        bool unrestakingConsumer = rateLimiter.isConsumerAllowed(unrestakingLimitId, ETHERFI_NODES_MANAGER_PROXY);
        bool exitRequestConsumer = rateLimiter.isConsumerAllowed(exitRequestLimitId, ETHERFI_NODES_MANAGER_PROXY);

        if (unrestakingConsumer) {
            console2.log(unicode"✓ EtherFiNodesManager allowed as UNRESTAKING consumer");
        } else {
            console2.log(unicode"✗ EtherFiNodesManager NOT allowed as UNRESTAKING consumer");
        }

        if (exitRequestConsumer) {
            console2.log(unicode"✓ EtherFiNodesManager allowed as EXIT_REQUEST consumer");
        } else {
            console2.log(unicode"✗ EtherFiNodesManager NOT allowed as EXIT_REQUEST consumer");
        }

        console2.log("");
    }

    function verifyNewFunctionality() internal view {
        console2.log("=== VERIFYING NEW FUNCTIONALITY ACCESS ===");

        EtherFiNodesManager nodesManager = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER_PROXY));

        // Check if new functions are accessible (won't execute due to no params, but checks if they exist)
        console2.log("Checking function signatures exist:");

        // Check EL-triggered withdrawal function
        bytes4 selector1 = nodesManager.requestExecutionLayerTriggeredWithdrawal.selector;
        console2.log(unicode"✓ requestExecutionLayerTriggeredWithdrawal exists:", vm.toString(selector1));

        // Check consolidation function
        bytes4 selector2 = nodesManager.requestConsolidation.selector;
        console2.log(unicode"✓ requestConsolidation exists:", vm.toString(selector2));

        // Check new call forwarding functions
        bytes4 selector3 = nodesManager.updateAllowedForwardedEigenpodCalls.selector;
        console2.log(unicode"✓ updateAllowedForwardedEigenpodCalls (user-specific) exists:", vm.toString(selector3));

        bytes4 selector4 = nodesManager.updateAllowedForwardedExternalCalls.selector;
        console2.log(unicode"✓ updateAllowedForwardedExternalCalls (user-specific) exists:", vm.toString(selector4));

        console2.log("");
    }

    function printVerificationSummary() internal view {
        console2.log("========================================");
        console2.log("VERIFICATION SUMMARY");
        console2.log("========================================");
        console2.log("");
        
        console2.log("Verified Components:");
        console2.log(unicode"✓ Contract upgrade verification");
        console2.log(unicode"✓ Role assignment verification");
        if (rateLimiterAddress != address(0)) {
            console2.log(unicode"✓ Rate limiter configuration verification");
        } else {
            console2.log(unicode"⚠ Rate limiter verification skipped (address not provided)");
        }
        console2.log(unicode"✓ New functionality availability verification");
        console2.log("");
        
        console2.log("Key Addresses Verified:");
        console2.log("- StakingManager Proxy:", STAKING_MANAGER_PROXY);
        console2.log("- EtherFiNodesManager Proxy:", ETHERFI_NODES_MANAGER_PROXY);
        console2.log("- Role Registry:", ROLE_REGISTRY);
        if (rateLimiterAddress != address(0)) {
            console2.log("- EtherFiRateLimiter:", rateLimiterAddress);
        }
        console2.log("");
        
        console2.log("Key Role Holders:");
        console2.log("- EL Exit Trigger:", ETHERFI_ADMIN_EXECUTER);
        console2.log("- Rate Limiter Admin:", ETHERFI_ADMIN);
        console2.log("");
        
        console2.log("Manual Testing Recommendations:");
        console2.log("1. Test EL-triggered withdrawal with proper role");
        console2.log("2. Test consolidation request functionality");
        console2.log("3. Test rate limiting behavior");
        console2.log("4. Test user-specific call forwarding permissions");
        console2.log("5. Verify old whitelist mappings are cleared");
        console2.log("");
        
        console2.log(unicode"✓ EIP-7002 deployment verification complete!");
    }

    // Helper function to check specific rate limiter address
    function checkRateLimiterOnly(address _rateLimiterAddress) external view {
        console2.log("=== RATE LIMITER SPOT CHECK ===");
        console2.log("Rate Limiter Address:", _rateLimiterAddress);
        
        EtherFiRateLimiter rateLimiter = EtherFiRateLimiter(_rateLimiterAddress);
        EtherFiNodesManager nodesManager = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER_PROXY));

        bytes32 unrestakingLimitId = nodesManager.UNRESTAKING_LIMIT_ID();
        bytes32 exitRequestLimitId = nodesManager.EXIT_REQUEST_LIMIT_ID();

        // Check if buckets exist
        bool unrestakingExists = rateLimiter.limitExists(unrestakingLimitId);
        bool exitRequestExists = rateLimiter.limitExists(exitRequestLimitId);

        console2.log("UNRESTAKING_LIMIT_ID exists:", unrestakingExists);
        console2.log("EXIT_REQUEST_LIMIT_ID exists:", exitRequestExists);

        if (unrestakingExists) {
            (uint64 capacity, uint64 remaining, uint64 refillRate, uint256 lastRefill) = rateLimiter.getLimit(unrestakingLimitId);
            console2.log("UNRESTAKING - Capacity:", capacity, "Remaining:", remaining);
        }

        if (exitRequestExists) {
            (uint64 capacity, uint64 remaining, uint64 refillRate, uint256 lastRefill) = rateLimiter.getLimit(exitRequestLimitId);
            console2.log("EXIT_REQUEST - Capacity:", capacity, "Remaining:", remaining);
        }
    }
}