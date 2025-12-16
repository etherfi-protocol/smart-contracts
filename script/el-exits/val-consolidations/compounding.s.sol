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
        
        // Parse validators from JSON
        (bytes[] memory pubkeys, uint256[] memory ids, address targetEigenPod) = _parseValidatorsFromConsolidateTwoJson();
        
        console2.log("Found", pubkeys.length, "validators");
        
        if (pubkeys.length == 0) {
            console2.log("No validators to compound");
            return;
        }
        
        // linking all validators
        _linkAllValidatorIds(ids, pubkeys);

        // Verify target pod
        (, IEigenPod targetPod) = _resolvePod(pubkeys[0]);
        require(address(targetPod) != address(0), "First validator has no pod");
        require(address(targetPod) == targetEigenPod, "Pod address mismatch");

        _executeCompoundingBatch(pubkeys, pubkeys[0], targetPod);
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

    // === HELPER FUNCTIONS ===
    function _parseValidatorsFromConsolidateTwoJson() internal view returns (bytes[] memory pubkeys, uint256[] memory ids, address targetEigenPod) {
        string memory root = vm.projectRoot();
        string memory jsonFilePath = string.concat(
            root,
            "/script/el-exits/val-consolidations/LugaNodes.json"
        );
        string memory jsonData = vm.readFile(jsonFilePath);
        bytes memory withdrawalCredentials = stdJson.readBytes(jsonData, "$[0].withdrawal_credentials");
        targetEigenPod = address(uint160(uint256(bytes32(withdrawalCredentials))));
        console2.log("Target EigenPod from withdrawal credentials:", targetEigenPod);
        uint256 validatorCount = 50; // First 50 validators from LugaNodes.json

        pubkeys = new bytes[](validatorCount);
        ids = new uint256[](validatorCount);

        for (uint256 i = 0; i < validatorCount; i++) {
            string memory basePath = string.concat("$[", vm.toString(i), "]");
            ids[i] = stdJson.readUint(jsonData, string.concat(basePath, ".id"));
            pubkeys[i] = stdJson.readBytes(jsonData, string.concat(basePath, ".pubkey"));
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

