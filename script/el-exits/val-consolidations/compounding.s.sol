// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "forge-std/StdJson.sol";
import "../../utils/utils.sol";
import "../../../src/EtherFiNodesManager.sol";
import "../../../src/RoleRegistry.sol";
import "../../../src/EtherFiTimelock.sol";
import "../../../src/interfaces/IEtherFiNode.sol";
import "../../../src/eigenlayer-interfaces/IEigenPod.sol";

/**
 * @title Consolidate Validators
 * @notice Consolidates all validators from the specified EigenPod address
 * @dev Reads validator public keys from consolidate.json and consolidates them
 * 
 * Usage:
   forge script script/el-exits/val-consolidations/compounding.s.sol:CompoundValidators \
     --fork-url $MAINNET_RPC_URL \
     -- --fs script/el-exits/val-consolidations \
     -vvvv
*/

contract CompoundValidators is Script, Utils {
    using stdJson for string;
    
    // === MAINNET CONTRACT ADDRESSES ===
    EtherFiNodesManager constant etherFiNodesManager = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER));
    RoleRegistry constant roleRegistry = RoleRegistry(ROLE_REGISTRY);
    EtherFiTimelock constant etherFiOperatingTimelock = EtherFiTimelock(payable(OPERATING_TIMELOCK));
    
    function run() external {
        console2.log("=== COMPOUNDING SCRIPT ===");
        string memory jsonFilePath = string.concat(vm.projectRoot(), "/script/el-exits/val-consolidations/ebunker.json");

        // OPTION 1: filter by withdrawal credentials and take first N matches
        bytes memory withdrawalCredentials = bytes("0x010000000000000000000000499867d2d9c3eb250bb6db5cdaa1e600e75272d7");
        uint256 validatorCount = 100;
        compound_with_withdrawal_credentials(jsonFilePath, withdrawalCredentials, validatorCount);

        // OPTION 2: compound validators from the json file with start and end index
        uint256 startIndex = 0;
        uint256 endIndex = 40;
        require(endIndex > startIndex, "END_INDEX must be > START_INDEX");
        console2.log("Slice start (inclusive):", startIndex);
        console2.log("Slice end (exclusive):", endIndex);
        
        (bytes[] memory pubkeys, uint256[] memory ids, address[] memory podAddrs) =
            _parseValidatorsFromConsolidateTwoJson(jsonFilePath, startIndex, endIndex);

        console2.log("Found", pubkeys.length, "validators");
        if (pubkeys.length == 0) {
            console2.log("No validators to compound");
            return;
        }

        _linkAllValidatorIds(ids, pubkeys);
        _compoundByPod(pubkeys, podAddrs);
    }

    function _linkAllValidatorIds(uint256[] memory ids, bytes[] memory pubkeys) internal {
        require(ids.length == pubkeys.length, "ids and pubkeys length mismatch");
        
        if (ids.length == 0) {
            console2.log("No validators to link");
            return;
        }
        
        console2.log("Linking", ids.length, "validator IDs...");
        for (uint256 i = 0; i < ids.length; i++) {
            console2.log("Linking validator ID:", ids[i]);
            console2.log("Linking validator pubkey:");
            console2.logBytes(pubkeys[i]);
        }
        
        _executeTimelockBatch(
            address(etherFiNodesManager),
            0,
            abi.encodeWithSelector(
                etherFiNodesManager.linkLegacyValidatorIds.selector,
                ids,
                pubkeys
            ),
            "linkLegacyValidatorIds"
        );
        console2.log("All validator IDs linked successfully");
    }

    function _compoundByPod(bytes[] memory pubkeys, address[] memory podAddrs) internal {
        require(pubkeys.length == podAddrs.length, "pubkeys/pods length mismatch");
        if (pubkeys.length == 0) return;

        // unique pod set (O(n^2) but small batches)
        address[] memory uniqPods = new address[](pubkeys.length);
        uint256 uniqCount = 0;
        for (uint256 i = 0; i < pubkeys.length; i++) {
            address podAddr = podAddrs[i];
            bool seen = false;
            for (uint256 j = 0; j < uniqCount; j++) {
                if (uniqPods[j] == podAddr) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                uniqPods[uniqCount] = podAddr;
                unchecked { ++uniqCount; }
            }
        }

        console2.log("Unique EigenPods in input:", uniqCount);

        for (uint256 p = 0; p < uniqCount; p++) {
            address expectedPodAddr = uniqPods[p];

            bytes[] memory podPubkeysTmp = new bytes[](pubkeys.length);
            uint256 podCount = 0;

            for (uint256 i = 0; i < pubkeys.length; i++) {
                if (podAddrs[i] != expectedPodAddr) continue;
                podPubkeysTmp[podCount] = pubkeys[i];
                unchecked { ++podCount; }
            }

            if (podCount == 0) continue;

            bytes[] memory podPubkeys = _shrinkPubkeys(podPubkeysTmp, podCount);

            console2.log("------------------------------------------------");
            console2.log("EigenPod (from withdrawal credentials):", expectedPodAddr);
            console2.log("Validators in pod:", podPubkeys.length);

            // Sanity check: resolved pod matches withdrawal-credentials-derived pod.
            (, IEigenPod targetPod) = _resolvePod(podPubkeys[0]);
            require(address(targetPod) == expectedPodAddr, "Pod address mismatch in group");

            _executeCompoundingBatch(podPubkeys, podPubkeys[0], targetPod);
        }
    }

    function _shrinkPubkeys(bytes[] memory pubkeys, uint256 count) internal pure returns (bytes[] memory out) {
        out = new bytes[](count);
        for (uint256 i = 0; i < count; i++) out[i] = pubkeys[i];
    }

    // === HELPER FUNCTIONS ===
    function _parseValidatorsFromConsolidateTwoJson(string memory jsonFilePath, uint256 startIndex, uint256 endIndex)
        internal
        view
        returns (bytes[] memory pubkeys, uint256[] memory ids, address[] memory podAddrs)
    {
        return _parseFirstNFromJson(jsonFilePath, startIndex, endIndex);
    }

    /// @notice Helper to build compounding calldata for the first `validatorCount`
    ///         validators in the input json matching `withdrawalCredentials`.
    /// @dev This links *all* selected legacy IDs in one call, then batches consolidation per-pod.
    function compound_with_withdrawal_credentials(string memory jsonFilePath, bytes memory withdrawalCredentials, uint256 validatorCount) internal {
        string memory jsonData = vm.readFile(jsonFilePath);

        bytes memory normalized = _normalizeWithdrawalCredentials(withdrawalCredentials);
        (bytes[] memory pubkeys, uint256[] memory ids, address[] memory podAddrs) =
            _parseFirstNByWithdrawalCredentials(jsonData, normalized, validatorCount);

        console2.log("Input file:", jsonFilePath);
        console2.log("Target withdrawal credentials:");
        console2.logBytes(normalized);
        console2.log("Found", pubkeys.length, "validators for withdrawal credentials");

        if (pubkeys.length == 0) return;
        _linkAllValidatorIds(ids, pubkeys);
        _compoundByPod(pubkeys, podAddrs);
    }

    /// @dev Accepts either real bytes (32 bytes) OR ASCII-encoded hex string bytes (e.g. bytes("0x01..")).
    function _normalizeWithdrawalCredentials(bytes memory withdrawalCredentials) internal view returns (bytes memory out) {
        if (withdrawalCredentials.length >= 2 && withdrawalCredentials[0] == bytes1("0") && withdrawalCredentials[1] == bytes1("x")) {
            // bytes("0x...") case
            out = vm.parseBytes(string(withdrawalCredentials));
        } else {
            out = withdrawalCredentials;
        }
    }

    function _parseFirstNFromJson(
        string memory jsonFilePath,
        uint256 startIndex,
        uint256 endIndex
    ) internal view returns (bytes[] memory pubkeys, uint256[] memory ids, address[] memory podAddrs) {
        string memory jsonData = vm.readFile(jsonFilePath);
        pubkeys = new bytes[](endIndex - startIndex);
        ids = new uint256[](endIndex - startIndex);
        podAddrs = new address[](endIndex - startIndex);
        uint256 count = 0;
        for (uint256 i = startIndex; i < endIndex; i++) {
            string memory basePath = string.concat("$[", vm.toString(i), "]");
            string memory idPath = string.concat(basePath, ".id");
            if (!stdJson.keyExists(jsonData, idPath)) break;

            ids[count] = stdJson.readUint(jsonData, idPath);
            pubkeys[count] = stdJson.readBytes(jsonData, string.concat(basePath, ".pubkey"));
            bytes memory wc = stdJson.readBytes(jsonData, string.concat(basePath, ".withdrawal_credentials"));
            podAddrs[count] = address(uint160(uint256(bytes32(wc))));
            unchecked { ++count; }
        }

        if (count == endIndex - startIndex) return (pubkeys, ids, podAddrs);
        return _shrinkSlice(pubkeys, ids, podAddrs, endIndex - startIndex);
    }

    /// @notice Finds the first `validatorCount` entries matching `withdrawalCredentials`.
    /// @dev `withdrawalCredentials` should be 32 bytes (as emitted by beacon node exports).
    function _parseFirstNByWithdrawalCredentials(
        string memory jsonData,
        bytes memory withdrawalCredentials,
        uint256 validatorCount
    )
        internal
        view
        returns (bytes[] memory pubkeys, uint256[] memory ids, address[] memory podAddrs)
    {
        pubkeys = new bytes[](validatorCount);
        ids = new uint256[](validatorCount);
        podAddrs = new address[](validatorCount);

        withdrawalCredentials = _normalizeWithdrawalCredentials(withdrawalCredentials);
        require(withdrawalCredentials.length == 32, "withdrawalCredentials must be 32 bytes");

        bytes32 want = keccak256(withdrawalCredentials);
        uint256 found = 0;

        for (uint256 i = 0; found < validatorCount; i++) {
            string memory basePath = string.concat("$[", vm.toString(i), "]");
            string memory idPath = string.concat(basePath, ".id");
            if (!stdJson.keyExists(jsonData, idPath)) break;

            string memory wcPath = string.concat(basePath, ".withdrawal_credentials");
            if (!stdJson.keyExists(jsonData, wcPath)) {
                console2.log("Skip: missing withdrawal_credentials at index", i);
                continue;
            }

            bytes memory wc = stdJson.readBytes(jsonData, wcPath);
            if (wc.length != 32) {
                console2.log("Skip: bad withdrawal_credentials length at index", i, "len", wc.length);
                continue;
            }
            if (keccak256(wc) != want) continue;

            string memory pkPath = string.concat(basePath, ".pubkey");
            if (!stdJson.keyExists(jsonData, pkPath)) {
                console2.log("Skip: missing pubkey at index", i);
                continue;
            }

            ids[found] = stdJson.readUint(jsonData, idPath);
            pubkeys[found] = stdJson.readBytes(jsonData, pkPath);
            podAddrs[found] = address(uint160(uint256(bytes32(wc))));
            unchecked { ++found; }
        }

        if (found == validatorCount) return (pubkeys, ids, podAddrs);
        return _shrinkSlice(pubkeys, ids, podAddrs, found);
    }

    function _shrinkSlice(
        bytes[] memory pubkeys,
        uint256[] memory ids,
        address[] memory podAddrs,
        uint256 count
    )
        internal
        pure
        returns (bytes[] memory outPubkeys, uint256[] memory outIds, address[] memory outPods)
    {
        outPubkeys = new bytes[](count);
        outIds = new uint256[](count);
        outPods = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            outPubkeys[i] = pubkeys[i];
            outIds[i] = ids[i];
            outPods[i] = podAddrs[i];
        }
    }

    function _consolidationRequestsFromPubkeys(bytes[] memory pubkeys, bytes memory targetPubkey)
        internal
        pure
        returns (IEigenPodTypes.ConsolidationRequest[] memory reqs) {
        reqs = new IEigenPodTypes.ConsolidationRequest[](pubkeys.length);
        for (uint256 i = 0; i < pubkeys.length; ++i) {
            reqs[i] = IEigenPodTypes.ConsolidationRequest({
                srcPubkey: pubkeys[i],
                targetPubkey: targetPubkey // same pod consolidation
            });
        }
    }

    function _autoCompoundAllPubkeys(bytes[] memory pubkeys)
        internal
        pure
        returns (IEigenPodTypes.ConsolidationRequest[] memory reqs) {
        reqs = new IEigenPodTypes.ConsolidationRequest[](pubkeys.length);
        for (uint256 i = 0; i < pubkeys.length; ++i) {
            reqs[i] = IEigenPodTypes.ConsolidationRequest({
                srcPubkey: pubkeys[i],
                targetPubkey: pubkeys[i] // same pod consolidation
            });
        }
    }

    function _resolvePod(bytes memory pubkey) internal view returns (IEtherFiNode etherFiNode, IEigenPod pod) {
        bytes32 pkHash = etherFiNodesManager.calculateValidatorPubkeyHash(pubkey);
        etherFiNode = etherFiNodesManager.etherFiNodeFromPubkeyHash(pkHash);
        pod = etherFiNode.getEigenPod();
        require(address(pod) != address(0), "_resolvePod: node has no pod");
    }
    
    function _executeCompoundingBatch(bytes[] memory batchPubkeys, bytes memory targetPubkey, IEigenPod targetPod) internal {
        IEigenPodTypes.ConsolidationRequest[] memory reqs = _autoCompoundAllPubkeys(batchPubkeys);

        
        // Calculate fees
        uint256 feePer = targetPod.getConsolidationRequestFee();
        uint256 totalFee = feePer * reqs.length;
        
        console2.log("Fee per request:", feePer);
        console2.log("Number of requests:", reqs.length);
        console2.log("Total fee required:", totalFee);
        
        // Fund the timelock with enough ETH to pay consolidation fees
        vm.deal(address(etherFiOperatingTimelock), totalFee + 1 ether);
        
        // Generate and log calldata for requestConsolidation
        bytes memory consolidationCalldata = abi.encodeWithSelector(
            etherFiNodesManager.requestConsolidation.selector,
            reqs
        );
        console2.log("=== requestConsolidation Calldata ===");
        console2.logBytes(consolidationCalldata);
        console2.log("================================================");
        
        console2.log("Batch compounding completed successfully!");
    }
    
    function _executeTimelockBatch(
        address target,
        uint256 value,
        bytes memory callData,
        string memory operationName
    ) internal {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = value;
        bytes[] memory data = new bytes[](1);
        data[0] = callData;
        
        bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));
        
        // Log schedule calldata
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherFiOperatingTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt,
            MIN_DELAY_OPERATING_TIMELOCK
        );
        console2.log("=== Schedule", operationName, "Tx ===");
        console2.logBytes(scheduleCalldata);
        console2.log("================================================");
        console2.log("");
        
        // Log execute calldata
        bytes memory executeCalldata = abi.encodeWithSelector(
            etherFiOperatingTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt
        );
        console2.log("=== Execute", operationName, "Tx ===");
        console2.logBytes(executeCalldata);
        console2.log("================================================");
        console2.log("");
        
        // Schedule
        vm.prank(address(ETHERFI_OPERATING_ADMIN));
        etherFiOperatingTimelock.scheduleBatch(
            targets,
            values,
            data,
            bytes32(0),
            timelockSalt,
            MIN_DELAY_OPERATING_TIMELOCK
        );
        
        // Execute
        vm.warp(block.timestamp + MIN_DELAY_OPERATING_TIMELOCK + 1);
        vm.prank(address(ETHERFI_OPERATING_ADMIN));
        etherFiOperatingTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
    }
}

