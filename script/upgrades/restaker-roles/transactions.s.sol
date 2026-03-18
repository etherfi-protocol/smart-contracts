// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {Utils} from "../../utils/utils.sol";
import {EtherFiTimelock} from "../../../src/EtherFiTimelock.sol";
import {EtherFiRestaker} from "../../../src/EtherFiRestaker.sol";
import {IRoleRegistry} from "../../../src/interfaces/IRoleRegistry.sol";
import {ContractCodeChecker} from "../../../script/ContractCodeChecker.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title RestakerRolesTransactions
 * @notice Schedules and executes the EtherFiRestaker upgrade that introduces per-function roles,
 *         then grants the new roles to ETHERFI_OPERATING_ADMIN
 *
 * New roles (grant via RoleRegistry after upgrade):
 *   ETHERFI_RESTAKER_STETH_CLAIM_WITHDRAWALS_ROLE    -> stEthClaimWithdrawals
 *   ETHERFI_RESTAKER_STETH_REQUEST_WITHDRAWAL_ROLE   -> stEthRequestWithdrawal
 *   ETHERFI_RESTAKER_QUEUE_WITHDRAWALS_ROLE          -> queueWithdrawals
 *   ETHERFI_RESTAKER_COMPLETE_QUEUED_WITHDRAWALS_ROLE -> completeQueuedWithdrawals
 *   ETHERFI_RESTAKER_DEPOSIT_INTO_STRATEGY_ROLE       -> depositIntoStrategy
 * Run:
 * forge script script/upgrades/restaker-roles/transactions.s.sol --fork-url $MAINNET_RPC_URL -vvvv
 */
contract RestakerRolesTransactions is Utils {
    EtherFiTimelock etherFiTimelock = EtherFiTimelock(payable(UPGRADE_TIMELOCK));
    ContractCodeChecker contractCodeChecker;

    // TODO: fill in after running deploy.s.sol
    address constant etherFiRestakerImpl = address(0);

    bytes32 constant commitHashSalt = keccak256("restaker-roles-v1"); // TODO: fill in after audit

    address internal preRestakerOwner;

    function run() public {
        console2.log("================================================");
        console2.log("=== EtherFiRestaker Roles Upgrade ==============");
        console2.log("================================================");
        console2.log("");

        require(etherFiRestakerImpl != address(0), "Set etherFiRestakerImpl before running");

        contractCodeChecker = new ContractCodeChecker();

        verifyDeployedBytecode();
        takePreUpgradeSnapshots();
        executeUpgrade();
        verifyUpgrade();
        verifyAccessControlPreservation();

        console2.log("=== Upgrade Complete ===");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- BYTECODE VERIFICATION --------------------------------
    //--------------------------------------------------------------------------------------
    function verifyDeployedBytecode() public {
        console2.log("=== Verifying Deployed Bytecode ===");

        EtherFiRestaker expected = new EtherFiRestaker(
            address(EIGENLAYER_REWARDS_COORDINATOR),
            address(ETHERFI_REDEMPTION_MANAGER),
            address(ROLE_REGISTRY)
        );
        contractCodeChecker.verifyContractByteCodeMatch(etherFiRestakerImpl, address(expected));

        console2.log("Bytecode verification passed!");
        console2.log("================================================");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- PRE-UPGRADE SNAPSHOTS --------------------------------
    //--------------------------------------------------------------------------------------
    function takePreUpgradeSnapshots() internal {
        console2.log("=== Taking Pre-Upgrade Snapshots ===");

        preRestakerOwner = _getOwner(ETHERFI_RESTAKER);
        console2.log("  EtherFiRestaker owner:", preRestakerOwner);

        console2.log("================================================");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- EXECUTE UPGRADE --------------------------------------
    //--------------------------------------------------------------------------------------
    function executeUpgrade() public {
        console2.log("=== Executing Upgrade ===");

        EtherFiRestaker restaker = EtherFiRestaker(payable(ETHERFI_RESTAKER));
        bytes32 claimRole = restaker.ETHERFI_RESTAKER_STETH_CLAIM_WITHDRAWALS_ROLE();
        bytes32 requestRole = restaker.ETHERFI_RESTAKER_STETH_REQUEST_WITHDRAWAL_ROLE();
        bytes32 queueRole = restaker.ETHERFI_RESTAKER_QUEUE_WITHDRAWALS_ROLE();
        bytes32 completeRole = restaker.ETHERFI_RESTAKER_COMPLETE_QUEUED_WITHDRAWALS_ROLE();
        bytes32 depositRole = restaker.ETHERFI_RESTAKER_DEPOSIT_INTO_STRATEGY_ROLE();

        address[] memory targets = new address[](6);
        bytes[] memory data = new bytes[](targets.length);
        uint256[] memory values = new uint256[](targets.length);

        targets[0] = ETHERFI_RESTAKER;
        data[0] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, etherFiRestakerImpl);
        targets[1] = ROLE_REGISTRY;
        data[1] = abi.encodeWithSelector(IRoleRegistry.grantRole.selector, claimRole, ETHERFI_OPERATING_ADMIN);
        targets[2] = ROLE_REGISTRY;
        data[2] = abi.encodeWithSelector(IRoleRegistry.grantRole.selector, requestRole, ETHERFI_OPERATING_ADMIN);
        targets[3] = ROLE_REGISTRY;
        data[3] = abi.encodeWithSelector(IRoleRegistry.grantRole.selector, queueRole, ETHERFI_OPERATING_ADMIN);
        targets[4] = ROLE_REGISTRY;
        data[4] = abi.encodeWithSelector(IRoleRegistry.grantRole.selector, completeRole, ETHERFI_OPERATING_ADMIN);
        targets[5] = ROLE_REGISTRY;
        data[5] = abi.encodeWithSelector(IRoleRegistry.grantRole.selector, depositRole, ETHERFI_OPERATING_ADMIN);

        bytes32 timelockSalt = keccak256(abi.encode(targets, data, commitHashSalt, block.number));

        // Schedule transaction (for Gnosis Safe)
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherFiTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0),
            timelockSalt,
            MIN_DELAY_TIMELOCK
        );
        writeSafeJson(
            "script/upgrades/restaker-roles",
            "restaker-roles-upgrade-schedule.json",
            ETHERFI_UPGRADE_ADMIN,
            UPGRADE_TIMELOCK,
            0,
            scheduleCalldata,
            1
        );

        // Execute transaction (for Gnosis Safe)
        bytes memory executeCalldata = abi.encodeWithSelector(
            etherFiTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0),
            timelockSalt
        );
        writeSafeJson(
            "script/upgrades/restaker-roles",
            "restaker-roles-upgrade-execute.json",
            ETHERFI_UPGRADE_ADMIN,
            UPGRADE_TIMELOCK,
            0,
            executeCalldata,
            1
        );

        // Execute on fork for testing
        console2.log("=== Scheduling on Fork ===");
        vm.prank(ETHERFI_UPGRADE_ADMIN);
        etherFiTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_TIMELOCK);

        vm.warp(block.timestamp + MIN_DELAY_TIMELOCK + 1);

        console2.log("=== Executing on Fork ===");
        vm.prank(ETHERFI_UPGRADE_ADMIN);
        etherFiTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);

        console2.log("Upgrade executed on fork!");
        console2.log("================================================");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- VERIFY UPGRADE ---------------------------------------
    //--------------------------------------------------------------------------------------
    function verifyUpgrade() public view {
        console2.log("=== Verifying Upgrade ===");

        address currentImpl = getImplementation(ETHERFI_RESTAKER);
        require(currentImpl == etherFiRestakerImpl, "EtherFiRestaker upgrade failed");
        console2.log("EtherFiRestaker implementation:", currentImpl);

        // Verify new role constants are accessible
        EtherFiRestaker restaker = EtherFiRestaker(payable(ETHERFI_RESTAKER));
        bytes32 claimRole = restaker.ETHERFI_RESTAKER_STETH_CLAIM_WITHDRAWALS_ROLE();
        bytes32 requestRole = restaker.ETHERFI_RESTAKER_STETH_REQUEST_WITHDRAWAL_ROLE();
        bytes32 queueRole = restaker.ETHERFI_RESTAKER_QUEUE_WITHDRAWALS_ROLE();
        bytes32 completeRole = restaker.ETHERFI_RESTAKER_COMPLETE_QUEUED_WITHDRAWALS_ROLE();
        bytes32 depositRole = restaker.ETHERFI_RESTAKER_DEPOSIT_INTO_STRATEGY_ROLE();

        require(claimRole == keccak256("ETHERFI_RESTAKER_STETH_CLAIM_WITHDRAWALS_ROLE"), "claimRole mismatch");
        require(requestRole == keccak256("ETHERFI_RESTAKER_STETH_REQUEST_WITHDRAWAL_ROLE"), "requestRole mismatch");
        require(queueRole == keccak256("ETHERFI_RESTAKER_QUEUE_WITHDRAWALS_ROLE"), "queueRole mismatch");
        require(completeRole == keccak256("ETHERFI_RESTAKER_COMPLETE_QUEUED_WITHDRAWALS_ROLE"), "completeRole mismatch");
        require(depositRole == keccak256("ETHERFI_RESTAKER_DEPOSIT_INTO_STRATEGY_ROLE"), "depositRole mismatch");

        // Verify roleRegistry immutable is set correctly
        require(address(restaker.roleRegistry()) == ROLE_REGISTRY, "roleRegistry mismatch");

        // Verify role grants were applied to operating admin
        IRoleRegistry registry = IRoleRegistry(ROLE_REGISTRY);
        require(registry.hasRole(claimRole, ETHERFI_OPERATING_ADMIN), "claimRole not granted");
        require(registry.hasRole(requestRole, ETHERFI_OPERATING_ADMIN), "requestRole not granted");
        require(registry.hasRole(queueRole, ETHERFI_OPERATING_ADMIN), "queueRole not granted");
        require(registry.hasRole(completeRole, ETHERFI_OPERATING_ADMIN), "completeRole not granted");
        require(registry.hasRole(depositRole, ETHERFI_OPERATING_ADMIN), "depositRole not granted");

        console2.log("All role constants verified!");
        console2.log("All role grants verified for ETHERFI_OPERATING_ADMIN!");
        console2.log("================================================");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- ACCESS CONTROL PRESERVATION --------------------------
    //--------------------------------------------------------------------------------------
    function verifyAccessControlPreservation() internal view {
        console2.log("=== Verifying Access Control Preservation ===");

        address postOwner = _getOwner(ETHERFI_RESTAKER);
        require(postOwner == preRestakerOwner, "EtherFiRestaker: owner changed");
        console2.log("[OWNER OK] EtherFiRestaker:", postOwner);

        verifyNotReinitializable(ETHERFI_RESTAKER, "EtherFiRestaker");

        console2.log("Access control preservation checks passed!");
        console2.log("================================================");
    }
}
