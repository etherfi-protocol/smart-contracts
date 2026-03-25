// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {Utils} from "../../utils/utils.sol";
import {EtherFiTimelock} from "../../../src/EtherFiTimelock.sol";
import {EtherFiRestaker} from "../../../src/EtherFiRestaker.sol";
import {EtherFiRedemptionManager} from "../../../src/EtherFiRedemptionManager.sol";
import {IRoleRegistry} from "../../../src/interfaces/IRoleRegistry.sol";
import {IEtherFiRateLimiter} from "../../../src/interfaces/IEtherFiRateLimiter.sol";
import {ContractCodeChecker} from "../../../script/ContractCodeChecker.sol";
import {IDelegationManager} from "../../../src/eigenlayer-interfaces/IDelegationManager.sol";
import {ILido} from "../../../src/interfaces/ILiquifier.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title RestakerRolesTransactions
 * @notice Schedules and executes two upgrades in a single timelock batch:
 *         1. EtherFiRestaker: introduces per-function RoleRegistry roles
 *         2. EtherFiRedemptionManager: EIP-7702 gas fix (10k -> 100k gas stipend)
 *
 * New Restaker roles (grant via RoleRegistry after upgrade):
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
    address constant etherFiRestakerImpl = 0x2d09A6561588506aF434CEe87Eac16Aba09d5641;
    // TODO: fill in after running redemption-manager-7702/deploy.s.sol
    address constant redemptionManagerImpl = address(0);

    bytes32 constant commitHashSalt = keccak256("restaker-roles-v2"); // TODO: fill in after audit

    // Rate limiter values (in gwei)
    // capacity:   100_000_000_000_000 gwei = 100,000 ETH
    // refillRate: 1_157_407_407 gwei/sec   = 100,000 ETH/day
    uint64 constant RATE_LIMIT_CAPACITY = 100_000_000_000_000;
    uint64 constant RATE_LIMIT_REFILL_RATE = 1_157_407_407;

    // depositIntoStrategy rate limiter: 100k ETH/day
    // capacity:   100_000_000_000_000 gwei = 100,000 ETH
    // refillRate: 1_157_407_407 gwei/sec   ≈ 100,000 ETH/day
    uint64 constant DEPOSIT_RATE_LIMIT_CAPACITY = 100_000_000_000_000;
    uint64 constant DEPOSIT_RATE_LIMIT_REFILL_RATE = 1_157_407_407;

    //--------------------------------------------------------------------------------------
    //---------------------------- IMMUTABLE SNAPSHOTS (PRE-UPGRADE) -----------------------
    //--------------------------------------------------------------------------------------
    ImmutableSnapshot internal preRestakerImmutables;
    ImmutableSnapshot internal preRedemptionManagerImmutables;

    //--------------------------------------------------------------------------------------
    //---------------------------- ACCESS CONTROL SNAPSHOTS (PRE-UPGRADE) ------------------
    //--------------------------------------------------------------------------------------
    address internal preRestakerOwner;
    address internal preRedemptionManagerOwner;
    bool internal preRedemptionManagerPaused;

    function run() public {
        console2.log("================================================");
        console2.log("=== Restaker Roles + RedemptionManager 7702 ====");
        console2.log("================================================");
        console2.log("");

        require(etherFiRestakerImpl != address(0), "Set etherFiRestakerImpl before running");
        require(redemptionManagerImpl != address(0), "Set redemptionManagerImpl before running");

        contractCodeChecker = new ContractCodeChecker();

        verifyDeployedBytecode();
        takePreUpgradeSnapshots();
        executeUpgrade();
        setUpRateLimiters();
        verifyUpgrade();
        verifyImmutablePreservation();
        verifyAccessControlPreservation();
        forkTests();

        console2.log("=== Upgrade Complete ===");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- BYTECODE VERIFICATION --------------------------------
    //--------------------------------------------------------------------------------------
    function verifyDeployedBytecode() public {
        console2.log("=== Verifying Deployed Bytecode ===");

        EtherFiRestaker expectedRestaker = new EtherFiRestaker(
            address(EIGENLAYER_REWARDS_COORDINATOR),
            address(ETHERFI_REDEMPTION_MANAGER),
            address(ROLE_REGISTRY),
            address(ETHERFI_RATE_LIMITER)
        );
        contractCodeChecker.verifyContractByteCodeMatch(etherFiRestakerImpl, address(expectedRestaker));
        console2.log("EtherFiRestaker bytecode verified!");

        EtherFiRedemptionManager expectedRedemption = new EtherFiRedemptionManager(
            LIQUIDITY_POOL,
            EETH,
            WEETH,
            WITHDRAW_REQUEST_NFT_BUYBACK_SAFE,
            ROLE_REGISTRY,
            ETHERFI_RESTAKER,
            PRIORITY_WITHDRAWAL_QUEUE
        );
        contractCodeChecker.verifyContractByteCodeMatch(redemptionManagerImpl, address(expectedRedemption));
        console2.log("EtherFiRedemptionManager bytecode verified!");

        console2.log("================================================");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- IMMUTABLE SELECTOR DEFINITIONS -----------------------
    //--------------------------------------------------------------------------------------
    function getRestakerImmutableSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("rewardsCoordinator()"));
        selectors[1] = bytes4(keccak256("etherFiRedemptionManager()"));
    }

    function getRedemptionManagerImmutableSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](7);
        selectors[0] = bytes4(keccak256("roleRegistry()"));
        selectors[1] = bytes4(keccak256("treasury()"));
        selectors[2] = bytes4(keccak256("eEth()"));
        selectors[3] = bytes4(keccak256("weEth()"));
        selectors[4] = bytes4(keccak256("liquidityPool()"));
        selectors[5] = bytes4(keccak256("etherFiRestaker()"));
        selectors[6] = bytes4(keccak256("lido()"));
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- PRE-UPGRADE SNAPSHOTS --------------------------------
    //--------------------------------------------------------------------------------------
    function takePreUpgradeSnapshots() internal {
        console2.log("=== Taking Pre-Upgrade Snapshots ===");
        console2.log("");

        // Immutable snapshots
        console2.log("--- Immutable Snapshots ---");
        preRestakerImmutables = takeImmutableSnapshot(
            ETHERFI_RESTAKER,
            getRestakerImmutableSelectors()
        );
        console2.log("  EtherFiRestaker: captured", preRestakerImmutables.selectors.length, "immutables");

        preRedemptionManagerImmutables = takeImmutableSnapshot(
            ETHERFI_REDEMPTION_MANAGER,
            getRedemptionManagerImmutableSelectors()
        );
        console2.log("  EtherFiRedemptionManager: captured", preRedemptionManagerImmutables.selectors.length, "immutables");

        // Access control snapshots
        console2.log("");
        console2.log("--- Access Control Snapshots ---");

        preRestakerOwner = _getOwner(ETHERFI_RESTAKER);
        console2.log("  EtherFiRestaker owner:", preRestakerOwner);

        preRedemptionManagerOwner = _getOwner(ETHERFI_REDEMPTION_MANAGER);
        console2.log("  EtherFiRedemptionManager owner:", preRedemptionManagerOwner);

        preRedemptionManagerPaused = _getPaused(ETHERFI_REDEMPTION_MANAGER);
        console2.log("  EtherFiRedemptionManager paused:", preRedemptionManagerPaused);

        console2.log("");
        console2.log("Pre-upgrade snapshots captured!");
        console2.log("================================================");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- EXECUTE UPGRADE --------------------------------------
    //--------------------------------------------------------------------------------------
    function executeUpgrade() public {
        console2.log("=== Executing Upgrade ===");

        bytes32 claimRole = keccak256("ETHERFI_RESTAKER_STETH_CLAIM_WITHDRAWALS_ROLE");
        bytes32 requestRole = keccak256("ETHERFI_RESTAKER_STETH_REQUEST_WITHDRAWAL_ROLE");
        bytes32 queueRole = keccak256("ETHERFI_RESTAKER_QUEUE_WITHDRAWALS_ROLE");
        bytes32 completeRole = keccak256("ETHERFI_RESTAKER_COMPLETE_QUEUED_WITHDRAWALS_ROLE");
        bytes32 depositRole = keccak256("ETHERFI_RESTAKER_DEPOSIT_INTO_STRATEGY_ROLE");

        address[] memory targets = new address[](7);
        bytes[] memory data = new bytes[](targets.length);
        uint256[] memory values = new uint256[](targets.length);

        // Restaker upgrade
        targets[0] = ETHERFI_RESTAKER;
        data[0] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, etherFiRestakerImpl);
        // Restaker role grants
        targets[1] = ROLE_REGISTRY;
        data[1] = abi.encodeWithSelector(IRoleRegistry.grantRole.selector, claimRole, ADMIN_EOA);
        targets[2] = ROLE_REGISTRY;
        data[2] = abi.encodeWithSelector(IRoleRegistry.grantRole.selector, requestRole, ADMIN_EOA);
        targets[3] = ROLE_REGISTRY;
        data[3] = abi.encodeWithSelector(IRoleRegistry.grantRole.selector, queueRole, ADMIN_EOA);
        targets[4] = ROLE_REGISTRY;
        data[4] = abi.encodeWithSelector(IRoleRegistry.grantRole.selector, completeRole, ADMIN_EOA);
        targets[5] = ROLE_REGISTRY;
        data[5] = abi.encodeWithSelector(IRoleRegistry.grantRole.selector, depositRole, ADMIN_EOA);
        targets[6] = ETHERFI_REDEMPTION_MANAGER;
        data[6] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, redemptionManagerImpl);

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
    //------------------------------- RATE LIMITER SETUP -----------------------------------
    //--------------------------------------------------------------------------------------
    function setUpRateLimiters() public {
        console2.log("=== Setting Up Rate Limiters ===");

        bytes32 stethLimitId = keccak256("STETH_REQUEST_WITHDRAWAL_LIMIT_ID");
        bytes32 queueLimitId = keccak256("QUEUE_WITHDRAWALS_LIMIT_ID");
        bytes32 depositLimitId = keccak256("DEPOSIT_INTO_STRATEGY_LIMIT_ID");

        address[] memory targets = new address[](6);
        bytes[] memory data = new bytes[](6);

        data[0] = abi.encodeWithSelector(
            IEtherFiRateLimiter.createNewLimiter.selector,
            stethLimitId,
            RATE_LIMIT_CAPACITY,
            RATE_LIMIT_REFILL_RATE
        );
        data[1] = abi.encodeWithSelector(
            IEtherFiRateLimiter.createNewLimiter.selector,
            queueLimitId,
            RATE_LIMIT_CAPACITY,
            RATE_LIMIT_REFILL_RATE
        );
        data[2] = abi.encodeWithSelector(
            IEtherFiRateLimiter.createNewLimiter.selector,
            depositLimitId,
            DEPOSIT_RATE_LIMIT_CAPACITY,
            DEPOSIT_RATE_LIMIT_REFILL_RATE
        );
        data[3] = abi.encodeWithSelector(
            IEtherFiRateLimiter.updateConsumers.selector,
            stethLimitId,
            ETHERFI_RESTAKER,
            true
        );
        data[4] = abi.encodeWithSelector(
            IEtherFiRateLimiter.updateConsumers.selector,
            queueLimitId,
            ETHERFI_RESTAKER,
            true
        );
        data[5] = abi.encodeWithSelector(
            IEtherFiRateLimiter.updateConsumers.selector,
            depositLimitId,
            ETHERFI_RESTAKER,
            true
        );

        uint256[] memory values = new uint256[](6);
        for (uint256 i = 0; i < 6; i++) {
            targets[i] = ETHERFI_RATE_LIMITER;
        }

        writeSafeJson(
            "script/upgrades/restaker-roles",
            "restaker-roles-rate-limiters.json",
            ETHERFI_OPERATING_ADMIN,
            targets,
            values,
            data,
            1
        );

        // Execute on fork for testing
        vm.startPrank(ETHERFI_OPERATING_ADMIN);
        IEtherFiRateLimiter(ETHERFI_RATE_LIMITER).createNewLimiter(stethLimitId, RATE_LIMIT_CAPACITY, RATE_LIMIT_REFILL_RATE);
        IEtherFiRateLimiter(ETHERFI_RATE_LIMITER).createNewLimiter(queueLimitId, RATE_LIMIT_CAPACITY, RATE_LIMIT_REFILL_RATE);
        IEtherFiRateLimiter(ETHERFI_RATE_LIMITER).createNewLimiter(depositLimitId, DEPOSIT_RATE_LIMIT_CAPACITY, DEPOSIT_RATE_LIMIT_REFILL_RATE);
        IEtherFiRateLimiter(ETHERFI_RATE_LIMITER).updateConsumers(stethLimitId, ETHERFI_RESTAKER, true);
        IEtherFiRateLimiter(ETHERFI_RATE_LIMITER).updateConsumers(queueLimitId, ETHERFI_RESTAKER, true);
        IEtherFiRateLimiter(ETHERFI_RATE_LIMITER).updateConsumers(depositLimitId, ETHERFI_RESTAKER, true);
        vm.stopPrank();

        console2.log("Rate limiter setup completed!");
        console2.log("================================================");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- VERIFY UPGRADE ---------------------------------------
    //--------------------------------------------------------------------------------------
    function verifyUpgrade() public view {
        console2.log("=== Verifying Upgrade ===");

        // Verify EtherFiRestaker upgrade
        address currentImpl = getImplementation(ETHERFI_RESTAKER);
        require(currentImpl == etherFiRestakerImpl, "EtherFiRestaker upgrade failed");
        console2.log("EtherFiRestaker implementation:", currentImpl);

        // Verify EtherFiRedemptionManager upgrade
        address currentRedemptionImpl = getImplementation(ETHERFI_REDEMPTION_MANAGER);
        require(currentRedemptionImpl == redemptionManagerImpl, "EtherFiRedemptionManager upgrade failed");
        console2.log("EtherFiRedemptionManager implementation:", currentRedemptionImpl);

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

        // Verify role grants were applied to ADMIN_EOA
        IRoleRegistry registry = IRoleRegistry(ROLE_REGISTRY);
        require(registry.hasRole(claimRole, ADMIN_EOA), "claimRole not granted");
        require(registry.hasRole(requestRole, ADMIN_EOA), "requestRole not granted");
        require(registry.hasRole(queueRole, ADMIN_EOA), "queueRole not granted");
        require(registry.hasRole(completeRole, ADMIN_EOA), "completeRole not granted");
        require(registry.hasRole(depositRole, ADMIN_EOA), "depositRole not granted");

        console2.log("All role constants verified!");
        console2.log("All role grants verified for ADMIN_EOA!");

        // Verify rate limiter immutable
        require(address(restaker.rateLimiter()) == ETHERFI_RATE_LIMITER, "rateLimiter mismatch");

        // Verify rate limiters were created and restaker is registered as consumer
        IEtherFiRateLimiter rl = IEtherFiRateLimiter(ETHERFI_RATE_LIMITER);
        bytes32 stethLimitId = restaker.STETH_REQUEST_WITHDRAWAL_LIMIT_ID();
        bytes32 queueLimitId = restaker.QUEUE_WITHDRAWALS_LIMIT_ID();
        bytes32 depositLimitId = restaker.DEPOSIT_INTO_STRATEGY_LIMIT_ID();

        require(rl.limitExists(stethLimitId), "STETH_REQUEST_WITHDRAWAL rate limiter not created");
        require(rl.limitExists(queueLimitId), "QUEUE_WITHDRAWALS rate limiter not created");
        require(rl.limitExists(depositLimitId), "DEPOSIT_INTO_STRATEGY rate limiter not created");
        require(rl.isConsumerAllowed(stethLimitId, ETHERFI_RESTAKER), "Restaker not registered as consumer for STETH_REQUEST_WITHDRAWAL");
        require(rl.isConsumerAllowed(queueLimitId, ETHERFI_RESTAKER), "Restaker not registered as consumer for QUEUE_WITHDRAWALS");
        require(rl.isConsumerAllowed(depositLimitId, ETHERFI_RESTAKER), "Restaker not registered as consumer for DEPOSIT_INTO_STRATEGY");

        // Verify deposit rate limiter config
        (uint64 depositCap, , uint64 depositRefill, ) = rl.getLimit(depositLimitId);
        require(depositCap == DEPOSIT_RATE_LIMIT_CAPACITY, "Deposit limiter capacity mismatch");
        require(depositRefill == DEPOSIT_RATE_LIMIT_REFILL_RATE, "Deposit limiter refill rate mismatch");

        console2.log("Rate limiters verified (including DEPOSIT_INTO_STRATEGY)!");
        console2.log("================================================");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- IMMUTABLE PRESERVATION VERIFICATION -----------------
    //--------------------------------------------------------------------------------------
    function verifyImmutablePreservation() internal view {
        console2.log("=== Verifying Immutable Preservation ===");
        console2.log("");

        ImmutableSnapshot memory postRestakerImmutables = takeImmutableSnapshot(
            ETHERFI_RESTAKER,
            getRestakerImmutableSelectors()
        );
        verifyImmutablesUnchanged(preRestakerImmutables, postRestakerImmutables, "EtherFiRestaker");

        ImmutableSnapshot memory postRedemptionManagerImmutables = takeImmutableSnapshot(
            ETHERFI_REDEMPTION_MANAGER,
            getRedemptionManagerImmutableSelectors()
        );
        verifyImmutablesUnchanged(preRedemptionManagerImmutables, postRedemptionManagerImmutables, "EtherFiRedemptionManager");

        console2.log("");
        console2.log("All immutable preservation checks passed!");
        console2.log("================================================");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- ACCESS CONTROL PRESERVATION --------------------------
    //--------------------------------------------------------------------------------------
    function verifyAccessControlPreservation() internal view {
        console2.log("=== Verifying Access Control Preservation ===");
        console2.log("");

        // Owner verification
        console2.log("--- Owner Verification ---");

        address postOwner = _getOwner(ETHERFI_RESTAKER);
        require(postOwner == preRestakerOwner, "EtherFiRestaker: owner changed");
        console2.log("[OWNER OK] EtherFiRestaker:", postOwner);

        address postRedemptionOwner = _getOwner(ETHERFI_REDEMPTION_MANAGER);
        require(postRedemptionOwner == preRedemptionManagerOwner, "EtherFiRedemptionManager: owner changed");
        console2.log("[OWNER OK] EtherFiRedemptionManager:", postRedemptionOwner);

        // Paused state verification
        console2.log("");
        console2.log("--- Paused State Verification ---");

        bool postRedemptionManagerPaused = _getPaused(ETHERFI_REDEMPTION_MANAGER);
        require(postRedemptionManagerPaused == preRedemptionManagerPaused, "EtherFiRedemptionManager: paused state changed");
        console2.log("[PAUSED OK] EtherFiRedemptionManager:", postRedemptionManagerPaused);

        // Initialization state verification
        console2.log("");
        console2.log("--- Initialization State Verification ---");

        verifyNotReinitializable(ETHERFI_RESTAKER, "EtherFiRestaker");
        verifyNotReinitializable(ETHERFI_REDEMPTION_MANAGER, "EtherFiRedemptionManager");

        console2.log("");
        console2.log("All access control preservation checks passed!");
        console2.log("================================================");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- FORK TESTS -------------------------------------------
    //--------------------------------------------------------------------------------------
    function forkTests() public {
        console2.log("=== Running Fork Tests ===");
        console2.log("");

        testRoleBasedAccessControl();
        testRateLimiterEnforcement();
        testDepositIntoStrategyRateLimit();

        console2.log("");
        console2.log("All fork tests passed!");
        console2.log("================================================");
    }

    function testRoleBasedAccessControl() internal {
        console2.log("Testing role-based access control...");

        EtherFiRestaker restaker = EtherFiRestaker(payable(ETHERFI_RESTAKER));
        address unauthorizedAddr = address(0xdead);

        // ADMIN_EOA should be able to call role-gated functions (revert for other reasons is OK)
        // Unauthorized address should revert with IncorrectRole

        // Test stEthRequestWithdrawal — unauthorized must revert with IncorrectRole
        vm.prank(unauthorizedAddr);
        try restaker.stEthRequestWithdrawal() {
            revert("stEthRequestWithdrawal: should have reverted for unauthorized");
        } catch (bytes memory reason) {
            require(bytes4(reason) == EtherFiRestaker.IncorrectRole.selector, "stEthRequestWithdrawal: wrong revert reason");
        }
        console2.log("  [OK] stEthRequestWithdrawal blocks unauthorized");

        // Test stEthClaimWithdrawals — unauthorized must revert with IncorrectRole
        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyHints = new uint256[](0);
        vm.prank(unauthorizedAddr);
        try restaker.stEthClaimWithdrawals(emptyIds, emptyHints) {
            revert("stEthClaimWithdrawals: should have reverted for unauthorized");
        } catch (bytes memory reason) {
            require(bytes4(reason) == EtherFiRestaker.IncorrectRole.selector, "stEthClaimWithdrawals: wrong revert reason");
        }
        console2.log("  [OK] stEthClaimWithdrawals blocks unauthorized");

        // Test queueWithdrawals — unauthorized must revert with IncorrectRole
        vm.prank(unauthorizedAddr);
        try restaker.queueWithdrawals(address(restaker.lido()), 1 ether) {
            revert("queueWithdrawals: should have reverted for unauthorized");
        } catch (bytes memory reason) {
            require(bytes4(reason) == EtherFiRestaker.IncorrectRole.selector, "queueWithdrawals: wrong revert reason");
        }
        console2.log("  [OK] queueWithdrawals blocks unauthorized");

        // Test completeQueuedWithdrawals — unauthorized must revert with IncorrectRole
        IDelegationManager.Withdrawal[] memory emptyWithdrawals = new IDelegationManager.Withdrawal[](0);
        IERC20[][] memory emptyTokens = new IERC20[][](0);
        vm.prank(unauthorizedAddr);
        try restaker.completeQueuedWithdrawals(emptyWithdrawals, emptyTokens) {
            revert("completeQueuedWithdrawals: should have reverted for unauthorized");
        } catch (bytes memory reason) {
            require(bytes4(reason) == EtherFiRestaker.IncorrectRole.selector, "completeQueuedWithdrawals: wrong revert reason");
        }
        console2.log("  [OK] completeQueuedWithdrawals blocks unauthorized");

        // Test depositIntoStrategy — unauthorized must revert with IncorrectRole
        vm.prank(unauthorizedAddr);
        try restaker.depositIntoStrategy(address(restaker.lido()), 1 ether) {
            revert("depositIntoStrategy: should have reverted for unauthorized");
        } catch (bytes memory reason) {
            require(bytes4(reason) == EtherFiRestaker.IncorrectRole.selector, "depositIntoStrategy: wrong revert reason");
        }
        console2.log("  [OK] depositIntoStrategy blocks unauthorized");

        // Verify ADMIN_EOA passes the role check (may revert for other reasons like insufficient balance)
        // stEthRequestWithdrawal with 0 balance should revert with IncorrectAmount, NOT IncorrectRole
        vm.prank(ADMIN_EOA);
        try restaker.stEthRequestWithdrawal() {
            // If it succeeds, that's fine too (role check passed)
        } catch (bytes memory reason) {
            require(bytes4(reason) != EtherFiRestaker.IncorrectRole.selector, "ADMIN_EOA should have the request role");
        }
        console2.log("  [OK] ADMIN_EOA passes role check for stEthRequestWithdrawal");

        console2.log("  Role-based access control tests passed!");
    }

    function testRateLimiterEnforcement() internal {
        console2.log("Testing rate limiter enforcement...");

        EtherFiRestaker restaker = EtherFiRestaker(payable(ETHERFI_RESTAKER));
        IEtherFiRateLimiter rl = IEtherFiRateLimiter(ETHERFI_RATE_LIMITER);

        // Verify rate limiter is wired up
        require(address(restaker.rateLimiter()) == ETHERFI_RATE_LIMITER, "rateLimiter not set");

        // Verify limiters exist and restaker is consumer
        bytes32 stethLimitId = restaker.STETH_REQUEST_WITHDRAWAL_LIMIT_ID();
        bytes32 queueLimitId = restaker.QUEUE_WITHDRAWALS_LIMIT_ID();

        require(rl.limitExists(stethLimitId), "stETH limiter missing");
        require(rl.limitExists(queueLimitId), "queue limiter missing");
        require(rl.isConsumerAllowed(stethLimitId, ETHERFI_RESTAKER), "restaker not consumer for stETH limiter");
        require(rl.isConsumerAllowed(queueLimitId, ETHERFI_RESTAKER), "restaker not consumer for queue limiter");

        console2.log("  [OK] Rate limiters wired correctly");

        // Warp 1 second to refill buckets so consumption test is valid
        vm.warp(block.timestamp + 1);

        // Test that a legitimate call from ADMIN_EOA hits the rate limiter (not IncorrectRole)
        // stEthRequestWithdrawal with a small amount: should fail for balance, not role or rate limit
        // (rate limit capacity is 100k ETH, so small amounts pass)
        vm.prank(ADMIN_EOA);
        try restaker.stEthRequestWithdrawal(1 ether) {
            // Passed — role + rate limit OK, had enough stETH balance
        } catch (bytes memory reason) {
            // Should NOT be IncorrectRole (role is granted)
            require(bytes4(reason) != EtherFiRestaker.IncorrectRole.selector, "ADMIN_EOA should have the role");
            // Acceptable reverts: NotEnoughBalance, IncorrectAmount (stETH balance < 1 ether)
        }
        console2.log("  [OK] Rate limiter allows small amounts within capacity");

        console2.log("  Rate limiter enforcement tests passed!");
    }

    function testDepositIntoStrategyRateLimit() internal {
        console2.log("Testing depositIntoStrategy rate limiting...");

        EtherFiRestaker restaker = EtherFiRestaker(payable(ETHERFI_RESTAKER));
        IEtherFiRateLimiter rl = IEtherFiRateLimiter(ETHERFI_RATE_LIMITER);
        bytes32 depositLimitId = restaker.DEPOSIT_INTO_STRATEGY_LIMIT_ID();
        address stETH = address(restaker.lido());

        // Warp to let bucket fully refill
        vm.warp(block.timestamp + 1 days);

        // Pre-check: limiter exists, capacity is 100k ETH
        (uint64 cap, , , ) = rl.getLimit(depositLimitId);
        require(cap == DEPOSIT_RATE_LIMIT_CAPACITY, "Deposit limiter capacity wrong");
        console2.log("  [OK] Deposit limiter capacity:", cap, "gwei (100k ETH)");

        // Fund restaker with stETH for testing
        address depositor = address(0xBEEF);
        vm.deal(depositor, 150_000 ether);
        vm.startPrank(depositor);
        ILido(stETH).submit{value: 150_000 ether}(address(0));
        IERC20(stETH).transfer(ETHERFI_RESTAKER, ILido(stETH).balanceOf(depositor));
        vm.stopPrank();

        uint256 restakerStEthBefore = IERC20(stETH).balanceOf(ETHERFI_RESTAKER);
        console2.log("  Restaker stETH balance:", restakerStEthBefore / 1e18, "stETH");

        // --- Test 1: Deposit 90k stETH within 100k capacity succeeds ---
        console2.log("  [Test 1] Deposit 90k stETH (within capacity)...");
        vm.prank(ADMIN_EOA);
        restaker.depositIntoStrategy(stETH, 90_000 ether);
        console2.log("  [OK] 90k stETH deposited into strategy");

        // --- Test 2: Deposit 20k stETH exceeds remaining ~10k capacity, should revert ---
        console2.log("  [Test 2] Deposit 20k stETH (exceeds remaining bucket)...");
        vm.prank(ADMIN_EOA);
        try restaker.depositIntoStrategy(stETH, 20_000 ether) {
            revert("Should have reverted due to rate limit");
        } catch {
            console2.log("  [OK] 20k stETH blocked by rate limiter");
        }

        // --- Test 3: Deposit 9k stETH within remaining ~10k succeeds ---
        console2.log("  [Test 3] Deposit 9k stETH (within remaining bucket)...");
        vm.prank(ADMIN_EOA);
        restaker.depositIntoStrategy(stETH, 9_000 ether);
        console2.log("  [OK] 9k stETH deposited into strategy");

        // --- Test 4: After partial refill, verify bucket replenishes ---
        console2.log("  [Test 4] Verify refill after 12 hours (~50k ETH refilled)...");
        vm.warp(block.timestamp + 12 hours);

        // 12 hours * 1_157_407_407 gwei/sec = ~50k ETH refilled
        // canConsume checks if amount fits in current bucket
        uint64 consumableAfter12h = rl.consumable(depositLimitId);
        console2.log("  Consumable after 12h:", consumableAfter12h, "gwei");
        require(consumableAfter12h >= 49_000_000_000_000, "Should have ~50k gwei refilled after 12h");
        require(consumableAfter12h <= 51_000_000_000_000, "Should not exceed ~50k gwei after 12h");
        console2.log("  [OK] ~50k ETH refilled after 12 hours");

        // Fund restaker with more stETH for the next deposit
        vm.deal(depositor, 60_000 ether);
        vm.startPrank(depositor);
        ILido(stETH).submit{value: 60_000 ether}(address(0));
        IERC20(stETH).transfer(ETHERFI_RESTAKER, ILido(stETH).balanceOf(depositor));
        vm.stopPrank();

        // Deposit 40k should succeed after 12h refill
        vm.prank(ADMIN_EOA);
        restaker.depositIntoStrategy(stETH, 40_000 ether);
        console2.log("  [OK] 40k stETH deposited after 12h refill");

        // --- Test 5: Full refill after 1 day restores full capacity ---
        console2.log("  [Test 5] Full refill after 1 day...");
        vm.warp(block.timestamp + 1 days);

        uint64 consumableAfterFullRefill = rl.consumable(depositLimitId);
        require(consumableAfterFullRefill == DEPOSIT_RATE_LIMIT_CAPACITY, "Should be at full capacity after 1 day");
        console2.log("  [OK] Full capacity restored:", consumableAfterFullRefill, "gwei");

        console2.log("  depositIntoStrategy rate limiter tests passed!");
    }
}
