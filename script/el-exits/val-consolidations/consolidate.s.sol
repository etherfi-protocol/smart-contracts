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
        
        // Build absolute path to JSON file
        string memory root = vm.projectRoot();
        string memory jsonFilePath = string.concat(root, "/script/el-exits/val-consolidations/consolidate.json");
        
        // Read JSON file
        string memory jsonData = vm.readFile(jsonFilePath);
        
        // Read eigenpod_address from JSON
        address targetEigenPod = stdJson.readAddress(jsonData, ".eigenpod_address");
        console2.log("Target EigenPod from JSON:", targetEigenPod);
        
        // Read validators array (it's stored as a JSON string, so we need to parse it)
        string memory validatorsJsonStr = stdJson.readString(jsonData, ".validators");
        
        // Parse the validators JSON string as an array
        bytes[] memory pubkeys = new bytes[](1003); // Temp storage
        uint256[] memory ids = new uint256[](1003);
        uint256 validatorCount = 0;
        
        // Parse validators one by one from the validators JSON string
        for (uint256 i = 0; i < 1003; i++) {
            string memory basePath = string.concat("$[", vm.toString(i), "]");
            string memory idPath = string.concat(basePath, ".id");
            
            // Check if this element exists in the validators JSON string
            if (!stdJson.keyExists(validatorsJsonStr, idPath)) {
                // Reached end of array
                break;
            }
            
            uint256 id = stdJson.readUint(validatorsJsonStr, idPath);
            bytes memory pubkey = stdJson.readBytes(validatorsJsonStr, string.concat(basePath, ".pubkey"));
            
            pubkeys[validatorCount] = pubkey;
            ids[validatorCount] = id;
            address linkedAddress = _checkWhichValidatorIsLinkedAlready(pubkey);
            if (linkedAddress != address(0)) {
                console2.log("Validator: ");
                console2.logBytes(pubkey);
                console2.log("is already linked to");
                console2.logAddress(linkedAddress);
            }
            validatorCount++;
        }
        
        console2.log("Found", validatorCount, "validators");
        
        if (validatorCount == 0) {
            console2.log("No validators to consolidate");
            return;
        }

        // Link the legacy validator ID to the pubkey
        _linkLegacyValidatorId(ids[0], pubkeys[0]);
        
        // bytes[] memory onePubkey = new bytes[](1);
        // onePubkey[0] = pubkeys[0];
        // uint256[] memory oneLegacyId = new uint256[](1);
        // oneLegacyId[0] = ids[0];

        // linkLegacyValidatorId(ids[0], pubkeys[0]);

        // console2.log("Linking legacy validator ID to pubkey...");
        // vm.prank(address(etherFiOperatingTimelock));
        // etherFiNodesManager.linkLegacyValidatorIds(oneLegacyId, onePubkey);
        // vm.stopPrank();
        // console2.log("Legacy validator ID linked");
        
        // Resolve the first validator's pod to use as target
        bytes32 firstPkHash = etherFiNodesManager.calculateValidatorPubkeyHash(pubkeys[0]);
        IEtherFiNode firstNode = etherFiNodesManager.etherFiNodeFromPubkeyHash(firstPkHash);
        IEigenPod targetPod = firstNode.getEigenPod();
        
        require(address(targetPod) != address(0), "First validator has no pod");
        require(address(targetPod) == targetEigenPod, "Pod address mismatch");
        
        console2.log("Target EigenPod:", address(targetPod));

        // Create consolidation requests (all consolidating to first validator's pod)
        IEigenPodTypes.ConsolidationRequest[] memory reqs = new IEigenPodTypes.ConsolidationRequest[](pubkeys.length);
        for (uint256 i = 0; i < pubkeys.length; i++) {
            reqs[i] = IEigenPodTypes.ConsolidationRequest({
                srcPubkey: pubkeys[i],
                targetPubkey: pubkeys[0] // same pod consolidation
            });
        }
        
        // Calculate fees
        uint256 feePer = targetPod.getConsolidationRequestFee();
        uint256 totalFee = feePer * reqs.length;
        
        console2.log("Fee per request:", feePer);
        console2.log("Number of requests:", reqs.length);
        console2.log("Total fee required:", totalFee);
        
        // Fund the timelock with enough ETH to pay consolidation fees
        vm.deal(address(etherFiOperatingTimelock), totalFee + 1 ether);
        console2.log("Funded timelock with:", totalFee + 1 ether);
        address[] memory targets = new address[](1);
        targets[0] = address(etherFiNodesManager);
        uint256[] memory values = new uint256[](1);
        values[0] = totalFee;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(
            etherFiNodesManager.requestConsolidation.selector,
            reqs
        );
        bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));

        // Request consolidation
        console2.log("Requesting consolidation...");
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherFiOperatingTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt,
            MIN_DELAY_OPERATING_TIMELOCK // minDelay
        );
        console2.log("Schedule consolidation request...");
        console2.logBytes(scheduleCalldata);

        bytes memory executeCalldata = abi.encodeWithSelector(
            etherFiOperatingTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt,
            MIN_DELAY_OPERATING_TIMELOCK // minDelay
        );
        console2.log("================================================");
        console2.log("Execute consolidation request Tx:");
        console2.logBytes(executeCalldata);
        console2.log("================================================");
        console2.log("");

        vm.prank(address(ETHERFI_OPERATING_ADMIN));
        etherFiOperatingTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_OPERATING_TIMELOCK);

        console2.log("Executing consolidation request...");
        vm.warp(block.timestamp + MIN_DELAY_OPERATING_TIMELOCK + 1); // +1 to ensure it's past the delay
        vm.prank(address(ETHERFI_OPERATING_ADMIN));
        etherFiOperatingTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);

        // uncomment to run against fork
        // vm.prank(address(etherFiOperatingTimelock));
        // etherFiNodesManager.requestConsolidation{value: totalFee}(reqs);
        // vm.stopPrank();
        
        console2.log("Consolidation requested successfully!");
        console2.log("Consolidated", reqs.length, "validators to pod", address(targetPod));
    }

    function _linkLegacyValidatorId(uint256 legacyId, bytes memory pubkey) internal {
        uint256[] memory legacyIdsForOneValidator = new uint256[](1);
        legacyIdsForOneValidator[0] = legacyId;
        bytes[] memory pubkeysForOneValidator = new bytes[](1);
        pubkeysForOneValidator[0] = pubkey;

        address[] memory targets = new address[](1);
        targets[0] = address(etherFiNodesManager);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(
            etherFiNodesManager.linkLegacyValidatorIds.selector,
            legacyIdsForOneValidator,
            pubkeysForOneValidator
        );

        bytes32 timelockSalt = keccak256(
            abi.encode(targets, data, block.number)
        );

        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherFiOperatingTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0), //predecessor
            timelockSalt,
            MIN_DELAY_OPERATING_TIMELOCK
        );
        console2.log("Scheduled linkLegacyValidatorIds Tx");
        console2.log("================================================");
        console2.logBytes(scheduleCalldata);
        console2.log("================================================");
        console2.log("");

        bytes memory executeCalldata = abi.encodeWithSelector(
            etherFiOperatingTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0), //predecessor
            timelockSalt,
            MIN_DELAY_OPERATING_TIMELOCK
        );
        console2.log("Executed linkLegacyValidatorIds Tx");
        console2.log("================================================");
        console2.logBytes(executeCalldata);
        console2.log("================================================");
        console2.log("");

        console2.log("Scheduled linkLegacyValidatorIds Tx");
        vm.prank(address(ETHERFI_OPERATING_ADMIN));
        etherFiOperatingTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_OPERATING_TIMELOCK);
        console2.log("================================================");

        vm.warp(block.timestamp + MIN_DELAY_OPERATING_TIMELOCK + 1); // +1 to ensure it's past the delay
        console2.log("Executing linkLegacyValidatorIds Tx");
        console2.log("================================================");
        console2.log("");
        vm.prank(address(ETHERFI_OPERATING_ADMIN));
        etherFiOperatingTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);

        // uncomment to run against fork
        // vm.prank(address(ETHERFI_OPERATING_ADMIN));
        // etherFiNodesManager.linkLegacyValidatorIds(legacyIdsForOneValidator, pubkeysForOneValidator);
        // vm.stopPrank();
    }

    // === HELPER FUNCTIONS ===
    function _checkWhichValidatorIsLinkedAlready(bytes memory pubkey) internal view returns (address) {
        bytes32 pubkeyHash = etherFiNodesManager.calculateValidatorPubkeyHash(pubkey);
        if (etherFiNodesManager.etherFiNodeFromPubkeyHash(pubkeyHash) == IEtherFiNode(address(0))) {
            return address(0);
        } else {
            return address(etherFiNodesManager.etherFiNodeFromPubkeyHash(pubkeyHash).getEigenPod()  );
        }
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
}

