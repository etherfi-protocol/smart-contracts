// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "forge-std/StdJson.sol";

import {EtherFiTimelock} from "../../../src/EtherFiTimelock.sol";
import {IEtherFiNodesManager} from "../../../src/interfaces/IEtherFiNodesManager.sol";
import {LiquidityPool} from "../../../src/LiquidityPool.sol";
import {IDelegationManager} from "../../../src/eigenlayer-interfaces/IDelegationManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Utils} from "../../utils/utils.sol";

/// @title SimulateFullFlow
/// @notice End-to-end fork simulation:
///         1. Reads queued withdrawals from EigenLayer DelegationManager for each node.
///         2. Rolls block.number past EIGENLAYER_WITHDRAWAL_DELAY_BLOCKS (~14 days).
///         3. Pranks the EIGENLAYER_ADMIN EOA and calls
///            EtherFiNodesManager.completeQueuedWithdrawals(node, withdrawals, tokens, receiveAsTokens=true).
///            ETH lands on each node.
///         4. Schedules two sweep batches through OPERATING_TIMELOCK, warps 2 days, executes both.
///         5. Reports LP delta, per-node delta, and per-batch gas usage.
///
/// Usage:
///   forge script script/operations/withdraw-and-sweep/SimulateFullFlow.s.sol:SimulateFullFlow \
///     --fork-url $MAINNET_RPC_URL -vvvv
contract SimulateFullFlow is Script, Utils {
    using stdJson for string;

    IEtherFiNodesManager constant nodesManager = IEtherFiNodesManager(ETHERFI_NODES_MANAGER);
    LiquidityPool constant liquidityPool = LiquidityPool(payable(LIQUIDITY_POOL));
    EtherFiTimelock constant operatingTimelock = EtherFiTimelock(payable(OPERATING_TIMELOCK));
    IDelegationManager constant delegationManager = IDelegationManager(EIGENLAYER_DELEGATION_MANAGER);

    address constant EIGENLAYER_ADMIN_EOA = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;
    address constant BEACON_ETH_STRATEGY = 0xbeaC0eeEeeeeEEeEeEEEEeeEEeEeeeEeeEEBEaC0;
    uint32 constant WITHDRAWAL_DELAY_BLOCKS = 100800;

    bytes32 constant SCHEDULE_SALT_A = keccak256("etherfi.sweepFunds.batch-A.2026-05-11");
    bytes32 constant SCHEDULE_SALT_B = keccak256("etherfi.sweepFunds.batch-B.2026-05-11");

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

        console2.log("=== STAGE 1: Inspect queued withdrawals ===");
        console2.log("Current block:", block.number);
        uint32 maxStartBlock = _inspectQueued(nodes);

        // Ensure all withdrawals are completable. Roll past max(startBlock) + delay + buffer.
        uint256 targetBlock = uint256(maxStartBlock) + WITHDRAWAL_DELAY_BLOCKS + 10;
        if (block.number < targetBlock) {
            uint256 deltaBlocks = targetBlock - block.number;
            vm.roll(targetBlock);
            vm.warp(block.timestamp + deltaBlocks * 12);
            console2.log("Rolled forward to block:", block.number);
        }


        console2.log("\n=== STAGE 2: completeQueuedWithdrawals ===");
        uint256 lpBeforeComplete = address(liquidityPool).balance;
        uint256[] memory nodeBalBeforeComplete = _snapshot(nodes);
        _completeAll(nodes);

        console2.log("\n--- Post-complete deltas ---");
        uint256 totalCompletedETH;
        for (uint256 i = 0; i < nodes.length; i++) {
            uint256 delta = nodes[i].balance - nodeBalBeforeComplete[i];
            totalCompletedETH += delta;
            console2.log(nodes[i], delta);
        }
        console2.log("Sum of node ETH credited:", totalCompletedETH);
        console2.log("LP balance delta during complete (should be 0):", address(liquidityPool).balance - lpBeforeComplete);

        uint256 mismatchCount;
        for (uint256 i = 0; i < nodes.length; i++) {
            address resolved = nodesManager.etherfiNodeAddress(ids[i]);
            if (resolved != nodes[i]) {
                mismatchCount++;
                console2.log("MISMATCH idx", i);
                console2.log("  expected node:", nodes[i]);
                console2.log("  resolved     :", resolved);
            }
        }
        console2.log("Total mismatches:", mismatchCount);
        require(mismatchCount == 0, "id->node mismatches detected");

        console2.log("\n=== STAGE 3: schedule sweep via OPERATING_TIMELOCK ===");
        uint256 lpBeforeSweep = address(liquidityPool).balance;
        uint256[] memory nodeBalBeforeSweep = _snapshot(nodes);
        _scheduleAndExecuteSweep(ids);

        console2.log("\n--- Post-sweep deltas ---");
        uint256 totalSwept;
        for (uint256 i = 0; i < nodes.length; i++) {
            uint256 delta = nodeBalBeforeSweep[i] - nodes[i].balance;
            totalSwept += delta;
            console2.log(nodes[i], delta);
        }
        console2.log("Total swept to LP:", totalSwept);
        console2.log("LP balance delta:", address(liquidityPool).balance - lpBeforeSweep);

        console2.log("\n=== FINAL ===");
        console2.log("Net LP gain (complete + sweep):", address(liquidityPool).balance - lpBeforeComplete);
        console2.log("Sum of node residual ETH:", _sumBalances(nodes));
    }

    function _loadNodeIds() internal view returns (address[] memory nodes, uint256[] memory ids) {
        string memory path = string.concat(
            vm.projectRoot(),
            "/script/operations/withdraw-and-sweep/node-ids.json"
        );
        string memory json = vm.readFile(path);
        Entry[] memory entries = abi.decode(json.parseRaw(".nodes"), (Entry[]));
        nodes = new address[](entries.length);
        ids = new uint256[](entries.length);
        for (uint256 i = 0; i < entries.length; i++) {
            nodes[i] = entries[i].node;
            ids[i] = vm.parseUint(entries[i].id);
        }
    }

    function _inspectQueued(address[] memory nodes) internal view returns (uint32 maxStartBlock) {
        for (uint256 i = 0; i < nodes.length; i++) {
            (IDelegationManager.Withdrawal[] memory ws, ) = delegationManager.getQueuedWithdrawals(nodes[i]);
            console2.log(nodes[i], "queued:", ws.length);
            for (uint256 j = 0; j < ws.length; j++) {
                if (ws[j].startBlock > maxStartBlock) maxStartBlock = ws[j].startBlock;
                uint256 totalShares;
                for (uint256 k = 0; k < ws[j].scaledShares.length; k++) totalShares += ws[j].scaledShares[k];
                bool isBeacon = ws[j].strategies.length == 1
                    && address(ws[j].strategies[0]) == BEACON_ETH_STRATEGY;
                console2.log("  startBlock:", ws[j].startBlock, "shares:", totalShares);
                console2.log("  isBeaconETH:", isBeacon);
            }
        }
    }

    function _completeAll(address[] memory nodes) internal {
        vm.startPrank(EIGENLAYER_ADMIN_EOA);
        for (uint256 i = 0; i < nodes.length; i++) {
            _completeOne(nodes[i]);
        }
        vm.stopPrank();
    }

    function _completeOne(address node) internal {
        address pod = nodesManager.getEigenPod(node);
        uint256 budgetWei = uint256(_readWithdrawableGwei(pod)) * 1 gwei;

        (IDelegationManager.Withdrawal[] memory ws, ) = delegationManager.getQueuedWithdrawals(node);
        console2.log(node);
        console2.log("  pod ETH:", pod.balance, "withdrawable wei:", budgetWei);
        console2.log("  total queued:", ws.length);

        if (ws.length == 0) {
            console2.log("  no queued withdrawals - skipping");
            return;
        }

        // Greedy fit: walk queued withdrawals in order; include any whose beaconETH shares
        // fit within the remaining budget. Skip non-beaconETH roots (unlikely here).
        IDelegationManager.Withdrawal[] memory pick = new IDelegationManager.Withdrawal[](ws.length);
        uint256 picked;
        uint256 remaining = budgetWei;
        for (uint256 j = 0; j < ws.length; j++) {
            if (ws[j].strategies.length != 1) continue;
            if (address(ws[j].strategies[0]) != BEACON_ETH_STRATEGY) continue;
            uint256 amt = ws[j].scaledShares[0];
            if (amt <= remaining) {
                pick[picked++] = ws[j];
                remaining -= amt;
            }
        }

        if (picked == 0) {
            console2.log("  no root fits within current withdrawableGwei");
            return;
        }

        IDelegationManager.Withdrawal[] memory selected = new IDelegationManager.Withdrawal[](picked);
        IERC20[][] memory tokens = new IERC20[][](picked);
        bool[] memory receiveAsTokens = new bool[](picked);
        for (uint256 j = 0; j < picked; j++) {
            selected[j] = pick[j];
            tokens[j] = new IERC20[](1);
            receiveAsTokens[j] = true;
        }

        uint256 nodeBefore = node.balance;
        uint256 gasBefore = gasleft();
        try nodesManager.completeQueuedWithdrawals(node, selected, tokens, receiveAsTokens) {
            console2.log("  picked:", picked, "of", ws.length);
            console2.log("  claimed wei:", node.balance - nodeBefore);
            console2.log("  gas used:", gasBefore - gasleft());
        } catch (bytes memory raw) {
            bytes4 sel;
            assembly { sel := mload(add(raw, 0x20)) }
            console2.log("  unexpected revert sel:");
            console2.logBytes4(sel);
        }
    }

    function _readWithdrawableGwei(address pod) internal view returns (uint64) {
        bytes32 slot = vm.load(pod, bytes32(uint256(52)));
        return uint64(uint256(slot));
    }

    function _scheduleAndExecuteSweep(uint256[] memory ids) internal {
        (address[] memory t, uint256[] memory v, bytes[] memory d) = _buildSweepCalls(ids, 0, ids.length);

        vm.startPrank(ETHERFI_OPERATING_ADMIN);
        operatingTimelock.scheduleBatch(t, v, d, bytes32(0), SCHEDULE_SALT_A, operatingTimelock.getMinDelay());
        console2.log("Scheduled single batch at block:", block.number);

        vm.warp(block.timestamp + operatingTimelock.getMinDelay() + 1);
        console2.log("Warped 2 days; now timestamp:", block.timestamp);

        uint256 g = gasleft();
        operatingTimelock.executeBatch(t, v, d, bytes32(0), SCHEDULE_SALT_A);
        console2.log("Batch executed. Gas used:", g - gasleft());
        vm.stopPrank();
    }

    function _buildSweepCalls(uint256[] memory ids, uint256 start, uint256 end)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calls)
    {
        uint256 n = end - start;
        targets = new address[](n);
        values = new uint256[](n);
        calls = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            targets[i] = ETHERFI_NODES_MANAGER;
            calls[i] = abi.encodeWithSelector(IEtherFiNodesManager.sweepFunds.selector, ids[start + i]);
        }
    }

    function _snapshot(address[] memory nodes) internal view returns (uint256[] memory snap) {
        snap = new uint256[](nodes.length);
        for (uint256 i = 0; i < nodes.length; i++) snap[i] = nodes[i].balance;
    }

    function _sumBalances(address[] memory nodes) internal view returns (uint256 s) {
        for (uint256 i = 0; i < nodes.length; i++) s += nodes[i].balance;
    }

    function _sumOf(uint256[] memory arr) internal pure returns (uint256 s) {
        for (uint256 i = 0; i < arr.length; i++) s += arr[i];
    }
}
