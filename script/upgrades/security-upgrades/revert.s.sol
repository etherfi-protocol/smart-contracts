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
 *     - The ERC1967 implementation slot on each of the 16 proxies. After
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
 *
 * If you need any of the above undone, write a separate operation. This
 * script intentionally has the smallest possible blast radius: 16
 * `upgradeTo(oldImpl)` calls.
 *
 * Snapshot taken at mainnet block 25_146_941 (Alchemy) - all current impls
 * are baked in as constants below. Re-run the revert-prep query if mainnet
 * has been upgraded since then.
 *
 * Run:
 *   forge script script/upgrades/security-upgrades/revert.s.sol:SecurityUpgradesRevertScript \
 *       --fork-url $MAINNET_RPC_URL -vvvv
 */
contract SecurityUpgradesRevertScript is Script, Deployed, Utils {
    // ─────────────────────────────────────────────────────────────────────
    // PRE-UPGRADE IMPLEMENTATIONS (snapshot @ block 25_146_941, mainnet)
    // Source: ERC1967 impl slot read via UUPSProxy's custom slot:
    //         0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
    // ─────────────────────────────────────────────────────────────────────
    address constant PRE_EETH                       = 0xCB3D917A965A70214f430a135154Cd5ADdA2ad84;
    address constant PRE_WEETH                      = 0x2d10683E941275D502173053927AD6066e6aFd6B;
    address constant PRE_LIQUIDITY_POOL             = 0x83bc649fCdb2c8DA146b2154a559ddEDf937eF12;
    address constant PRE_WITHDRAW_REQUEST_NFT       = 0x2f4A5921FcAB46F1F3154e8b42Fc189e08fae3Ed;
    address constant PRE_LIQUIFIER                  = 0x0E7489D32D34CCdC12d7092067bf53Aa38bf2BF6;
    address constant PRE_ETHERFI_ADMIN              = 0xd50f28485A75A1FdE432BA7d012d0E2543D2f20d;
    address constant PRE_ETHERFI_ORACLE             = 0x5eefE6f65a280A6f1Eb1FdFf36Ab9e2af6f38462;
    address constant PRE_ETHERFI_REDEMPTION_MANAGER = 0x6BD191582F40012b2f2cdf66bD3D32bDe41191F7;
    address constant PRE_ETHERFI_RESTAKER           = 0x9D795b303B9dA3488FD3A4ca4702c872576BD0c6;
    address constant PRE_ETHERFI_NODES_MANAGER      = 0x789CbBe0739F1458905C9Ca6d6e74f7997622A9B;
    address constant PRE_STAKING_MANAGER            = 0xd3985048Bf1Cb613F5E199713a86B2aD3954F82A;
    address constant PRE_AUCTION_MANAGER            = 0x68FE80C6e97E0c8613e2FED344358c6635ba5366;
    address constant PRE_NODE_OPERATOR_MANAGER      = 0xfcC674Fc9A0602692D2a91905E7e978aE6EE2cAF;
    address constant PRE_MEMBERSHIP_MANAGER         = 0x047A7749AD683C2Fd8A27C7904Ca8dD128F15889;
    address constant PRE_MEMBERSHIP_NFT             = 0x290d981b41B713437265Cd7846806D7500307106;
    address constant PRE_ETHERFI_RATE_LIMITER       = 0x1dd43C32f03f8A74b8160926D559d34358880A89;

    EtherFiTimelock constant upgradeTimelock = EtherFiTimelock(payable(UPGRADE_TIMELOCK));
    uint256 constant UPGRADE_TIMELOCK_DELAY = 10 days;
    string constant OUT_DIR = "script/upgrades/security-upgrades";

    struct Snap { address owner; bool paused; }
    mapping(address => Snap) internal preRevertSnap;

    function run() public {
        string memory forkUrl = vm.envString("MAINNET_RPC_URL");
        vm.selectFork(vm.createFork(forkUrl));

        confirmCurrentlyOnNewImpl();
        takePreRevertSnapshots();
        executeRevert();
        verifyReverted();
        verifyAccessControlPreservation();
    }

    /// @notice Sanity check: every proxy is currently NOT on the pre-upgrade
    ///         impl. If they already are, the revert is a no-op and we abort
    ///         loudly to avoid scheduling a useless 10-day timelock.
    function confirmCurrentlyOnNewImpl() public view {
        console2.log("=== Step 0: Confirming proxies are on the new impl ===");
        _assertNotAlreadyOnPre(EETH,                       PRE_EETH,                       "EETH");
        _assertNotAlreadyOnPre(WEETH,                      PRE_WEETH,                      "WeETH");
        _assertNotAlreadyOnPre(LIQUIDITY_POOL,             PRE_LIQUIDITY_POOL,             "LiquidityPool");
        _assertNotAlreadyOnPre(WITHDRAW_REQUEST_NFT,       PRE_WITHDRAW_REQUEST_NFT,       "WithdrawRequestNFT");
        _assertNotAlreadyOnPre(LIQUIFIER,                  PRE_LIQUIFIER,                  "Liquifier");
        _assertNotAlreadyOnPre(ETHERFI_ADMIN,              PRE_ETHERFI_ADMIN,              "EtherFiAdmin");
        _assertNotAlreadyOnPre(ETHERFI_ORACLE,             PRE_ETHERFI_ORACLE,             "EtherFiOracle");
        _assertNotAlreadyOnPre(ETHERFI_REDEMPTION_MANAGER, PRE_ETHERFI_REDEMPTION_MANAGER, "EtherFiRedemptionManager");
        _assertNotAlreadyOnPre(ETHERFI_RESTAKER,           PRE_ETHERFI_RESTAKER,           "EtherFiRestaker");
        _assertNotAlreadyOnPre(ETHERFI_NODES_MANAGER,      PRE_ETHERFI_NODES_MANAGER,      "EtherFiNodesManager");
        _assertNotAlreadyOnPre(STAKING_MANAGER,            PRE_STAKING_MANAGER,            "StakingManager");
        _assertNotAlreadyOnPre(AUCTION_MANAGER,            PRE_AUCTION_MANAGER,            "AuctionManager");
        _assertNotAlreadyOnPre(NODE_OPERATOR_MANAGER,      PRE_NODE_OPERATOR_MANAGER,      "NodeOperatorManager");
        _assertNotAlreadyOnPre(MEMBERSHIP_MANAGER,         PRE_MEMBERSHIP_MANAGER,         "MembershipManager");
        _assertNotAlreadyOnPre(MEMBERSHIP_NFT,             PRE_MEMBERSHIP_NFT,             "MembershipNFT");
        _assertNotAlreadyOnPre(ETHERFI_RATE_LIMITER,       PRE_ETHERFI_RATE_LIMITER,       "EtherFiRateLimiter");
        console2.log("[OK] all 16 proxies are on post-upgrade impls; revert is meaningful");
        console2.log("");
    }

    function _assertNotAlreadyOnPre(address proxy, address pre, string memory name) internal view {
        address current = getImplementation(proxy);
        require(current != pre, string.concat(name, ": already on pre-upgrade impl - nothing to revert"));
        console2.log(string.concat("[CURRENT] ", name), current);
    }

    function takePreRevertSnapshots() public {
        console2.log("=== Step 1: Snapshotting owner+paused before revert ===");
        address[16] memory p = _proxies();
        for (uint256 i = 0; i < p.length; i++) {
            preRevertSnap[p[i]] = Snap({ owner: _getOwner(p[i]), paused: _getPaused(p[i]) });
        }
        console2.log("[OK] snapshot taken for 16 proxies");
        console2.log("");
    }

    function executeRevert() public {
        console2.log("=== Step 2: Executing revert (UPGRADE_TIMELOCK, 10d) ===");

        address[] memory targets = new address[](16);
        bytes[]   memory data    = new bytes[](16);
        uint256[] memory values  = new uint256[](16);

        targets[0]  = EETH;                       data[0]  = _upgradeTo(PRE_EETH);
        targets[1]  = WEETH;                      data[1]  = _upgradeTo(PRE_WEETH);
        targets[2]  = LIQUIDITY_POOL;             data[2]  = _upgradeTo(PRE_LIQUIDITY_POOL);
        targets[3]  = WITHDRAW_REQUEST_NFT;       data[3]  = _upgradeTo(PRE_WITHDRAW_REQUEST_NFT);
        targets[4]  = LIQUIFIER;                  data[4]  = _upgradeTo(PRE_LIQUIFIER);
        targets[5]  = ETHERFI_ADMIN;              data[5]  = _upgradeTo(PRE_ETHERFI_ADMIN);
        targets[6]  = ETHERFI_ORACLE;             data[6]  = _upgradeTo(PRE_ETHERFI_ORACLE);
        targets[7]  = ETHERFI_REDEMPTION_MANAGER; data[7]  = _upgradeTo(PRE_ETHERFI_REDEMPTION_MANAGER);
        targets[8]  = ETHERFI_RESTAKER;           data[8]  = _upgradeTo(PRE_ETHERFI_RESTAKER);
        targets[9]  = ETHERFI_NODES_MANAGER;      data[9]  = _upgradeTo(PRE_ETHERFI_NODES_MANAGER);
        targets[10] = STAKING_MANAGER;            data[10] = _upgradeTo(PRE_STAKING_MANAGER);
        targets[11] = AUCTION_MANAGER;            data[11] = _upgradeTo(PRE_AUCTION_MANAGER);
        targets[12] = NODE_OPERATOR_MANAGER;      data[12] = _upgradeTo(PRE_NODE_OPERATOR_MANAGER);
        targets[13] = MEMBERSHIP_MANAGER;         data[13] = _upgradeTo(PRE_MEMBERSHIP_MANAGER);
        targets[14] = MEMBERSHIP_NFT;             data[14] = _upgradeTo(PRE_MEMBERSHIP_NFT);
        targets[15] = ETHERFI_RATE_LIMITER;       data[15] = _upgradeTo(PRE_ETHERFI_RATE_LIMITER);

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
        _assertImpl(EETH,                       PRE_EETH,                       "EETH");
        _assertImpl(WEETH,                      PRE_WEETH,                      "WeETH");
        _assertImpl(LIQUIDITY_POOL,             PRE_LIQUIDITY_POOL,             "LiquidityPool");
        _assertImpl(WITHDRAW_REQUEST_NFT,       PRE_WITHDRAW_REQUEST_NFT,       "WithdrawRequestNFT");
        _assertImpl(LIQUIFIER,                  PRE_LIQUIFIER,                  "Liquifier");
        _assertImpl(ETHERFI_ADMIN,              PRE_ETHERFI_ADMIN,              "EtherFiAdmin");
        _assertImpl(ETHERFI_ORACLE,             PRE_ETHERFI_ORACLE,             "EtherFiOracle");
        _assertImpl(ETHERFI_REDEMPTION_MANAGER, PRE_ETHERFI_REDEMPTION_MANAGER, "EtherFiRedemptionManager");
        _assertImpl(ETHERFI_RESTAKER,           PRE_ETHERFI_RESTAKER,           "EtherFiRestaker");
        _assertImpl(ETHERFI_NODES_MANAGER,      PRE_ETHERFI_NODES_MANAGER,      "EtherFiNodesManager");
        _assertImpl(STAKING_MANAGER,            PRE_STAKING_MANAGER,            "StakingManager");
        _assertImpl(AUCTION_MANAGER,            PRE_AUCTION_MANAGER,            "AuctionManager");
        _assertImpl(NODE_OPERATOR_MANAGER,      PRE_NODE_OPERATOR_MANAGER,      "NodeOperatorManager");
        _assertImpl(MEMBERSHIP_MANAGER,         PRE_MEMBERSHIP_MANAGER,         "MembershipManager");
        _assertImpl(MEMBERSHIP_NFT,             PRE_MEMBERSHIP_NFT,             "MembershipNFT");
        _assertImpl(ETHERFI_RATE_LIMITER,       PRE_ETHERFI_RATE_LIMITER,       "EtherFiRateLimiter");
        console2.log("");
    }

    function _assertImpl(address proxy, address expected, string memory name) internal view {
        address actual = getImplementation(proxy);
        require(actual == expected, string.concat(name, ": revert failed (impl slot mismatch)"));
        console2.log(string.concat("[REVERTED] ", name), actual);
    }

    function verifyAccessControlPreservation() public view {
        console2.log("=== Step 4: Verifying owner + paused unchanged ===");
        address[16] memory p = _proxies();
        for (uint256 i = 0; i < p.length; i++) {
            Snap memory pre = preRevertSnap[p[i]];
            require(_getOwner(p[i])  == pre.owner,  string.concat("owner changed across revert: ", vm.toString(p[i])));
            require(_getPaused(p[i]) == pre.paused, string.concat("paused changed across revert: ", vm.toString(p[i])));
        }
        console2.log("[OK] owner + paused unchanged on all 16 proxies");
        console2.log("");
    }

    function _proxies() internal pure returns (address[16] memory list) {
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
    }

    function _upgradeTo(address impl) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, impl);
    }
}
