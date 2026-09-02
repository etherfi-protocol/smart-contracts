// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {EtherFiTimelock} from "@etherfi/governance/EtherFiTimelock.sol";
import {RoleRegistry} from "@etherfi/governance/RoleRegistry.sol";
import {EtherFiRateLimiter} from "@etherfi/governance/rate-limiting/EtherFiRateLimiter.sol";
import {EtherFiNodesManager} from "@etherfi/staking/EtherFiNodesManager.sol";
import {EtherFiNode} from "@etherfi/staking/EtherFiNode.sol";
import {IEtherFiNode} from "@etherfi/staking/interfaces/IEtherFiNode.sol";
import {StakingManager} from "@etherfi/staking/StakingManager.sol";
import {IStakingManager} from "@etherfi/staking/interfaces/IStakingManager.sol";
import {LiquidityPool} from "@etherfi/core/LiquidityPool.sol";
import {IAuctionManager} from "@etherfi/staking/interfaces/IAuctionManager.sol";
import {NodeOperatorManager} from "@etherfi/staking/NodeOperatorManager.sol";
import {IEigenPodTypes} from "@etherfi/interfaces/eigenlayer-interfaces/IEigenPod.sol";
import {depositDataRootGenerator} from "@etherfi/staking/libraries/DepositDataRootGenerator.sol";
import {Treasury} from "@etherfi/archive/Treasury.sol";
import {ContractCodeChecker} from "@scripts/ContractCodeChecker.sol";
import {DeployNonEigenPodCreds} from "./deploy.s.sol";

/**
 * @title NonEigenPodCredsTransactions
 * @notice Governance transactions for the non-EigenPod withdrawal credentials release (PR #485),
 *         plus a drain of the retired Treasury into the LiquidityPool.
 *
 * One UPGRADE_TIMELOCK batch (10-day delay) proposed by ETHERFI_UPGRADE_ADMIN:
 *   0 EtherFiNodesManager.upgradeTo
 *   1 StakingManager.upgradeTo
 *   2 EtherFiAdmin.upgradeTo
 *   3 StakingManager.upgradeEtherFiNode   (beacon; onlyUpgradeTimelock)
 *   4 Treasury(retired).withdraw          (Ownable; owner == UPGRADE_TIMELOCK)
 *
 * run() snapshots immutables, schedules, warps, executes, re-checks immutables, then exercises
 * the upgraded contracts on the fork: a pod-less validator spin-up, an EL-triggered exit request,
 * and the classic EigenLayer queue/complete withdrawal path.
 *
 * AVS deregistration is deliberately absent. adminForwardCall is gated by OPERATION_MULTISIG_ROLE
 * on the Operating Safe, which the UPGRADE_TIMELOCK does not hold, so it cannot ride this batch.
 *
 * command:
 * forge script script/upgrades/non-eigenpod-creds/transactions.s.sol:NonEigenPodCredsTransactions \
 *   --fork-url $MAINNET_RPC_URL -vvvv
 */
contract NonEigenPodCredsTransactions is DeployNonEigenPodCreds {
    using stdStorage for StdStorage;

    // Expected CREATE2 addresses for commitHashSalt; these are what the Safe calldata encodes.
    address constant EXPECTED_ETHERFI_NODES_MANAGER_IMPL = 0x020016Fa077515451975712595EB3e984907ad3b;
    address constant EXPECTED_ETHERFI_NODE_IMPL = 0x73Df4a005332525fB0A0B2cf067352a9b706f233;
    address constant EXPECTED_STAKING_MANAGER_IMPL = 0x6515B41BDcf83BE5543B88591BC0bC34d844c9c2;
    address constant EXPECTED_ETHERFI_ADMIN_IMPL = 0x841fA691AA6E30E97c817608F90111701a3D0Ac8;

    /// @dev retired Treasury, src/archive/Treasury.sol
    address constant TREASURY_LEGACY = 0x6329004E903B7F420245E7aF3f355186f2432466;
    /// @dev its balance; only the timelock can withdraw, so it can only grow. Re-check before hashing.
    uint256 constant TREASURY_LEGACY_SWEEP_AMOUNT = 9_712_223_546_514_004_611;

    EtherFiTimelock constant upgradeTimelock = EtherFiTimelock(payable(UPGRADE_TIMELOCK));
    RoleRegistry constant roleRegistry = RoleRegistry(ROLE_REGISTRY);
    EtherFiNodesManager constant etherFiNodesManager = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER));
    StakingManager constant stakingManager = StakingManager(STAKING_MANAGER);
    LiquidityPool constant liquidityPool = LiquidityPool(payable(LIQUIDITY_POOL));

    /// @dev UPGRADE_TIMELOCK.getMinDelay() on-chain
    uint256 constant TIMELOCK_MIN_DELAY = 864_000;

    /// @dev fixed, not block-derived, so the Safe tx hashes stay reproducible
    bytes32 constant TIMELOCK_SALT = keccak256("etherfi.non-eigenpod-creds.pr485");

    ContractCodeChecker public contractCodeChecker;

    uint256 internal lpBalanceBefore;
    ImmutableSnapshot internal preEnm;
    ImmutableSnapshot internal preStakingManager;
    ImmutableSnapshot internal preEtherFiAdmin;

    function run() public override {
        _deployAll();
        _requireImplsMatchExpected();
        contractCodeChecker = new ContractCodeChecker();

        _snapshotImmutables();

        (address[] memory targets, uint256[] memory values, bytes[] memory data) = _buildUpgradeBatch();
        _logUpgradeBatch(targets, values, data, TIMELOCK_SALT);

        lpBalanceBefore = LIQUIDITY_POOL.balance;

        vm.startPrank(ETHERFI_UPGRADE_ADMIN);
        upgradeTimelock.scheduleBatch(targets, values, data, bytes32(0), TIMELOCK_SALT, TIMELOCK_MIN_DELAY);
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);
        upgradeTimelock.executeBatch(targets, values, data, bytes32(0), TIMELOCK_SALT);
        vm.stopPrank();

        console2.log("upgrade batch executed on fork");
        console2.log("");

        verifyDeployedBytecode();
        verifyUpgrades();
        verifyImmutablesPreserved();
        verifyTreasurySweep();

        forkTests();
    }

    // ------------------------------------------------------------------ batch

    function _buildUpgradeBatch()
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory data)
    {
        targets = new address[](5);
        data = new bytes[](5);
        values = new uint256[](5);

        targets[0] = ETHERFI_NODES_MANAGER;
        data[0] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, EXPECTED_ETHERFI_NODES_MANAGER_IMPL);

        targets[1] = STAKING_MANAGER;
        data[1] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, EXPECTED_STAKING_MANAGER_IMPL);

        targets[2] = ETHERFI_ADMIN;
        data[2] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, EXPECTED_ETHERFI_ADMIN_IMPL);

        // after call 1 so the beacon is repointed by the StakingManager build shipping with it
        targets[3] = STAKING_MANAGER;
        data[3] = abi.encodeWithSelector(StakingManager.upgradeEtherFiNode.selector, EXPECTED_ETHERFI_NODE_IMPL);

        targets[4] = TREASURY_LEGACY;
        data[4] = abi.encodeWithSelector(Treasury.withdraw.selector, TREASURY_LEGACY_SWEEP_AMOUNT, LIQUIDITY_POOL);
    }

    function logUpgradeBatchCalldata() public view {
        (address[] memory t, uint256[] memory v, bytes[] memory d) = _buildUpgradeBatch();
        _logUpgradeBatch(t, v, d, TIMELOCK_SALT);
    }

    function _logUpgradeBatch(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory data,
        bytes32 salt
    ) internal view {
        console2.log("=== UPGRADE_TIMELOCK batch ===");
        console2.log("timelock:     ", UPGRADE_TIMELOCK);
        console2.log("proposer Safe:", ETHERFI_UPGRADE_ADMIN);
        console2.log("minDelay:     ", TIMELOCK_MIN_DELAY);
        console2.log("salt:");
        console2.logBytes32(salt);

        for (uint256 i = 0; i < targets.length; i++) {
            console2.log("--- call", i);
            console2.log("target:", targets[i]);
            console2.log("data:");
            console2.logBytes(data[i]);
        }

        console2.log("Schedule calldata:");
        console2.logBytes(
            abi.encodeWithSelector(
                upgradeTimelock.scheduleBatch.selector, targets, values, data, bytes32(0), salt, TIMELOCK_MIN_DELAY
            )
        );
        console2.log("Execute calldata:");
        console2.logBytes(
            abi.encodeWithSelector(upgradeTimelock.executeBatch.selector, targets, values, data, bytes32(0), salt)
        );
        console2.log("");
    }

    // ------------------------------------------------------- immutable checks

    function _enmImmutableSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = bytes4(keccak256("stakingManager()"));
        s[1] = bytes4(keccak256("roleRegistry()"));
        s[2] = bytes4(keccak256("rateLimiter()"));
    }

    function _stakingManagerImmutableSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = bytes4(keccak256("liquidityPool()"));
        s[1] = bytes4(keccak256("etherFiNodesManager()"));
        s[2] = bytes4(keccak256("depositContractEth2()"));
        s[3] = bytes4(keccak256("auctionManager()"));
        s[4] = bytes4(keccak256("etherFiNodeBeacon()"));
        s[5] = bytes4(keccak256("roleRegistry()"));
    }

    function _etherFiAdminImmutableSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](14);
        s[0] = bytes4(keccak256("etherFiOracle()"));
        s[1] = bytes4(keccak256("stakingManager()"));
        s[2] = bytes4(keccak256("auctionManager()"));
        s[3] = bytes4(keccak256("etherFiNodesManager()"));
        s[4] = bytes4(keccak256("liquidityPool()"));
        s[5] = bytes4(keccak256("withdrawRequestNft()"));
        s[6] = bytes4(keccak256("priorityWithdrawalQueue()"));
        s[7] = bytes4(keccak256("roleRegistry()"));
        s[8] = bytes4(keccak256("maxAcceptableRebaseAprInBps()"));
        s[9] = bytes4(keccak256("maxValidatorTaskBatchSize()"));
        s[10] = bytes4(keccak256("maxNumberOfRequestsToFinalizePerReport()"));
        s[11] = bytes4(keccak256("maxAcceptableFinalizedWithdrawalAmountPerDay()"));
        s[12] = bytes4(keccak256("maxAcceptableNumValidatorsToApprovePerDay()"));
        s[13] = bytes4(keccak256("staleOracleReportBlockWindow()"));
    }

    function _snapshotImmutables() internal {
        preEnm = takeImmutableSnapshot(ETHERFI_NODES_MANAGER, _enmImmutableSelectors());
        preStakingManager = takeImmutableSnapshot(STAKING_MANAGER, _stakingManagerImmutableSelectors());
        preEtherFiAdmin = takeImmutableSnapshot(ETHERFI_ADMIN, _etherFiAdminImmutableSelectors());
        console2.log("[OK] pre-upgrade immutables snapshotted");
    }

    function verifyImmutablesPreserved() public view {
        verifyImmutablesUnchanged(
            preEnm, takeImmutableSnapshot(ETHERFI_NODES_MANAGER, _enmImmutableSelectors()), "EtherFiNodesManager"
        );
        verifyImmutablesUnchanged(
            preStakingManager,
            takeImmutableSnapshot(STAKING_MANAGER, _stakingManagerImmutableSelectors()),
            "StakingManager"
        );
        verifyImmutablesUnchanged(
            preEtherFiAdmin, takeImmutableSnapshot(ETHERFI_ADMIN, _etherFiAdminImmutableSelectors()), "EtherFiAdmin"
        );

        verifyNotReinitializable(ETHERFI_NODES_MANAGER, "EtherFiNodesManager");
        verifyNotReinitializable(STAKING_MANAGER, "StakingManager");
        verifyNotReinitializable(ETHERFI_ADMIN, "EtherFiAdmin");
    }

    // ------------------------------------------------------------ upgrade checks

    function verifyDeployedBytecode() public {
        EtherFiNodesManager freshEnm = new EtherFiNodesManager(STAKING_MANAGER, ROLE_REGISTRY, ETHERFI_RATE_LIMITER);
        contractCodeChecker.verifyContractByteCodeMatch(EXPECTED_ETHERFI_NODES_MANAGER_IMPL, address(freshEnm));

        EtherFiNode freshNode = new EtherFiNode(
            LIQUIDITY_POOL, ETHERFI_NODES_MANAGER, EIGENLAYER_POD_MANAGER, EIGENLAYER_DELEGATION_MANAGER
        );
        contractCodeChecker.verifyContractByteCodeMatch(EXPECTED_ETHERFI_NODE_IMPL, address(freshNode));

        StakingManager freshSm = new StakingManager(
            LIQUIDITY_POOL,
            ETHERFI_NODES_MANAGER,
            ETH2_DEPOSIT_CONTRACT,
            AUCTION_MANAGER,
            ETHERFI_NODE_BEACON,
            ROLE_REGISTRY
        );
        contractCodeChecker.verifyContractByteCodeMatch(EXPECTED_STAKING_MANAGER_IMPL, address(freshSm));

        console2.log("[OK] deployed bytecode matches this commit");
    }

    function verifyUpgrades() public view {
        require(getImplementation(ETHERFI_NODES_MANAGER) == EXPECTED_ETHERFI_NODES_MANAGER_IMPL, "ENM impl mismatch");
        require(getImplementation(STAKING_MANAGER) == EXPECTED_STAKING_MANAGER_IMPL, "StakingManager impl mismatch");
        require(getImplementation(ETHERFI_ADMIN) == EXPECTED_ETHERFI_ADMIN_IMPL, "EtherFiAdmin impl mismatch");
        require(
            stakingManager.etherFiNodeBeacon().implementation() == EXPECTED_ETHERFI_NODE_IMPL,
            "EtherFiNode beacon impl mismatch"
        );
        console2.log("[OK] all four implementations live");
    }

    function verifyTreasurySweep() public view {
        require(TREASURY_LEGACY.balance == 0, "legacy treasury not drained");
        require(
            LIQUIDITY_POOL.balance == lpBalanceBefore + TREASURY_LEGACY_SWEEP_AMOUNT,
            "liquidity pool did not receive the sweep"
        );
        console2.log("[OK] treasury drained into the liquidity pool:", TREASURY_LEGACY_SWEEP_AMOUNT);
    }

    // ---------------------------------------------------------------- fork tests

    function forkTests() public {
        _grantForkTestRoles();
        (address node, bytes memory pubkey) = forkTestSpinUpPodlessValidator();
        forkTestElTriggeredExit(node, pubkey);
        forkTestEigenLayerWithdrawal();
    }

    /// @dev granted outside the timelock batch so the proposal's calldata is unaffected
    function _grantForkTestRoles() internal {
        vm.startPrank(UPGRADE_TIMELOCK);
        roleRegistry.grantRole(roleRegistry.EXECUTOR_OPERATIONS_ROLE(), ADMIN_EOA);
        roleRegistry.grantRole(roleRegistry.ORACLE_OPERATIONS_ROLE(), ADMIN_EOA);
        roleRegistry.grantRole(roleRegistry.HOUSEKEEPING_OPERATIONS_ROLE(), ADMIN_EOA);
        vm.stopPrank();
    }

    /// @notice pod-less validator: withdrawal credentials point at the node, not an EigenPod
    function forkTestSpinUpPodlessValidator() public returns (address, bytes memory) {
        address spawner = makeAddr("forkTestSpawner");
        address operator = makeAddr("forkTestOperator");

        vm.deal(LIQUIDITY_POOL, LIQUIDITY_POOL.balance + 10_000 ether);

        vm.prank(OPERATING_TIMELOCK);
        liquidityPool.registerValidatorSpawner(spawner);

        vm.prank(ETHERFI_OPERATING_ADMIN);
        NodeOperatorManager(NODE_OPERATOR_MANAGER).addToWhitelist(operator);
        vm.prank(operator);
        NodeOperatorManager(NODE_OPERATOR_MANAGER).registerNodeOperator("test_ipfs_hash", 1000);

        vm.deal(operator, 1 ether);
        vm.prank(operator);
        uint256[] memory bidIds = IAuctionManager(AUCTION_MANAGER).createBid{value: 0.1 ether}(1, 0.1 ether);

        vm.prank(ADMIN_EOA);
        address node = stakingManager.instantiateEtherFiNode(false);
        require(etherFiNodesManager.withdrawalCredentialTarget(node) == node, "pod-less target must be the node");

        bytes memory creds = abi.encodePacked(bytes1(0x02), bytes11(0x0), node);
        bytes memory pubkey = new bytes(48);
        bytes memory sig = new bytes(96);
        for (uint256 i = 0; i < 48; i++) pubkey[i] = 0xab;
        for (uint256 i = 0; i < 96; i++) sig[i] = 0xcd;

        IStakingManager.DepositData[] memory dd = new IStakingManager.DepositData[](1);
        dd[0] = IStakingManager.DepositData({
            publicKey: pubkey,
            signature: sig,
            depositDataRoot: depositDataRootGenerator.generateDepositDataRoot(pubkey, sig, creds, 1 ether),
            ipfsHashForEncryptedValidatorKey: "test_ipfs_hash"
        });

        vm.prank(spawner);
        liquidityPool.batchRegister(dd, bidIds, node);
        vm.prank(ADMIN_EOA);
        liquidityPool.batchCreateBeaconValidators(dd, bidIds, node);

        // top-up root is built over 31 ETH, not 32
        IStakingManager.DepositData[] memory dd31 = new IStakingManager.DepositData[](1);
        dd31[0] = dd[0];
        dd31[0].depositDataRoot = depositDataRootGenerator.generateDepositDataRoot(pubkey, sig, creds, 31 ether);
        vm.prank(ADMIN_EOA);
        liquidityPool.confirmAndFundBeaconValidators(dd31, 32 ether);

        console2.log("[OK] pod-less validator spun up on node", node);
        return (node, pubkey);
    }

    /// @notice EL-triggered full exit on a pod-less node: straight to the EIP-7002 predeploy, no
    ///         EigenPod involved. Uses the node just spun up, so the validator is linked in our own
    ///         pubkey map, which is what the pod-less branch checks instead of pod membership.
    function forkTestElTriggeredExit(address node, bytes memory pubkey) public {
        require(etherFiNodesManager.getEigenPod(node) == address(0), "expected a pod-less node");

        _ensureExitCapacity();

        IEigenPodTypes.WithdrawalRequest[] memory reqs = new IEigenPodTypes.WithdrawalRequest[](1);
        reqs[0] = IEigenPodTypes.WithdrawalRequest({pubkey: pubkey, amountGwei: 0}); // 0 == full exit

        uint256 fee = IEtherFiNode(node).getWithdrawalRequestFee();
        vm.deal(ADMIN_EOA, ADMIN_EOA.balance + fee + 1 ether);
        vm.prank(ADMIN_EOA);
        etherFiNodesManager.requestExecutionLayerTriggeredWithdrawal{value: fee}(reqs);

        console2.log("[OK] EL-triggered exit requested for node", node);
        console2.log("     fee paid:", fee);
    }

    /// @notice classic EigenLayer queue -> delay -> complete, proceeds land in the LiquidityPool
    function forkTestEigenLayerWithdrawal() public {
        bytes memory pubkey =
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c";
        uint256[] memory ids = new uint256[](1);
        ids[0] = 10270;
        bytes[] memory pubkeys = new bytes[](1);
        pubkeys[0] = pubkey;
        vm.prank(ETHERFI_OPERATING_ADMIN);
        etherFiNodesManager.linkLegacyValidatorIds(ids, pubkeys);

        address node = address(etherFiNodesManager.etherFiNodeFromPubkeyHash(
            etherFiNodesManager.calculateValidatorPubkeyHash(pubkey)
        ));
        address pod = etherFiNodesManager.getEigenPod(node);
        require(pod != address(0), "fixture node has no EigenPod");

        // slot 52 is withdrawableRestakedExecutionLayerGwei; both pokes must precede the queue
        vm.store(pod, bytes32(uint256(52)), bytes32(uint256(10_000 ether / 1 gwei)));
        vm.deal(pod, 10_000 ether);
        stdstore.target(EIGENLAYER_POD_MANAGER).sig("podOwnerDepositShares(address)").with_key(node)
            .checked_write_int(int256(10_000 ether));

        _ensureUnrestakingCapacity();

        uint256 lpBefore = LIQUIDITY_POOL.balance;
        vm.prank(ADMIN_EOA);
        etherFiNodesManager.queueETHWithdrawal(node, 1 ether);

        vm.roll(block.number + 100_800 + 1);

        vm.prank(ADMIN_EOA);
        etherFiNodesManager.completeQueuedETHWithdrawals(node, true);

        require(LIQUIDITY_POOL.balance > lpBefore, "liquidity pool received no withdrawal proceeds");
        console2.log("[OK] EigenLayer withdrawal completed. LP delta:", LIQUIDITY_POOL.balance - lpBefore);
    }

    // -------------------------------------------------------------- rate limits

    function _ensureExitCapacity() internal {
        _topUpLimit(etherFiNodesManager.EXIT_REQUEST_LIMIT_ID());
    }

    function _ensureUnrestakingCapacity() internal {
        _topUpLimit(etherFiNodesManager.UNRESTAKING_LIMIT_ID());
    }

    /// @dev limits are denominated in gwei; the limiter and its consumers already exist on mainnet
    function _topUpLimit(bytes32 limitId) internal {
        EtherFiRateLimiter limiter = EtherFiRateLimiter(payable(ETHERFI_RATE_LIMITER));
        uint64 capacity = 20_000_000 * 1e9;
        vm.startPrank(OPERATING_TIMELOCK);
        limiter.setCapacity(limitId, capacity);
        limiter.setRemaining(limitId, capacity);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- internals

    function _requireImplsMatchExpected() internal view {
        require(etherFiNodesManagerImpl == EXPECTED_ETHERFI_NODES_MANAGER_IMPL, "ENM impl address drifted");
        require(etherFiNodeImpl == EXPECTED_ETHERFI_NODE_IMPL, "EtherFiNode impl address drifted");
        require(stakingManagerImpl == EXPECTED_STAKING_MANAGER_IMPL, "StakingManager impl address drifted");
        require(etherFiAdminImpl == EXPECTED_ETHERFI_ADMIN_IMPL, "EtherFiAdmin impl address drifted");
        console2.log("[OK] CREATE2 addresses match the Safe calldata");
    }
}
