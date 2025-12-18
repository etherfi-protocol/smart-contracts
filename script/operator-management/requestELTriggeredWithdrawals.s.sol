// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "forge-std/StdJson.sol";

import {EtherFiNodesManager} from "../../src/EtherFiNodesManager.sol";
import {IEtherFiNode} from "../../src/interfaces/IEtherFiNode.sol";
import "../../src/eigenlayer-interfaces/IEigenPod.sol";
import {EtherFiRateLimiter} from "../../src/EtherFiRateLimiter.sol";

import "../utils/utils.sol";

/**
 * @notice Broadcasts `EtherFiNodesManager.requestExecutionLayerTriggeredWithdrawal()` for every pubkey in
 *         `script/operator-management/a41-data.json`.
 *
 * Command (mainnet fork dry-run):
 * forge script script/operator-management/requestELTriggeredWithdrawals.s.sol:RequestELTriggeredWithdrawals \
 *   --fork-url $MAINNET_RPC_URL -vvvv
 *
 * Command (broadcast):
 * PRIVATE_KEY=... forge script script/operator-management/requestELTriggeredWithdrawals.s.sol:RequestELTriggeredWithdrawals \
 *   --rpc-url $MAINNET_RPC_URL --broadcast -vvvv
 */
contract RequestELTriggeredWithdrawals is Script, Utils {
    using stdJson for string;

    EtherFiNodesManager internal _nodesManager;
    address internal constant EL_EXIT_TRIGGERER = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;
    // NOTE: Rate limiter units are **gwei** (not wei). This needs to be >= max `totalExitGwei` per tx.
    // If you only change `remaining` but not `capacity`, `setRemaining()` will clamp to `capacity` and you’ll still revert.
    uint64 internal constant EXIT_REQUEST_BUCKET_CAPACITY_GWEI = 50_000_000_000_000_000; // 50,000,000 ETH in gwei
    uint64 internal constant EXIT_REQUEST_BUCKET_REMAINING_GWEI = 50_000_000_000_000_000; // 50,000,000 ETH in gwei

    function run() external {
        _nodesManager = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER));

        string memory jsonPath = string.concat(vm.projectRoot(), "/script/operator-management/a41-data.json");
        string memory jsonData = vm.readFile(jsonPath);

        uint256 nodeCount = _countNodeEntries(jsonData);
        console2.log("=== EL TRIGGERED WITHDRAWALS (A41) ===");
        console2.log("NodesManager:", address(_nodesManager));
        console2.log("JSON:", jsonPath);
        console2.log("Entries:", nodeCount);

        console2.log("Broadcaster:", EL_EXIT_TRIGGERER);
        console2.log("");

        console2.log("");
        console2.log("Linking Legacy Validator IDs");
        console2.log("===================================");
        console2.log("");
        vm.startPrank(OPERATING_TIMELOCK);
        linkLegacyValidatorIds(jsonData);
        vm.stopPrank();
        vm.startPrank(ETHERFI_OPERATING_ADMIN);
        updateRateLimiterCapacity();
        vm.stopPrank();

        // vm.startBroadcast(EL_EXIT_TRIGGERER);
        vm.startPrank(EL_EXIT_TRIGGERER);
        for (uint256 i = 0; i < nodeCount; i++) {
            address nodeAddr = stdJson.readAddress(jsonData, string.concat("$[", vm.toString(i), "].node_address"));
            uint256 expectedCount = 0;
            if (stdJson.keyExists(jsonData, string.concat("$[", vm.toString(i), "].validator_count"))) {
                expectedCount = stdJson.readUint(jsonData, string.concat("$[", vm.toString(i), "].validator_count"));
            }

            string memory pubkeysBlob = stdJson.readString(jsonData, string.concat("$[", vm.toString(i), "].pubkeys"));
            bytes[] memory pubkeys = _parsePubkeysBlob(pubkeysBlob);

            if (expectedCount != 0 && expectedCount != pubkeys.length) {
                revert(string.concat("INPUT_JSON: validator_count mismatch at index=", vm.toString(i)));
            }

            IEigenPod pod = IEtherFiNode(nodeAddr).getEigenPod();
            uint256 feePerRequest = pod.getWithdrawalRequestFee();

            console2.log("Node:", nodeAddr);
            console2.log("Pod:", address(pod));
            console2.log("Pubkeys:", pubkeys.length);
            console2.log("FeePerRequest:", feePerRequest);

            IEigenPodTypes.WithdrawalRequest[] memory reqs = new IEigenPodTypes.WithdrawalRequest[](pubkeys.length);
            for (uint256 j = 0; j < pubkeys.length; j++) {
                bytes memory pk = pubkeys[j];
                if (pk.length != 48) revert("INPUT_JSON: pubkey must be 48 bytes");
                reqs[j] = IEigenPodTypes.WithdrawalRequest({pubkey: pk, amountGwei: 0});
            }

            uint256 valueToSend = feePerRequest * pubkeys.length;
            console2.log("Value:", valueToSend);
            _nodesManager.requestExecutionLayerTriggeredWithdrawal{value: valueToSend}(reqs);

            console2.log("");
        }
        vm.stopPrank();
    }

    /// @notice For each node entry, links (first validator id) <-> (first pubkey).
    /// @dev Uses `EtherFiNodesManager.linkLegacyValidatorIds` (admin-only).
    function linkLegacyValidatorIds(string memory jsonData) internal {
        console2.log("=== Link Legacy Validator IDs ===");
        console2.log("===================================");
        console2.log("");

        uint256 nodeCount = _countNodeEntries(jsonData);
        uint256[] memory ids = new uint256[](nodeCount);
        bytes[] memory pks = new bytes[](nodeCount);

        for (uint256 i = 0; i < nodeCount; i++) {
            address nodeAddr = stdJson.readAddress(jsonData, string.concat("$[", vm.toString(i), "].node_address"));

            string memory validatorIdsBlob =
                stdJson.readString(jsonData, string.concat("$[", vm.toString(i), "].validator_ids"));
            uint256 firstValidatorId = _parseFirstValidatorIdBlob(validatorIdsBlob);

            string memory pubkeysBlob = stdJson.readString(jsonData, string.concat("$[", vm.toString(i), "].pubkeys"));
            bytes[] memory pubkeys = _parsePubkeysBlob(pubkeysBlob);
            if (pubkeys.length == 0) revert("INPUT_JSON: empty pubkeys array");

            bytes memory firstPubkey = pubkeys[0];
            if (firstPubkey.length != 48) revert("INPUT_JSON: pubkey must be 48 bytes");

            // uint256[] memory ids = new uint256[](1);
            // bytes[] memory pks = new bytes[](1);
            // ids[0] = firstValidatorId;
            // pks[0] = firstPubkey;
            ids[i] = firstValidatorId;
            pks[i] = firstPubkey;

            console2.log("linked: node=", nodeAddr, " validatorId=", firstValidatorId);
        }
        _nodesManager.linkLegacyValidatorIds(ids, pks);
        console2.log("Legacy Validator IDs linked successfully");
        console2.log("===================================");
        console2.log("");
    }

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

    function updateRateLimiterCapacity() internal {
        console2.log("=== Update Rate Limiter Capacity ===");
        bytes32 limitId = _nodesManager.EXIT_REQUEST_LIMIT_ID();
        address rateLimiterAddr = address(_nodesManager.rateLimiter());

        console2.log("NodesManager.rateLimiter():", rateLimiterAddr);
        console2.log("Deployed.ETHERFI_RATE_LIMITER:", ETHERFI_RATE_LIMITER);
        console2.log("limitId (EXIT_REQUEST_LIMIT_ID):", vm.toString(limitId));
        console2.log("targetCapacityGwei:", EXIT_REQUEST_BUCKET_CAPACITY_GWEI);
        console2.log("targetRemainingGwei:", EXIT_REQUEST_BUCKET_REMAINING_GWEI);
        console2.log("===================================");

        vm.startPrank(ETHERFI_OPERATING_ADMIN);
        EtherFiRateLimiter limiter = EtherFiRateLimiter(payable(rateLimiterAddr));

        // // Ensure bucket exists
        // if (!limiter.limitExists(limitId)) {
        //     limiter.createNewLimiter(limitId, EXIT_REQUEST_BUCKET_CAPACITY_GWEI, 0);
        // }

        // // Ensure NodesManager can consume from this bucket (consumer is msg.sender of `consume()`, i.e. NodesManager)
        // if (!limiter.isConsumerAllowed(limitId, address(_nodesManager))) {
        //     limiter.updateConsumers(limitId, address(_nodesManager), true);
        // }

        (uint64 capBefore, uint64 remBefore, uint64 rateBefore, uint256 lastBefore) = limiter.getLimit(limitId);
        console2.log("Before.capacity:", capBefore);
        console2.log("Before.remaining:", remBefore);
        console2.log("Before.refillRate:", rateBefore);
        console2.log("Before.lastRefill:", lastBefore);

        // IMPORTANT: must raise capacity first; setRemaining clamps to capacity.
        limiter.setCapacity(limitId, EXIT_REQUEST_BUCKET_CAPACITY_GWEI);
        limiter.setRemaining(limitId, EXIT_REQUEST_BUCKET_REMAINING_GWEI);

        (uint64 capAfter, uint64 remAfter, uint64 rateAfter, uint256 lastAfter) = limiter.getLimit(limitId);
        console2.log("After.capacity:", capAfter);
        console2.log("After.remaining:", remAfter);
        console2.log("After.refillRate:", rateAfter);
        console2.log("After.lastRefill:", lastAfter);
        vm.stopPrank();

        console2.log("Rate Limiter capacity updated successfully");
        console2.log("===================================");
        console2.log("");
    }

    function _countNodeEntries(string memory jsonData) internal view returns (uint256 n) {
        while (true) {
            string memory path = string.concat("$[", vm.toString(n), "].node_address");
            if (!stdJson.keyExists(jsonData, path)) break;
            unchecked {
                ++n;
            }
        }
        if (n == 0) revert("INPUT_JSON: empty node_address array");
    }

    /**
     * @dev Parses a string formatted like "{0x<hex>,0x<hex>,...}" into bytes[] pubkeys.
     */
    function _parsePubkeysBlob(string memory blob) internal view returns (bytes[] memory out) {
        bytes memory b = bytes(blob);
        if (b.length == 0) revert("INPUT_JSON: empty pubkeys blob");

        // Locate '{'
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

