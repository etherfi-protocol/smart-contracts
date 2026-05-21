// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {EtherFiTimelock} from "../../../src/EtherFiTimelock.sol";
import {RoleRegistry} from "../../../src/RoleRegistry.sol";
import {EtherFiRateLimiter} from "../../../src/EtherFiRateLimiter.sol";

import {EETH as EETHToken} from "../../../src/EETH.sol";
import {WeETH as WeETHToken} from "../../../src/WeETH.sol";
import {LiquidityPool} from "../../../src/LiquidityPool.sol";
import {WithdrawRequestNFT} from "../../../src/WithdrawRequestNFT.sol";
import {Liquifier} from "../../../src/Liquifier.sol";
import {EtherFiNodesManager} from "../../../src/EtherFiNodesManager.sol";

import {Deployed} from "../../deploys/Deployed.s.sol";
import {Utils} from "../../utils/utils.sol";

/**
 * 26Q2 Security Upgrades - Timelocked Upgrade + Configuration
 *
 * See ROLE_MIGRATION.md in this directory for the role-by-role plan and the
 * operational parameter table. EVERY constant in this file is intentionally
 * left at address(0) / 0; you must fill them in before broadcast.
 *
 * Layout:
 *   Batch A - UPGRADE_TIMELOCK (10-day delay)
 *       proxy upgrades + post-upgrade migrations + role grants/revokes on
 *       UPGRADE_TIMELOCK_ROLE / OPERATION_TIMELOCK_ROLE / OPERATION_MULTISIG_ROLE.
 *
 *   Batch B - OPERATING_TIMELOCK (2-day delay)
 *       rate limiter buckets, PausableUntil durations, operational role
 *       grants/revokes (GUARDIAN, SUPER_GUARDIAN, ORACLE/HOUSEKEEPING/EXECUTOR
 *       /EIGENPOD/MEMBERSHIP_MANAGER operations).
 *
 * Each batch emits schedule.json + execute.json and dry-runs on the fork.
 */
contract SecurityUpgradesScript is Script, Deployed, Utils {
    // ─────────────────────────────────────────────────────────────────────
    // DEPLOYED IMPLEMENTATIONS - populate from deploy.s.sol output
    // ─────────────────────────────────────────────────────────────────────
    address constant blacklisterProxy             = address(0);
    address constant eEthImpl                     = address(0);
    address constant weEthImpl                    = address(0);
    address constant liquidityPoolImpl            = address(0);
    address constant withdrawRequestNFTImpl       = address(0);
    address constant liquifierImpl                = address(0);
    address constant etherFiAdminImpl             = address(0);
    address constant etherFiOracleImpl            = address(0);
    address constant etherFiRedemptionManagerImpl = address(0);
    address constant etherFiRestakerImpl          = address(0);
    address constant etherFiNodesManagerImpl      = address(0);
    address constant stakingManagerImpl           = address(0);
    address constant auctionManagerImpl           = address(0);
    address constant nodeOperatorManagerImpl      = address(0);
    address constant membershipManagerImpl        = address(0);
    address constant membershipNFTImpl            = address(0);
    address constant bucketRateLimiterImpl        = address(0);

    // ─────────────────────────────────────────────────────────────────────
    // ROLE GRANT / REVOKE TARGETS - see ROLE_MIGRATION.md for each row
    // (set every constant to 0 means "no change" for that row.)
    // ─────────────────────────────────────────────────────────────────────

    // Tier roles
    address constant GRANT_UPGRADE_TIMELOCK_ROLE  = address(0);
    address constant REVOKE_UPGRADE_TIMELOCK_ROLE = address(0);
    address constant GRANT_OPERATION_TIMELOCK_ROLE  = address(0);
    address constant REVOKE_OPERATION_TIMELOCK_ROLE = address(0);
    address constant GRANT_OPERATION_MULTISIG_ROLE  = address(0);
    address constant REVOKE_OPERATION_MULTISIG_ROLE = address(0);

    // Guardian tier
    address constant GRANT_GUARDIAN_ROLE_HYPERNATIVE = address(0);
    address constant GRANT_GUARDIAN_ROLE_EOA         = address(0);
    address constant REVOKE_GUARDIAN_ROLE_LEGACY     = address(0);
    address constant GRANT_SUPER_GUARDIAN_ROLE       = address(0);
    address constant REVOKE_SUPER_GUARDIAN_ROLE      = address(0);

    // Operations roles
    address constant GRANT_ORACLE_OPERATIONS_ROLE          = address(0);
    address constant REVOKE_ORACLE_OPERATIONS_ROLE         = address(0);
    address constant GRANT_HOUSEKEEPING_OPERATIONS_ROLE    = address(0);
    address constant REVOKE_HOUSEKEEPING_OPERATIONS_ROLE   = address(0);
    address constant GRANT_EXECUTOR_OPERATIONS_ROLE        = address(0);
    address constant REVOKE_EXECUTOR_OPERATIONS_ROLE       = address(0);
    address constant GRANT_EIGENPOD_OPERATIONS_ROLE        = address(0);
    address constant REVOKE_EIGENPOD_OPERATIONS_ROLE       = address(0);
    address constant GRANT_MEMBERSHIP_MGR_OPERATIONS_ROLE  = address(0);
    address constant REVOKE_MEMBERSHIP_MGR_OPERATIONS_ROLE = address(0);

    // ─────────────────────────────────────────────────────────────────────
    // OPERATIONAL PARAMETERS - see ROLE_MIGRATION.md §Operational Parameters
    // ─────────────────────────────────────────────────────────────────────

    // EETH / WeETH rate limit buckets (gwei units)
    uint64 constant EETH_MINT_CAPACITY       = 0;
    uint64 constant EETH_MINT_REFILL_RATE    = 0;
    uint64 constant EETH_BURN_CAPACITY       = 0;
    uint64 constant EETH_BURN_REFILL_RATE    = 0;
    uint64 constant EETH_TRANSFER_CAPACITY   = 0;
    uint64 constant EETH_TRANSFER_REFILL_RATE = 0;
    uint64 constant WEETH_MINT_CAPACITY      = 0;
    uint64 constant WEETH_MINT_REFILL_RATE   = 0;
    uint64 constant WEETH_BURN_CAPACITY      = 0;
    uint64 constant WEETH_BURN_REFILL_RATE   = 0;
    uint64 constant WEETH_TRANSFER_CAPACITY  = 0;
    uint64 constant WEETH_TRANSFER_REFILL_RATE = 0;

    // PausableUntil durations per contract (seconds). Must be in [8h, 30d].
    uint256 constant PAUSE_UNTIL_EETH                     = 0;
    uint256 constant PAUSE_UNTIL_WEETH                    = 0;
    uint256 constant PAUSE_UNTIL_LIQUIDITY_POOL           = 0;
    uint256 constant PAUSE_UNTIL_WITHDRAW_REQUEST_NFT     = 0;
    uint256 constant PAUSE_UNTIL_LIQUIFIER                = 0;
    uint256 constant PAUSE_UNTIL_ETHERFI_NODES_MANAGER    = 0;
    uint256 constant PAUSE_UNTIL_ETHERFI_ADMIN            = 0;
    uint256 constant PAUSE_UNTIL_ETHERFI_REDEMPTION_MGR   = 0;
    uint256 constant PAUSE_UNTIL_MEMBERSHIP_MANAGER       = 0;
    uint256 constant PAUSE_UNTIL_MEMBERSHIP_NFT           = 0;
    uint256 constant PAUSE_UNTIL_AUCTION_MANAGER          = 0;
    uint256 constant PAUSE_UNTIL_NODE_OPERATOR_MANAGER    = 0;

    // ─────────────────────────────────────────────────────────────────────
    // Bucket IDs (mirror token contracts)
    // ─────────────────────────────────────────────────────────────────────
    bytes32 constant EETH_MINT_LIMIT_ID      = keccak256("EETH_MINT_LIMIT_ID");
    bytes32 constant EETH_BURN_LIMIT_ID      = keccak256("EETH_BURN_LIMIT_ID");
    bytes32 constant EETH_TRANSFER_LIMIT_ID  = keccak256("EETH_TRANSFER_LIMIT_ID");
    bytes32 constant WEETH_MINT_LIMIT_ID     = keccak256("WEETH_MINT_LIMIT_ID");
    bytes32 constant WEETH_BURN_LIMIT_ID     = keccak256("WEETH_BURN_LIMIT_ID");
    bytes32 constant WEETH_TRANSFER_LIMIT_ID = keccak256("WEETH_TRANSFER_LIMIT_ID");

    EtherFiTimelock constant upgradeTimelock   = EtherFiTimelock(payable(UPGRADE_TIMELOCK));
    EtherFiTimelock constant operatingTimelock = EtherFiTimelock(payable(OPERATING_TIMELOCK));
    RoleRegistry constant roleRegistry         = RoleRegistry(ROLE_REGISTRY);

    uint256 constant UPGRADE_TIMELOCK_DELAY   = 10 days; // 864_000 s
    uint256 constant OPERATING_TIMELOCK_DELAY = 2 days;  // 172_800 s

    string constant OUT_DIR = "script/upgrades/security-upgrades";

    function run() public {
        string memory forkUrl = vm.envString("MAINNET_RPC_URL");
        vm.selectFork(vm.createFork(forkUrl));

        _preflight();
        _runUpgradeBatch();
        _runOperatingBatch();
        _verifyPostUpgrade();
    }

    /// @dev Fail loudly the moment a required constant is unset, before we
    ///      generate misleading calldata or burn a fork run.
    function _preflight() internal pure {
        require(blacklisterProxy != address(0), "preflight: blacklisterProxy unset");
        require(eEthImpl != address(0), "preflight: eEthImpl unset");
        require(weEthImpl != address(0), "preflight: weEthImpl unset");
        require(liquidityPoolImpl != address(0), "preflight: liquidityPoolImpl unset");
        require(withdrawRequestNFTImpl != address(0), "preflight: withdrawRequestNFTImpl unset");
        require(liquifierImpl != address(0), "preflight: liquifierImpl unset");
        require(etherFiAdminImpl != address(0), "preflight: etherFiAdminImpl unset");
        require(etherFiOracleImpl != address(0), "preflight: etherFiOracleImpl unset");
        require(etherFiRedemptionManagerImpl != address(0), "preflight: etherFiRedemptionManagerImpl unset");
        require(etherFiRestakerImpl != address(0), "preflight: etherFiRestakerImpl unset");
        require(etherFiNodesManagerImpl != address(0), "preflight: etherFiNodesManagerImpl unset");
        require(stakingManagerImpl != address(0), "preflight: stakingManagerImpl unset");
        require(auctionManagerImpl != address(0), "preflight: auctionManagerImpl unset");
        require(nodeOperatorManagerImpl != address(0), "preflight: nodeOperatorManagerImpl unset");
        require(membershipManagerImpl != address(0), "preflight: membershipManagerImpl unset");
        require(membershipNFTImpl != address(0), "preflight: membershipNFTImpl unset");
        require(bucketRateLimiterImpl != address(0), "preflight: bucketRateLimiterImpl unset");

        require(EETH_MINT_CAPACITY != 0,       "preflight: EETH_MINT_CAPACITY unset");
        require(EETH_MINT_REFILL_RATE != 0,    "preflight: EETH_MINT_REFILL_RATE unset");
        require(EETH_BURN_CAPACITY != 0,       "preflight: EETH_BURN_CAPACITY unset");
        require(EETH_BURN_REFILL_RATE != 0,    "preflight: EETH_BURN_REFILL_RATE unset");
        require(EETH_TRANSFER_CAPACITY != 0,   "preflight: EETH_TRANSFER_CAPACITY unset");
        require(EETH_TRANSFER_REFILL_RATE != 0,"preflight: EETH_TRANSFER_REFILL_RATE unset");
        require(WEETH_MINT_CAPACITY != 0,      "preflight: WEETH_MINT_CAPACITY unset");
        require(WEETH_MINT_REFILL_RATE != 0,   "preflight: WEETH_MINT_REFILL_RATE unset");
        require(WEETH_BURN_CAPACITY != 0,      "preflight: WEETH_BURN_CAPACITY unset");
        require(WEETH_BURN_REFILL_RATE != 0,   "preflight: WEETH_BURN_REFILL_RATE unset");
        require(WEETH_TRANSFER_CAPACITY != 0,  "preflight: WEETH_TRANSFER_CAPACITY unset");
        require(WEETH_TRANSFER_REFILL_RATE != 0,"preflight: WEETH_TRANSFER_REFILL_RATE unset");

        require(PAUSE_UNTIL_EETH != 0,                   "preflight: PAUSE_UNTIL_EETH unset");
        require(PAUSE_UNTIL_WEETH != 0,                  "preflight: PAUSE_UNTIL_WEETH unset");
        require(PAUSE_UNTIL_LIQUIDITY_POOL != 0,         "preflight: PAUSE_UNTIL_LIQUIDITY_POOL unset");
        require(PAUSE_UNTIL_WITHDRAW_REQUEST_NFT != 0,   "preflight: PAUSE_UNTIL_WITHDRAW_REQUEST_NFT unset");
        require(PAUSE_UNTIL_LIQUIFIER != 0,              "preflight: PAUSE_UNTIL_LIQUIFIER unset");
        require(PAUSE_UNTIL_ETHERFI_NODES_MANAGER != 0,  "preflight: PAUSE_UNTIL_ETHERFI_NODES_MANAGER unset");
        require(PAUSE_UNTIL_ETHERFI_ADMIN != 0,          "preflight: PAUSE_UNTIL_ETHERFI_ADMIN unset");
        require(PAUSE_UNTIL_ETHERFI_REDEMPTION_MGR != 0, "preflight: PAUSE_UNTIL_ETHERFI_REDEMPTION_MGR unset");
        require(PAUSE_UNTIL_MEMBERSHIP_MANAGER != 0,     "preflight: PAUSE_UNTIL_MEMBERSHIP_MANAGER unset");
        require(PAUSE_UNTIL_MEMBERSHIP_NFT != 0,         "preflight: PAUSE_UNTIL_MEMBERSHIP_NFT unset");
        require(PAUSE_UNTIL_AUCTION_MANAGER != 0,        "preflight: PAUSE_UNTIL_AUCTION_MANAGER unset");
        require(PAUSE_UNTIL_NODE_OPERATOR_MANAGER != 0,  "preflight: PAUSE_UNTIL_NODE_OPERATOR_MANAGER unset");
    }

    //--------------------------------------------------------------------------------------
    //--------- Batch A - UPGRADE_TIMELOCK (10 days) : proxy upgrades + role admin --------
    //--------------------------------------------------------------------------------------
    function _runUpgradeBatch() internal {
        console2.log("================================================");
        console2.log("== Batch A: UPGRADE_TIMELOCK (10d) - upgrades ==");
        console2.log("================================================");

        // Build dynamically so we can omit no-op role changes (addr == 0).
        address[] memory targets = new address[](40);
        bytes[]   memory data    = new bytes[](40);
        uint256[] memory values  = new uint256[](40);
        uint256 i;

        // --- proxy upgrades ---
        (targets[i], data[i]) = (EETH,                       _upgradeTo(eEthImpl));                   i++;
        (targets[i], data[i]) = (WEETH,                      _upgradeTo(weEthImpl));                  i++;
        (targets[i], data[i]) = (LIQUIDITY_POOL,             _upgradeTo(liquidityPoolImpl));          i++;
        (targets[i], data[i]) = (WITHDRAW_REQUEST_NFT,       _upgradeTo(withdrawRequestNFTImpl));     i++;
        (targets[i], data[i]) = (LIQUIFIER,                  _upgradeTo(liquifierImpl));              i++;
        (targets[i], data[i]) = (ETHERFI_ADMIN,              _upgradeTo(etherFiAdminImpl));           i++;
        (targets[i], data[i]) = (ETHERFI_ORACLE,             _upgradeTo(etherFiOracleImpl));          i++;
        (targets[i], data[i]) = (ETHERFI_REDEMPTION_MANAGER, _upgradeTo(etherFiRedemptionManagerImpl)); i++;
        (targets[i], data[i]) = (ETHERFI_RESTAKER,           _upgradeTo(etherFiRestakerImpl));        i++;
        (targets[i], data[i]) = (ETHERFI_NODES_MANAGER,      _upgradeTo(etherFiNodesManagerImpl));    i++;
        (targets[i], data[i]) = (STAKING_MANAGER,            _upgradeTo(stakingManagerImpl));         i++;
        (targets[i], data[i]) = (AUCTION_MANAGER,            _upgradeTo(auctionManagerImpl));         i++;
        (targets[i], data[i]) = (NODE_OPERATOR_MANAGER,      _upgradeTo(nodeOperatorManagerImpl));    i++;
        (targets[i], data[i]) = (MEMBERSHIP_MANAGER,         _upgradeTo(membershipManagerImpl));      i++;
        (targets[i], data[i]) = (MEMBERSHIP_NFT,             _upgradeTo(membershipNFTImpl));          i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER,       _upgradeTo(bucketRateLimiterImpl));      i++;

        // --- one-shot post-upgrade migrations ---
        (targets[i], data[i]) = (LIQUIDITY_POOL,
            abi.encodeWithSelector(LiquidityPool.initializeOnUpgradeV2.selector));                    i++;
        (targets[i], data[i]) = (WITHDRAW_REQUEST_NFT,
            abi.encodeWithSelector(WithdrawRequestNFT.initializeShareRateFreezeUpgrade.selector));    i++;

        // --- tier role rotations (only the timelocks themselves can edit these) ---
        i = _maybeRoleGrant (targets, data, i, roleRegistry.UPGRADE_TIMELOCK_ROLE(),   GRANT_UPGRADE_TIMELOCK_ROLE);
        i = _maybeRoleRevoke(targets, data, i, roleRegistry.UPGRADE_TIMELOCK_ROLE(),   REVOKE_UPGRADE_TIMELOCK_ROLE);
        i = _maybeRoleGrant (targets, data, i, roleRegistry.OPERATION_TIMELOCK_ROLE(), GRANT_OPERATION_TIMELOCK_ROLE);
        i = _maybeRoleRevoke(targets, data, i, roleRegistry.OPERATION_TIMELOCK_ROLE(), REVOKE_OPERATION_TIMELOCK_ROLE);
        i = _maybeRoleGrant (targets, data, i, roleRegistry.OPERATION_MULTISIG_ROLE(), GRANT_OPERATION_MULTISIG_ROLE);
        i = _maybeRoleRevoke(targets, data, i, roleRegistry.OPERATION_MULTISIG_ROLE(), REVOKE_OPERATION_MULTISIG_ROLE);

        _shrinkAndEmit(
            "Batch A - Upgrade",
            upgradeTimelock,
            UPGRADE_TIMELOCK,
            ETHERFI_UPGRADE_ADMIN,
            UPGRADE_TIMELOCK_DELAY,
            targets,
            values,
            data,
            i,
            keccak256(abi.encode("security-upgrades-v1-batchA", block.number)),
            "upgrade_schedule.json",
            "upgrade_execute.json"
        );
    }

    //--------------------------------------------------------------------------------------
    //--------- Batch B - OPERATING_TIMELOCK (2 days) : ops config + role grants ----------
    //--------------------------------------------------------------------------------------
    function _runOperatingBatch() internal {
        console2.log("================================================");
        console2.log("== Batch B: OPERATING_TIMELOCK (2d) - config  ==");
        console2.log("================================================");

        address[] memory targets = new address[](60);
        bytes[]   memory data    = new bytes[](60);
        uint256[] memory values  = new uint256[](60);
        uint256 i;

        // ---- rate limiter buckets ----
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _createLimiter(EETH_MINT_LIMIT_ID,      EETH_MINT_CAPACITY,      EETH_MINT_REFILL_RATE));      i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _createLimiter(EETH_BURN_LIMIT_ID,      EETH_BURN_CAPACITY,      EETH_BURN_REFILL_RATE));      i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _createLimiter(EETH_TRANSFER_LIMIT_ID,  EETH_TRANSFER_CAPACITY,  EETH_TRANSFER_REFILL_RATE));  i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _createLimiter(WEETH_MINT_LIMIT_ID,     WEETH_MINT_CAPACITY,     WEETH_MINT_REFILL_RATE));     i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _createLimiter(WEETH_BURN_LIMIT_ID,     WEETH_BURN_CAPACITY,     WEETH_BURN_REFILL_RATE));     i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _createLimiter(WEETH_TRANSFER_LIMIT_ID, WEETH_TRANSFER_CAPACITY, WEETH_TRANSFER_REFILL_RATE)); i++;

        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _updateConsumer(EETH_MINT_LIMIT_ID,      EETH));  i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _updateConsumer(EETH_BURN_LIMIT_ID,      EETH));  i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _updateConsumer(EETH_TRANSFER_LIMIT_ID,  EETH));  i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _updateConsumer(WEETH_MINT_LIMIT_ID,     WEETH)); i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _updateConsumer(WEETH_BURN_LIMIT_ID,     WEETH)); i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _updateConsumer(WEETH_TRANSFER_LIMIT_ID, WEETH)); i++;

        // ---- PausableUntil durations (per contract; each value mandated > 0 by preflight) ----
        (targets[i], data[i]) = (EETH,                       _pauseDur(PAUSE_UNTIL_EETH));                   i++;
        (targets[i], data[i]) = (WEETH,                      _pauseDur(PAUSE_UNTIL_WEETH));                  i++;
        (targets[i], data[i]) = (LIQUIDITY_POOL,             _pauseDur(PAUSE_UNTIL_LIQUIDITY_POOL));         i++;
        (targets[i], data[i]) = (WITHDRAW_REQUEST_NFT,       _pauseDur(PAUSE_UNTIL_WITHDRAW_REQUEST_NFT));   i++;
        (targets[i], data[i]) = (LIQUIFIER,                  _pauseDur(PAUSE_UNTIL_LIQUIFIER));              i++;
        (targets[i], data[i]) = (ETHERFI_NODES_MANAGER,      _pauseDur(PAUSE_UNTIL_ETHERFI_NODES_MANAGER));  i++;
        (targets[i], data[i]) = (ETHERFI_ADMIN,              _pauseDur(PAUSE_UNTIL_ETHERFI_ADMIN));          i++;
        (targets[i], data[i]) = (ETHERFI_REDEMPTION_MANAGER, _pauseDur(PAUSE_UNTIL_ETHERFI_REDEMPTION_MGR)); i++;
        (targets[i], data[i]) = (MEMBERSHIP_MANAGER,         _pauseDur(PAUSE_UNTIL_MEMBERSHIP_MANAGER));     i++;
        (targets[i], data[i]) = (MEMBERSHIP_NFT,             _pauseDur(PAUSE_UNTIL_MEMBERSHIP_NFT));         i++;
        (targets[i], data[i]) = (AUCTION_MANAGER,            _pauseDur(PAUSE_UNTIL_AUCTION_MANAGER));        i++;
        (targets[i], data[i]) = (NODE_OPERATOR_MANAGER,      _pauseDur(PAUSE_UNTIL_NODE_OPERATOR_MANAGER));  i++;

        // ---- Role grants/revokes (Guardian + ops tiers) ----
        i = _maybeRoleGrant (targets, data, i, roleRegistry.GUARDIAN_ROLE(),       GRANT_GUARDIAN_ROLE_HYPERNATIVE);
        i = _maybeRoleGrant (targets, data, i, roleRegistry.GUARDIAN_ROLE(),       GRANT_GUARDIAN_ROLE_EOA);
        i = _maybeRoleRevoke(targets, data, i, roleRegistry.GUARDIAN_ROLE(),       REVOKE_GUARDIAN_ROLE_LEGACY);
        i = _maybeRoleGrant (targets, data, i, roleRegistry.SUPER_GUARDIAN_ROLE(), GRANT_SUPER_GUARDIAN_ROLE);
        i = _maybeRoleRevoke(targets, data, i, roleRegistry.SUPER_GUARDIAN_ROLE(), REVOKE_SUPER_GUARDIAN_ROLE);

        i = _maybeRoleGrant (targets, data, i, roleRegistry.ORACLE_OPERATIONS_ROLE(),       GRANT_ORACLE_OPERATIONS_ROLE);
        i = _maybeRoleRevoke(targets, data, i, roleRegistry.ORACLE_OPERATIONS_ROLE(),       REVOKE_ORACLE_OPERATIONS_ROLE);
        i = _maybeRoleGrant (targets, data, i, roleRegistry.HOUSEKEEPING_OPERATIONS_ROLE(), GRANT_HOUSEKEEPING_OPERATIONS_ROLE);
        i = _maybeRoleRevoke(targets, data, i, roleRegistry.HOUSEKEEPING_OPERATIONS_ROLE(), REVOKE_HOUSEKEEPING_OPERATIONS_ROLE);
        i = _maybeRoleGrant (targets, data, i, roleRegistry.EXECUTOR_OPERATIONS_ROLE(),     GRANT_EXECUTOR_OPERATIONS_ROLE);
        i = _maybeRoleRevoke(targets, data, i, roleRegistry.EXECUTOR_OPERATIONS_ROLE(),     REVOKE_EXECUTOR_OPERATIONS_ROLE);
        i = _maybeRoleGrant (targets, data, i, roleRegistry.EIGENPOD_OPERATIONS_ROLE(),     GRANT_EIGENPOD_OPERATIONS_ROLE);
        i = _maybeRoleRevoke(targets, data, i, roleRegistry.EIGENPOD_OPERATIONS_ROLE(),     REVOKE_EIGENPOD_OPERATIONS_ROLE);

        // MembershipManager-internal role uses its contract-local constant.
        bytes32 mmRole = keccak256("MEMBERSHIP_MANAGER_OPERATIONS_ROLE");
        i = _maybeRoleGrant (targets, data, i, mmRole, GRANT_MEMBERSHIP_MGR_OPERATIONS_ROLE);
        i = _maybeRoleRevoke(targets, data, i, mmRole, REVOKE_MEMBERSHIP_MGR_OPERATIONS_ROLE);

        _shrinkAndEmit(
            "Batch B - Operating",
            operatingTimelock,
            OPERATING_TIMELOCK,
            ETHERFI_OPERATING_ADMIN,
            OPERATING_TIMELOCK_DELAY,
            targets,
            values,
            data,
            i,
            keccak256(abi.encode("security-upgrades-v1-batchB", block.number)),
            "ops_schedule.json",
            "ops_execute.json"
        );
    }

    function _verifyPostUpgrade() internal view {
        console2.log("================================================");
        console2.log("======== Post-upgrade verification =============");
        console2.log("================================================");

        EtherFiRateLimiter rl = EtherFiRateLimiter(payable(ETHERFI_RATE_LIMITER));
        require(rl.limitExists(EETH_MINT_LIMIT_ID),      "EETH_MINT bucket missing");
        require(rl.limitExists(EETH_BURN_LIMIT_ID),      "EETH_BURN bucket missing");
        require(rl.limitExists(EETH_TRANSFER_LIMIT_ID),  "EETH_TRANSFER bucket missing");
        require(rl.limitExists(WEETH_MINT_LIMIT_ID),     "WEETH_MINT bucket missing");
        require(rl.limitExists(WEETH_BURN_LIMIT_ID),     "WEETH_BURN bucket missing");
        require(rl.limitExists(WEETH_TRANSFER_LIMIT_ID), "WEETH_TRANSFER bucket missing");
        require(rl.isConsumerAllowed(EETH_MINT_LIMIT_ID,  EETH),  "EETH not allowed consumer");
        require(rl.isConsumerAllowed(WEETH_MINT_LIMIT_ID, WEETH), "WeETH not allowed consumer");

        require(EETHToken(EETH).pauseUntilDuration()                            == PAUSE_UNTIL_EETH,                   "EETH pause duration mismatch");
        require(WeETHToken(WEETH).pauseUntilDuration()                          == PAUSE_UNTIL_WEETH,                  "WeETH pause duration mismatch");
        require(LiquidityPool(payable(LIQUIDITY_POOL)).pauseUntilDuration()     == PAUSE_UNTIL_LIQUIDITY_POOL,         "LP pause duration mismatch");
        require(WithdrawRequestNFT(payable(WITHDRAW_REQUEST_NFT)).pauseUntilDuration() == PAUSE_UNTIL_WITHDRAW_REQUEST_NFT, "NFT pause duration mismatch");
        require(Liquifier(payable(LIQUIFIER)).pauseUntilDuration()              == PAUSE_UNTIL_LIQUIFIER,              "Liquifier pause duration mismatch");

        console2.log("[OK] Rate limiter buckets configured");
        console2.log("[OK] PausableUntil durations configured");
        console2.log("================================================");
    }

    //--------------------------------------------------------------------------------------
    //--------------------------------- Helpers --------------------------------------------
    //--------------------------------------------------------------------------------------
    function _upgradeTo(address newImpl) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, newImpl);
    }

    function _createLimiter(bytes32 id, uint64 capacity, uint64 refillRate) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(EtherFiRateLimiter.createNewLimiter.selector, id, capacity, refillRate);
    }

    function _updateConsumer(bytes32 id, address consumer) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(EtherFiRateLimiter.updateConsumers.selector, id, consumer, true);
    }

    function _pauseDur(uint256 d) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("setPauseUntilDuration(uint256)", d);
    }

    function _maybeRoleGrant(
        address[] memory targets,
        bytes[]   memory data,
        uint256          i,
        bytes32          role,
        address          account
    ) internal view returns (uint256) {
        if (account == address(0)) return i;
        targets[i] = ROLE_REGISTRY;
        data[i]    = abi.encodeWithSelector(RoleRegistry.grantRole.selector, role, account);
        return i + 1;
    }

    function _maybeRoleRevoke(
        address[] memory targets,
        bytes[]   memory data,
        uint256          i,
        bytes32          role,
        address          account
    ) internal view returns (uint256) {
        if (account == address(0)) return i;
        targets[i] = ROLE_REGISTRY;
        data[i]    = abi.encodeWithSelector(RoleRegistry.revokeRole.selector, role, account);
        return i + 1;
    }

    function _shrinkAndEmit(
        string memory label,
        EtherFiTimelock timelock,
        address timelockAddr,
        address adminSafe,
        uint256 minDelay,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory data,
        uint256 used,
        bytes32 salt,
        string memory scheduleFile,
        string memory executeFile
    ) internal {
        address[] memory tt = new address[](used);
        uint256[] memory vv = new uint256[](used);
        bytes[]   memory dd = new bytes[](used);
        for (uint256 k = 0; k < used; k++) {
            tt[k] = targets[k];
            vv[k] = values[k];
            dd[k] = data[k];
        }

        bytes memory scheduleCalldata = abi.encodeWithSelector(
            timelock.scheduleBatch.selector,
            tt, vv, dd, bytes32(0), salt, minDelay
        );
        bytes memory executeCalldata = abi.encodeWithSelector(
            timelock.executeBatch.selector,
            tt, vv, dd, bytes32(0), salt
        );

        writeSafeJson(OUT_DIR, scheduleFile, adminSafe, timelockAddr, 0, scheduleCalldata, 1);
        writeSafeJson(OUT_DIR, executeFile,  adminSafe, timelockAddr, 0, executeCalldata,  1);

        console2.log(string.concat("=== Dry-running ", label, " on fork ==="));
        vm.startPrank(adminSafe);
        timelock.scheduleBatch(tt, vv, dd, bytes32(0), salt, minDelay);
        vm.warp(block.timestamp + minDelay + 1);
        timelock.executeBatch(tt, vv, dd, bytes32(0), salt);
        vm.stopPrank();
        console2.log(string.concat("[OK] ", label, " executed on fork"));
        console2.log("");
    }
}
