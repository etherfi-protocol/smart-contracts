// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/console2.sol";
import "forge-std/StdJson.sol";
import "forge-std/Script.sol";

import "../utils/utils.sol";

import {EtherFiTimelock} from "../../src/EtherFiTimelock.sol";
import {EtherFiNodesManager} from "../../src/EtherFiNodesManager.sol";
import {RoleRegistry} from "../../src/RoleRegistry.sol";
import {IDelegationManager} from "../../src/eigenlayer-interfaces/IDelegationManager.sol";
import {EtherFiRateLimiter} from "../../src/EtherFiRateLimiter.sol";

contract Configurations is Script, Utils {
    using stdJson for string;

    EtherFiTimelock internal _operatingTimelock;
    EtherFiNodesManager internal _nodesManager;
    RoleRegistry internal _roleRegistry;
    IDelegationManager internal _delegationManager;
    EtherFiRateLimiter internal _rateLimiter;

    // FULL_EXIT_GWEI = 2_048_000_000_000 = 2,048 ETH
    // 2616 vals * FULL_EXIT_GWEI = 5,400,000 ETH in gwei
    uint64 internal constant EXIT_REQUEST_BUCKET_CAPACITY_GWEI = 5_400_000_000_000_000; // 5,400,000 ETH in gwei
    uint64 internal constant EXIT_REQUEST_BUCKET_REMAINING_GWEI = 5_400_000_000_000_000; // 5,400,000 ETH in gwei

    address internal constant _MAINNET_EIGENLAYER_DELEGATION_MANAGER = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A;
    address internal constant _A41_OPERATOR_MANAGER = 0xe0156eF2905c2Ea8B1F7571cAEE85fdF1657Ab38; // https://app.eigenlayer.xyz/operator/0xe0156ef2905c2ea8b1f7571caee85fdf1657ab38
    address internal constant _CHAINNODES_OPERATOR_MANAGER = 0x8e7e7176D3470c6c2Efe71004f496A6Ef422a56F; // https://app.eigenlayer.xyz/operator/0x8e7e7176d3470c6c2efe71004f496a6ef422a56f

    bytes4 internal constant _DELEGATE_TO_SELECTOR = IDelegationManager.delegateTo.selector;
    bytes4 internal constant _REDELEGATE_SELECTOR = IDelegationManager.redelegate.selector;
    bytes4 internal constant _UNDELEGATE_SELECTOR = IDelegationManager.undelegate.selector;

    uint256 internal constant _A41_REDELEGATE_PART1_NODES = 22;

    function run() external {
        _initAddresses();
        string memory jsonPath = string.concat(vm.projectRoot(), "/script/operator-management/a41-data.json");
        string memory jsonData = vm.readFile(jsonPath);


        string memory jsonPathEtherFiNodes = string.concat(vm.projectRoot(), "/script/operator-management/etherFiNodes.json");
        string memory jsonDataEtherFiNodes = vm.readFile(jsonPathEtherFiNodes);
        (uint256[] memory ids, bytes[] memory pks) = _linkLegacyValidatorIds(jsonData);
        (address[] memory nodes, bytes[] memory batchData) = _getA41NodesAndBatchData(jsonDataEtherFiNodes);
        console2.log("A41 nodes to redelegate:", nodes.length);
        if (nodes.length != 48) revert("EXPECTED_48_A41_NODES");
        if (batchData.length != nodes.length) revert("NODES_BATCHDATA_LEN_MISMATCH");

        (address[] memory nodesP1, bytes[] memory batchDataP1) =
            _sliceNodesBatch(nodes, batchData, 0, _A41_REDELEGATE_PART1_NODES);
        (address[] memory nodesP2, bytes[] memory batchDataP2) =
            _sliceNodesBatch(nodes, batchData, _A41_REDELEGATE_PART1_NODES, nodes.length - _A41_REDELEGATE_PART1_NODES);

        console2.log("Part1 nodes:", nodesP1.length); // 22
        console2.log("Part2 nodes:", nodesP2.length); // 26

        // Part 1: use the existing timelock tx (includes linkLegacyValidatorIds)
        timelockTx(ids, pks, nodesP1, batchDataP1);

        // Part 2: redelegate-only timelock tx (do NOT re-link legacy IDs)
        timelockTxRedelegateOnly(nodesP2, batchDataP2);

        updateRateLimiterCapacity();

        console2.log("=== Checking Post Configuration ===");
        console2.log("================================================");
        checksPostConfiguration(nodes);
    }

    function _initAddresses() internal {
        _operatingTimelock = EtherFiTimelock(payable(OPERATING_TIMELOCK));
        _nodesManager = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER));
        _roleRegistry = RoleRegistry(ROLE_REGISTRY);
        _delegationManager = IDelegationManager(_MAINNET_EIGENLAYER_DELEGATION_MANAGER);
        _rateLimiter = EtherFiRateLimiter(payable(ETHERFI_RATE_LIMITER));
    }

    function timelockTx(uint256[] memory ids, bytes[] memory pks, address[] memory nodes, bytes[] memory batchData) internal {
        // a) Whitelist forwarded delegateTo on DelegationManager for Operating Timelock
        // b) Whitelist forwarded redelegate on DelegationManager for Operating Timelock
        // c) Whitelist forwarded undelegate on DelegationManager for Operating Timelock
        // d) Link legacy validator ids
        // e) Forward batched redelegate calls for the nodes (for the A41 nodes)
        address[] memory targets = new address[](6);
        bytes[] memory payloads = new bytes[](targets.length);
        payloads[0] = abi.encodeWithSelector(
            _nodesManager.updateAllowedForwardedExternalCalls.selector,
            OPERATING_TIMELOCK,
            _DELEGATE_TO_SELECTOR,
            _MAINNET_EIGENLAYER_DELEGATION_MANAGER,
            true
        );
        targets[0] = ETHERFI_NODES_MANAGER;
        payloads[1] = abi.encodeWithSelector(
            _nodesManager.updateAllowedForwardedExternalCalls.selector,
            OPERATING_TIMELOCK,
            _REDELEGATE_SELECTOR,
            _MAINNET_EIGENLAYER_DELEGATION_MANAGER,
            true
        );
        targets[1] = ETHERFI_NODES_MANAGER;
        payloads[2] = abi.encodeWithSelector(
            _nodesManager.updateAllowedForwardedExternalCalls.selector,
            OPERATING_TIMELOCK,
            _UNDELEGATE_SELECTOR,
            _MAINNET_EIGENLAYER_DELEGATION_MANAGER,
            true
        );
        targets[2] = ETHERFI_NODES_MANAGER;
        payloads[3] = abi.encodeWithSelector(
            _nodesManager.linkLegacyValidatorIds.selector,
            ids,
            pks
        );
        targets[3] = ETHERFI_NODES_MANAGER;

        bytes memory forwardExternalCallData = abi.encodeWithSelector(
            _nodesManager.forwardExternalCall.selector,
            nodes,
            batchData,
            _MAINNET_EIGENLAYER_DELEGATION_MANAGER
        );
        payloads[4] = forwardExternalCallData;
        targets[4] = ETHERFI_NODES_MANAGER;

        uint256[] memory values = new uint256[](targets.length);
        for (uint256 i = 0; i < payloads.length; i++) {
            values[i] = 0;
        }

        bytes32 timelockSalt = keccak256(abi.encode("LINK_LEGACY_VALIDATOR_IDS", ETHERFI_NODES_MANAGER));
        bytes32 predecessor = bytes32(0);
        bytes memory data = abi.encodeWithSelector(
            _operatingTimelock.scheduleBatch.selector,
            targets,
            values,
            payloads,
            predecessor,
            timelockSalt,
            MIN_DELAY_OPERATING_TIMELOCK
        );

        console2.log("Scheduled Calldata Tx");
        console2.log("================================================");
        console2.logBytes(data);
        console2.log("================================================");
        console2.log("");

        bytes memory executeData = abi.encodeWithSelector(
            _operatingTimelock.executeBatch.selector,
            targets,
            values,
            payloads,
            predecessor,
            timelockSalt
        );
        console2.log("Executed Calldata Tx");
        console2.log("================================================");
        console2.logBytes(executeData);
        console2.log("================================================");
        console2.log("");

        vm.startPrank(ETHERFI_OPERATING_ADMIN);
        _operatingTimelock.scheduleBatch(targets, values, payloads, predecessor, timelockSalt, MIN_DELAY_OPERATING_TIMELOCK);
        vm.warp(block.timestamp + MIN_DELAY_OPERATING_TIMELOCK + 1);
        _operatingTimelock.executeBatch(targets, values, payloads, predecessor, timelockSalt);

        console2.log("Tx executed successfully");
        console2.log("================================================");
        console2.log("");
    }

    function timelockTxRedelegateOnly(address[] memory nodes, bytes[] memory batchData) internal {
        // Forward batched redelegate calls for the nodes (part 2).
        address[] memory targets = new address[](1);
        bytes[] memory payloads = new bytes[](1);
        uint256[] memory values = new uint256[](1);

        payloads[0] = abi.encodeWithSelector(
            _nodesManager.forwardExternalCall.selector,
            nodes,
            batchData,
            _MAINNET_EIGENLAYER_DELEGATION_MANAGER
        );
        targets[0] = ETHERFI_NODES_MANAGER;
        values[0] = 0;

        bytes32 predecessor = bytes32(0);
        bytes32 timelockSalt = keccak256(
            abi.encode("A41_REDELEGATE_PART2", ETHERFI_NODES_MANAGER, _MAINNET_EIGENLAYER_DELEGATION_MANAGER, nodes)
        );

        bytes memory scheduleData = abi.encodeWithSelector(
            _operatingTimelock.scheduleBatch.selector,
            targets,
            values,
            payloads,
            predecessor,
            timelockSalt,
            MIN_DELAY_OPERATING_TIMELOCK
        );
        console2.log("Scheduled Calldata Tx (redelegate-only / part2)");
        console2.log("================================================");
        console2.logBytes(scheduleData);
        console2.log("================================================");
        console2.log("");

        bytes memory executeData = abi.encodeWithSelector(
            _operatingTimelock.executeBatch.selector,
            targets,
            values,
            payloads,
            predecessor,
            timelockSalt
        );
        console2.log("Executed Calldata Tx (redelegate-only / part2)");
        console2.log("================================================");
        console2.logBytes(executeData);
        console2.log("================================================");
        console2.log("");

        vm.startPrank(ETHERFI_OPERATING_ADMIN);
        _operatingTimelock.scheduleBatch(targets, values, payloads, predecessor, timelockSalt, MIN_DELAY_OPERATING_TIMELOCK);
        vm.warp(block.timestamp + MIN_DELAY_OPERATING_TIMELOCK + 1);
        _operatingTimelock.executeBatch(targets, values, payloads, predecessor, timelockSalt);

        console2.log("Tx executed successfully (redelegate-only / part2)");
        console2.log("================================================");
        console2.log("");
    }

    function _sliceNodesBatch(
        address[] memory nodes,
        bytes[] memory batchData,
        uint256 start,
        uint256 len
    ) internal pure returns (address[] memory outNodes, bytes[] memory outBatchData) {
        if (batchData.length != nodes.length) revert("NODES_BATCHDATA_LEN_MISMATCH");
        if (start + len > nodes.length) revert("SLICE_OOB");

        outNodes = new address[](len);
        outBatchData = new bytes[](len);
        for (uint256 i = 0; i < len; i++) {
            outNodes[i] = nodes[start + i];
            outBatchData[i] = batchData[start + i];
        }
    }

    function _linkLegacyValidatorIds(string memory jsonData) internal returns (uint256[] memory ids, bytes[] memory pks) {
        ids = new uint256[](26);
        pks = new bytes[](26);

        for (uint256 i = 0; i < 26; i++) {
            string memory validatorIdsBlob =
                stdJson.readString(jsonData, string.concat("$[", vm.toString(i), "].validator_ids"));
            uint256 firstValidatorId = _parseFirstValidatorIdBlob(validatorIdsBlob);

            string memory pubkeysBlob = stdJson.readString(jsonData, string.concat("$[", vm.toString(i), "].pubkeys"));
            bytes[] memory pubkeys = _parsePubkeysBlob(pubkeysBlob);
            if (pubkeys.length == 0) revert("INPUT_JSON: empty pubkeys array");

            bytes memory firstPubkey = pubkeys[0];
            if (firstPubkey.length != 48) revert("INPUT_JSON: pubkey must be 48 bytes");
            ids[i] = firstValidatorId;
            pks[i] = firstPubkey;
        }
    }

    function _getA41NodesAndBatchData(string memory jsonData) internal returns (address[] memory nodes, bytes[] memory batchData) {
        // Count array length by probing for sequential indices.
        uint256 nodeCount = 0;
        while (true) {
            string memory path = string.concat("$[", vm.toString(nodeCount), "].node_address");
            if (!stdJson.keyExists(jsonData, path)) break;
            unchecked {
                ++nodeCount;
            }
        }
        if (nodeCount == 0) revert("INPUT_JSON: empty node_address array");

        // Filter nodes whose *current* EigenLayer operator is A41, and build per-node redelegate calldata.
        address[] memory nodesTmp = new address[](nodeCount);
        bytes[] memory batchDataTmp = new bytes[](nodeCount);

        IDelegationManager.SignatureWithExpiry memory emptySig;
        bytes32 emptySalt = bytes32(0);

        uint256 n = 0;
        for (uint256 i = 0; i < nodeCount; i++) {
            address node = stdJson.readAddress(jsonData, string.concat("$[", vm.toString(i), "].node_address"));
            if (node == address(0)) revert(string.concat("INPUT_JSON: node_address is zero at index=", vm.toString(i)));
            address operator = _delegationManager.delegatedTo(node);

            // Keep only A41-managed nodes
            if (operator != _A41_OPERATOR_MANAGER) continue;

            // PRECHECK: redelegate behaves like undelegate+delegate, and will revert for operators / non-delegated stakers.
            if (!_delegationManager.isDelegated(node)) {
                revert(string.concat("PRECHECK: node not delegated at index=", vm.toString(i)));
            }
            if (_delegationManager.isOperator(node)) {
                revert(string.concat("PRECHECK: node is operator (cannot redelegate) at index=", vm.toString(i)));
            }

            nodesTmp[n] = node;
            batchDataTmp[n] = abi.encodeWithSelector(
                _REDELEGATE_SELECTOR,
                _CHAINNODES_OPERATOR_MANAGER,
                emptySig,
                emptySalt
            );
            unchecked {
                ++n;
            }
        }

        nodes = new address[](n);
        batchData = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            nodes[i] = nodesTmp[i];
            batchData[i] = batchDataTmp[i];
        }
    }

    function checksPostConfiguration(address[] memory nodes) internal {
        console2.log("delegateTo:", _nodesManager.allowedForwardedExternalCalls(OPERATING_TIMELOCK, _DELEGATE_TO_SELECTOR, _MAINNET_EIGENLAYER_DELEGATION_MANAGER));
        console2.log("redelegate:", _nodesManager.allowedForwardedExternalCalls(OPERATING_TIMELOCK, _REDELEGATE_SELECTOR, _MAINNET_EIGENLAYER_DELEGATION_MANAGER));
        console2.log("undelegate:", _nodesManager.allowedForwardedExternalCalls(OPERATING_TIMELOCK, _UNDELEGATE_SELECTOR, _MAINNET_EIGENLAYER_DELEGATION_MANAGER));
        console2.log("================================================");
        console2.log("");

        for (uint256 i = 0; i < nodes.length; i++) {
            console2.log("Checking node:", nodes[i]);
            if (_delegationManager.delegatedTo(nodes[i]) != _CHAINNODES_OPERATOR_MANAGER) {
                console2.log("Node is not redelegated to ChainNodes");
                console2.log("================================================");
                console2.log("");
                revert("Node is not redelegated to ChainNodes");
            }
        }
        console2.log("All nodes are redelegated");
        console2.log("================================================");

        console2.log("=== Checking Rate Limiter Capacity ===");
        console2.log("================================================");
        (uint64 capAfter, uint64 remAfter, uint64 rateAfter, uint256 lastAfter) = _rateLimiter.getLimit(_nodesManager.EXIT_REQUEST_LIMIT_ID());
        console2.log("Capacity:", capAfter);
        console2.log("Remaining:", remAfter);
        console2.log("Refill Rate:", rateAfter);
        console2.log("Last Refill:", lastAfter);
        console2.log("================================================");
        console2.log("");
    }

    function updateRateLimiterCapacity() internal {
        console2.log("=== Updating Rate Limiter Capacity ===");
        console2.log("================================================");
        console2.log("Capacity:", EXIT_REQUEST_BUCKET_CAPACITY_GWEI);
        console2.log("Remaining:", EXIT_REQUEST_BUCKET_REMAINING_GWEI);
        console2.log("================================================");
        console2.log("");

        (uint64 capBefore, uint64 remBefore, uint64 rateBefore, uint256 lastBefore) = _rateLimiter.getLimit(_nodesManager.EXIT_REQUEST_LIMIT_ID());
        console2.log("Before.capacity:", capBefore);
        console2.log("Before.remaining:", remBefore);
        console2.log("Before.refillRate:", rateBefore);
        console2.log("Before.lastRefill:", lastBefore);

        bytes memory setCapacityData = abi.encodeWithSelector(
            _rateLimiter.setCapacity.selector,
            _nodesManager.EXIT_REQUEST_LIMIT_ID(),
            EXIT_REQUEST_BUCKET_CAPACITY_GWEI
        );
        bytes memory setRemainingData = abi.encodeWithSelector(
            _rateLimiter.setRemaining.selector,
            _nodesManager.EXIT_REQUEST_LIMIT_ID(),
            EXIT_REQUEST_BUCKET_REMAINING_GWEI
        );

        vm.startPrank(ETHERFI_OPERATING_ADMIN);
        _rateLimiter.setCapacity(_nodesManager.EXIT_REQUEST_LIMIT_ID(), EXIT_REQUEST_BUCKET_CAPACITY_GWEI);
        _rateLimiter.setRemaining(_nodesManager.EXIT_REQUEST_LIMIT_ID(), EXIT_REQUEST_BUCKET_REMAINING_GWEI);
        vm.stopPrank();

        console2.log("================================================");
        console2.log("Set Capacity Data");
        console2.logBytes(setCapacityData);
        console2.log("================================================");
        console2.log("Set Remaining Data");
        console2.logBytes(setRemainingData);
        console2.log("================================================");
        console2.log("");
    }



    /************ PARSING FUNCTIONS ************/

    function _parseFirstValidatorIdBlob(string memory blob) internal pure returns (uint256) {
        bytes memory b = bytes(blob);
        if (b.length == 0) revert("INPUT_JSON: empty validator_ids blob");

        // find '{'
        uint256 l = 0;
        while (l < b.length && b[l] != 0x7b) l++; // '{'
        if (l == b.length) revert("INPUT_JSON: validator_ids missing '{'");

        // scan first number after '{' (skip spaces)
        uint256 i = l + 1;
        while (i < b.length && _isSpace(b[i])) i++;
        if (i >= b.length) revert("INPUT_JSON: validator_ids missing number");

        uint256 val = 0;
        bool sawDigit = false;
        while (i < b.length) {
            uint8 c = uint8(b[i]);
            if (c >= 48 && c <= 57) {
                sawDigit = true;
                val = val * 10 + (c - 48);
                unchecked { ++i; }
                continue;
            }
            break; // stop on ',' or '}' or whitespace
        }

        if (!sawDigit) revert("INPUT_JSON: validator_ids first token not a uint");
        return val;
    }

    /**
     * @dev Parses a string formatted like "{0x<hex>,0x<hex>,...}" into bytes[] pubkeys.
     */
    function _parsePubkeysBlob(string memory blob) internal view returns (bytes[] memory out) {
        bytes memory b = bytes(blob);
        if (b.length == 0) revert("INPUT_JSON: empty pubkeys blob");

        // Locate '{'
        uint256 lbrace = 0;
        while (lbrace < b.length && b[lbrace] != 0x7b) lbrace++; // '{'
        if (lbrace == b.length) revert("INPUT_JSON: pubkeys blob missing '{'");

        // Locate last non-whitespace char, require it is '}'
        uint256 r = b.length;
        while (r > lbrace + 1 && _isSpace(b[r - 1])) {
            unchecked {
                --r;
            }
        }
        if (r <= lbrace + 1) return new bytes[](0); // "{}" or "{   }"
        if (b[r - 1] != 0x7d) revert("INPUT_JSON: pubkeys blob missing '}'"); // '}'

        uint256 contentStart = lbrace + 1;
        uint256 contentEndExclusive = r - 1; // excludes trailing '}'

        // Count pubkeys by counting "0x" occurrences in [contentStart, contentEndExclusive)
        uint256 count = 0;
        for (uint256 i = contentStart; i + 1 < contentEndExclusive; i++) {
            if (b[i] == 0x30 && (b[i + 1] == 0x78 || b[i + 1] == 0x58)) {
                unchecked {
                    ++count;
                }
            }
        }
        if (count == 0) return new bytes[](0);

        out = new bytes[](count);
        uint256 k = 0;

        uint256 idx = contentStart;
        while (idx < contentEndExclusive) {
            // find next 0x
            while (
                idx + 1 < contentEndExclusive
                    && !(b[idx] == 0x30 && (b[idx + 1] == 0x78 || b[idx + 1] == 0x58))
            ) {
                unchecked {
                    ++idx;
                }
            }
            if (idx + 1 >= contentEndExclusive) break;

            // token ends at ',' or endExclusive
            uint256 j = idx;
            while (j < contentEndExclusive && b[j] != 0x2c) {
                unchecked {
                    ++j;
                }
            } // ','

            // trim trailing whitespace inside token
            uint256 tokenEnd = j;
            while (tokenEnd > idx && _isSpace(b[tokenEnd - 1])) tokenEnd--;
            if (tokenEnd <= idx) revert("INPUT_JSON: empty pubkey token");

            string memory hexStr = _substring(b, idx, tokenEnd); // [idx, tokenEnd)
            out[k] = vm.parseBytes(hexStr);

            unchecked {
                ++k;
                idx = j + 1;
            }
        }

        assembly { mstore(out, k) }
    }

    function _isSpace(bytes1 c) internal pure returns (bool) {
        return uint8(c) <= 0x20;
    }

    function _substring(bytes memory s, uint256 start, uint256 endExclusive) internal pure returns (string memory) {
        if (endExclusive < start) revert("substring: bad bounds");
        uint256 len = endExclusive - start;
        bytes memory out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = s[start + i];
        }
        return string(out);
    }
}