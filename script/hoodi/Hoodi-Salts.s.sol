// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title Hoodi-Salts
 * @notice Salt values for Create2 deployments on Hoodi testnet
 * @dev These salts ensure deterministic addresses across deployments
 */
contract HoodiSalts {
    // Core Protocol Contracts
    bytes32 public constant TREASURY_SALT = keccak256("Treasury");
    bytes32 public constant NODE_OPERATOR_MANAGER_SALT = keccak256("NodeOperatorManager");
    bytes32 public constant AUCTION_MANAGER_SALT = keccak256("AuctionManager");
    bytes32 public constant STAKING_MANAGER_SALT = keccak256("StakingManager");
    bytes32 public constant ETHERFI_NODE_SALT = keccak256("EtherFiNode");
    bytes32 public constant BNFT_SALT = keccak256("BNFT");
    bytes32 public constant TNFT_SALT = keccak256("TNFT");
    bytes32 public constant PROTOCOL_REVENUE_MANAGER_SALT = keccak256("ProtocolRevenueManager");
    bytes32 public constant ETHERFI_NODES_MANAGER_SALT = keccak256("EtherFiNodesManager");
    bytes32 public constant REGULATIONS_MANAGER_SALT = keccak256("RegulationsManager");
    bytes32 public constant MEMBERSHIP_MANAGER_SALT = keccak256("MembershipManager");
    bytes32 public constant WITHDRAW_REQUEST_NFT_SALT = keccak256("WithdrawRequestNFT");
    bytes32 public constant MEMBERSHIP_NFT_SALT = keccak256("MembershipNFT");
    bytes32 public constant LIQUIDITY_POOL_SALT = keccak256("LiquidityPool");
    bytes32 public constant EETH_SALT = keccak256("EETH");
    bytes32 public constant WEETH_SALT = keccak256("WeETH");
    bytes32 public constant ETHERFI_ORACLE_SALT = keccak256("EtherFiOracle");
    bytes32 public constant ETHERFI_ADMIN_SALT = keccak256("EtherFiAdmin");
    bytes32 public constant ROLE_REGISTRY_SALT = keccak256("RoleRegistry");
    bytes32 public constant ETHERFI_OPERATION_PARAMETERS_SALT = keccak256("EtherFiOperationParameters");
    bytes32 public constant BUCKET_RATE_LIMITER_SALT = keccak256("BucketRateLimiter");
    bytes32 public constant TVL_ORACLE_SALT = keccak256("TVLOracle");
    bytes32 public constant ETHERFI_TIMELOCK_SALT = keccak256("EtherFiTimelock");
    bytes32 public constant LIQUIFIER_SALT = keccak256("Liquifier");
    bytes32 public constant ETHERFI_RESTAKER_SALT = keccak256("EtherFiRestaker");
    bytes32 public constant ETHERFI_REWARDS_ROUTER_SALT = keccak256("EtherFiRewardsRouter");
    bytes32 public constant ADDRESS_PROVIDER_SALT = keccak256("AddressProvider");
    bytes32 public constant ETHERFI_VIEWER_SALT = keccak256("EtherFiViewer");
    bytes32 public constant ETHERFI_REDEMPTION_MANAGER_SALT = keccak256("EtherFiRedemptionManager");
}

