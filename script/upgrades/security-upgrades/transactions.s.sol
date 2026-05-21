// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {EtherFiTimelock} from "../../../src/EtherFiTimelock.sol";
import {RoleRegistry} from "../../../src/RoleRegistry.sol";
import {EtherFiRateLimiter} from "../../../src/EtherFiRateLimiter.sol";
import {BucketRateLimiter} from "../../../src/BucketRateLimiter.sol";

import {EETH as EETHToken} from "../../../src/EETH.sol";
import {WeETH as WeETHToken} from "../../../src/WeETH.sol";
import {LiquidityPool} from "../../../src/LiquidityPool.sol";
import {WithdrawRequestNFT} from "../../../src/WithdrawRequestNFT.sol";
import {Liquifier} from "../../../src/Liquifier.sol";
import {EtherFiAdmin} from "../../../src/EtherFiAdmin.sol";
import {EtherFiOracle} from "../../../src/EtherFiOracle.sol";
import {EtherFiRedemptionManager} from "../../../src/EtherFiRedemptionManager.sol";
import {EtherFiRestaker} from "../../../src/EtherFiRestaker.sol";
import {EtherFiNodesManager} from "../../../src/EtherFiNodesManager.sol";
import {StakingManager} from "../../../src/StakingManager.sol";
import {AuctionManager} from "../../../src/AuctionManager.sol";
import {NodeOperatorManager} from "../../../src/NodeOperatorManager.sol";
import {MembershipManager} from "../../../src/MembershipManager.sol";
import {MembershipNFT} from "../../../src/MembershipNFT.sol";

import {ContractCodeChecker} from "../../ContractCodeChecker.sol";
import {Deployed} from "../../deploys/Deployed.s.sol";
import {Utils} from "../../utils/utils.sol";

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
 *   7. executeOperatingConfig      — Batch B (OPERATING_TIMELOCK, 2d)
 *   8. verifyOperatingConfig       — rate-limiter buckets + pause durations set
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
    // CONSTRUCTOR PARAMS - MUST MATCH deploy.s.sol exactly.
    // Re-stated here so verifyDeployedBytecode can rebuild each impl locally.
    // ─────────────────────────────────────────────────────────────────────
    // Liquifier
    address constant STETH_PRICE_FEED = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    address constant LIDO             = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant STETH_ETH_CURVE_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    uint256 constant LIQUIFIER_MIN_DISCOUNT_BPS = 100;
    uint256 constant LIQUIFIER_STALE_PRICE_WINDOW = 24 hours;
    uint256 constant LIQUIFIER_MAX_PRICE_DEVIATION_BPS = 500;

    // EtherFiRedemptionManager
    uint256 constant RM_MAX_EXIT_FEE_SPLIT_TO_TREASURY_BPS = 10_000;
    uint256 constant RM_MAX_EXIT_FEE_BPS                   = 500;
    uint256 constant RM_MAX_LOW_WATERMARK_BPS_OF_TVL       = 2_000;

    // EtherFiAdmin
    int256  constant ADMIN_MAX_REBASE_APR_BPS                  = 1_000;
    uint256 constant ADMIN_MAX_VALIDATOR_TASK_BATCH_SIZE        = 25;
    uint256 constant ADMIN_STALE_ORACLE_REPORT_BLOCK_WINDOW     = 7200 * 7;
    uint256 constant ADMIN_MAX_FINALIZED_WITHDRAWAL_AMOUNT_PER_DAY = 100_000 ether;
    uint256 constant ADMIN_MAX_VALIDATORS_TO_APPROVE_PER_DAY    = 2_000;

    // LiquidityPool
    uint256 constant LP_MIN_AMOUNT_FOR_SHARE = 1 ether;

    // WithdrawRequestNFT
    uint256 constant WNFT_MIN_ACCEPTABLE_SHARE_RATE = 1;
    uint256 constant WNFT_MAX_ACCEPTABLE_SHARE_RATE = 4 ether;

    address constant ETH2_DEPOSIT_CONTRACT = 0x00000000219ab540356cBB839Cbe05303d7705Fa;

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
    uint64 constant EETH_MINT_CAPACITY        = 0;
    uint64 constant EETH_MINT_REFILL_RATE     = 0;
    uint64 constant EETH_BURN_CAPACITY        = 0;
    uint64 constant EETH_BURN_REFILL_RATE     = 0;
    uint64 constant EETH_TRANSFER_CAPACITY    = 0;
    uint64 constant EETH_TRANSFER_REFILL_RATE = 0;
    uint64 constant WEETH_MINT_CAPACITY        = 0;
    uint64 constant WEETH_MINT_REFILL_RATE     = 0;
    uint64 constant WEETH_BURN_CAPACITY        = 0;
    uint64 constant WEETH_BURN_REFILL_RATE     = 0;
    uint64 constant WEETH_TRANSFER_CAPACITY    = 0;
    uint64 constant WEETH_TRANSFER_REFILL_RATE = 0;

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

    // Bucket IDs
    bytes32 constant EETH_MINT_LIMIT_ID      = keccak256("EETH_MINT_LIMIT_ID");
    bytes32 constant EETH_BURN_LIMIT_ID      = keccak256("EETH_BURN_LIMIT_ID");
    bytes32 constant EETH_TRANSFER_LIMIT_ID  = keccak256("EETH_TRANSFER_LIMIT_ID");
    bytes32 constant WEETH_MINT_LIMIT_ID     = keccak256("WEETH_MINT_LIMIT_ID");
    bytes32 constant WEETH_BURN_LIMIT_ID     = keccak256("WEETH_BURN_LIMIT_ID");
    bytes32 constant WEETH_TRANSFER_LIMIT_ID = keccak256("WEETH_TRANSFER_LIMIT_ID");

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

        executeOperatingConfig();
        verifyOperatingConfig();
    }

    /// @dev Fail loudly the moment a required constant is unset.
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

        require(EETH_MINT_CAPACITY != 0,        "preflight: EETH_MINT_CAPACITY unset");
        require(EETH_MINT_REFILL_RATE != 0,     "preflight: EETH_MINT_REFILL_RATE unset");
        require(EETH_BURN_CAPACITY != 0,        "preflight: EETH_BURN_CAPACITY unset");
        require(EETH_BURN_REFILL_RATE != 0,     "preflight: EETH_BURN_REFILL_RATE unset");
        require(EETH_TRANSFER_CAPACITY != 0,    "preflight: EETH_TRANSFER_CAPACITY unset");
        require(EETH_TRANSFER_REFILL_RATE != 0, "preflight: EETH_TRANSFER_REFILL_RATE unset");
        require(WEETH_MINT_CAPACITY != 0,       "preflight: WEETH_MINT_CAPACITY unset");
        require(WEETH_MINT_REFILL_RATE != 0,    "preflight: WEETH_MINT_REFILL_RATE unset");
        require(WEETH_BURN_CAPACITY != 0,       "preflight: WEETH_BURN_CAPACITY unset");
        require(WEETH_BURN_REFILL_RATE != 0,    "preflight: WEETH_BURN_REFILL_RATE unset");
        require(WEETH_TRANSFER_CAPACITY != 0,   "preflight: WEETH_TRANSFER_CAPACITY unset");
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
        _verifyTokens();
        _verifyCore();
        _verifyAdminAndOracle();
        _verifyValidatorStack();
        _verifyMembership();
        _verifyRateLimiter();
        console2.log("[OK] all 16 implementations matched local bytecode");
        console2.log("");
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
                lido: LIDO,
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
            ADMIN_MAX_VALIDATORS_TO_APPROVE_PER_DAY
        );
        codeChecker.verifyContractByteCodeMatch(etherFiAdminImpl, address(fresh));

        EtherFiOracle fresh2 = new EtherFiOracle(ETHERFI_ADMIN, ROLE_REGISTRY);
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

        StakingManager fresh3 = new StakingManager(
            LIQUIDITY_POOL, ETHERFI_NODES_MANAGER, ETH2_DEPOSIT_CONTRACT,
            AUCTION_MANAGER, ETHERFI_NODE_BEACON, ROLE_REGISTRY
        );
        codeChecker.verifyContractByteCodeMatch(stakingManagerImpl, address(fresh3));

        AuctionManager fresh4 = new AuctionManager(
            ROLE_REGISTRY, blacklisterProxy, NODE_OPERATOR_MANAGER, STAKING_MANAGER, MEMBERSHIP_MANAGER
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
        BucketRateLimiter fresh = new BucketRateLimiter(ROLE_REGISTRY);
        codeChecker.verifyContractByteCodeMatch(bucketRateLimiterImpl, address(fresh));
    }

    //--------------------------------------------------------------------------------------
    // STEP 2: takePreUpgradeSnapshots
    //--------------------------------------------------------------------------------------
    function takePreUpgradeSnapshots() public {
        console2.log("=== Step 2: Taking Pre-Upgrade Snapshots ===");
        address[17] memory proxies = _upgradedProxies();
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
        s = new bytes4[](14);
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
    }
    function _oracleImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = bytes4(keccak256("etherFiAdmin()"));
        s[1] = bytes4(keccak256("roleRegistry()"));
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
        s = new bytes4[](5);
        s[0] = bytes4(keccak256("roleRegistry()"));
        s[1] = bytes4(keccak256("blacklister()"));
        s[2] = bytes4(keccak256("nodeOperatorManager()"));
        s[3] = bytes4(keccak256("stakingManagerContractAddress()"));
        s[4] = bytes4(keccak256("membershipManagerContractAddress()"));
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

    function _upgradedProxies() internal pure returns (address[17] memory list) {
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
        list[16] = PRIORITY_WITHDRAWAL_QUEUE; // snapshot only; not upgraded here
    }

    //--------------------------------------------------------------------------------------
    // STEP 3: executeUpgrade - Batch A
    //--------------------------------------------------------------------------------------
    function executeUpgrade() public {
        console2.log("=== Step 3: Executing Upgrade (Batch A, UPGRADE_TIMELOCK, 10d) ===");

        address[] memory targets = new address[](40);
        bytes[]   memory data    = new bytes[](40);
        uint256[] memory values  = new uint256[](40);
        uint256 i;

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

        (targets[i], data[i]) = (LIQUIDITY_POOL,
            abi.encodeWithSelector(LiquidityPool.initializeOnUpgradeV2.selector));                    i++;
        (targets[i], data[i]) = (WITHDRAW_REQUEST_NFT,
            abi.encodeWithSelector(WithdrawRequestNFT.initializeShareRateFreezeUpgrade.selector));    i++;

        i = _roleGrant(targets, data, i, roleRegistry.UPGRADE_TIMELOCK_ROLE(),   HOLDER_UPGRADE_TIMELOCK_ROLE);
        i = _roleGrant(targets, data, i, roleRegistry.OPERATION_TIMELOCK_ROLE(), HOLDER_OPERATION_TIMELOCK_ROLE);
        i = _roleGrant(targets, data, i, roleRegistry.OPERATION_MULTISIG_ROLE(), HOLDER_OPERATION_MULTISIG_ROLE);

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
        _assertImpl(AUCTION_MANAGER,            auctionManagerImpl,           "AuctionManager");
        _assertImpl(NODE_OPERATOR_MANAGER,      nodeOperatorManagerImpl,      "NodeOperatorManager");
        _assertImpl(MEMBERSHIP_MANAGER,         membershipManagerImpl,        "MembershipManager");
        _assertImpl(MEMBERSHIP_NFT,             membershipNFTImpl,            "MembershipNFT");
        _assertImpl(ETHERFI_RATE_LIMITER,       bucketRateLimiterImpl,        "EtherFiRateLimiter");
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
        require(n.treasury()                  == WITHDRAW_REQUEST_NFT_BUYBACK_SAFE, "NFT.treasury");
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
        require(address(l.lido())                == LIDO,                  "Liquifier.lido");
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

        EtherFiOracle o = EtherFiOracle(ETHERFI_ORACLE);
        require(address(o.etherFiAdmin()) == ETHERFI_ADMIN, "EFOracle.etherFiAdmin");
        require(address(o.roleRegistry()) == ROLE_REGISTRY, "EFOracle.roleRegistry");
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
        require(a.membershipManagerContractAddress()    == MEMBERSHIP_MANAGER,   "Auction.membershipManagerContractAddress");

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

    //--------------------------------------------------------------------------------------
    // STEP 6: verifyAccessControlPreservation
    //--------------------------------------------------------------------------------------
    function verifyAccessControlPreservation() public view {
        console2.log("=== Step 6: Verifying Access Control Preservation ===");
        address[17] memory proxies = _upgradedProxies();
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
        console2.log("[OK] owner + paused + init state preserved");
        console2.log("");
    }

    //--------------------------------------------------------------------------------------
    // STEP 7: executeOperatingConfig - Batch B
    //--------------------------------------------------------------------------------------
    function executeOperatingConfig() public {
        console2.log("=== Step 7: Executing Operating Config (Batch B, OPERATING_TIMELOCK, 2d) ===");

        address[] memory targets = new address[](60);
        bytes[]   memory data    = new bytes[](60);
        uint256[] memory values  = new uint256[](60);
        uint256 i;

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

        i = _roleGrant(targets, data, i, roleRegistry.SUPER_GUARDIAN_ROLE(),          HOLDER_SUPER_GUARDIAN_ROLE);
        i = _roleGrant(targets, data, i, roleRegistry.GUARDIAN_ROLE(),                HOLDER_GUARDIAN_ROLE);
        i = _roleGrant(targets, data, i, roleRegistry.ORACLE_OPERATIONS_ROLE(),       HOLDER_ORACLE_OPERATIONS_ROLE);
        i = _roleGrant(targets, data, i, roleRegistry.HOUSEKEEPING_OPERATIONS_ROLE(), HOLDER_HOUSEKEEPING_OPERATIONS_ROLE);
        i = _roleGrant(targets, data, i, roleRegistry.EXECUTOR_OPERATIONS_ROLE(),     HOLDER_EXECUTOR_OPERATIONS_ROLE);
        i = _roleGrant(targets, data, i, roleRegistry.EIGENPOD_OPERATIONS_ROLE(),     HOLDER_EIGENPOD_OPERATIONS_ROLE);

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
    // STEP 8: verifyOperatingConfig
    //--------------------------------------------------------------------------------------
    function verifyOperatingConfig() public view {
        console2.log("=== Step 8: Verifying Operating Config ===");
        EtherFiRateLimiter rl = EtherFiRateLimiter(payable(ETHERFI_RATE_LIMITER));
        require(rl.limitExists(EETH_MINT_LIMIT_ID),      "EETH_MINT bucket missing");
        require(rl.limitExists(EETH_BURN_LIMIT_ID),      "EETH_BURN bucket missing");
        require(rl.limitExists(EETH_TRANSFER_LIMIT_ID),  "EETH_TRANSFER bucket missing");
        require(rl.limitExists(WEETH_MINT_LIMIT_ID),     "WEETH_MINT bucket missing");
        require(rl.limitExists(WEETH_BURN_LIMIT_ID),     "WEETH_BURN bucket missing");
        require(rl.limitExists(WEETH_TRANSFER_LIMIT_ID), "WEETH_TRANSFER bucket missing");
        require(rl.isConsumerAllowed(EETH_MINT_LIMIT_ID,      EETH),  "EETH not allowed consumer");
        require(rl.isConsumerAllowed(EETH_BURN_LIMIT_ID,      EETH),  "EETH not allowed consumer (burn)");
        require(rl.isConsumerAllowed(EETH_TRANSFER_LIMIT_ID,  EETH),  "EETH not allowed consumer (transfer)");
        require(rl.isConsumerAllowed(WEETH_MINT_LIMIT_ID,     WEETH), "WeETH not allowed consumer");
        require(rl.isConsumerAllowed(WEETH_BURN_LIMIT_ID,     WEETH), "WeETH not allowed consumer (burn)");
        require(rl.isConsumerAllowed(WEETH_TRANSFER_LIMIT_ID, WEETH), "WeETH not allowed consumer (transfer)");

        require(EETHToken(EETH).pauseUntilDuration()                                  == PAUSE_UNTIL_EETH,                  "EETH pause duration mismatch");
        require(WeETHToken(WEETH).pauseUntilDuration()                                == PAUSE_UNTIL_WEETH,                 "WeETH pause duration mismatch");
        require(LiquidityPool(payable(LIQUIDITY_POOL)).pauseUntilDuration()           == PAUSE_UNTIL_LIQUIDITY_POOL,        "LP pause duration mismatch");
        require(WithdrawRequestNFT(payable(WITHDRAW_REQUEST_NFT)).pauseUntilDuration()== PAUSE_UNTIL_WITHDRAW_REQUEST_NFT,  "NFT pause duration mismatch");
        require(Liquifier(payable(LIQUIFIER)).pauseUntilDuration()                    == PAUSE_UNTIL_LIQUIFIER,             "Liquifier pause duration mismatch");

        require(roleRegistry.hasRole(roleRegistry.UPGRADE_TIMELOCK_ROLE(),    HOLDER_UPGRADE_TIMELOCK_ROLE),   "UPGRADE_TIMELOCK_ROLE not granted");
        require(roleRegistry.hasRole(roleRegistry.OPERATION_TIMELOCK_ROLE(),  HOLDER_OPERATION_TIMELOCK_ROLE), "OPERATION_TIMELOCK_ROLE not granted");
        require(roleRegistry.hasRole(roleRegistry.OPERATION_MULTISIG_ROLE(),  HOLDER_OPERATION_MULTISIG_ROLE), "OPERATION_MULTISIG_ROLE not granted");
        require(roleRegistry.hasRole(roleRegistry.SUPER_GUARDIAN_ROLE(),          HOLDER_SUPER_GUARDIAN_ROLE),          "SUPER_GUARDIAN_ROLE not granted");
        require(roleRegistry.hasRole(roleRegistry.GUARDIAN_ROLE(),                HOLDER_GUARDIAN_ROLE),                "GUARDIAN_ROLE not granted");
        require(roleRegistry.hasRole(roleRegistry.ORACLE_OPERATIONS_ROLE(),       HOLDER_ORACLE_OPERATIONS_ROLE),       "ORACLE_OPERATIONS_ROLE not granted");
        require(roleRegistry.hasRole(roleRegistry.HOUSEKEEPING_OPERATIONS_ROLE(), HOLDER_HOUSEKEEPING_OPERATIONS_ROLE), "HOUSEKEEPING_OPERATIONS_ROLE not granted");
        require(roleRegistry.hasRole(roleRegistry.EXECUTOR_OPERATIONS_ROLE(),     HOLDER_EXECUTOR_OPERATIONS_ROLE),     "EXECUTOR_OPERATIONS_ROLE not granted");
        require(roleRegistry.hasRole(roleRegistry.EIGENPOD_OPERATIONS_ROLE(),     HOLDER_EIGENPOD_OPERATIONS_ROLE),     "EIGENPOD_OPERATIONS_ROLE not granted");

        console2.log("[OK] rate-limiter buckets + pause durations + role grants verified");
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

    function _roleGrant(
        address[] memory targets,
        bytes[]   memory data,
        uint256          i,
        bytes32          role,
        address          account
    ) internal pure returns (uint256) {
        targets[i] = ROLE_REGISTRY;
        data[i]    = abi.encodeWithSelector(RoleRegistry.grantRole.selector, role, account);
        return i + 1;
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
