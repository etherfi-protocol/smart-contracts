// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "forge-std/StdJson.sol";

import {EtherFiTimelock} from "../../../src/EtherFiTimelock.sol";
import {IEtherFiNodesManager} from "../../../src/interfaces/IEtherFiNodesManager.sol";
import {LiquidityPool} from "../../../src/LiquidityPool.sol";
import {Utils} from "../../utils/utils.sol";

/// @title SweepFunds
/// @notice Schedules + emits a single Safe-Tx-Builder pair to sweep ETH from a set of
///         EtherFiNodes to the LiquidityPool via the OPERATING_TIMELOCK.
///
///         Input :  node-ids.json (produced by query_node_ids.py) — every entry is included.
///                  sweepFunds(id) is a safe no-op on a node with 0 balance, so over-including
///                  is fine; the timelock's 2-day window also gives time for ETH from
///                  in-flight EigenLayer withdrawals to land on the nodes before execute.
///
///         Output:  $OUTPUT_DIR/schedule.json  (one scheduleBatch on the timelock)
///                  $OUTPUT_DIR/execute.json   (one matching executeBatch)
///                  Default $OUTPUT_DIR = operations/sweep-<unix-timestamp>
///                  Override with env var OUTPUT_DIR (relative to repo root, must be a path
///                  whitelisted by foundry.toml fs_permissions; "./operations" already is).
///
///         Salt  :  derived from chosen ids so the operation hash is deterministic per ids set;
///                  override with env var SALT (any string).
///
/// Usage:
///   forge script script/operations/withdraw-and-sweep/SweepFunds.s.sol:SweepFunds \
///     --fork-url $MAINNET_RPC_URL -vv
contract SweepFunds is Script, Utils {
    using stdJson for string;

    IEtherFiNodesManager constant nodesManager = IEtherFiNodesManager(ETHERFI_NODES_MANAGER);
    LiquidityPool constant liquidityPool = LiquidityPool(payable(LIQUIDITY_POOL));
    EtherFiTimelock constant operatingTimelock = EtherFiTimelock(payable(OPERATING_TIMELOCK));

    uint256 constant CHAIN_ID = 1;

    struct Entry {
        uint256 etherfi_id;
        string id;
        string kind;
        address node;
        string pubkey;
    }

    function run() external {
        (address[] memory nodes, uint256[] memory ids) = _loadNodeIds();
        require(nodes.length > 0, "node-ids.json is empty");

        for (uint256 i = 0; i < nodes.length; i++) {
            require(nodesManager.etherfiNodeAddress(ids[i]) == nodes[i], "id->node mismatch");
        }

        (address[] memory targets, uint256[] memory values, bytes[] memory calls) =
            _buildSweepCalls(ids);

        uint256 delay = operatingTimelock.getMinDelay();
        bytes32 salt = _computeSalt(ids);

        bytes memory scheduleCalldata = abi.encodeWithSelector(
            operatingTimelock.scheduleBatch.selector,
            targets, values, calls, bytes32(0), salt, delay
        );
        bytes memory executeCalldata = abi.encodeWithSelector(
            operatingTimelock.executeBatch.selector,
            targets, values, calls, bytes32(0), salt
        );

        string memory outDir = _resolveOutputDir();
        vm.createDir(string.concat(vm.projectRoot(), "/", outDir), true);
        writeSafeJson(outDir, "schedule.json", ETHERFI_OPERATING_ADMIN,
            OPERATING_TIMELOCK, 0, scheduleCalldata, CHAIN_ID);
        writeSafeJson(outDir, "execute.json", ETHERFI_OPERATING_ADMIN,
            OPERATING_TIMELOCK, 0, executeCalldata, CHAIN_ID);

        _logSummary(nodes, ids, delay, salt, outDir);

        if (vm.envOr("SIMULATE", true)) {
            _simulate(nodes, targets, values, calls, salt, delay);
        } else {
            console2.log("SIMULATE=false -> skipping fork simulation");
        }
    }

    function _loadNodeIds() internal view returns (address[] memory nodes, uint256[] memory ids) {
        string memory path = string.concat(
            vm.projectRoot(),
            "/script/operations/withdraw-and-sweep/node-ids.json"
        );
        Entry[] memory entries = abi.decode(vm.readFile(path).parseRaw(".nodes"), (Entry[]));
        nodes = new address[](entries.length);
        ids = new uint256[](entries.length);
        for (uint256 i = 0; i < entries.length; i++) {
            nodes[i] = entries[i].node;
            ids[i] = vm.parseUint(entries[i].id);
        }
    }

    function _buildSweepCalls(uint256[] memory ids)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calls)
    {
        targets = new address[](ids.length);
        values = new uint256[](ids.length);
        calls = new bytes[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            targets[i] = ETHERFI_NODES_MANAGER;
            calls[i] = abi.encodeWithSelector(IEtherFiNodesManager.sweepFunds.selector, ids[i]);
        }
    }

    function _computeSalt(uint256[] memory ids) internal view returns (bytes32) {
        string memory override_ = vm.envOr("SALT", string(""));
        if (bytes(override_).length > 0) return keccak256(bytes(override_));
        return keccak256(abi.encode("etherfi.sweepFunds", ids));
    }

    function _resolveOutputDir() internal view returns (string memory) {
        string memory override_ = vm.envOr("OUTPUT_DIR", string(""));
        if (bytes(override_).length > 0) return override_;
        return string.concat("operations/sweep-", vm.toString(block.timestamp));
    }

    function _logSummary(
        address[] memory nodes,
        uint256[] memory ids,
        uint256 delay,
        bytes32 salt,
        string memory outDir
    ) internal view {
        console2.log("=== SWEEP FUNDS - SAFE JSON GENERATION ===");
        console2.log("Output dir:", outDir);
        console2.log("Operating Timelock:", OPERATING_TIMELOCK);
        console2.log("Safe (admin):", ETHERFI_OPERATING_ADMIN);
        console2.log("Manager:", ETHERFI_NODES_MANAGER);
        console2.log("Min delay (s):", delay);
        console2.log("Nodes included:", nodes.length);
        for (uint256 i = 0; i < nodes.length; i++) {
            console2.log(nodes[i], ids[i], nodes[i].balance);
        }
        console2.log("Salt:");
        console2.logBytes32(salt);
    }

    function _simulate(
        address[] memory nodes,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calls,
        bytes32 salt,
        uint256 delay
    ) internal {
        console2.log("\n=== FORK SIMULATION (sweep-only; assumes ETH already on nodes) ===");
        uint256[] memory before = new uint256[](nodes.length);
        for (uint256 i = 0; i < nodes.length; i++) before[i] = nodes[i].balance;
        uint256 lpBefore = address(liquidityPool).balance;

        vm.startPrank(ETHERFI_OPERATING_ADMIN);
        operatingTimelock.scheduleBatch(targets, values, calls, bytes32(0), salt, delay);
        console2.log("Scheduled at block:", block.number, "timestamp:", block.timestamp);

        vm.warp(block.timestamp + delay + 1);
        console2.log("Warped past delay; timestamp:", block.timestamp);

        uint256 gasBefore = gasleft();
        operatingTimelock.executeBatch(targets, values, calls, bytes32(0), salt);
        console2.log("Execute gas:", gasBefore - gasleft());
        vm.stopPrank();

        uint256 totalSwept;
        for (uint256 i = 0; i < nodes.length; i++) {
            uint256 delta = before[i] - nodes[i].balance;
            totalSwept += delta;
            console2.log(nodes[i], delta);
        }
        console2.log("LP delta:", address(liquidityPool).balance - lpBefore);
        console2.log("Total swept:", totalSwept);
        require(address(liquidityPool).balance - lpBefore == totalSwept, "swept != LP credit");
    }
}
