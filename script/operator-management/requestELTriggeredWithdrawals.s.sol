// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "forge-std/StdJson.sol";

import {EtherFiNodesManager} from "../../src/EtherFiNodesManager.sol";
import {IEtherFiNode} from "../../src/interfaces/IEtherFiNode.sol";
import "../../src/eigenlayer-interfaces/IEigenPod.sol";

import "../utils/utils.sol";

/**
 * @notice Broadcasts `EtherFiNodesManager.requestExecutionLayerTriggeredWithdrawal()` for every pubkey in
 *         `script/operator-management/a41-node-address.json`.
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

    function run() external {
        _nodesManager = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER));

        string memory jsonPath = string.concat(vm.projectRoot(), "/script/operator-management/a41-node-address.json");
        string memory jsonData = vm.readFile(jsonPath);

        uint256 nodeCount = _countNodeEntries(jsonData);
        console2.log("=== EL TRIGGERED WITHDRAWALS (A41) ===");
        console2.log("NodesManager:", address(_nodesManager));
        console2.log("JSON:", jsonPath);
        console2.log("Entries:", nodeCount);

        console2.log("Broadcaster:", EL_EXIT_TRIGGERER);
        console2.log("");

        vm.startBroadcast(EL_EXIT_TRIGGERER);
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
        vm.stopBroadcast();
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

