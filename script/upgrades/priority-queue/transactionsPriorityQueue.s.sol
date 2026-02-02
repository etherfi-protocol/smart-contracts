// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../../utils/utils.sol";
import "../../../src/EtherFiTimelock.sol";
import "../../../src/LiquidityPool.sol";
import "../../../src/PriorityWithdrawalQueue.sol";
import "../../../src/RoleRegistry.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "forge-std/Script.sol";
import "forge-std/console2.sol";

/// @title PriorityQueueTransactions
/// @notice Generates timelock transactions for upgrading LiquidityPool and granting roles for PriorityWithdrawalQueue
/// @dev Run with: forge script script/upgrades/priority-queue/transactionsPriorityQueue.s.sol --fork-url $MAINNET_RPC_URL
contract PriorityQueueTransactions is Script, Utils {
    //--------------------------------------------------------------------------------------
    //------------------------------- EXISTING CONTRACTS -----------------------------------
    //--------------------------------------------------------------------------------------
    EtherFiTimelock etherFiTimelock = EtherFiTimelock(payable(UPGRADE_TIMELOCK));
    RoleRegistry roleRegistryContract = RoleRegistry(ROLE_REGISTRY);
    LiquidityPool liquidityPool = LiquidityPool(payable(LIQUIDITY_POOL));

    //--------------------------------------------------------------------------------------
    //------------------------------- NEW DEPLOYMENTS --------------------------------------
    //--------------------------------------------------------------------------------------
    
    // TODO: Update these addresses with actual deployed addresses
    address constant liquidityPoolImpl = 0x5598b8c76BA17253459e069041349704c28d33DF;
    address constant priorityWithdrawalQueueProxy = 0x79Eb9c078fA5a5Bd1Ee8ba84937acd48AA5F90A8;
    address constant priorityWithdrawalQueueImpl = 0xB149ce3957370066D7C03e5CA81A7997Fe00cAF6;

    //--------------------------------------------------------------------------------------
    //------------------------------- ROLES ------------------------------------------------
    //--------------------------------------------------------------------------------------
    
    bytes32 public PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE;
    bytes32 public PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE;
    bytes32 public PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE;

    function run() public {
        console2.log("================================================");
        console2.log("Running Priority Queue Transactions");
        console2.log("================================================");
        console2.log("");

        // string memory forkUrl = vm.envString("MAINNET_RPC_URL");
        // vm.selectFork(vm.createFork(forkUrl));

        // Get role hashes from the implementation
        PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE = PriorityWithdrawalQueue(payable(priorityWithdrawalQueueImpl)).PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE();
        PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE = PriorityWithdrawalQueue(payable(priorityWithdrawalQueueImpl)).PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE();
        PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE = PriorityWithdrawalQueue(payable(priorityWithdrawalQueueImpl)).PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE();

        executeUpgrade();
        forkTest();
    }

    function executeUpgrade() public {
        console2.log("Generating Upgrade Transactions");
        console2.log("================================================");

        address[] memory targets = new address[](4);
        bytes[] memory data = new bytes[](4);
        uint256[] memory values = new uint256[](4); // Default to 0

        //--------------------------------------------------------------------------------------
        //------------------------------- CONTRACT UPGRADES  -----------------------------------
        //--------------------------------------------------------------------------------------
        
        // Upgrade LiquidityPool to new implementation with priorityWithdrawalQueue support
        targets[0] = LIQUIDITY_POOL;
        data[0] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, liquidityPoolImpl);

        //--------------------------------------------------------------------------------------
        //---------------------------------- Grant Roles ---------------------------------------
        //--------------------------------------------------------------------------------------
        console2.log("PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE:", vm.toString(PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE));
        console2.log("PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE:", vm.toString(PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE));
        console2.log("PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE:", vm.toString(PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE));

        // Grant PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE to ADMIN_EOA
        targets[1] = ROLE_REGISTRY;
        data[1] = _encodeRoleGrant(
            PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE,
            ETHERFI_OPERATING_ADMIN
        );

        // Grant PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE to ADMIN_EOA
        targets[2] = ROLE_REGISTRY;
        data[2] = _encodeRoleGrant(
            PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE,
            ETHERFI_OPERATING_ADMIN
        );

        // Grant PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE to ADMIN_EOA
        targets[3] = ROLE_REGISTRY;
        data[3] = _encodeRoleGrant(
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
        console2.log("2. Grant PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE to:", ETHERFI_OPERATING_ADMIN);
        console2.log("3. Grant PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE to:", ETHERFI_OPERATING_ADMIN);
        console2.log("4. Grant PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE to:", ADMIN_EOA);
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
            "ADMIN_EOA does not have PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE"
        );
        console2.log("PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE granted to ADMIN_EOA");

        require(
            roleRegistryContract.hasRole(PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE, ETHERFI_OPERATING_ADMIN),
            "ADMIN_EOA does not have PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE"
        );
        console2.log("PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE granted to ADMIN_EOA");

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
