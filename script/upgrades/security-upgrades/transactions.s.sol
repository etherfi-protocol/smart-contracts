// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

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
import {EtherFiTimelock} from "@etherfi/governance/EtherFiTimelock.sol";
import {RoleRegistry} from "@etherfi/governance/RoleRegistry.sol";
import {Blacklister} from "@etherfi/governance/Blacklister.sol";
import {RevokeAdmin} from "@etherfi/governance/RevokeAdmin.sol";
import {EtherFiRateLimiter} from "@etherfi/governance/rate-limiting/EtherFiRateLimiter.sol";
// membership
import {MembershipManager} from "@etherfi/archive/membership/MembershipManager.sol";
import {MembershipNFT} from "@etherfi/archive/membership/MembershipNFT.sol";
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
import {IEtherFiRedemptionManager} from "@etherfi/withdrawals/interfaces/IEtherFiRedemptionManager.sol";
import {PriorityWithdrawalQueue} from "@etherfi/withdrawals/PriorityWithdrawalQueue.sol";
import {WeETHWithdrawAdapter} from "@etherfi/withdrawals/WeETHWithdrawAdapter.sol";
import {WithdrawRequestNFT} from "@etherfi/withdrawals/WithdrawRequestNFT.sol";

// interfaces — the ConstructorAddresses structs live on the interfaces (not the contracts)
import {ILiquidityPool} from "@etherfi/core/interfaces/ILiquidityPool.sol";
import {IDepositAdapter} from "@etherfi/deposits/interfaces/IDepositAdapter.sol";
import {ILiquifier} from "@etherfi/deposits/interfaces/ILiquifier.sol";
import {IEtherFiAdmin} from "@etherfi/oracle/interfaces/IEtherFiAdmin.sol";
import {IEtherFiOracle} from "@etherfi/oracle/interfaces/IEtherFiOracle.sol";
import {IWithdrawRequestNFT} from "@etherfi/withdrawals/interfaces/IWithdrawRequestNFT.sol";

import {ContractCodeChecker} from "@scripts/ContractCodeChecker.sol";
import {Utils} from "@scripts/utils/utils.sol";
import {SecurityUpgradesConstants} from "./Constants.s.sol";

/**
 * 26Q2 Security Upgrades - Timelocked Upgrade + Configuration
 *
 * See ROLE_MIGRATION.md for the role plan and operational parameter table.
 * Every constant left at address(0) / 0 must be filled in before broadcast;
 * `_preflight()` reverts otherwise.
 *
 * Everything is packed into FOUR batches → SIX Safe JSON files:
 *   • Batch 0 — OPERATION_MULTISIG (now): auction_sweep.json   (PRE-UPGRADE; must execute first)
 *   • Batch 1 — UPGRADE_TIMELOCK (10d):   upgrade_schedule.json + upgrade_execute.json
 *   • Batch 2 — OPERATING_TIMELOCK (2d):  ops_schedule.json + ops_execute.json
 *   • Batch 3 — OPERATION_MULTISIG (now): lp_withdraw_bounds.json
 * Execute Batch 0 first (flushes AuctionManager revenue while the old impl still can).
 * Both timelock batches are SCHEDULED together; after the 10-day delay, execute
 * Batch 1, then Batch 2, then the instant Batch 3.
 *
 * `run()` builds + dry-runs them in execution order:
 *   1. verifyDeployedBytecode      — fresh deploys match the recorded impls
 *   2. takePreUpgradeSnapshots     — owners + paused, per upgraded proxy
 *   2.5 executeAuctionSweep        — Batch 0 (OPERATION_MULTISIG, instant, PRE-UPGRADE):
 *                                    flush AuctionManager.accumulatedRevenue to MembershipManager
 *                                    before the impl swap deletes that slot + its transfer fn.
 *   3. executeUpgrade              — Batch 1 (UPGRADE_TIMELOCK, 10d). ONE batch, in order:
 *                                    (a) grant the 9 RolesLibrary roles (owner-gated; owner == UPGRADE_TIMELOCK),
 *                                    (b) upgrade RoleRegistry + every proxy + the EtherFiNode beacon,
 *                                    (c) the two onlyUpgradeTimelock initializers
 *                                        (LiquidityPool.initializeOnUpgradeV2, WithdrawRequestNFT.initializeShareRateFreezeUpgrade),
 *                                    (d) unwhitelist cbETH + wBETH on Liquifier (EARN-1421),
 *                                    (e) revoke every holder of the 31 legacy roles (owner-gated).
 *                                    Grants precede the initializers (which need UPGRADE_TIMELOCK_ROLE);
 *                                    revokes come last, once the legacy roles are orphaned.
 *   4. verifyUpgrades              — ERC1967 implementation slot == new impl
 *   5. verifyImmutablePreservation — immutables on each new impl match wiring
 *   6. verifyAccessControlPreservation — owner + paused + init state unchanged
 *   7. verifyLegacyRolesRevoked    — assert roleHolders() is empty for every legacy role
 *  7b. verifyLiquifierWhitelistRemoved — assert cbETH + wBETH unwhitelisted on Liquifier (EARN-1421)
 *
 *   8. executeOperatingConfig      — Batch 2 (OPERATING_TIMELOCK, 2d): rate-limiter buckets,
 *                                    pause durations, EtherFiAdmin daily finalized-withdrawal cap,
 *                                    and the ENM forwarded-call whitelist migration (grant the
 *                                    legacy caller's set to the eigenpod-ops holder, revoke the legacy)
 *   9. executeLpWithdrawBounds     — Batch 3 (OPERATION_MULTISIG, instant): LP min/max withdraw bounds
 *  10. verifyOperatingConfig       — buckets + pause durations + role grants + LP bounds + finalized-withdrawal cap
 */
contract SecurityUpgradesScript is Script, SecurityUpgradesConstants, Utils {
    // ─────────────────────────────────────────────────────────────────────
    // DEPLOYED IMPLEMENTATIONS - populate from deploy.s.sol output
    // ─────────────────────────────────────────────────────────────────────
    // New proxies (Blacklister / RevokeAdmin) are reused as proxies; every other
    // entry is a fresh implementation address. Peripheral UUPS proxies touched by
    // PR #385 reuse their existing proxies — impls only. Ordered by src/ group.
    // core
    address constant eEthImpl                     = address(0);
    address constant liquidityPoolImpl            = address(0);
    address constant weEthImpl                    = address(0);
    // deposits
    address constant depositAdapterImpl           = address(0);
    address constant liquifierImpl                = address(0);
    // governance
    address constant blacklisterProxy             = address(0);
    address constant revokeAdminProxy             = address(0);
    address constant roleRegistryImpl             = address(0);
    address constant etherFiRateLimiterImpl       = address(0);
    // membership
    address constant membershipManagerImpl        = address(0);
    address constant membershipNFTImpl            = address(0);
    // oracle
    address constant etherFiAdminImpl             = address(0);
    address constant etherFiOracleImpl            = address(0);
    // restaking
    address constant etherFiRestakerImpl          = address(0);
    address constant restakingRewardsRouterImpl   = address(0);
    // rewards
    address constant cumulativeMerkleRewardsDistributorImpl = address(0);
    address constant etherFiRewardsRouterImpl     = address(0);
    // staking
    address constant auctionManagerImpl           = address(0);
    address constant etherFiNodeImpl              = address(0);
    address constant etherFiNodesManagerImpl      = address(0);
    address constant nodeOperatorManagerImpl      = address(0);
    address constant stakingManagerImpl           = address(0);
    // withdrawals
    address constant etherFiRedemptionManagerImpl = address(0);
    address constant priorityWithdrawalQueueImpl  = address(0);
    address constant weETHWithdrawAdapterImpl     = address(0);
    address constant withdrawRequestNFTImpl       = address(0);
    // cross-chain — EtherfiL1SyncPoolETH new impl (deployed from the WeETH-cross-chain repo,
    // PR #77). Fill from that repo's deploy output. Its proxy (ETHERFI_L1_SYNC_POOL_ETH) is an
    // OZ5 TransparentUpgradeableProxy, upgraded through its ProxyAdmin (below), not via upgradeTo.
    address constant l1SyncPoolImpl = address(0);
    // ProxyAdmin of the L1SyncPool transparent proxy (on-chain admin slot of 0xD789…). Owner is
    // currently ETHERFI_OPERATING_ADMIN; must be transferred to UPGRADE_TIMELOCK before this batch.
    address constant L1_SYNC_POOL_PROXY_ADMIN     = 0xDBf6bE120D4dc72f01534673a1223182D9F6261D;

    // ─────────────────────────────────────────────────────────────────────
    // All configuration constants — immutable constructor params, operational
    // setpoints, role holders, role IDs, legacy role IDs, rate-limiter buckets,
    // pause durations, bucket IDs, timelock/registry handles, delays, OUT_DIR
    // and GIT_COMMIT_SHA / commitHashSalt — live in Constants.s.sol
    // (SecurityUpgradesConstants), shared with deploy.s.sol and revert.s.sol.
    // The constructor params there MUST match what deploy.s.sol baked into each
    // impl; verifyDeployedBytecode rebuilds each impl from them locally.
    //
    // Only the deployed-implementation INPUT addresses (populated by hand from
    // deploy.s.sol's output) remain declared above, since they are per-run
    // deployment bookkeeping rather than shared configuration.
    // ─────────────────────────────────────────────────────────────────────

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

    // Forwarded-call whitelist migration. ENM's whitelist is keyed per caller. Move the eigenpod-ops
    // forwarder's live grants from the legacy pod-prover EOA to HOLDER_EIGENPOD_OPERATIONS_ROLE: grant
    // each to the new holder and revoke each from the legacy caller. The holder must equal the
    // EIGENPOD_OPERATIONS_ROLE holder, since forward* checks both the role and the per-caller whitelist.
    // The set below is LEGACY_FORWARD_CALLER's effective whitelist verified live on mainnet (block
    // 25383537); the OPERATING_TIMELOCK's separate delegation grants are intentionally left untouched.
    address internal constant LEGACY_FORWARD_CALLER = 0x7835fB36A8143a014A2c381363cD1A4DeE586d2A;

    // forwardEigenPodCall selectors (called on the validator's EigenPod).
    bytes4 internal constant SEL_START_CHECKPOINT              = 0x88676cad; // startCheckpoint(bool)
    bytes4 internal constant SEL_VERIFY_CHECKPOINT_PROOFS      = 0xf074ba62; // verifyCheckpointProofs((bytes32,bytes),(bytes32,bytes32,bytes)[])
    bytes4 internal constant SEL_VERIFY_WITHDRAWAL_CREDENTIALS = 0x3f65cf19; // verifyWithdrawalCredentials(uint64,(bytes32,bytes),uint40[],bytes[],bytes32[][])

    // forwardExternalCall selector — processClaim on the EigenLayer RewardsCoordinator.
    bytes4 internal constant SEL_PROCESS_CLAIM = 0x3ccc861d; // processClaim((...),address)

    // forwardExternalCall selectors on the EigenLayer DelegationManager, newly whitelisted in 3CP #580
    // (batch queue/complete across backfilled nodes). GRANT-ONLY to the new holder here; the legacy
    // caller's copies are revoked in a separate later 3CP.
    bytes4 internal constant SEL_QUEUE_WITHDRAWALS           = 0x0dd8dd02; // queueWithdrawals((address[],uint256[],address)[])
    bytes4 internal constant SEL_COMPLETE_QUEUED_WITHDRAWALS = 0x9435bb43; // completeQueuedWithdrawals((...)[],address[][],bool[]) (plural)
    bytes4 internal constant SEL_COMPLETE_QUEUED_WITHDRAWAL  = 0xe4cc3f90; // completeQueuedWithdrawal((...),address[],bool) (singular; used by completeQueuedETHWithdrawals)

    function run() public {
        // Prefer FORK_RPC_URL when set (e.g. a Tenderly virtual testnet that already has the
        // deploy.s.sol broadcast applied) so verifyDeployedBytecode can read the new impls'
        // code; fall back to mainnet. On bare mainnet the new impls have no code yet and the
        // bytecode gate reverts with "on-chain bytecode empty".
        string memory forkUrl = vm.envOr("FORK_RPC_URL", vm.envString("MAINNET_RPC_URL"));
        vm.selectFork(vm.createFork(forkUrl));

        _printPleaseEyeball();
        _preflight();
        _preflightRoleHashes();
        _verifyReleaseCommit();
        codeChecker = new ContractCodeChecker();

        verifyDeployedBytecode();
        takePreUpgradeSnapshots();

        // ── Batch 0: the pre-upgrade AuctionManager sweep (instant) ────────────────
        // Flush the OLD AuctionManager's pending accumulatedRevenue to the MembershipManager
        // BEFORE the impl swap deletes that storage slot + its transfer function. Signed by
        // ETHERFI_OPERATING_ADMIN (an `admins[]` entry on the old impl). Must execute before
        // Batch 1 executes.
        executeAuctionSweep();

        // ── Batch 1: the UPGRADE_TIMELOCK batch (10d) ──────────────────────────────
        // One schedule + one execute JSON. Internally ordered: role grants ->
        // proxy/beacon upgrades -> onlyUpgradeTimelock initializers -> legacy role
        // revocations (all owner-gated or onlyUpgradeTimelock).
        executeUpgrade();
        verifyUpgrades();
        verifyImmutablePreservation();
        verifyAccessControlPreservation();
        verifyLegacyRolesRevoked();
        verifyLiquifierWhitelistRemoved();

        // ── Batch 2: the OPERATING_TIMELOCK batch (2d) ─────────────────────────────
        // Scheduled at the same time as Batch 1; executed after it. One schedule +
        // one execute JSON: rate-limiter buckets, pause durations, the EtherFiAdmin
        // daily finalized-withdrawal cap, and the ENM forwarded-call whitelist migration
        // (all OPERATION_TIMELOCK_ROLE / onlyOperatingTimelock).
        executeOperatingConfig();

        // ── Batch 3: the OPERATION_MULTISIG batch (instant) ────────────────────────
        // Executed last, with no timelock. One JSON: the LP withdraw bounds
        // (onlyOperatingMultisig). Needs the LP upgrade live + OPERATION_MULTISIG_ROLE,
        // both delivered by Batch 1.
        executeLpWithdrawBounds();

        verifyOperatingConfig();

        // ── Day-10 combined Safe B multiSend (steps 3 + 4) ─────────────────────────
        // Emits execday_ops_and_bounds.json: a single multiSend from ETHERFI_OPERATING_ADMIN
        // that runs the operating-timelock executeBatch THEN the LP bounds in one tx, in
        // order. Reuses the exact same executeBatch calldata + salt as ops_schedule.json so
        // the scheduled op matches. The standalone JSONs above remain valid; this is the
        // ordered/atomic packaging for execution day. (Sweep + nested upgrade are added once
        // the single-tx gas budget is confirmed.) Emit AFTER the dry-runs so we don't
        // re-schedule the same timelock op on the fork.
        emitExecutionDayOpsAndBounds();

        // ── Step 11: functional smoke test on the simulated post-upgrade fork ───────
        // Exercises the core user/operator flows against the upgraded contracts. Runs LAST,
        // after every Safe JSON is emitted, so its state mutations (deposits, a backlog flush,
        // bucket draining) can't affect broadcast output. Requires the buckets (Batch 2) + LP
        // bounds (Batch 3) to be live, which is why it can't sit in the view verifyUpgrades.
        verifyPostUpgradeFlows();
    }

    /// @dev Fail loudly the moment a required constant is unset.
    function _preflight() internal pure {
        require(GIT_COMMIT_SHA != bytes20(0), "preflight: GIT_COMMIT_SHA unset - set to first 20 bytes of release commit (MUST match deploy.s.sol)");
        require(LP_MIN_WITHDRAW_AMOUNT > 0,                                       "preflight: LP_MIN_WITHDRAW_AMOUNT unset");
        require(LP_MAX_WITHDRAW_AMOUNT > LP_MIN_WITHDRAW_AMOUNT,                  "preflight: LP_MAX_WITHDRAW_AMOUNT <= MIN");
        // core
        require(eEthImpl != address(0), "preflight: eEthImpl unset");
        require(liquidityPoolImpl != address(0), "preflight: liquidityPoolImpl unset");
        require(weEthImpl != address(0), "preflight: weEthImpl unset");
        // deposits
        require(depositAdapterImpl                     != address(0), "preflight: depositAdapterImpl unset");
        require(liquifierImpl != address(0), "preflight: liquifierImpl unset");
        // governance
        require(blacklisterProxy != address(0), "preflight: blacklisterProxy unset");
        require(revokeAdminProxy != address(0), "preflight: revokeAdminProxy unset");
        require(roleRegistryImpl != address(0), "preflight: roleRegistryImpl unset");
        require(etherFiRateLimiterImpl != address(0), "preflight: etherFiRateLimiterImpl unset");
        // membership
        require(membershipManagerImpl != address(0), "preflight: membershipManagerImpl unset");
        require(membershipNFTImpl != address(0), "preflight: membershipNFTImpl unset");
        // oracle
        require(etherFiAdminImpl != address(0), "preflight: etherFiAdminImpl unset");
        require(etherFiOracleImpl != address(0), "preflight: etherFiOracleImpl unset");
        // restaking
        require(etherFiRestakerImpl != address(0), "preflight: etherFiRestakerImpl unset");
        require(restakingRewardsRouterImpl             != address(0), "preflight: restakingRewardsRouterImpl unset");
        // rewards
        require(cumulativeMerkleRewardsDistributorImpl != address(0), "preflight: cumulativeMerkleRewardsDistributorImpl unset");
        require(etherFiRewardsRouterImpl               != address(0), "preflight: etherFiRewardsRouterImpl unset");
        // staking
        require(auctionManagerImpl != address(0), "preflight: auctionManagerImpl unset");
        require(etherFiNodeImpl != address(0), "preflight: etherFiNodeImpl unset");
        require(etherFiNodesManagerImpl != address(0), "preflight: etherFiNodesManagerImpl unset");
        require(nodeOperatorManagerImpl != address(0), "preflight: nodeOperatorManagerImpl unset");
        require(stakingManagerImpl != address(0), "preflight: stakingManagerImpl unset");
        // withdrawals
        require(etherFiRedemptionManagerImpl != address(0), "preflight: etherFiRedemptionManagerImpl unset");
        require(priorityWithdrawalQueueImpl            != address(0), "preflight: priorityWithdrawalQueueImpl unset");
        require(weETHWithdrawAdapterImpl               != address(0), "preflight: weETHWithdrawAdapterImpl unset");
        require(withdrawRequestNFTImpl != address(0), "preflight: withdrawRequestNFTImpl unset");
        // cross-chain
        require(l1SyncPoolImpl != address(0), "preflight: l1SyncPoolImpl unset (deploy from WeETH-cross-chain repo)");

        require(EETH_MINT_CAPACITY    != 0, "preflight: EETH_MINT_CAPACITY unset");
        require(EETH_MINT_REFILL_RATE != 0, "preflight: EETH_MINT_REFILL_RATE unset");
        require(EETH_BURN_CAPACITY    != 0, "preflight: EETH_BURN_CAPACITY unset");
        require(EETH_BURN_REFILL_RATE != 0, "preflight: EETH_BURN_REFILL_RATE unset");

        require(STETH_REQUEST_WITHDRAWAL_CAPACITY    != 0, "preflight: STETH_REQUEST_WITHDRAWAL_CAPACITY unset");
        require(STETH_REQUEST_WITHDRAWAL_REFILL_RATE != 0, "preflight: STETH_REQUEST_WITHDRAWAL_REFILL_RATE unset");

        // core
        require(PAUSE_UNTIL_EETH != 0,                   "preflight: PAUSE_UNTIL_EETH unset");
        require(PAUSE_UNTIL_LIQUIDITY_POOL != 0,         "preflight: PAUSE_UNTIL_LIQUIDITY_POOL unset");
        require(PAUSE_UNTIL_WEETH != 0,                  "preflight: PAUSE_UNTIL_WEETH unset");
        // deposits
        require(PAUSE_UNTIL_LIQUIFIER != 0,              "preflight: PAUSE_UNTIL_LIQUIFIER unset");
        // rewards
        require(PAUSE_UNTIL_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR != 0, "preflight: PAUSE_UNTIL_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR unset");
        // staking
        require(PAUSE_UNTIL_AUCTION_MANAGER != 0,        "preflight: PAUSE_UNTIL_AUCTION_MANAGER unset");
        require(PAUSE_UNTIL_ETHERFI_NODES_MANAGER != 0,  "preflight: PAUSE_UNTIL_ETHERFI_NODES_MANAGER unset");
        // withdrawals
        require(PAUSE_UNTIL_ETHERFI_REDEMPTION_MGR != 0, "preflight: PAUSE_UNTIL_ETHERFI_REDEMPTION_MGR unset");
        require(PAUSE_UNTIL_PRIORITY_WITHDRAWAL_QUEUE != 0,             "preflight: PAUSE_UNTIL_PRIORITY_WITHDRAWAL_QUEUE unset");
        require(PAUSE_UNTIL_WEETH_WITHDRAW_ADAPTER != 0,                "preflight: PAUSE_UNTIL_WEETH_WITHDRAW_ADAPTER unset");
        require(PAUSE_UNTIL_WITHDRAW_REQUEST_NFT != 0,   "preflight: PAUSE_UNTIL_WITHDRAW_REQUEST_NFT unset");

        require(ADMIN_DAILY_FINALIZED_WITHDRAWAL_LIMIT != 0, "preflight: ADMIN_DAILY_FINALIZED_WITHDRAWAL_LIMIT unset");
        require(ADMIN_DAILY_FINALIZED_WITHDRAWAL_LIMIT <= ADMIN_MAX_FINALIZED_WITHDRAWAL_AMOUNT_PER_DAY, "preflight: ADMIN_DAILY_FINALIZED_WITHDRAWAL_LIMIT exceeds acceptable ceiling");

        require(HOLDER_SUPER_GUARDIAN_ROLE          != address(0), "preflight: HOLDER_SUPER_GUARDIAN_ROLE unset");
        require(HOLDER_GUARDIAN_ROLE                != address(0), "preflight: HOLDER_GUARDIAN_ROLE unset");
        require(HOLDER_ORACLE_OPERATIONS_ROLE       != address(0), "preflight: HOLDER_ORACLE_OPERATIONS_ROLE unset");
        require(HOLDER_HOUSEKEEPING_OPERATIONS_ROLE != address(0), "preflight: HOLDER_HOUSEKEEPING_OPERATIONS_ROLE unset");
        require(HOLDER_EXECUTOR_OPERATIONS_ROLE     != address(0), "preflight: HOLDER_EXECUTOR_OPERATIONS_ROLE unset");
        require(HOLDER_EIGENPOD_OPERATIONS_ROLE     != address(0), "preflight: HOLDER_EIGENPOD_OPERATIONS_ROLE unset");
        require(HOLDER_CANCELLER_GUARDIAN           != address(0), "preflight: HOLDER_CANCELLER_GUARDIAN unset");
    }

    /// @dev verifyDeployedBytecode rebuilds each impl by compiling the CURRENT working tree, so a
    ///      bytecode match only proves "on-chain impl == my checkout", NOT "== the audited release
    ///      commit". This pins the checkout to GIT_COMMIT_SHA and rejects a dirty tree, closing that
    ///      gap. Requires `--ffi`. For the production verification run:
    ///          VERIFY_GIT_COMMIT=true forge script ... --ffi
    ///      from a clean checkout of the release commit. When the env flag is unset the check is
    ///      skipped but logs a LOUD warning so the gap is never silent.
    function _verifyReleaseCommit() internal {
        if (!vm.envOr("VERIFY_GIT_COMMIT", false)) {
            console2.log("[WARN] ============================================================");
            console2.log("[WARN] GIT COMMIT PIN NOT VERIFIED. Step 1 rebuilds every impl from the");
            console2.log("[WARN] CURRENT working tree, which may differ from the audited release");
            console2.log("[WARN] commit. For the production broadcast verification, run with:");
            console2.log("[WARN]   VERIFY_GIT_COMMIT=true forge script ... --ffi");
            console2.log("[WARN] from a clean checkout of GIT_COMMIT_SHA.");
            console2.log("[WARN] ============================================================");
            return;
        }

        // HEAD must equal GIT_COMMIT_SHA. `git rev-parse HEAD` emits 40 lowercase hex chars + "\n",
        // which ffi returns as UTF-8 bytes (the trailing newline prevents hex auto-decoding).
        string[] memory headCmd = new string[](3);
        headCmd[0] = "git";
        headCmd[1] = "rev-parse";
        headCmd[2] = "HEAD";
        bytes memory head = vm.ffi(headCmd);
        require(head.length >= 40, "release-commit: unexpected `git rev-parse HEAD` output");
        bytes memory expected = bytes(_bytes20ToLowerHex(GIT_COMMIT_SHA));
        for (uint256 i = 0; i < 40; i++) {
            require(head[i] == expected[i], "release-commit: HEAD != GIT_COMMIT_SHA (wrong checkout)");
        }

        // Working tree must be clean, else the rebuilt impls reflect uncommitted edits.
        string[] memory statusCmd = new string[](3);
        statusCmd[0] = "git";
        statusCmd[1] = "status";
        statusCmd[2] = "--porcelain";
        require(vm.ffi(statusCmd).length == 0, "release-commit: working tree dirty - commit or stash first");

        console2.log("[OK] release commit verified: HEAD == GIT_COMMIT_SHA and working tree clean");
    }

    /// @dev Lowercase hex (no 0x prefix) of a bytes20, for comparing against `git rev-parse` output.
    function _bytes20ToLowerHex(bytes20 v) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory out = new bytes(40);
        for (uint256 i = 0; i < 20; i++) {
            out[2 * i]     = alphabet[uint8(v[i]) >> 4];
            out[2 * i + 1] = alphabet[uint8(v[i]) & 0x0f];
        }
        return string(out);
    }

    /// @dev Cross-check every hardcoded keccak256 role-ID string against a freshly-built
    ///      RoleRegistry instance, so a typo in any of the 9 role strings fails BEFORE
    ///      any JSON is written (see H8 in PR #420 review). Non-pure because `new`
    ///      deploys a transient contract; runs after _preflight verified addresses.
    function _preflightRoleHashes() internal {
        RoleRegistry _rr = new RoleRegistry(revokeAdminProxy);
        require(_rr.UPGRADE_TIMELOCK_ROLE()        == UPGRADE_TIMELOCK_ROLE,        "preflight: UPGRADE_TIMELOCK_ROLE hash mismatch");
        require(_rr.OPERATION_TIMELOCK_ROLE()      == OPERATION_TIMELOCK_ROLE,      "preflight: OPERATION_TIMELOCK_ROLE hash mismatch");
        require(_rr.OPERATION_MULTISIG_ROLE()      == OPERATION_MULTISIG_ROLE,      "preflight: OPERATION_MULTISIG_ROLE hash mismatch");
        require(_rr.SUPER_GUARDIAN_ROLE()          == SUPER_GUARDIAN_ROLE,          "preflight: SUPER_GUARDIAN_ROLE hash mismatch");
        require(_rr.GUARDIAN_ROLE()                == GUARDIAN_ROLE,                "preflight: GUARDIAN_ROLE hash mismatch");
        require(_rr.ORACLE_OPERATIONS_ROLE()       == ORACLE_OPERATIONS_ROLE,       "preflight: ORACLE_OPERATIONS_ROLE hash mismatch");
        require(_rr.HOUSEKEEPING_OPERATIONS_ROLE() == HOUSEKEEPING_OPERATIONS_ROLE, "preflight: HOUSEKEEPING_OPERATIONS_ROLE hash mismatch");
        require(_rr.EXECUTOR_OPERATIONS_ROLE()     == EXECUTOR_OPERATIONS_ROLE,     "preflight: EXECUTOR_OPERATIONS_ROLE hash mismatch");
        require(_rr.EIGENPOD_OPERATIONS_ROLE()     == EIGENPOD_OPERATIONS_ROLE,     "preflight: EIGENPOD_OPERATIONS_ROLE hash mismatch");
    }

    /// @dev Print every TBD / signer-reviewable constant at the top of run() so the
    ///      broadcaster can eyeball them BEFORE any other output (H3 in PR #420 review).
    function _printPleaseEyeball() internal view {
        console2.log("================================================");
        console2.log("===== PLEASE EYEBALL - UPGRADE CONSTANTS =======");
        console2.log("================================================");
        console2.log("GIT_COMMIT_SHA (must match deploy.s.sol):", vm.toString(GIT_COMMIT_SHA));
        console2.log("commitHashSalt:                          ", vm.toString(commitHashSalt));
        console2.log("");
        console2.log("--- Deployed impl addresses (set after deploy.s.sol) ---");
        console2.log("blacklisterProxy:                    ", blacklisterProxy);
        console2.log("revokeAdminProxy:                    ", revokeAdminProxy);
        console2.log("roleRegistryImpl:                    ", roleRegistryImpl);
        console2.log("eEthImpl:                            ", eEthImpl);
        console2.log("liquidityPoolImpl:                   ", liquidityPoolImpl);
        console2.log("weEthImpl:                           ", weEthImpl);
        console2.log("depositAdapterImpl:                  ", depositAdapterImpl);
        console2.log("liquifierImpl:                       ", liquifierImpl);
        console2.log("etherFiRateLimiterImpl:              ", etherFiRateLimiterImpl);
        console2.log("membershipManagerImpl:               ", membershipManagerImpl);
        console2.log("membershipNFTImpl:                   ", membershipNFTImpl);
        console2.log("etherFiAdminImpl:                    ", etherFiAdminImpl);
        console2.log("etherFiOracleImpl:                   ", etherFiOracleImpl);
        console2.log("etherFiRestakerImpl:                 ", etherFiRestakerImpl);
        console2.log("restakingRewardsRouterImpl:          ", restakingRewardsRouterImpl);
        console2.log("cumulativeMerkleRewardsDistImpl:     ", cumulativeMerkleRewardsDistributorImpl);
        console2.log("etherFiRewardsRouterImpl:            ", etherFiRewardsRouterImpl);
        console2.log("auctionManagerImpl:                  ", auctionManagerImpl);
        console2.log("etherFiNodeImpl (beacon):            ", etherFiNodeImpl);
        console2.log("etherFiNodesManagerImpl:             ", etherFiNodesManagerImpl);
        console2.log("nodeOperatorManagerImpl:             ", nodeOperatorManagerImpl);
        console2.log("stakingManagerImpl:                  ", stakingManagerImpl);
        console2.log("etherFiRedemptionManagerImpl:        ", etherFiRedemptionManagerImpl);
        console2.log("priorityWithdrawalQueueImpl:         ", priorityWithdrawalQueueImpl);
        console2.log("weETHWithdrawAdapterImpl:            ", weETHWithdrawAdapterImpl);
        console2.log("withdrawRequestNFTImpl:              ", withdrawRequestNFTImpl);
        console2.log("");
        console2.log("--- 9 RoleRegistry role holders ---");
        console2.log("UPGRADE_TIMELOCK    (prefilled):     ", HOLDER_UPGRADE_TIMELOCK_ROLE);
        console2.log("OPERATION_TIMELOCK  (prefilled):     ", HOLDER_OPERATION_TIMELOCK_ROLE);
        console2.log("OPERATION_MULTISIG  (prefilled):     ", HOLDER_OPERATION_MULTISIG_ROLE);
        console2.log("SUPER_GUARDIAN_ROLE (TBD):           ", HOLDER_SUPER_GUARDIAN_ROLE);
        console2.log("GUARDIAN_ROLE (TBD):                 ", HOLDER_GUARDIAN_ROLE);
        console2.log("ORACLE_OPERATIONS_ROLE (TBD):        ", HOLDER_ORACLE_OPERATIONS_ROLE);
        console2.log("HOUSEKEEPING_OPERATIONS_ROLE (TBD):  ", HOLDER_HOUSEKEEPING_OPERATIONS_ROLE);
        console2.log("EXECUTOR_OPERATIONS_ROLE (TBD):      ", HOLDER_EXECUTOR_OPERATIONS_ROLE);
        console2.log("EIGENPOD_OPERATIONS_ROLE (TBD):      ", HOLDER_EIGENPOD_OPERATIONS_ROLE);
        console2.log("");
        console2.log("--- Rate-limiter buckets (gwei units; TBD) ---");
        console2.log("EETH_MINT  cap / refill:             ", EETH_MINT_CAPACITY,  EETH_MINT_REFILL_RATE);
        console2.log("EETH_BURN  cap / refill:             ", EETH_BURN_CAPACITY,  EETH_BURN_REFILL_RATE);
        console2.log("STETH_REQUEST_WITHDRAWAL cap/refill: ", STETH_REQUEST_WITHDRAWAL_CAPACITY, STETH_REQUEST_WITHDRAWAL_REFILL_RATE);
        console2.log("");
        console2.log("--- PausableUntil durations (sec; TBD) ---");
        console2.log("PAUSE_UNTIL_EETH:                    ", PAUSE_UNTIL_EETH);
        console2.log("PAUSE_UNTIL_WEETH:                   ", PAUSE_UNTIL_WEETH);
        console2.log("PAUSE_UNTIL_LIQUIDITY_POOL:          ", PAUSE_UNTIL_LIQUIDITY_POOL);
        console2.log("PAUSE_UNTIL_LIQUIFIER:               ", PAUSE_UNTIL_LIQUIFIER);
        console2.log("PAUSE_UNTIL_CMRD:                    ", PAUSE_UNTIL_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR);
        console2.log("PAUSE_UNTIL_AUCTION_MANAGER:         ", PAUSE_UNTIL_AUCTION_MANAGER);
        console2.log("PAUSE_UNTIL_ETHERFI_NODES_MANAGER:   ", PAUSE_UNTIL_ETHERFI_NODES_MANAGER);
        console2.log("PAUSE_UNTIL_ETHERFI_REDEMPTION_MGR:  ", PAUSE_UNTIL_ETHERFI_REDEMPTION_MGR);
        console2.log("PAUSE_UNTIL_PRIORITY_WITHDRAWAL_QUEUE", PAUSE_UNTIL_PRIORITY_WITHDRAWAL_QUEUE);
        console2.log("PAUSE_UNTIL_WEETH_WITHDRAW_ADAPTER:  ", PAUSE_UNTIL_WEETH_WITHDRAW_ADAPTER);
        console2.log("PAUSE_UNTIL_WITHDRAW_REQUEST_NFT:    ", PAUSE_UNTIL_WITHDRAW_REQUEST_NFT);
        console2.log("");
        console2.log("--- Operational setpoints ---");
        console2.log("ADMIN_DAILY_FINALIZED_WITHDRAWAL_LIMIT (TBD):", ADMIN_DAILY_FINALIZED_WITHDRAWAL_LIMIT);
        console2.log("LP_MIN_WITHDRAW_AMOUNT (wei):                ", LP_MIN_WITHDRAW_AMOUNT);
        console2.log("LP_MAX_WITHDRAW_AMOUNT (wei):                ", LP_MAX_WITHDRAW_AMOUNT);
        console2.log("================================================");
        console2.log("");
    }

    //--------------------------------------------------------------------------------------
    // STEP 1: verifyDeployedBytecode
    //--------------------------------------------------------------------------------------
    function verifyDeployedBytecode() public {
        console2.log("=== Step 1: Verifying Deployed Bytecode ===");
        _verifyCoreBytecode();
        _verifyDepositsBytecode();
        _verifyGovernanceBytecode();
        _verifyMembershipBytecode();
        _verifyOracleBytecode();
        _verifyRestakingBytecode();
        _verifyRewardsBytecode();
        _verifyStakingBytecode();
        _verifyWithdrawalsBytecode();
        console2.log("[OK] RoleRegistry + Blacklister + RevokeAdmin + all 22 implementations matched local bytecode");
        console2.log("");
    }

    function _verifyCoreBytecode() internal {
        EETHToken fresh = new EETHToken(LIQUIDITY_POOL, ROLE_REGISTRY, blacklisterProxy, ETHERFI_RATE_LIMITER);
        // EETH bakes its EIP-712 domain separator (keccak over address(this)) as an immutable, so
        // the on-chain impl and the fresh copy differ at that 32-byte word in addition to the
        // self-address. Read both via DOMAIN_SEPARATOR() so the gate can tolerate exactly that word.
        codeChecker.assertByteCodeMatch(
            eEthImpl, address(fresh),
            EETHToken(eEthImpl).DOMAIN_SEPARATOR(), fresh.DOMAIN_SEPARATOR()
        );

        LiquidityPool fresh2 = new LiquidityPool(
            ILiquidityPool.ConstructorAddresses({
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
            })
        );
        codeChecker.assertByteCodeMatch(liquidityPoolImpl, address(fresh2));

        WeETHToken fresh3 = new WeETHToken(EETH, LIQUIDITY_POOL, ROLE_REGISTRY, blacklisterProxy);
        codeChecker.assertByteCodeMatch(weEthImpl, address(fresh3));
    }

    function _verifyDepositsBytecode() internal {
        DepositAdapter fresh = new DepositAdapter(
            IDepositAdapter.ConstructorAddresses({
                liquidityPool: LIQUIDITY_POOL,
                liquifier: LIQUIFIER,
                weETH: WEETH,
                eETH: EETH,
                wETH: WETH,
                stETH: STETH,
                wstETH: WSTETH,
                roleRegistry: ROLE_REGISTRY,
                blacklister: blacklisterProxy
            })
        );
        codeChecker.assertByteCodeMatch(depositAdapterImpl, address(fresh));

        Liquifier fresh2 = new Liquifier(
            ILiquifier.ConstructorAddresses({
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
            LIQUIFIER_MIN_DISCOUNT_BPS, LIQUIFIER_STALE_PRICE_WINDOW, LIQUIFIER_MAX_PRICE_DEVIATION_BPS,
            LIQUIFIER_MAX_PRICE_THRESHOLD
        );
        codeChecker.assertByteCodeMatch(liquifierImpl, address(fresh2));
    }

    function _verifyGovernanceBytecode() internal {
        RoleRegistry fresh = new RoleRegistry(revokeAdminProxy);
        codeChecker.assertByteCodeMatch(roleRegistryImpl, address(fresh));

        EtherFiRateLimiter fresh2 = new EtherFiRateLimiter(ROLE_REGISTRY, EETH, WEETH);
        codeChecker.assertByteCodeMatch(etherFiRateLimiterImpl, address(fresh2));

        // Blacklister + RevokeAdmin are deployed as fresh proxy+impl pairs in this upgrade.
        // transactions.s.sol only tracks their proxies, so read each proxy's implementation from
        // its ERC1967 slot and verify that bytecode against a freshly-constructed instance.
        Blacklister fresh3 = new Blacklister(ROLE_REGISTRY);
        codeChecker.assertByteCodeMatch(getImplementation(blacklisterProxy), address(fresh3));

        RevokeAdmin fresh4 = new RevokeAdmin(ROLE_REGISTRY);
        codeChecker.assertByteCodeMatch(getImplementation(revokeAdminProxy), address(fresh4));
    }

    function _verifyMembershipBytecode() internal {
        MembershipManager fresh = new MembershipManager(
            EETH, LIQUIDITY_POOL, MEMBERSHIP_NFT, ROLE_REGISTRY, blacklisterProxy
        );
        codeChecker.assertByteCodeMatch(membershipManagerImpl, address(fresh));

        MembershipNFT fresh2 = new MembershipNFT(
            LIQUIDITY_POOL, MEMBERSHIP_MANAGER, ROLE_REGISTRY, blacklisterProxy
        );
        codeChecker.assertByteCodeMatch(membershipNFTImpl, address(fresh2));
    }

    function _verifyOracleBytecode() internal {
        EtherFiAdmin fresh = new EtherFiAdmin(
            IEtherFiAdmin.ConstructorAddresses({
                etherFiOracle: ETHERFI_ORACLE,
                stakingManager: STAKING_MANAGER,
                auctionManager: AUCTION_MANAGER,
                etherFiNodesManager: ETHERFI_NODES_MANAGER,
                liquidityPool: LIQUIDITY_POOL,
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
        codeChecker.assertByteCodeMatch(etherFiAdminImpl, address(fresh));

        EtherFiOracle fresh2 = new EtherFiOracle(ORACLE_MIN_QUORUM_SIZE, ETHERFI_ADMIN, ROLE_REGISTRY);
        codeChecker.assertByteCodeMatch(etherFiOracleImpl, address(fresh2));
    }

    function _verifyRestakingBytecode() internal {
        EtherFiRestaker fresh = new EtherFiRestaker(
            LIQUIDITY_POOL, LIQUIFIER, EIGENLAYER_REWARDS_COORDINATOR, ETHERFI_REDEMPTION_MANAGER,
            ROLE_REGISTRY, ETHERFI_RATE_LIMITER, EIGENLAYER_STRATEGY_MANAGER, EIGENLAYER_DELEGATION_MANAGER
        );
        codeChecker.assertByteCodeMatch(etherFiRestakerImpl, address(fresh));

        RestakingRewardsRouter fresh2 = new RestakingRewardsRouter(
            ROLE_REGISTRY, EIGEN, LIQUIDITY_POOL
        );
        codeChecker.assertByteCodeMatch(restakingRewardsRouterImpl, address(fresh2));
    }

    function _verifyRewardsBytecode() internal {
        CumulativeMerkleRewardsDistributor fresh = new CumulativeMerkleRewardsDistributor(ROLE_REGISTRY);
        codeChecker.assertByteCodeMatch(cumulativeMerkleRewardsDistributorImpl, address(fresh));

        EtherFiRewardsRouter fresh2 = new EtherFiRewardsRouter(LIQUIDITY_POOL, TREASURY, ROLE_REGISTRY);
        codeChecker.assertByteCodeMatch(etherFiRewardsRouterImpl, address(fresh2));
    }

    function _verifyStakingBytecode() internal {
        AuctionManager fresh = new AuctionManager(
            ROLE_REGISTRY, blacklisterProxy, NODE_OPERATOR_MANAGER, STAKING_MANAGER, TREASURY
        );
        codeChecker.assertByteCodeMatch(auctionManagerImpl, address(fresh));

        EtherFiNode fresh2 = new EtherFiNode(LIQUIDITY_POOL, ETHERFI_NODES_MANAGER, EIGENLAYER_POD_MANAGER, EIGENLAYER_DELEGATION_MANAGER);
        codeChecker.assertByteCodeMatch(etherFiNodeImpl, address(fresh2));

        EtherFiNodesManager fresh3 = new EtherFiNodesManager(STAKING_MANAGER, ROLE_REGISTRY, ETHERFI_RATE_LIMITER);
        codeChecker.assertByteCodeMatch(etherFiNodesManagerImpl, address(fresh3));

        NodeOperatorManager fresh4 = new NodeOperatorManager(ROLE_REGISTRY, AUCTION_MANAGER);
        codeChecker.assertByteCodeMatch(nodeOperatorManagerImpl, address(fresh4));

        StakingManager fresh5 = new StakingManager(
            LIQUIDITY_POOL, ETHERFI_NODES_MANAGER, ETH2_DEPOSIT_CONTRACT,
            AUCTION_MANAGER, ETHERFI_NODE_BEACON, ROLE_REGISTRY
        );
        codeChecker.assertByteCodeMatch(stakingManagerImpl, address(fresh5));
    }

    function _verifyWithdrawalsBytecode() internal {
        EtherFiRedemptionManager fresh = new EtherFiRedemptionManager(
            IEtherFiRedemptionManager.ConstructorAddresses({
                liquidityPool: LIQUIDITY_POOL,
                eEth: EETH,
                weEth: WEETH,
                treasury: TREASURY,
                roleRegistry: ROLE_REGISTRY,
                etherFiRestaker: ETHERFI_RESTAKER,
                priorityWithdrawalQueue: PRIORITY_WITHDRAWAL_QUEUE,
                blacklister: blacklisterProxy,
                stEthPriceFeed: STETH_PRICE_FEED
            }),
            RM_MAX_EXIT_FEE_SPLIT_TO_TREASURY_BPS, RM_MAX_EXIT_FEE_BPS, RM_MAX_LOW_WATERMARK_BPS_OF_TVL,
            RM_STALE_PRICE_WINDOW, RM_MAX_PRICE_THRESHOLD
        );
        codeChecker.assertByteCodeMatch(etherFiRedemptionManagerImpl, address(fresh));

        PriorityWithdrawalQueue fresh2 = new PriorityWithdrawalQueue(
            LIQUIDITY_POOL, EETH, WEETH, blacklisterProxy, ROLE_REGISTRY, PWQ_MIN_DELAY
        );
        codeChecker.assertByteCodeMatch(priorityWithdrawalQueueImpl, address(fresh2));

        WeETHWithdrawAdapter fresh3 = new WeETHWithdrawAdapter(
            WEETH, EETH, LIQUIDITY_POOL, ROLE_REGISTRY, blacklisterProxy
        );
        codeChecker.assertByteCodeMatch(weETHWithdrawAdapterImpl, address(fresh3));

        WithdrawRequestNFT fresh4 = new WithdrawRequestNFT(
            LIQUIDITY_POOL, ROLE_REGISTRY, blacklisterProxy, ETHERFI_ADMIN
        );
        codeChecker.assertByteCodeMatch(withdrawRequestNFTImpl, address(fresh4));
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
        // core
        preImm[EETH]                       = _safeSnapshot(EETH,                       _eethImmSels());
        preImm[LIQUIDITY_POOL]             = _safeSnapshot(LIQUIDITY_POOL,             _lpImmSels());
        preImm[WEETH]                      = _safeSnapshot(WEETH,                      _weethImmSels());
        // deposits
        preImm[DEPOSIT_ADAPTER]            = _safeSnapshot(DEPOSIT_ADAPTER,            _depositAdapterImmSels());
        preImm[LIQUIFIER]                  = _safeSnapshot(LIQUIFIER,                  _liquifierImmSels());
        // governance
        preImm[ETHERFI_RATE_LIMITER]       = _safeSnapshot(ETHERFI_RATE_LIMITER,       _rateLimiterImmSels());
        // membership
        preImm[MEMBERSHIP_MANAGER]         = _safeSnapshot(MEMBERSHIP_MANAGER,         _mmImmSels());
        preImm[MEMBERSHIP_NFT]             = _safeSnapshot(MEMBERSHIP_NFT,             _mnftImmSels());
        // oracle
        preImm[ETHERFI_ADMIN]              = _safeSnapshot(ETHERFI_ADMIN,              _adminImmSels());
        preImm[ETHERFI_ORACLE]             = _safeSnapshot(ETHERFI_ORACLE,             _oracleImmSels());
        // restaking
        preImm[ETHERFI_RESTAKER]           = _safeSnapshot(ETHERFI_RESTAKER,           _restakerImmSels());
        preImm[RESTAKING_REWARDS_ROUTER]   = _safeSnapshot(RESTAKING_REWARDS_ROUTER,   _restakingRewardsRouterImmSels());
        // rewards
        preImm[CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR]  = _safeSnapshot(CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR,  _cmrdImmSels());
        preImm[ETHERFI_REWARDS_ROUTER]     = _safeSnapshot(ETHERFI_REWARDS_ROUTER,     _rewardsRouterImmSels());
        // staking
        preImm[AUCTION_MANAGER]            = _safeSnapshot(AUCTION_MANAGER,            _auctionImmSels());
        preImm[ETHERFI_NODES_MANAGER]      = _safeSnapshot(ETHERFI_NODES_MANAGER,      _nodesMgrImmSels());
        preImm[NODE_OPERATOR_MANAGER]      = _safeSnapshot(NODE_OPERATOR_MANAGER,      _nodeOpImmSels());
        preImm[STAKING_MANAGER]            = _safeSnapshot(STAKING_MANAGER,            _stakingMgrImmSels());
        // withdrawals
        preImm[ETHERFI_REDEMPTION_MANAGER] = _safeSnapshot(ETHERFI_REDEMPTION_MANAGER, _redemptionImmSels());
        preImm[PRIORITY_WITHDRAWAL_QUEUE]  = _safeSnapshot(PRIORITY_WITHDRAWAL_QUEUE,  _pwqImmSels());
        preImm[WEETH_WITHDRAW_ADAPTER]     = _safeSnapshot(WEETH_WITHDRAW_ADAPTER,     _weethWithdrawAdapterImmSels());
        preImm[WITHDRAW_REQUEST_NFT]       = _safeSnapshot(WITHDRAW_REQUEST_NFT,       _nftImmSels());

        console2.log("[OK] snapshotted owner + paused + immutable getters for", proxies.length, "proxies");
        console2.log("");
    }

    /// @dev Forwarded eigenpod-call selectors to migrate; shared by the batch builder and verifier.
    function _forwardedEigenpodSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = SEL_START_CHECKPOINT;
        s[1] = SEL_VERIFY_CHECKPOINT_PROOFS;
        s[2] = SEL_VERIFY_WITHDRAWAL_CREDENTIALS;
    }

    /// @dev Forwarded external-call (selector,target) pairs to migrate.
    function _forwardedExternalCalls() internal pure returns (bytes4[] memory s, address[] memory t) {
        s = new bytes4[](1);
        t = new address[](1);
        (s[0], t[0]) = (SEL_PROCESS_CLAIM, EIGENLAYER_REWARDS_COORDINATOR);
    }

    /// @dev forwardExternalCall (selector,target) pairs newly whitelisted in 3CP #580. Grant-only to
    ///      the new holder; the legacy caller's copies are revoked in a later 3CP.
    function _grantOnlyExternalCalls() internal pure returns (bytes4[] memory s, address[] memory t) {
        s = new bytes4[](3);
        t = new address[](3);
        (s[0], t[0]) = (SEL_QUEUE_WITHDRAWALS,           EIGENLAYER_DELEGATION_MANAGER);
        (s[1], t[1]) = (SEL_COMPLETE_QUEUED_WITHDRAWALS, EIGENLAYER_DELEGATION_MANAGER);
        (s[2], t[2]) = (SEL_COMPLETE_QUEUED_WITHDRAWAL,  EIGENLAYER_DELEGATION_MANAGER);
    }

    /// @dev Capture `staticcall` returns for every selector; silently skip the
    ///      ones that revert (e.g. immutable getters that didn't exist on the
    ///      old impl). Only the surviving selectors get diffed in step 6.
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
    // core
    function _eethImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = bytes4(keccak256("liquidityPool()"));
        s[1] = bytes4(keccak256("roleRegistry()"));
        s[2] = bytes4(keccak256("blacklister()"));
        s[3] = bytes4(keccak256("rateLimiter()"));
    }
    function _lpImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](11);
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
    }
    function _weethImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = bytes4(keccak256("eETH()"));
        s[1] = bytes4(keccak256("liquidityPool()"));
        s[2] = bytes4(keccak256("roleRegistry()"));
        s[3] = bytes4(keccak256("blacklister()"));
        s[4] = bytes4(keccak256("rateLimiter()"));
    }
    // deposits
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
    // governance
    function _rateLimiterImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = bytes4(keccak256("eETH()"));
        s[1] = bytes4(keccak256("weETH()"));
        s[2] = bytes4(keccak256("roleRegistry()"));
    }
    // membership
    function _mmImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = bytes4(keccak256("eETH()"));
        s[1] = bytes4(keccak256("liquidityPool()"));
        s[2] = bytes4(keccak256("membershipNFT()"));
        s[3] = bytes4(keccak256("roleRegistry()"));
        s[4] = bytes4(keccak256("blacklister()"));
    }
    function _mnftImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = bytes4(keccak256("liquidityPool()"));
        s[1] = bytes4(keccak256("membershipManager()"));
        s[2] = bytes4(keccak256("roleRegistry()"));
        s[3] = bytes4(keccak256("blacklister()"));
    }
    // oracle
    function _adminImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](14);
        s[0]  = bytes4(keccak256("etherFiOracle()"));
        s[1]  = bytes4(keccak256("stakingManager()"));
        s[2]  = bytes4(keccak256("auctionManager()"));
        s[3]  = bytes4(keccak256("etherFiNodesManager()"));
        s[4]  = bytes4(keccak256("liquidityPool()"));
        s[5]  = bytes4(keccak256("withdrawRequestNft()"));
        s[6]  = bytes4(keccak256("roleRegistry()"));
        s[7]  = bytes4(keccak256("priorityWithdrawalQueue()"));
        s[8]  = bytes4(keccak256("maxAcceptableRebaseAprInBps()"));
        s[9]  = bytes4(keccak256("maxValidatorTaskBatchSize()"));
        s[10] = bytes4(keccak256("maxAcceptableFinalizedWithdrawalAmountPerDay()"));
        s[11] = bytes4(keccak256("maxAcceptableNumValidatorsToApprovePerDay()"));
        s[12] = bytes4(keccak256("staleOracleReportBlockWindow()"));
        s[13] = bytes4(keccak256("maxNumberOfRequestsToFinalizePerReport()"));
    }
    function _oracleImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = bytes4(keccak256("etherFiAdmin()"));
        s[1] = bytes4(keccak256("roleRegistry()"));
        s[2] = bytes4(keccak256("minQuorumSize()"));
    }
    // restaking
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
    function _restakingRewardsRouterImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = bytes4(keccak256("liquidityPool()"));
        s[1] = bytes4(keccak256("rewardTokenAddress()"));
        s[2] = bytes4(keccak256("roleRegistry()"));
    }
    // rewards
    function _cmrdImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = bytes4(keccak256("roleRegistry()"));
    }
    function _rewardsRouterImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = bytes4(keccak256("treasury()"));
        s[1] = bytes4(keccak256("liquidityPool()"));
        s[2] = bytes4(keccak256("roleRegistry()"));
    }
    // staking
    function _auctionImmSels() internal pure returns (bytes4[] memory s) {
        // membershipManagerContractAddress() was removed by the new AuctionManager impl
        // and is no longer in the post-upgrade selector set. Excluded so _postSnap's
        // strict re-call doesn't revert on it.
        s = new bytes4[](5);
        s[0] = bytes4(keccak256("roleRegistry()"));
        s[1] = bytes4(keccak256("blacklister()"));
        s[2] = bytes4(keccak256("nodeOperatorManager()"));
        s[3] = bytes4(keccak256("stakingManagerContractAddress()"));
        s[4] = bytes4(keccak256("treasury()"));
    }
    function _nodesMgrImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = bytes4(keccak256("stakingManager()"));
        s[1] = bytes4(keccak256("roleRegistry()"));
        s[2] = bytes4(keccak256("rateLimiter()"));
    }
    function _nodeOpImmSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = bytes4(keccak256("auctionManagerContractAddress()"));
        s[1] = bytes4(keccak256("roleRegistry()"));
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
    // withdrawals
    function _redemptionImmSels() internal pure returns (bytes4[] memory s) {
        // treasury() intentionally CHANGES in this upgrade (live buyback-safe -> TREASURY), so it
        // is excluded from the preservation diff; the new value is asserted in _verifyImmutablesWithdrawals.
        s = new bytes4[](11);
        s[0]  = bytes4(keccak256("roleRegistry()"));
        s[1]  = bytes4(keccak256("eEth()"));
        s[2]  = bytes4(keccak256("weEth()"));
        s[3]  = bytes4(keccak256("liquidityPool()"));
        s[4]  = bytes4(keccak256("etherFiRestaker()"));
        s[5]  = bytes4(keccak256("lido()"));
        s[6]  = bytes4(keccak256("priorityWithdrawalQueue()"));
        s[7]  = bytes4(keccak256("blacklister()"));
        s[8]  = bytes4(keccak256("maxExitFeeSplitToTreasuryInBps()"));
        s[9]  = bytes4(keccak256("maxExitFeeInBps()"));
        s[10] = bytes4(keccak256("maxLowWatermarkInBpsOfTvl()"));
    }
    function _pwqImmSels() internal pure returns (bytes4[] memory s) {
        // treasury() removed: the new PriorityWithdrawalQueue constructor no longer takes a
        // treasury/buyback address (intentional removal in this upgrade).
        s = new bytes4[](6);
        s[0] = bytes4(keccak256("liquidityPool()"));
        s[1] = bytes4(keccak256("eETH()"));
        s[2] = bytes4(keccak256("weETH()"));
        s[3] = bytes4(keccak256("minDelay()"));
        s[4] = bytes4(keccak256("roleRegistry()"));
        // blacklister immutable added by this PR; skipped pre-upgrade by _safeSnapshot
        s[5] = bytes4(keccak256("blacklister()"));
    }
    function _weethWithdrawAdapterImmSels() internal pure returns (bytes4[] memory s) {
        // withdrawRequestNFT() removed: the new WeETHWithdrawAdapter constructor no longer
        // takes a withdrawRequestNFT address (intentional removal in this upgrade).
        s = new bytes4[](5);
        s[0] = bytes4(keccak256("weETH()"));
        s[1] = bytes4(keccak256("eETH()"));
        s[2] = bytes4(keccak256("liquidityPool()"));
        s[3] = bytes4(keccak256("blacklister()"));
        s[4] = bytes4(keccak256("roleRegistry()"));
    }
    function _nftImmSels() internal pure returns (bytes4[] memory s) {
        // treasury() and eETH() removed: the new WithdrawRequestNFT constructor is
        // (liquidityPool, roleRegistry, blacklister, etherFiAdmin) — no treasury/buyback or eETH.
        s = new bytes4[](4);
        s[0] = bytes4(keccak256("liquidityPool()"));
        s[1] = bytes4(keccak256("roleRegistry()"));
        s[2] = bytes4(keccak256("blacklister()"));
        s[3] = bytes4(keccak256("etherFiAdmin()"));
    }

    function _upgradedProxies() internal pure returns (address[22] memory list) {
        // core
        list[0]  = EETH;
        list[1]  = LIQUIDITY_POOL;
        list[2]  = WEETH;
        // deposits
        list[3]  = DEPOSIT_ADAPTER;
        list[4]  = LIQUIFIER;
        // governance
        list[5]  = ETHERFI_RATE_LIMITER;
        // membership
        list[6]  = MEMBERSHIP_MANAGER;
        list[7]  = MEMBERSHIP_NFT;
        // oracle
        list[8]  = ETHERFI_ADMIN;
        list[9]  = ETHERFI_ORACLE;
        // restaking
        list[10] = ETHERFI_RESTAKER;
        list[11] = RESTAKING_REWARDS_ROUTER;
        // rewards
        list[12] = CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR;
        list[13] = ETHERFI_REWARDS_ROUTER;
        // staking
        list[14] = AUCTION_MANAGER;
        list[15] = ETHERFI_NODES_MANAGER;
        list[16] = NODE_OPERATOR_MANAGER;
        list[17] = STAKING_MANAGER;
        // withdrawals
        list[18] = ETHERFI_REDEMPTION_MANAGER;
        list[19] = PRIORITY_WITHDRAWAL_QUEUE;
        list[20] = WEETH_WITHDRAW_ADAPTER;
        list[21] = WITHDRAW_REQUEST_NFT;
    }

    //--------------------------------------------------------------------------------------
    // STEP 2.5: executeAuctionSweep — Batch 0, the OPERATION_MULTISIG pre-upgrade sweep (instant)
    //
    // MUST run BEFORE the upgrade batch executes. The currently-deployed AuctionManager
    // accrues consumed-bid fees in the `accumulatedRevenue` storage slot and only flushes
    // them to the MembershipManager once they cross `accumulatedRevenueThreshold`
    // (`transferAccumulatedRevenue()`). The NEW AuctionManager impl deletes that slot (now a
    // deprecated `__gap`) and forwards each bid's revenue directly to `treasury` — it has no
    // `transferAccumulatedRevenue` and no path to move the residual. Any un-flushed
    // `accumulatedRevenue` ETH would therefore be stranded in the proxy balance post-upgrade.
    // So we flush it first, on the OLD impl, while the function still exists.
    //
    // `transferAccumulatedRevenue()` is `onlyAdmin` on the OLD impl, where `onlyAdmin` checks
    // the legacy `admins[msg.sender]` mapping (NOT a RoleRegistry role). On mainnet
    // ETHERFI_OPERATING_ADMIN (0x2aCA…) has `admins[..] == true`, so this single tx is
    // broadcast directly from that Safe (no timelock). One JSON, executed first of all.
    //
    // The call is built via abi.encodeWithSignature because the NEW AuctionManager type
    // (imported here) no longer declares transferAccumulatedRevenue().
    //--------------------------------------------------------------------------------------
    function executeAuctionSweep() public {
        console2.log("=== Step 2.5: Executing AuctionManager Sweep (Batch 0, OPERATION_MULTISIG, instant, PRE-UPGRADE) ===");

        bytes memory sweepData = abi.encodeWithSignature("transferAccumulatedRevenue()");

        writeSafeJson(OUT_DIR, "auction_sweep.json", ETHERFI_OPERATING_ADMIN, AUCTION_MANAGER, 0, sweepData, 1);

        console2.log("=== Dry-running AuctionManager sweep on fork (OLD impl, pre-upgrade) ===");
        uint256 pendingBefore = _auctionAccumulatedRevenue();
        uint256 mmBalBefore   = MEMBERSHIP_MANAGER.balance;
        console2.log("accumulatedRevenue (wei) to flush:   ", pendingBefore);

        vm.prank(ETHERFI_OPERATING_ADMIN);
        (bool ok, ) = AUCTION_MANAGER.call(sweepData);
        require(ok, "auction sweep: transferAccumulatedRevenue reverted");

        require(_auctionAccumulatedRevenue() == 0, "auction sweep: accumulatedRevenue not zeroed");
        require(MEMBERSHIP_MANAGER.balance == mmBalBefore + pendingBefore, "auction sweep: MembershipManager did not receive flushed revenue");

        console2.log("[OK] AuctionManager accumulatedRevenue flushed to MembershipManager");
        console2.log("");
    }

    /// @dev Read the OLD AuctionManager's `accumulatedRevenue` via low-level staticcall, since
    ///      the NEW AuctionManager type imported by this script no longer declares it.
    function _auctionAccumulatedRevenue() internal view returns (uint256) {
        (bool ok, bytes memory ret) = AUCTION_MANAGER.staticcall(abi.encodeWithSignature("accumulatedRevenue()"));
        require(ok && ret.length >= 32, "auction sweep: accumulatedRevenue() read failed");
        return abi.decode(ret, (uint256));
    }

    //--------------------------------------------------------------------------------------
    // STEP 3: executeUpgrade — the single UPGRADE_TIMELOCK batch (10d)
    //
    // ONE atomic batch, executed by the UPGRADE_TIMELOCK, in this exact order:
    //   1. grant the 9 RolesLibrary roles + 6 extra (operating multisig gets all RevokeAdmin
    //      roles) + 2 (exec guardian safe gets GUARDIAN + SUPER_GUARDIAN) = 17 grants
    //      (grantRole is owner-gated; owner == UPGRADE_TIMELOCK)
    //   2. upgrade every proxy + the EtherFiNode beacon (gated by OLD RR.onlyProtocolUpgrader = owner check)
    //   3. swap RoleRegistry impl                       (gated by OLD RR._authorizeUpgrade = onlyOwner)
    //   4. run the two onlyUpgradeTimelock one-shot initializers (gated by NEW RR.onlyUpgradeTimelock)
    //   4b. unwhitelist cbETH + wBETH on Liquifier (onlyUpgradeTimelock; EARN-1421)
    //   5. revoke every holder of the 31 legacy roles  (revokeRole is owner-gated; works on either RR impl)
    //
    // Grants come first so UPGRADE_TIMELOCK already holds UPGRADE_TIMELOCK_ROLE before the
    // initializers run. Proxy upgrades come BEFORE the RR swap because OLD proxy impls gate
    // `_authorizeUpgrade` via `roleRegistry.onlyProtocolUpgrader(msg.sender)`, which the
    // NEW RoleRegistry does not implement — swapping RR first would brick every subsequent
    // upgradeTo with an unknown-selector revert. See _appendUpgradeCalls for full rationale.
    //--------------------------------------------------------------------------------------
    function executeUpgrade() public {
        console2.log("=== Step 3: Executing Upgrade Timelock Batch (grants -> proxy upgrades -> RR swap -> initializers -> legacy revokes, UPGRADE_TIMELOCK, 10d) ===");

        uint256 revokeCount = _countLegacyRoleHolders();

        // 18 grants (9 HOLDER_* + 6 operating-multisig RevokeAdmin roles + 2 exec guardian safe
        // + 1 UPGRADE_TIMELOCK CANCELLER_ROLE) + (21 UUPS upgrades + 1 transparent (L1SyncPool via
        // ProxyAdmin) + 1 beacon + 1 RR swap + 2 initializers + 2 Liquifier token unwhitelists) = 46,
        // <=50 headroom + N legacy revokes.
        address[] memory targets = new address[](50 + revokeCount);
        bytes[]   memory data    = new bytes[](50 + revokeCount);
        uint256[] memory values  = new uint256[](50 + revokeCount);
        uint256 i;

        i = _appendGrantCalls(targets, data, i);        // 1. role grants
        i = _appendUpgradeCalls(targets, data, i);      // 2-4. proxy upgrades -> RR swap -> initializers
        i = _appendLegacyRevokeCalls(targets, data, i); // 5. legacy role revocations

        console2.log("Upgrade-timelock batch op count (incl legacy revokes):", i);

        _shrinkAndEmit(
            BatchEmit({
                label: "Upgrade Timelock Batch",
                timelock: upgradeTimelock,
                timelockAddr: UPGRADE_TIMELOCK,
                adminSafe: ETHERFI_UPGRADE_ADMIN,
                minDelay: UPGRADE_TIMELOCK_DELAY,
                salt: keccak256(abi.encode("batch-1", commitHashSalt)),
                scheduleFile: "upgrade_schedule.json",
                executeFile: "upgrade_execute.json"
            }),
            targets, values, data, i
        );
    }

    /// @dev Append the proxy/beacon upgrades, then the RoleRegistry impl swap, then the
    ///      two onlyUpgradeTimelock one-shot initializers. Returns the updated write index.
    ///
    /// ORDERING RATIONALE (see C1 in PR #420 review):
    ///   The currently-deployed proxy impls gate `_authorizeUpgrade` via
    ///   `roleRegistry.onlyProtocolUpgrader(msg.sender)`, which on the OLD RoleRegistry
    ///   is a simple `owner() == account` check. The OLD RR's owner is the UPGRADE_TIMELOCK
    ///   executing this batch, so all 21 proxy upgrades + the beacon upgrade pass against
    ///   the OLD RR.
    ///   The NEW RoleRegistry impl drops `onlyProtocolUpgrader` and exposes
    ///   `onlyUpgradeTimelock` instead. If we swapped RR first, every subsequent
    ///   `upgradeTo` call would revert with an unknown-selector fallback on the new RR.
    ///   The 2 onlyUpgradeTimelock initializers (LP.initializeOnUpgradeV2,
    ///   WRN.initializeShareRateFreezeUpgrade) are functions on the NEW impls whose
    ///   modifier calls `roleRegistry.onlyUpgradeTimelock(msg.sender)`, so they need the
    ///   NEW RR live. Hence the order: proxy upgrades → RR swap → initializers.
    ///   Legacy revokes come after this function (still in the same batch); they're
    ///   owner-gated (Solady setRole), and owner stays UPGRADE_TIMELOCK across the swap.
    function _appendUpgradeCalls(address[] memory targets, bytes[] memory data, uint256 i)
        internal
        pure
        returns (uint256)
    {
        // ─── Phase A: 21 UUPS proxy upgrades + 1 beacon upgrade ─────────────────────────
        // All gated by the OLD impls' `_authorizeUpgrade`, which on master/main calls
        // `roleRegistry.onlyProtocolUpgrader(msg.sender)` → OLD RR `owner() == msg.sender`
        // → UPGRADE_TIMELOCK. Passes.

        // core
        (targets[i], data[i]) = (EETH,                       _upgradeTo(eEthImpl));                   i++;
        (targets[i], data[i]) = (LIQUIDITY_POOL,             _upgradeTo(liquidityPoolImpl));          i++;
        (targets[i], data[i]) = (WEETH,                      _upgradeTo(weEthImpl));                  i++;
        // deposits
        (targets[i], data[i]) = (DEPOSIT_ADAPTER,                       _upgradeTo(depositAdapterImpl));                     i++;
        (targets[i], data[i]) = (LIQUIFIER,                  _upgradeTo(liquifierImpl));              i++;
        // governance (RoleRegistry swap is deferred to Phase B below)
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER,       _upgradeTo(etherFiRateLimiterImpl));     i++;
        // membership
        (targets[i], data[i]) = (MEMBERSHIP_MANAGER,         _upgradeTo(membershipManagerImpl));      i++;
        (targets[i], data[i]) = (MEMBERSHIP_NFT,             _upgradeTo(membershipNFTImpl));          i++;
        // oracle
        (targets[i], data[i]) = (ETHERFI_ADMIN,              _upgradeTo(etherFiAdminImpl));           i++;
        (targets[i], data[i]) = (ETHERFI_ORACLE,             _upgradeTo(etherFiOracleImpl));          i++;
        // restaking
        (targets[i], data[i]) = (ETHERFI_RESTAKER,           _upgradeTo(etherFiRestakerImpl));        i++;
        (targets[i], data[i]) = (RESTAKING_REWARDS_ROUTER,              _upgradeTo(restakingRewardsRouterImpl));             i++;
        // rewards
        (targets[i], data[i]) = (CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR, _upgradeTo(cumulativeMerkleRewardsDistributorImpl)); i++;
        (targets[i], data[i]) = (ETHERFI_REWARDS_ROUTER,                _upgradeTo(etherFiRewardsRouterImpl));               i++;
        // staking
        (targets[i], data[i]) = (AUCTION_MANAGER,            _upgradeTo(auctionManagerImpl));         i++;

        // EtherFiNode is a beacon proxy, not UUPS. Upgrade it via the beacon owner
        // (the StakingManager) using upgradeEtherFiNode, which is gated by the same
        // UPGRADE_TIMELOCK authority executing this batch. Done before the StakingManager
        // proxy swap so it runs against the current impl's upgrade gate.
        (targets[i], data[i]) = (STAKING_MANAGER,
            abi.encodeWithSelector(StakingManager.upgradeEtherFiNode.selector, etherFiNodeImpl));     i++;
        (targets[i], data[i]) = (ETHERFI_NODES_MANAGER,      _upgradeTo(etherFiNodesManagerImpl));    i++;
        (targets[i], data[i]) = (NODE_OPERATOR_MANAGER,      _upgradeTo(nodeOperatorManagerImpl));    i++;
        (targets[i], data[i]) = (STAKING_MANAGER,            _upgradeTo(stakingManagerImpl));         i++;
        // withdrawals
        (targets[i], data[i]) = (ETHERFI_REDEMPTION_MANAGER, _upgradeTo(etherFiRedemptionManagerImpl)); i++;
        (targets[i], data[i]) = (PRIORITY_WITHDRAWAL_QUEUE,             _upgradeTo(priorityWithdrawalQueueImpl));            i++;
        (targets[i], data[i]) = (WEETH_WITHDRAW_ADAPTER,                _upgradeTo(weETHWithdrawAdapterImpl));               i++;
        (targets[i], data[i]) = (WITHDRAW_REQUEST_NFT,       _upgradeTo(withdrawRequestNFTImpl));     i++;

        // cross-chain — EtherfiL1SyncPoolETH (WeETH-cross-chain repo, PR #77: adds PausableUntil).
        // UNLIKE every entry above, this proxy is an OZ5 TransparentUpgradeableProxy, NOT UUPS: it
        // has no `upgradeTo`, so the upgrade goes through its ProxyAdmin via
        // upgradeAndCall(proxy, impl, "") rather than a self-call. ProxyAdmin.upgradeAndCall is
        // `onlyOwner`, so this requires the ProxyAdmin owner to be UPGRADE_TIMELOCK at execution.
        // PRECONDITION: the owner is currently ETHERFI_OPERATING_ADMIN — the operating multisig must
        // transferOwnership(UPGRADE_TIMELOCK) before this batch is scheduled, else the batch reverts.
        // Independent of the RR-swap ordering (ProxyAdmin-owner-gated, not roleRegistry-gated).
        (targets[i], data[i]) = (L1_SYNC_POOL_PROXY_ADMIN,
            _upgradeTransparent(ETHERFI_L1_SYNC_POOL_ETH, l1SyncPoolImpl));                            i++;

        // ─── Phase B: RoleRegistry impl swap ─────────────────────────────────────────────
        // Run AFTER every other upgradeTo so those upgrades resolve against the OLD RR's
        // `onlyProtocolUpgrader` (owner-check). The OLD RR's own `_authorizeUpgrade` is
        // `onlyOwner` → UPGRADE_TIMELOCK, so this swap is authorized.
        // After this, all future `_authorizeUpgrade` calls and the initializers below
        // resolve against the NEW RR's `onlyUpgradeTimelock` → UPGRADE_TIMELOCK_ROLE,
        // which was granted in step 1 (_appendGrantCalls).
        (targets[i], data[i]) = (ROLE_REGISTRY,              _upgradeTo(roleRegistryImpl));           i++;

        // ─── Phase C: post-upgrade one-shot initializers ─────────────────────────────────
        // onlyUpgradeTimelock on the NEW impls → needs NEW RR + UPGRADE_TIMELOCK_ROLE,
        // both delivered by Phase B and step 1 respectively.
        (targets[i], data[i]) = (LIQUIDITY_POOL,
            abi.encodeWithSelector(LiquidityPool.initializeOnUpgradeV2.selector));                    i++;
        (targets[i], data[i]) = (WITHDRAW_REQUEST_NFT,
            abi.encodeWithSelector(WithdrawRequestNFT.initializeShareRateFreezeUpgrade.selector));    i++;

        // ─── Phase D: unwhitelist deprecated Liquifier deposit tokens (EARN-1421) ─────────
        // cbETH + wBETH (bETH) are no longer supported LSTs. updateWhitelistedToken is
        // onlyUpgradeTimelock on the (now-upgraded) Liquifier impl → gated by NEW RR's
        // onlyUpgradeTimelock → UPGRADE_TIMELOCK_ROLE (granted in step 1), so it rides this
        // batch after Phase A (Liquifier proxy upgrade) and Phase B (RR swap). Blocks all
        // future cbETH/wBETH deposits (depositWithERC20 reverts on !isTokenWhitelisted).
        (targets[i], data[i]) = (LIQUIFIER,
            abi.encodeWithSelector(Liquifier.updateWhitelistedToken.selector, CBETH, false));         i++;
        (targets[i], data[i]) = (LIQUIFIER,
            abi.encodeWithSelector(Liquifier.updateWhitelistedToken.selector, WBETH, false));         i++;

        return i;
    }

    //--------------------------------------------------------------------------------------
    // STEP 4: verifyUpgrades
    //--------------------------------------------------------------------------------------
    function verifyUpgrades() public view {
        console2.log("=== Step 4: Verifying Upgrades ===");
        // core
        _assertImpl(EETH,                       eEthImpl,                     "EETH");
        _assertImpl(LIQUIDITY_POOL,             liquidityPoolImpl,            "LiquidityPool");
        _assertImpl(WEETH,                      weEthImpl,                    "WeETH");
        // deposits
        _assertImpl(DEPOSIT_ADAPTER,                       depositAdapterImpl,                     "DepositAdapter");
        _assertImpl(LIQUIFIER,                  liquifierImpl,                "Liquifier");
        // governance
        _assertImpl(ROLE_REGISTRY,              roleRegistryImpl,             "RoleRegistry");
        require(roleRegistry.revokeAdmin() == revokeAdminProxy, "RoleRegistry.revokeAdmin != revokeAdminProxy");
        _assertImpl(ETHERFI_RATE_LIMITER,       etherFiRateLimiterImpl,        "EtherFiRateLimiter");
        // membership
        _assertImpl(MEMBERSHIP_MANAGER,         membershipManagerImpl,        "MembershipManager");
        _assertImpl(MEMBERSHIP_NFT,             membershipNFTImpl,            "MembershipNFT");
        // oracle
        _assertImpl(ETHERFI_ADMIN,              etherFiAdminImpl,             "EtherFiAdmin");
        _assertImpl(ETHERFI_ORACLE,             etherFiOracleImpl,            "EtherFiOracle");
        // restaking
        _assertImpl(ETHERFI_RESTAKER,           etherFiRestakerImpl,          "EtherFiRestaker");
        _assertImpl(RESTAKING_REWARDS_ROUTER,              restakingRewardsRouterImpl,             "RestakingRewardsRouter");
        // rewards
        _assertImpl(CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR, cumulativeMerkleRewardsDistributorImpl, "CumulativeMerkleRewardsDistributor");
        _assertImpl(ETHERFI_REWARDS_ROUTER,                etherFiRewardsRouterImpl,               "EtherFiRewardsRouter");
        // staking
        _assertImpl(AUCTION_MANAGER,            auctionManagerImpl,           "AuctionManager");
        // EtherFiNode beacon: implementation lives on the beacon, read via StakingManager.
        require(StakingManager(STAKING_MANAGER).implementation() == etherFiNodeImpl, "EtherFiNode: beacon implementation mismatch");
        _assertImpl(ETHERFI_NODES_MANAGER,      etherFiNodesManagerImpl,      "EtherFiNodesManager");
        _assertImpl(NODE_OPERATOR_MANAGER,      nodeOperatorManagerImpl,      "NodeOperatorManager");
        _assertImpl(STAKING_MANAGER,            stakingManagerImpl,           "StakingManager");
        // withdrawals
        _assertImpl(ETHERFI_REDEMPTION_MANAGER, etherFiRedemptionManagerImpl, "EtherFiRedemptionManager");
        _assertImpl(PRIORITY_WITHDRAWAL_QUEUE,             priorityWithdrawalQueueImpl,            "PriorityWithdrawalQueue");
        _assertImpl(WEETH_WITHDRAW_ADAPTER,                weETHWithdrawAdapterImpl,               "WeETHWithdrawAdapter");
        _assertImpl(WITHDRAW_REQUEST_NFT,       withdrawRequestNFTImpl,       "WithdrawRequestNFT");
        // cross-chain — same ERC1967 impl slot read works for the transparent proxy too.
        _assertImpl(ETHERFI_L1_SYNC_POOL_ETH,   l1SyncPoolImpl,               "EtherfiL1SyncPoolETH");
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
        // core
        _diffPreserved(EETH,                       "EETH");
        _diffPreserved(LIQUIDITY_POOL,             "LiquidityPool");
        _diffPreserved(WEETH,                      "WeETH");
        // deposits
        _diffPreserved(DEPOSIT_ADAPTER,                       "DepositAdapter");
        _diffPreserved(LIQUIFIER,                  "Liquifier");
        // governance
        _diffPreserved(ETHERFI_RATE_LIMITER,       "EtherFiRateLimiter");
        // membership
        _diffPreserved(MEMBERSHIP_MANAGER,         "MembershipManager");
        _diffPreserved(MEMBERSHIP_NFT,             "MembershipNFT");
        // oracle
        _diffPreserved(ETHERFI_ADMIN,              "EtherFiAdmin");
        _diffPreserved(ETHERFI_ORACLE,             "EtherFiOracle");
        // restaking
        _diffPreserved(ETHERFI_RESTAKER,           "EtherFiRestaker");
        _diffPreserved(RESTAKING_REWARDS_ROUTER,              "RestakingRewardsRouter");
        // rewards
        _diffPreserved(CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR, "CumulativeMerkleRewardsDistributor");
        _diffPreserved(ETHERFI_REWARDS_ROUTER,                "EtherFiRewardsRouter");
        // staking
        _diffPreserved(AUCTION_MANAGER,            "AuctionManager");
        _diffPreserved(ETHERFI_NODES_MANAGER,      "EtherFiNodesManager");
        _diffPreserved(NODE_OPERATOR_MANAGER,      "NodeOperatorManager");
        _diffPreserved(STAKING_MANAGER,            "StakingManager");
        // withdrawals
        _diffPreserved(ETHERFI_REDEMPTION_MANAGER, "EtherFiRedemptionManager");
        _diffPreserved(PRIORITY_WITHDRAWAL_QUEUE,             "PriorityWithdrawalQueue");
        _diffPreserved(WEETH_WITHDRAW_ADAPTER,                "WeETHWithdrawAdapter");
        _diffPreserved(WITHDRAW_REQUEST_NFT,       "WithdrawRequestNFT");

        // (b) post vs deployment-time expected
        _verifyImmutablesCore();
        _verifyImmutablesDeposits();
        _verifyImmutablesGovernance();
        _verifyImmutablesMembership();
        _verifyImmutablesOracle();
        _verifyImmutablesRestaking();
        _verifyImmutablesRewards();
        _verifyImmutablesStaking();
        _verifyImmutablesWithdrawals();
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

    function _verifyImmutablesCore() internal view {
        EETHToken e = EETHToken(EETH);
        require(address(e.liquidityPool()) == LIQUIDITY_POOL,  "EETH.liquidityPool");
        require(address(e.roleRegistry())  == ROLE_REGISTRY,   "EETH.roleRegistry");
        require(address(e.blacklister())   == blacklisterProxy,"EETH.blacklister");
        require(address(e.rateLimiter())   == ETHERFI_RATE_LIMITER, "EETH.rateLimiter");

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

        WeETHToken w = WeETHToken(WEETH);
        require(address(w.eETH())          == EETH,            "WeETH.eETH");
        require(address(w.liquidityPool()) == LIQUIDITY_POOL,  "WeETH.liquidityPool");
        require(address(w.roleRegistry())  == ROLE_REGISTRY,   "WeETH.roleRegistry");
        require(address(w.blacklister())   == blacklisterProxy,"WeETH.blacklister");
    }

    function _verifyImmutablesDeposits() internal view {
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

    function _verifyImmutablesGovernance() internal view {
        EtherFiRateLimiter rl = EtherFiRateLimiter(payable(ETHERFI_RATE_LIMITER));
        require(rl.eETH()                   == EETH,          "RateLimiter.eETH");
        require(rl.weETH()                  == WEETH,         "RateLimiter.weETH");
        require(address(rl.roleRegistry())  == ROLE_REGISTRY, "RateLimiter.roleRegistry");
    }

    function _verifyImmutablesMembership() internal view {
        MembershipManager m = MembershipManager(payable(MEMBERSHIP_MANAGER));
        require(address(m.eETH())            == EETH,                "MM.eETH");
        require(address(m.liquidityPool())   == LIQUIDITY_POOL,      "MM.liquidityPool");
        require(address(m.membershipNFT())   == MEMBERSHIP_NFT,      "MM.membershipNFT");
        require(address(m.roleRegistry())    == ROLE_REGISTRY,       "MM.roleRegistry");
        require(address(m.blacklister())     == blacklisterProxy,    "MM.blacklister");

        MembershipNFT mn = MembershipNFT(MEMBERSHIP_NFT);
        require(address(mn.liquidityPool())      == LIQUIDITY_POOL,    "MNFT.liquidityPool");
        require(address(mn.membershipManager())  == MEMBERSHIP_MANAGER,"MNFT.membershipManager");
        require(address(mn.roleRegistry())       == ROLE_REGISTRY,     "MNFT.roleRegistry");
        require(address(mn.blacklister())        == blacklisterProxy,  "MNFT.blacklister");
    }

    function _verifyImmutablesOracle() internal view {
        EtherFiAdmin a = EtherFiAdmin(ETHERFI_ADMIN);
        require(address(a.etherFiOracle())            == ETHERFI_ORACLE,            "EFAdmin.etherFiOracle");
        require(address(a.stakingManager())           == STAKING_MANAGER,           "EFAdmin.stakingManager");
        require(address(a.auctionManager())           == AUCTION_MANAGER,           "EFAdmin.auctionManager");
        require(address(a.etherFiNodesManager())      == ETHERFI_NODES_MANAGER,     "EFAdmin.etherFiNodesManager");
        require(address(a.liquidityPool())            == LIQUIDITY_POOL,            "EFAdmin.liquidityPool");
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

    function _verifyImmutablesRestaking() internal view {
        EtherFiRestaker r = EtherFiRestaker(payable(ETHERFI_RESTAKER));
        require(address(r.liquidityPool())                 == LIQUIDITY_POOL,                 "EFRestaker.liquidityPool");
        require(address(r.liquifier())                     == LIQUIFIER,                      "EFRestaker.liquifier");
        require(address(r.rewardsCoordinator())            == EIGENLAYER_REWARDS_COORDINATOR, "EFRestaker.rewardsCoordinator");
        require(r.etherFiRedemptionManager()               == ETHERFI_REDEMPTION_MANAGER,     "EFRestaker.etherFiRedemptionManager");
        require(address(r.roleRegistry())                  == ROLE_REGISTRY,                  "EFRestaker.roleRegistry");
        require(address(r.rateLimiter())                   == ETHERFI_RATE_LIMITER,           "EFRestaker.rateLimiter");
        require(address(r.eigenLayerStrategyManager())     == EIGENLAYER_STRATEGY_MANAGER,    "EFRestaker.eigenLayerStrategyManager");
        require(address(r.eigenLayerDelegationManager())   == EIGENLAYER_DELEGATION_MANAGER,  "EFRestaker.eigenLayerDelegationManager");

        RestakingRewardsRouter rrr = RestakingRewardsRouter(payable(RESTAKING_REWARDS_ROUTER));
        require(rrr.liquidityPool()          == LIQUIDITY_POOL,        "RestakingRR.liquidityPool");
        require(rrr.rewardTokenAddress()     == EIGEN,                "RestakingRR.rewardTokenAddress");
        require(address(rrr.roleRegistry())  == ROLE_REGISTRY,         "RestakingRR.roleRegistry");
    }

    function _verifyImmutablesRewards() internal view {
        CumulativeMerkleRewardsDistributor cmrd = CumulativeMerkleRewardsDistributor(payable(CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR));
        require(address(cmrd.roleRegistry()) == ROLE_REGISTRY, "CMRD.roleRegistry");

        EtherFiRewardsRouter rr = EtherFiRewardsRouter(payable(ETHERFI_REWARDS_ROUTER));
        require(rr.treasury()                == TREASURY,        "RewardsRouter.treasury");
        require(rr.liquidityPool()           == LIQUIDITY_POOL,  "RewardsRouter.liquidityPool");
        require(address(rr.roleRegistry())   == ROLE_REGISTRY,   "RewardsRouter.roleRegistry");
    }

    function _verifyImmutablesStaking() internal view {
        AuctionManager a = AuctionManager(AUCTION_MANAGER);
        require(address(a.roleRegistry())               == ROLE_REGISTRY,        "Auction.roleRegistry");
        require(address(a.blacklister())                == blacklisterProxy,     "Auction.blacklister");
        require(address(a.nodeOperatorManager())        == NODE_OPERATOR_MANAGER,"Auction.nodeOperatorManager");
        require(a.stakingManagerContractAddress()       == STAKING_MANAGER,      "Auction.stakingManagerContractAddress");
        require(a.treasury()                            == TREASURY,             "Auction.treasury");

        EtherFiNodesManager n = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER));
        require(address(n.stakingManager())  == STAKING_MANAGER,       "EFNodesMgr.stakingManager");
        require(address(n.roleRegistry())    == ROLE_REGISTRY,         "EFNodesMgr.roleRegistry");
        require(address(n.rateLimiter())     == ETHERFI_RATE_LIMITER,  "EFNodesMgr.rateLimiter");

        NodeOperatorManager nm = NodeOperatorManager(NODE_OPERATOR_MANAGER);
        require(nm.auctionManagerContractAddress() == AUCTION_MANAGER, "NodeOp.auctionManagerContractAddress");
        require(address(nm.roleRegistry())         == ROLE_REGISTRY,   "NodeOp.roleRegistry");

        StakingManager s = StakingManager(STAKING_MANAGER);
        require(s.liquidityPool()                  == LIQUIDITY_POOL,       "SM.liquidityPool");
        require(address(s.etherFiNodesManager())   == ETHERFI_NODES_MANAGER,"SM.etherFiNodesManager");
        require(address(s.depositContractEth2())   == ETH2_DEPOSIT_CONTRACT,"SM.depositContractEth2");
        require(address(s.auctionManager())        == AUCTION_MANAGER,      "SM.auctionManager");
        require(address(s.etherFiNodeBeacon())     == ETHERFI_NODE_BEACON,  "SM.etherFiNodeBeacon");
        require(address(s.roleRegistry())          == ROLE_REGISTRY,        "SM.roleRegistry");
    }

    function _verifyImmutablesWithdrawals() internal view {
        EtherFiRedemptionManager r = EtherFiRedemptionManager(payable(ETHERFI_REDEMPTION_MANAGER));
        require(r.treasury()                          == TREASURY, "EFRedemption.treasury");
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

        PriorityWithdrawalQueue pwq = PriorityWithdrawalQueue(payable(PRIORITY_WITHDRAWAL_QUEUE));
        require(address(pwq.liquidityPool()) == LIQUIDITY_POOL,                  "PWQ.liquidityPool");
        require(address(pwq.eETH())          == EETH,                            "PWQ.eETH");
        require(address(pwq.weETH())         == WEETH,                           "PWQ.weETH");
        require(pwq.minDelay()               == PWQ_MIN_DELAY,                   "PWQ.minDelay");
        require(address(pwq.roleRegistry())  == ROLE_REGISTRY,                   "PWQ.roleRegistry");
        require(address(pwq.blacklister())   == blacklisterProxy,                "PWQ.blacklister");

        WeETHWithdrawAdapter wwa = WeETHWithdrawAdapter(payable(WEETH_WITHDRAW_ADAPTER));
        require(address(wwa.weETH())              == WEETH,                "WeETHWA.weETH");
        require(address(wwa.eETH())               == EETH,                 "WeETHWA.eETH");
        require(address(wwa.liquidityPool())      == LIQUIDITY_POOL,       "WeETHWA.liquidityPool");
        require(address(wwa.blacklister())        == blacklisterProxy,     "WeETHWA.blacklister");
        require(address(wwa.roleRegistry())       == ROLE_REGISTRY,        "WeETHWA.roleRegistry");

        WithdrawRequestNFT n = WithdrawRequestNFT(payable(WITHDRAW_REQUEST_NFT));
        require(address(n.liquidityPool())    == LIQUIDITY_POOL,           "NFT.liquidityPool");
        require(address(n.roleRegistry())     == ROLE_REGISTRY,            "NFT.roleRegistry");
        require(address(n.blacklister())      == blacklisterProxy,         "NFT.blacklister");
        require(n.etherFiAdmin()              == ETHERFI_ADMIN,            "NFT.etherFiAdmin");
    }

    //--------------------------------------------------------------------------------------
    // STEP 6: verifyAccessControlPreservation
    //--------------------------------------------------------------------------------------
    /// @dev True for the 16 upgraded proxies whose new impl inherits DeprecatedOZOwnable and
    ///      therefore drops the owner() getter (OZ Ownable -> RoleRegistry migration). The other
    ///      6 in _upgradedProxies() either keep OZ Ownable (MembershipManager/MembershipNFT) or
    ///      never had owner() (RateLimiter / RestakingRewardsRouter / EtherFiRedemptionManager /
    ///      PriorityWithdrawalQueue), so their owner() is expected unchanged.
    function _ownerDeprecated(address p) internal pure returns (bool) {
        return
            p == EETH || p == WEETH || p == LIQUIDITY_POOL ||
            p == DEPOSIT_ADAPTER || p == LIQUIFIER ||
            p == ETHERFI_ADMIN || p == ETHERFI_ORACLE ||
            p == ETHERFI_RESTAKER ||
            p == CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR || p == ETHERFI_REWARDS_ROUTER ||
            p == AUCTION_MANAGER || p == ETHERFI_NODES_MANAGER ||
            p == NODE_OPERATOR_MANAGER || p == STAKING_MANAGER ||
            p == WEETH_WITHDRAW_ADAPTER || p == WITHDRAW_REQUEST_NFT;
    }

    function verifyAccessControlPreservation() public view {
        console2.log("=== Step 6: Verifying Access Control Preservation ===");
        address[22] memory proxies = _upgradedProxies();
        for (uint256 k = 0; k < proxies.length; k++) {
            address p = proxies[k];
            Snap memory pre = preSnap[p];
            if (_ownerDeprecated(p)) {
                // This upgrade migrates the contract off OpenZeppelin Ownable to the RoleRegistry
                // model: the new impl inherits DeprecatedOZOwnable (a storage-only shim with NO
                // owner() getter), so owner() is intentionally removed. Assert it is now gone
                // (staticcall reverts -> _getOwner returns address(0)) rather than requiring it
                // equal the pre-upgrade owner. Upgrade authority is preserved via _authorizeUpgrade's
                // onlyUpgradeTimelock + the role grants (verified in verifyOperatingConfig).
                require(_getOwner(p) == address(0), string.concat("owner not deprecated: ", vm.toString(p)));
            } else {
                // Contracts that retain (or never had) owner(): MembershipManager / MembershipNFT
                // keep OZ Ownable; RateLimiter / RestakingRewardsRouter / EtherFiRedemptionManager /
                // PriorityWithdrawalQueue never exposed owner(). Either way owner() must be unchanged.
                require(_getOwner(p) == pre.owner, string.concat("owner changed: ", vm.toString(p)));
            }
            require(_getPaused(p) == pre.paused, string.concat("paused changed: ", vm.toString(p)));
        }
        // Initialization state - upgraded proxies must remain non-reinitializable.
        // core
        verifyNotReinitializable(EETH,                       "EETH");
        verifyNotReinitializable(LIQUIDITY_POOL,             "LiquidityPool");
        verifyNotReinitializable(WEETH,                      "WeETH");
        // deposits
        verifyNotReinitializable(DEPOSIT_ADAPTER,                       "DepositAdapter");
        verifyNotReinitializable(LIQUIFIER,                  "Liquifier");
        // governance
        verifyNotReinitializable(ETHERFI_RATE_LIMITER,       "EtherFiRateLimiter");
        // membership
        verifyNotReinitializable(MEMBERSHIP_MANAGER,         "MembershipManager");
        verifyNotReinitializable(MEMBERSHIP_NFT,             "MembershipNFT");
        // oracle
        verifyNotReinitializable(ETHERFI_ADMIN,              "EtherFiAdmin");
        verifyNotReinitializable(ETHERFI_ORACLE,             "EtherFiOracle");
        // restaking
        verifyNotReinitializable(ETHERFI_RESTAKER,           "EtherFiRestaker");
        verifyNotReinitializable(RESTAKING_REWARDS_ROUTER,              "RestakingRewardsRouter");
        // rewards
        verifyNotReinitializable(CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR, "CumulativeMerkleRewardsDistributor");
        verifyNotReinitializable(ETHERFI_REWARDS_ROUTER,                "EtherFiRewardsRouter");
        // staking
        verifyNotReinitializable(AUCTION_MANAGER,            "AuctionManager");
        verifyNotReinitializable(ETHERFI_NODES_MANAGER,      "EtherFiNodesManager");
        verifyNotReinitializable(NODE_OPERATOR_MANAGER,      "NodeOperatorManager");
        verifyNotReinitializable(STAKING_MANAGER,            "StakingManager");
        // withdrawals
        verifyNotReinitializable(ETHERFI_REDEMPTION_MANAGER, "EtherFiRedemptionManager");
        verifyNotReinitializable(PRIORITY_WITHDRAWAL_QUEUE,             "PriorityWithdrawalQueue");
        verifyNotReinitializable(WEETH_WITHDRAW_ADAPTER,                "WeETHWithdrawAdapter");
        verifyNotReinitializable(WITHDRAW_REQUEST_NFT,       "WithdrawRequestNFT");
        console2.log("[OK] owner + paused + init state preserved");
        console2.log("");
    }

    //--------------------------------------------------------------------------------------
    // _appendGrantCalls — part 1 of the upgrade-timelock batch (see executeUpgrade)
    //
    // Appends the 9 RolesLibrary role grants (one HOLDER_* each), PLUS 6 extra grants that
    // give the operating multisig every RevokeAdmin-governed role, PLUS 2 that give the
    // executor guardian safe both guardian-tier roles, PLUS 1 that grants
    // HOLDER_CANCELLER_GUARDIAN the TimelockController CANCELLER_ROLE on the UPGRADE_TIMELOCK
    // itself — 18 grantRole calls total.
    // The first 17 grantRole calls are owner-gated (Solady
    // setRole -> contract owner) and the RoleRegistry owner IS the UPGRADE_TIMELOCK
    // executing this batch, so it can grant. The 18th targets the UPGRADE_TIMELOCK, which is
    // its own OZ AccessControl admin, so the same executing timelock can self-grant.
    // These run before the proxy upgrades, so
    // the calldata hits the pre-upgrade registry impl — fine, it shares Solady's role
    // storage, and the grants are visible to the new impl after the swap. They MUST
    // precede the onlyUpgradeTimelock initializers in _appendUpgradeCalls, which need
    // UPGRADE_TIMELOCK to already hold UPGRADE_TIMELOCK_ROLE.
    //
    // Precondition: these 9 roles are introduced by this upgrade, so nobody should
    // hold them yet. Assert zero current holders first — a pre-existing holder would
    // mean a stale grant (or a role-ID collision) and we fail loudly. Role IDs are the
    // hardcoded keccak256 constants above (the pre-upgrade impl has no *_ROLE() getters).
    //--------------------------------------------------------------------------------------
    function _appendGrantCalls(address[] memory targets, bytes[] memory data, uint256 i)
        internal
        view
        returns (uint256)
    {
        bytes32[9] memory roles = [
            UPGRADE_TIMELOCK_ROLE,
            OPERATION_TIMELOCK_ROLE,
            OPERATION_MULTISIG_ROLE,
            SUPER_GUARDIAN_ROLE,
            GUARDIAN_ROLE,
            ORACLE_OPERATIONS_ROLE,
            HOUSEKEEPING_OPERATIONS_ROLE,
            EXECUTOR_OPERATIONS_ROLE,
            EIGENPOD_OPERATIONS_ROLE
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
            require(
                roleRegistry.roleHolders(roles[k]).length == 0,
                "executeUpgrade: new role already has holder(s) before grant"
            );
        }

        for (uint256 k = 0; k < 9; k++) {
            targets[i] = ROLE_REGISTRY;
            data[i]    = abi.encodeWithSelector(RoleRegistry.grantRole.selector, roles[k], holders[k]);
            i++;
        }

        // Additionally grant the operating multisig (OPERATION_MULTISIG holder, 0x2aCA…) every
        // role that RevokeAdmin governs — the 6 guardian/operations roles its revoke* helpers
        // can strip (revokeSuperGuardianRole / revokeGuardianRole / revokeOracleOperationsRole /
        // revokeHousekeepingOperationsRole / revokeExecutorOperationsRole /
        // revokeEigenpodOperationsRole). This gives the operating multisig direct authority over
        // every guardian/operations action, alongside its existing revoke power. These are
        // ADDITIONAL holders on top of the dedicated HOLDER_* grants above; Solady `_setRole`
        // no-ops when the account already holds the role, so this is safe even if a HOLDER_*
        // is itself the operating multisig.
        bytes32[6] memory revokeAdminRoles = [
            SUPER_GUARDIAN_ROLE,
            GUARDIAN_ROLE,
            ORACLE_OPERATIONS_ROLE,
            HOUSEKEEPING_OPERATIONS_ROLE,
            EXECUTOR_OPERATIONS_ROLE,
            EIGENPOD_OPERATIONS_ROLE
        ];
        for (uint256 k = 0; k < 6; k++) {
            targets[i] = ROLE_REGISTRY;
            data[i]    = abi.encodeWithSelector(RoleRegistry.grantRole.selector, revokeAdminRoles[k], HOLDER_OPERATION_MULTISIG_ROLE);
            i++;
        }

        // Also grant the executor guardian safe (HOLDER_EXEC_GUARDIAN_SAFE) both guardian-tier
        // roles, so it can pauseContractUntil across the protocol (GUARDIAN) and pause the
        // EETH/WeETH tokens (SUPER_GUARDIAN). Additional holder; Solady `_setRole` no-ops on overlap.
        targets[i] = ROLE_REGISTRY;
        data[i]    = abi.encodeWithSelector(RoleRegistry.grantRole.selector, SUPER_GUARDIAN_ROLE, HOLDER_EXEC_GUARDIAN_SAFE);
        i++;
        targets[i] = ROLE_REGISTRY;
        data[i]    = abi.encodeWithSelector(RoleRegistry.grantRole.selector, GUARDIAN_ROLE, HOLDER_EXEC_GUARDIAN_SAFE);
        i++;

        // Grant the guardian Safe CANCELLER_ROLE on the UPGRADE_TIMELOCK so it can cancel a
        // scheduled-but-pending op during the 10-day delay. Target is the timelock itself
        // (NOT the RoleRegistry): TimelockController is its own AccessControl admin, and the
        // UPGRADE_TIMELOCK is the account executing this batch, so it can self-grant.
        targets[i] = UPGRADE_TIMELOCK;
        data[i]    = abi.encodeWithSelector(upgradeTimelock.grantRole.selector, TIMELOCK_CANCELLER_ROLE, HOLDER_CANCELLER_GUARDIAN);
        i++;

        return i;
    }

    //--------------------------------------------------------------------------------------
    // STEP 9: executeLpWithdrawBounds — Batch 3, the OPERATION_MULTISIG batch (instant)
    //
    // LP.setMinWithdrawAmount / setMaxWithdrawAmount are onlyOperatingMultisig.
    // ETHERFI_OPERATING_ADMIN is granted OPERATION_MULTISIG_ROLE inside the upgrade
    // timelock batch (step 3), so this tx is broadcast directly from that Safe (no
    // timelock). One JSON, executed last.
    //
    // Order matters: setMaxWithdrawAmount must run first. The setMinWithdrawAmount
    // check requires _min <= maxWithdrawAmount, which is 0 in fresh storage and
    // would force any non-zero _min to revert.
    //--------------------------------------------------------------------------------------
    function executeLpWithdrawBounds() public {
        console2.log("=== Step 9: Executing LP Withdraw Bounds (Batch 3, OPERATION_MULTISIG, instant) ===");

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
    // STEP 8: executeOperatingConfig — Batch 2, the OPERATING_TIMELOCK batch (2d)
    //--------------------------------------------------------------------------------------
    /// @dev Salt for the operating-timelock (Batch 2) operation. Shared between the
    ///      schedule/execute JSONs (executeOperatingConfig) and the day-10 combined
    ///      multiSend (emitExecutionDayOpsAndBounds), so both reference the SAME timelock
    ///      operation id — the day-10 executeBatch must match what was scheduled at day 0.
    function _opsBatchSalt() internal view returns (bytes32) {
        return keccak256(abi.encode("batch-2", commitHashSalt));
    }

    function executeOperatingConfig() public {
        console2.log("=== Step 8: Executing Operating Config (Batch 2, OPERATING_TIMELOCK, 2d) ===");

        (address[] memory tt, uint256[] memory vv, bytes[] memory dd) = _buildOperatingConfigBatch();

        _shrinkAndEmit(
            BatchEmit({
                label: "Operating Timelock Batch",
                timelock: operatingTimelock,
                timelockAddr: OPERATING_TIMELOCK,
                adminSafe: ETHERFI_OPERATING_ADMIN,
                minDelay: OPERATING_TIMELOCK_DELAY,
                salt: _opsBatchSalt(),
                scheduleFile: "ops_schedule.json",
                executeFile: "ops_execute.json"
            }),
            tt, vv, dd, tt.length
        );
    }

    /// @dev Builds the operating-timelock (Batch 2) call set: rate-limiter buckets +
    ///      consumers, pause durations, and the EtherFiAdmin daily finalized-withdrawal cap.
    ///      Extracted so both the schedule/execute JSON path and the day-10 combined
    ///      multiSend can encode the identical (targets, values, datas) tuple.
    function _buildOperatingConfigBatch()
        internal
        view
        returns (address[] memory, uint256[] memory, bytes[] memory)
    {
        address[] memory targets = new address[](60);
        bytes[]   memory data    = new bytes[](60);
        uint256[] memory values  = new uint256[](60);
        uint256 i;

        // ───────── core — Token-side global buckets (consumeToken on eETH mint/burn) ─────────
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _createLimiter(EETH_MINT_LIMIT_ID,  EETH_MINT_CAPACITY,  EETH_MINT_REFILL_RATE));  i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _createLimiter(EETH_BURN_LIMIT_ID,  EETH_BURN_CAPACITY,  EETH_BURN_REFILL_RATE));  i++;

        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _updateConsumer(EETH_MINT_LIMIT_ID,  EETH));  i++;
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _updateConsumer(EETH_BURN_LIMIT_ID,  EETH));  i++;

        // ───────── restaking — EtherFiRestaker bucket (consume) ─────────
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _createLimiter(STETH_REQUEST_WITHDRAWAL_LIMIT_ID, STETH_REQUEST_WITHDRAWAL_CAPACITY, STETH_REQUEST_WITHDRAWAL_REFILL_RATE)); i++;

        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER, _updateConsumer(STETH_REQUEST_WITHDRAWAL_LIMIT_ID, ETHERFI_RESTAKER)); i++;

        // ───────── oracle — EtherFiAdmin daily finalized-withdrawal cap (onlyAdmin) ─────────
        // Seeds maxFinalizedWithdrawalAmountPerDay (defaults to 0, which rejects all
        // finalized withdrawals). onlyAdmin = OPERATION_TIMELOCK_ROLE, so it belongs in
        // this operating-timelock batch, not the upgrade batch with the initializers.
        (targets[i], data[i]) = (ETHERFI_ADMIN,
            abi.encodeWithSelector(EtherFiAdmin.updateMaxFinalizedWithdrawalAmountPerDay.selector, ADMIN_DAILY_FINALIZED_WITHDRAWAL_LIMIT)); i++;

        // core
        (targets[i], data[i]) = (EETH,                       _pauseDur(PAUSE_UNTIL_EETH));                   i++;
        (targets[i], data[i]) = (LIQUIDITY_POOL,             _pauseDur(PAUSE_UNTIL_LIQUIDITY_POOL));         i++;
        (targets[i], data[i]) = (WEETH,                      _pauseDur(PAUSE_UNTIL_WEETH));                  i++;
        // deposits
        (targets[i], data[i]) = (LIQUIFIER,                  _pauseDur(PAUSE_UNTIL_LIQUIFIER));              i++;
        // rewards
        (targets[i], data[i]) = (CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR, _pauseDur(PAUSE_UNTIL_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR)); i++;
        // staking
        (targets[i], data[i]) = (AUCTION_MANAGER,            _pauseDur(PAUSE_UNTIL_AUCTION_MANAGER));        i++;
        (targets[i], data[i]) = (ETHERFI_NODES_MANAGER,      _pauseDur(PAUSE_UNTIL_ETHERFI_NODES_MANAGER));  i++;
        // withdrawals
        (targets[i], data[i]) = (ETHERFI_REDEMPTION_MANAGER, _pauseDur(PAUSE_UNTIL_ETHERFI_REDEMPTION_MGR)); i++;
        (targets[i], data[i]) = (PRIORITY_WITHDRAWAL_QUEUE,             _pauseDur(PAUSE_UNTIL_PRIORITY_WITHDRAWAL_QUEUE));             i++;
        (targets[i], data[i]) = (WEETH_WITHDRAW_ADAPTER,                _pauseDur(PAUSE_UNTIL_WEETH_WITHDRAW_ADAPTER));                i++;
        (targets[i], data[i]) = (WITHDRAW_REQUEST_NFT,       _pauseDur(PAUSE_UNTIL_WITHDRAW_REQUEST_NFT));   i++;

        // governance — grant the guardian Safe CANCELLER_ROLE on the OPERATING_TIMELOCK so it
        // can cancel a scheduled-but-pending op during the 2-day delay. Target is the timelock
        // itself: TimelockController is its own AccessControl admin and the OPERATING_TIMELOCK
        // is the account executing this batch, so it self-grants. This rides the operating
        // batch (not the upgrade batch) because only the OPERATING_TIMELOCK can grant its own role.
        (targets[i], data[i]) = (OPERATING_TIMELOCK,
            abi.encodeWithSelector(operatingTimelock.grantRole.selector, TIMELOCK_CANCELLER_ROLE, HOLDER_CANCELLER_GUARDIAN)); i++;

        // ───────── staking — migrate ENM forwarded-call whitelist (grant new holder, revoke legacy) ─────────
        bytes4[] memory eigSelectors = _forwardedEigenpodSelectors();
        for (uint256 j = 0; j < eigSelectors.length; j++) {
            (targets[i], data[i]) = (ETHERFI_NODES_MANAGER, abi.encodeWithSelector(
                EtherFiNodesManager.updateAllowedForwardedEigenpodCalls.selector,
                HOLDER_EIGENPOD_OPERATIONS_ROLE, eigSelectors[j], true)); i++;
            (targets[i], data[i]) = (ETHERFI_NODES_MANAGER, abi.encodeWithSelector(
                EtherFiNodesManager.updateAllowedForwardedEigenpodCalls.selector,
                LEGACY_FORWARD_CALLER, eigSelectors[j], false)); i++;
        }
        (bytes4[] memory extSelectors, address[] memory extTargets) = _forwardedExternalCalls();
        for (uint256 j = 0; j < extSelectors.length; j++) {
            (targets[i], data[i]) = (ETHERFI_NODES_MANAGER, abi.encodeWithSelector(
                EtherFiNodesManager.updateAllowedForwardedExternalCalls.selector,
                HOLDER_EIGENPOD_OPERATIONS_ROLE, extSelectors[j], extTargets[j], true)); i++;
            (targets[i], data[i]) = (ETHERFI_NODES_MANAGER, abi.encodeWithSelector(
                EtherFiNodesManager.updateAllowedForwardedExternalCalls.selector,
                LEGACY_FORWARD_CALLER, extSelectors[j], extTargets[j], false)); i++;
        }
        // Grant-only (3CP #580): newly-whitelisted DelegationManager selectors granted to the new
        // holder; the legacy caller's copies are revoked in a separate later 3CP, not here.
        (bytes4[] memory goSelectors, address[] memory goTargets) = _grantOnlyExternalCalls();
        for (uint256 j = 0; j < goSelectors.length; j++) {
            (targets[i], data[i]) = (ETHERFI_NODES_MANAGER, abi.encodeWithSelector(
                EtherFiNodesManager.updateAllowedForwardedExternalCalls.selector,
                HOLDER_EIGENPOD_OPERATIONS_ROLE, goSelectors[j], goTargets[j], true)); i++;
        }

        return _shrink(targets, values, data, i);
    }

    //--------------------------------------------------------------------------------------
    // STEP 9b: emitExecutionDayOpsAndBounds — day-10 combined Safe B multiSend (steps 3 + 4)
    //
    // Both steps are signed/executed by the SAME Safe (ETHERFI_OPERATING_ADMIN, 0x2aCA…):
    //   3. OPERATING_TIMELOCK.executeBatch(...)  (Safe B is the timelock's executor)
    //   4. LiquidityPool.setMaxWithdrawAmount / setMinWithdrawAmount (Safe B holds OPERATION_MULTISIG_ROLE)
    // so they fold into ONE Safe Transaction-Builder batch → the Safe UI runs it as a single
    // `multiSend`, guaranteeing order (execute-batch THEN bounds) with no tx in between.
    //
    // This is the same-Safe portion of the day-10 atomic sequence. The full sequence also
    // prepends the AuctionManager sweep (step 1, Safe B) and the nested UPGRADE_TIMELOCK
    // execute (step 2, wrapped as SafeA.execTransaction with pre-approved hashes) — those are
    // added once the gas budget for a single combined tx is confirmed on a fork.
    //
    // The executeBatch calldata MUST match what `ops_schedule.json` scheduled at day 0:
    // identical (targets, values, datas, predecessor=0, salt). We reuse _buildOperatingConfigBatch
    // + _opsBatchSalt so they can never drift. setMaxWithdrawAmount comes before
    // setMinWithdrawAmount (the min check requires _min <= maxWithdrawAmount).
    //--------------------------------------------------------------------------------------
    function emitExecutionDayOpsAndBounds() public {
        console2.log("=== Step 9b: Emitting day-10 combined Safe B multiSend (ops execute + LP bounds) ===");

        (address[] memory tt, uint256[] memory vv, bytes[] memory dd) = _buildOperatingConfigBatch();

        SafeTx[] memory batch = new SafeTx[](3);
        // 3. execute the (already-scheduled) operating-timelock batch
        batch[0] = SafeTx({
            to: OPERATING_TIMELOCK,
            value: 0,
            data: abi.encodeWithSelector(operatingTimelock.executeBatch.selector, tt, vv, dd, bytes32(0), _opsBatchSalt())
        });
        // 4. LP withdraw bounds — max first, then min
        batch[1] = SafeTx({
            to: LIQUIDITY_POOL,
            value: 0,
            data: abi.encodeWithSelector(LiquidityPool.setMaxWithdrawAmount.selector, LP_MAX_WITHDRAW_AMOUNT)
        });
        batch[2] = SafeTx({
            to: LIQUIDITY_POOL,
            value: 0,
            data: abi.encodeWithSelector(LiquidityPool.setMinWithdrawAmount.selector, LP_MIN_WITHDRAW_AMOUNT)
        });

        writeSafeJson(OUT_DIR, "execday_ops_and_bounds.json", ETHERFI_OPERATING_ADMIN, batch, 1);
        console2.log("[OK] wrote execday_ops_and_bounds.json (3 sub-calls, one multiSend from ETHERFI_OPERATING_ADMIN)");
        console2.log("");
    }

    //--------------------------------------------------------------------------------------
    // STEP 10: verifyOperatingConfig
    //--------------------------------------------------------------------------------------
    function verifyOperatingConfig() public view {
        console2.log("=== Step 10: Verifying Operating Config ===");
        EtherFiRateLimiter rl = EtherFiRateLimiter(payable(ETHERFI_RATE_LIMITER));
        require(rl.limitExists(EETH_MINT_LIMIT_ID),                "EETH_MINT bucket missing");
        require(rl.limitExists(EETH_BURN_LIMIT_ID),                "EETH_BURN bucket missing");
        require(rl.limitExists(STETH_REQUEST_WITHDRAWAL_LIMIT_ID), "STETH_REQUEST_WITHDRAWAL bucket missing");

        require(rl.isConsumerAllowed(EETH_MINT_LIMIT_ID,                EETH),                  "EETH consumer (mint) not allowed");
        require(rl.isConsumerAllowed(EETH_BURN_LIMIT_ID,                EETH),                  "EETH consumer (burn) not allowed");
        require(rl.isConsumerAllowed(STETH_REQUEST_WITHDRAWAL_LIMIT_ID, ETHERFI_RESTAKER),      "EFRestaker consumer (stEth) not allowed");

        // Each bucket's capacity + refillRate must equal the Constants the batch configured them
        // with — otherwise the rate-limit boundaries enforced on-chain differ from spec.
        _assertBucketConfig(rl, EETH_MINT_LIMIT_ID,                EETH_MINT_CAPACITY,                EETH_MINT_REFILL_RATE,                "EETH_MINT");
        _assertBucketConfig(rl, EETH_BURN_LIMIT_ID,                EETH_BURN_CAPACITY,                EETH_BURN_REFILL_RATE,                "EETH_BURN");
        _assertBucketConfig(rl, STETH_REQUEST_WITHDRAWAL_LIMIT_ID, STETH_REQUEST_WITHDRAWAL_CAPACITY, STETH_REQUEST_WITHDRAWAL_REFILL_RATE, "STETH_REQUEST_WITHDRAWAL");

        require(EETHToken(EETH).pauseUntilDuration()                                  == PAUSE_UNTIL_EETH,                  "EETH pause duration mismatch");
        require(LiquidityPool(payable(LIQUIDITY_POOL)).pauseUntilDuration()           == PAUSE_UNTIL_LIQUIDITY_POOL,        "LP pause duration mismatch");
        require(WeETHToken(WEETH).pauseUntilDuration()                                == PAUSE_UNTIL_WEETH,                 "WeETH pause duration mismatch");
        require(Liquifier(payable(LIQUIFIER)).pauseUntilDuration()                    == PAUSE_UNTIL_LIQUIFIER,             "Liquifier pause duration mismatch");
        require(CumulativeMerkleRewardsDistributor(payable(CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR)).pauseUntilDuration() == PAUSE_UNTIL_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR, "CMRD pause duration mismatch");
        require(AuctionManager(AUCTION_MANAGER).pauseUntilDuration()                                           == PAUSE_UNTIL_AUCTION_MANAGER,                      "Auction pause duration mismatch");
        require(EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER)).pauseUntilDuration()                       == PAUSE_UNTIL_ETHERFI_NODES_MANAGER,                "EFNodesMgr pause duration mismatch");
        require(EtherFiRedemptionManager(payable(ETHERFI_REDEMPTION_MANAGER)).pauseUntilDuration()             == PAUSE_UNTIL_ETHERFI_REDEMPTION_MGR,               "EFRedemption pause duration mismatch");
        require(PriorityWithdrawalQueue(payable(PRIORITY_WITHDRAWAL_QUEUE)).pauseUntilDuration()               == PAUSE_UNTIL_PRIORITY_WITHDRAWAL_QUEUE,             "PWQ pause duration mismatch");
        require(WeETHWithdrawAdapter(payable(WEETH_WITHDRAW_ADAPTER)).pauseUntilDuration()                     == PAUSE_UNTIL_WEETH_WITHDRAW_ADAPTER,               "WeETHWA pause duration mismatch");
        require(WithdrawRequestNFT(payable(WITHDRAW_REQUEST_NFT)).pauseUntilDuration()== PAUSE_UNTIL_WITHDRAW_REQUEST_NFT,  "NFT pause duration mismatch");

        // Cross-check the hardcoded role IDs (used by _appendGrantCalls, before the
        // getters existed) against the now-upgraded registry. This is the only guard
        // that catches a typo in the 8 non-upgrade role strings — the upgrade-batch
        // dry-run only exercises UPGRADE_TIMELOCK_ROLE (via the initializers).
        require(roleRegistry.UPGRADE_TIMELOCK_ROLE()        == UPGRADE_TIMELOCK_ROLE,        "UPGRADE_TIMELOCK_ROLE id mismatch");
        require(roleRegistry.OPERATION_TIMELOCK_ROLE()      == OPERATION_TIMELOCK_ROLE,      "OPERATION_TIMELOCK_ROLE id mismatch");
        require(roleRegistry.OPERATION_MULTISIG_ROLE()      == OPERATION_MULTISIG_ROLE,      "OPERATION_MULTISIG_ROLE id mismatch");
        require(roleRegistry.SUPER_GUARDIAN_ROLE()          == SUPER_GUARDIAN_ROLE,          "SUPER_GUARDIAN_ROLE id mismatch");
        require(roleRegistry.GUARDIAN_ROLE()                == GUARDIAN_ROLE,                "GUARDIAN_ROLE id mismatch");
        require(roleRegistry.ORACLE_OPERATIONS_ROLE()       == ORACLE_OPERATIONS_ROLE,       "ORACLE_OPERATIONS_ROLE id mismatch");
        require(roleRegistry.HOUSEKEEPING_OPERATIONS_ROLE() == HOUSEKEEPING_OPERATIONS_ROLE, "HOUSEKEEPING_OPERATIONS_ROLE id mismatch");
        require(roleRegistry.EXECUTOR_OPERATIONS_ROLE()     == EXECUTOR_OPERATIONS_ROLE,     "EXECUTOR_OPERATIONS_ROLE id mismatch");
        require(roleRegistry.EIGENPOD_OPERATIONS_ROLE()     == EIGENPOD_OPERATIONS_ROLE,     "EIGENPOD_OPERATIONS_ROLE id mismatch");

        require(roleRegistry.hasRole(UPGRADE_TIMELOCK_ROLE,        HOLDER_UPGRADE_TIMELOCK_ROLE),       "UPGRADE_TIMELOCK_ROLE not granted");
        require(roleRegistry.hasRole(OPERATION_TIMELOCK_ROLE,      HOLDER_OPERATION_TIMELOCK_ROLE),     "OPERATION_TIMELOCK_ROLE not granted");
        require(roleRegistry.hasRole(OPERATION_MULTISIG_ROLE,      HOLDER_OPERATION_MULTISIG_ROLE),     "OPERATION_MULTISIG_ROLE not granted");
        require(roleRegistry.hasRole(SUPER_GUARDIAN_ROLE,          HOLDER_SUPER_GUARDIAN_ROLE),          "SUPER_GUARDIAN_ROLE not granted");
        require(roleRegistry.hasRole(GUARDIAN_ROLE,                HOLDER_GUARDIAN_ROLE),                "GUARDIAN_ROLE not granted");
        require(roleRegistry.hasRole(ORACLE_OPERATIONS_ROLE,       HOLDER_ORACLE_OPERATIONS_ROLE),       "ORACLE_OPERATIONS_ROLE not granted");
        require(roleRegistry.hasRole(HOUSEKEEPING_OPERATIONS_ROLE, HOLDER_HOUSEKEEPING_OPERATIONS_ROLE), "HOUSEKEEPING_OPERATIONS_ROLE not granted");
        require(roleRegistry.hasRole(EXECUTOR_OPERATIONS_ROLE,     HOLDER_EXECUTOR_OPERATIONS_ROLE),     "EXECUTOR_OPERATIONS_ROLE not granted");
        require(roleRegistry.hasRole(EIGENPOD_OPERATIONS_ROLE,     HOLDER_EIGENPOD_OPERATIONS_ROLE),     "EIGENPOD_OPERATIONS_ROLE not granted");

        // The operating multisig must additionally hold every RevokeAdmin-governed role.
        require(roleRegistry.hasRole(SUPER_GUARDIAN_ROLE,          HOLDER_OPERATION_MULTISIG_ROLE), "SUPER_GUARDIAN_ROLE not granted to operating multisig");
        require(roleRegistry.hasRole(GUARDIAN_ROLE,                HOLDER_OPERATION_MULTISIG_ROLE), "GUARDIAN_ROLE not granted to operating multisig");
        require(roleRegistry.hasRole(ORACLE_OPERATIONS_ROLE,       HOLDER_OPERATION_MULTISIG_ROLE), "ORACLE_OPERATIONS_ROLE not granted to operating multisig");
        require(roleRegistry.hasRole(HOUSEKEEPING_OPERATIONS_ROLE, HOLDER_OPERATION_MULTISIG_ROLE), "HOUSEKEEPING_OPERATIONS_ROLE not granted to operating multisig");
        require(roleRegistry.hasRole(EXECUTOR_OPERATIONS_ROLE,     HOLDER_OPERATION_MULTISIG_ROLE), "EXECUTOR_OPERATIONS_ROLE not granted to operating multisig");
        require(roleRegistry.hasRole(EIGENPOD_OPERATIONS_ROLE,     HOLDER_OPERATION_MULTISIG_ROLE), "EIGENPOD_OPERATIONS_ROLE not granted to operating multisig");

        // The executor guardian safe must hold both guardian-tier roles.
        require(roleRegistry.hasRole(SUPER_GUARDIAN_ROLE, HOLDER_EXEC_GUARDIAN_SAFE), "SUPER_GUARDIAN_ROLE not granted to exec guardian safe");
        require(roleRegistry.hasRole(GUARDIAN_ROLE,       HOLDER_EXEC_GUARDIAN_SAFE), "GUARDIAN_ROLE not granted to exec guardian safe");

        // The guardian Safe must hold CANCELLER_ROLE on BOTH timelocks. Both batches have been
        // dry-run on the fork by the time this verifier runs (executeUpgrade then
        // executeOperatingConfig in run()), so the grants are live on the forked timelocks.
        require(upgradeTimelock.hasRole(TIMELOCK_CANCELLER_ROLE,   HOLDER_CANCELLER_GUARDIAN), "CANCELLER_ROLE not granted on upgrade timelock");
        require(operatingTimelock.hasRole(TIMELOCK_CANCELLER_ROLE, HOLDER_CANCELLER_GUARDIAN), "CANCELLER_ROLE not granted on operating timelock");

        require(LiquidityPool(payable(LIQUIDITY_POOL)).maxWithdrawAmount() == LP_MAX_WITHDRAW_AMOUNT, "LP.maxWithdrawAmount mismatch");
        require(LiquidityPool(payable(LIQUIDITY_POOL)).minWithdrawAmount() == LP_MIN_WITHDRAW_AMOUNT, "LP.minWithdrawAmount mismatch");

        require(EtherFiAdmin(ETHERFI_ADMIN).maxFinalizedWithdrawalAmountPerDay() == ADMIN_DAILY_FINALIZED_WITHDRAWAL_LIMIT, "EFAdmin.maxFinalizedWithdrawalAmountPerDay mismatch");

        // Forwarded-call whitelist migrated: granted to the new role holder, revoked from the legacy caller.
        EtherFiNodesManager enm = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER));
        bytes4[] memory eigSelectors = _forwardedEigenpodSelectors();
        for (uint256 j = 0; j < eigSelectors.length; j++) {
            require(enm.allowedForwardedEigenpodCalls(HOLDER_EIGENPOD_OPERATIONS_ROLE, eigSelectors[j]),
                "forwarded eigenpod call not granted to role holder");
            require(!enm.allowedForwardedEigenpodCalls(LEGACY_FORWARD_CALLER, eigSelectors[j]),
                "forwarded eigenpod call not revoked from legacy caller");
        }
        (bytes4[] memory extSelectors, address[] memory extTargets) = _forwardedExternalCalls();
        for (uint256 j = 0; j < extSelectors.length; j++) {
            require(enm.allowedForwardedExternalCalls(HOLDER_EIGENPOD_OPERATIONS_ROLE, extSelectors[j], extTargets[j]),
                "forwarded external call not granted to role holder");
            require(!enm.allowedForwardedExternalCalls(LEGACY_FORWARD_CALLER, extSelectors[j], extTargets[j]),
                "forwarded external call not revoked from legacy caller");
        }
        // Grant-only (3CP #580): the new holder must hold each; legacy is untouched here.
        (bytes4[] memory goSelectors, address[] memory goTargets) = _grantOnlyExternalCalls();
        for (uint256 j = 0; j < goSelectors.length; j++) {
            require(enm.allowedForwardedExternalCalls(HOLDER_EIGENPOD_OPERATIONS_ROLE, goSelectors[j], goTargets[j]),
                "grant-only external call not granted to role holder");
        }

        console2.log("[OK] rate-limiter buckets + pause durations + role grants + LP withdraw bounds + finalized-withdrawal cap + forwarded-call whitelist verified");
        console2.log("");
    }

    /// @dev Assert a bucket's configured capacity + refillRate equal the Constants values.
    function _assertBucketConfig(
        EtherFiRateLimiter rl,
        bytes32 id,
        uint64 expectedCapacity,
        uint64 expectedRefillRate,
        string memory tag
    ) private view {
        (uint64 capacity, , uint64 refillRate, ) = rl.getLimit(id);
        require(capacity   == expectedCapacity,   string.concat(tag, ": capacity != Constants"));
        require(refillRate == expectedRefillRate, string.concat(tag, ": refillRate != Constants"));
    }

    //--------------------------------------------------------------------------------------
    // _appendLegacyRevokeCalls — part 4 (final) of the upgrade-timelock batch
    //
    // Appends one revokeRole(role, holder) per current holder of each of the 31 legacy
    // (pre-upgrade) granular roles. Holders are enumerated LIVE via roleHolders() at
    // generation time. Grants/upgrades earlier in the batch don't touch legacy roles,
    // so what we read equals the real mainnet holders. revokeRole is owner-gated and
    // the registry owner is the UPGRADE_TIMELOCK executing this batch.
    //
    // Safe to revoke: every master-branch contract that checked a legacy role is in
    // the upgrade set and now routes gating through the 9 RolesLibrary roles, so the
    // legacy roles are orphaned post-upgrade. Solady _setRole(active=false) is a no-op
    // on a non-holder, so the batch tolerates holder drift between generation and
    // execution. The emitted JSON encodes the exact holders observed at generation
    // time — regenerate if a legacy role gains a new holder before execution.
    //--------------------------------------------------------------------------------------
    function _appendLegacyRevokeCalls(address[] memory targets, bytes[] memory data, uint256 i)
        internal
        view
        returns (uint256)
    {
        bytes32[31] memory roles = _legacyRoles();
        for (uint256 r = 0; r < roles.length; r++) {
            address[] memory holders = roleRegistry.roleHolders(roles[r]);
            for (uint256 h = 0; h < holders.length; h++) {
                targets[i] = ROLE_REGISTRY;
                data[i]    = abi.encodeWithSelector(RoleRegistry.revokeRole.selector, roles[r], holders[h]);
                i++;
            }
        }
        return i;
    }

    /// @dev Total current holders across all 31 legacy roles — used to size the
    ///      upgrade-timelock batch arrays before _appendLegacyRevokeCalls fills them.
    function _countLegacyRoleHolders() internal view returns (uint256 total) {
        bytes32[31] memory roles = _legacyRoles();
        for (uint256 r = 0; r < roles.length; r++) {
            total += roleRegistry.roleHolders(roles[r]).length;
        }
    }

    //--------------------------------------------------------------------------------------
    // STEP 7: verifyLegacyRolesRevoked
    //--------------------------------------------------------------------------------------
    function verifyLegacyRolesRevoked() public view {
        console2.log("=== Step 7: Verifying Legacy Roles Fully Revoked ===");
        bytes32[31] memory roles = _legacyRoles();
        for (uint256 r = 0; r < roles.length; r++) {
            require(roleRegistry.roleHolders(roles[r]).length == 0, "legacy role still has holders");
        }
        console2.log("[OK] all 31 legacy roles have zero holders");
        console2.log("");
    }

    //--------------------------------------------------------------------------------------
    // STEP 7b: verifyLiquifierWhitelistRemoved (EARN-1421)
    //
    // Asserts cbETH + wBETH (bETH) are no longer whitelisted Liquifier deposit tokens after
    // the upgrade batch, and surfaces any outstanding token balance the Liquifier still holds
    // so the operator can confirm nothing needs migrating before go-live (acceptance item 3).
    //--------------------------------------------------------------------------------------
    function verifyLiquifierWhitelistRemoved() public view {
        console2.log("=== Step 7b: Verifying Liquifier cbETH/wBETH unwhitelisted ===");
        Liquifier l = Liquifier(payable(LIQUIFIER));
        require(!l.isTokenWhitelisted(CBETH), "Liquifier: cbETH still whitelisted");
        require(!l.isTokenWhitelisted(WBETH), "Liquifier: wBETH still whitelisted");

        // Outstanding balances held directly by the Liquifier (operator eyeball — not a gate).
        uint256 cbethBal = _erc20BalanceOf(CBETH, LIQUIFIER);
        uint256 wbethBal = _erc20BalanceOf(WBETH, LIQUIFIER);
        console2.log("Liquifier cbETH balance (confirm migration if non-zero):", cbethBal);
        console2.log("Liquifier wBETH balance (confirm migration if non-zero):", wbethBal);

        console2.log("[OK] cbETH + wBETH unwhitelisted on Liquifier");
        console2.log("");
    }

    /// @dev Best-effort ERC20 balanceOf via staticcall (returns 0 if the call reverts/returns nothing).
    function _erc20BalanceOf(address token, address holder) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", holder));
        return (ok && ret.length >= 32) ? abi.decode(ret, (uint256)) : 0;
    }

    /// @dev The 31 pre-upgrade granular roles (see the LEGACY ROLE IDs block above).
    ///      Order is irrelevant — every holder of every entry is revoked.
    function _legacyRoles() internal pure returns (bytes32[31] memory list) {
        list[0]  = L_PROTOCOL_PAUSER;
        list[1]  = L_PROTOCOL_UNPAUSER;
        list[2]  = L_EETH_OPERATING_ADMIN_ROLE;
        list[3]  = L_WEETH_OPERATING_ADMIN_ROLE;
        list[4]  = L_LIQUIDITY_POOL_ADMIN_ROLE;
        list[5]  = L_LIQUIDITY_POOL_VALIDATOR_APPROVER_ROLE;
        list[6]  = L_LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE;
        list[7]  = L_STAKING_MANAGER_ADMIN_ROLE;
        list[8]  = L_STAKING_MANAGER_NODE_CREATOR_ROLE;
        list[9]  = L_STAKING_MANAGER_VALIDATOR_INVALIDATOR_ROLE;
        list[10] = L_ETHERFI_NODES_MANAGER_ADMIN_ROLE;
        list[11] = L_ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE;
        list[12] = L_ETHERFI_NODES_MANAGER_POD_PROVER_ROLE;
        list[13] = L_ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE;
        list[14] = L_ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE;
        list[15] = L_ETHERFI_NODES_MANAGER_EL_CONSOLIDATION_ROLE;
        list[16] = L_ETHERFI_NODES_MANAGER_LEGACY_LINKER_ROLE;
        list[17] = L_ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE;
        list[18] = L_ETHERFI_ORACLE_EXECUTOR_TASK_MANAGER_ROLE;
        list[19] = L_ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE;
        list[20] = L_ETHERFI_RATE_LIMITER_ADMIN_ROLE;
        list[21] = L_WITHDRAW_REQUEST_NFT_ADMIN_ROLE;
        list[22] = L_IMPLICIT_FEE_CLAIMER_ROLE;
        list[23] = L_PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE;
        list[24] = L_PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE;
        list[25] = L_PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE;
        list[26] = L_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR_ADMIN_ROLE;
        list[27] = L_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR_CLAIM_DELAY_SETTER_ROLE;
        list[28] = L_ETHERFI_REWARDS_ROUTER_ADMIN_ROLE;
        list[29] = L_ETHERFI_REWARDS_ROUTER_ERC20_TRANSFER_ROLE;
        list[30] = L_WEETH_WITHDRAW_ADAPTER_ADMIN_ROLE;
    }

    //--------------------------------------------------------------------------------------
    // Helpers
    //--------------------------------------------------------------------------------------
    function _upgradeTo(address newImpl) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, newImpl);
    }

    /// @dev Calldata for an OZ5 ProxyAdmin to upgrade a TransparentUpgradeableProxy. OZ5 dropped
    ///      the bare `upgrade(proxy,impl)`; only `upgradeAndCall(proxy,impl,data)` exists. Empty
    ///      data => no post-upgrade call, just the impl swap. Sent TO the ProxyAdmin (its owner
    ///      must be the caller), not to the proxy itself.
    function _upgradeTransparent(address proxy, address newImpl) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("upgradeAndCall(address,address,bytes)", proxy, newImpl, bytes(""));
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

    //--------------------------------------------------------------------------------------
    // STEP 11: verifyPostUpgradeFlows — functional smoke test on the simulated post-upgrade fork
    //
    // Proves the upgrade is functionally live (not just structurally correct): deposit, wrap/
    // unwrap, oracle report submit+execute, the full withdraw lifecycle (request -> finalize ->
    // claim), instant redemption, and eETH mint/burn rate-limiting. State-changing via vm cheats
    // (simulation only — runs after every Safe JSON is emitted, so it can't affect broadcast
    // output). Replaces the former test/fork-tests/PostUpgradeFlows.t.sol. Asserts via require()
    // (a forge Script has no StdAssertions). EETH + the EETH_MINT/BURN buckets are already in
    // their real post-upgrade state here (upgraded in Batch 1, buckets created in Batch 2), so no
    // vm.store force-upgrade or bucket bootstrap is needed (unlike the standalone fork test).
    //--------------------------------------------------------------------------------------
    address private constant FLOW_ETH_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function verifyPostUpgradeFlows() public {
        console2.log("=== Step 11: Verifying Post-Upgrade Functional Flows ===");
        _syncOracleReportState();
        _flushPendingWithdrawalBacklog();

        _flowDeposit();
        _flowWrapUnwrap();
        _flowOracleReport();
        _flowWithdrawLifecycle();
        _flowInstantRedeem();
        _flowEEthRateLimits();

        console2.log("  [OK] flows: deposit, wrap/unwrap, oracle report, withdraw lifecycle, instant redeem, eETH rate-limits");
        console2.log("");
    }

    function _flowUser(string memory tag) private returns (address u) {
        u = vm.addr(uint256(keccak256(abi.encodePacked("efi.postupgrade.flow:", tag))));
        vm.etch(u, bytes("")); // ensure EOA (no code) so NFT _safeMint + ETH receive succeed
    }

    function _approx(uint256 a, uint256 b, uint256 tol) private pure returns (bool) {
        return a > b ? a - b <= tol : b - a <= tol;
    }

    // flow 1: deposit -> eETH minted + TVL up
    function _flowDeposit() private {
        LiquidityPool lp = LiquidityPool(payable(LIQUIDITY_POOL));
        EETHToken eeth = EETHToken(EETH);
        address user = _flowUser("deposit");
        uint256 amount = 10 ether;
        vm.deal(user, amount);
        uint256 tvlBefore  = lp.getTotalPooledEther();
        uint256 eethBefore = eeth.balanceOf(user);
        vm.prank(user);
        lp.deposit{value: amount}();
        require(_approx(eeth.balanceOf(user) - eethBefore, amount, 1e9), "flow.deposit: eETH minted != deposit");
        require(_approx(lp.getTotalPooledEther() - tvlBefore, amount, 1e9), "flow.deposit: TVL not increased");
        console2.log("  [flow] deposit -> eETH + TVL OK");
    }

    // flow 2: deposit -> wrap -> unwrap round-trip
    function _flowWrapUnwrap() private {
        LiquidityPool lp = LiquidityPool(payable(LIQUIDITY_POOL));
        EETHToken eeth = EETHToken(EETH);
        WeETHToken weeth = WeETHToken(WEETH);
        address user = _flowUser("wrap");
        uint256 amount = 10 ether;
        vm.deal(user, amount);
        vm.startPrank(user);
        lp.deposit{value: amount}();
        uint256 eethBal = eeth.balanceOf(user);
        eeth.approve(address(weeth), eethBal);
        uint256 weethOut = weeth.wrap(eethBal);
        require(weethOut > 0, "flow.wrap: no weETH minted");
        require(weeth.balanceOf(user) == weethOut, "flow.wrap: weETH balance mismatch");
        uint256 eethOut = weeth.unwrap(weethOut);
        require(_approx(eethOut, eethBal, 1e9), "flow.unwrap: did not round-trip");
        vm.stopPrank();
        console2.log("  [flow] wrap/unwrap round-trip OK");
    }

    // flow 3: oracle report submit + execute (no-op finalization isolates the pipeline)
    function _flowOracleReport() private {
        EtherFiAdmin admin = EtherFiAdmin(ETHERFI_ADMIN);
        WithdrawRequestNFT wrn = WithdrawRequestNFT(payable(WITHDRAW_REQUEST_NFT));
        uint32 handledBefore = admin.lastHandledReportRefSlot();
        IEtherFiOracle.OracleReport memory report = _emptyReport();
        report.lastFinalizedWithdrawalRequestId = wrn.lastFinalizedRequestId();
        _submitAndExecuteReport(report);
        require(admin.lastHandledReportRefSlot() > handledBefore, "flow.oracle: report not handled");
        console2.log("  [flow] oracle report submit+execute OK");
    }

    // flow 4: full withdraw lifecycle request -> finalize (report) -> claim
    function _flowWithdrawLifecycle() private {
        LiquidityPool lp = LiquidityPool(payable(LIQUIDITY_POOL));
        EETHToken eeth = EETHToken(EETH);
        WithdrawRequestNFT wrn = WithdrawRequestNFT(payable(WITHDRAW_REQUEST_NFT));
        address user = _flowUser("withdraw");
        uint256 amount = 5 ether;
        vm.deal(user, amount);
        vm.startPrank(user);
        lp.deposit{value: amount}();
        eeth.approve(address(lp), amount);
        uint256 requestId = lp.requestWithdraw(user, amount);
        vm.stopPrank();
        require(wrn.ownerOf(requestId) == user, "flow.withdraw: NFT not owned by requester");
        require(wrn.getRequest(requestId).isValid, "flow.withdraw: request not valid");

        IEtherFiOracle.OracleReport memory report = _emptyReport();
        report.lastFinalizedWithdrawalRequestId = uint32(requestId);
        report.finalizedWithdrawalAmount = _sumValidRequestAmounts(uint32(requestId));
        _submitAndExecuteReport(report);
        require(wrn.lastFinalizedRequestId() >= requestId, "flow.withdraw: not finalized");

        uint256 balBefore = user.balance;
        vm.prank(user);
        wrn.claimWithdraw(requestId);
        require(_approx(user.balance - balBefore, amount, 1e12), "flow.withdraw: claim payout != requested");
        console2.log("  [flow] withdraw lifecycle request->finalize->claim OK");
    }

    // flow 5: instant redemption via EtherFiRedemptionManager
    function _flowInstantRedeem() private {
        LiquidityPool lp = LiquidityPool(payable(LIQUIDITY_POOL));
        EETHToken eeth = EETHToken(EETH);
        EtherFiRedemptionManager erm = EtherFiRedemptionManager(payable(ETHERFI_REDEMPTION_MANAGER));
        _makeRedemptionPermissive();

        address user = _flowUser("redeem");
        vm.deal(user, 2010 ether);
        address receiver = _flowUser("redeem-recv");

        vm.startPrank(user);
        lp.deposit{value: 2005 ether}();
        uint256 redeemAmount = 2000 ether;
        (, , uint16 feeBps, ) = erm.tokenToRedemptionInfo(FLOW_ETH_TOKEN);
        uint256 shares = lp.sharesForAmount(redeemAmount);
        uint256 expected = lp.amountForShare((shares * (10000 - feeBps)) / 10000);
        uint256 recvBefore = receiver.balance;
        eeth.approve(address(erm), redeemAmount);
        erm.redeemEEth(redeemAmount, receiver, FLOW_ETH_TOKEN);
        vm.stopPrank();
        require(_approx(receiver.balance - recvBefore, expected, 1e15), "flow.redeem: receiver payout wrong");
        console2.log("  [flow] instant redeem OK");
    }

    // flow 6: eETH mint/burn rate-limit consumption (buckets already at Constants values from Batch 2)
    function _flowEEthRateLimits() private {
        LiquidityPool lp = LiquidityPool(payable(LIQUIDITY_POOL));
        EETHToken eeth = EETHToken(EETH);
        EtherFiRedemptionManager erm = EtherFiRedemptionManager(payable(ETHERFI_REDEMPTION_MANAGER));
        EtherFiRateLimiter rl = EtherFiRateLimiter(payable(ETHERFI_RATE_LIMITER));

        // mint: a deposit decrements the mint bucket by ~amount (gwei)
        address u1 = _flowUser("rl-mint");
        vm.deal(u1, 100 ether);
        (, uint64 mintRemBefore, , ) = rl.getLimit(EETH_MINT_LIMIT_ID);
        vm.prank(u1);
        lp.deposit{value: 100 ether}();
        (, uint64 mintRemAfter, , ) = rl.getLimit(EETH_MINT_LIMIT_ID);
        require(mintRemBefore - mintRemAfter >= 99_000_000_000, "flow.rl: mint bucket not decremented");

        // mint over-remaining reverts LimitExceeded
        vm.prank(OPERATING_TIMELOCK);
        rl.setRemaining(EETH_MINT_LIMIT_ID, 5_000_000_000); // 5 ETH-equiv
        address u2 = _flowUser("rl-mint-over");
        vm.deal(u2, 6 ether);
        vm.prank(u2);
        vm.expectRevert(bytes4(keccak256("LimitExceeded()")));
        lp.deposit{value: 6 ether}();

        // mint refills at the configured rate
        vm.prank(OPERATING_TIMELOCK);
        rl.setRemaining(EETH_MINT_LIMIT_ID, 0);
        address u3 = _flowUser("rl-mint-refill");
        vm.deal(u3, 1 ether);
        vm.prank(u3);
        vm.expectRevert(bytes4(keccak256("LimitExceeded()")));
        lp.deposit{value: 1 ether}();
        vm.warp(block.timestamp + 10);
        require(rl.consumable(EETH_MINT_LIMIT_ID) > 1_000_000_000, "flow.rl: mint bucket did not refill");
        vm.deal(u3, 1 ether);
        vm.prank(u3);
        lp.deposit{value: 1 ether}();
        vm.prank(OPERATING_TIMELOCK);
        rl.setRemaining(EETH_MINT_LIMIT_ID, EETH_MINT_CAPACITY); // restore

        // burn: a redemption decrements the burn bucket
        _makeRedemptionPermissive();
        address u4 = _flowUser("rl-burn");
        vm.deal(u4, 200 ether);
        vm.startPrank(u4);
        lp.deposit{value: 200 ether}();
        (, uint64 burnRemBefore, , ) = rl.getLimit(EETH_BURN_LIMIT_ID);
        eeth.approve(address(erm), 50 ether);
        erm.redeemEEth(50 ether, _flowUser("rl-burn-recv"), FLOW_ETH_TOKEN);
        vm.stopPrank();
        (, uint64 burnRemAfter, , ) = rl.getLimit(EETH_BURN_LIMIT_ID);
        require(burnRemAfter < burnRemBefore, "flow.rl: burn bucket not decremented");

        // burn over-remaining reverts LimitExceeded
        vm.prank(OPERATING_TIMELOCK);
        rl.setRemaining(EETH_BURN_LIMIT_ID, 5_000_000_000);
        address u5 = _flowUser("rl-burn-over");
        vm.deal(u5, 200 ether);
        vm.startPrank(u5);
        lp.deposit{value: 200 ether}();
        eeth.approve(address(erm), 50 ether);
        vm.expectRevert(bytes4(keccak256("LimitExceeded()")));
        erm.redeemEEth(50 ether, _flowUser("rl-burn-over-recv"), FLOW_ETH_TOKEN);
        vm.stopPrank();
        vm.prank(OPERATING_TIMELOCK);
        rl.setRemaining(EETH_BURN_LIMIT_ID, EETH_BURN_CAPACITY); // restore

        // ── exact boundaries: drain each configured bucket to PRECISELY zero through its own
        //    on-chain consumer, then assert one unit over reverts LimitExceeded. Proves the limit
        //    fires exactly at the configured edge (not merely "somewhere above a small value").
        //    This is also the ONLY place the STETH_REQUEST_WITHDRAWAL bucket's enforcement is
        //    exercised, since no cheap fork flow mints a stETH withdrawal request.
        _assertExactBoundary(rl, EETH_MINT_LIMIT_ID,                EETH,             EETH_MINT_CAPACITY,                9_000_000_000, "mint");
        _assertExactBoundary(rl, EETH_BURN_LIMIT_ID,                EETH,             EETH_BURN_CAPACITY,                7_000_000_000, "burn");
        _assertExactBoundary(rl, STETH_REQUEST_WITHDRAWAL_LIMIT_ID, ETHERFI_RESTAKER, STETH_REQUEST_WITHDRAWAL_CAPACITY, 8_000_000_000, "stETH");

        console2.log("  [flow] eETH mint/burn + stETH rate-limit exact boundaries OK");
    }

    /// @dev Drain a bucket to EXACTLY zero through its whitelisted consumer, then assert that one
    ///      unit over the edge reverts LimitExceeded. A `consume(id, 0)` first flushes the
    ///      time-based refill so `lastRefill == now`; with no vm.warp before the real drain the
    ///      boundary is exact regardless of how stale the bucket was (by Step 11 the fork clock
    ///      has advanced days past the buckets' creation). Restores capacity afterwards.
    function _assertExactBoundary(
        EtherFiRateLimiter rl,
        bytes32 id,
        address consumer,
        uint64 capacity,
        uint64 drain,
        string memory tag
    ) private {
        vm.prank(consumer);
        rl.consume(id, 0); // flush refill -> lastRefill = now
        vm.prank(OPERATING_TIMELOCK);
        rl.setRemaining(id, drain);
        vm.prank(consumer);
        rl.consume(id, drain); // no elapsed time since flush -> no refill -> exact drain
        (, uint64 remaining, , ) = rl.getLimit(id);
        require(remaining == 0, string.concat("flow.rl: ", tag, " boundary not exact (remaining != 0)"));
        vm.prank(consumer);
        vm.expectRevert(bytes4(keccak256("LimitExceeded()")));
        rl.consume(id, 1); // one unit over the drained edge must revert
        vm.prank(OPERATING_TIMELOCK);
        rl.setRemaining(id, capacity); // restore
    }

    // ── post-upgrade flow helpers (ported from test/fork-tests/PostUpgradeFlows.t.sol) ──

    function _emptyReport() private view returns (IEtherFiOracle.OracleReport memory report) {
        uint256[] memory emptyVals = new uint256[](0);
        uint32 cv = EtherFiOracle(ETHERFI_ORACLE).consensusVersion();
        report = IEtherFiOracle.OracleReport(cv, 0, 0, 0, 0, 0, 0, emptyVals, 0, 0);
    }

    function _makeRedemptionPermissive() private {
        EtherFiRedemptionManager erm = EtherFiRedemptionManager(payable(ETHERFI_REDEMPTION_MANAGER));
        vm.startPrank(OPERATING_TIMELOCK);
        erm.setCapacity(100_000 ether, FLOW_ETH_TOKEN);
        erm.setRefillRatePerSecond(100_000 ether, FLOW_ETH_TOKEN);
        erm.setLowWatermarkInBpsOfTvl(0, FLOW_ETH_TOKEN);
        vm.stopPrank();
        vm.warp(block.timestamp + 1); // refill
    }

    /// @dev Advance the oracle epoch, submit via both operators, wait the post-report window,
    ///      then executeTasks. Mirrors the inline flow in test/integration-tests/Withdraw.t.sol.
    function _submitAndExecuteReport(IEtherFiOracle.OracleReport memory report) private {
        EtherFiOracle oracle = EtherFiOracle(ETHERFI_ORACLE);
        EtherFiAdmin admin = EtherFiAdmin(ETHERFI_ADMIN);
        while (true) {
            uint32 slot = oracle.slotForNextReport();
            uint32 curr = oracle.computeSlotAtTimestamp(block.timestamp);
            uint32 min = ((slot / 32) + 3) * 32;
            if (curr >= min) break;
            uint256 d = min - curr;
            vm.roll(block.number + d);
            vm.warp(oracle.beaconGenesisTimestamp() + 12 * (curr + uint32(d)));
        }

        (report.refSlotFrom, report.refSlotTo, report.refBlockFrom) = oracle.blockStampForNextReport();
        report.refBlockTo = uint32(block.number - 1);
        if (report.refBlockTo <= admin.lastAdminExecutionBlock()) {
            report.refBlockTo = admin.lastAdminExecutionBlock() + 1;
        }

        vm.prank(AVS_OPERATOR_1);
        oracle.submitReport(report);
        vm.prank(AVS_OPERATOR_2);
        oracle.submitReport(report);

        uint256 slotsToWait = uint256(admin.postReportWaitTimeInSlots() + 1);
        uint32 slotAfter = oracle.computeSlotAtTimestamp(block.timestamp);
        vm.roll(block.number + slotsToWait);
        vm.warp(oracle.beaconGenesisTimestamp() + 12 * (slotAfter + slotsToWait));

        vm.prank(ADMIN_EOA);
        admin.executeTasks(report);
    }

    function _flushPendingWithdrawalBacklog() private {
        // Finalize the pre-existing mainnet pending-withdrawal backlog so the lifecycle flow's
        // report finalizes only its own fresh request, and lift the per-day finalized cap to its
        // immutable ceiling. OPERATING_TIMELOCK already holds OPERATION_TIMELOCK_ROLE (granted in
        // Batch 1), so no self-grant is needed (scripts forbid address(this)).
        WithdrawRequestNFT wrn = WithdrawRequestNFT(payable(WITHDRAW_REQUEST_NFT));
        EtherFiAdmin admin = EtherFiAdmin(ETHERFI_ADMIN);

        uint32 head = wrn.nextRequestId();
        if (head > 0) {
            vm.prank(ETHERFI_ADMIN);
            wrn.finalizeRequests(head - 1);
        }
        // Read the ceiling BEFORE the prank — a call in the argument would consume the
        // single-shot vm.prank, leaving updateMax... to run as the script (OnlyOperatingTimelock).
        uint256 maxCap = admin.maxAcceptableFinalizedWithdrawalAmountPerDay();
        vm.prank(OPERATING_TIMELOCK);
        admin.updateMaxFinalizedWithdrawalAmountPerDay(maxCap);
    }

    function _syncOracleReportState() private {
        EtherFiOracle oracle = EtherFiOracle(ETHERFI_ORACLE);
        EtherFiAdmin admin = EtherFiAdmin(ETHERFI_ADMIN);
        uint32 lastPublished = oracle.lastPublishedReportRefSlot();
        uint32 lastHandled   = admin.lastHandledReportRefSlot();
        if (lastPublished != lastHandled) {
            // Align EtherFiAdmin.lastHandledReportRefSlot/Block (packed in slot 209) with the
            // oracle's last published report so the next report is cleanly "the next one".
            uint32 lastPublishedBlock = oracle.lastPublishedReportRefBlock();
            uint256 val = uint256(vm.load(address(admin), bytes32(uint256(209))));
            val &= ~uint256(0xFFFFFFFFFFFFFFFF);
            val |= uint256(lastPublished);
            val |= uint256(lastPublishedBlock) << 32;
            vm.store(address(admin), bytes32(uint256(209)), bytes32(val));
        }
        // NOTE: no committee reconfiguration. AVS_OPERATOR_1/2 are active committee members on
        // mainnet, and `submitReport` consumes the live storage `quorumSize` (2) at runtime — the
        // post-upgrade `minQuorumSize`=3 floor only gates committee-management calls (_checkQuorum),
        // not report submission. So submitting from the 2 active operators for a fresh report
        // period reaches quorum without touching the committee (which can't shrink below the
        // min-quorum floor anyway, hence the original toggle reverted InvalidQuorum post-upgrade).
    }

    function _sumValidRequestAmounts(uint32 _lastFinalizedRequestIdInclusive) private view returns (uint128) {
        WithdrawRequestNFT wrn = WithdrawRequestNFT(payable(WITHDRAW_REQUEST_NFT));
        uint256 sum;
        uint32 from = wrn.lastFinalizedRequestId() + 1;
        for (uint256 i = from; i <= _lastFinalizedRequestIdInclusive; i++) {
            IWithdrawRequestNFT.WithdrawRequest memory r = wrn.getRequest(i);
            if (r.isValid) sum += r.amountOfEEth;
        }
        return uint128(sum);
    }
}
