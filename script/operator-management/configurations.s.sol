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

    bytes4 internal constant _DELEGATE_TO_SELECTOR = IDelegationManager.delegateTo.selector;
    bytes4 internal constant _REDELEGATE_SELECTOR = IDelegationManager.redelegate.selector;
    bytes4 internal constant _UNDELEGATE_SELECTOR = IDelegationManager.undelegate.selector;

    function run() external {
        _initAddresses();
        string memory jsonPath = string.concat(vm.projectRoot(), "/script/operator-management/a41-data.json");
        string memory jsonData = vm.readFile(jsonPath);
        (uint256[] memory ids, bytes[] memory pks) = _linkLegacyValidatorIds(jsonData);
        timelockTx(ids, pks);
        updateRateLimiterCapacity();
    }

    function _initAddresses() internal {
        _operatingTimelock = EtherFiTimelock(payable(OPERATING_TIMELOCK));
        _nodesManager = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER));
        _roleRegistry = RoleRegistry(ROLE_REGISTRY);
        _delegationManager = IDelegationManager(_MAINNET_EIGENLAYER_DELEGATION_MANAGER);
        _rateLimiter = EtherFiRateLimiter(payable(ETHERFI_RATE_LIMITER));
    }

    function timelockTx(uint256[] memory ids, bytes[] memory pks) internal {
        // a) Whitelist forwarded delegateTo on DelegationManager for Operating Timelock
        // b) Whitelist forwarded redelegate on DelegationManager for Operating Timelock
        // c) Whitelist forwarded undelegate on DelegationManager for Operating Timelock
        // d) Link legacy validator ids
        address[] memory targets = new address[](5);
        bytes[] memory payloads = new bytes[](5);
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

        // payloads[3] = abi.encodeWithSelector(
        //     _rateLimiter.setCapacity.selector,
        //     _nodesManager.EXIT_REQUEST_LIMIT_ID(),
        //     EXIT_REQUEST_BUCKET_CAPACITY_GWEI
        // );
        // targets[3] = ETHERFI_RATE_LIMITER;

        // payloads[4] = abi.encodeWithSelector(
        //     _rateLimiter.setRemaining.selector,
        //     _nodesManager.EXIT_REQUEST_LIMIT_ID(),
        //     EXIT_REQUEST_BUCKET_REMAINING_GWEI
        // );
        // targets[4] = ETHERFI_RATE_LIMITER;

        uint256[] memory values = new uint256[](payloads.length);
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

        (uint64 capAfter, uint64 remAfter, uint64 rateAfter, uint256 lastAfter) = _rateLimiter.getLimit(_nodesManager.EXIT_REQUEST_LIMIT_ID());
        console2.log("After.capacity:", capAfter);
        console2.log("After.remaining:", remAfter);
        console2.log("After.refillRate:", rateAfter);
        console2.log("After.lastRefill:", lastAfter);
        console2.log("================================================");
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