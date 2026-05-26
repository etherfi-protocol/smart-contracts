// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {EtherFiTimelock} from "../../../src/EtherFiTimelock.sol";

import {Deployed} from "../../deploys/Deployed.s.sol";
import {Utils} from "../../utils/utils.sol";

/**
 * 26Q2 Security Upgrades - REVERT Script
 *
 * Re-points every proxy touched by transactions.s.sol back at its pre-upgrade
 * implementation. Use this only if you need to roll the binary upgrade back.
 *
 * Limits of what this script reverts:
 *
 *   IT REVERTS:
 *     - The ERC1967 implementation slot on each of the 22 proxies. After
 *       execution, each proxy delegates to the original impl address again.
 *
 *   IT DOES NOT REVERT:
 *     - The one-shot post-upgrade migration calls
 *       (LiquidityPool.initializeOnUpgradeV2,
 *        WithdrawRequestNFT.initializeShareRateFreezeUpgrade).
 *       Those wrote new storage — the old impls won't read it, but the slots
 *       remain set. If you re-upgrade later, expect re-entry checks to skip.
 *     - The EtherFiRateLimiter bucket creation
 *       (createNewLimiter / updateConsumers). Buckets remain configured.
 *     - PausableUntil durations set on each contract. The namespaced storage
 *       slot still holds the value; old impls just ignore it.
 *     - RoleRegistry grants. Roles persist independently of any impl pointer.
 *     - LP min/max withdraw bounds seeded by executeLpWithdrawBounds().
 *
 * If you need any of the above undone, write a separate operation. This
 * script intentionally has the smallest possible blast radius: 22
 * `upgradeTo(oldImpl)` calls.
 *
 * Every PRE_* constant below must be refreshed from the current mainnet
 * ERC1967 implementation slot before broadcasting. _preflight() reverts if
 * any is still address(0). Query template:
 *   cast storage <proxy> 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url $MAINNET_RPC_URL
 *
 * Run:
 *   forge script script/upgrades/security-upgrades/revert.s.sol:SecurityUpgradesRevertScript \
 *       --fork-url $MAINNET_RPC_URL -vvvv
 */
contract SecurityUpgradesRevertScript is Script, Deployed, Utils {
    // ─────────────────────────────────────────────────────────────────────
    // PRE-UPGRADE IMPLEMENTATIONS — fill from a fresh mainnet snapshot.
    // Source: ERC1967 impl slot read via UUPSProxy's custom slot:
    //         0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
    // _preflight() asserts every entry is non-zero before doing anything.
    // ─────────────────────────────────────────────────────────────────────
    address constant PRE_EETH                                = address(0);
    address constant PRE_WEETH                               = address(0);
    address constant PRE_LIQUIDITY_POOL                      = address(0);
    address constant PRE_WITHDRAW_REQUEST_NFT                = address(0);
    address constant PRE_LIQUIFIER                           = address(0);
    address constant PRE_ETHERFI_ADMIN                       = address(0);
    address constant PRE_ETHERFI_ORACLE                      = address(0);
    address constant PRE_ETHERFI_REDEMPTION_MANAGER          = address(0);
    address constant PRE_ETHERFI_RESTAKER                    = address(0);
    address constant PRE_ETHERFI_NODES_MANAGER               = address(0);
    address constant PRE_STAKING_MANAGER                     = address(0);
    address constant PRE_AUCTION_MANAGER                     = address(0);
    address constant PRE_NODE_OPERATOR_MANAGER               = address(0);
    address constant PRE_MEMBERSHIP_MANAGER                  = address(0);
    address constant PRE_MEMBERSHIP_NFT                      = address(0);
    address constant PRE_ETHERFI_RATE_LIMITER                = address(0);
    address constant PRE_PRIORITY_WITHDRAWAL_QUEUE           = address(0);
    address constant PRE_ETHERFI_REWARDS_ROUTER              = address(0);
    address constant PRE_RESTAKING_REWARDS_ROUTER            = address(0);
    address constant PRE_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR = address(0);
    address constant PRE_DEPOSIT_ADAPTER                     = address(0);
    address constant PRE_WEETH_WITHDRAW_ADAPTER              = address(0);

    EtherFiTimelock constant upgradeTimelock = EtherFiTimelock(payable(UPGRADE_TIMELOCK));
    uint256 constant UPGRADE_TIMELOCK_DELAY = 10 days;
    string constant OUT_DIR = "script/upgrades/security-upgrades";

    struct Snap { address owner; bool paused; }
    mapping(address => Snap) internal preRevertSnap;

    function run() public {
        string memory forkUrl = vm.envString("MAINNET_RPC_URL");
        vm.selectFork(vm.createFork(forkUrl));

        _preflight();
        confirmCurrentlyOnNewImpl();
        takePreRevertSnapshots();
        executeRevert();
        verifyReverted();
        verifyAccessControlPreservation();
    }

    /// @dev Fail loudly the moment a required PRE_* constant is unset.
    function _preflight() internal pure {
        require(PRE_EETH                                != address(0), "preflight: PRE_EETH unset");
        require(PRE_WEETH                               != address(0), "preflight: PRE_WEETH unset");
        require(PRE_LIQUIDITY_POOL                      != address(0), "preflight: PRE_LIQUIDITY_POOL unset");
        require(PRE_WITHDRAW_REQUEST_NFT                != address(0), "preflight: PRE_WITHDRAW_REQUEST_NFT unset");
        require(PRE_LIQUIFIER                           != address(0), "preflight: PRE_LIQUIFIER unset");
        require(PRE_ETHERFI_ADMIN                       != address(0), "preflight: PRE_ETHERFI_ADMIN unset");
        require(PRE_ETHERFI_ORACLE                      != address(0), "preflight: PRE_ETHERFI_ORACLE unset");
        require(PRE_ETHERFI_REDEMPTION_MANAGER          != address(0), "preflight: PRE_ETHERFI_REDEMPTION_MANAGER unset");
        require(PRE_ETHERFI_RESTAKER                    != address(0), "preflight: PRE_ETHERFI_RESTAKER unset");
        require(PRE_ETHERFI_NODES_MANAGER               != address(0), "preflight: PRE_ETHERFI_NODES_MANAGER unset");
        require(PRE_STAKING_MANAGER                     != address(0), "preflight: PRE_STAKING_MANAGER unset");
        require(PRE_AUCTION_MANAGER                     != address(0), "preflight: PRE_AUCTION_MANAGER unset");
        require(PRE_NODE_OPERATOR_MANAGER               != address(0), "preflight: PRE_NODE_OPERATOR_MANAGER unset");
        require(PRE_MEMBERSHIP_MANAGER                  != address(0), "preflight: PRE_MEMBERSHIP_MANAGER unset");
        require(PRE_MEMBERSHIP_NFT                      != address(0), "preflight: PRE_MEMBERSHIP_NFT unset");
        require(PRE_ETHERFI_RATE_LIMITER                != address(0), "preflight: PRE_ETHERFI_RATE_LIMITER unset");
        require(PRE_PRIORITY_WITHDRAWAL_QUEUE           != address(0), "preflight: PRE_PRIORITY_WITHDRAWAL_QUEUE unset");
        require(PRE_ETHERFI_REWARDS_ROUTER              != address(0), "preflight: PRE_ETHERFI_REWARDS_ROUTER unset");
        require(PRE_RESTAKING_REWARDS_ROUTER            != address(0), "preflight: PRE_RESTAKING_REWARDS_ROUTER unset");
        require(PRE_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR != address(0), "preflight: PRE_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR unset");
        require(PRE_DEPOSIT_ADAPTER                     != address(0), "preflight: PRE_DEPOSIT_ADAPTER unset");
        require(PRE_WEETH_WITHDRAW_ADAPTER              != address(0), "preflight: PRE_WEETH_WITHDRAW_ADAPTER unset");
    }

    /// @notice Sanity check: every proxy is currently NOT on the pre-upgrade
    ///         impl. If they already are, the revert is a no-op and we abort
    ///         loudly to avoid scheduling a useless 10-day timelock.
    function confirmCurrentlyOnNewImpl() public view {
        console2.log("=== Step 0: Confirming proxies are on the new impl ===");
        _assertNotAlreadyOnPre(EETH,                                PRE_EETH,                                "EETH");
        _assertNotAlreadyOnPre(WEETH,                               PRE_WEETH,                               "WeETH");
        _assertNotAlreadyOnPre(LIQUIDITY_POOL,                      PRE_LIQUIDITY_POOL,                      "LiquidityPool");
        _assertNotAlreadyOnPre(WITHDRAW_REQUEST_NFT,                PRE_WITHDRAW_REQUEST_NFT,                "WithdrawRequestNFT");
        _assertNotAlreadyOnPre(LIQUIFIER,                           PRE_LIQUIFIER,                           "Liquifier");
        _assertNotAlreadyOnPre(ETHERFI_ADMIN,                       PRE_ETHERFI_ADMIN,                       "EtherFiAdmin");
        _assertNotAlreadyOnPre(ETHERFI_ORACLE,                      PRE_ETHERFI_ORACLE,                      "EtherFiOracle");
        _assertNotAlreadyOnPre(ETHERFI_REDEMPTION_MANAGER,          PRE_ETHERFI_REDEMPTION_MANAGER,          "EtherFiRedemptionManager");
        _assertNotAlreadyOnPre(ETHERFI_RESTAKER,                    PRE_ETHERFI_RESTAKER,                    "EtherFiRestaker");
        _assertNotAlreadyOnPre(ETHERFI_NODES_MANAGER,               PRE_ETHERFI_NODES_MANAGER,               "EtherFiNodesManager");
        _assertNotAlreadyOnPre(STAKING_MANAGER,                     PRE_STAKING_MANAGER,                     "StakingManager");
        _assertNotAlreadyOnPre(AUCTION_MANAGER,                     PRE_AUCTION_MANAGER,                     "AuctionManager");
        _assertNotAlreadyOnPre(NODE_OPERATOR_MANAGER,               PRE_NODE_OPERATOR_MANAGER,               "NodeOperatorManager");
        _assertNotAlreadyOnPre(MEMBERSHIP_MANAGER,                  PRE_MEMBERSHIP_MANAGER,                  "MembershipManager");
        _assertNotAlreadyOnPre(MEMBERSHIP_NFT,                      PRE_MEMBERSHIP_NFT,                      "MembershipNFT");
        _assertNotAlreadyOnPre(ETHERFI_RATE_LIMITER,                PRE_ETHERFI_RATE_LIMITER,                "EtherFiRateLimiter");
        _assertNotAlreadyOnPre(PRIORITY_WITHDRAWAL_QUEUE,           PRE_PRIORITY_WITHDRAWAL_QUEUE,           "PriorityWithdrawalQueue");
        _assertNotAlreadyOnPre(ETHERFI_REWARDS_ROUTER,              PRE_ETHERFI_REWARDS_ROUTER,              "EtherFiRewardsRouter");
        _assertNotAlreadyOnPre(RESTAKING_REWARDS_ROUTER,            PRE_RESTAKING_REWARDS_ROUTER,            "RestakingRewardsRouter");
        _assertNotAlreadyOnPre(CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR, PRE_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR, "CumulativeMerkleRewardsDistributor");
        _assertNotAlreadyOnPre(DEPOSIT_ADAPTER,                     PRE_DEPOSIT_ADAPTER,                     "DepositAdapter");
        _assertNotAlreadyOnPre(WEETH_WITHDRAW_ADAPTER,              PRE_WEETH_WITHDRAW_ADAPTER,              "WeETHWithdrawAdapter");
        console2.log("[OK] all 22 proxies are on post-upgrade impls; revert is meaningful");
        console2.log("");
    }

    function _assertNotAlreadyOnPre(address proxy, address pre, string memory name) internal view {
        address current = getImplementation(proxy);
        require(current != pre, string.concat(name, ": already on pre-upgrade impl - nothing to revert"));
        console2.log(string.concat("[CURRENT] ", name), current);
    }

    function takePreRevertSnapshots() public {
        console2.log("=== Step 1: Snapshotting owner+paused before revert ===");
        address[22] memory p = _proxies();
        for (uint256 i = 0; i < p.length; i++) {
            preRevertSnap[p[i]] = Snap({ owner: _getOwner(p[i]), paused: _getPaused(p[i]) });
        }
        console2.log("[OK] snapshot taken for 22 proxies");
        console2.log("");
    }

    function executeRevert() public {
        console2.log("=== Step 2: Executing revert (UPGRADE_TIMELOCK, 10d) ===");

        address[] memory targets = new address[](22);
        bytes[]   memory data    = new bytes[](22);
        uint256[] memory values  = new uint256[](22);

        targets[0]  = EETH;                                data[0]  = _upgradeTo(PRE_EETH);
        targets[1]  = WEETH;                               data[1]  = _upgradeTo(PRE_WEETH);
        targets[2]  = LIQUIDITY_POOL;                      data[2]  = _upgradeTo(PRE_LIQUIDITY_POOL);
        targets[3]  = WITHDRAW_REQUEST_NFT;                data[3]  = _upgradeTo(PRE_WITHDRAW_REQUEST_NFT);
        targets[4]  = LIQUIFIER;                           data[4]  = _upgradeTo(PRE_LIQUIFIER);
        targets[5]  = ETHERFI_ADMIN;                       data[5]  = _upgradeTo(PRE_ETHERFI_ADMIN);
        targets[6]  = ETHERFI_ORACLE;                      data[6]  = _upgradeTo(PRE_ETHERFI_ORACLE);
        targets[7]  = ETHERFI_REDEMPTION_MANAGER;          data[7]  = _upgradeTo(PRE_ETHERFI_REDEMPTION_MANAGER);
        targets[8]  = ETHERFI_RESTAKER;                    data[8]  = _upgradeTo(PRE_ETHERFI_RESTAKER);
        targets[9]  = ETHERFI_NODES_MANAGER;               data[9]  = _upgradeTo(PRE_ETHERFI_NODES_MANAGER);
        targets[10] = STAKING_MANAGER;                     data[10] = _upgradeTo(PRE_STAKING_MANAGER);
        targets[11] = AUCTION_MANAGER;                     data[11] = _upgradeTo(PRE_AUCTION_MANAGER);
        targets[12] = NODE_OPERATOR_MANAGER;               data[12] = _upgradeTo(PRE_NODE_OPERATOR_MANAGER);
        targets[13] = MEMBERSHIP_MANAGER;                  data[13] = _upgradeTo(PRE_MEMBERSHIP_MANAGER);
        targets[14] = MEMBERSHIP_NFT;                      data[14] = _upgradeTo(PRE_MEMBERSHIP_NFT);
        targets[15] = ETHERFI_RATE_LIMITER;                data[15] = _upgradeTo(PRE_ETHERFI_RATE_LIMITER);
        targets[16] = PRIORITY_WITHDRAWAL_QUEUE;           data[16] = _upgradeTo(PRE_PRIORITY_WITHDRAWAL_QUEUE);
        targets[17] = ETHERFI_REWARDS_ROUTER;              data[17] = _upgradeTo(PRE_ETHERFI_REWARDS_ROUTER);
        targets[18] = RESTAKING_REWARDS_ROUTER;            data[18] = _upgradeTo(PRE_RESTAKING_REWARDS_ROUTER);
        targets[19] = CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR; data[19] = _upgradeTo(PRE_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR);
        targets[20] = DEPOSIT_ADAPTER;                     data[20] = _upgradeTo(PRE_DEPOSIT_ADAPTER);
        targets[21] = WEETH_WITHDRAW_ADAPTER;              data[21] = _upgradeTo(PRE_WEETH_WITHDRAW_ADAPTER);

        bytes32 salt = keccak256(abi.encode("security-upgrades-v1-REVERT", block.number));

        bytes memory scheduleCalldata = abi.encodeWithSelector(
            upgradeTimelock.scheduleBatch.selector,
            targets, values, data, bytes32(0), salt, UPGRADE_TIMELOCK_DELAY
        );
        bytes memory executeCalldata = abi.encodeWithSelector(
            upgradeTimelock.executeBatch.selector,
            targets, values, data, bytes32(0), salt
        );

        writeSafeJson(OUT_DIR, "revert_schedule.json", ETHERFI_UPGRADE_ADMIN, UPGRADE_TIMELOCK, 0, scheduleCalldata, 1);
        writeSafeJson(OUT_DIR, "revert_execute.json",  ETHERFI_UPGRADE_ADMIN, UPGRADE_TIMELOCK, 0, executeCalldata,  1);

        console2.log("=== Dry-running revert on fork ===");
        vm.startPrank(ETHERFI_UPGRADE_ADMIN);
        upgradeTimelock.scheduleBatch(targets, values, data, bytes32(0), salt, UPGRADE_TIMELOCK_DELAY);
        vm.warp(block.timestamp + UPGRADE_TIMELOCK_DELAY + 1);
        upgradeTimelock.executeBatch(targets, values, data, bytes32(0), salt);
        vm.stopPrank();
        console2.log("[OK] revert executed on fork");
        console2.log("");
    }

    function verifyReverted() public view {
        console2.log("=== Step 3: Verifying impl slot reverted ===");
        _assertImpl(EETH,                                PRE_EETH,                                "EETH");
        _assertImpl(WEETH,                               PRE_WEETH,                               "WeETH");
        _assertImpl(LIQUIDITY_POOL,                      PRE_LIQUIDITY_POOL,                      "LiquidityPool");
        _assertImpl(WITHDRAW_REQUEST_NFT,                PRE_WITHDRAW_REQUEST_NFT,                "WithdrawRequestNFT");
        _assertImpl(LIQUIFIER,                           PRE_LIQUIFIER,                           "Liquifier");
        _assertImpl(ETHERFI_ADMIN,                       PRE_ETHERFI_ADMIN,                       "EtherFiAdmin");
        _assertImpl(ETHERFI_ORACLE,                      PRE_ETHERFI_ORACLE,                      "EtherFiOracle");
        _assertImpl(ETHERFI_REDEMPTION_MANAGER,          PRE_ETHERFI_REDEMPTION_MANAGER,          "EtherFiRedemptionManager");
        _assertImpl(ETHERFI_RESTAKER,                    PRE_ETHERFI_RESTAKER,                    "EtherFiRestaker");
        _assertImpl(ETHERFI_NODES_MANAGER,               PRE_ETHERFI_NODES_MANAGER,               "EtherFiNodesManager");
        _assertImpl(STAKING_MANAGER,                     PRE_STAKING_MANAGER,                     "StakingManager");
        _assertImpl(AUCTION_MANAGER,                     PRE_AUCTION_MANAGER,                     "AuctionManager");
        _assertImpl(NODE_OPERATOR_MANAGER,               PRE_NODE_OPERATOR_MANAGER,               "NodeOperatorManager");
        _assertImpl(MEMBERSHIP_MANAGER,                  PRE_MEMBERSHIP_MANAGER,                  "MembershipManager");
        _assertImpl(MEMBERSHIP_NFT,                      PRE_MEMBERSHIP_NFT,                      "MembershipNFT");
        _assertImpl(ETHERFI_RATE_LIMITER,                PRE_ETHERFI_RATE_LIMITER,                "EtherFiRateLimiter");
        _assertImpl(PRIORITY_WITHDRAWAL_QUEUE,           PRE_PRIORITY_WITHDRAWAL_QUEUE,           "PriorityWithdrawalQueue");
        _assertImpl(ETHERFI_REWARDS_ROUTER,              PRE_ETHERFI_REWARDS_ROUTER,              "EtherFiRewardsRouter");
        _assertImpl(RESTAKING_REWARDS_ROUTER,            PRE_RESTAKING_REWARDS_ROUTER,            "RestakingRewardsRouter");
        _assertImpl(CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR, PRE_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR, "CumulativeMerkleRewardsDistributor");
        _assertImpl(DEPOSIT_ADAPTER,                     PRE_DEPOSIT_ADAPTER,                     "DepositAdapter");
        _assertImpl(WEETH_WITHDRAW_ADAPTER,              PRE_WEETH_WITHDRAW_ADAPTER,              "WeETHWithdrawAdapter");
        console2.log("");
    }

    function _assertImpl(address proxy, address expected, string memory name) internal view {
        address actual = getImplementation(proxy);
        require(actual == expected, string.concat(name, ": revert failed (impl slot mismatch)"));
        console2.log(string.concat("[REVERTED] ", name), actual);
    }

    function verifyAccessControlPreservation() public view {
        console2.log("=== Step 4: Verifying owner + paused unchanged ===");
        address[22] memory p = _proxies();
        for (uint256 i = 0; i < p.length; i++) {
            Snap memory pre = preRevertSnap[p[i]];
            require(_getOwner(p[i])  == pre.owner,  string.concat("owner changed across revert: ", vm.toString(p[i])));
            require(_getPaused(p[i]) == pre.paused, string.concat("paused changed across revert: ", vm.toString(p[i])));
        }
        console2.log("[OK] owner + paused unchanged on all 22 proxies");
        console2.log("");
    }

    function _proxies() internal pure returns (address[22] memory list) {
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

    function _upgradeTo(address impl) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, impl);
    }
}
