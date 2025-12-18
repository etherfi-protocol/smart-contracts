// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "forge-std/StdJson.sol";

import {IEtherFiNodesManager} from "../../src/interfaces/IEtherFiNodesManager.sol";
import {IDelegationManager} from "../../src/eigenlayer-interfaces/IDelegationManager.sol";

/**
 * @title UndelegateAllStakers
 * @notice Calls EigenLayer `DelegationManager.undelegate(staker)` for a list of EtherFi node "stakers".
 * @dev Uses `EtherFiNodesManager.forwardExternalCall()` so the EtherFiNode is the caller (i.e. the staker),
 *      avoiding per-staker private keys.
 *
 * Input JSON (set with env `INPUT_JSON`, default: `<repo>/script/operator-management/undelegate.json`)
 * - Either:
 *   { "validator_ids": [21397, 338, ...] }
 * - Or:
 *   { "nodes": ["0x...", "0x...", ...] }
 * - Or:
 *   [ { "node_address": "0x..." }, ... ]  (your `a41-node-address.json` format)
 *
 * Env:
 * - PRIVATE_KEY (required): broadcaster with CALL_FORWARDER_ROLE on EtherFiNodesManager.
 * - AUTO_WHITELIST (optional, default false): if true, attempts to call
 *   `updateAllowedForwardedExternalCalls(broadcaster, undelegateSelector, delegationManager, true)` first.
 * - NODES_MANAGER (optional): EtherFiNodesManager address (default mainnet).
 * - DELEGATION_MANAGER (optional): EigenLayer DelegationManager address (default mainnet).
 * - BATCH_SIZE (optional, default 20): number of nodes per `forwardExternalCall` tx.
 */
contract UndelegateAllStakers is Script {
    using stdJson for string;

    // Mainnet defaults
    address internal constant _MAINNET_ETHERFI_NODES_MANAGER = 0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F;
    address internal constant _MAINNET_EIGENLAYER_DELEGATION_MANAGER = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A;

    bytes4 internal constant _UNDELEGATE_SELECTOR = IDelegationManager.undelegate.selector;

    IEtherFiNodesManager internal _nodesManager;
    IDelegationManager internal _delegationManager;
    address internal _delegationManagerAddr;
    address internal _broadcaster;
    uint256 internal _batchSize;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        _broadcaster = vm.addr(pk);

        address nodesManagerAddr = vm.envOr("NODES_MANAGER", _MAINNET_ETHERFI_NODES_MANAGER);
        _delegationManagerAddr = vm.envOr("DELEGATION_MANAGER", _MAINNET_EIGENLAYER_DELEGATION_MANAGER);

        _nodesManager = IEtherFiNodesManager(nodesManagerAddr);
        _delegationManager = IDelegationManager(_delegationManagerAddr);

        _batchSize = vm.envOr("BATCH_SIZE", uint256(20));
        bool autoWhitelist = vm.envOr("AUTO_WHITELIST", false);

        string memory jsonPath = vm.envOr("INPUT_JSON", _defaultInputPath());
        string memory jsonData = vm.readFile(jsonPath);

        address[] memory nodes = _loadNodes(jsonData);

        console2.log("=== UNDELEGATE ALL STAKERS ===");
        console2.log("Broadcaster:", _broadcaster);
        console2.log("EtherFiNodesManager:", nodesManagerAddr);
        console2.log("DelegationManager:", _delegationManagerAddr);
        console2.log("Undelegate selector:", vm.toString(_UNDELEGATE_SELECTOR));
        console2.log("Input:", jsonPath);
        console2.log("Nodes in input:", nodes.length);
        console2.log("Batch size:", _batchSize);
        console2.log("");

        vm.startBroadcast(pk);

        _ensureWhitelistedOrRevert(autoWhitelist);
        (uint256 considered, uint256 skipped, uint256 attempted) = _processAll(nodes);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== DONE ===");
        console2.log("Considered:", considered);
        console2.log("Skipped:", skipped);
        console2.log("Attempted:", attempted);
    }

    function _defaultInputPath() internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/script/operator-management/undelegate.json");
    }

    function _loadNodes(string memory jsonData) internal view returns (address[] memory nodes) {
        // Format 1: raw array like: [ { "node_address": "0x..." }, ... ]
        // (this is the shape of `script/operator-management/a41-node-address.json`)
        if (stdJson.keyExists(jsonData, "$[0].node_address")) {
            return _loadNodesFromNodeAddressArray(jsonData);
        }

        bool hasNodes = stdJson.keyExists(jsonData, ".nodes");
        bool hasValidatorIds = stdJson.keyExists(jsonData, ".validator_ids");

        if (!hasNodes && !hasValidatorIds) {
            revert("INPUT_JSON missing `.nodes` or `.validator_ids` (or $[0].node_address)");
        }
        if (hasNodes && hasValidatorIds) {
            revert("INPUT_JSON must contain only one of `.nodes` or `.validator_ids`");
        }

        if (hasNodes) {
            nodes = abi.decode(vm.parseJson(jsonData, ".nodes"), (address[]));
            return nodes;
        }

        uint256[] memory validatorIds = abi.decode(vm.parseJson(jsonData, ".validator_ids"), (uint256[]));
        nodes = new address[](validatorIds.length);
        for (uint256 i = 0; i < validatorIds.length; i++) {
            nodes[i] = _nodesManager.etherfiNodeAddress(validatorIds[i]);
        }
    }

    function _loadNodesFromNodeAddressArray(string memory jsonData) internal view returns (address[] memory nodes) {
        // Count array length by probing for sequential indices.
        uint256 n = 0;
        while (true) {
            string memory path = string.concat("$[", vm.toString(n), "].node_address");
            if (!stdJson.keyExists(jsonData, path)) break;
            unchecked {
                ++n;
            }
        }
        if (n == 0) revert("INPUT_JSON: empty node_address array");

        nodes = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            nodes[i] = stdJson.readAddress(jsonData, string.concat("$[", vm.toString(i), "].node_address"));
        }
    }

    function _ensureWhitelistedOrRevert(bool autoWhitelist) internal {
        // Ensure the call-forwarding whitelist is enabled for this broadcaster (optional).
        if (_nodesManager.allowedForwardedExternalCalls(_broadcaster, _UNDELEGATE_SELECTOR, _delegationManagerAddr)) {
            return;
        }
        if (!autoWhitelist) {
            revert("NOT_WHITELISTED: set AUTO_WHITELIST=true or whitelist manually");
        }
        _nodesManager.updateAllowedForwardedExternalCalls(_broadcaster, _UNDELEGATE_SELECTOR, _delegationManagerAddr, true);
        console2.log("[OK] Whitelisted undelegate for broadcaster");
        console2.log("");
    }

    function _processAll(address[] memory nodes) internal returns (uint256 considered, uint256 skipped, uint256 attempted) {
        uint256 i = 0;
        while (i < nodes.length) {
            uint256 end = _min(nodes.length, i + _batchSize);

            (address[] memory batchNodes, bytes[] memory batchData, uint256 consideredBatch, uint256 skippedBatch) =
                _buildBatch(nodes, i, end);
            considered += consideredBatch;
            skipped += skippedBatch;

            if (batchNodes.length == 0) {
                i = end;
                continue;
            }

            console2.log("Batch start:", i);
            console2.log("Batch end:", end);
            console2.log("Attempting:", batchNodes.length);

            try _nodesManager.forwardExternalCall(batchNodes, batchData, _delegationManagerAddr) returns (bytes[] memory returnData) {
                attempted += batchNodes.length;
                _logWithdrawalRoots(batchNodes, returnData);
            } catch (bytes memory err) {
                console2.log("[BATCH REVERT]");
                console2.log("  start:", i);
                console2.log("  end:", end);
                console2.log("  len:", batchNodes.length);
                console2.logBytes(err);
                revert("BATCH_REVERT: rerun with smaller BATCH_SIZE or fix underlying revert");
            }

            i = end;
        }
    }

    function _buildBatch(
        address[] memory nodes,
        uint256 start,
        uint256 end
    )
        internal
        view
        returns (address[] memory batchNodes, bytes[] memory batchData, uint256 considered, uint256 skipped)
    {
        uint256 maxLen = end - start;
        batchNodes = new address[](maxLen);
        batchData = new bytes[](maxLen);

        uint256 k = 0;
        for (uint256 j = start; j < end; j++) {
            address node = nodes[j];
            considered++;

            if (node == address(0)) {
                skipped++;
                continue;
            }
            if (!_delegationManager.isDelegated(node)) {
                skipped++;
                continue;
            }
            if (_delegationManager.isOperator(node)) {
                skipped++;
                continue;
            }

            batchNodes[k] = node;
            batchData[k] = abi.encodeWithSelector(_UNDELEGATE_SELECTOR, node);
            unchecked {
                ++k;
            }
        }

        // Shrink arrays to actual size `k`.
        assembly {
            mstore(batchNodes, k)
            mstore(batchData, k)
        }
    }

    function _logWithdrawalRoots(address[] memory nodes, bytes[] memory returnData) internal pure {
        // Each element should be the raw returndata from DelegationManager.undelegate(staker)
        // i.e. abi-encoded `bytes32[] withdrawalRoots`.
        if (nodes.length != returnData.length) return;
        for (uint256 i = 0; i < nodes.length; i++) {
            bytes memory ret = returnData[i];
            // If return data can't be decoded, just skip logging roots.
            if (ret.length == 0) {
                continue;
            }
            // NOTE: if this decode reverts due to unexpected returndata, it will bubble up.
            bytes32[] memory roots = abi.decode(ret, (bytes32[]));
            // Minimal logging, but enough to diff outcomes.
            console2.log("  node:", nodes[i]);
            console2.log("  withdrawalRoots:", roots.length);
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

