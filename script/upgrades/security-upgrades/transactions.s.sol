// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {EtherFiTimelock} from "@etherfi/governance/EtherFiTimelock.sol";
import {RoleRegistry} from "@etherfi/governance/RoleRegistry.sol";
import {EtherFiRateLimiter} from "@etherfi/governance/rate-limiting/EtherFiRateLimiter.sol";

import {EETH as EETHToken} from "@etherfi/core/EETH.sol";
import {WeETH as WeETHToken} from "@etherfi/core/WeETH.sol";
import {LiquidityPool} from "@etherfi/core/LiquidityPool.sol";
import {WithdrawRequestNFT} from "@etherfi/withdrawals/WithdrawRequestNFT.sol";
import {Liquifier} from "@etherfi/deposits/Liquifier.sol";
import {EtherFiAdmin} from "@etherfi/oracle/EtherFiAdmin.sol";
import {EtherFiOracle} from "@etherfi/oracle/EtherFiOracle.sol";
import {EtherFiRedemptionManager} from "@etherfi/withdrawals/EtherFiRedemptionManager.sol";
import {EtherFiRestaker} from "@etherfi/restaking/EtherFiRestaker.sol";
import {EtherFiNodesManager} from "@etherfi/staking/EtherFiNodesManager.sol";
import {EtherFiNode} from "@etherfi/staking/EtherFiNode.sol";
import {StakingManager} from "@etherfi/staking/StakingManager.sol";
import {AuctionManager} from "@etherfi/staking/AuctionManager.sol";
import {NodeOperatorManager} from "@etherfi/staking/NodeOperatorManager.sol";
import {MembershipManager} from "@etherfi/membership/MembershipManager.sol";
import {MembershipNFT} from "@etherfi/membership/MembershipNFT.sol";
import {PriorityWithdrawalQueue} from "@etherfi/withdrawals/PriorityWithdrawalQueue.sol";
import {EtherFiRewardsRouter} from "@etherfi/rewards/EtherFiRewardsRouter.sol";
import {RestakingRewardsRouter} from "@etherfi/restaking/RestakingRewardsRouter.sol";
import {CumulativeMerkleRewardsDistributor} from "@etherfi/rewards/CumulativeMerkleRewardsDistributor.sol";
import {DepositAdapter} from "@etherfi/deposits/DepositAdapter.sol";
import {WeETHWithdrawAdapter} from "@etherfi/withdrawals/WeETHWithdrawAdapter.sol";

import {ContractCodeChecker} from "@scripts/ContractCodeChecker.sol";
import {Deployed} from "@scripts/deploys/Deployed.s.sol";
import {Utils} from "@scripts/utils/utils.sol";

/**
 * 26Q2 Security Upgrades - Timelocked Upgrade + Configuration
 *
 * See ROLE_MIGRATION.md for the role plan and operational parameter table.
 * Every constant left at address(0) / 0 must be filled in before broadcast;
 * `_preflight()` reverts otherwise.
 *
 * `run()` follows the standard upgrade-script pattern:
 *   1. verifyDeployedBytecode      — fresh deploys match the recorded impls
 *   2. takePreUpgradeSnapshots     — owners + paused, per upgraded proxy
 *   3. executeUpgrade              — Batch A (UPGRADE_TIMELOCK, 10d)
 *   4. verifyUpgrades              — ERC1967 implementation slot == new impl
 *   5. verifyImmutablePreservation — immutables on each new impl match wiring
 *   6. verifyAccessControlPreservation — owner + paused + init state unchanged
 *
 *   7. executeRoleGrants           — direct from ETHERFI_UPGRADE_ADMIN (RoleRegistry owner, no timelock)
 *   8. executeLpWithdrawBounds     — direct from ETHERFI_OPERATING_ADMIN (operating multisig, no timelock)
 *   9. executeOperatingConfig      — Batch B (OPERATING_TIMELOCK, 2d)
 *  10. verifyOperatingConfig       — rate-limiter buckets + pause durations set + roles granted + LP withdraw bounds
 */
contract SecurityUpgradesScript is Script, Deployed, Utils {
    // ─────────────────────────────────────────────────────────────────────
    // DEPLOYED IMPLEMENTATIONS - populate from deploy.s.sol output
    // ─────────────────────────────────────────────────────────────────────
    address constant blacklisterProxy             = address(0);
    address constant revokeAdminProxy             = address(0);
    address constant roleRegistryImpl             = address(0);
    address constant eEthImpl                     = address(0);
    address constant weEthImpl                    = address(0);
    address constant liquidityPoolImpl            = address(0);
    address constant withdrawRequestNFTImpl       = address(0);
    address constant liquifierImpl                = address(0);
    address constant etherFiAdminImpl             = address(0);
    address constant etherFiOracleImpl            = address(0);
    address constant etherFiRedemptionManagerImpl = address(0);
    address constant etherFiRestakerImpl          = address(0);
    address constant etherFiNodeImpl              = address(0);
    address constant etherFiNodesManagerImpl      = address(0);
    address constant stakingManagerImpl           = address(0);
    address constant auctionManagerImpl           = address(0);
    address constant nodeOperatorManagerImpl      = address(0);
    address constant membershipManagerImpl        = address(0);
    address constant membershipNFTImpl            = address(0);
    address constant etherFiRateLimiterImpl        = address(0);

    // Peripheral UUPS proxies touched by PR #385 — impls only, existing proxies are reused.
    address constant priorityWithdrawalQueueImpl            = address(0);
    address constant etherFiRewardsRouterImpl               = address(0);
    address constant restakingRewardsRouterImpl             = address(0);
    address constant cumulativeMerkleRewardsDistributorImpl = address(0);
    address constant depositAdapterImpl                     = address(0);
    address constant weETHWithdrawAdapterImpl               = address(0);

    // ─────────────────────────────────────────────────────────────────────
    // CONSTRUCTOR PARAMS - MUST MATCH deploy.s.sol exactly.
    // Re-stated here so verifyDeployedBytecode can rebuild each impl locally.
    // ─────────────────────────────────────────────────────────────────────
    // Liquifier
    address constant STETH_PRICE_FEED = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    address constant STETH_ETH_CURVE_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    uint256 constant LIQUIFIER_MIN_DISCOUNT_BPS = 100;
    uint256 constant LIQUIFIER_STALE_PRICE_WINDOW = 7 days;
    uint256 constant LIQUIFIER_MAX_PRICE_DEVIATION_BPS = 500;

    // EtherFiRedemptionManager
    uint256 constant RM_MAX_EXIT_FEE_SPLIT_TO_TREASURY_BPS = 10_000;
    uint256 constant RM_MAX_EXIT_FEE_BPS                   = 500;
    uint256 constant RM_MAX_LOW_WATERMARK_BPS_OF_TVL       = 2_000;

    // EtherFiAdmin
    int256  constant ADMIN_MAX_REBASE_APR_BPS                       = 1_000;
    uint256 constant ADMIN_MAX_VALIDATOR_TASK_BATCH_SIZE            = 100;
    uint256 constant ADMIN_STALE_ORACLE_REPORT_BLOCK_WINDOW         = 7200 * 7;
    uint256 constant ADMIN_MAX_FINALIZED_WITHDRAWAL_AMOUNT_PER_DAY  = 100_000 ether;
    uint256 constant ADMIN_MAX_VALIDATORS_TO_APPROVE_PER_DAY        = 1_000;
    uint256 constant ADMIN_MAX_REQUESTS_TO_FINALIZE_PER_REPORT      = 2_000;

    // EtherFiOracle
    uint32  constant ORACLE_MIN_QUORUM_SIZE = 3;

    // LiquidityPool
    uint256 constant LP_MIN_AMOUNT_FOR_SHARE = 1 ether;
    // Bounds for LP.requestWithdraw (queued NFT-mint path). Default storage is 0/0,
    // which bricks the path; seeded via Safe tx from ETHERFI_OPERATING_ADMIN after
    // executeRoleGrants() grants it OPERATION_MULTISIG_ROLE. Dummy values for now.
    uint256 constant LP_MIN_WITHDRAW_AMOUNT = 100_000 gwei; // 0.0001 ether
    uint256 constant LP_MAX_WITHDRAW_AMOUNT = 1_000 ether;

    // WithdrawRequestNFT
    uint256 constant WNFT_MIN_ACCEPTABLE_SHARE_RATE = 1;
    uint256 constant WNFT_MAX_ACCEPTABLE_SHARE_RATE = 4 ether;

    // PriorityWithdrawalQueue — must match the value baked into the proxy at genesis.
    uint32  constant PWQ_MIN_DELAY = 1 hours;

    // ─────────────────────────────────────────────────────────────────────
    // ROLE HOLDERS - 3 fixed + 6 user-set.
    // ─────────────────────────────────────────────────────────────────────
    address constant HOLDER_UPGRADE_TIMELOCK_ROLE   = 0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761; // UPGRADE_TIMELOCK
    address constant HOLDER_OPERATION_TIMELOCK_ROLE = 0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a; // OPERATING_TIMELOCK
    address constant HOLDER_OPERATION_MULTISIG_ROLE = 0x2aCA71020De61bb532008049e1Bd41E451aE8AdC; // ETHERFI_OPERATING_ADMIN

    address constant HOLDER_SUPER_GUARDIAN_ROLE          = address(0);
    address constant HOLDER_GUARDIAN_ROLE                = address(0);
    address constant HOLDER_ORACLE_OPERATIONS_ROLE       = address(0);
    address constant HOLDER_HOUSEKEEPING_OPERATIONS_ROLE = address(0);
    address constant HOLDER_EXECUTOR_OPERATIONS_ROLE     = address(0);
    address constant HOLDER_EIGENPOD_OPERATIONS_ROLE     = address(0);

    // ─────────────────────────────────────────────────────────────────────
    // OPERATIONAL PARAMETERS
    // ─────────────────────────────────────────────────────────────────────
    // Token-side global buckets (consumeToken on eETH/weETH paths).
    // Transfer is now per-address (consumeForAddressIfConfigured); no global TRANSFER bucket.
    uint64 constant EETH_MINT_CAPACITY    = 0;
    uint64 constant EETH_MINT_REFILL_RATE = 0;
    uint64 constant EETH_BURN_CAPACITY    = 0;
    uint64 constant EETH_BURN_REFILL_RATE = 0;
    uint64 constant WEETH_MINT_CAPACITY   = 0;
    uint64 constant WEETH_MINT_REFILL_RATE = 0;
    uint64 constant WEETH_BURN_CAPACITY   = 0;
    uint64 constant WEETH_BURN_REFILL_RATE = 0;

    // EtherFiNodesManager buckets (consume).
    uint64 constant UNRESTAKING_CAPACITY            = 0;
    uint64 constant UNRESTAKING_REFILL_RATE         = 0;
    uint64 constant EXIT_REQUEST_CAPACITY           = 0;
    uint64 constant EXIT_REQUEST_REFILL_RATE        = 0;
    uint64 constant CONSOLIDATION_REQUEST_CAPACITY  = 0;
    uint64 constant CONSOLIDATION_REQUEST_REFILL_RATE = 0;

    // EtherFiRestaker buckets (consume).
    uint64 constant STETH_REQUEST_WITHDRAWAL_CAPACITY    = 0;
    uint64 constant STETH_REQUEST_WITHDRAWAL_REFILL_RATE = 0;
    uint64 constant QUEUE_WITHDRAWALS_CAPACITY           = 0;
    uint64 constant QUEUE_WITHDRAWALS_REFILL_RATE        = 0;
    uint64 constant DEPOSIT_INTO_STRATEGY_CAPACITY       = 0;
    uint64 constant DEPOSIT_INTO_STRATEGY_REFILL_RATE    = 0;

    // PAUSE_UNTIL_* targets are gated to contracts that mix in PausableUntil. The
    // four ex-targets (EtherFiAdmin, MembershipManager, MembershipNFT, NodeOperatorManager)
    // have no setPauseUntilDuration and were dropped.
    uint256 constant PAUSE_UNTIL_EETH                                 = 0;
    uint256 constant PAUSE_UNTIL_WEETH                                = 0;
    uint256 constant PAUSE_UNTIL_LIQUIDITY_POOL                       = 0;
    uint256 constant PAUSE_UNTIL_WITHDRAW_REQUEST_NFT                 = 0;
    uint256 constant PAUSE_UNTIL_LIQUIFIER                            = 0;
    uint256 constant PAUSE_UNTIL_ETHERFI_NODES_MANAGER                = 0;
    uint256 constant PAUSE_UNTIL_ETHERFI_REDEMPTION_MGR               = 0;
    uint256 constant PAUSE_UNTIL_AUCTION_MANAGER                      = 0;
    uint256 constant PAUSE_UNTIL_PRIORITY_WITHDRAWAL_QUEUE             = 0;
    uint256 constant PAUSE_UNTIL_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR = 0;
    uint256 constant PAUSE_UNTIL_WEETH_WITHDRAW_ADAPTER               = 0;

    // Bucket IDs — must match the constants declared in the source contracts.
    bytes32 constant EETH_MINT_LIMIT_ID                = keccak256("EETH_MINT_LIMIT_ID");
    bytes32 constant EETH_BURN_LIMIT_ID                = keccak256("EETH_BURN_LIMIT_ID");
    bytes32 constant WEETH_MINT_LIMIT_ID               = keccak256("WEETH_MINT_LIMIT_ID");
    bytes32 constant WEETH_BURN_LIMIT_ID               = keccak256("WEETH_BURN_LIMIT_ID");

    bytes32 constant UNRESTAKING_LIMIT_ID              = keccak256("UNRESTAKING_LIMIT_ID");
    bytes32 constant EXIT_REQUEST_LIMIT_ID             = keccak256("EXIT_REQUEST_LIMIT_ID");
    bytes32 constant CONSOLIDATION_REQUEST_LIMIT_ID    = keccak256("CONSOLIDATION_REQUEST_LIMIT_ID");

    bytes32 constant STETH_REQUEST_WITHDRAWAL_LIMIT_ID = keccak256("STETH_REQUEST_WITHDRAWAL_LIMIT_ID");
    bytes32 constant QUEUE_WITHDRAWALS_LIMIT_ID        = keccak256("QUEUE_WITHDRAWALS_LIMIT_ID");
    bytes32 constant DEPOSIT_INTO_STRATEGY_LIMIT_ID    = keccak256("DEPOSIT_INTO_STRATEGY_LIMIT_ID");

    EtherFiTimelock constant upgradeTimelock   = EtherFiTimelock(payable(UPGRADE_TIMELOCK));
    EtherFiTimelock constant operatingTimelock = EtherFiTimelock(payable(OPERATING_TIMELOCK));
    RoleRegistry    constant roleRegistry      = RoleRegistry(ROLE_REGISTRY);

    uint256 constant UPGRADE_TIMELOCK_DELAY   = 10 days;
    uint256 constant OPERATING_TIMELOCK_DELAY = 2 days;

    string constant OUT_DIR = "script/upgrades/security-upgrades";

    // ─────────────────────────────────────────────────────────────────────
    // PRE-UPGRADE SNAPSHOTS
    //
    // preSnap   - owner + paused per proxy.
    // preImm    - immutable getter values per proxy. Pre-snapshot is "safe":
    //             selectors that revert pre-upgrade (because the immutable
    //             didn't exist on the old impl) are *filtered out* — they
    //             can't be diffed but the post-vs-expected check still
    //             validates them via the per-contract _verifyImmutablesXxx
    //             functions. So pre/post diff covers the *preserved* wiring
    //             and post/expected covers the *newly-introduced* immutables.
    // ─────────────────────────────────────────────────────────────────────
    struct Snap { address owner; bool paused; }
    mapping(address => Snap) internal preSnap;
    mapping(address => ImmutableSnapshot) internal preImm;

    ContractCodeChecker internal codeChecker;

    function run() public {
        string memory forkUrl = vm.envString("MAINNET_RPC_URL");
        vm.selectFork(vm.createFork(forkUrl));

        _preflight();
        codeChecker = new ContractCodeChecker();

        verifyDeployedBytecode();
        takePreUpgradeSnapshots();
        executeUpgrade();
        verifyUpgrades();
        verifyImmutablePreservation();
        verifyAccessControlPreservation();

        executeRoleGrants();
        executeLpWithdrawBounds();

        executeOperatingConfig();
        verifyOperatingConfig();
    }

    /// @dev Fail loudly the moment a required constant is unset.
    function _preflight() internal pure {
        require(blacklisterProxy != address(0), "preflight: blacklisterProxy unset");
        require(revokeAdminProxy != address(0), "preflight: revokeAdminProxy unset");
        require(roleRegistryImpl != address(0), "preflight: roleRegistryImpl unset");
        require(eEthImpl != address(0), "preflight: eEthImpl unset");
        require(weEthImpl != address(0), "preflight: weEthImpl unset");
        require(liquidityPoolImpl != address(0), "preflight: liquidityPoolImpl unset");
        require(withdrawRequestNFTImpl != address(0), "preflight: withdrawRequestNFTImpl unset");
        require(liquifierImpl != address(0), "preflight: liquifierImpl unset");
        require(etherFiAdminImpl != address(0), "preflight: etherFiAdminImpl unset");
        require(etherFiOracleImpl != address(0), "preflight: etherFiOracleImpl unset");
        require(etherFiRedemptionManagerImpl != address(0), "preflight: etherFiRedemptionManagerImpl unset");
        require(etherFiRestakerImpl != address(0), "preflight: etherFiRestakerImpl unset");
        require(etherFiNodeImpl != address(0), "preflight: etherFiNodeImpl unset");
        require(etherFiNodesManagerImpl != address(0), "preflight: etherFiNodesManagerImpl unset");
        require(stakingManagerImpl != address(0), "preflight: stakingManagerImpl unset");
        require(auctionManagerImpl != address(0), "preflight: auctionManagerImpl unset");
        require(nodeOperatorManagerImpl != address(0), "preflight: nodeOperatorManagerImpl unset");
        require(membershipManagerImpl != address(0), "preflight: membershipManagerImpl unset");
        require(membershipNFTImpl != address(0), "preflight: membershipNFTImpl unset");
        require(etherFiRateLimiterImpl != address(0), "preflight: etherFiRateLimiterImpl unset");

        require(priorityWithdrawalQueueImpl            != address(0), "preflight: priorityWithdrawalQueueImpl unset");
        require(etherFiRewardsRouterImpl               != address(0), "preflight: etherFiRewardsRouterImpl unset");
        require(restakingRewardsRouterImpl             != address(0), "preflight: restakingRewardsRouterImpl unset");
        require(cumulativeMerkleRewardsDistributorImpl != address(0), "preflight: cumulativeMerkleRewardsDistributorImpl unset");
        require(depositAdapterImpl                     != address(0), "preflight: depositAdapterImpl unset");
        require(weETHWithdrawAdapterImpl               != address(0), "preflight: weETHWithdrawAdapterImpl unset");

        require(EETH_MINT_CAPACITY    != 0, "preflight: EETH_MINT_CAPACITY unset");
        require(EETH_MINT_REFILL_RATE != 0, "preflight: EETH_MINT_REFILL_RATE unset");
        require(EETH_BURN_CAPACITY    != 0, "preflight: EETH_BURN_CAPACITY unset");
        require(EETH_BURN_REFILL_RATE != 0, "preflight: EETH_BURN_REFILL_RATE unset");
        require(WEETH_MINT_CAPACITY   != 0, "preflight: WEETH_MINT_CAPACITY unset");
        require(WEETH_MINT_REFILL_RATE!= 0, "preflight: WEETH_MINT_REFILL_RATE unset");
        require(WEETH_BURN_CAPACITY   != 0, "preflight: WEETH_BURN_CAPACITY unset");
        require(WEETH_BURN_REFILL_RATE!= 0, "preflight: WEETH_BURN_REFILL_RATE unset");

        require(UNRESTAKING_CAPACITY              != 0, "preflight: UNRESTAKING_CAPACITY unset");
        require(UNRESTAKING_REFILL_RATE           != 0, "preflight: UNRESTAKING_REFILL_RATE unset");
        require(EXIT_REQUEST_CAPACITY             != 0, "preflight: EXIT_REQUEST_CAPACITY unset");
        require(EXIT_REQUEST_REFILL_RATE          != 0, "preflight: EXIT_REQUEST_REFILL_RATE unset");
        require(CONSOLIDATION_REQUEST_CAPACITY    != 0, "preflight: CONSOLIDATION_REQUEST_CAPACITY unset");
        require(CONSOLIDATION_REQUEST_REFILL_RATE != 0, "preflight: CONSOLIDATION_REQUEST_REFILL_RATE unset");

        require(STETH_REQUEST_WITHDRAWAL_CAPACITY    != 0, "preflight: STETH_REQUEST_WITHDRAWAL_CAPACITY unset");
        require(STETH_REQUEST_WITHDRAWAL_REFILL_RATE != 0, "preflight: STETH_REQUEST_WITHDRAWAL_REFILL_RATE unset");
        require(QUEUE_WITHDRAWALS_CAPACITY           != 0, "preflight: QUEUE_WITHDRAWALS_CAPACITY unset");
        require(QUEUE_WITHDRAWALS_REFILL_RATE        != 0, "preflight: QUEUE_WITHDRAWALS_REFILL_RATE unset");
        require(DEPOSIT_INTO_STRATEGY_CAPACITY       != 0, "preflight: DEPOSIT_INTO_STRATEGY_CAPACITY unset");
        require(DEPOSIT_INTO_STRATEGY_REFILL_RATE    != 0, "preflight: DEPOSIT_INTO_STRATEGY_REFILL_RATE unset");

        require(PAUSE_UNTIL_EETH != 0,                   "preflight: PAUSE_UNTIL_EETH unset");
        require(PAUSE_UNTIL_WEETH != 0,                  "preflight: PAUSE_UNTIL_WEETH unset");
        require(PAUSE_UNTIL_LIQUIDITY_POOL != 0,         "preflight: PAUSE_UNTIL_LIQUIDITY_POOL unset");
        require(PAUSE_UNTIL_WITHDRAW_REQUEST_NFT != 0,   "preflight: PAUSE_UNTIL_WITHDRAW_REQUEST_NFT unset");
        require(PAUSE_UNTIL_LIQUIFIER != 0,              "preflight: PAUSE_UNTIL_LIQUIFIER unset");
        require(PAUSE_UNTIL_ETHERFI_NODES_MANAGER != 0,  "preflight: PAUSE_UNTIL_ETHERFI_NODES_MANAGER unset");
        require(PAUSE_UNTIL_ETHERFI_REDEMPTION_MGR != 0, "preflight: PAUSE_UNTIL_ETHERFI_REDEMPTION_MGR unset");
        require(PAUSE_UNTIL_AUCTION_MANAGER != 0,        "preflight: PAUSE_UNTIL_AUCTION_MANAGER unset");
        require(PAUSE_UNTIL_PRIORITY_WITHDRAWAL_QUEUE != 0,             "preflight: PAUSE_UNTIL_PRIORITY_WITHDRAWAL_QUEUE unset");
        require(PAUSE_UNTIL_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR != 0, "preflight: PAUSE_UNTIL_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR unset");
        require(PAUSE_UNTIL_WEETH_WITHDRAW_ADAPTER != 0,                "preflight: PAUSE_UNTIL_WEETH_WITHDRAW_ADAPTER unset");

        require(HOLDER_SUPER_GUARDIAN_ROLE          != address(0), "preflight: HOLDER_SUPER_GUARDIAN_ROLE unset");
        require(HOLDER_GUARDIAN_ROLE                != address(0), "preflight: HOLDER_GUARDIAN_ROLE unset");
        require(HOLDER_ORACLE_OPERATIONS_ROLE       != address(0), "preflight: HOLDER_ORACLE_OPERATIONS_ROLE unset");
        require(HOLDER_HOUSEKEEPING_OPERATIONS_ROLE != address(0), "preflight: HOLDER_HOUSEKEEPING_OPERATIONS_ROLE unset");
        require(HOLDER_EXECUTOR_OPERATIONS_ROLE     != address(0), "preflight: HOLDER_EXECUTOR_OPERATIONS_ROLE unset");
        require(HOLDER_EIGENPOD_OPERATIONS_ROLE     != address(0), "preflight: HOLDER_EIGENPOD_OPERATIONS_ROLE unset");
    }

    //--------------------------------------------------------------------------------------
    // STEP 1: verifyDeployedBytecode
    //--------------------------------------------------------------------------------------
    function verifyDeployedBytecode() public {
        console2.log("=== Step 1: Verifying Deployed Bytecode ===");
        _verifyRoleRegistry();
        _verifyTokens();
        _verifyCore();
        _verifyAdminAndOracle();
        _verifyValidatorStack();
        _verifyMembership();
        _verifyRateLimiter();
        _verifyPeripherals();
        console2.log("[OK] RoleRegistry + all 22 implementations matched local bytecode");
        console2.log("");
    }

    function _verifyRoleRegistry() internal {
        RoleRegistry fresh = new RoleRegistry(revokeAdminProxy);
        codeChecker.verifyContractByteCodeMatch(roleRegistryImpl, address(fresh));
    }

    function _verifyTokens() internal {
        EETHToken fresh = new EETHToken(LIQUIDITY_POOL, ROLE_REGISTRY, blacklisterProxy, ETHERFI_RATE_LIMITER);
        codeChecker.verifyContractByteCodeMatch(eEthImpl, address(fresh));
        WeETHToken fresh2 = new WeETHToken(EETH, LIQUIDITY_POOL, ROLE_REGISTRY, blacklisterProxy, ETHERFI_RATE_LIMITER);
        codeChecker.verifyContractByteCodeMatch(weEthImpl, address(fresh2));
    }

    function _verifyCore() internal {
        LiquidityPool fresh = new LiquidityPool(
            LiquidityPool.ConstructorAddresses({
                stakingManager: STAKING_MANAGER,
                nodesManager: ETHERFI_NODES_MANAGER,
                eETH: EETH,
                withdrawRequestNFT: WITHDRAW_REQUEST_NFT,
                liquifier: LIQUIFIER,
                etherFiRedemptionManager: ETHERFI_REDEMPTION_MANAGER,
                roleRegistry: ROLE_REGISTRY,
                priorityWithdrawalQueue: PRIORITY_WITHDRAWAL_QUEUE,
                blacklister: blacklisterProxy,
                etherFiAdminContract: ETHERFI_ADMIN,
                membershipManager: MEMBERSHIP_MANAGER
            }),
            LP_MIN_AMOUNT_FOR_SHARE
        );
        codeChecker.verifyContractByteCodeMatch(liquidityPoolImpl, address(fresh));

        WithdrawRequestNFT fresh2 = new WithdrawRequestNFT(
            WITHDRAW_REQUEST_NFT_BUYBACK_SAFE, EETH, LIQUIDITY_POOL, MEMBERSHIP_MANAGER,
            ROLE_REGISTRY, blacklisterProxy, ETHERFI_ADMIN,
            WNFT_MIN_ACCEPTABLE_SHARE_RATE, WNFT_MAX_ACCEPTABLE_SHARE_RATE
        );
        codeChecker.verifyContractByteCodeMatch(withdrawRequestNFTImpl, address(fresh2));

        Liquifier fresh3 = new Liquifier(
            Liquifier.ConstructorAddresses({
                liquidityPool: LIQUIDITY_POOL,
                lidoWithdrawalQueue: LIDO_WITHDRAWAL_QUEUE,
                lido: STETH,
                stEth_Eth_Pool: STETH_ETH_CURVE_POOL,
                roleRegistry: ROLE_REGISTRY,
                stEthPriceFeed: STETH_PRICE_FEED,
                blacklister: blacklisterProxy,
                etherfiRestaker: ETHERFI_RESTAKER,
                l1SyncPool: ETHERFI_L1_SYNC_POOL_ETH
            }),
            LIQUIFIER_MIN_DISCOUNT_BPS, LIQUIFIER_STALE_PRICE_WINDOW, LIQUIFIER_MAX_PRICE_DEVIATION_BPS
        );
        codeChecker.verifyContractByteCodeMatch(liquifierImpl, address(fresh3));
    }

    function _verifyAdminAndOracle() internal {
        EtherFiAdmin fresh = new EtherFiAdmin(
            EtherFiAdmin.ConstructorAddresses({
                etherFiOracle: ETHERFI_ORACLE,
                stakingManager: STAKING_MANAGER,
                auctionManager: AUCTION_MANAGER,
                etherFiNodesManager: ETHERFI_NODES_MANAGER,
                liquidityPool: LIQUIDITY_POOL,
                membershipManager: MEMBERSHIP_MANAGER,
                withdrawRequestNft: WITHDRAW_REQUEST_NFT,
                roleRegistry: ROLE_REGISTRY,
                priorityWithdrawalQueue: PRIORITY_WITHDRAWAL_QUEUE
            }),
            ADMIN_MAX_REBASE_APR_BPS,
            ADMIN_MAX_VALIDATOR_TASK_BATCH_SIZE,
            ADMIN_STALE_ORACLE_REPORT_BLOCK_WINDOW,
            ADMIN_MAX_FINALIZED_WITHDRAWAL_AMOUNT_PER_DAY,
            ADMIN_MAX_VALIDATORS_TO_APPROVE_PER_DAY,
            ADMIN_MAX_REQUESTS_TO_FINALIZE_PER_REPORT
        );
        codeChecker.verifyContractByteCodeMatch(etherFiAdminImpl, address(fresh));

        EtherFiOracle fresh2 = new EtherFiOracle(ORACLE_MIN_QUORUM_SIZE, ETHERFI_ADMIN, ROLE_REGISTRY);
        codeChecker.verifyContractByteCodeMatch(etherFiOracleImpl, address(fresh2));

        EtherFiRedemptionManager fresh3 = new EtherFiRedemptionManager(
            LIQUIDITY_POOL, EETH, WEETH, TREASURY, ROLE_REGISTRY, ETHERFI_RESTAKER,
            PRIORITY_WITHDRAWAL_QUEUE, blacklisterProxy,
            RM_MAX_EXIT_FEE_SPLIT_TO_TREASURY_BPS, RM_MAX_EXIT_FEE_BPS, RM_MAX_LOW_WATERMARK_BPS_OF_TVL
        );
        codeChecker.verifyContractByteCodeMatch(etherFiRedemptionManagerImpl, address(fresh3));
    }

    function _verifyValidatorStack() internal {
        EtherFiRestaker fresh = new EtherFiRestaker(
            LIQUIDITY_POOL, LIQUIFIER, EIGENLAYER_REWARDS_COORDINATOR, ETHERFI_REDEMPTION_MANAGER,
            ROLE_REGISTRY, ETHERFI_RATE_LIMITER, EIGENLAYER_STRATEGY_MANAGER, EIGENLAYER_DELEGATION_MANAGER
        );
        codeChecker.verifyContractByteCodeMatch(etherFiRestakerImpl, address(fresh));

        EtherFiNodesManager fresh2 = new EtherFiNodesManager(STAKING_MANAGER, ROLE_REGISTRY, ETHERFI_RATE_LIMITER);
        codeChecker.verifyContractByteCodeMatch(etherFiNodesManagerImpl, address(fresh2));

        EtherFiNode freshNode = new EtherFiNode(LIQUIDITY_POOL, ETHERFI_NODES_MANAGER, EIGENLAYER_POD_MANAGER, EIGENLAYER_DELEGATION_MANAGER);
        codeChecker.verifyContractByteCodeMatch(etherFiNodeImpl, address(freshNode));

        StakingManager fresh3 = new StakingManager(
            LIQUIDITY_POOL, ETHERFI_NODES_MANAGER, ETH2_DEPOSIT_CONTRACT,
            AUCTION_MANAGER, ETHERFI_NODE_BEACON, ROLE_REGISTRY
        );
        codeChecker.verifyContractByteCodeMatch(stakingManagerImpl, address(fresh3));

        AuctionManager fresh4 = new AuctionManager(
            ROLE_REGISTRY, blacklisterProxy, NODE_OPERATOR_MANAGER, STAKING_MANAGER, TREASURY
        );
        codeChecker.verifyContractByteCodeMatch(auctionManagerImpl, address(fresh4));

        NodeOperatorManager fresh5 = new NodeOperatorManager(ROLE_REGISTRY, AUCTION_MANAGER);
        codeChecker.verifyContractByteCodeMatch(nodeOperatorManagerImpl, address(fresh5));
    }

    function _verifyMembership() internal {
        MembershipManager fresh = new MembershipManager(
            EETH, LIQUIDITY_POOL, MEMBERSHIP_NFT, ETHERFI_ADMIN, ROLE_REGISTRY, blacklisterProxy
        );
        codeChecker.verifyContractByteCodeMatch(membershipManagerImpl, address(fresh));

        MembershipNFT fresh2 = new MembershipNFT(
            LIQUIDITY_POOL, MEMBERSHIP_MANAGER, ROLE_REGISTRY, blacklisterProxy
        );
        codeChecker.verifyContractByteCodeMatch(membershipNFTImpl, address(fresh2));
    }

    function _verifyRateLimiter() internal {
        EtherFiRateLimiter fresh2 = new EtherFiRateLimiter(ROLE_REGISTRY, EETH, WEETH);
        codeChecker.verifyContractByteCodeMatch(etherFiRateLimiterImpl, address(fresh2));
    }

    function _verifyPeripherals() internal {
        PriorityWithdrawalQueue fresh = new PriorityWithdrawalQueue(
            LIQUIDITY_POOL, EETH, WEETH, ROLE_REGISTRY, WITHDRAW_REQUEST_NFT_BUYBACK_SAFE, PWQ_MIN_DELAY
        );
        codeChecker.verifyContractByteCodeMatch(priorityWithdrawalQueueImpl, address(fresh));

        EtherFiRewardsRouter fresh2 = new EtherFiRewardsRouter(LIQUIDITY_POOL, TREASURY, ROLE_REGISTRY);
        codeChecker.verifyContractByteCodeMatch(etherFiRewardsRouterImpl, address(fresh2));

        RestakingRewardsRouter fresh3 = new RestakingRewardsRouter(
            ROLE_REGISTRY, EIGEN, LIQUIDITY_POOL
        );
        codeChecker.verifyContractByteCodeMatch(restakingRewardsRouterImpl, address(fresh3));

        CumulativeMerkleRewardsDistributor fresh4 = new CumulativeMerkleRewardsDistributor(ROLE_REGISTRY);
        codeChecker.verifyContractByteCodeMatch(cumulativeMerkleRewardsDistributorImpl, address(fresh4));

        DepositAdapter fresh5 = new DepositAdapter(
            LIQUIDITY_POOL, LIQUIFIER, WEETH, EETH, WETH, STETH, WSTETH, ROLE_REGISTRY, blacklisterProxy
        );
        codeChecker.verifyContractByteCodeMatch(depositAdapterImpl, address(fresh5));

        WeETHWithdrawAdapter fresh6 = new WeETHWithdrawAdapter(
            WEETH, EETH, LIQUIDITY_POOL, WITHDRAW_REQUEST_NFT, ROLE_REGISTRY, blacklisterProxy
        );
        codeChecker.verifyContractByteCodeMatch(weETHWithdrawAdapterImpl, address(fresh6));
    }

    //--------------------------------------------------------------------------------------
    // STEP 2: takePreUpgradeSnapshots
    //--------------------------------------------------------------------------------------
    function takePreUpgradeSnapshots() public {
        console2.log("=== Step 2: Taking Pre-Upgrade Snapshots ===");
        address[22] memory proxies = _upgradedProxies();
        for (uint256 k = 0; k < proxies.length; k++) {
            preSnap[proxies[k]] = Snap({ owner: _getOwner(proxies[k]), paused: _getPaused(proxies[k]) });
        }

        // Immutable getter snapshots - filtered to selectors that exist pre-upgrade.
        preImm[EETH]                       = _safeSnapshot(EETH,                       _eethImmSels());
        preImm[WEETH]                      = _safeSnapshot(WEETH,                      _weethImmSels());
        preImm[LIQUIDITY_POOL]             = _safeSnapshot(LIQUIDITY_POOL,             _lpImmSels());
        preImm[WITHDRAW_REQUEST_NFT]       = _safeSnapshot(WITHDRAW_REQUEST_NFT,       _nftImmSels());
        preImm[LIQUIFIER]                  = _safeSnapshot(LIQUIFIER,                  _liquifierImmSels());
        preImm[ETHERFI_ADMIN]              = _safeSnapshot(ETHERFI_ADMIN,              _adminImmSels());
        preImm[ETHERFI_ORACLE]             = _safeSnapshot(ETHERFI_ORACLE,             _oracleImmSels());
        preImm[ETHERFI_REDEMPTION_MANAGER] = _safeSnapshot(ETHERFI_REDEMPTION_MANAGER, _redemptionImmSels());
        preImm[ETHERFI_RESTAKER]           = _safeSnapshot(ETHERFI_RESTAKER,           _restakerImmSels());
        preImm[ETHERFI_NODES_MANAGER]      = _safeSnapshot(ETHERFI_NODES_MANAGER,      _nodesMgrImmSels());
        preImm[STAKING_MANAGER]            = _safeSnapshot(STAKING_MANAGER,            _stakingMgrImmSels());
        preImm[AUCTION_MANAGER]            = _safeSnapshot(AUCTION_MANAGER,            _auctionImmSels());
        preImm[NODE_OPERATOR_MANAGER]      = _safeSnapshot(NODE_OPERATOR_MANAGER,      _nodeOpImmSels());
        preImm[MEMBERSHIP_MANAGER]         = _safeSnapshot(MEMBERSHIP_MANAGER,         _mmImmSels());
        preImm[MEMBERSHIP_NFT]             = _safeSnapshot(MEMBERSHIP_NFT,             _mnftImmSels());
        preImm[ETHERFI_RATE_LIMITER]       = _safeSnapshot(ETHERFI_RATE_LIMITER,       _rateLimiterImmSels());

        preImm[PRIORITY_WITHDRAWAL_QUEUE]              = _safeSnapshot(PRIORITY_WITHDRAWAL_QUEUE,              _pwqImmSels());
        preImm[ETHERFI_REWARDS_ROUTER]                 = _safeSnapshot(ETHERFI_REWARDS_ROUTER,                 _rewardsRouterImmSels());
        preImm[RESTAKING_REWARDS_ROUTER]               = _safeSnapshot(RESTAKING_REWARDS_ROUTER,               _restakingRewardsRouterImmSels());
        preImm[CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR]  = _safeSnapshot(CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR,  _cmrdImmSels());
        preImm[DEPOSIT_ADAPTER]                        = _safeSnapshot(DEPOSIT_ADAPTER,                        _depositAdapterImmSels());
        preImm[WEETH_WITHDRAW_ADAPTER]                 = _safeSnapshot(WEETH_WITHDRAW_ADAPTER,                 _weethWithdrawAdapterImmSels());

        console2.log("[OK] snapshotted owner + paused + immutable getters for", proxies.length, "proxies");
        console2.log("");
    }

    /// @dev Capture `staticcall` returns for every selector; silently skip the
    ///      ones that revert (e.g. immutable getters that didn't exist on the
    ///      old impl). Only the surviving selectors get diffed in step 5.
    function _safeSnapshot(address target, bytes4[] memory selectors)
        internal
        view
        returns (ImmutableSnapshot memory)
    {
        bytes4[] memory s = new bytes4[](selectors.length);
        bytes[]  memory v = new bytes[](selectors.length);
        uint256 n;
        for (uint256 i = 0; i < selectors.length; i++) {
            (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSelector(selectors[i]));
            if (ok) { s[n] = selectors[i]; v[n] = ret; n++; }
        }
        bytes4[] memory s2 = new bytes4[](n);
        bytes[]  memory v2 = new bytes[](n);
        for (uint256 i = 0; i < n; i++) { s2[i] = s[i]; v2[i] = v[i]; }
        return ImmutableSnapshot({ target: target, selectors: s2, values: v2 });
    }

    function _postSnap(ImmutableSnapshot memory pre) internal view returns (ImmutableSnapshot memory) {
        bytes[] memory v = new bytes[](pre.selectors.length);
        for (uint256 i = 0; i < pre.selectors.length; i++) {
            (bool ok, bytes memory ret) = pre.target.staticcall(abi.encodeWithSelector(pre.selectors[i]));
            require(ok, "post-upgrade: previously-surviving selector now reverts");
            v[i] = ret;
        }
        return ImmutableSnapshot({ target: pre.target, selectors: pre.selectors, values: v });
    }

    // ─── Immutable selector lists ──────────────────────────────────────────
    // Selectors hard-coded as bytes4(keccak256("getterName()")) so that
    // pre-upgrade calls don't need the new ABI to be linked at compile time.
    function _eethImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = bytes4(keccak256("liquidityPool()"));
        s[1] = bytes4(keccak256("roleRegistry()"));
        s[2] = bytes4(keccak256("blacklister()"));
        s[3] = bytes4(keccak256("rateLimiter()"));
    }
    function _weethImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = bytes4(keccak256("eETH()"));
        s[1] = bytes4(keccak256("liquidityPool()"));
        s[2] = bytes4(keccak256("roleRegistry()"));
        s[3] = bytes4(keccak256("blacklister()"));
        s[4] = bytes4(keccak256("rateLimiter()"));
    }
    function _lpImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](12);
        s[0]  = bytes4(keccak256("stakingManager()"));
        s[1]  = bytes4(keccak256("nodesManager()"));
        s[2]  = bytes4(keccak256("eETH()"));
        s[3]  = bytes4(keccak256("withdrawRequestNFT()"));
        s[4]  = bytes4(keccak256("liquifier()"));
        s[5]  = bytes4(keccak256("etherFiRedemptionManager()"));
        s[6]  = bytes4(keccak256("roleRegistry()"));
        s[7]  = bytes4(keccak256("priorityWithdrawalQueue()"));
        s[8]  = bytes4(keccak256("blacklister()"));
        s[9]  = bytes4(keccak256("etherFiAdminContract()"));
        s[10] = bytes4(keccak256("membershipManager()"));
        s[11] = bytes4(keccak256("minAmountForShare()"));
    }
    function _nftImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](9);
        s[0] = bytes4(keccak256("treasury()"));
        s[1] = bytes4(keccak256("liquidityPool()"));
        s[2] = bytes4(keccak256("eETH()"));
        s[3] = bytes4(keccak256("membershipManager()"));
        s[4] = bytes4(keccak256("roleRegistry()"));
        s[5] = bytes4(keccak256("blacklister()"));
        s[6] = bytes4(keccak256("etherFiAdmin()"));
        s[7] = bytes4(keccak256("minAcceptableShareRate()"));
        s[8] = bytes4(keccak256("maxAcceptableShareRate()"));
    }
    function _liquifierImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](12);
        s[0]  = bytes4(keccak256("liquidityPool()"));
        s[1]  = bytes4(keccak256("lidoWithdrawalQueue()"));
        s[2]  = bytes4(keccak256("lido()"));
        s[3]  = bytes4(keccak256("stEth_Eth_Pool()"));
        s[4]  = bytes4(keccak256("roleRegistry()"));
        s[5]  = bytes4(keccak256("stEthPriceFeed()"));
        s[6]  = bytes4(keccak256("blacklister()"));
        s[7]  = bytes4(keccak256("etherfiRestaker()"));
        s[8]  = bytes4(keccak256("l1SyncPool()"));
        s[9]  = bytes4(keccak256("minDiscountRateInBps()"));
        s[10] = bytes4(keccak256("stalePriceWindow()"));
        s[11] = bytes4(keccak256("maxPriceDeviationInBps()"));
    }
    function _adminImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](15);
        s[0]  = bytes4(keccak256("etherFiOracle()"));
        s[1]  = bytes4(keccak256("stakingManager()"));
        s[2]  = bytes4(keccak256("auctionManager()"));
        s[3]  = bytes4(keccak256("etherFiNodesManager()"));
        s[4]  = bytes4(keccak256("liquidityPool()"));
        s[5]  = bytes4(keccak256("membershipManager()"));
        s[6]  = bytes4(keccak256("withdrawRequestNft()"));
        s[7]  = bytes4(keccak256("roleRegistry()"));
        s[8]  = bytes4(keccak256("priorityWithdrawalQueue()"));
        s[9]  = bytes4(keccak256("maxAcceptableRebaseAprInBps()"));
        s[10] = bytes4(keccak256("maxValidatorTaskBatchSize()"));
        s[11] = bytes4(keccak256("maxAcceptableFinalizedWithdrawalAmountPerDay()"));
        s[12] = bytes4(keccak256("maxAcceptableNumValidatorsToApprovePerDay()"));
        s[13] = bytes4(keccak256("staleOracleReportBlockWindow()"));
        s[14] = bytes4(keccak256("maxNumberOfRequestsToFinalizePerReport()"));
    }
    function _oracleImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = bytes4(keccak256("etherFiAdmin()"));
        s[1] = bytes4(keccak256("roleRegistry()"));
        s[2] = bytes4(keccak256("minQuorumSize()"));
    }
    function _redemptionImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](12);
        s[0]  = bytes4(keccak256("treasury()"));
        s[1]  = bytes4(keccak256("roleRegistry()"));
        s[2]  = bytes4(keccak256("eEth()"));
        s[3]  = bytes4(keccak256("weEth()"));
        s[4]  = bytes4(keccak256("liquidityPool()"));
        s[5]  = bytes4(keccak256("etherFiRestaker()"));
        s[6]  = bytes4(keccak256("lido()"));
        s[7]  = bytes4(keccak256("priorityWithdrawalQueue()"));
        s[8]  = bytes4(keccak256("blacklister()"));
        s[9]  = bytes4(keccak256("maxExitFeeSplitToTreasuryInBps()"));
        s[10] = bytes4(keccak256("maxExitFeeInBps()"));
        s[11] = bytes4(keccak256("maxLowWatermarkInBpsOfTvl()"));
    }
    function _restakerImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](10);
        s[0] = bytes4(keccak256("rewardsCoordinator()"));
        s[1] = bytes4(keccak256("etherFiRedemptionManager()"));
        s[2] = bytes4(keccak256("liquidityPool()"));
        s[3] = bytes4(keccak256("liquifier()"));
        s[4] = bytes4(keccak256("lidoWithdrawalQueue()"));
        s[5] = bytes4(keccak256("lido()"));
        s[6] = bytes4(keccak256("eigenLayerDelegationManager()"));
        s[7] = bytes4(keccak256("eigenLayerStrategyManager()"));
        s[8] = bytes4(keccak256("roleRegistry()"));
        s[9] = bytes4(keccak256("rateLimiter()"));
    }
    function _nodesMgrImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = bytes4(keccak256("stakingManager()"));
        s[1] = bytes4(keccak256("roleRegistry()"));
        s[2] = bytes4(keccak256("rateLimiter()"));
    }
    function _stakingMgrImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = bytes4(keccak256("liquidityPool()"));
        s[1] = bytes4(keccak256("etherFiNodesManager()"));
        s[2] = bytes4(keccak256("depositContractEth2()"));
        s[3] = bytes4(keccak256("auctionManager()"));
        s[4] = bytes4(keccak256("etherFiNodeBeacon()"));
        s[5] = bytes4(keccak256("roleRegistry()"));
    }
    function _auctionImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = bytes4(keccak256("roleRegistry()"));
        s[1] = bytes4(keccak256("blacklister()"));
        s[2] = bytes4(keccak256("nodeOperatorManager()"));
        s[3] = bytes4(keccak256("stakingManagerContractAddress()"));
        s[4] = bytes4(keccak256("membershipManagerContractAddress()"));
        s[5] = bytes4(keccak256("treasury()"));
    }
    function _nodeOpImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = bytes4(keccak256("auctionManagerContractAddress()"));
        s[1] = bytes4(keccak256("roleRegistry()"));
    }
    function _mmImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = bytes4(keccak256("eETH()"));
        s[1] = bytes4(keccak256("liquidityPool()"));
        s[2] = bytes4(keccak256("membershipNFT()"));
        s[3] = bytes4(keccak256("etherFiAdmin()"));
        s[4] = bytes4(keccak256("roleRegistry()"));
        s[5] = bytes4(keccak256("blacklister()"));
    }
    function _mnftImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = bytes4(keccak256("liquidityPool()"));
        s[1] = bytes4(keccak256("membershipManager()"));
        s[2] = bytes4(keccak256("roleRegistry()"));
        s[3] = bytes4(keccak256("blacklister()"));
    }
    function _rateLimiterImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = bytes4(keccak256("eETH()"));
        s[1] = bytes4(keccak256("weETH()"));
        s[2] = bytes4(keccak256("roleRegistry()"));
    }
    function _pwqImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = bytes4(keccak256("liquidityPool()"));
        s[1] = bytes4(keccak256("eETH()"));
        s[2] = bytes4(keccak256("weETH()"));
        s[3] = bytes4(keccak256("treasury()"));
        s[4] = bytes4(keccak256("minDelay()"));
        s[5] = bytes4(keccak256("roleRegistry()"));
    }
    function _rewardsRouterImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = bytes4(keccak256("treasury()"));
        s[1] = bytes4(keccak256("liquidityPool()"));
        s[2] = bytes4(keccak256("roleRegistry()"));
    }
    function _restakingRewardsRouterImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = bytes4(keccak256("liquidityPool()"));
        s[1] = bytes4(keccak256("rewardTokenAddress()"));
        s[2] = bytes4(keccak256("roleRegistry()"));
    }
    function _cmrdImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = bytes4(keccak256("roleRegistry()"));
    }
    function _depositAdapterImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](9);
        s[0] = bytes4(keccak256("liquidityPool()"));
        s[1] = bytes4(keccak256("liquifier()"));
        s[2] = bytes4(keccak256("eETH()"));
        s[3] = bytes4(keccak256("weETH()"));
        s[4] = bytes4(keccak256("wETH()"));
        s[5] = bytes4(keccak256("stETH()"));
        s[6] = bytes4(keccak256("wstETH()"));
        s[7] = bytes4(keccak256("blacklister()"));
        s[8] = bytes4(keccak256("roleRegistry()"));
    }
    function _weethWithdrawAdapterImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = bytes4(keccak256("weETH()"));
        s[1] = bytes4(keccak256("eETH()"));
        s[2] = bytes4(keccak256("liquidityPool()"));
        s[3] = bytes4(keccak256("withdrawRequestNFT()"));
        s[4] = bytes4(keccak256("blacklister()"));
        s[5] = bytes4(keccak256("roleRegistry()"));
    }

    function _upgradedProxies() internal pure returns (address[22] memory list) {
        list[0]  = EETH;
        list[1]  = WEETH;
        list[2]  = LIQUIDITY_POOL;
        list[3]  = WITHDRAW_REQUEST_NFT;
        list[4]  = LIQUIFIER;
        list[5]  = ETHERFI_ADMIN;
        list[6]  = ETHERFI_ORACLE;
        list[7]  = ETHERFI_REDEMPTION_MANAGER;
        list[8]  = ETHERFI_RESTAKER;
        list[9]  = ETHERFI_NODES_MANAGER;
        list[10] = STAKING_MANAGER;
        list[11] = AUCTION_MANAGER;
        list[12] = NODE_OPERATOR_MANAGER;
        list[13] = MEMBERSHIP_MANAGER;
        list[14] = MEMBERSHIP_NFT;
        list[15] = ETHERFI_RATE_LIMITER;
        list[16] = PRIORITY_WITHDRAWAL_QUEUE;
        list[17] = ETHERFI_REWARDS_ROUTER;
        list[18] = RESTAKING_REWARDS_ROUTER;
        list[19] = CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR;
        list[20] = DEPOSIT_ADAPTER;
        list[21] = WEETH_WITHDRAW_ADAPTER;
    }

    //--------------------------------------------------------------------------------------
    // STEP 3: executeUpgrade - Batch A
    //--------------------------------------------------------------------------------------
    function executeUpgrade() public {
        console2.log("=== Step 3: Executing Upgrade (Batch A, UPGRADE_TIMELOCK, 10d) ===");

        address[] memory targets = new address[](50);
        bytes[]   memory data    = new bytes[](50);
        uint256[] memory values  = new uint256[](50);
        uint256 i;

        // RoleRegistry MUST upgrade before every other proxy. Its owner is the
        // UPGRADE_TIMELOCK (this batch's executor), so the current impl's onlyOwner
        // gate authorizes the swap; the new impl then gates upgrades on
        // UPGRADE_TIMELOCK_ROLE (granted to the same owner in executeRoleGrants).
        (targets[i], data[i]) = (ROLE_REGISTRY,              _upgradeTo(roleRegistryImpl));           i++;

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

        // EtherFiNode is a beacon proxy, not UUPS. Upgrade it via the beacon owner
        // (the StakingManager) using upgradeEtherFiNode, which is gated by the same
        // UPGRADE_TIMELOCK authority executing this batch. Done before the StakingManager
        // proxy swap so it runs against the current impl's upgrade gate.
        (targets[i], data[i]) = (STAKING_MANAGER,
            abi.encodeWithSelector(StakingManager.upgradeEtherFiNode.selector, etherFiNodeImpl));     i++;
        (targets[i], data[i]) = (STAKING_MANAGER,            _upgradeTo(stakingManagerImpl));         i++;
        (targets[i], data[i]) = (AUCTION_MANAGER,            _upgradeTo(auctionManagerImpl));         i++;
        (targets[i], data[i]) = (NODE_OPERATOR_MANAGER,      _upgradeTo(nodeOperatorManagerImpl));    i++;
        (targets[i], data[i]) = (MEMBERSHIP_MANAGER,         _upgradeTo(membershipManagerImpl));      i++;
        (targets[i], data[i]) = (MEMBERSHIP_NFT,             _upgradeTo(membershipNFTImpl));          i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER,       _upgradeTo(etherFiRateLimiterImpl));     i++;

        (targets[i], data[i]) = (PRIORITY_WITHDRAWAL_QUEUE,             _upgradeTo(priorityWithdrawalQueueImpl));            i++;
        (targets[i], data[i]) = (ETHERFI_REWARDS_ROUTER,                _upgradeTo(etherFiRewardsRouterImpl));               i++;
        (targets[i], data[i]) = (RESTAKING_REWARDS_ROUTER,              _upgradeTo(restakingRewardsRouterImpl));             i++;
        (targets[i], data[i]) = (CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR, _upgradeTo(cumulativeMerkleRewardsDistributorImpl)); i++;
        (targets[i], data[i]) = (DEPOSIT_ADAPTER,                       _upgradeTo(depositAdapterImpl));                     i++;
        (targets[i], data[i]) = (WEETH_WITHDRAW_ADAPTER,                _upgradeTo(weETHWithdrawAdapterImpl));               i++;

        (targets[i], data[i]) = (LIQUIDITY_POOL,
            abi.encodeWithSelector(LiquidityPool.initializeOnUpgradeV2.selector));                    i++;
        (targets[i], data[i]) = (WITHDRAW_REQUEST_NFT,
            abi.encodeWithSelector(WithdrawRequestNFT.initializeShareRateFreezeUpgrade.selector));    i++;

        // Role grants live in executeRoleGrants() — they originate from the
        // RoleRegistry owner (ETHERFI_UPGRADE_ADMIN), not from any timelock.

        _shrinkAndEmit(
            BatchEmit({
                label: "Batch A - Upgrade",
                timelock: upgradeTimelock,
                timelockAddr: UPGRADE_TIMELOCK,
                adminSafe: ETHERFI_UPGRADE_ADMIN,
                minDelay: UPGRADE_TIMELOCK_DELAY,
                salt: keccak256(abi.encode("security-upgrades-v1-batchA", block.number)),
                scheduleFile: "upgrade_schedule.json",
                executeFile: "upgrade_execute.json"
            }),
            targets, values, data, i
        );
    }

    //--------------------------------------------------------------------------------------
    // STEP 4: verifyUpgrades
    //--------------------------------------------------------------------------------------
    function verifyUpgrades() public view {
        console2.log("=== Step 4: Verifying Upgrades ===");
        _assertImpl(ROLE_REGISTRY,              roleRegistryImpl,             "RoleRegistry");
        require(roleRegistry.revokeAdmin() == revokeAdminProxy, "RoleRegistry.revokeAdmin != revokeAdminProxy");
        _assertImpl(EETH,                       eEthImpl,                     "EETH");
        _assertImpl(WEETH,                      weEthImpl,                    "WeETH");
        _assertImpl(LIQUIDITY_POOL,             liquidityPoolImpl,            "LiquidityPool");
        _assertImpl(WITHDRAW_REQUEST_NFT,       withdrawRequestNFTImpl,       "WithdrawRequestNFT");
        _assertImpl(LIQUIFIER,                  liquifierImpl,                "Liquifier");
        _assertImpl(ETHERFI_ADMIN,              etherFiAdminImpl,             "EtherFiAdmin");
        _assertImpl(ETHERFI_ORACLE,             etherFiOracleImpl,            "EtherFiOracle");
        _assertImpl(ETHERFI_REDEMPTION_MANAGER, etherFiRedemptionManagerImpl, "EtherFiRedemptionManager");
        _assertImpl(ETHERFI_RESTAKER,           etherFiRestakerImpl,          "EtherFiRestaker");
        _assertImpl(ETHERFI_NODES_MANAGER,      etherFiNodesManagerImpl,      "EtherFiNodesManager");
        _assertImpl(STAKING_MANAGER,            stakingManagerImpl,           "StakingManager");
        // EtherFiNode beacon: implementation lives on the beacon, read via StakingManager.
        require(StakingManager(STAKING_MANAGER).implementation() == etherFiNodeImpl, "EtherFiNode: beacon implementation mismatch");
        _assertImpl(AUCTION_MANAGER,            auctionManagerImpl,           "AuctionManager");
        _assertImpl(NODE_OPERATOR_MANAGER,      nodeOperatorManagerImpl,      "NodeOperatorManager");
        _assertImpl(MEMBERSHIP_MANAGER,         membershipManagerImpl,        "MembershipManager");
        _assertImpl(MEMBERSHIP_NFT,             membershipNFTImpl,            "MembershipNFT");
        _assertImpl(ETHERFI_RATE_LIMITER,       etherFiRateLimiterImpl,        "EtherFiRateLimiter");
        _assertImpl(PRIORITY_WITHDRAWAL_QUEUE,             priorityWithdrawalQueueImpl,            "PriorityWithdrawalQueue");
        _assertImpl(ETHERFI_REWARDS_ROUTER,                etherFiRewardsRouterImpl,               "EtherFiRewardsRouter");
        _assertImpl(RESTAKING_REWARDS_ROUTER,              restakingRewardsRouterImpl,             "RestakingRewardsRouter");
        _assertImpl(CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR, cumulativeMerkleRewardsDistributorImpl, "CumulativeMerkleRewardsDistributor");
        _assertImpl(DEPOSIT_ADAPTER,                       depositAdapterImpl,                     "DepositAdapter");
        _assertImpl(WEETH_WITHDRAW_ADAPTER,                weETHWithdrawAdapterImpl,               "WeETHWithdrawAdapter");
        console2.log("");
    }

    function _assertImpl(address proxy, address expected, string memory name) internal view {
        address actual = getImplementation(proxy);
        require(actual == expected, string.concat(name, ": implementation slot mismatch"));
        console2.log(string.concat("[IMPL OK] ", name), actual);
    }

    //--------------------------------------------------------------------------------------
    // STEP 5: verifyImmutablePreservation
    //
    // Two complementary checks per contract:
    //
    //   (a) PRE/POST DIFF (verifyImmutablesUnchanged):
    //       For every immutable getter whose selector existed pre-upgrade,
    //       assert post == pre. New immutables introduced by this PR are
    //       skipped here because their selectors revert pre-upgrade and were
    //       filtered out of the pre-snapshot in step 2.
    //
    //   (b) POST vs EXPECTED (_verifyImmutablesXxx):
    //       Read every immutable on the new impl and assert it equals the
    //       deployment-time constant from Deployed.s.sol / params above.
    //       This is the only check that covers immutables introduced by
    //       this PR.
    //--------------------------------------------------------------------------------------
    function verifyImmutablePreservation() public view {
        console2.log("=== Step 5: Verifying Immutable Preservation ===");

        // (a) pre/post diff for surviving selectors
        _diffPreserved(EETH,                       "EETH");
        _diffPreserved(WEETH,                      "WeETH");
        _diffPreserved(LIQUIDITY_POOL,             "LiquidityPool");
        _diffPreserved(WITHDRAW_REQUEST_NFT,       "WithdrawRequestNFT");
        _diffPreserved(LIQUIFIER,                  "Liquifier");
        _diffPreserved(ETHERFI_ADMIN,              "EtherFiAdmin");
        _diffPreserved(ETHERFI_ORACLE,             "EtherFiOracle");
        _diffPreserved(ETHERFI_REDEMPTION_MANAGER, "EtherFiRedemptionManager");
        _diffPreserved(ETHERFI_RESTAKER,           "EtherFiRestaker");
        _diffPreserved(ETHERFI_NODES_MANAGER,      "EtherFiNodesManager");
        _diffPreserved(STAKING_MANAGER,            "StakingManager");
        _diffPreserved(AUCTION_MANAGER,            "AuctionManager");
        _diffPreserved(NODE_OPERATOR_MANAGER,      "NodeOperatorManager");
        _diffPreserved(MEMBERSHIP_MANAGER,         "MembershipManager");
        _diffPreserved(MEMBERSHIP_NFT,             "MembershipNFT");
        _diffPreserved(ETHERFI_RATE_LIMITER,       "EtherFiRateLimiter");
        _diffPreserved(PRIORITY_WITHDRAWAL_QUEUE,             "PriorityWithdrawalQueue");
        _diffPreserved(ETHERFI_REWARDS_ROUTER,                "EtherFiRewardsRouter");
        _diffPreserved(RESTAKING_REWARDS_ROUTER,              "RestakingRewardsRouter");
        _diffPreserved(CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR, "CumulativeMerkleRewardsDistributor");
        _diffPreserved(DEPOSIT_ADAPTER,                       "DepositAdapter");
        _diffPreserved(WEETH_WITHDRAW_ADAPTER,                "WeETHWithdrawAdapter");

        // (b) post vs deployment-time expected
        _verifyImmutablesTokens();
        _verifyImmutablesLP();
        _verifyImmutablesNFT();
        _verifyImmutablesLiquifier();
        _verifyImmutablesAdmin();
        _verifyImmutablesRedemption();
        _verifyImmutablesRestaker();
        _verifyImmutablesValidatorStack();
        _verifyImmutablesMembership();
        _verifyImmutablesRateLimiter();
        _verifyImmutablesPeripherals();
        console2.log("[OK] immutables: pre/post diff + post/expected checks passed");
        console2.log("");
    }

    function _diffPreserved(address target, string memory name) internal view {
        ImmutableSnapshot memory pre = preImm[target];
        if (pre.selectors.length == 0) {
            console2.log(string.concat("[NEW IMMUTABLES] ", name, ": all introduced by this PR; pre/post diff skipped"));
            return;
        }
        verifyImmutablesUnchanged(pre, _postSnap(pre), name);
    }

    function _verifyImmutablesTokens() internal view {
        EETHToken e = EETHToken(EETH);
        require(address(e.liquidityPool()) == LIQUIDITY_POOL,  "EETH.liquidityPool");
        require(address(e.roleRegistry())  == ROLE_REGISTRY,   "EETH.roleRegistry");
        require(address(e.blacklister())   == blacklisterProxy,"EETH.blacklister");
        require(address(e.rateLimiter())   == ETHERFI_RATE_LIMITER, "EETH.rateLimiter");

        WeETHToken w = WeETHToken(WEETH);
        require(address(w.eETH())          == EETH,            "WeETH.eETH");
        require(address(w.liquidityPool()) == LIQUIDITY_POOL,  "WeETH.liquidityPool");
        require(address(w.roleRegistry())  == ROLE_REGISTRY,   "WeETH.roleRegistry");
        require(address(w.blacklister())   == blacklisterProxy,"WeETH.blacklister");
        require(address(w.rateLimiter())   == ETHERFI_RATE_LIMITER, "WeETH.rateLimiter");
    }

    function _verifyImmutablesLP() internal view {
        LiquidityPool lp = LiquidityPool(payable(LIQUIDITY_POOL));
        require(address(lp.stakingManager())           == STAKING_MANAGER,            "LP.stakingManager");
        require(address(lp.nodesManager())             == ETHERFI_NODES_MANAGER,      "LP.nodesManager");
        require(address(lp.eETH())                     == EETH,                       "LP.eETH");
        require(address(lp.withdrawRequestNFT())       == WITHDRAW_REQUEST_NFT,       "LP.withdrawRequestNFT");
        require(address(lp.liquifier())                == LIQUIFIER,                  "LP.liquifier");
        require(address(lp.etherFiRedemptionManager()) == ETHERFI_REDEMPTION_MANAGER, "LP.etherFiRedemptionManager");
        require(address(lp.roleRegistry())             == ROLE_REGISTRY,              "LP.roleRegistry");
        require(address(lp.priorityWithdrawalQueue())  == PRIORITY_WITHDRAWAL_QUEUE,  "LP.priorityWithdrawalQueue");
        require(address(lp.blacklister())              == blacklisterProxy,           "LP.blacklister");
        require(lp.etherFiAdminContract()              == ETHERFI_ADMIN,              "LP.etherFiAdminContract");
        require(lp.membershipManager()                 == MEMBERSHIP_MANAGER,         "LP.membershipManager");
        require(lp.minAmountForShare()                 == LP_MIN_AMOUNT_FOR_SHARE,    "LP.minAmountForShare");
    }

    function _verifyImmutablesNFT() internal view {
        WithdrawRequestNFT n = WithdrawRequestNFT(payable(WITHDRAW_REQUEST_NFT));
        require(n.treasury()       == WITHDRAW_REQUEST_NFT_BUYBACK_SAFE, "NFT.treasury");
        require(address(n.liquidityPool())    == LIQUIDITY_POOL,           "NFT.liquidityPool");
        require(address(n.eETH())             == EETH,                     "NFT.eETH");
        require(address(n.membershipManager())== MEMBERSHIP_MANAGER,       "NFT.membershipManager");
        require(address(n.roleRegistry())     == ROLE_REGISTRY,            "NFT.roleRegistry");
        require(address(n.blacklister())      == blacklisterProxy,         "NFT.blacklister");
        require(n.etherFiAdmin()              == ETHERFI_ADMIN,            "NFT.etherFiAdmin");
        require(n.minAcceptableShareRate()    == WNFT_MIN_ACCEPTABLE_SHARE_RATE, "NFT.minAcceptableShareRate");
        require(n.maxAcceptableShareRate()    == WNFT_MAX_ACCEPTABLE_SHARE_RATE, "NFT.maxAcceptableShareRate");
    }

    function _verifyImmutablesLiquifier() internal view {
        Liquifier l = Liquifier(payable(LIQUIFIER));
        require(address(l.liquidityPool())       == LIQUIDITY_POOL,        "Liquifier.liquidityPool");
        require(address(l.lidoWithdrawalQueue()) == LIDO_WITHDRAWAL_QUEUE, "Liquifier.lidoWithdrawalQueue");
        require(address(l.lido())                == STETH,                 "Liquifier.lido");
        require(address(l.stEth_Eth_Pool())      == STETH_ETH_CURVE_POOL,  "Liquifier.stEth_Eth_Pool");
        require(address(l.roleRegistry())        == ROLE_REGISTRY,         "Liquifier.roleRegistry");
        require(address(l.stEthPriceFeed())      == STETH_PRICE_FEED,      "Liquifier.stEthPriceFeed");
        require(address(l.blacklister())         == blacklisterProxy,      "Liquifier.blacklister");
        require(l.etherfiRestaker()              == ETHERFI_RESTAKER,      "Liquifier.etherfiRestaker");
        require(l.l1SyncPool()                   == ETHERFI_L1_SYNC_POOL_ETH, "Liquifier.l1SyncPool");
        require(l.minDiscountRateInBps()         == LIQUIFIER_MIN_DISCOUNT_BPS, "Liquifier.minDiscountRateInBps");
        require(l.stalePriceWindow()             == LIQUIFIER_STALE_PRICE_WINDOW, "Liquifier.stalePriceWindow");
        require(l.maxPriceDeviationInBps()       == LIQUIFIER_MAX_PRICE_DEVIATION_BPS, "Liquifier.maxPriceDeviationInBps");
    }

    function _verifyImmutablesAdmin() internal view {
        EtherFiAdmin a = EtherFiAdmin(ETHERFI_ADMIN);
        require(address(a.etherFiOracle())            == ETHERFI_ORACLE,            "EFAdmin.etherFiOracle");
        require(address(a.stakingManager())           == STAKING_MANAGER,           "EFAdmin.stakingManager");
        require(address(a.auctionManager())           == AUCTION_MANAGER,           "EFAdmin.auctionManager");
        require(address(a.etherFiNodesManager())      == ETHERFI_NODES_MANAGER,     "EFAdmin.etherFiNodesManager");
        require(address(a.liquidityPool())            == LIQUIDITY_POOL,            "EFAdmin.liquidityPool");
        require(address(a.membershipManager())        == MEMBERSHIP_MANAGER,        "EFAdmin.membershipManager");
        require(address(a.withdrawRequestNft())       == WITHDRAW_REQUEST_NFT,      "EFAdmin.withdrawRequestNft");
        require(address(a.roleRegistry())             == ROLE_REGISTRY,             "EFAdmin.roleRegistry");
        require(address(a.priorityWithdrawalQueue())  == PRIORITY_WITHDRAWAL_QUEUE, "EFAdmin.priorityWithdrawalQueue");
        require(a.maxAcceptableRebaseAprInBps()       == ADMIN_MAX_REBASE_APR_BPS,  "EFAdmin.maxAcceptableRebaseAprInBps");
        require(a.maxValidatorTaskBatchSize()         == ADMIN_MAX_VALIDATOR_TASK_BATCH_SIZE, "EFAdmin.maxValidatorTaskBatchSize");
        require(a.staleOracleReportBlockWindow()      == ADMIN_STALE_ORACLE_REPORT_BLOCK_WINDOW, "EFAdmin.staleOracleReportBlockWindow");
        require(a.maxAcceptableFinalizedWithdrawalAmountPerDay() == ADMIN_MAX_FINALIZED_WITHDRAWAL_AMOUNT_PER_DAY, "EFAdmin.maxAcceptableFinalizedWithdrawalAmountPerDay");
        require(a.maxAcceptableNumValidatorsToApprovePerDay()    == ADMIN_MAX_VALIDATORS_TO_APPROVE_PER_DAY,       "EFAdmin.maxAcceptableNumValidatorsToApprovePerDay");
        require(a.maxNumberOfRequestsToFinalizePerReport()       == ADMIN_MAX_REQUESTS_TO_FINALIZE_PER_REPORT,    "EFAdmin.maxNumberOfRequestsToFinalizePerReport");

        EtherFiOracle o = EtherFiOracle(ETHERFI_ORACLE);
        require(address(o.etherFiAdmin()) == ETHERFI_ADMIN,        "EFOracle.etherFiAdmin");
        require(address(o.roleRegistry()) == ROLE_REGISTRY,        "EFOracle.roleRegistry");
        require(o.minQuorumSize()         == ORACLE_MIN_QUORUM_SIZE,"EFOracle.minQuorumSize");
    }

    function _verifyImmutablesRedemption() internal view {
        EtherFiRedemptionManager r = EtherFiRedemptionManager(payable(ETHERFI_REDEMPTION_MANAGER));
        require(r.treasury()                          == TREASURY,                  "EFRedemption.treasury");
        require(address(r.roleRegistry())             == ROLE_REGISTRY,             "EFRedemption.roleRegistry");
        require(address(r.eEth())                     == EETH,                      "EFRedemption.eEth");
        require(address(r.weEth())                    == WEETH,                     "EFRedemption.weEth");
        require(address(r.liquidityPool())            == LIQUIDITY_POOL,            "EFRedemption.liquidityPool");
        require(address(r.etherFiRestaker())          == ETHERFI_RESTAKER,          "EFRedemption.etherFiRestaker");
        require(address(r.priorityWithdrawalQueue())  == PRIORITY_WITHDRAWAL_QUEUE, "EFRedemption.priorityWithdrawalQueue");
        require(address(r.blacklister())              == blacklisterProxy,          "EFRedemption.blacklister");
        require(r.maxExitFeeSplitToTreasuryInBps()    == RM_MAX_EXIT_FEE_SPLIT_TO_TREASURY_BPS, "EFRedemption.maxExitFeeSplitToTreasuryInBps");
        require(r.maxExitFeeInBps()                   == RM_MAX_EXIT_FEE_BPS,       "EFRedemption.maxExitFeeInBps");
        require(r.maxLowWatermarkInBpsOfTvl()         == RM_MAX_LOW_WATERMARK_BPS_OF_TVL, "EFRedemption.maxLowWatermarkInBpsOfTvl");
    }

    function _verifyImmutablesRestaker() internal view {
        EtherFiRestaker r = EtherFiRestaker(payable(ETHERFI_RESTAKER));
        require(address(r.liquidityPool())                 == LIQUIDITY_POOL,                 "EFRestaker.liquidityPool");
        require(address(r.liquifier())                     == LIQUIFIER,                      "EFRestaker.liquifier");
        require(address(r.rewardsCoordinator())            == EIGENLAYER_REWARDS_COORDINATOR, "EFRestaker.rewardsCoordinator");
        require(r.etherFiRedemptionManager()               == ETHERFI_REDEMPTION_MANAGER,     "EFRestaker.etherFiRedemptionManager");
        require(address(r.roleRegistry())                  == ROLE_REGISTRY,                  "EFRestaker.roleRegistry");
        require(address(r.rateLimiter())                   == ETHERFI_RATE_LIMITER,           "EFRestaker.rateLimiter");
        require(address(r.eigenLayerStrategyManager())     == EIGENLAYER_STRATEGY_MANAGER,    "EFRestaker.eigenLayerStrategyManager");
        require(address(r.eigenLayerDelegationManager())   == EIGENLAYER_DELEGATION_MANAGER,  "EFRestaker.eigenLayerDelegationManager");
    }

    function _verifyImmutablesValidatorStack() internal view {
        EtherFiNodesManager n = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER));
        require(address(n.stakingManager())  == STAKING_MANAGER,       "EFNodesMgr.stakingManager");
        require(address(n.roleRegistry())    == ROLE_REGISTRY,         "EFNodesMgr.roleRegistry");
        require(address(n.rateLimiter())     == ETHERFI_RATE_LIMITER,  "EFNodesMgr.rateLimiter");

        StakingManager s = StakingManager(STAKING_MANAGER);
        require(s.liquidityPool()                  == LIQUIDITY_POOL,       "SM.liquidityPool");
        require(address(s.etherFiNodesManager())   == ETHERFI_NODES_MANAGER,"SM.etherFiNodesManager");
        require(address(s.depositContractEth2())   == ETH2_DEPOSIT_CONTRACT,"SM.depositContractEth2");
        require(address(s.auctionManager())        == AUCTION_MANAGER,      "SM.auctionManager");
        require(address(s.etherFiNodeBeacon())     == ETHERFI_NODE_BEACON,  "SM.etherFiNodeBeacon");
        require(address(s.roleRegistry())          == ROLE_REGISTRY,        "SM.roleRegistry");

        AuctionManager a = AuctionManager(AUCTION_MANAGER);
        require(address(a.roleRegistry())               == ROLE_REGISTRY,        "Auction.roleRegistry");
        require(address(a.blacklister())                == blacklisterProxy,     "Auction.blacklister");
        require(address(a.nodeOperatorManager())        == NODE_OPERATOR_MANAGER,"Auction.nodeOperatorManager");
        require(a.stakingManagerContractAddress()       == STAKING_MANAGER,      "Auction.stakingManagerContractAddress");
        require(a.treasury()                            == TREASURY,             "Auction.treasury");

        NodeOperatorManager nm = NodeOperatorManager(NODE_OPERATOR_MANAGER);
        require(nm.auctionManagerContractAddress() == AUCTION_MANAGER, "NodeOp.auctionManagerContractAddress");
        require(address(nm.roleRegistry())         == ROLE_REGISTRY,   "NodeOp.roleRegistry");
    }

    function _verifyImmutablesMembership() internal view {
        MembershipManager m = MembershipManager(payable(MEMBERSHIP_MANAGER));
        require(address(m.eETH())            == EETH,                "MM.eETH");
        require(address(m.liquidityPool())   == LIQUIDITY_POOL,      "MM.liquidityPool");
        require(address(m.membershipNFT())   == MEMBERSHIP_NFT,      "MM.membershipNFT");
        require(address(m.etherFiAdmin())    == ETHERFI_ADMIN,       "MM.etherFiAdmin");
        require(address(m.roleRegistry())    == ROLE_REGISTRY,       "MM.roleRegistry");
        require(address(m.blacklister())     == blacklisterProxy,    "MM.blacklister");

        MembershipNFT mn = MembershipNFT(MEMBERSHIP_NFT);
        require(address(mn.liquidityPool())      == LIQUIDITY_POOL,    "MNFT.liquidityPool");
        require(address(mn.membershipManager())  == MEMBERSHIP_MANAGER,"MNFT.membershipManager");
        require(address(mn.roleRegistry())       == ROLE_REGISTRY,     "MNFT.roleRegistry");
        require(address(mn.blacklister())        == blacklisterProxy,  "MNFT.blacklister");
    }

    function _verifyImmutablesRateLimiter() internal view {
        EtherFiRateLimiter rl = EtherFiRateLimiter(payable(ETHERFI_RATE_LIMITER));
        require(rl.eETH()                   == EETH,          "RateLimiter.eETH");
        require(rl.weETH()                  == WEETH,         "RateLimiter.weETH");
        require(address(rl.roleRegistry())  == ROLE_REGISTRY, "RateLimiter.roleRegistry");
    }

    function _verifyImmutablesPeripherals() internal view {
        PriorityWithdrawalQueue pwq = PriorityWithdrawalQueue(payable(PRIORITY_WITHDRAWAL_QUEUE));
        require(address(pwq.liquidityPool()) == LIQUIDITY_POOL,                  "PWQ.liquidityPool");
        require(address(pwq.eETH())          == EETH,                            "PWQ.eETH");
        require(address(pwq.weETH())         == WEETH,                           "PWQ.weETH");
        require(pwq.treasury()    == WITHDRAW_REQUEST_NFT_BUYBACK_SAFE, "PWQ.treasury");
        require(pwq.minDelay()               == PWQ_MIN_DELAY,                   "PWQ.minDelay");
        require(address(pwq.roleRegistry())  == ROLE_REGISTRY,                   "PWQ.roleRegistry");

        EtherFiRewardsRouter rr = EtherFiRewardsRouter(payable(ETHERFI_REWARDS_ROUTER));
        require(rr.treasury()                == TREASURY,        "RewardsRouter.treasury");
        require(rr.liquidityPool()           == LIQUIDITY_POOL,  "RewardsRouter.liquidityPool");
        require(address(rr.roleRegistry())   == ROLE_REGISTRY,   "RewardsRouter.roleRegistry");

        RestakingRewardsRouter rrr = RestakingRewardsRouter(payable(RESTAKING_REWARDS_ROUTER));
        require(rrr.liquidityPool()          == LIQUIDITY_POOL,        "RestakingRR.liquidityPool");
        require(rrr.rewardTokenAddress()     == EIGEN,                "RestakingRR.rewardTokenAddress");
        require(address(rrr.roleRegistry())  == ROLE_REGISTRY,         "RestakingRR.roleRegistry");

        CumulativeMerkleRewardsDistributor cmrd = CumulativeMerkleRewardsDistributor(payable(CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR));
        require(address(cmrd.roleRegistry()) == ROLE_REGISTRY, "CMRD.roleRegistry");

        DepositAdapter da = DepositAdapter(payable(DEPOSIT_ADAPTER));
        require(address(da.liquidityPool())  == LIQUIDITY_POOL,     "DepositAdapter.liquidityPool");
        require(address(da.liquifier())      == LIQUIFIER,          "DepositAdapter.liquifier");
        require(address(da.eETH())           == EETH,               "DepositAdapter.eETH");
        require(address(da.weETH())          == WEETH,              "DepositAdapter.weETH");
        require(address(da.wETH())           == WETH,               "DepositAdapter.wETH");
        require(address(da.stETH())          == STETH,              "DepositAdapter.stETH");
        require(address(da.wstETH())         == WSTETH,             "DepositAdapter.wstETH");
        require(address(da.blacklister())    == blacklisterProxy,   "DepositAdapter.blacklister");
        require(address(da.roleRegistry())   == ROLE_REGISTRY,      "DepositAdapter.roleRegistry");

        WeETHWithdrawAdapter wwa = WeETHWithdrawAdapter(payable(WEETH_WITHDRAW_ADAPTER));
        require(address(wwa.weETH())              == WEETH,                "WeETHWA.weETH");
        require(address(wwa.eETH())               == EETH,                 "WeETHWA.eETH");
        require(address(wwa.liquidityPool())      == LIQUIDITY_POOL,       "WeETHWA.liquidityPool");
        require(address(wwa.withdrawRequestNFT()) == WITHDRAW_REQUEST_NFT, "WeETHWA.withdrawRequestNFT");
        require(address(wwa.blacklister())        == blacklisterProxy,     "WeETHWA.blacklister");
        require(address(wwa.roleRegistry())       == ROLE_REGISTRY,        "WeETHWA.roleRegistry");
    }

    //--------------------------------------------------------------------------------------
    // STEP 6: verifyAccessControlPreservation
    //--------------------------------------------------------------------------------------
    function verifyAccessControlPreservation() public view {
        console2.log("=== Step 6: Verifying Access Control Preservation ===");
        address[22] memory proxies = _upgradedProxies();
        for (uint256 k = 0; k < proxies.length; k++) {
            address p = proxies[k];
            Snap memory pre = preSnap[p];
            require(_getOwner(p)  == pre.owner,  string.concat("owner changed: ", vm.toString(p)));
            require(_getPaused(p) == pre.paused, string.concat("paused changed: ", vm.toString(p)));
        }
        // Initialization state - upgraded proxies must remain non-reinitializable.
        verifyNotReinitializable(EETH,                       "EETH");
        verifyNotReinitializable(WEETH,                      "WeETH");
        verifyNotReinitializable(LIQUIDITY_POOL,             "LiquidityPool");
        verifyNotReinitializable(WITHDRAW_REQUEST_NFT,       "WithdrawRequestNFT");
        verifyNotReinitializable(LIQUIFIER,                  "Liquifier");
        verifyNotReinitializable(ETHERFI_ADMIN,              "EtherFiAdmin");
        verifyNotReinitializable(ETHERFI_ORACLE,             "EtherFiOracle");
        verifyNotReinitializable(ETHERFI_REDEMPTION_MANAGER, "EtherFiRedemptionManager");
        verifyNotReinitializable(ETHERFI_RESTAKER,           "EtherFiRestaker");
        verifyNotReinitializable(ETHERFI_NODES_MANAGER,      "EtherFiNodesManager");
        verifyNotReinitializable(STAKING_MANAGER,            "StakingManager");
        verifyNotReinitializable(AUCTION_MANAGER,            "AuctionManager");
        verifyNotReinitializable(NODE_OPERATOR_MANAGER,      "NodeOperatorManager");
        verifyNotReinitializable(MEMBERSHIP_MANAGER,         "MembershipManager");
        verifyNotReinitializable(MEMBERSHIP_NFT,             "MembershipNFT");
        verifyNotReinitializable(ETHERFI_RATE_LIMITER,       "EtherFiRateLimiter");
        verifyNotReinitializable(PRIORITY_WITHDRAWAL_QUEUE,             "PriorityWithdrawalQueue");
        verifyNotReinitializable(ETHERFI_REWARDS_ROUTER,                "EtherFiRewardsRouter");
        verifyNotReinitializable(RESTAKING_REWARDS_ROUTER,              "RestakingRewardsRouter");
        verifyNotReinitializable(CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR, "CumulativeMerkleRewardsDistributor");
        verifyNotReinitializable(DEPOSIT_ADAPTER,                       "DepositAdapter");
        verifyNotReinitializable(WEETH_WITHDRAW_ADAPTER,                "WeETHWithdrawAdapter");
        console2.log("[OK] owner + paused + init state preserved");
        console2.log("");
    }

    //--------------------------------------------------------------------------------------
    // STEP 7: executeRoleGrants
    //
    // RoleRegistry.grantRole is gated by `onlyOwner` on the registry — the
    // registry's owner is ETHERFI_UPGRADE_ADMIN (the upgrade multisig), NOT
    // any timelock. So every role grant is emitted as one Safe transaction
    // directly from that multisig, with no timelock wrapping.
    //--------------------------------------------------------------------------------------
    function executeRoleGrants() public {
        console2.log("=== Step 7: Executing Role Grants (ETHERFI_UPGRADE_ADMIN, no timelock) ===");

        address[] memory targets    = new address[](9);
        uint256[] memory values     = new uint256[](9);
        bytes[]   memory calldatas  = new bytes[](9);

        bytes32[9] memory roles = [
            roleRegistry.UPGRADE_TIMELOCK_ROLE(),
            roleRegistry.OPERATION_TIMELOCK_ROLE(),
            roleRegistry.OPERATION_MULTISIG_ROLE(),
            roleRegistry.SUPER_GUARDIAN_ROLE(),
            roleRegistry.GUARDIAN_ROLE(),
            roleRegistry.ORACLE_OPERATIONS_ROLE(),
            roleRegistry.HOUSEKEEPING_OPERATIONS_ROLE(),
            roleRegistry.EXECUTOR_OPERATIONS_ROLE(),
            roleRegistry.EIGENPOD_OPERATIONS_ROLE()
        ];
        address[9] memory holders = [
            HOLDER_UPGRADE_TIMELOCK_ROLE,
            HOLDER_OPERATION_TIMELOCK_ROLE,
            HOLDER_OPERATION_MULTISIG_ROLE,
            HOLDER_SUPER_GUARDIAN_ROLE,
            HOLDER_GUARDIAN_ROLE,
            HOLDER_ORACLE_OPERATIONS_ROLE,
            HOLDER_HOUSEKEEPING_OPERATIONS_ROLE,
            HOLDER_EXECUTOR_OPERATIONS_ROLE,
            HOLDER_EIGENPOD_OPERATIONS_ROLE
        ];
        for (uint256 k = 0; k < 9; k++) {
            targets[k]   = ROLE_REGISTRY;
            calldatas[k] = abi.encodeWithSelector(RoleRegistry.grantRole.selector, roles[k], holders[k]);
        }

        writeSafeJson(OUT_DIR, "role_grants.json", ETHERFI_UPGRADE_ADMIN, targets, values, calldatas, 1);

        console2.log("=== Dry-running role grants on fork ===");
        vm.startPrank(ETHERFI_UPGRADE_ADMIN);
        for (uint256 k = 0; k < 9; k++) {
            roleRegistry.grantRole(roles[k], holders[k]);
        }
        vm.stopPrank();
        console2.log("[OK] all 9 role grants executed on fork");
        console2.log("");
    }

    //--------------------------------------------------------------------------------------
    // STEP 8: executeLpWithdrawBounds
    //
    // LP.setMinWithdrawAmount / setMaxWithdrawAmount are onlyOperatingMultisig.
    // ETHERFI_OPERATING_ADMIN is granted OPERATION_MULTISIG_ROLE in step 7, so this
    // tx is broadcast directly from that Safe (no timelock).
    //
    // Order matters: setMaxWithdrawAmount must run first. The setMinWithdrawAmount
    // check requires _min <= maxWithdrawAmount, which is 0 in fresh storage and
    // would force any non-zero _min to revert.
    //--------------------------------------------------------------------------------------
    function executeLpWithdrawBounds() public {
        console2.log("=== Step 8: Executing LP Withdraw Bounds (ETHERFI_OPERATING_ADMIN, no timelock) ===");

        address[] memory targets   = new address[](2);
        uint256[] memory values    = new uint256[](2);
        bytes[]   memory calldatas = new bytes[](2);

        targets[0]   = LIQUIDITY_POOL;
        calldatas[0] = abi.encodeWithSelector(LiquidityPool.setMaxWithdrawAmount.selector, LP_MAX_WITHDRAW_AMOUNT);
        targets[1]   = LIQUIDITY_POOL;
        calldatas[1] = abi.encodeWithSelector(LiquidityPool.setMinWithdrawAmount.selector, LP_MIN_WITHDRAW_AMOUNT);

        writeSafeJson(OUT_DIR, "lp_withdraw_bounds.json", ETHERFI_OPERATING_ADMIN, targets, values, calldatas, 1);

        console2.log("=== Dry-running LP withdraw bounds on fork ===");
        vm.startPrank(ETHERFI_OPERATING_ADMIN);
        LiquidityPool(payable(LIQUIDITY_POOL)).setMaxWithdrawAmount(LP_MAX_WITHDRAW_AMOUNT);
        LiquidityPool(payable(LIQUIDITY_POOL)).setMinWithdrawAmount(LP_MIN_WITHDRAW_AMOUNT);
        vm.stopPrank();

        require(LiquidityPool(payable(LIQUIDITY_POOL)).maxWithdrawAmount() == LP_MAX_WITHDRAW_AMOUNT, "LP.maxWithdrawAmount not seeded");
        require(LiquidityPool(payable(LIQUIDITY_POOL)).minWithdrawAmount() == LP_MIN_WITHDRAW_AMOUNT, "LP.minWithdrawAmount not seeded");

        console2.log("[OK] LP min/max withdraw bounds set");
        console2.log("");
    }

    //--------------------------------------------------------------------------------------
    // STEP 9: executeOperatingConfig - Batch B
    //--------------------------------------------------------------------------------------
    function executeOperatingConfig() public {
        console2.log("=== Step 9: Executing Operating Config (Batch B, OPERATING_TIMELOCK, 2d) ===");

        address[] memory targets = new address[](60);
        bytes[]   memory data    = new bytes[](60);
        uint256[] memory values  = new uint256[](60);
        uint256 i;

        // ───────── Token-side global buckets (consumeToken on eETH/weETH) ─────────
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _createLimiter(EETH_MINT_LIMIT_ID,  EETH_MINT_CAPACITY,  EETH_MINT_REFILL_RATE));  i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _createLimiter(EETH_BURN_LIMIT_ID,  EETH_BURN_CAPACITY,  EETH_BURN_REFILL_RATE));  i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _createLimiter(WEETH_MINT_LIMIT_ID, WEETH_MINT_CAPACITY, WEETH_MINT_REFILL_RATE)); i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _createLimiter(WEETH_BURN_LIMIT_ID, WEETH_BURN_CAPACITY, WEETH_BURN_REFILL_RATE)); i++;

        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _updateConsumer(EETH_MINT_LIMIT_ID,  EETH));  i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _updateConsumer(EETH_BURN_LIMIT_ID,  EETH));  i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _updateConsumer(WEETH_MINT_LIMIT_ID, WEETH)); i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _updateConsumer(WEETH_BURN_LIMIT_ID, WEETH)); i++;

        // ───────── EtherFiNodesManager buckets (consume) ─────────
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _createLimiter(UNRESTAKING_LIMIT_ID,           UNRESTAKING_CAPACITY,           UNRESTAKING_REFILL_RATE));           i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _createLimiter(EXIT_REQUEST_LIMIT_ID,          EXIT_REQUEST_CAPACITY,          EXIT_REQUEST_REFILL_RATE));          i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _createLimiter(CONSOLIDATION_REQUEST_LIMIT_ID, CONSOLIDATION_REQUEST_CAPACITY, CONSOLIDATION_REQUEST_REFILL_RATE)); i++;

        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _updateConsumer(UNRESTAKING_LIMIT_ID,           ETHERFI_NODES_MANAGER)); i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _updateConsumer(EXIT_REQUEST_LIMIT_ID,          ETHERFI_NODES_MANAGER)); i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _updateConsumer(CONSOLIDATION_REQUEST_LIMIT_ID, ETHERFI_NODES_MANAGER)); i++;

        // ───────── EtherFiRestaker buckets (consume) ─────────
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _createLimiter(STETH_REQUEST_WITHDRAWAL_LIMIT_ID, STETH_REQUEST_WITHDRAWAL_CAPACITY, STETH_REQUEST_WITHDRAWAL_REFILL_RATE)); i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _createLimiter(QUEUE_WITHDRAWALS_LIMIT_ID,        QUEUE_WITHDRAWALS_CAPACITY,        QUEUE_WITHDRAWALS_REFILL_RATE));        i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _createLimiter(DEPOSIT_INTO_STRATEGY_LIMIT_ID,    DEPOSIT_INTO_STRATEGY_CAPACITY,    DEPOSIT_INTO_STRATEGY_REFILL_RATE));    i++;

        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _updateConsumer(STETH_REQUEST_WITHDRAWAL_LIMIT_ID, ETHERFI_RESTAKER)); i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _updateConsumer(QUEUE_WITHDRAWALS_LIMIT_ID,        ETHERFI_RESTAKER)); i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _updateConsumer(DEPOSIT_INTO_STRATEGY_LIMIT_ID,    ETHERFI_RESTAKER)); i++;

        (targets[i], data[i]) = (EETH,                       _pauseDur(PAUSE_UNTIL_EETH));                   i++;
        (targets[i], data[i]) = (WEETH,                      _pauseDur(PAUSE_UNTIL_WEETH));                  i++;
        (targets[i], data[i]) = (LIQUIDITY_POOL,             _pauseDur(PAUSE_UNTIL_LIQUIDITY_POOL));         i++;
        (targets[i], data[i]) = (WITHDRAW_REQUEST_NFT,       _pauseDur(PAUSE_UNTIL_WITHDRAW_REQUEST_NFT));   i++;
        (targets[i], data[i]) = (LIQUIFIER,                  _pauseDur(PAUSE_UNTIL_LIQUIFIER));              i++;
        (targets[i], data[i]) = (ETHERFI_NODES_MANAGER,      _pauseDur(PAUSE_UNTIL_ETHERFI_NODES_MANAGER));  i++;
        (targets[i], data[i]) = (ETHERFI_REDEMPTION_MANAGER, _pauseDur(PAUSE_UNTIL_ETHERFI_REDEMPTION_MGR)); i++;
        (targets[i], data[i]) = (AUCTION_MANAGER,            _pauseDur(PAUSE_UNTIL_AUCTION_MANAGER));        i++;
        (targets[i], data[i]) = (PRIORITY_WITHDRAWAL_QUEUE,             _pauseDur(PAUSE_UNTIL_PRIORITY_WITHDRAWAL_QUEUE));             i++;
        (targets[i], data[i]) = (CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR, _pauseDur(PAUSE_UNTIL_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR)); i++;
        (targets[i], data[i]) = (WEETH_WITHDRAW_ADAPTER,                _pauseDur(PAUSE_UNTIL_WEETH_WITHDRAW_ADAPTER));                i++;

        _shrinkAndEmit(
            BatchEmit({
                label: "Batch B - Operating",
                timelock: operatingTimelock,
                timelockAddr: OPERATING_TIMELOCK,
                adminSafe: ETHERFI_OPERATING_ADMIN,
                minDelay: OPERATING_TIMELOCK_DELAY,
                salt: keccak256(abi.encode("security-upgrades-v1-batchB", block.number)),
                scheduleFile: "ops_schedule.json",
                executeFile: "ops_execute.json"
            }),
            targets, values, data, i
        );
    }

    //--------------------------------------------------------------------------------------
    // STEP 10: verifyOperatingConfig
    //--------------------------------------------------------------------------------------
    function verifyOperatingConfig() public view {
        console2.log("=== Step 10: Verifying Operating Config ===");
        EtherFiRateLimiter rl = EtherFiRateLimiter(payable(ETHERFI_RATE_LIMITER));
        require(rl.limitExists(EETH_MINT_LIMIT_ID),                "EETH_MINT bucket missing");
        require(rl.limitExists(EETH_BURN_LIMIT_ID),                "EETH_BURN bucket missing");
        require(rl.limitExists(WEETH_MINT_LIMIT_ID),               "WEETH_MINT bucket missing");
        require(rl.limitExists(WEETH_BURN_LIMIT_ID),               "WEETH_BURN bucket missing");
        require(rl.limitExists(UNRESTAKING_LIMIT_ID),              "UNRESTAKING bucket missing");
        require(rl.limitExists(EXIT_REQUEST_LIMIT_ID),             "EXIT_REQUEST bucket missing");
        require(rl.limitExists(CONSOLIDATION_REQUEST_LIMIT_ID),    "CONSOLIDATION_REQUEST bucket missing");
        require(rl.limitExists(STETH_REQUEST_WITHDRAWAL_LIMIT_ID), "STETH_REQUEST_WITHDRAWAL bucket missing");
        require(rl.limitExists(QUEUE_WITHDRAWALS_LIMIT_ID),        "QUEUE_WITHDRAWALS bucket missing");
        require(rl.limitExists(DEPOSIT_INTO_STRATEGY_LIMIT_ID),    "DEPOSIT_INTO_STRATEGY bucket missing");

        require(rl.isConsumerAllowed(EETH_MINT_LIMIT_ID,                EETH),                  "EETH consumer (mint) not allowed");
        require(rl.isConsumerAllowed(EETH_BURN_LIMIT_ID,                EETH),                  "EETH consumer (burn) not allowed");
        require(rl.isConsumerAllowed(WEETH_MINT_LIMIT_ID,               WEETH),                 "WeETH consumer (mint) not allowed");
        require(rl.isConsumerAllowed(WEETH_BURN_LIMIT_ID,               WEETH),                 "WeETH consumer (burn) not allowed");
        require(rl.isConsumerAllowed(UNRESTAKING_LIMIT_ID,              ETHERFI_NODES_MANAGER), "EFNodesMgr consumer (unrestaking) not allowed");
        require(rl.isConsumerAllowed(EXIT_REQUEST_LIMIT_ID,             ETHERFI_NODES_MANAGER), "EFNodesMgr consumer (exit) not allowed");
        require(rl.isConsumerAllowed(CONSOLIDATION_REQUEST_LIMIT_ID,    ETHERFI_NODES_MANAGER), "EFNodesMgr consumer (consolidation) not allowed");
        require(rl.isConsumerAllowed(STETH_REQUEST_WITHDRAWAL_LIMIT_ID, ETHERFI_RESTAKER),      "EFRestaker consumer (stEth) not allowed");
        require(rl.isConsumerAllowed(QUEUE_WITHDRAWALS_LIMIT_ID,        ETHERFI_RESTAKER),      "EFRestaker consumer (queue) not allowed");
        require(rl.isConsumerAllowed(DEPOSIT_INTO_STRATEGY_LIMIT_ID,    ETHERFI_RESTAKER),      "EFRestaker consumer (deposit) not allowed");

        require(EETHToken(EETH).pauseUntilDuration()                                  == PAUSE_UNTIL_EETH,                  "EETH pause duration mismatch");
        require(WeETHToken(WEETH).pauseUntilDuration()                                == PAUSE_UNTIL_WEETH,                 "WeETH pause duration mismatch");
        require(LiquidityPool(payable(LIQUIDITY_POOL)).pauseUntilDuration()           == PAUSE_UNTIL_LIQUIDITY_POOL,        "LP pause duration mismatch");
        require(WithdrawRequestNFT(payable(WITHDRAW_REQUEST_NFT)).pauseUntilDuration()== PAUSE_UNTIL_WITHDRAW_REQUEST_NFT,  "NFT pause duration mismatch");
        require(Liquifier(payable(LIQUIFIER)).pauseUntilDuration()                    == PAUSE_UNTIL_LIQUIFIER,             "Liquifier pause duration mismatch");
        require(EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER)).pauseUntilDuration()                       == PAUSE_UNTIL_ETHERFI_NODES_MANAGER,                "EFNodesMgr pause duration mismatch");
        require(EtherFiRedemptionManager(payable(ETHERFI_REDEMPTION_MANAGER)).pauseUntilDuration()             == PAUSE_UNTIL_ETHERFI_REDEMPTION_MGR,               "EFRedemption pause duration mismatch");
        require(AuctionManager(AUCTION_MANAGER).pauseUntilDuration()                                           == PAUSE_UNTIL_AUCTION_MANAGER,                      "Auction pause duration mismatch");
        require(PriorityWithdrawalQueue(payable(PRIORITY_WITHDRAWAL_QUEUE)).pauseUntilDuration()               == PAUSE_UNTIL_PRIORITY_WITHDRAWAL_QUEUE,             "PWQ pause duration mismatch");
        require(CumulativeMerkleRewardsDistributor(payable(CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR)).pauseUntilDuration() == PAUSE_UNTIL_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR, "CMRD pause duration mismatch");
        require(WeETHWithdrawAdapter(payable(WEETH_WITHDRAW_ADAPTER)).pauseUntilDuration()                     == PAUSE_UNTIL_WEETH_WITHDRAW_ADAPTER,               "WeETHWA pause duration mismatch");

        require(roleRegistry.hasRole(roleRegistry.UPGRADE_TIMELOCK_ROLE(),    HOLDER_UPGRADE_TIMELOCK_ROLE),   "UPGRADE_TIMELOCK_ROLE not granted");
        require(roleRegistry.hasRole(roleRegistry.OPERATION_TIMELOCK_ROLE(),  HOLDER_OPERATION_TIMELOCK_ROLE), "OPERATION_TIMELOCK_ROLE not granted");
        require(roleRegistry.hasRole(roleRegistry.OPERATION_MULTISIG_ROLE(),  HOLDER_OPERATION_MULTISIG_ROLE), "OPERATION_MULTISIG_ROLE not granted");
        require(roleRegistry.hasRole(roleRegistry.SUPER_GUARDIAN_ROLE(),          HOLDER_SUPER_GUARDIAN_ROLE),          "SUPER_GUARDIAN_ROLE not granted");
        require(roleRegistry.hasRole(roleRegistry.GUARDIAN_ROLE(),                HOLDER_GUARDIAN_ROLE),                "GUARDIAN_ROLE not granted");
        require(roleRegistry.hasRole(roleRegistry.ORACLE_OPERATIONS_ROLE(),       HOLDER_ORACLE_OPERATIONS_ROLE),       "ORACLE_OPERATIONS_ROLE not granted");
        require(roleRegistry.hasRole(roleRegistry.HOUSEKEEPING_OPERATIONS_ROLE(), HOLDER_HOUSEKEEPING_OPERATIONS_ROLE), "HOUSEKEEPING_OPERATIONS_ROLE not granted");
        require(roleRegistry.hasRole(roleRegistry.EXECUTOR_OPERATIONS_ROLE(),     HOLDER_EXECUTOR_OPERATIONS_ROLE),     "EXECUTOR_OPERATIONS_ROLE not granted");
        require(roleRegistry.hasRole(roleRegistry.EIGENPOD_OPERATIONS_ROLE(),     HOLDER_EIGENPOD_OPERATIONS_ROLE),     "EIGENPOD_OPERATIONS_ROLE not granted");

        require(LiquidityPool(payable(LIQUIDITY_POOL)).maxWithdrawAmount() == LP_MAX_WITHDRAW_AMOUNT, "LP.maxWithdrawAmount mismatch");
        require(LiquidityPool(payable(LIQUIDITY_POOL)).minWithdrawAmount() == LP_MIN_WITHDRAW_AMOUNT, "LP.minWithdrawAmount mismatch");

        console2.log("[OK] rate-limiter buckets + pause durations + role grants + LP withdraw bounds verified");
        console2.log("");
    }

    //--------------------------------------------------------------------------------------
    // Helpers
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

    struct BatchEmit {
        string label;
        EtherFiTimelock timelock;
        address timelockAddr;
        address adminSafe;
        uint256 minDelay;
        bytes32 salt;
        string scheduleFile;
        string executeFile;
    }

    function _shrinkAndEmit(
        BatchEmit memory b,
        address[] memory targets,
        uint256[] memory values,
        bytes[]   memory data,
        uint256          used
    ) internal {
        (address[] memory tt, uint256[] memory vv, bytes[] memory dd) = _shrink(targets, values, data, used);
        _writeSafeJsons(b, tt, vv, dd);
        _dryRunOnFork(b, tt, vv, dd);
    }

    function _shrink(
        address[] memory targets,
        uint256[] memory values,
        bytes[]   memory data,
        uint256          used
    ) internal pure returns (address[] memory tt, uint256[] memory vv, bytes[] memory dd) {
        tt = new address[](used);
        vv = new uint256[](used);
        dd = new bytes[](used);
        for (uint256 k = 0; k < used; k++) {
            tt[k] = targets[k];
            vv[k] = values[k];
            dd[k] = data[k];
        }
    }

    function _writeSafeJsons(
        BatchEmit memory b,
        address[] memory tt,
        uint256[] memory vv,
        bytes[]   memory dd
    ) internal {
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            b.timelock.scheduleBatch.selector, tt, vv, dd, bytes32(0), b.salt, b.minDelay
        );
        bytes memory executeCalldata = abi.encodeWithSelector(
            b.timelock.executeBatch.selector, tt, vv, dd, bytes32(0), b.salt
        );
        writeSafeJson(OUT_DIR, b.scheduleFile, b.adminSafe, b.timelockAddr, 0, scheduleCalldata, 1);
        writeSafeJson(OUT_DIR, b.executeFile,  b.adminSafe, b.timelockAddr, 0, executeCalldata,  1);
    }

    function _dryRunOnFork(
        BatchEmit memory b,
        address[] memory tt,
        uint256[] memory vv,
        bytes[]   memory dd
    ) internal {
        console2.log(string.concat("=== Dry-running ", b.label, " on fork ==="));
        vm.startPrank(b.adminSafe);
        b.timelock.scheduleBatch(tt, vv, dd, bytes32(0), b.salt, b.minDelay);
        vm.warp(block.timestamp + b.minDelay + 1);
        b.timelock.executeBatch(tt, vv, dd, bytes32(0), b.salt);
        vm.stopPrank();
        console2.log(string.concat("[OK] ", b.label, " executed on fork"));
        console2.log("");
    }
}
