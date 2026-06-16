// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {StakingManager} from "@etherfi/staking/StakingManager.sol";

import {Utils} from "@scripts/utils/utils.sol";
import {SecurityUpgradesConstants} from "./Constants.s.sol";

/**
 * 26Q2 Security Upgrades - REVERT Script
 *
 * Re-points every proxy touched by transactions.s.sol back at its pre-upgrade
 * implementation. Use this only if you need to roll the binary upgrade back.
 *
 * Limits of what this script reverts:
 *
 *   IT REVERTS:
 *     - The ERC1967 implementation slot on each of the 22 proxies plus the
 *       RoleRegistry. After execution, each proxy delegates to the original
 *       impl address again. RoleRegistry is reverted last (see executeRevert).
 *     - The EtherFiNode beacon implementation. EtherFiNode is a beacon proxy,
 *       not UUPS, so it is re-pointed via StakingManager.upgradeEtherFiNode
 *       (the beacon owner), not upgradeTo. Done before the StakingManager proxy
 *       revert and well before the RoleRegistry revert, so the new impl's
 *       onlyUpgradeTimelock gate still authorizes it.
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
 * script intentionally has the smallest possible blast radius: 23
 * `upgradeTo(oldImpl)` calls (22 proxies + RoleRegistry) plus one
 * `StakingManager.upgradeEtherFiNode(oldImpl)` beacon revert.
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
contract SecurityUpgradesRevertScript is Script, SecurityUpgradesConstants, Utils {
    // ─────────────────────────────────────────────────────────────────────
    // PRE-UPGRADE IMPLEMENTATIONS — fill from a fresh mainnet snapshot.
    // Source: ERC1967 impl slot read via UUPSProxy's custom slot:
    //         0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
    // _preflight() asserts every entry is non-zero before doing anything.
    // Ordered by src/ group: core, deposits, governance, membership, oracle,
    // restaking, rewards, staking, withdrawals.
    // ─────────────────────────────────────────────────────────────────────
    // core
    address constant PRE_EETH                                = 0xCB3D917A965A70214f430a135154Cd5ADdA2ad84;
    address constant PRE_LIQUIDITY_POOL                      = 0x83bc649fCdb2c8DA146b2154a559ddEDf937eF12;
    address constant PRE_WEETH                               = 0x2d10683E941275D502173053927AD6066e6aFd6B;
    // deposits
    address constant PRE_DEPOSIT_ADAPTER                     = 0xE87797A1aFb329216811dfA22C87380128CA17d8;
    address constant PRE_LIQUIFIER                           = 0x0E7489D32D34CCdC12d7092067bf53Aa38bf2BF6;
    // governance
    address constant PRE_ROLE_REGISTRY                       = 0x3A75019F8b09c278D152279d446c97d009E064f3;
    address constant PRE_ETHERFI_RATE_LIMITER                = 0x1dd43C32f03f8A74b8160926D559d34358880A89;
    // membership
    address constant PRE_MEMBERSHIP_MANAGER                  = 0x047A7749AD683C2Fd8A27C7904Ca8dD128F15889;
    address constant PRE_MEMBERSHIP_NFT                      = 0x290d981b41B713437265Cd7846806D7500307106;
    // oracle
    address constant PRE_ETHERFI_ADMIN                       = 0xd50f28485A75A1FdE432BA7d012d0E2543D2f20d;
    address constant PRE_ETHERFI_ORACLE                      = 0x5eefE6f65a280A6f1Eb1FdFf36Ab9e2af6f38462;
    // restaking
    address constant PRE_ETHERFI_RESTAKER                    = 0x9D795b303B9dA3488FD3A4ca4702c872576BD0c6;
    address constant PRE_RESTAKING_REWARDS_ROUTER            = 0xcB6e9a5943946307815eaDF3BEDC49fE30290CA8;
    // rewards
    address constant PRE_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR = 0xD3F3480511FB25a3D86568B6e1eFBa09d0aDEebF;
    address constant PRE_ETHERFI_REWARDS_ROUTER              = 0x408de8D339F40086c5643EE4778E0F872aB5E423;
    // staking
    address constant PRE_AUCTION_MANAGER                     = 0x68FE80C6e97E0c8613e2FED344358c6635ba5366;
    // EtherFiNode is a beacon proxy: its pre-upgrade impl is NOT in any ERC1967
    // slot. Read it from the beacon via StakingManager.implementation():
    //   cast call <STAKING_MANAGER> "implementation()(address)" --rpc-url $MAINNET_RPC_URL
    address constant PRE_ETHERFI_NODE_IMPL                   = 0xA91F8a52F0C1b4D3fDC256fC5bEBCA4D627da392;
    address constant PRE_ETHERFI_NODES_MANAGER               = 0x789CbBe0739F1458905C9Ca6d6e74f7997622A9B;
    address constant PRE_NODE_OPERATOR_MANAGER               = 0xfcC674Fc9A0602692D2a91905E7e978aE6EE2cAF;
    address constant PRE_STAKING_MANAGER                     = 0xd3985048Bf1Cb613F5E199713a86B2aD3954F82A;
    // withdrawals
    address constant PRE_ETHERFI_REDEMPTION_MANAGER          = 0x6BD191582F40012b2f2cdf66bD3D32bDe41191F7;
    address constant PRE_PRIORITY_WITHDRAWAL_QUEUE           = 0x554B2a0c78840bBD4fDB24e198cdD93f99E29456;
    address constant PRE_WEETH_WITHDRAW_ADAPTER              = 0x3f313F0A856aE12b0A16178e29B6Ada84c256952;
    address constant PRE_WITHDRAW_REQUEST_NFT                = 0x2f4A5921FcAB46F1F3154e8b42Fc189e08fae3Ed;

    // upgradeTimelock, UPGRADE_TIMELOCK_DELAY, OUT_DIR, GIT_COMMIT_SHA and
    // commitHashSalt all come from Constants.s.sol (SecurityUpgradesConstants).

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
        require(GIT_COMMIT_SHA != bytes20(0), "preflight: GIT_COMMIT_SHA unset - set to first 20 bytes of release commit");
        // core
        require(PRE_EETH                                != address(0), "preflight: PRE_EETH unset");
        require(PRE_LIQUIDITY_POOL                      != address(0), "preflight: PRE_LIQUIDITY_POOL unset");
        require(PRE_WEETH                               != address(0), "preflight: PRE_WEETH unset");
        // deposits
        require(PRE_DEPOSIT_ADAPTER                     != address(0), "preflight: PRE_DEPOSIT_ADAPTER unset");
        require(PRE_LIQUIFIER                           != address(0), "preflight: PRE_LIQUIFIER unset");
        // governance
        require(PRE_ROLE_REGISTRY                       != address(0), "preflight: PRE_ROLE_REGISTRY unset");
        require(PRE_ETHERFI_RATE_LIMITER                != address(0), "preflight: PRE_ETHERFI_RATE_LIMITER unset");
        // membership
        require(PRE_MEMBERSHIP_MANAGER                  != address(0), "preflight: PRE_MEMBERSHIP_MANAGER unset");
        require(PRE_MEMBERSHIP_NFT                      != address(0), "preflight: PRE_MEMBERSHIP_NFT unset");
        // oracle
        require(PRE_ETHERFI_ADMIN                       != address(0), "preflight: PRE_ETHERFI_ADMIN unset");
        require(PRE_ETHERFI_ORACLE                      != address(0), "preflight: PRE_ETHERFI_ORACLE unset");
        // restaking
        require(PRE_ETHERFI_RESTAKER                    != address(0), "preflight: PRE_ETHERFI_RESTAKER unset");
        require(PRE_RESTAKING_REWARDS_ROUTER            != address(0), "preflight: PRE_RESTAKING_REWARDS_ROUTER unset");
        // rewards
        require(PRE_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR != address(0), "preflight: PRE_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR unset");
        require(PRE_ETHERFI_REWARDS_ROUTER              != address(0), "preflight: PRE_ETHERFI_REWARDS_ROUTER unset");
        // staking
        require(PRE_AUCTION_MANAGER                     != address(0), "preflight: PRE_AUCTION_MANAGER unset");
        require(PRE_ETHERFI_NODE_IMPL                   != address(0), "preflight: PRE_ETHERFI_NODE_IMPL unset");
        require(PRE_ETHERFI_NODES_MANAGER               != address(0), "preflight: PRE_ETHERFI_NODES_MANAGER unset");
        require(PRE_NODE_OPERATOR_MANAGER               != address(0), "preflight: PRE_NODE_OPERATOR_MANAGER unset");
        require(PRE_STAKING_MANAGER                     != address(0), "preflight: PRE_STAKING_MANAGER unset");
        // withdrawals
        require(PRE_ETHERFI_REDEMPTION_MANAGER          != address(0), "preflight: PRE_ETHERFI_REDEMPTION_MANAGER unset");
        require(PRE_PRIORITY_WITHDRAWAL_QUEUE           != address(0), "preflight: PRE_PRIORITY_WITHDRAWAL_QUEUE unset");
        require(PRE_WEETH_WITHDRAW_ADAPTER              != address(0), "preflight: PRE_WEETH_WITHDRAW_ADAPTER unset");
        require(PRE_WITHDRAW_REQUEST_NFT                != address(0), "preflight: PRE_WITHDRAW_REQUEST_NFT unset");
    }

    /// @notice Sanity check: every proxy is currently NOT on the pre-upgrade
    ///         impl. If they already are, the revert is a no-op and we abort
    ///         loudly to avoid scheduling a useless 10-day timelock.
    function confirmCurrentlyOnNewImpl() public view {
        console2.log("=== Step 0: Confirming proxies are on the new impl ===");
        // core
        _assertNotAlreadyOnPre(EETH,                                PRE_EETH,                                "EETH");
        _assertNotAlreadyOnPre(LIQUIDITY_POOL,                      PRE_LIQUIDITY_POOL,                      "LiquidityPool");
        _assertNotAlreadyOnPre(WEETH,                               PRE_WEETH,                               "WeETH");
        // deposits
        _assertNotAlreadyOnPre(DEPOSIT_ADAPTER,                     PRE_DEPOSIT_ADAPTER,                     "DepositAdapter");
        _assertNotAlreadyOnPre(LIQUIFIER,                           PRE_LIQUIFIER,                           "Liquifier");
        // governance
        _assertNotAlreadyOnPre(ROLE_REGISTRY,                       PRE_ROLE_REGISTRY,                       "RoleRegistry");
        _assertNotAlreadyOnPre(ETHERFI_RATE_LIMITER,                PRE_ETHERFI_RATE_LIMITER,                "EtherFiRateLimiter");
        // membership
        _assertNotAlreadyOnPre(MEMBERSHIP_MANAGER,                  PRE_MEMBERSHIP_MANAGER,                  "MembershipManager");
        _assertNotAlreadyOnPre(MEMBERSHIP_NFT,                      PRE_MEMBERSHIP_NFT,                      "MembershipNFT");
        // oracle
        _assertNotAlreadyOnPre(ETHERFI_ADMIN,                       PRE_ETHERFI_ADMIN,                       "EtherFiAdmin");
        _assertNotAlreadyOnPre(ETHERFI_ORACLE,                      PRE_ETHERFI_ORACLE,                      "EtherFiOracle");
        // restaking
        _assertNotAlreadyOnPre(ETHERFI_RESTAKER,                    PRE_ETHERFI_RESTAKER,                    "EtherFiRestaker");
        _assertNotAlreadyOnPre(RESTAKING_REWARDS_ROUTER,            PRE_RESTAKING_REWARDS_ROUTER,            "RestakingRewardsRouter");
        // rewards
        _assertNotAlreadyOnPre(CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR, PRE_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR, "CumulativeMerkleRewardsDistributor");
        _assertNotAlreadyOnPre(ETHERFI_REWARDS_ROUTER,              PRE_ETHERFI_REWARDS_ROUTER,              "EtherFiRewardsRouter");
        // staking
        _assertNotAlreadyOnPre(AUCTION_MANAGER,                     PRE_AUCTION_MANAGER,                     "AuctionManager");
        // EtherFiNode beacon impl is read from the beacon, not an ERC1967 slot.
        address currentNodeImpl = StakingManager(STAKING_MANAGER).implementation();
        require(currentNodeImpl != PRE_ETHERFI_NODE_IMPL, "EtherFiNode beacon: already on pre-upgrade impl - nothing to revert");
        console2.log("[CURRENT] EtherFiNode beacon", currentNodeImpl);
        _assertNotAlreadyOnPre(ETHERFI_NODES_MANAGER,               PRE_ETHERFI_NODES_MANAGER,               "EtherFiNodesManager");
        _assertNotAlreadyOnPre(NODE_OPERATOR_MANAGER,               PRE_NODE_OPERATOR_MANAGER,               "NodeOperatorManager");
        _assertNotAlreadyOnPre(STAKING_MANAGER,                     PRE_STAKING_MANAGER,                     "StakingManager");
        // withdrawals
        _assertNotAlreadyOnPre(ETHERFI_REDEMPTION_MANAGER,          PRE_ETHERFI_REDEMPTION_MANAGER,          "EtherFiRedemptionManager");
        _assertNotAlreadyOnPre(PRIORITY_WITHDRAWAL_QUEUE,           PRE_PRIORITY_WITHDRAWAL_QUEUE,           "PriorityWithdrawalQueue");
        _assertNotAlreadyOnPre(WEETH_WITHDRAW_ADAPTER,              PRE_WEETH_WITHDRAW_ADAPTER,              "WeETHWithdrawAdapter");
        _assertNotAlreadyOnPre(WITHDRAW_REQUEST_NFT,                PRE_WITHDRAW_REQUEST_NFT,                "WithdrawRequestNFT");
        console2.log("[OK] RoleRegistry + 22 proxies + EtherFiNode beacon are on post-upgrade impls; revert is meaningful");
        console2.log("");
    }

    function _assertNotAlreadyOnPre(address proxy, address pre, string memory name) internal view {
        address current = getImplementation(proxy);
        require(current != pre, string.concat(name, ": already on pre-upgrade impl - nothing to revert"));
        console2.log(string.concat("[CURRENT] ", name), current);
    }

    function takePreRevertSnapshots() public {
        console2.log("=== Step 1: Snapshotting owner+paused before revert ===");
        address[23] memory p = _proxies();
        for (uint256 i = 0; i < p.length; i++) {
            preRevertSnap[p[i]] = Snap({ owner: _getOwner(p[i]), paused: _getPaused(p[i]) });
        }
        console2.log("[OK] snapshot taken for 23 proxies");
        console2.log("");
    }

    function executeRevert() public {
        console2.log("=== Step 2: Executing revert (UPGRADE_TIMELOCK, 10d) ===");

        address[] memory targets = new address[](24);
        bytes[]   memory data    = new bytes[](24);
        uint256[] memory values  = new uint256[](24);
        uint256 i;

        // core
        (targets[i], data[i]) = (EETH,                       _upgradeTo(PRE_EETH));                          i++;
        (targets[i], data[i]) = (LIQUIDITY_POOL,             _upgradeTo(PRE_LIQUIDITY_POOL));                i++;
        (targets[i], data[i]) = (WEETH,                      _upgradeTo(PRE_WEETH));                         i++;
        // deposits
        (targets[i], data[i]) = (DEPOSIT_ADAPTER,            _upgradeTo(PRE_DEPOSIT_ADAPTER));               i++;
        (targets[i], data[i]) = (LIQUIFIER,                  _upgradeTo(PRE_LIQUIFIER));                     i++;
        // governance — RoleRegistry is reverted LAST (see end of batch); only the
        // rate limiter falls in the governance slot here.
        (targets[i], data[i]) = (ETHERFI_RATE_LIMITER,       _upgradeTo(PRE_ETHERFI_RATE_LIMITER));          i++;
        // membership
        (targets[i], data[i]) = (MEMBERSHIP_MANAGER,         _upgradeTo(PRE_MEMBERSHIP_MANAGER));            i++;
        (targets[i], data[i]) = (MEMBERSHIP_NFT,             _upgradeTo(PRE_MEMBERSHIP_NFT));                i++;
        // oracle
        (targets[i], data[i]) = (ETHERFI_ADMIN,              _upgradeTo(PRE_ETHERFI_ADMIN));                 i++;
        (targets[i], data[i]) = (ETHERFI_ORACLE,             _upgradeTo(PRE_ETHERFI_ORACLE));                i++;
        // restaking
        (targets[i], data[i]) = (ETHERFI_RESTAKER,           _upgradeTo(PRE_ETHERFI_RESTAKER));              i++;
        (targets[i], data[i]) = (RESTAKING_REWARDS_ROUTER,   _upgradeTo(PRE_RESTAKING_REWARDS_ROUTER));      i++;
        // rewards
        (targets[i], data[i]) = (CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR, _upgradeTo(PRE_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR)); i++;
        (targets[i], data[i]) = (ETHERFI_REWARDS_ROUTER,     _upgradeTo(PRE_ETHERFI_REWARDS_ROUTER));        i++;
        // staking
        (targets[i], data[i]) = (AUCTION_MANAGER,            _upgradeTo(PRE_AUCTION_MANAGER));               i++;

        // EtherFiNode is a beacon proxy, not UUPS. Revert it via the beacon owner
        // (the StakingManager) using upgradeEtherFiNode, gated by the same
        // UPGRADE_TIMELOCK authority executing this batch. Done BEFORE the StakingManager
        // proxy revert so it runs against the current (new) impl's upgrade gate, mirroring
        // the forward upgrade ordering. RoleRegistry is still on the new impl here, so its
        // onlyUpgradeTimelock gate authorizes the call.
        (targets[i], data[i]) = (STAKING_MANAGER,
            abi.encodeWithSelector(StakingManager.upgradeEtherFiNode.selector, PRE_ETHERFI_NODE_IMPL));     i++;

        (targets[i], data[i]) = (ETHERFI_NODES_MANAGER,      _upgradeTo(PRE_ETHERFI_NODES_MANAGER));         i++;
        (targets[i], data[i]) = (NODE_OPERATOR_MANAGER,      _upgradeTo(PRE_NODE_OPERATOR_MANAGER));         i++;
        (targets[i], data[i]) = (STAKING_MANAGER,            _upgradeTo(PRE_STAKING_MANAGER));               i++;
        // withdrawals
        (targets[i], data[i]) = (ETHERFI_REDEMPTION_MANAGER, _upgradeTo(PRE_ETHERFI_REDEMPTION_MANAGER));    i++;
        (targets[i], data[i]) = (PRIORITY_WITHDRAWAL_QUEUE,  _upgradeTo(PRE_PRIORITY_WITHDRAWAL_QUEUE));     i++;
        (targets[i], data[i]) = (WEETH_WITHDRAW_ADAPTER,     _upgradeTo(PRE_WEETH_WITHDRAW_ADAPTER));        i++;
        (targets[i], data[i]) = (WITHDRAW_REQUEST_NFT,       _upgradeTo(PRE_WITHDRAW_REQUEST_NFT));          i++;
        // RoleRegistry reverts LAST: while it is still on the new impl it provides the
        // onlyUpgradeTimelock gate authorizing the reverts above (including the beacon
        // revert). Reverting it first would strip that gate and the remaining reverts
        // would lose their authorizer.
        (targets[i], data[i]) = (ROLE_REGISTRY,              _upgradeTo(PRE_ROLE_REGISTRY));                 i++;

        bytes32 salt = keccak256(abi.encode("batch-revert", commitHashSalt));

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
        // core
        _assertImpl(EETH,                                PRE_EETH,                                "EETH");
        _assertImpl(LIQUIDITY_POOL,                      PRE_LIQUIDITY_POOL,                      "LiquidityPool");
        _assertImpl(WEETH,                               PRE_WEETH,                               "WeETH");
        // deposits
        _assertImpl(DEPOSIT_ADAPTER,                     PRE_DEPOSIT_ADAPTER,                     "DepositAdapter");
        _assertImpl(LIQUIFIER,                           PRE_LIQUIFIER,                           "Liquifier");
        // governance
        _assertImpl(ROLE_REGISTRY,                       PRE_ROLE_REGISTRY,                       "RoleRegistry");
        _assertImpl(ETHERFI_RATE_LIMITER,                PRE_ETHERFI_RATE_LIMITER,                "EtherFiRateLimiter");
        // membership
        _assertImpl(MEMBERSHIP_MANAGER,                  PRE_MEMBERSHIP_MANAGER,                  "MembershipManager");
        _assertImpl(MEMBERSHIP_NFT,                      PRE_MEMBERSHIP_NFT,                      "MembershipNFT");
        // oracle
        _assertImpl(ETHERFI_ADMIN,                       PRE_ETHERFI_ADMIN,                       "EtherFiAdmin");
        _assertImpl(ETHERFI_ORACLE,                      PRE_ETHERFI_ORACLE,                      "EtherFiOracle");
        // restaking
        _assertImpl(ETHERFI_RESTAKER,                    PRE_ETHERFI_RESTAKER,                    "EtherFiRestaker");
        _assertImpl(RESTAKING_REWARDS_ROUTER,            PRE_RESTAKING_REWARDS_ROUTER,            "RestakingRewardsRouter");
        // rewards
        _assertImpl(CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR, PRE_CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR, "CumulativeMerkleRewardsDistributor");
        _assertImpl(ETHERFI_REWARDS_ROUTER,              PRE_ETHERFI_REWARDS_ROUTER,              "EtherFiRewardsRouter");
        // staking
        _assertImpl(AUCTION_MANAGER,                     PRE_AUCTION_MANAGER,                     "AuctionManager");
        // EtherFiNode beacon: implementation lives on the beacon, read via StakingManager.
        address revertedNodeImpl = StakingManager(STAKING_MANAGER).implementation();
        require(revertedNodeImpl == PRE_ETHERFI_NODE_IMPL, "EtherFiNode beacon: revert failed (impl mismatch)");
        console2.log("[REVERTED] EtherFiNode beacon", revertedNodeImpl);
        _assertImpl(ETHERFI_NODES_MANAGER,               PRE_ETHERFI_NODES_MANAGER,               "EtherFiNodesManager");
        _assertImpl(NODE_OPERATOR_MANAGER,               PRE_NODE_OPERATOR_MANAGER,               "NodeOperatorManager");
        _assertImpl(STAKING_MANAGER,                     PRE_STAKING_MANAGER,                     "StakingManager");
        // withdrawals
        _assertImpl(ETHERFI_REDEMPTION_MANAGER,          PRE_ETHERFI_REDEMPTION_MANAGER,          "EtherFiRedemptionManager");
        _assertImpl(PRIORITY_WITHDRAWAL_QUEUE,           PRE_PRIORITY_WITHDRAWAL_QUEUE,           "PriorityWithdrawalQueue");
        _assertImpl(WEETH_WITHDRAW_ADAPTER,              PRE_WEETH_WITHDRAW_ADAPTER,              "WeETHWithdrawAdapter");
        _assertImpl(WITHDRAW_REQUEST_NFT,                PRE_WITHDRAW_REQUEST_NFT,                "WithdrawRequestNFT");
        console2.log("");
    }

    function _assertImpl(address proxy, address expected, string memory name) internal view {
        address actual = getImplementation(proxy);
        require(actual == expected, string.concat(name, ": revert failed (impl slot mismatch)"));
        console2.log(string.concat("[REVERTED] ", name), actual);
    }

    function verifyAccessControlPreservation() public view {
        console2.log("=== Step 4: Verifying owner + paused across revert ===");
        address[23] memory p = _proxies();
        for (uint256 i = 0; i < p.length; i++) {
            Snap memory pre = preRevertSnap[p[i]];
            if (_ownerDeprecated(p[i])) {
                // These 16 contracts migrated OFF OZ Ownable in the upgrade (DeprecatedOZOwnable
                // shim, no owner() getter), so the pre-revert snapshot captured owner()==address(0).
                // The revert restores the OLD impl, which HAS owner() again — so post-revert owner()
                // must be RESTORED to a non-zero value (the original pre-upgrade owner). Asserting
                // == pre.owner (address(0)) would be wrong; assert the getter is live again instead.
                require(_getOwner(p[i]) != address(0), string.concat("owner not restored by revert: ", vm.toString(p[i])));
            } else {
                // MembershipManager/MembershipNFT keep OZ Ownable; RateLimiter/RestakingRewardsRouter/
                // EtherFiRedemptionManager/PriorityWithdrawalQueue never exposed owner(). owner() is
                // identical on the new and old impls, so it must be unchanged across the revert.
                require(_getOwner(p[i]) == pre.owner, string.concat("owner changed across revert: ", vm.toString(p[i])));
            }
            require(_getPaused(p[i]) == pre.paused, string.concat("paused changed across revert: ", vm.toString(p[i])));
        }
        console2.log("[OK] owner restored/unchanged + paused unchanged on all 23 proxies");
        console2.log("");
    }

    /// @dev The 16 proxies whose upgrade impl inherits DeprecatedOZOwnable (owner() removed).
    ///      Mirrors the same helper in transactions.s.sol. On a revert these get owner()
    ///      restored (old impl has the getter); the other 7 entries in _proxies() keep their
    ///      owner() identical (Membership* keep OZ Ownable; the rest never had owner()).
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

    function _proxies() internal pure returns (address[23] memory list) {
        // core
        list[0]  = EETH;
        list[1]  = LIQUIDITY_POOL;
        list[2]  = WEETH;
        // deposits
        list[3]  = DEPOSIT_ADAPTER;
        list[4]  = LIQUIFIER;
        // governance
        list[5]  = ROLE_REGISTRY;
        list[6]  = ETHERFI_RATE_LIMITER;
        // membership
        list[7]  = MEMBERSHIP_MANAGER;
        list[8]  = MEMBERSHIP_NFT;
        // oracle
        list[9]  = ETHERFI_ADMIN;
        list[10] = ETHERFI_ORACLE;
        // restaking
        list[11] = ETHERFI_RESTAKER;
        list[12] = RESTAKING_REWARDS_ROUTER;
        // rewards
        list[13] = CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR;
        list[14] = ETHERFI_REWARDS_ROUTER;
        // staking
        list[15] = AUCTION_MANAGER;
        list[16] = ETHERFI_NODES_MANAGER;
        list[17] = NODE_OPERATOR_MANAGER;
        list[18] = STAKING_MANAGER;
        // withdrawals
        list[19] = ETHERFI_REDEMPTION_MANAGER;
        list[20] = PRIORITY_WITHDRAWAL_QUEUE;
        list[21] = WEETH_WITHDRAW_ADAPTER;
        list[22] = WITHDRAW_REQUEST_NFT;
    }

    function _upgradeTo(address impl) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, impl);
    }
}
