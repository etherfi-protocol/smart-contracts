// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import {EtherFiTimelock} from "../../../src/EtherFiTimelock.sol";
import {RoleRegistry} from "../../../src/RoleRegistry.sol";
import {Deployed} from "../../deploys/Deployed.s.sol";
import {Utils} from "../../utils/utils.sol";

/// @title UpdateTimelockDelays
/// @notice Raises the min delays on both etherFi timelocks:
///           UPGRADE_TIMELOCK   -> 10 days (signed by ETHERFI_UPGRADE_ADMIN)
///           OPERATING_TIMELOCK ->  2 days (signed by ETHERFI_OPERATING_ADMIN)
///         Generates Gnosis Safe JSONs per timelock (schedule + execute) and
///         then simulates the full schedule -> wait -> execute flow on a fork
///         plus the post-change enforcement check on the upgrade timelock.
///
/// @dev Run: forge script script/operations/timelock/UpdateTimelockDelays.s.sol --fork-url $MAINNET_RPC_URL -vvvv
contract UpdateTimelockDelays is Script, Deployed, Utils {
    EtherFiTimelock constant etherFiUpgradeTimelock = EtherFiTimelock(payable(UPGRADE_TIMELOCK));
    EtherFiTimelock constant etherFiOperatingTimelock = EtherFiTimelock(payable(OPERATING_TIMELOCK));
    RoleRegistry constant roleRegistry = RoleRegistry(ROLE_REGISTRY);

    uint256 constant NEW_UPGRADE_DELAY = 10 days;
    uint256 constant NEW_OPERATING_DELAY = 2 days;

    // Deterministic salts so the pre-computed execute call resolves to the
    // same operation id produced by the schedule call.
    bytes32 constant UPGRADE_SALT =
        keccak256("UpdateTimelockDelays.UPGRADE_TIMELOCK.v1");
    bytes32 constant OPERATING_SALT =
        keccak256("UpdateTimelockDelays.OPERATING_TIMELOCK.v1");

    string constant OUT_DIR = "script/operations/timelock";

    // OZ TimelockController v4.x role identifiers.
    bytes32 constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    bytes32 constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");

    // Real EtherFiNodesManager role used to exercise a RoleRegistry.grantRole
    // path through the upgrade timelock after the delay change.
    bytes32 constant ETHERFI_NODES_MANAGER_POD_PROVER_ROLE =
        keccak256("ETHERFI_NODES_MANAGER_POD_PROVER_ROLE");

    function run() public {
        console2.log("=== UPGRADE TIMELOCK ===");
        _generateTimelockTxns(
            etherFiUpgradeTimelock,
            UPGRADE_TIMELOCK,
            ETHERFI_UPGRADE_ADMIN,
            NEW_UPGRADE_DELAY,
            UPGRADE_SALT,
            "schedule-upgrade-timelock-delay.json",
            "execute-upgrade-timelock-delay.json"
        );
        console2.log("=== OPERATING TIMELOCK ===");
        _generateTimelockTxns(
            etherFiOperatingTimelock,
            OPERATING_TIMELOCK,
            ETHERFI_OPERATING_ADMIN,
            NEW_OPERATING_DELAY,
            OPERATING_SALT,
            "schedule-operating-timelock-delay.json",
            "execute-operating-timelock-delay.json"
        );

        runFork();
    }

    // ---------------------------------------------------------------------
    // Safe JSON + calldata generation
    // ---------------------------------------------------------------------

    function _generateTimelockTxns(
        EtherFiTimelock tl,
        address timelockAddr,
        address safe,
        uint256 newDelay,
        bytes32 salt,
        string memory scheduleFile,
        string memory executeFile
    ) internal {
        uint256 currentDelay = tl.getMinDelay();

        // Inner call: timelock.updateDelay(newDelay). TimelockController
        // enforces `msg.sender == address(this)` on updateDelay, so this must
        // reach the timelock via schedule/execute.
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = timelockAddr;
        values[0] = 0;
        data[0] = abi.encodeWithSelector(TimelockController.updateDelay.selector, newDelay);

        // Outer calls: Safe -> timelock.scheduleBatch / executeBatch
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            tl.scheduleBatch.selector, targets, values, data, bytes32(0), salt, currentDelay
        );
        bytes memory executeCalldata = abi.encodeWithSelector(
            tl.executeBatch.selector, targets, values, data, bytes32(0), salt
        );

        _logCalldata(timelockAddr, safe, currentDelay, newDelay, salt, scheduleCalldata, executeCalldata, data[0]);

        writeSafeJson(OUT_DIR, scheduleFile, safe, timelockAddr, 0, scheduleCalldata, 1);
        writeSafeJson(OUT_DIR, executeFile, safe, timelockAddr, 0, executeCalldata, 1);
    }

    function _logCalldata(
        address timelockAddr,
        address safe,
        uint256 currentDelay,
        uint256 newDelay,
        bytes32 salt,
        bytes memory scheduleCalldata,
        bytes memory executeCalldata,
        bytes memory innerCall
    ) internal pure {
        console2.log("Timelock:", timelockAddr);
        console2.log("Safe:", safe);
        console2.log("Current minDelay (s):", currentDelay);
        console2.log("New     minDelay (s):", newDelay);
        console2.log("Schedule call to:", timelockAddr);
        console2.logBytes(scheduleCalldata);
        console2.log("Execute call to:", timelockAddr);
        console2.logBytes(executeCalldata);
        console2.log("Inner updateDelay call:");
        console2.logBytes(innerCall);
        console2.log("Salt:");
        console2.logBytes32(salt);
        console2.log("");
    }

    // ---------------------------------------------------------------------
    // fork simulation
    // ---------------------------------------------------------------------

    /// @notice Simulate the full schedule -> wait -> execute flow for both
    ///         timelocks, assert invariants, then exercise the new 10 day
    ///         floor on the upgrade timelock via a real RoleRegistry grant.
    function runFork() public {
        string memory forkUrl = vm.envString("MAINNET_RPC_URL");
        vm.selectFork(vm.createFork(forkUrl));

        console2.log("=== SIMULATING ON FORK ===");
        console2.log("Upgrade minDelay before:  ", etherFiUpgradeTimelock.getMinDelay());
        console2.log("Operating minDelay before:", etherFiOperatingTimelock.getMinDelay());

        // Preconditions: the safes must hold PROPOSER and EXECUTOR roles,
        // otherwise the simulated prank would be silently unauthorised.
        require(
            etherFiUpgradeTimelock.hasRole(PROPOSER_ROLE, ETHERFI_UPGRADE_ADMIN) &&
                etherFiUpgradeTimelock.hasRole(EXECUTOR_ROLE, ETHERFI_UPGRADE_ADMIN),
            "upgrade safe missing proposer/executor"
        );
        require(
            etherFiOperatingTimelock.hasRole(PROPOSER_ROLE, ETHERFI_OPERATING_ADMIN) &&
                etherFiOperatingTimelock.hasRole(EXECUTOR_ROLE, ETHERFI_OPERATING_ADMIN),
            "operating safe missing proposer/executor"
        );

        // Snapshot everything that must remain unchanged.
        address preRegistryOwner = roleRegistry.owner();
        bool preUpgradeSafeProposer = etherFiUpgradeTimelock.hasRole(PROPOSER_ROLE, ETHERFI_UPGRADE_ADMIN);
        bool preUpgradeSafeExecutor = etherFiUpgradeTimelock.hasRole(EXECUTOR_ROLE, ETHERFI_UPGRADE_ADMIN);
        bool preUpgradeSafeCanceller = etherFiUpgradeTimelock.hasRole(CANCELLER_ROLE, ETHERFI_UPGRADE_ADMIN);
        bool preUpgradeSelfAdmin = etherFiUpgradeTimelock.hasRole(TIMELOCK_ADMIN_ROLE, UPGRADE_TIMELOCK);
        bool preOperatingSafeProposer = etherFiOperatingTimelock.hasRole(PROPOSER_ROLE, ETHERFI_OPERATING_ADMIN);
        bool preOperatingSafeExecutor = etherFiOperatingTimelock.hasRole(EXECUTOR_ROLE, ETHERFI_OPERATING_ADMIN);
        bool preOperatingSafeCanceller = etherFiOperatingTimelock.hasRole(CANCELLER_ROLE, ETHERFI_OPERATING_ADMIN);
        bool preOperatingSelfAdmin = etherFiOperatingTimelock.hasRole(TIMELOCK_ADMIN_ROLE, OPERATING_TIMELOCK);

        // Simulate each delay change.
        _simulateUpdateDelay(
            etherFiUpgradeTimelock,
            UPGRADE_TIMELOCK,
            ETHERFI_UPGRADE_ADMIN,
            NEW_UPGRADE_DELAY
        );
        _simulateUpdateDelay(
            etherFiOperatingTimelock,
            OPERATING_TIMELOCK,
            ETHERFI_OPERATING_ADMIN,
            NEW_OPERATING_DELAY
        );

        console2.log("Upgrade minDelay after:   ", etherFiUpgradeTimelock.getMinDelay());
        console2.log("Operating minDelay after: ", etherFiOperatingTimelock.getMinDelay());

        require(
            etherFiUpgradeTimelock.getMinDelay() == NEW_UPGRADE_DELAY,
            "upgrade delay not 10 days"
        );
        require(
            etherFiOperatingTimelock.getMinDelay() == NEW_OPERATING_DELAY,
            "operating delay not 2 days"
        );

        // Roles and RoleRegistry ownership unchanged.
        require(
            etherFiUpgradeTimelock.hasRole(PROPOSER_ROLE, ETHERFI_UPGRADE_ADMIN) == preUpgradeSafeProposer,
            "upgrade proposer changed"
        );
        require(
            etherFiUpgradeTimelock.hasRole(EXECUTOR_ROLE, ETHERFI_UPGRADE_ADMIN) == preUpgradeSafeExecutor,
            "upgrade executor changed"
        );
        require(
            etherFiUpgradeTimelock.hasRole(CANCELLER_ROLE, ETHERFI_UPGRADE_ADMIN) == preUpgradeSafeCanceller,
            "upgrade canceller changed"
        );
        require(
            etherFiUpgradeTimelock.hasRole(TIMELOCK_ADMIN_ROLE, UPGRADE_TIMELOCK) == preUpgradeSelfAdmin,
            "upgrade self-admin changed"
        );
        require(
            etherFiOperatingTimelock.hasRole(PROPOSER_ROLE, ETHERFI_OPERATING_ADMIN) == preOperatingSafeProposer,
            "operating proposer changed"
        );
        require(
            etherFiOperatingTimelock.hasRole(EXECUTOR_ROLE, ETHERFI_OPERATING_ADMIN) == preOperatingSafeExecutor,
            "operating executor changed"
        );
        require(
            etherFiOperatingTimelock.hasRole(CANCELLER_ROLE, ETHERFI_OPERATING_ADMIN) == preOperatingSafeCanceller,
            "operating canceller changed"
        );
        require(
            etherFiOperatingTimelock.hasRole(TIMELOCK_ADMIN_ROLE, OPERATING_TIMELOCK) == preOperatingSelfAdmin,
            "operating self-admin changed"
        );
        require(roleRegistry.owner() == preRegistryOwner, "role registry owner changed");

        // Exercise the new 10 day floor using a real role grant.
        _simulate10DayEnforcementOnUpgradeTimelock();

        console2.log("");
        console2.log("[OK] All delay updates simulated and verified on fork.");
    }

    function _simulateUpdateDelay(
        EtherFiTimelock tl,
        address timelockAddr,
        address safe,
        uint256 newDelay
    ) internal {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = timelockAddr;
        values[0] = 0;
        data[0] = abi.encodeWithSelector(TimelockController.updateDelay.selector, newDelay);

        bytes32 salt = keccak256(abi.encode("sim.updateDelay", timelockAddr, newDelay));
        uint256 currentDelay = tl.getMinDelay();

        vm.startPrank(safe);
        tl.scheduleBatch(targets, values, data, bytes32(0), salt, currentDelay);
        vm.warp(block.timestamp + currentDelay + 1);
        tl.executeBatch(targets, values, data, bytes32(0), salt);
        vm.stopPrank();
    }

    function _simulate10DayEnforcementOnUpgradeTimelock() internal {
        require(
            etherFiUpgradeTimelock.getMinDelay() == NEW_UPGRADE_DELAY,
            "enforcement precondition: delay not 10 days"
        );
        require(
            roleRegistry.owner() == UPGRADE_TIMELOCK,
            "upgrade timelock must own RoleRegistry"
        );

        address grantee = vm.addr(0xBEEF);
        require(
            !roleRegistry.hasRole(ETHERFI_NODES_MANAGER_POD_PROVER_ROLE, grantee),
            "grantee already has POD_PROVER_ROLE"
        );

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = ROLE_REGISTRY;
        values[0] = 0;
        data[0] = abi.encodeWithSelector(
            RoleRegistry.grantRole.selector,
            ETHERFI_NODES_MANAGER_POD_PROVER_ROLE,
            grantee
        );
        bytes32 salt = keccak256("sim.upgrade-timelock-delay-enforcement");

        console2.log("");
        console2.log("--- 10-day floor enforcement ---");

        // 1. Scheduling with a delay below the new minimum reverts.
        vm.prank(ETHERFI_UPGRADE_ADMIN);
        vm.expectRevert(bytes("TimelockController: insufficient delay"));
        etherFiUpgradeTimelock.scheduleBatch(
            targets,
            values,
            data,
            bytes32(0),
            salt,
            NEW_UPGRADE_DELAY - 1
        );
        console2.log("schedule(delay=10d - 1) correctly reverted");

        // 2. Scheduling with delay == 10 days succeeds.
        uint256 scheduledAt = block.timestamp;
        vm.prank(ETHERFI_UPGRADE_ADMIN);
        etherFiUpgradeTimelock.scheduleBatch(
            targets,
            values,
            data,
            bytes32(0),
            salt,
            NEW_UPGRADE_DELAY
        );
        console2.log("schedule(delay=10d) succeeded");

        // 3. Executing before 10 days reverts.
        vm.prank(ETHERFI_UPGRADE_ADMIN);
        vm.expectRevert(bytes("TimelockController: operation is not ready"));
        etherFiUpgradeTimelock.executeBatch(targets, values, data, bytes32(0), salt);

        vm.warp(scheduledAt + NEW_UPGRADE_DELAY - 1);
        vm.prank(ETHERFI_UPGRADE_ADMIN);
        vm.expectRevert(bytes("TimelockController: operation is not ready"));
        etherFiUpgradeTimelock.executeBatch(targets, values, data, bytes32(0), salt);
        console2.log("execute() correctly reverted before t + 10d");

        // 4. Exactly 10 days after schedule -> executes and the grantRole
        //    side-effect is visible on the registry.
        vm.warp(scheduledAt + NEW_UPGRADE_DELAY);
        vm.prank(ETHERFI_UPGRADE_ADMIN);
        etherFiUpgradeTimelock.executeBatch(targets, values, data, bytes32(0), salt);
        require(
            roleRegistry.hasRole(ETHERFI_NODES_MANAGER_POD_PROVER_ROLE, grantee),
            "grantRole did not apply"
        );
        console2.log("execute() at t + 10d succeeded; POD_PROVER_ROLE granted");
    }
}
