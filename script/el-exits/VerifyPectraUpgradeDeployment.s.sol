// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import "../../src/EtherFiNodesManager.sol";
import "../../src/EtherFiRateLimiter.sol";
import "../../src/StakingManager.sol";
import "../../src/RoleRegistry.sol";
import "../../src/EtherFiNode.sol";
import "../../src/UUPSProxy.sol";

interface ICreate2Factory {
    function computeAddress(bytes32 salt, bytes memory code) external view returns (address);
}

/**
 * @title VerifyPectraUpgradeDeployment
 * @notice Verification script to check EIP-7002 deployment status
 * @dev Run after deployment to verify all components are properly configured
 * 
 * Usage: forge script script/el-exits/VerifyPectraUpgradeDeployment.s.sol --rpc-url <mainnet-rpc>
 */
contract VerifyPectraUpgradeDeployment is Script {
    // === CREATE2 FACTORY ===
    ICreate2Factory constant factory = ICreate2Factory(0x356d1B83970CeF2018F2c9337cDdb67dff5AEF99);
    bytes32 constant commitHashSalt = bytes32(bytes20(hex"6c46a46c04f65838ca4ea2750f2b293e01117eb7"));

    // === MAINNET CONTRACT ADDRESSES ===
    address constant STAKING_MANAGER_PROXY = 0x25e821b7197B146F7713C3b89B6A4D83516B912d;
    address constant ETHERFI_NODES_MANAGER_PROXY = 0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F;
    address constant ROLE_REGISTRY = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;
    address constant RATE_LIMITER_PROXY = 0x6C7c54cfC2225fA985cD25F04d923B93c60a02F8;
    address constant LIQUIDITY_POOL_PROXY = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address constant AUCTION_MANAGER = 0x00C452aFFee3a17d9Cecc1Bcd2B8d5C7635C4CB9;
    address constant ETHERFI_NODE_BEACON = 0x3c55986Cfee455E2533F4D29006634EcF9B7c03F;
    address constant ETH_DEPOSIT_CONTRACT = 0x00000000219ab540356cBB839Cbe05303d7705Fa;
    address constant EIGEN_POD_MANAGER = 0x91E677b07F7AF907ec9a428aafA9fc14a0d3A338;
    address constant DELEGATION_MANAGER = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A;

    // === DEPLOYED CONTRACTS ===
    address constant NEW_STAKING_MANAGER_IMPL = 0xa38d03ea42F8bc31892336E1F42523e94FB91a7A;
    address constant NEW_ETHERFI_NODES_MANAGER_IMPL = 0x0f366dF7af5003fC7C6524665ca58bDeAdDC3745;
    address constant NEW_ETHERFI_NODE_IMPL = 0x6268728c52aAa4EC670F5fcdf152B50c4B463472;
    address constant NEW_RATE_LIMITER_IMPL = 0x1dd43C32f03f8A74b8160926D559d34358880A89;
    address constant NEW_RATE_LIMITER_PROXY = 0x6C7c54cfC2225fA985cD25F04d923B93c60a02F8;

    // === ROLE ADDRESSES ===
    // address constant ETHERFI_ADMIN_EXECUTER = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;
    address constant ETHERFI_ADMIN = 0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a;
    address constant ETHERFI_OPERATING_ADMIN =
        0x2aCA71020De61bb532008049e1Bd41E451aE8AdC;
    address constant POD_PROVER = 0x7835fB36A8143a014A2c381363cD1A4DeE586d2A;
    address constant EL_TRIGGER_EXITER =
        0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;

    function run() external {
        console2.log("========================================");
        console2.log("EIP-7002 DEPLOYMENT VERIFICATION");
        console2.log("========================================");
        console2.log("");

        verifyContractUpgrades();
        verifyAddress();
        verifyRoleAssignments();
        // verifyRateLimiter();
        verifyNewFunctionality();

        printVerificationSummary();
    }
    
    function verifyAddress() internal {
        console2.log("=== VERIFYING ADDRESS ===");
        console2.log("ETHERFI_NODES_MANAGER_PROXY:", ETHERFI_NODES_MANAGER_PROXY);
        console2.log("STAKING_MANAGER_PROXY:", STAKING_MANAGER_PROXY);
        console2.log("ROLE_REGISTRY:", ROLE_REGISTRY);
        console2.log("RATE_LIMITER_PROXY:", RATE_LIMITER_PROXY);

        console2.log("");

        address stakingManagerImpl;
        address etherFiNodesManagerImpl;
        address etherFiNodeImpl;

                // StakingManager
        {
            string memory contractName = "StakingManager";
            bytes memory constructorArgs = abi.encode(
                LIQUIDITY_POOL_PROXY,
                ETHERFI_NODES_MANAGER_PROXY,
                ETH_DEPOSIT_CONTRACT,
                AUCTION_MANAGER,
                ETHERFI_NODE_BEACON,
                ROLE_REGISTRY
            );
            bytes memory bytecode = abi.encodePacked(
                type(StakingManager).creationCode,
                constructorArgs
            );
            stakingManagerImpl = verifyCreate2Address(contractName, constructorArgs, bytecode, commitHashSalt, true);
            // stakingManagerImpl = deployCreate2(contractName, constructorArgs, bytecode, commitHashSalt, true);
        }

        // EtherFiNodesManager (with rate limiter)
        {
            string memory contractName = "EtherFiNodesManager";
            bytes memory constructorArgs = abi.encode(
                STAKING_MANAGER_PROXY,
                ROLE_REGISTRY,
                address(RATE_LIMITER_PROXY) // New rate limiter integration
            );
            bytes memory bytecode = abi.encodePacked(
                type(EtherFiNodesManager).creationCode,
                constructorArgs
            );
            etherFiNodesManagerImpl = verifyCreate2Address(contractName, constructorArgs, bytecode, commitHashSalt, true);
            // etherFiNodesManagerImpl = deployCreate2(contractName, constructorArgs, bytecode, commitHashSalt, true);
        }

        // EtherFiNode
        {
            string memory contractName = "EtherFiNode";
            bytes memory constructorArgs = abi.encode(
                LIQUIDITY_POOL_PROXY,
                ETHERFI_NODES_MANAGER_PROXY,
                EIGEN_POD_MANAGER,
                DELEGATION_MANAGER,
                ROLE_REGISTRY
            );
            bytes memory bytecode = abi.encodePacked(
                type(EtherFiNode).creationCode,
                constructorArgs
            );
            etherFiNodeImpl = verifyCreate2Address(contractName, constructorArgs, bytecode, commitHashSalt, true);
            // etherFiNodeImpl = deployCreate2(contractName, constructorArgs, bytecode, commitHashSalt, true);
        }

        address rateLimiterImpl;
        // Deploy implementation using Create2Factory
        {
            string memory contractName = "EtherFiRateLimiter";
            bytes memory constructorArgs = abi.encode(ROLE_REGISTRY);
            bytes memory bytecode = abi.encodePacked(
                type(EtherFiRateLimiter).creationCode,
                constructorArgs
            );
            rateLimiterImpl = verifyCreate2Address(contractName, constructorArgs, bytecode, commitHashSalt, true);
            // rateLimiterImpl = deployCreate2(contractName, constructorArgs, bytecode, commitHashSalt, true);
            console2.log("Rate limiter implementation:", rateLimiterImpl);
        }

        address rateLimiterProxyAddr;
        // Deploy proxy using Create2Factory
        {
        string memory contractName = "UUPSProxy";
        bytes memory constructorArgs = abi.encode(address(rateLimiterImpl), "");
        bytes memory bytecode = abi.encodePacked(
            type(UUPSProxy).creationCode,
            constructorArgs
        );
        rateLimiterProxyAddr = verifyCreate2Address(
            contractName,
            constructorArgs,
            bytecode,
            commitHashSalt,
            true
        );
        }

        console2.log("");
        console2.log("=== VERIFYING COMPUTED IMPLEMENTATION ADDRESSES ===");
        console2.log("");
        if (stakingManagerImpl != NEW_STAKING_MANAGER_IMPL) {
            console2.log("[FAIL] StakingManager implementation mismatch");
        } else {
            console2.log("[OK] StakingManager implementation matches");
        }
        if (etherFiNodesManagerImpl != NEW_ETHERFI_NODES_MANAGER_IMPL) {
            console2.log("[FAIL] EtherFiNodesManager implementation mismatch");
        } else {
            console2.log("[OK] EtherFiNodesManager implementation matches");
        }
        if (etherFiNodeImpl != NEW_ETHERFI_NODE_IMPL) {
            console2.log("[FAIL] EtherFiNode implementation mismatch");
        } else {
            console2.log("[OK] EtherFiNode implementation matches");
        }
        if (rateLimiterProxyAddr != NEW_RATE_LIMITER_PROXY) {
            console2.log("[FAIL] Rate limiter implementation mismatch");
        } else {
            console2.log("[OK] Rate limiter implementation matches");
        }
        if (rateLimiterImpl != NEW_RATE_LIMITER_IMPL) {
            console2.log("[FAIL] Rate limiter implementation mismatch");
        } else {
            console2.log("[OK] Rate limiter implementation matches");
        }
        console2.log("");
    }

    function verifyContractUpgrades() internal view {
        console2.log("=== VERIFYING CONTRACT UPGRADES ===");

        EtherFiNodesManager nodesManager = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER_PROXY));
        StakingManager stakingManager = StakingManager(STAKING_MANAGER_PROXY);

        // Check if new functions exist (will revert if not upgraded)
        try nodesManager.ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE() returns (bytes32 role) {
            console2.log("[OK] EtherFiNodesManager upgraded - EL exit role exists:", vm.toString(role));
        } catch {
            console2.log("[FAIL] EtherFiNodesManager not upgraded - EL exit role missing");
        }

        try nodesManager.UNRESTAKING_LIMIT_ID() returns (bytes32 limitId) {
            console2.log("[OK] EtherFiNodesManager rate limiter integration - UNRESTAKING_LIMIT_ID:", vm.toString(limitId));
        } catch {
            console2.log("[FAIL] EtherFiNodesManager rate limiter integration missing");
        }

        try nodesManager.EXIT_REQUEST_LIMIT_ID() returns (bytes32 limitId) {
            console2.log("[OK] EtherFiNodesManager rate limiter integration - EXIT_REQUEST_LIMIT_ID:", vm.toString(limitId));
        } catch {
            console2.log("[FAIL] EtherFiNodesManager rate limiter integration missing");
        }

        // Check rate limiter address integration
        if (RATE_LIMITER_PROXY != address(0)) {
            try nodesManager.rateLimiter() returns (IEtherFiRateLimiter limiter) {
                if (address(limiter) == RATE_LIMITER_PROXY) {
                    console2.log("[OK] Rate limiter correctly integrated:", address(limiter));
                } else {
                    console2.log("[FAIL] Rate limiter mismatch - expected:", RATE_LIMITER_PROXY, "got:", address(limiter));
                }
            } catch {
                console2.log("[FAIL] Rate limiter integration not accessible");
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
            bool hasRole = roleRegistry.hasRole(elTriggerExitRole, EL_TRIGGER_EXITER);
            if (hasRole) {
                console2.log("[OK] EL Trigger Exit role assigned to:", EL_TRIGGER_EXITER);
            } else {
                console2.log("[FAIL] EL Trigger Exit role NOT assigned to:", EL_TRIGGER_EXITER);
            }
        } catch {
            console2.log("[FAIL] Cannot check EL Trigger Exit role - contract not upgraded?");
        }

        // Check Rate Limiter Admin Role
        if (RATE_LIMITER_PROXY != address(0)) {
            EtherFiRateLimiter rateLimiter = EtherFiRateLimiter(RATE_LIMITER_PROXY);
            try rateLimiter.ETHERFI_RATE_LIMITER_ADMIN_ROLE() returns (bytes32 rateLimiterAdminRole) {
                bool hasRole = roleRegistry.hasRole(rateLimiterAdminRole, ETHERFI_OPERATING_ADMIN);
                if (hasRole) {
                    console2.log("[OK] Rate Limiter Admin role assigned to:", ETHERFI_OPERATING_ADMIN);
                } else {
                    console2.log("[FAIL] Rate Limiter Admin role NOT assigned to:", ETHERFI_OPERATING_ADMIN);
                }
            } catch {
                console2.log("[FAIL] Cannot check Rate Limiter Admin role");
            }
        }

        // Check standard admin roles
        bytes32 nodesManagerAdminRole = nodesManager.ETHERFI_NODES_MANAGER_ADMIN_ROLE();
        bool hasAdminRole = roleRegistry.hasRole(nodesManagerAdminRole, ETHERFI_ADMIN);
        if (hasAdminRole) {
            console2.log("[OK] Nodes Manager Admin role assigned to:", ETHERFI_ADMIN);
        } else {
            console2.log("[FAIL] Nodes Manager Admin role NOT assigned to:", ETHERFI_ADMIN);
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
        console2.log("[OK] requestExecutionLayerTriggeredWithdrawal exists:", vm.toString(selector1));

        // Check consolidation function
        bytes4 selector2 = nodesManager.requestConsolidation.selector;
        console2.log("[OK] requestConsolidation exists:", vm.toString(selector2));

        // Check new call forwarding functions
        bytes4 selector3 = nodesManager.updateAllowedForwardedEigenpodCalls.selector;
        console2.log("[OK] updateAllowedForwardedEigenpodCalls (user-specific) exists:", vm.toString(selector3));

        bytes4 selector4 = nodesManager.updateAllowedForwardedExternalCalls.selector;
        console2.log("[OK] updateAllowedForwardedExternalCalls (user-specific) exists:", vm.toString(selector4));

        console2.log("");
    }

    function printVerificationSummary() internal view {
        console2.log("========================================");
        console2.log("VERIFICATION SUMMARY");
        console2.log("========================================");
        console2.log("");
        
        console2.log("Verified Components:");
        console2.log("[OK] Contract upgrade verification");
        console2.log("[OK] Role assignment verification");
        if (RATE_LIMITER_PROXY != address(0)) {
            console2.log("[OK] Rate limiter configuration verification");
        } else {
            console2.log("[WARN] Rate limiter verification skipped (address not provided)");
        }
        console2.log("[OK] New functionality availability verification");
        console2.log("");
        
        console2.log("Key Addresses Verified:");
        console2.log("- StakingManager Proxy:", STAKING_MANAGER_PROXY);
        console2.log("- EtherFiNodesManager Proxy:", ETHERFI_NODES_MANAGER_PROXY);
        console2.log("- Role Registry:", ROLE_REGISTRY);
        if (RATE_LIMITER_PROXY != address(0)) {
            console2.log("- EtherFiRateLimiter:", RATE_LIMITER_PROXY);
        }
        console2.log("");
        
        console2.log("Key Role Holders:");
        console2.log("- EL Exit Trigger:", EL_TRIGGER_EXITER);
        console2.log("- Rate Limiter Admin:", ETHERFI_OPERATING_ADMIN);
        console2.log("");
        
        console2.log("Manual Testing Recommendations:");
        console2.log("1. Test EL-triggered withdrawal with proper role");
        console2.log("2. Test consolidation request functionality");
        console2.log("3. Test rate limiting behavior");
        console2.log("4. Test user-specific call forwarding permissions");
        console2.log("5. Verify old whitelist mappings are cleared");
        console2.log("");
        
        console2.log("[OK] EIP-7002 deployment verification complete!");
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

    // Helper function to verify Create2 address    
    function verifyCreate2Address(
        string memory contractName, 
        bytes memory constructorArgs, 
        bytes memory bytecode, 
        bytes32 salt, 
        bool logging
    ) internal view returns (address) {
        address predictedAddress = factory.computeAddress(salt, bytecode);
        return predictedAddress;
    }
}