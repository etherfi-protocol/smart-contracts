// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";

import {AuctionManager} from "../../../src/AuctionManager.sol";
import {BucketRateLimiter} from "../../../src/BucketRateLimiter.sol";
import {EETH as EETHToken} from "../../../src/EETH.sol";
import {EtherFiAdmin} from "../../../src/EtherFiAdmin.sol";
import {EtherFiNodesManager} from "../../../src/EtherFiNodesManager.sol";
import {EtherFiOracle} from "../../../src/EtherFiOracle.sol";
import {EtherFiRedemptionManager} from "../../../src/EtherFiRedemptionManager.sol";
import {EtherFiRestaker} from "../../../src/EtherFiRestaker.sol";
import {LiquidityPool} from "../../../src/LiquidityPool.sol";
import {Liquifier} from "../../../src/Liquifier.sol";
import {MembershipManager} from "../../../src/MembershipManager.sol";
import {MembershipNFT} from "../../../src/MembershipNFT.sol";
import {NodeOperatorManager} from "../../../src/NodeOperatorManager.sol";
import {StakingManager} from "../../../src/StakingManager.sol";
import {WeETH as WeETHToken} from "../../../src/WeETH.sol";
import {WithdrawRequestNFT} from "../../../src/WithdrawRequestNFT.sol";

import {Blacklister} from "../../../src/helpers/Blacklister.sol";
import {UUPSProxy} from "../../../src/UUPSProxy.sol";

import {Deployed} from "../../deploys/Deployed.s.sol";
import {Utils, ICreate2Factory} from "../../utils/utils.sol";

/**
 * 26Q2 Security Upgrades — Deployment
 *
 * Deploys all new implementations for PR #385 plus the Blacklister proxy.
 * Configuration / upgrades are handled by transactions.s.sol.
 *
 * Usage:
 *   forge script script/upgrades/security-upgrades/deploy.s.sol:DeploySecurityUpgrades \
 *       --fork-url $MAINNET_RPC_URL --verify --etherscan-api-key $ETHERSCAN_API_KEY
 */
contract DeploySecurityUpgrades is Script, Deployed, Utils {
    ICreate2Factory public constant factory = ICreate2Factory(0x356d1B83970CeF2018F2c9337cDdb67dff5AEF99);

    // Commit hash used as salt — update before broadcast.
    bytes32 public constant commitHashSalt = bytes32(bytes20(hex"0000000000000000000000000000000000000000"));

    // ----- Immutable params (set per spec / ops review) -----
    // NOTE: These values are variable and would be further changed as per needed
    // Liquifier
    address public constant STETH_PRICE_FEED = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812; // Chainlink stETH/ETH
    address public constant LIDO = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant STETH_ETH_CURVE_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    uint256 public constant LIQUIFIER_MIN_DISCOUNT_BPS = 100;          // 1% floor
    uint256 public constant LIQUIFIER_STALE_PRICE_WINDOW = 7 days;
    uint256 public constant LIQUIFIER_MAX_PRICE_DEVIATION_BPS = 500;   // 5%

    // EtherFiRedemptionManager hardcoded ceilings (per spec §7.4.6 / §9)
    uint256 public constant RM_MAX_EXIT_FEE_SPLIT_TO_TREASURY_BPS = 10_000;
    uint256 public constant RM_MAX_EXIT_FEE_BPS = 500;                  // 5% hardcoded ceiling
    uint256 public constant RM_MAX_LOW_WATERMARK_BPS_OF_TVL = 2_000;    // 20% hardcoded ceiling

    // EtherFiAdmin immutable params
    int256  public constant ADMIN_MAX_REBASE_APR_BPS = 1_000;           // 10% absolute ceiling
    uint256 public constant ADMIN_MAX_VALIDATOR_TASK_BATCH_SIZE = 100; // 50 Currently
    uint256 public constant ADMIN_STALE_ORACLE_REPORT_BLOCK_WINDOW = 7200 * 7; // ~14 days @ 12s blocks
    uint256 public constant ADMIN_MAX_FINALIZED_WITHDRAWAL_AMOUNT_PER_DAY = 100_000 ether;
    uint256 public constant ADMIN_MAX_VALIDATORS_TO_APPROVE_PER_DAY = 1_000; 

    // LiquidityPool dust guard (spec — minimum amount per share)
    uint256 public constant LP_MIN_AMOUNT_FOR_SHARE = 1 ether;

    // WithdrawRequestNFT share-rate acceptance band
    uint256 public constant WNFT_MIN_ACCEPTABLE_SHARE_RATE = 1;
    uint256 public constant WNFT_MAX_ACCEPTABLE_SHARE_RATE = 4 ether;

    // WITHDRAW_REQUEST_NFT_BUYBACK_SAFE and TREASURY inherited from Deployed.

    // ----- Deployment outputs -----
    address public auctionManagerImpl;
    address public bucketRateLimiterImpl;
    address public eEthImpl;
    address public etherFiAdminImpl;
    address public etherFiNodesManagerImpl;
    address public etherFiOracleImpl;
    address public etherFiRedemptionManagerImpl;
    address public etherFiRestakerImpl;
    address public liquidityPoolImpl;
    address public liquifierImpl;
    address public membershipManagerImpl;
    address public membershipNFTImpl;
    address public nodeOperatorManagerImpl;
    address public stakingManagerImpl;
    address public weEthImpl;
    address public withdrawRequestNFTImpl;

    address public blacklisterImpl;
    address public blacklisterProxy;

    function run() public {
        console2.log("================================================");
        console2.log("====== 26Q2 Security Upgrades - Deploy ========");
        console2.log("================================================");
        console2.log("");

        vm.startBroadcast();

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

        // 2. Implementations
        {
            string memory name = "EETH";
            bytes memory args = abi.encode(LIQUIDITY_POOL, ROLE_REGISTRY, blacklisterProxy, ETHERFI_RATE_LIMITER);
            bytes memory bc = abi.encodePacked(type(EETHToken).creationCode, args);
            eEthImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }
        {
            string memory name = "WeETH";
            bytes memory args = abi.encode(EETH, LIQUIDITY_POOL, ROLE_REGISTRY, blacklisterProxy, ETHERFI_RATE_LIMITER);
            bytes memory bc = abi.encodePacked(type(WeETHToken).creationCode, args);
            weEthImpl = deploy(name, args, bc, commitHashSalt, true, factory);
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
            liquidityPoolImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }
        {
            string memory name = "WithdrawRequestNFT";
            bytes memory args = abi.encode(
                TREASURY, // NOTE: Making this address as Treasury and not WithdrawRequestNFT because we want to send funds there directly
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
        {
            string memory name = "Liquifier";
            Liquifier.ConstructorAddresses memory lqAddrs = Liquifier.ConstructorAddresses({
                liquidityPool: LIQUIDITY_POOL,
                lidoWithdrawalQueue: LIDO_WITHDRAWAL_QUEUE,
                lido: LIDO,
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
            liquifierImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }
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
                ADMIN_MAX_VALIDATORS_TO_APPROVE_PER_DAY
            );
            bytes memory bc = abi.encodePacked(type(EtherFiAdmin).creationCode, args);
            etherFiAdminImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }
        {
            string memory name = "EtherFiOracle";
            bytes memory args = abi.encode(ETHERFI_ADMIN, ROLE_REGISTRY);
            bytes memory bc = abi.encodePacked(type(EtherFiOracle).creationCode, args);
            etherFiOracleImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }
        {
            string memory name = "EtherFiRedemptionManager";
            bytes memory args = abi.encode(
                LIQUIDITY_POOL,
                EETH,
                WEETH,
                TREASURY,
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
            string memory name = "EtherFiNodesManager";
            bytes memory args = abi.encode(STAKING_MANAGER, ROLE_REGISTRY, ETHERFI_RATE_LIMITER);
            bytes memory bc = abi.encodePacked(type(EtherFiNodesManager).creationCode, args);
            etherFiNodesManagerImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }
        {
            string memory name = "StakingManager";
            bytes memory args = abi.encode(
                LIQUIDITY_POOL,
                ETHERFI_NODES_MANAGER,
                0x00000000219ab540356cBB839Cbe05303d7705Fa, // ETH2 deposit contract
                AUCTION_MANAGER,
                ETHERFI_NODE_BEACON,
                ROLE_REGISTRY
            );
            bytes memory bc = abi.encodePacked(type(StakingManager).creationCode, args);
            stakingManagerImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }
        {
            string memory name = "AuctionManager";
            bytes memory args = abi.encode(
                ROLE_REGISTRY,
                blacklisterProxy,
                NODE_OPERATOR_MANAGER,
                STAKING_MANAGER,
                MEMBERSHIP_MANAGER
            );
            bytes memory bc = abi.encodePacked(type(AuctionManager).creationCode, args);
            auctionManagerImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }
        {
            string memory name = "NodeOperatorManager";
            bytes memory args = abi.encode(ROLE_REGISTRY, AUCTION_MANAGER);
            bytes memory bc = abi.encodePacked(type(NodeOperatorManager).creationCode, args);
            nodeOperatorManagerImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }
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
        {
            string memory name = "BucketRateLimiter";
            bytes memory args = abi.encode(ROLE_REGISTRY);
            bytes memory bc = abi.encodePacked(type(BucketRateLimiter).creationCode, args);
            bucketRateLimiterImpl = deploy(name, args, bc, commitHashSalt, true, factory);
        }

        vm.stopBroadcast();

        _logSummary();
    }

    function _logSummary() internal view {
        console2.log("");
        console2.log("================================================");
        console2.log("============== DEPLOYMENT SUMMARY ==============");
        console2.log("================================================");
        console2.log("Blacklister impl:               ", blacklisterImpl);
        console2.log("Blacklister proxy:              ", blacklisterProxy);
        console2.log("EETH impl:                      ", eEthImpl);
        console2.log("WeETH impl:                     ", weEthImpl);
        console2.log("LiquidityPool impl:             ", liquidityPoolImpl);
        console2.log("WithdrawRequestNFT impl:        ", withdrawRequestNFTImpl);
        console2.log("Liquifier impl:                 ", liquifierImpl);
        console2.log("EtherFiAdmin impl:              ", etherFiAdminImpl);
        console2.log("EtherFiOracle impl:             ", etherFiOracleImpl);
        console2.log("EtherFiRedemptionManager impl:  ", etherFiRedemptionManagerImpl);
        console2.log("EtherFiRestaker impl:           ", etherFiRestakerImpl);
        console2.log("EtherFiNodesManager impl:       ", etherFiNodesManagerImpl);
        console2.log("StakingManager impl:            ", stakingManagerImpl);
        console2.log("AuctionManager impl:            ", auctionManagerImpl);
        console2.log("NodeOperatorManager impl:       ", nodeOperatorManagerImpl);
        console2.log("MembershipManager impl:         ", membershipManagerImpl);
        console2.log("MembershipNFT impl:             ", membershipNFTImpl);
        console2.log("BucketRateLimiter impl:         ", bucketRateLimiterImpl);
        console2.log("================================================");
    }
}
