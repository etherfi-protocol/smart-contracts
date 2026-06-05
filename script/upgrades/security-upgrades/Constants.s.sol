// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {EtherFiTimelock} from "@etherfi/governance/EtherFiTimelock.sol";
import {RoleRegistry} from "@etherfi/governance/RoleRegistry.sol";

import {Deployed} from "@scripts/deploys/Deployed.s.sol";

/**
 * 26Q2 Security Upgrades — Shared Constants
 *
 * Single source of truth for every configuration constant consumed by the
 * three security-upgrade scripts (deploy.s.sol, transactions.s.sol,
 * revert.s.sol). All three inherit this contract, so a value set here is seen
 * identically everywhere — no more "MUST MATCH deploy.s.sol" hand-syncing.
 *
 * Fill in the TBD values (anything left at 0 / address(0) / bytes20(0)) BEFORE
 * broadcasting; each script's own `_preflight()` re-asserts the subset it needs.
 *
 * NOT declared here (intentionally script-local, because they are not shared
 * configuration but per-run deployment bookkeeping):
 *   • deploy.s.sol  — the CREATE2 `factory` handle and the runtime deployment
 *                     OUTPUT variables (eEthImpl, blacklisterProxy, … are
 *                     mutable state there, assigned during the broadcast).
 *   • transactions.s.sol — the deployed-implementation INPUT addresses
 *                     (populated by hand from deploy.s.sol's output).
 *   • revert.s.sol  — the PRE_* pre-upgrade implementation addresses (read
 *                     from the live ERC1967 slots before a rollback).
 */
abstract contract SecurityUpgradesConstants is Deployed {
    // ─────────────────────────────────────────────────────────────────────
    // GIT_COMMIT_SHA — shared by all three scripts. Set to the first 20 bytes
    // of the release commit SHA BEFORE broadcasting (see PR #420 review C3).
    // Derives the CREATE2 salt (deploy) and the timelock batch salts
    // (transactions / revert), so every script must agree on it. Each script's
    // _preflight() rejects bytes20(0).
    // ─────────────────────────────────────────────────────────────────────
    bytes20 internal constant GIT_COMMIT_SHA = bytes20(hex"87bc3d6783bf9b0278e3ffb98b6eba7f8f0e1769");
    bytes32 internal constant commitHashSalt = bytes32(GIT_COMMIT_SHA);

    // ─────────────────────────────────────────────────────────────────────
    // IMMUTABLE CONSTRUCTOR PARAMS (deploy.s.sol bakes these into the impls;
    // transactions.s.sol re-states them to rebuild + bytecode-verify each impl).
    // Ordered by src/ group: core, deposits, oracle, withdrawals.
    // NOTE: These values are variable and would be further changed as needed.
    // ─────────────────────────────────────────────────────────────────────

    // core — LiquidityPool dust guard (spec — minimum amount per share)
    uint256 internal constant LP_MIN_AMOUNT_FOR_SHARE = 1 ether;

    // deposits — Liquifier
    address internal constant STETH_PRICE_FEED = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812; // Chainlink stETH/ETH
    address internal constant STETH_ETH_CURVE_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    uint256 internal constant LIQUIFIER_MIN_DISCOUNT_BPS = 0;
    uint256 internal constant LIQUIFIER_STALE_PRICE_WINDOW = 2 days; // 2 days (heartbeat to updated stETH price feed is 1 days)
    uint256 internal constant LIQUIFIER_MAX_PRICE_DEVIATION_BPS = 200;   // 2%

    // oracle — EtherFiAdmin immutable params
    int256  internal constant ADMIN_MAX_REBASE_APR_BPS = 1_000;           // 10% absolute ceiling
    uint256 internal constant ADMIN_MAX_VALIDATOR_TASK_BATCH_SIZE = 100; // 50 Currently
    uint256 internal constant ADMIN_STALE_ORACLE_REPORT_BLOCK_WINDOW = 7200 * 14; // ~14 days @ 12s blocks
    uint256 internal constant ADMIN_MAX_FINALIZED_WITHDRAWAL_AMOUNT_PER_DAY = 100_000 ether;
    uint256 internal constant ADMIN_MAX_VALIDATORS_TO_APPROVE_PER_DAY = 100;
    // rationale: 5000 requests x 2000 sload cost ~ 10M gas which we consider is max acceptable limit for grefining, 
    // anyone making that many requests will be flagged for grefining and their requests can be invalidated
    uint256 internal constant ADMIN_MAX_REQUESTS_TO_FINALIZE_PER_REPORT = 5_000;
    // oracle — EtherFiOracle immutable params
    /**
      * @dev for current setup, we have 2 of 3 set on oracle out of which 2 are internal and 1 is external.
      * We need to remove one internal and one external and replace those with 2 external nodes with 3 of 3
      * setup. We will do the following executions:
      * 1. Add new external member 1 with quorum size 3 (setup: 3 of 4)
      * 2. Add new external member 2 with quorum size 3 (setup: 3 of 5)
      * 3. Remove existing internal member 1 with quorum size 3 (setup: 3 of 4)
      * 4. Remove existing external member 1 with quorum size 3 (setup: 3 of 3)
      * This way, we replace the keys to the 3 operators: ether.fi, nonce and distrust
      * After this is successful we add two extra parties (member 3 and member 4 with quorum 3) to reach desired 3 of 5 setup.
     */
    uint32  internal constant ORACLE_MIN_QUORUM_SIZE = 3; // enforces min 3/5 quorum for consensus

    // withdrawals — EtherFiRedemptionManager hardcoded ceilings (per spec §7.4.6 / §9)
    // NOTE: the contract field is named `maxExitFeeSplitToTreasuryInBps`, but the actual
    // destination address (passed as `_treasury` in the constructor) is the buyback safe.
    // We standardize the BPS constant name on "TREASURY" to match the contract field;
    // the destination address is WITHDRAW_REQUEST_NFT_BUYBACK_SAFE in BOTH deploy and
    // transactions/verify (see C2 in PR #420 review).
    uint256 internal constant RM_MAX_EXIT_FEE_SPLIT_TO_TREASURY_BPS = 10_000;
    uint256 internal constant RM_MAX_EXIT_FEE_BPS = 500;                  // 5% hardcoded ceiling
    uint256 internal constant RM_MAX_LOW_WATERMARK_BPS_OF_TVL = 500;    // 5% hardcoded ceiling

    // withdrawals — WithdrawRequestNFT share-rate acceptance band
    // Tightened band ~[0.9, 1.1] × the live LiquidityPool.amountPerShareCeil() snapshot
    // at deploy time (~1.05 ether as of 2026-05-28). See H4 in PR #420 review.
    // RE-VERIFY THESE BEFORE BROADCAST against the current `amountPerShareCeil()` —
    // any drift > a few % suggests rate has moved and the band should be re-centered.
    uint256 internal constant WNFT_MIN_ACCEPTABLE_SHARE_RATE = 1.05 ether;
    uint256 internal constant WNFT_MAX_ACCEPTABLE_SHARE_RATE = 1.25 ether;

    // withdrawals — PriorityWithdrawalQueue — must match the constructor arg used at proxy genesis;
    // the proxy's existing impl was deployed with 1 hour, so the new impl must too.
    uint32  internal constant PWQ_MIN_DELAY = 1 hours;

    // ─────────────────────────────────────────────────────────────────────
    // OPERATIONAL SETPOINTS — applied post-upgrade by transactions.s.sol.
    // ─────────────────────────────────────────────────────────────────────

    // core — LiquidityPool.requestWithdraw bounds (queued NFT-mint path). Default storage
    // is 0/0, which bricks the path; seeded via the OPERATION_MULTISIG Safe tx (Batch 3)
    // after the upgrade batch grants it OPERATION_MULTISIG_ROLE. Dummy values for now.
    uint256 internal constant LP_MIN_WITHDRAW_AMOUNT = 1_000_000 gwei; // 0.001 ether
    uint256 internal constant LP_MAX_WITHDRAW_AMOUNT = 1_000 ether;

    // oracle — EtherFiAdmin daily finalized-withdrawal cap (operational setpoint).
    // Set post-upgrade via updateMaxFinalizedWithdrawalAmountPerDay, which is
    // onlyAdmin = OPERATION_TIMELOCK_ROLE — so it rides the operating-timelock batch
    // (Batch 2), NOT the upgrade batch with the LP/WRN initializers (those are
    // onlyUpgradeTimelock; the upgrade timelock can't satisfy onlyAdmin).
    // The storage var maxFinalizedWithdrawalAmountPerDay defaults to 0, which makes
    // _validateReport reject EVERY finalized withdrawal, so it must be seeded.
    // Must satisfy 0 < value <= ADMIN_MAX_FINALIZED_WITHDRAWAL_AMOUNT_PER_DAY
    // (the immutable acceptable ceiling baked into the EtherFiAdmin impl).
    uint256 internal constant ADMIN_DAILY_FINALIZED_WITHDRAWAL_LIMIT = 20_000 ether;

    // ─────────────────────────────────────────────────────────────────────
    // ROLE HOLDERS - 3 fixed + 6 user-set.
    // ─────────────────────────────────────────────────────────────────────
    address internal constant HOLDER_UPGRADE_TIMELOCK_ROLE   = 0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761; // UPGRADE_TIMELOCK
    address internal constant HOLDER_OPERATION_TIMELOCK_ROLE = 0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a; // OPERATING_TIMELOCK
    address internal constant HOLDER_OPERATION_MULTISIG_ROLE = 0x2aCA71020De61bb532008049e1Bd41E451aE8AdC; // ETHERFI_OPERATING_ADMIN

    address internal constant HOLDER_SUPER_GUARDIAN_ROLE          = address(0);
    address internal constant HOLDER_GUARDIAN_ROLE                = address(0);
    address internal constant HOLDER_ORACLE_OPERATIONS_ROLE       = address(0);
    address internal constant HOLDER_HOUSEKEEPING_OPERATIONS_ROLE = address(0);
    address internal constant HOLDER_EXECUTOR_OPERATIONS_ROLE     = address(0);
    address internal constant HOLDER_EIGENPOD_OPERATIONS_ROLE     = address(0);

    // ─────────────────────────────────────────────────────────────────────
    // ROLE IDs — hardcoded keccak256 of the role name. Mirror the constants in
    // src/governance/RoleRegistry.sol EXACTLY. Hardcoded (not read via
    // roleRegistry.<ROLE>()) because executeRoleGrants runs BEFORE the registry
    // upgrade, and the pre-upgrade impl doesn't expose these getters. Resolved
    // hex shown for `cast` cross-checks.
    // ─────────────────────────────────────────────────────────────────────
    bytes32 internal constant UPGRADE_TIMELOCK_ROLE        = keccak256("UPGRADE_TIMELOCK_ROLE");        // 0x5ba17a247620ef8426ae0fffc28eee4ee4b18eb3b8bcfa95664565c35371dfb5
    bytes32 internal constant OPERATION_TIMELOCK_ROLE      = keccak256("OPERATION_TIMELOCK_ROLE");      // 0xe6bda0fc5c63b525e475d178ed9c7fa9913b3429ade866197b11eb0f2c18c673
    bytes32 internal constant OPERATION_MULTISIG_ROLE      = keccak256("OPERATION_MULTISIG_ROLE");      // 0x9e4e6873d7e5b4630066665503d42d0314a7e21ea9ee5a05704b5b8c7148d3fb
    bytes32 internal constant SUPER_GUARDIAN_ROLE          = keccak256("SUPER_GUARDIAN_ROLE");          // 0xd79525443f4852b5f09ad4110de858f17068636090fc71aac61dd76a51bc2d1a
    bytes32 internal constant GUARDIAN_ROLE                = keccak256("GUARDIAN_ROLE");                // 0x55435dd261a4b9b3364963f7738a7a662ad9c84396d64be3365284bb7f0a5041
    bytes32 internal constant ORACLE_OPERATIONS_ROLE       = keccak256("ORACLE_OPERATIONS_ROLE");       // 0xe04627ac7a10b0a9db5fa2746383dd87425afe4c7fe0a07b97e3996bc31be8cf
    bytes32 internal constant HOUSEKEEPING_OPERATIONS_ROLE = keccak256("HOUSEKEEPING_OPERATIONS_ROLE"); // 0x6a220c67787309b57c3b5be766e6a2ee58f627b61610a5769482ab82dd198c87
    bytes32 internal constant EXECUTOR_OPERATIONS_ROLE     = keccak256("EXECUTOR_OPERATIONS_ROLE");     // 0x8d94a233c9c242689a785911ca9060f0c5e06f317a3ec55d9a79ce4f7991d669
    bytes32 internal constant EIGENPOD_OPERATIONS_ROLE     = keccak256("EIGENPOD_OPERATIONS_ROLE");     // 0x1d35f3653d06c44a47eae771269a6fec1babec5f5c25127bb524f5fefc5673e7

    // ─────────────────────────────────────────────────────────────────────
    // LEGACY ROLE IDs — the pre-upgrade granular roles, enumerated from every
    // keccak256("..._ROLE") / PROTOCOL_PAUSER/UNPAUSER constant declared across
    // the master-branch src/ contracts (the currently-deployed code). After this
    // upgrade every gated function routes through the 9 RolesLibrary roles above,
    // so these 31 are orphaned; _appendLegacyRevokeCalls (part of the upgrade batch)
    // revokes their holders. NONE of these collide with the 9 new role IDs (distinct
    // strings), so revoking them never touches the fresh grants from _appendGrantCalls.
    // ─────────────────────────────────────────────────────────────────────
    bytes32 internal constant L_PROTOCOL_PAUSER                                       = keccak256("PROTOCOL_PAUSER");
    bytes32 internal constant L_PROTOCOL_UNPAUSER                                     = keccak256("PROTOCOL_UNPAUSER");
    bytes32 internal constant L_EETH_OPERATING_ADMIN_ROLE                             = keccak256("EETH_OPERATING_ADMIN_ROLE");
    bytes32 internal constant L_WEETH_OPERATING_ADMIN_ROLE                            = keccak256("WEETH_OPERATING_ADMIN_ROLE");
    bytes32 internal constant L_LIQUIDITY_POOL_ADMIN_ROLE                             = keccak256("LIQUIDITY_POOL_ADMIN_ROLE");
    bytes32 internal constant L_LIQUIDITY_POOL_VALIDATOR_APPROVER_ROLE                = keccak256("LIQUIDITY_POOL_VALIDATOR_APPROVER_ROLE");
    bytes32 internal constant L_LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE                 = keccak256("LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE");
    bytes32 internal constant L_STAKING_MANAGER_ADMIN_ROLE                            = keccak256("STAKING_MANAGER_ADMIN_ROLE");
    bytes32 internal constant L_STAKING_MANAGER_NODE_CREATOR_ROLE                     = keccak256("STAKING_MANAGER_NODE_CREATOR_ROLE");
    bytes32 internal constant L_STAKING_MANAGER_VALIDATOR_INVALIDATOR_ROLE            = keccak256("STAKING_MANAGER_VALIDATOR_INVALIDATOR_ROLE");
    bytes32 internal constant L_ETHERFI_NODES_MANAGER_ADMIN_ROLE                      = keccak256("ETHERFI_NODES_MANAGER_ADMIN_ROLE");
    bytes32 internal constant L_ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE           = keccak256("ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE");
    bytes32 internal constant L_ETHERFI_NODES_MANAGER_POD_PROVER_ROLE                 = keccak256("ETHERFI_NODES_MANAGER_POD_PROVER_ROLE");
    bytes32 internal constant L_ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE             = keccak256("ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE");
    bytes32 internal constant L_ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE            = keccak256("ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE");
    bytes32 internal constant L_ETHERFI_NODES_MANAGER_EL_CONSOLIDATION_ROLE           = keccak256("ETHERFI_NODES_MANAGER_EL_CONSOLIDATION_ROLE");
    bytes32 internal constant L_ETHERFI_NODES_MANAGER_LEGACY_LINKER_ROLE              = keccak256("ETHERFI_NODES_MANAGER_LEGACY_LINKER_ROLE");
    bytes32 internal constant L_ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE                    = keccak256("ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE");
    bytes32 internal constant L_ETHERFI_ORACLE_EXECUTOR_TASK_MANAGER_ROLE             = keccak256("ETHERFI_ORACLE_EXECUTOR_TASK_MANAGER_ROLE");
    bytes32 internal constant L_ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE                 = keccak256("ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE");
    bytes32 internal constant L_ETHERFI_RATE_LIMITER_ADMIN_ROLE                       = keccak256("ETHERFI_RATE_LIMITER_ADMIN_ROLE");
    bytes32 internal constant L_WITHDRAW_REQUEST_NFT_ADMIN_ROLE                       = keccak256("WITHDRAW_REQUEST_NFT_ADMIN_ROLE");
    bytes32 internal constant L_IMPLICIT_FEE_CLAIMER_ROLE                             = keccak256("IMPLICIT_FEE_CLAIMER_ROLE");
    bytes32 internal constant L_PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE                  = keccak256("PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE");
    bytes32 internal constant L_PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE      = keccak256("PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE");
    bytes32 internal constant L_PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE        = keccak256("PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE");
    bytes32 internal constant L_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR_ADMIN_ROLE      = keccak256("CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR_ADMIN_ROLE");
    bytes32 internal constant L_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR_CLAIM_DELAY_SETTER_ROLE = keccak256("CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR_CLAIM_DELAY_SETTER_ROLE");
    bytes32 internal constant L_ETHERFI_REWARDS_ROUTER_ADMIN_ROLE                     = keccak256("ETHERFI_REWARDS_ROUTER_ADMIN_ROLE");
    bytes32 internal constant L_ETHERFI_REWARDS_ROUTER_ERC20_TRANSFER_ROLE            = keccak256("ETHERFI_REWARDS_ROUTER_ERC20_TRANSFER_ROLE");
    bytes32 internal constant L_WEETH_WITHDRAW_ADAPTER_ADMIN_ROLE                     = keccak256("WEETH_WITHDRAW_ADAPTER_ADMIN_ROLE");

    // ─────────────────────────────────────────────────────────────────────
    // RATE-LIMITER BUCKETS (gwei units; TBD).
    // ─────────────────────────────────────────────────────────────────────
    // core — Token-side global buckets (consumeToken on eETH/weETH paths).
    // Transfer is now per-address (consumeForAddressIfConfigured); no global TRANSFER bucket.
    uint64 internal constant EETH_MINT_CAPACITY    = 0;
    uint64 internal constant EETH_MINT_REFILL_RATE = 0;
    uint64 internal constant EETH_BURN_CAPACITY    = 0;
    uint64 internal constant EETH_BURN_REFILL_RATE = 0;
    uint64 internal constant WEETH_MINT_CAPACITY   = 0;
    uint64 internal constant WEETH_MINT_REFILL_RATE = 0;
    uint64 internal constant WEETH_BURN_CAPACITY   = 0;
    uint64 internal constant WEETH_BURN_REFILL_RATE = 0;

    // restaking — EtherFiRestaker buckets (consume).
    uint64 internal constant STETH_REQUEST_WITHDRAWAL_CAPACITY    = 0;
    uint64 internal constant STETH_REQUEST_WITHDRAWAL_REFILL_RATE = 0;
    uint64 internal constant QUEUE_WITHDRAWALS_CAPACITY           = 0;
    uint64 internal constant QUEUE_WITHDRAWALS_REFILL_RATE        = 0;
    uint64 internal constant DEPOSIT_INTO_STRATEGY_CAPACITY       = 0;
    uint64 internal constant DEPOSIT_INTO_STRATEGY_REFILL_RATE    = 0;

    // staking — EtherFiNodesManager buckets (consume).
    // NOTE: UNRESTAKING / EXIT_REQUEST / CONSOLIDATION_REQUEST buckets already exist on
    // mainnet from a prior deployment (limitExists() == true). Batch 2 calls
    // setCapacity + setRefillRate for these 3 rather than createNewLimiter; the 7 token
    // and restaker buckets are still newly-created. See F2 in PR #420 review.
    uint64 internal constant UNRESTAKING_CAPACITY            = 0;
    uint64 internal constant UNRESTAKING_REFILL_RATE         = 0;
    uint64 internal constant EXIT_REQUEST_CAPACITY           = 0;
    uint64 internal constant EXIT_REQUEST_REFILL_RATE        = 0;
    uint64 internal constant CONSOLIDATION_REQUEST_CAPACITY  = 0;
    uint64 internal constant CONSOLIDATION_REQUEST_REFILL_RATE = 0;

    // ─────────────────────────────────────────────────────────────────────
    // PausableUntil durations (sec; TBD). Gated to contracts that mix in
    // PausableUntil. The four ex-targets (EtherFiAdmin, MembershipManager,
    // MembershipNFT, NodeOperatorManager) have no setPauseUntilDuration and were dropped.
    // ─────────────────────────────────────────────────────────────────────
    // core
    uint256 internal constant PAUSE_UNTIL_EETH                                  = 8 hours;
    uint256 internal constant PAUSE_UNTIL_LIQUIDITY_POOL                        = 1 days;
    uint256 internal constant PAUSE_UNTIL_WEETH                                 = 8 hours;
    // deposits
    uint256 internal constant PAUSE_UNTIL_LIQUIFIER                             = 1 days;
    // rewards
    uint256 internal constant PAUSE_UNTIL_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR = 2 days;
    // staking
    uint256 internal constant PAUSE_UNTIL_AUCTION_MANAGER                       = 2 days;
    uint256 internal constant PAUSE_UNTIL_ETHERFI_NODES_MANAGER                 = 2 days;
    // withdrawals
    uint256 internal constant PAUSE_UNTIL_ETHERFI_REDEMPTION_MGR                = 1 days;
    uint256 internal constant PAUSE_UNTIL_PRIORITY_WITHDRAWAL_QUEUE             = 1 days;
    uint256 internal constant PAUSE_UNTIL_WEETH_WITHDRAW_ADAPTER                = 1 days;
    uint256 internal constant PAUSE_UNTIL_WITHDRAW_REQUEST_NFT                  = 1 days;

    // ─────────────────────────────────────────────────────────────────────
    // Bucket IDs — must match the constants declared in the source contracts.
    // ─────────────────────────────────────────────────────────────────────
    // core
    bytes32 internal constant EETH_MINT_LIMIT_ID                = keccak256("EETH_MINT_LIMIT_ID");
    bytes32 internal constant EETH_BURN_LIMIT_ID                = keccak256("EETH_BURN_LIMIT_ID");
    bytes32 internal constant WEETH_MINT_LIMIT_ID               = keccak256("WEETH_MINT_LIMIT_ID");
    bytes32 internal constant WEETH_BURN_LIMIT_ID               = keccak256("WEETH_BURN_LIMIT_ID");

    // restaking
    bytes32 internal constant STETH_REQUEST_WITHDRAWAL_LIMIT_ID = keccak256("STETH_REQUEST_WITHDRAWAL_LIMIT_ID");
    bytes32 internal constant QUEUE_WITHDRAWALS_LIMIT_ID        = keccak256("QUEUE_WITHDRAWALS_LIMIT_ID");
    bytes32 internal constant DEPOSIT_INTO_STRATEGY_LIMIT_ID    = keccak256("DEPOSIT_INTO_STRATEGY_LIMIT_ID");

    // staking
    bytes32 internal constant UNRESTAKING_LIMIT_ID              = keccak256("UNRESTAKING_LIMIT_ID");
    bytes32 internal constant EXIT_REQUEST_LIMIT_ID             = keccak256("EXIT_REQUEST_LIMIT_ID");
    bytes32 internal constant CONSOLIDATION_REQUEST_LIMIT_ID    = keccak256("CONSOLIDATION_REQUEST_LIMIT_ID");

    // ─────────────────────────────────────────────────────────────────────
    // TIMELOCKS / REGISTRY HANDLES + DELAYS + OUTPUT DIR.
    // ─────────────────────────────────────────────────────────────────────
    EtherFiTimelock internal constant upgradeTimelock   = EtherFiTimelock(payable(UPGRADE_TIMELOCK));
    EtherFiTimelock internal constant operatingTimelock = EtherFiTimelock(payable(OPERATING_TIMELOCK));
    RoleRegistry    internal constant roleRegistry      = RoleRegistry(ROLE_REGISTRY);

    uint256 internal constant UPGRADE_TIMELOCK_DELAY   = 10 days;
    uint256 internal constant OPERATING_TIMELOCK_DELAY = 2 days;

    string internal constant OUT_DIR = "script/upgrades/security-upgrades";
}
