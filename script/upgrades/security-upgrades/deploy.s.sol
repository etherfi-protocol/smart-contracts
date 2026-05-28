// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";

// Contract imports ordered by src/ group:
// core, deposits, governance, membership, oracle, restaking, rewards, staking, withdrawals.
// core
import {EETH as EETHToken} from "@etherfi/core/EETH.sol";
import {LiquidityPool} from "@etherfi/core/LiquidityPool.sol";
import {WeETH as WeETHToken} from "@etherfi/core/WeETH.sol";
// deposits
import {DepositAdapter} from "@etherfi/deposits/DepositAdapter.sol";
import {Liquifier} from "@etherfi/deposits/Liquifier.sol";
// governance
import {Blacklister} from "@etherfi/governance/Blacklister.sol";
import {RevokeAdmin} from "@etherfi/governance/RevokeAdmin.sol";
import {RoleRegistry} from "@etherfi/governance/RoleRegistry.sol";
import {EtherFiRateLimiter} from "@etherfi/governance/rate-limiting/EtherFiRateLimiter.sol";
// membership
import {MembershipManager} from "@etherfi/membership/MembershipManager.sol";
import {MembershipNFT} from "@etherfi/membership/MembershipNFT.sol";
// oracle
import {EtherFiAdmin} from "@etherfi/oracle/EtherFiAdmin.sol";
import {EtherFiOracle} from "@etherfi/oracle/EtherFiOracle.sol";
// restaking
import {EtherFiRestaker} from "@etherfi/restaking/EtherFiRestaker.sol";
import {RestakingRewardsRouter} from "@etherfi/restaking/RestakingRewardsRouter.sol";
// rewards
import {CumulativeMerkleRewardsDistributor} from "@etherfi/rewards/CumulativeMerkleRewardsDistributor.sol";
import {EtherFiRewardsRouter} from "@etherfi/rewards/EtherFiRewardsRouter.sol";
// staking
import {AuctionManager} from "@etherfi/staking/AuctionManager.sol";
import {EtherFiNode} from "@etherfi/staking/EtherFiNode.sol";
import {EtherFiNodesManager} from "@etherfi/staking/EtherFiNodesManager.sol";
import {NodeOperatorManager} from "@etherfi/staking/NodeOperatorManager.sol";
import {StakingManager} from "@etherfi/staking/StakingManager.sol";
// withdrawals
import {EtherFiRedemptionManager} from "@etherfi/withdrawals/EtherFiRedemptionManager.sol";
import {PriorityWithdrawalQueue} from "@etherfi/withdrawals/PriorityWithdrawalQueue.sol";
import {WeETHWithdrawAdapter} from "@etherfi/withdrawals/WeETHWithdrawAdapter.sol";
import {WithdrawRequestNFT} from "@etherfi/withdrawals/WithdrawRequestNFT.sol";

import {UUPSProxy} from "@etherfi/utils/UUPSProxy.sol";

import {Deployed} from "@scripts/deploys/Deployed.s.sol";
import {Utils, ICreate2Factory} from "@scripts/utils/utils.sol";

/**
 * 26Q2 Security Upgrades — Deployment
 *
 * Deploys all new implementations for PR #385 plus the Blacklister and RevokeAdmin proxies
 * and a new RoleRegistry impl (wired to the RevokeAdmin proxy via its `revokeAdmin` immutable).
 * Configuration / upgrades are handled by transactions.s.sol.
 *
 * Usage:
 *   forge script script/upgrades/security-upgrades/deploy.s.sol:DeploySecurityUpgrades \
 *       --fork-url $MAINNET_RPC_URL --verify --etherscan-api-key $ETHERSCAN_API_KEY
 */
contract DeploySecurityUpgrades is Script, Deployed, Utils {
    ICreate2Factory public constant factory = ICreate2Factory(0x356d1B83970CeF2018F2c9337cDdb67dff5AEF99);

    // ─────────────────────────────────────────────────────────────────────
    // GIT_COMMIT_SHA — TBD; set to the first 20 bytes of the release commit SHA
    // BEFORE broadcasting (see PR #420 review C3). The same value must be set in
    // transactions.s.sol and revert.s.sol so the CREATE2 salt and timelock salts agree.
    // _preflight() rejects bytes20(0).
    // ─────────────────────────────────────────────────────────────────────
    bytes20 public constant GIT_COMMIT_SHA = bytes20(hex"0000000000000000000000000000000000000000"); // TBD
    bytes32 public constant commitHashSalt = bytes32(GIT_COMMIT_SHA);

    // ----- Immutable params (set per spec / ops review) -----
    // NOTE: These values are variable and would be further changed as per needed
    // Ordered by src/ group: core, deposits, oracle, withdrawals.

    // core — LiquidityPool dust guard (spec — minimum amount per share)
    uint256 public constant LP_MIN_AMOUNT_FOR_SHARE = 1 ether;

    // deposits — Liquifier
    address public constant STETH_PRICE_FEED = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812; // Chainlink stETH/ETH
    address public constant STETH_ETH_CURVE_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    uint256 public constant LIQUIFIER_MIN_DISCOUNT_BPS = 100;          // 1% floor
    uint256 public constant LIQUIFIER_STALE_PRICE_WINDOW = 1 days;       // Chainlink stETH/ETH heartbeat is 24h; 1d is the tight bound (see H5)
    uint256 public constant LIQUIFIER_MAX_PRICE_DEVIATION_BPS = 500;   // 5%

    // oracle — EtherFiAdmin immutable params
    int256  public constant ADMIN_MAX_REBASE_APR_BPS = 1_000;           // 10% absolute ceiling
    uint256 public constant ADMIN_MAX_VALIDATOR_TASK_BATCH_SIZE = 100; // 50 Currently
    uint256 public constant ADMIN_STALE_ORACLE_REPORT_BLOCK_WINDOW = 7200 * 14; // 14 days @ 12s blocks (7200 blocks/day × 14)
    uint256 public constant ADMIN_MAX_FINALIZED_WITHDRAWAL_AMOUNT_PER_DAY = 100_000 ether;
    uint256 public constant ADMIN_MAX_VALIDATORS_TO_APPROVE_PER_DAY = 1_000;
    uint256 public constant ADMIN_MAX_REQUESTS_TO_FINALIZE_PER_REPORT = 2_000;

    // oracle — EtherFiOracle immutable params
    uint256 public constant ORACLE_MIN_QUORUM_SIZE = 3; // enforces min 3/5 quorum for consensus

    // withdrawals — EtherFiRedemptionManager hardcoded ceilings (per spec §7.4.6 / §9)
    // NOTE: the contract field is named `maxExitFeeSplitToTreasuryInBps`, but the actual
    // destination address (passed as `_treasury` in the constructor) is the buyback safe.
    // We standardize the BPS constant name on "TREASURY" to match the contract field;
    // the destination address is WITHDRAW_REQUEST_NFT_BUYBACK_SAFE in BOTH deploy and
    // transactions/verify (see C2 in PR #420 review).
    uint256 public constant RM_MAX_EXIT_FEE_SPLIT_TO_TREASURY_BPS = 10_000;
    uint256 public constant RM_MAX_EXIT_FEE_BPS = 500;                  // 5% hardcoded ceiling
    uint256 public constant RM_MAX_LOW_WATERMARK_BPS_OF_TVL = 2_000;    // 20% hardcoded ceiling

    // withdrawals — WithdrawRequestNFT share-rate acceptance band
    // Tightened band ~[0.9, 1.1] × the live LiquidityPool.amountPerShareCeil() snapshot
    // at deploy time (~1.05 ether as of 2026-05-28). See H4 in PR #420 review.
    // RE-VERIFY THESE BEFORE BROADCAST against the current `amountPerShareCeil()` —
    // any drift > a few % suggests rate has moved and the band should be re-centered.
    uint256 public constant WNFT_MIN_ACCEPTABLE_SHARE_RATE = 0.95 ether;
    uint256 public constant WNFT_MAX_ACCEPTABLE_SHARE_RATE = 1.15 ether;

    // withdrawals — PriorityWithdrawalQueue — must match the constructor arg used at proxy genesis;
    // the proxy's existing impl was deployed with 1 hour, so the new impl must too.
    uint32  public constant PWQ_MIN_DELAY = 1 hours;

    // ----- Deployment outputs (ordered by src/ group) -----
    // core
    address public eEthImpl;
    address public liquidityPoolImpl;
    address public weEthImpl;
    // deposits
    address public depositAdapterImpl;
    address public liquifierImpl;
    // governance
    address public blacklisterImpl;
    address public blacklisterProxy;
    address public revokeAdminImpl;
    address public revokeAdminProxy;
    address public roleRegistryImpl;
    address public etherFiRateLimiterImpl;
    // membership
    address public membershipManagerImpl;
    address public membershipNFTImpl;
    // oracle
    address public etherFiAdminImpl;
    address public etherFiOracleImpl;
    // restaking
    address public etherFiRestakerImpl;
    address public restakingRewardsRouterImpl;
    // rewards
    address public cumulativeMerkleRewardsDistributorImpl;
    address public etherFiRewardsRouterImpl;
    // staking
    address public auctionManagerImpl;
    address public etherFiNodeImpl;
    address public etherFiNodesManagerImpl;
    address public nodeOperatorManagerImpl;
    address public stakingManagerImpl;
    // withdrawals
    address public etherFiRedemptionManagerImpl;
    address public priorityWithdrawalQueueImpl;
    address public weETHWithdrawAdapterImpl;
    address public withdrawRequestNFTImpl;

    function run() public {
        console2.log("================================================");
        console2.log("====== 26Q2 Security Upgrades - Deploy ========");
        console2.log("================================================");
        console2.log("");

        _preflight();
        _printPleaseEyeball();

        vm.startBroadcast();

        // ─────────────────────────────────────────────────────────────────
        // Dependency-ordered prefix (NOT group-ordered): the Blacklister and
        // RevokeAdmin proxies plus the RoleRegistry impl must be deployed first
        // because every other impl takes the Blacklister proxy as a constructor
        // arg, and the RoleRegistry impl bakes in the RevokeAdmin proxy.
        // ─────────────────────────────────────────────────────────────────

        // 1. Blacklister proxy first — every other impl takes it as a constructor arg.
        {
            string memory name = "Blacklister";
            bytes memory args = abi.encode(ROLE_REGISTRY);
            bytes memory bc = abi.encodePacked(type(Blacklister).creationCode, args);
            blacklisterImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }
        {
            string memory name = "UUPSProxy";
            bytes memory initData = abi.encodeWithSelector(Blacklister.initialize.selector);
            bytes memory args = abi.encode(blacklisterImpl, initData);
            bytes memory bc = abi.encodePacked(type(UUPSProxy).creationCode, args);
            blacklisterProxy = deploy(name, args, bc, commitHashSalt, true, factory);
        }
        console2.log("Blacklister proxy:", blacklisterProxy);

        // 1b. RevokeAdmin proxy — RoleRegistry.revokeAdmin (immutable) is wired to this
        //     address when the registry impl is (re)deployed, enabling revokeFast().
        {
            string memory name = "RevokeAdmin";
            bytes memory args = abi.encode(ROLE_REGISTRY);
            bytes memory bc = abi.encodePacked(type(RevokeAdmin).creationCode, args);
            revokeAdminImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }
        {
            string memory name = "UUPSProxy";
            bytes memory initData = abi.encodeWithSelector(RevokeAdmin.initialize.selector);
            bytes memory args = abi.encode(revokeAdminImpl, initData);
            bytes memory bc = abi.encodePacked(type(UUPSProxy).creationCode, args);
            revokeAdminProxy = deploy(name, args, bc, commitHashSalt, true, factory);
        }
        console2.log("RevokeAdmin proxy:", revokeAdminProxy);

        // 1c. New RoleRegistry impl — bakes the RevokeAdmin proxy into the `revokeAdmin`
        //     immutable (set in the constructor). transactions.s.sol upgrades the
        //     ROLE_REGISTRY proxy to this impl BEFORE every other proxy.
        {
            string memory name = "RoleRegistry";
            bytes memory args = abi.encode(revokeAdminProxy);
            bytes memory bc = abi.encodePacked(type(RoleRegistry).creationCode, args);
            roleRegistryImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }
        console2.log("RoleRegistry impl:", roleRegistryImpl);

        // ─────────────────────────────────────────────────────────────────
        // Remaining implementations, ordered by src/ group.
        // ─────────────────────────────────────────────────────────────────

        // core
        {
            string memory name = "EETH";
            bytes memory args = abi.encode(LIQUIDITY_POOL, ROLE_REGISTRY, blacklisterProxy, ETHERFI_RATE_LIMITER);
            bytes memory bc = abi.encodePacked(type(EETHToken).creationCode, args);
            eEthImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }
        {
            string memory name = "LiquidityPool";
            LiquidityPool.ConstructorAddresses memory lpAddrs = LiquidityPool.ConstructorAddresses({
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
            });
            bytes memory args = abi.encode(lpAddrs, LP_MIN_AMOUNT_FOR_SHARE);
            bytes memory bc = abi.encodePacked(type(LiquidityPool).creationCode, args);
            // logging=false because Utils.formatStaticParam can't pretty-print the
            // ConstructorAddresses struct (reverts "Unsupported static type"). Deployment
            // still succeeds; only the JSON log is skipped for this contract.
            liquidityPoolImpl = deploy(name, args, bc, commitHashSalt, false, factory);
        }
        {
            string memory name = "WeETH";
            bytes memory args = abi.encode(EETH, LIQUIDITY_POOL, ROLE_REGISTRY, blacklisterProxy, ETHERFI_RATE_LIMITER);
            bytes memory bc = abi.encodePacked(type(WeETHToken).creationCode, args);
            weEthImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }

        // deposits
        {
            string memory name = "DepositAdapter";
            bytes memory args = abi.encode(
                LIQUIDITY_POOL,
                LIQUIFIER,
                WEETH,
                EETH,
                WETH,
                STETH,
                WSTETH,
                ROLE_REGISTRY,
                blacklisterProxy
            );
            bytes memory bc = abi.encodePacked(type(DepositAdapter).creationCode, args);
            depositAdapterImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }
        {
            string memory name = "Liquifier";
            Liquifier.ConstructorAddresses memory lqAddrs = Liquifier.ConstructorAddresses({
                liquidityPool: LIQUIDITY_POOL,
                lidoWithdrawalQueue: LIDO_WITHDRAWAL_QUEUE,
                lido: STETH,
                stEth_Eth_Pool: STETH_ETH_CURVE_POOL,
                roleRegistry: ROLE_REGISTRY,
                stEthPriceFeed: STETH_PRICE_FEED,
                blacklister: blacklisterProxy,
                etherfiRestaker: ETHERFI_RESTAKER,
                l1SyncPool: ETHERFI_L1_SYNC_POOL_ETH
            });
            bytes memory args = abi.encode(
                lqAddrs,
                LIQUIFIER_MIN_DISCOUNT_BPS,
                LIQUIFIER_STALE_PRICE_WINDOW,
                LIQUIFIER_MAX_PRICE_DEVIATION_BPS
            );
            bytes memory bc = abi.encodePacked(type(Liquifier).creationCode, args);
            liquifierImpl = deploy(name, args, bc, commitHashSalt, false, factory); // logging=false: struct arg
        }

        // governance (Blacklister / RevokeAdmin / RoleRegistry deployed in the prefix above)
        {
            string memory name = "EtherFiRateLimiter";
            bytes memory args = abi.encode(ROLE_REGISTRY, EETH, WEETH);
            bytes memory bc = abi.encodePacked(type(EtherFiRateLimiter).creationCode, args);
            etherFiRateLimiterImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }

        // membership
        {
            string memory name = "MembershipManager";
            bytes memory args = abi.encode(
                EETH,
                LIQUIDITY_POOL,
                MEMBERSHIP_NFT,
                ETHERFI_ADMIN,
                ROLE_REGISTRY,
                blacklisterProxy
            );
            bytes memory bc = abi.encodePacked(type(MembershipManager).creationCode, args);
            membershipManagerImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }
        {
            string memory name = "MembershipNFT";
            bytes memory args = abi.encode(
                LIQUIDITY_POOL,
                MEMBERSHIP_MANAGER,
                ROLE_REGISTRY,
                blacklisterProxy
            );
            bytes memory bc = abi.encodePacked(type(MembershipNFT).creationCode, args);
            membershipNFTImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }

        // oracle
        {
            string memory name = "EtherFiAdmin";
            EtherFiAdmin.ConstructorAddresses memory adAddrs = EtherFiAdmin.ConstructorAddresses({
                etherFiOracle: ETHERFI_ORACLE,
                stakingManager: STAKING_MANAGER,
                auctionManager: AUCTION_MANAGER,
                etherFiNodesManager: ETHERFI_NODES_MANAGER,
                liquidityPool: LIQUIDITY_POOL,
                membershipManager: MEMBERSHIP_MANAGER,
                withdrawRequestNft: WITHDRAW_REQUEST_NFT,
                roleRegistry: ROLE_REGISTRY,
                priorityWithdrawalQueue: PRIORITY_WITHDRAWAL_QUEUE
            });
            bytes memory args = abi.encode(
                adAddrs,
                ADMIN_MAX_REBASE_APR_BPS,
                ADMIN_MAX_VALIDATOR_TASK_BATCH_SIZE,
                ADMIN_STALE_ORACLE_REPORT_BLOCK_WINDOW,
                ADMIN_MAX_FINALIZED_WITHDRAWAL_AMOUNT_PER_DAY,
                ADMIN_MAX_VALIDATORS_TO_APPROVE_PER_DAY,
                ADMIN_MAX_REQUESTS_TO_FINALIZE_PER_REPORT
            );
            bytes memory bc = abi.encodePacked(type(EtherFiAdmin).creationCode, args);
            etherFiAdminImpl = deploy(name, args, bc, commitHashSalt, false, factory); // logging=false: struct arg
        }
        {
            string memory name = "EtherFiOracle";
            bytes memory args = abi.encode(ORACLE_MIN_QUORUM_SIZE, ETHERFI_ADMIN, ROLE_REGISTRY);
            bytes memory bc = abi.encodePacked(type(EtherFiOracle).creationCode, args);
            etherFiOracleImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }

        // restaking
        {
            string memory name = "EtherFiRestaker";
            bytes memory args = abi.encode(
                LIQUIDITY_POOL,
                LIQUIFIER,
                EIGENLAYER_REWARDS_COORDINATOR,
                ETHERFI_REDEMPTION_MANAGER,
                ROLE_REGISTRY,
                ETHERFI_RATE_LIMITER,
                EIGENLAYER_STRATEGY_MANAGER,
                EIGENLAYER_DELEGATION_MANAGER
            );
            bytes memory bc = abi.encodePacked(type(EtherFiRestaker).creationCode, args);
            etherFiRestakerImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }
        {
            string memory name = "RestakingRewardsRouter";
            bytes memory args = abi.encode(ROLE_REGISTRY, EIGEN, LIQUIDITY_POOL);
            bytes memory bc = abi.encodePacked(type(RestakingRewardsRouter).creationCode, args);
            restakingRewardsRouterImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }

        // rewards
        {
            string memory name = "CumulativeMerkleRewardsDistributor";
            bytes memory args = abi.encode(ROLE_REGISTRY);
            bytes memory bc = abi.encodePacked(type(CumulativeMerkleRewardsDistributor).creationCode, args);
            cumulativeMerkleRewardsDistributorImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }
        {
            string memory name = "EtherFiRewardsRouter";
            bytes memory args = abi.encode(LIQUIDITY_POOL, TREASURY, ROLE_REGISTRY);
            bytes memory bc = abi.encodePacked(type(EtherFiRewardsRouter).creationCode, args);
            etherFiRewardsRouterImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }

        // staking
        {
            string memory name = "AuctionManager";
            bytes memory args = abi.encode(
                ROLE_REGISTRY,
                blacklisterProxy,
                NODE_OPERATOR_MANAGER,
                STAKING_MANAGER,
                TREASURY
            );
            bytes memory bc = abi.encodePacked(type(AuctionManager).creationCode, args);
            auctionManagerImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }
        {
            string memory name = "EtherFiNode";
            bytes memory args = abi.encode(LIQUIDITY_POOL, ETHERFI_NODES_MANAGER, EIGENLAYER_POD_MANAGER, EIGENLAYER_DELEGATION_MANAGER);
            bytes memory bc = abi.encodePacked(type(EtherFiNode).creationCode, args);
            etherFiNodeImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }
        {
            string memory name = "EtherFiNodesManager";
            bytes memory args = abi.encode(STAKING_MANAGER, ROLE_REGISTRY, ETHERFI_RATE_LIMITER);
            bytes memory bc = abi.encodePacked(type(EtherFiNodesManager).creationCode, args);
            etherFiNodesManagerImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }
        {
            string memory name = "NodeOperatorManager";
            bytes memory args = abi.encode(ROLE_REGISTRY, AUCTION_MANAGER);
            bytes memory bc = abi.encodePacked(type(NodeOperatorManager).creationCode, args);
            nodeOperatorManagerImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }
        {
            string memory name = "StakingManager";
            bytes memory args = abi.encode(
                LIQUIDITY_POOL,
                ETHERFI_NODES_MANAGER,
                ETH2_DEPOSIT_CONTRACT,
                AUCTION_MANAGER,
                ETHERFI_NODE_BEACON,
                ROLE_REGISTRY
            );
            bytes memory bc = abi.encodePacked(type(StakingManager).creationCode, args);
            stakingManagerImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }

        // withdrawals
        {
            string memory name = "EtherFiRedemptionManager";
            bytes memory args = abi.encode(
                LIQUIDITY_POOL,
                EETH,
                WEETH,
                WITHDRAW_REQUEST_NFT_BUYBACK_SAFE,
                ROLE_REGISTRY,
                ETHERFI_RESTAKER,
                PRIORITY_WITHDRAWAL_QUEUE,
                blacklisterProxy,
                RM_MAX_EXIT_FEE_SPLIT_TO_TREASURY_BPS,
                RM_MAX_EXIT_FEE_BPS,
                RM_MAX_LOW_WATERMARK_BPS_OF_TVL
            );
            bytes memory bc = abi.encodePacked(type(EtherFiRedemptionManager).creationCode, args);
            etherFiRedemptionManagerImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }
        {
            string memory name = "PriorityWithdrawalQueue";
            bytes memory args = abi.encode(
                LIQUIDITY_POOL,
                EETH,
                WEETH,
                ROLE_REGISTRY,
                WITHDRAW_REQUEST_NFT_BUYBACK_SAFE,
                PWQ_MIN_DELAY
            );
            bytes memory bc = abi.encodePacked(type(PriorityWithdrawalQueue).creationCode, args);
            priorityWithdrawalQueueImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }
        {
            string memory name = "WeETHWithdrawAdapter";
            bytes memory args = abi.encode(
                WEETH,
                EETH,
                LIQUIDITY_POOL,
                WITHDRAW_REQUEST_NFT,
                ROLE_REGISTRY,
                blacklisterProxy
            );
            bytes memory bc = abi.encodePacked(type(WeETHWithdrawAdapter).creationCode, args);
            weETHWithdrawAdapterImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }
        {
            string memory name = "WithdrawRequestNFT";
            bytes memory args = abi.encode(
                WITHDRAW_REQUEST_NFT_BUYBACK_SAFE,
                EETH,
                LIQUIDITY_POOL,
                MEMBERSHIP_MANAGER,
                ROLE_REGISTRY,
                blacklisterProxy,
                ETHERFI_ADMIN,
                WNFT_MIN_ACCEPTABLE_SHARE_RATE,
                WNFT_MAX_ACCEPTABLE_SHARE_RATE
            );
            bytes memory bc = abi.encodePacked(type(WithdrawRequestNFT).creationCode, args);
            withdrawRequestNFTImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }

        vm.stopBroadcast();

        _logSummary();
    }

    /// @dev Fail loudly the moment a deploy-time TBD constant is still unset.
    function _preflight() internal pure {
        require(GIT_COMMIT_SHA != bytes20(0), "preflight: GIT_COMMIT_SHA unset - set to first 20 bytes of release commit");
        require(WNFT_MIN_ACCEPTABLE_SHARE_RATE > 0,                                    "preflight: WNFT_MIN_ACCEPTABLE_SHARE_RATE unset");
        require(WNFT_MAX_ACCEPTABLE_SHARE_RATE > WNFT_MIN_ACCEPTABLE_SHARE_RATE,       "preflight: WNFT_MAX_ACCEPTABLE_SHARE_RATE <= MIN");
    }

    /// @dev Print every TBD/operational constant so the broadcaster can eyeball them before
    ///      `vm.startBroadcast` runs. See H3 in PR #420 review.
    function _printPleaseEyeball() internal pure {
        console2.log("================================================");
        console2.log("===== PLEASE EYEBALL - DEPLOY CONSTANTS ========");
        console2.log("================================================");
        console2.log("GIT_COMMIT_SHA (first 20B of commit, hex):", vm.toString(GIT_COMMIT_SHA));
        console2.log("commitHashSalt:                           ", vm.toString(commitHashSalt));
        console2.log("");
        console2.log("LP_MIN_AMOUNT_FOR_SHARE (LP dust):        ", LP_MIN_AMOUNT_FOR_SHARE);
        console2.log("");
        console2.log("LIQUIFIER_MIN_DISCOUNT_BPS:               ", LIQUIFIER_MIN_DISCOUNT_BPS);
        console2.log("LIQUIFIER_STALE_PRICE_WINDOW (sec):       ", LIQUIFIER_STALE_PRICE_WINDOW);
        console2.log("LIQUIFIER_MAX_PRICE_DEVIATION_BPS:        ", LIQUIFIER_MAX_PRICE_DEVIATION_BPS);
        console2.log("");
        console2.log("ADMIN_MAX_REBASE_APR_BPS (ceiling):       ", uint256(int256(ADMIN_MAX_REBASE_APR_BPS)));
        console2.log("ADMIN_MAX_VALIDATOR_TASK_BATCH_SIZE:      ", ADMIN_MAX_VALIDATOR_TASK_BATCH_SIZE);
        console2.log("ADMIN_STALE_ORACLE_REPORT_BLOCK_WINDOW:   ", ADMIN_STALE_ORACLE_REPORT_BLOCK_WINDOW);
        console2.log("ADMIN_MAX_FINALIZED_WITHDRAWAL_PER_DAY:   ", ADMIN_MAX_FINALIZED_WITHDRAWAL_AMOUNT_PER_DAY);
        console2.log("ADMIN_MAX_VALIDATORS_TO_APPROVE_PER_DAY:  ", ADMIN_MAX_VALIDATORS_TO_APPROVE_PER_DAY);
        console2.log("ADMIN_MAX_REQUESTS_TO_FINALIZE_PER_REPORT:", ADMIN_MAX_REQUESTS_TO_FINALIZE_PER_REPORT);
        console2.log("");
        console2.log("ORACLE_MIN_QUORUM_SIZE:                   ", ORACLE_MIN_QUORUM_SIZE);
        console2.log("");
        console2.log("RM_MAX_EXIT_FEE_SPLIT_TO_TREASURY_BPS:    ", RM_MAX_EXIT_FEE_SPLIT_TO_TREASURY_BPS);
        console2.log("RM_MAX_EXIT_FEE_BPS:                      ", RM_MAX_EXIT_FEE_BPS);
        console2.log("RM_MAX_LOW_WATERMARK_BPS_OF_TVL:          ", RM_MAX_LOW_WATERMARK_BPS_OF_TVL);
        console2.log("");
        console2.log("WNFT_MIN_ACCEPTABLE_SHARE_RATE:           ", WNFT_MIN_ACCEPTABLE_SHARE_RATE);
        console2.log("WNFT_MAX_ACCEPTABLE_SHARE_RATE:           ", WNFT_MAX_ACCEPTABLE_SHARE_RATE);
        console2.log("");
        console2.log("PWQ_MIN_DELAY (sec):                      ", PWQ_MIN_DELAY);
        console2.log("================================================");
        console2.log("");
    }

    function _logSummary() internal view {
        console2.log("");
        console2.log("================================================");
        console2.log("============== DEPLOYMENT SUMMARY ==============");
        console2.log("================================================");
        // core
        console2.log("EETH impl:                      ", eEthImpl);
        console2.log("LiquidityPool impl:             ", liquidityPoolImpl);
        console2.log("WeETH impl:                     ", weEthImpl);
        // deposits
        console2.log("DepositAdapter impl:            ", depositAdapterImpl);
        console2.log("Liquifier impl:                 ", liquifierImpl);
        // governance
        console2.log("Blacklister impl:               ", blacklisterImpl);
        console2.log("Blacklister proxy:              ", blacklisterProxy);
        console2.log("RevokeAdmin impl:               ", revokeAdminImpl);
        console2.log("RevokeAdmin proxy:              ", revokeAdminProxy);
        console2.log("RoleRegistry impl:              ", roleRegistryImpl);
        console2.log("EtherFiRateLimiter impl:        ", etherFiRateLimiterImpl);
        // membership
        console2.log("MembershipManager impl:         ", membershipManagerImpl);
        console2.log("MembershipNFT impl:             ", membershipNFTImpl);
        // oracle
        console2.log("EtherFiAdmin impl:              ", etherFiAdminImpl);
        console2.log("EtherFiOracle impl:             ", etherFiOracleImpl);
        // restaking
        console2.log("EtherFiRestaker impl:           ", etherFiRestakerImpl);
        console2.log("RestakingRewardsRouter impl:    ", restakingRewardsRouterImpl);
        // rewards
        console2.log("CumulativeMerkleRewardsDist impl:", cumulativeMerkleRewardsDistributorImpl);
        console2.log("EtherFiRewardsRouter impl:      ", etherFiRewardsRouterImpl);
        // staking
        console2.log("AuctionManager impl:            ", auctionManagerImpl);
        console2.log("EtherFiNode impl:               ", etherFiNodeImpl);
        console2.log("EtherFiNodesManager impl:       ", etherFiNodesManagerImpl);
        console2.log("NodeOperatorManager impl:       ", nodeOperatorManagerImpl);
        console2.log("StakingManager impl:            ", stakingManagerImpl);
        // withdrawals
        console2.log("EtherFiRedemptionManager impl:  ", etherFiRedemptionManagerImpl);
        console2.log("PriorityWithdrawalQueue impl:   ", priorityWithdrawalQueueImpl);
        console2.log("WeETHWithdrawAdapter impl:      ", weETHWithdrawAdapterImpl);
        console2.log("WithdrawRequestNFT impl:        ", withdrawRequestNFTImpl);
        console2.log("================================================");
    }
}
