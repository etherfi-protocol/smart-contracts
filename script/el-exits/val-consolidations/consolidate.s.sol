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
   forge script script/el-exits/val-consolidations/consolidate.s.sol:ConsolidateValidators \
     --rpc-url $MAINNET_RPC_URL \
     -- --fs script/el-exits/val-consolidations \
     --broadcast \
     -vvvv
*/

contract ConsolidateValidators is Script, Utils {
    using stdJson for string;
    
    // === MAINNET CONTRACT ADDRESSES ===
    EtherFiNodesManager constant etherFiNodesManager = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER));
    RoleRegistry constant roleRegistry = RoleRegistry(ROLE_REGISTRY);
    EtherFiTimelock constant etherFiOperatingTimelock = EtherFiTimelock(payable(OPERATING_TIMELOCK));
    
    function run() external {
        console2.log("=== CONSOLIDATION SCRIPT ===");
        
        // Parse validators from JSON
        (bytes[] memory pubkeys, uint256[] memory ids, address targetEigenPod) = _parseValidatorsFromJson();
        
        console2.log("Found", pubkeys.length, "validators");
        
        if (pubkeys.length == 0) {
            console2.log("No validators to consolidate");
            return;
        }

        // Link validators at indices 0, 250, 500, 750 (1st, 251st, 501st, 751st)
        _linkLegacyValidatorIds(ids, pubkeys);
        
        // Verify target pod
        (IEtherFiNode firstNode, IEigenPod targetPod) = _resolvePod(pubkeys[0]);
        require(address(targetPod) != address(0), "First validator has no pod");
        require(address(targetPod) == targetEigenPod, "Pod address mismatch");
        
        console2.log("Target EigenPod:", address(targetPod));

        // Split into 4 batches: 250, 250, 250, 253
        uint256[4] memory batchSizes = [uint256(250), 250, 250, 253];
        uint256 startIndex = 0;
        
        for (uint256 batchNum = 0; batchNum < 4; batchNum++) {
            uint256 batchSize = batchSizes[batchNum];
            uint256 endIndex = startIndex + batchSize;
            
            // Ensure we don't exceed array bounds
            if (endIndex > pubkeys.length) {
                endIndex = pubkeys.length;
                batchSize = endIndex - startIndex;
            }
            
            if (batchSize == 0) break;
            
            console2.log("=== Processing Batch", batchNum + 1, "===");
            // console2.log("Validators:", startIndex, "to", endIndex - 1, "(count:", batchSize, ")");
            console2.log("Batch size:", batchSize);
            console2.log("Start index:", startIndex);
            console2.log("End index:", endIndex);
            
            // Extract batch
            bytes[] memory batchPubkeys = new bytes[](batchSize);
            for (uint256 i = 0; i < batchSize; i++) {
                batchPubkeys[i] = pubkeys[startIndex + i];
            }
            
            // Execute consolidation for this batch
            _executeConsolidationBatch(batchPubkeys, targetPod);
            
            startIndex = endIndex;
        }
        
        console2.log("=== All consolidation batches completed successfully! ===");
    }

    function _linkLegacyValidatorIds(uint256[] memory ids, bytes[] memory pubkeys) internal {
        // Link validators at indices 0, 250, 500, 750 (1st, 251st, 501st, 751st)
        uint256[4] memory indices = [uint256(0), 250, 500, 750];
        uint256[] memory legacyIds = new uint256[](4);
        bytes[] memory legacyPubkeys = new bytes[](4);
        uint256 legacyCount = 0;
        
        for (uint256 i = 0; i < 4; i++) {
            uint256 idx = indices[i];
            if (idx < ids.length && idx < pubkeys.length) {
                legacyIds[legacyCount] = ids[idx];
                legacyPubkeys[legacyCount] = pubkeys[idx];
                legacyCount++;
            }
        }
        
        if (legacyCount == 0) {
            console2.log("No validators to link");
            return;
        }
        
        // Resize arrays to actual count
        uint256[] memory finalLegacyIds = new uint256[](4);
        bytes[] memory finalLegacyPubkeys = new bytes[](4);
        for (uint256 i = 0; i < legacyCount; i++) {
            console2.log("Linking legacy validator ID:", legacyIds[i]);
            console2.log("Linking legacy validator pubkey:");
            console2.logBytes(legacyPubkeys[i]);
            finalLegacyIds[i] = legacyIds[i];
            finalLegacyPubkeys[i] = legacyPubkeys[i];
        }
        
        console2.log("Linking", legacyCount, "legacy validator IDs (indices 0, 250, 500, 750)...");
        _executeTimelockBatch(
            address(etherFiNodesManager),
            0,
            abi.encodeWithSelector(
                etherFiNodesManager.linkLegacyValidatorIds.selector,
                finalLegacyIds,
                finalLegacyPubkeys
            ),
            "linkLegacyValidatorIds"
        );
        console2.log("Legacy validator IDs linked successfully");
    }

    // === HELPER FUNCTIONS ===
    
    function _parseValidatorsFromJson() internal view returns (
        bytes[] memory pubkeys,
        uint256[] memory ids,
        address targetEigenPod
    ) {
        // Build absolute path to JSON file
        string memory root = vm.projectRoot();
        string memory jsonFilePath = string.concat(root, "/script/el-exits/val-consolidations/consolidate.json");
        
        // Read JSON file
        string memory jsonData = vm.readFile(jsonFilePath);
        
        // Read eigenpod_address from JSON
        targetEigenPod = stdJson.readAddress(jsonData, ".eigenpod_address");
        console2.log("Target EigenPod from JSON:", targetEigenPod);
        
        // Read validators array (it's stored as a JSON string, so we need to parse it)
        string memory validatorsJsonStr = stdJson.readString(jsonData, ".validators");
        
        // Parse the validators JSON string as an array
        pubkeys = new bytes[](1003);
        ids = new uint256[](1003);
        uint256 validatorCount = 0;
        
        // Parse validators one by one from the validators JSON string
        for (uint256 i = 0; i < 1003; i++) {
            string memory basePath = string.concat("$[", vm.toString(i), "]");
            string memory idPath = string.concat(basePath, ".id");
            
            // Check if this element exists in the validators JSON string
            if (!stdJson.keyExists(validatorsJsonStr, idPath)) {
                break;
            }
            
            uint256 id = stdJson.readUint(validatorsJsonStr, idPath);
            bytes memory pubkey = stdJson.readBytes(validatorsJsonStr, string.concat(basePath, ".pubkey"));
            
            pubkeys[validatorCount] = pubkey;
            ids[validatorCount] = id;
            validatorCount++;
        }
        
        // // Create properly sized arrays
        // pubkeys = new bytes[](validatorCount);
        // ids = new uint256[](validatorCount);
        // for (uint256 i = 0; i < validatorCount; i++) {
        //     pubkeys[i] = tempPubkeys[i];
        //     ids[i] = tempIds[i];
        // }
    }

    function _consolidationRequestsFromPubkeys(bytes[] memory pubkeys)
        internal
        pure
        returns (IEigenPodTypes.ConsolidationRequest[] memory reqs) {
        reqs = new IEigenPodTypes.ConsolidationRequest[](pubkeys.length);
        for (uint256 i = 0; i < pubkeys.length; ++i) {
            reqs[i] = IEigenPodTypes.ConsolidationRequest({
                srcPubkey: pubkeys[i],
                targetPubkey: pubkeys[0] // same pod consolidation
            });
        }
    }

    function _resolvePod(bytes memory pubkey) internal view returns (IEtherFiNode etherFiNode, IEigenPod pod) {
        bytes32 pkHash = etherFiNodesManager.calculateValidatorPubkeyHash(pubkey);
        etherFiNode = etherFiNodesManager.etherFiNodeFromPubkeyHash(pkHash);
        pod = etherFiNode.getEigenPod();
        require(address(pod) != address(0), "_resolvePod: node has no pod");
    }
    
    function _executeConsolidationBatch(bytes[] memory batchPubkeys, IEigenPod targetPod) internal {
        // Create consolidation requests
        IEigenPodTypes.ConsolidationRequest[] memory reqs = _consolidationRequestsFromPubkeys(batchPubkeys);
        
        // Calculate fees
        uint256 feePer = targetPod.getConsolidationRequestFee();
        uint256 totalFee = feePer * reqs.length;
        
        console2.log("Fee per request:", feePer);
        console2.log("Number of requests:", reqs.length);
        console2.log("Total fee required:", totalFee);
        
        // Fund the timelock with enough ETH to pay consolidation fees
        vm.deal(address(etherFiOperatingTimelock), totalFee + 1 ether);
        
        // Execute via timelock
        _executeTimelockBatch(
            address(etherFiNodesManager),
            totalFee,
            abi.encodeWithSelector(
                etherFiNodesManager.requestConsolidation.selector,
                reqs
            ),
            "requestConsolidation"
        );
        
        console2.log("Batch consolidation completed successfully!");
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

