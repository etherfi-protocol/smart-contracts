// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../../utils/utils.sol";
import "../../../src/EtherFiTimelock.sol";
import "../../../src/EtherFiRedemptionManager.sol";
import "../../../src/LiquidityPool.sol";
import "../../../src/PriorityWithdrawalQueue.sol";
import "../../../src/RoleRegistry.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {ContractCodeChecker} from "../../../script/ContractCodeChecker.sol";

/// @title PriorityQueueTransactions
/// @notice Generates timelock transactions for upgrading LiquidityPool, EtherFiRedemptionManager, and granting roles for PriorityWithdrawalQueue
/// @dev Run with: forge script script/upgrades/priority-queue/transactionsPriorityQueue.s.sol --fork-url $MAINNET_RPC_URL
contract PriorityQueueTransactions is Script, Utils {
    //--------------------------------------------------------------------------------------
    //------------------------------- EXISTING CONTRACTS -----------------------------------
    //--------------------------------------------------------------------------------------
    EtherFiTimelock etherFiTimelock = EtherFiTimelock(payable(UPGRADE_TIMELOCK));
    RoleRegistry roleRegistryContract = RoleRegistry(ROLE_REGISTRY);
    LiquidityPool liquidityPool = LiquidityPool(payable(LIQUIDITY_POOL));
    EtherFiRedemptionManager etherFiRedemptionManager = EtherFiRedemptionManager(payable(ETHERFI_REDEMPTION_MANAGER));

    //--------------------------------------------------------------------------------------
    //------------------------------- NEW DEPLOYMENTS --------------------------------------
    //--------------------------------------------------------------------------------------
    
    address constant liquidityPoolImpl = 0xD97b8a3A1119a2C30ADaf9605da0b552F359adfe;
    address constant priorityWithdrawalQueueProxy = 0x06fce94d05CC4bC7ff75A210CC3d7FC254362FeE;
    address constant priorityWithdrawalQueueImpl = 0x94190737Ff3540a8990864F41c149159224878A0;
    address constant etherFiRedemptionManagerImpl = 0x61a4df8965926Bd4b2Ddb2c6f67c7B05D5ED2018;
    ContractCodeChecker contractCodeChecker;

    // MIN_DELAY used when deploying PriorityWithdrawalQueue implementation (must match deploy script)
    uint32 constant PWQ_MIN_DELAY = 1 hours;

    //--------------------------------------------------------------------------------------
    //------------------------------- IMMUTABLE SNAPSHOTS (PRE-UPGRADE) -------------------
    //--------------------------------------------------------------------------------------
    ImmutableSnapshot internal preRedemptionManagerImmutables;

    //--------------------------------------------------------------------------------------
    //------------------------------- ACCESS CONTROL SNAPSHOTS (PRE-UPGRADE) --------------
    //--------------------------------------------------------------------------------------
    address internal preLiquidityPoolOwner;
    address internal preRedemptionManagerOwner;

    bool internal preLiquidityPoolPaused;
    bool internal preRedemptionManagerPaused;

    //--------------------------------------------------------------------------------------
    //------------------------------- ROLES ------------------------------------------------
    //--------------------------------------------------------------------------------------

    bytes32 public PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE;
    bytes32 public PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE;
    bytes32 public PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE;

    function run() public {
        console2.log("================================================");
        console2.log("=== Priority Queue Upgrade Transactions ========");
        console2.log("================================================");
        console2.log("");

        contractCodeChecker = new ContractCodeChecker();

        // Get role hashes from the implementation
        PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE = PriorityWithdrawalQueue(payable(priorityWithdrawalQueueImpl)).PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE();
        PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE = PriorityWithdrawalQueue(payable(priorityWithdrawalQueueImpl)).PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE();
        PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE = PriorityWithdrawalQueue(payable(priorityWithdrawalQueueImpl)).PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE();

        // Step 1: Verify deployed bytecode matches expected
        verifyDeployedBytecode();

        // Step 2: Take pre-upgrade snapshots (immutables, access control)
        takePreUpgradeSnapshots();

        // Step 3: Execute upgrade via timelock
        executeUpgrade();

        // Step 4: Verify upgrades were successful
        verifyUpgrades();

        // Step 5: Verify immutables unchanged (and new ones set correctly)
        verifyImmutablePreservation();

        // Step 6: Verify access control preserved
        verifyAccessControlPreservation();

        // Step 7: Fork-level functional tests
        forkTest();
    }

    function executeUpgrade() public {
        console2.log("Generating Upgrade Transactions");
        console2.log("================================================");

        address[] memory targets = new address[](5);
        bytes[] memory data = new bytes[](targets.length);
        uint256[] memory values = new uint256[](targets.length); // Default to 0

        //--------------------------------------------------------------------------------------
        //------------------------------- CONTRACT UPGRADES  -----------------------------------
        //--------------------------------------------------------------------------------------
        
        // Upgrade LiquidityPool to new implementation with priorityWithdrawalQueue support
        targets[0] = LIQUIDITY_POOL;
        data[0] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, liquidityPoolImpl);

        // Upgrade EtherFiRedemptionManager to new implementation
        targets[1] = ETHERFI_REDEMPTION_MANAGER;
        data[1] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, etherFiRedemptionManagerImpl);

        //--------------------------------------------------------------------------------------
        //---------------------------------- Grant Roles ---------------------------------------
        //--------------------------------------------------------------------------------------
        console2.log("PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE:", vm.toString(PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE));
        console2.log("PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE:", vm.toString(PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE));
        console2.log("PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE:", vm.toString(PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE));

        // Grant PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE to ADMIN_EOA
        targets[2] = ROLE_REGISTRY;
        data[2] = _encodeRoleGrant(
            PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE,
            ETHERFI_OPERATING_ADMIN
        );

        // Grant PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE to ADMIN_EOA
        targets[3] = ROLE_REGISTRY;
        data[3] = _encodeRoleGrant(
            PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE,
            ETHERFI_OPERATING_ADMIN
        );

        // Grant PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE to ADMIN_EOA
        targets[4] = ROLE_REGISTRY;
        data[4] = _encodeRoleGrant(
            PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE,
            ADMIN_EOA
        );

        bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));

        // Generate schedule calldata
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherFiTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt,
            MIN_DELAY_TIMELOCK // 72 hours
        );

        console2.log("================================================");
        console2.log("Timelock Address:", address(etherFiTimelock));
        console2.log("================================================");
        console2.log("");

        console2.log("Schedule Tx (call from UPGRADE_ADMIN):");
        console2.logBytes(scheduleCalldata);
        console2.log("================================================");
        console2.log("");

        // Generate execute calldata
        bytes memory executeCalldata = abi.encodeWithSelector(
            etherFiTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt
        );
        console2.log("Execute Tx (after 72 hours):");
        console2.logBytes(executeCalldata);
        console2.log("================================================");
        console2.log("");

        // Log individual transactions for clarity
        console2.log("Transaction Details:");
        console2.log("--------------------");
        console2.log("1. Upgrade LiquidityPool to:", liquidityPoolImpl);
        console2.log("2. Upgrade EtherFiRedemptionManager to:", etherFiRedemptionManagerImpl);
        console2.log("3. Grant PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE to:", ETHERFI_OPERATING_ADMIN);
        console2.log("4. Grant PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE to:", ETHERFI_OPERATING_ADMIN);
        console2.log("5. Grant PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE to:", ADMIN_EOA);
        console2.log("================================================");
        console2.log("");

        // Execute on fork for testing
        console2.log("=== SCHEDULING BATCH ON FORK ===");
        vm.startPrank(ETHERFI_UPGRADE_ADMIN);
        etherFiTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_TIMELOCK);

        vm.warp(block.timestamp + MIN_DELAY_TIMELOCK + 1);
        etherFiTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
        vm.stopPrank();

        console2.log("Upgrade executed successfully on fork");
        console2.log("================================================");
    }

    function forkTest() public {
        console2.log("Running Fork Tests");
        console2.log("================================================");

        // Verify LiquidityPool upgrade
        address impl = liquidityPool.getImplementation();
        require(impl == liquidityPoolImpl, "LiquidityPool implementation mismatch");
        console2.log("LiquidityPool implementation verified:", impl);

        // Verify priorityWithdrawalQueue is set correctly in LiquidityPool
        address pwq = liquidityPool.priorityWithdrawalQueue();
        require(pwq == priorityWithdrawalQueueProxy, "PriorityWithdrawalQueue address mismatch");
        console2.log("PriorityWithdrawalQueue in LiquidityPool:", pwq);

        // Verify roles granted
        require(
            roleRegistryContract.hasRole(PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE, ETHERFI_OPERATING_ADMIN),
            "ETHERFI_OPERATING_ADMIN does not have PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE"
        );
        console2.log("PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE granted to ETHERFI_OPERATING_ADMIN");

        require(
            roleRegistryContract.hasRole(PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE, ETHERFI_OPERATING_ADMIN),
            "ETHERFI_OPERATING_ADMIN does not have PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE"
        );
        console2.log("PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE granted to ETHERFI_OPERATING_ADMIN");

        require(
            roleRegistryContract.hasRole(PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE, ADMIN_EOA),
            "ADMIN_EOA does not have PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE"
        );
        console2.log("PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE granted to ADMIN_EOA");

        // Test PriorityWithdrawalQueue is accessible via proxy
        PriorityWithdrawalQueue pwqContract = PriorityWithdrawalQueue(payable(priorityWithdrawalQueueProxy));
        require(address(pwqContract.liquidityPool()) == LIQUIDITY_POOL, "LiquidityPool reference mismatch in PriorityWithdrawalQueue");
        console2.log("PriorityWithdrawalQueue liquidityPool reference verified");

        console2.log("");
        console2.log("All fork tests passed!");
        console2.log("================================================");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- BYTECODE VERIFICATION --------------------------------
    //--------------------------------------------------------------------------------------
    function verifyDeployedBytecode() public {
        console2.log("=== Verifying Deployed Bytecode ===");
        console2.log("");

        LiquidityPool newLiquidityPoolImpl = new LiquidityPool(priorityWithdrawalQueueProxy);
        PriorityWithdrawalQueue newPWQImpl = new PriorityWithdrawalQueue(
            LIQUIDITY_POOL, EETH, ROLE_REGISTRY, TREASURY, PWQ_MIN_DELAY
        );
        EtherFiRedemptionManager newRedemptionManagerImpl = new EtherFiRedemptionManager(
            LIQUIDITY_POOL, EETH, WEETH, TREASURY, ROLE_REGISTRY, ETHERFI_RESTAKER, priorityWithdrawalQueueProxy
        );

        contractCodeChecker.verifyContractByteCodeMatch(liquidityPoolImpl, address(newLiquidityPoolImpl));
        contractCodeChecker.verifyContractByteCodeMatch(priorityWithdrawalQueueImpl, address(newPWQImpl));
        contractCodeChecker.verifyContractByteCodeMatch(etherFiRedemptionManagerImpl, address(newRedemptionManagerImpl));

        console2.log("");
        console2.log("All bytecode verifications passed!");
        console2.log("================================================");
        console2.log("");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- IMMUTABLE SELECTOR DEFINITIONS -----------------------
    //--------------------------------------------------------------------------------------

    /// @dev Only selectors present in BOTH old and new EtherFiRedemptionManager implementations.
    ///      Intentionally excludes lido() (removed in new impl) and priorityWithdrawalQueue()
    ///      (new in new impl).
    function getRedemptionManagerImmutableSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = bytes4(keccak256("roleRegistry()"));
        selectors[1] = bytes4(keccak256("treasury()"));
        selectors[2] = bytes4(keccak256("eEth()"));
        selectors[3] = bytes4(keccak256("weEth()"));
        selectors[4] = bytes4(keccak256("liquidityPool()"));
        selectors[5] = bytes4(keccak256("etherFiRestaker()"));
    }

    function getPWQImmutableSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = bytes4(keccak256("liquidityPool()"));
        selectors[1] = bytes4(keccak256("eETH()"));
        selectors[2] = bytes4(keccak256("roleRegistry()"));
        selectors[3] = bytes4(keccak256("treasury()"));
        selectors[4] = bytes4(keccak256("MIN_DELAY()"));
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- PRE-UPGRADE SNAPSHOTS --------------------------------
    //--------------------------------------------------------------------------------------
    function takePreUpgradeSnapshots() internal {
        console2.log("=== Taking Pre-Upgrade Snapshots ===");
        console2.log("");

        console2.log("--- Immutable Snapshots ---");
        preRedemptionManagerImmutables = takeImmutableSnapshot(
            ETHERFI_REDEMPTION_MANAGER,
            getRedemptionManagerImmutableSelectors()
        );
        console2.log(
            "  EtherFiRedemptionManager: captured",
            preRedemptionManagerImmutables.selectors.length,
            "immutables"
        );

        // LiquidityPool has no immutables in the current (pre-upgrade) implementation.
        console2.log("  LiquidityPool: no immutables in pre-upgrade implementation");

        console2.log("");
        console2.log("--- Access Control Snapshots ---");

        preLiquidityPoolOwner = _getOwner(LIQUIDITY_POOL);
        console2.log("  LiquidityPool owner:", preLiquidityPoolOwner);

        preRedemptionManagerOwner = _getOwner(ETHERFI_REDEMPTION_MANAGER);
        console2.log("  EtherFiRedemptionManager owner:", preRedemptionManagerOwner);

        preLiquidityPoolPaused = _getPaused(LIQUIDITY_POOL);
        console2.log("  LiquidityPool paused:", preLiquidityPoolPaused);

        preRedemptionManagerPaused = _getPaused(ETHERFI_REDEMPTION_MANAGER);
        console2.log("  EtherFiRedemptionManager paused:", preRedemptionManagerPaused);

        console2.log("");
        console2.log("Pre-upgrade snapshots captured!");
        console2.log("================================================");
        console2.log("");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- VERIFY UPGRADES --------------------------------------
    //--------------------------------------------------------------------------------------
    function verifyUpgrades() public view {
        console2.log("=== Verifying Upgrades ===");
        console2.log("");

        // 1. LiquidityPool (UUPS)
        {
            address currentImpl = getImplementation(LIQUIDITY_POOL);
            require(currentImpl == liquidityPoolImpl, "LiquidityPool upgrade failed");
            console2.log("LiquidityPool implementation:", currentImpl);
        }

        // 2. EtherFiRedemptionManager (UUPS)
        {
            address currentImpl = getImplementation(ETHERFI_REDEMPTION_MANAGER);
            require(currentImpl == etherFiRedemptionManagerImpl, "EtherFiRedemptionManager upgrade failed");
            console2.log("EtherFiRedemptionManager implementation:", currentImpl);
        }

        // 3. PriorityWithdrawalQueue proxy — verify it points to the expected implementation
        {
            address currentImpl = getImplementation(priorityWithdrawalQueueProxy);
            require(currentImpl == priorityWithdrawalQueueImpl, "PriorityWithdrawalQueue proxy impl mismatch");
            console2.log("PriorityWithdrawalQueue implementation:", currentImpl);
        }

        console2.log("");
        console2.log("All upgrades verified successfully!");
        console2.log("================================================");
        console2.log("");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- IMMUTABLE PRESERVATION VERIFICATION -----------------
    //--------------------------------------------------------------------------------------
    function verifyImmutablePreservation() internal view {
        console2.log("=== Verifying Immutable Preservation ===");
        console2.log("");

        // 1. EtherFiRedemptionManager: check shared immutables are unchanged
        ImmutableSnapshot memory postRedemptionManagerImmutables = takeImmutableSnapshot(
            ETHERFI_REDEMPTION_MANAGER,
            getRedemptionManagerImmutableSelectors()
        );
        verifyImmutablesUnchanged(
            preRedemptionManagerImmutables,
            postRedemptionManagerImmutables,
            "EtherFiRedemptionManager"
        );

        // 2. EtherFiRedemptionManager: new priorityWithdrawalQueue immutable set correctly
        {
            bytes4 sel = bytes4(keccak256("priorityWithdrawalQueue()"));
            (bool ok, bytes memory data) = ETHERFI_REDEMPTION_MANAGER.staticcall(abi.encodeWithSelector(sel));
            require(ok, "EtherFiRedemptionManager: priorityWithdrawalQueue() call failed");
            address pwq = abi.decode(data, (address));
            require(pwq == priorityWithdrawalQueueProxy, "EtherFiRedemptionManager: wrong priorityWithdrawalQueue");
            console2.log("[IMMUTABLES OK] EtherFiRedemptionManager.priorityWithdrawalQueue:", pwq);
        }

        // 3. LiquidityPool: new priorityWithdrawalQueue immutable set correctly
        {
            address pwq = LiquidityPool(payable(LIQUIDITY_POOL)).priorityWithdrawalQueue();
            require(pwq == priorityWithdrawalQueueProxy, "LiquidityPool: wrong priorityWithdrawalQueue immutable");
            console2.log("[IMMUTABLES OK] LiquidityPool.priorityWithdrawalQueue:", pwq);
        }

        // 4. PriorityWithdrawalQueue proxy: did not have anything pre upgrade

        console2.log("");
        console2.log("All immutable preservation checks passed!");
        console2.log("================================================");
        console2.log("");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- ACCESS CONTROL PRESERVATION --------------------------
    //--------------------------------------------------------------------------------------
    function verifyAccessControlPreservation() internal view {
        console2.log("=== Verifying Access Control Preservation ===");
        console2.log("");

        console2.log("--- Owner Verification ---");

        address postLiquidityPoolOwner = _getOwner(LIQUIDITY_POOL);
        require(postLiquidityPoolOwner == preLiquidityPoolOwner, "LiquidityPool: owner changed");
        console2.log("[OWNER OK] LiquidityPool:", postLiquidityPoolOwner);

        address postRedemptionManagerOwner = _getOwner(ETHERFI_REDEMPTION_MANAGER);
        require(postRedemptionManagerOwner == preRedemptionManagerOwner, "EtherFiRedemptionManager: owner changed");
        console2.log("[OWNER OK] EtherFiRedemptionManager:", postRedemptionManagerOwner);

        console2.log("");
        console2.log("--- Paused State Verification ---");

        bool postLiquidityPoolPaused = _getPaused(LIQUIDITY_POOL);
        require(postLiquidityPoolPaused == preLiquidityPoolPaused, "LiquidityPool: paused state changed");
        console2.log("[PAUSED OK] LiquidityPool:", postLiquidityPoolPaused);

        bool postRedemptionManagerPaused = _getPaused(ETHERFI_REDEMPTION_MANAGER);
        require(
            postRedemptionManagerPaused == preRedemptionManagerPaused,
            "EtherFiRedemptionManager: paused state changed"
        );
        console2.log("[PAUSED OK] EtherFiRedemptionManager:", postRedemptionManagerPaused);

        console2.log("");
        console2.log("--- Initialization State Verification ---");

        verifyNotReinitializable(LIQUIDITY_POOL, "LiquidityPool");
        verifyNotReinitializable(ETHERFI_REDEMPTION_MANAGER, "EtherFiRedemptionManager");
        verifyNotReinitializable(priorityWithdrawalQueueProxy, "PriorityWithdrawalQueue");

        console2.log("");
        console2.log("All access control preservation checks passed!");
        console2.log("================================================");
        console2.log("");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- HELPER FUNCTIONS  -----------------------------------
    //--------------------------------------------------------------------------------------

    function _encodeRoleGrant(
        bytes32 role,
        address account
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            RoleRegistry.grantRole.selector,
            role,
            account
        );
    }
}
