// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {EtherFiTimelock} from "@etherfi/governance/EtherFiTimelock.sol";
import {EtherFiNodesManager} from "@etherfi/staking/EtherFiNodesManager.sol";
import {EtherFiNode} from "@etherfi/staking/EtherFiNode.sol";
import {StakingManager} from "@etherfi/staking/StakingManager.sol";
import {Treasury} from "@etherfi/archive/Treasury.sol";
import {ContractCodeChecker} from "@scripts/ContractCodeChecker.sol";
import {DeployNonEigenPodCreds} from "./deploy.s.sol";

/**
 * @title NonEigenPodCredsTransactions
 * @notice Builds and fork-verifies the governance transactions for the non-EigenPod withdrawal
 *         credentials release (PR #485), plus two pieces of adjacent cleanup.
 *
 * Two independent routings, because the roles sit on different actors:
 *
 *  1. UPGRADE_TIMELOCK batch (10-day delay), proposed by ETHERFI_UPGRADE_ADMIN (6-of-N Safe):
 *       - EtherFiNodesManager.upgradeTo
 *       - StakingManager.upgradeTo
 *       - EtherFiAdmin.upgradeTo
 *       - StakingManager.upgradeEtherFiNode  (beacon; onlyUpgradeTimelock)
 *       - Treasury(legacy).withdraw          (Ownable; owner == UPGRADE_TIMELOCK)
 *     -> run()
 *
 *  2. Direct calls from ETHERFI_OPERATING_ADMIN (4-of-7 Safe), no timelock:
 *       - AvsOperatorManager.adminForwardCall, deregistering ether.fi's AvsOperator proxies from
 *         their EigenLayer AVSs. Gated by OPERATION_MULTISIG_ROLE, which the UPGRADE_TIMELOCK does
 *         NOT hold, so this cannot ride in the batch above.
 *     -> deregisterAvsOperators()
 *
 * command:
 * forge script script/upgrades/non-eigenpod-creds/transactions.s.sol:NonEigenPodCredsTransactions \
 *   --fork-url $MAINNET_RPC_URL -vvvv
 */
contract NonEigenPodCredsTransactions is DeployNonEigenPodCreds {
    // ---------------------------------------------------------------------------------
    // Expected CREATE2 addresses for commitHashSalt. These are what the Safe calldata
    // encodes, so a mismatch against a fresh _deployAll() must halt the script.
    // ---------------------------------------------------------------------------------
    address constant EXPECTED_ETHERFI_NODES_MANAGER_IMPL = 0x020016Fa077515451975712595EB3e984907ad3b;
    address constant EXPECTED_ETHERFI_NODE_IMPL = 0x73Df4a005332525fB0A0B2cf067352a9b706f233;
    address constant EXPECTED_STAKING_MANAGER_IMPL = 0x6515B41BDcf83BE5543B88591BC0bC34d844c9c2;
    address constant EXPECTED_ETHERFI_ADMIN_IMPL = 0x841fA691AA6E30E97c817608F90111701a3D0Ac8;

    EtherFiTimelock constant upgradeTimelock = EtherFiTimelock(payable(UPGRADE_TIMELOCK));

    /// @dev UPGRADE_TIMELOCK.getMinDelay() read on-chain: 864000 == 10 days
    uint256 constant TIMELOCK_MIN_DELAY = 864_000;

    /// @dev TREASURY_LEGACY balance. Only the timelock can withdraw, so the balance can only grow
    ///      and a fixed amount can never over-withdraw. Re-check before generating Safe hashes.
    uint256 constant TREASURY_LEGACY_SWEEP_AMOUNT = 9_712_223_546_514_004_611;

    ContractCodeChecker public contractCodeChecker;

    uint256 internal lpBalanceBefore;

    function run() public override {
        // Stage the fork: CREATE2-deploy the four implementations if they are not on-chain yet, so
        // this simulates cleanly both before and after the real broadcast. Idempotent.
        _deployAll();
        _requireImplsMatchExpected();

        contractCodeChecker = new ContractCodeChecker();

        (address[] memory targets, uint256[] memory values, bytes[] memory data) = _buildUpgradeBatch();
        bytes32 salt = _timelockSalt(targets, data);

        _logUpgradeBatch(targets, values, data, salt);

        lpBalanceBefore = LIQUIDITY_POOL.balance;

        vm.startPrank(ETHERFI_UPGRADE_ADMIN);
        upgradeTimelock.scheduleBatch(targets, values, data, bytes32(0), salt, TIMELOCK_MIN_DELAY);
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);
        upgradeTimelock.executeBatch(targets, values, data, bytes32(0), salt);
        vm.stopPrank();

        console2.log("Upgrade batch executed on fork");
        console2.log("================================================");
        console2.log("");

        verifyDeployedBytecode();
        verifyUpgrades();
        verifyTreasurySweep();
    }

    // ---------------------------------------------------------------------------------
    // Leg 1 - UPGRADE_TIMELOCK batch
    // ---------------------------------------------------------------------------------

    function _buildUpgradeBatch()
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory data)
    {
        targets = new address[](5);
        data = new bytes[](5);
        values = new uint256[](5);

        // EtherFiNodesManager implementation
        targets[0] = ETHERFI_NODES_MANAGER;
        data[0] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, EXPECTED_ETHERFI_NODES_MANAGER_IMPL);

        // StakingManager implementation
        targets[1] = STAKING_MANAGER;
        data[1] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, EXPECTED_STAKING_MANAGER_IMPL);

        // EtherFiAdmin implementation
        targets[2] = ETHERFI_ADMIN;
        data[2] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, EXPECTED_ETHERFI_ADMIN_IMPL);

        // EtherFiNode beacon implementation. Ordered after the StakingManager upgrade so the beacon
        // is repointed by the manager build that ships with it.
        targets[3] = STAKING_MANAGER;
        data[3] = abi.encodeWithSelector(StakingManager.upgradeEtherFiNode.selector, EXPECTED_ETHERFI_NODE_IMPL);

        // Drain the retired Treasury into the LiquidityPool
        targets[4] = TREASURY_LEGACY;
        data[4] = abi.encodeWithSelector(Treasury.withdraw.selector, TREASURY_LEGACY_SWEEP_AMOUNT, LIQUIDITY_POOL);
    }

    /// @dev Fixed, not block-derived: the Safe tx hashes signers reproduce must be stable across
    ///      runs. The timelock only needs the salt to be unique against pending operations.
    bytes32 constant TIMELOCK_SALT = keccak256("etherfi.non-eigenpod-creds.pr485");

    function _timelockSalt(address[] memory, bytes[] memory) internal pure returns (bytes32) {
        return TIMELOCK_SALT;
    }

    function logUpgradeBatchCalldata() public view {
        (address[] memory targets, uint256[] memory values, bytes[] memory data) = _buildUpgradeBatch();
        _logUpgradeBatch(targets, values, data, _timelockSalt(targets, data));
    }

    function _logUpgradeBatch(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory data,
        bytes32 salt
    ) internal view {
        console2.log("=== UPGRADE_TIMELOCK batch ===");
        console2.log("timelock:      ", UPGRADE_TIMELOCK);
        console2.log("proposer Safe: ", ETHERFI_UPGRADE_ADMIN);
        console2.log("minDelay:      ", TIMELOCK_MIN_DELAY);
        console2.log("salt:");
        console2.logBytes32(salt);
        console2.log("");

        for (uint256 i = 0; i < targets.length; i++) {
            console2.log("--- call", i);
            console2.log("target:", targets[i]);
            console2.log("value: ", values[i]);
            console2.log("data:");
            console2.logBytes(data[i]);
        }
        console2.log("");

        console2.log("Schedule calldata (Safe tx 1 -> UPGRADE_TIMELOCK):");
        console2.logBytes(
            abi.encodeWithSelector(
                upgradeTimelock.scheduleBatch.selector, targets, values, data, bytes32(0), salt, TIMELOCK_MIN_DELAY
            )
        );
        console2.log("");

        console2.log("Execute calldata (Safe tx 2 -> UPGRADE_TIMELOCK, after 10 days):");
        console2.logBytes(
            abi.encodeWithSelector(upgradeTimelock.executeBatch.selector, targets, values, data, bytes32(0), salt)
        );
        console2.log("================================================");
        console2.log("");
    }

    // ---------------------------------------------------------------------------------
    // Verification
    // ---------------------------------------------------------------------------------

    function verifyDeployedBytecode() public {
        EtherFiNodesManager freshEtherFiNodesManager =
            new EtherFiNodesManager(STAKING_MANAGER, ROLE_REGISTRY, ETHERFI_RATE_LIMITER);
        contractCodeChecker.verifyContractByteCodeMatch(
            EXPECTED_ETHERFI_NODES_MANAGER_IMPL, address(freshEtherFiNodesManager)
        );

        EtherFiNode freshEtherFiNode = new EtherFiNode(
            LIQUIDITY_POOL, ETHERFI_NODES_MANAGER, EIGENLAYER_POD_MANAGER, EIGENLAYER_DELEGATION_MANAGER
        );
        contractCodeChecker.verifyContractByteCodeMatch(EXPECTED_ETHERFI_NODE_IMPL, address(freshEtherFiNode));

        StakingManager freshStakingManager = new StakingManager(
            LIQUIDITY_POOL,
            ETHERFI_NODES_MANAGER,
            ETH2_DEPOSIT_CONTRACT,
            AUCTION_MANAGER,
            ETHERFI_NODE_BEACON,
            ROLE_REGISTRY
        );
        contractCodeChecker.verifyContractByteCodeMatch(EXPECTED_STAKING_MANAGER_IMPL, address(freshStakingManager));

        console2.log("[OK] deployed bytecode matches this commit");
    }

    function verifyUpgrades() public view {
        require(
            getImplementation(ETHERFI_NODES_MANAGER) == EXPECTED_ETHERFI_NODES_MANAGER_IMPL, "ENM impl mismatch"
        );
        require(getImplementation(STAKING_MANAGER) == EXPECTED_STAKING_MANAGER_IMPL, "StakingManager impl mismatch");
        require(getImplementation(ETHERFI_ADMIN) == EXPECTED_ETHERFI_ADMIN_IMPL, "EtherFiAdmin impl mismatch");
        require(
            StakingManager(STAKING_MANAGER).etherFiNodeBeacon().implementation() == EXPECTED_ETHERFI_NODE_IMPL,
            "EtherFiNode beacon impl mismatch"
        );

        // The release's new surface must be present in the live implementation, and the dropped
        // uint256-id overloads must be gone. Off-chain callers still on the id form break here
        // rather than in production.
        require(
            _implHasSelector(
                EXPECTED_ETHERFI_NODES_MANAGER_IMPL, EtherFiNodesManager.withdrawalCredentialTarget.selector
            ),
            "ENM missing withdrawalCredentialTarget"
        );
        require(
            _implHasSelector(EXPECTED_ETHERFI_NODES_MANAGER_IMPL, EtherFiNodesManager.disablePod.selector),
            "ENM missing disablePod"
        );
        require(
            !_implHasSelector(EXPECTED_ETHERFI_NODES_MANAGER_IMPL, bytes4(keccak256("sweepFunds(uint256)"))),
            "ENM still exposes the legacy sweepFunds(uint256) overload"
        );

        console2.log("[OK] all four implementations live");
    }

    function verifyTreasurySweep() public view {
        require(TREASURY_LEGACY.balance == 0, "legacy treasury not drained");
        require(
            LIQUIDITY_POOL.balance == lpBalanceBefore + TREASURY_LEGACY_SWEEP_AMOUNT,
            "liquidity pool did not receive the sweep"
        );
        console2.log("[OK] legacy treasury drained into the liquidity pool:", TREASURY_LEGACY_SWEEP_AMOUNT);
    }

    /// @dev scans an implementation's runtime code for a 4-byte selector constant
    function _implHasSelector(address impl, bytes4 selector) internal view returns (bool) {
        bytes memory code = impl.code;
        if (code.length < 4) return false;
        for (uint256 i = 0; i <= code.length - 4; i++) {
            if (
                code[i] == selector[0] && code[i + 1] == selector[1] && code[i + 2] == selector[2]
                    && code[i + 3] == selector[3]
            ) {
                return true;
            }
        }
        return false;
    }

    function _requireImplsMatchExpected() internal view {
        require(etherFiNodesManagerImpl == EXPECTED_ETHERFI_NODES_MANAGER_IMPL, "ENM impl address drifted");
        require(etherFiNodeImpl == EXPECTED_ETHERFI_NODE_IMPL, "EtherFiNode impl address drifted");
        require(stakingManagerImpl == EXPECTED_STAKING_MANAGER_IMPL, "StakingManager impl address drifted");
        require(etherFiAdminImpl == EXPECTED_ETHERFI_ADMIN_IMPL, "EtherFiAdmin impl address drifted");
        console2.log("[OK] CREATE2 addresses match the constants encoded in the Safe calldata");
    }
}
