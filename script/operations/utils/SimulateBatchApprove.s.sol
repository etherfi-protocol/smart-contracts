// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "forge-std/StdJson.sol";
import "../../../src/interfaces/ILiquidityPool.sol";
import "../../../src/interfaces/IEtherFiNodesManager.sol";

/**
 * @title SimulateBatchApprove
 * @notice Simulates batchApproveRegistration with validator data from JSON file
 * 
 * Usage:
 *   JSON_FILE=validators.json forge script \
 *     script/operations/utils/SimulateBatchApprove.s.sol:SimulateBatchApprove \
 *     --fork-url $MAINNET_RPC_URL -vvvv
 * 
 * JSON Format:
 *   [
 *     {"validator_id": 31225, "pubkey": "0xb4d601...", "eigenpod": "0x9ad4d1..."},
 *     {"validator_id": 31226, "pubkey": "0xa5eefc...", "eigenpod": "0x9ad4d1..."}
 *   ]
 */
contract SimulateBatchApprove is Script {
    using stdJson for string;
    
    // Mainnet addresses
    address constant LIQUIDITY_POOL = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address constant NODES_MANAGER = 0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F;
    address constant ETHERFI_ADMIN = 0x0EF8fa4760Db8f5Cd4d993f3e3416f30f942D705;
    
    function run() external {
        ILiquidityPool liquidityPool = ILiquidityPool(LIQUIDITY_POOL);
        IEtherFiNodesManager nodesManager = IEtherFiNodesManager(NODES_MANAGER);
        
        // Load JSON file
        string memory jsonFile = vm.envString("JSON_FILE");
        string memory jsonPath = _resolvePath(jsonFile);
        string memory jsonData = vm.readFile(jsonPath);
        
        console2.log("=== BATCH APPROVE SIMULATION ===");
        console2.log("JSON file:", jsonPath);
        console2.log("");
        
        // Count validators
        uint256 count = 0;
        for (uint256 i = 0; i < 1000; i++) {
            string memory path = string.concat("$[", vm.toString(i), "].validator_id");
            if (!stdJson.keyExists(jsonData, path)) break;
            count++;
        }
        
        console2.log("Validators found:", count);
        if (count == 0) {
            console2.log("No validators in JSON file");
            return;
        }
        
        // Parse validators
        uint256[] memory validatorIds = new uint256[](count);
        bytes[] memory pubkeys = new bytes[](count);
        bytes[] memory signatures = new bytes[](count);
        
        for (uint256 i = 0; i < count; i++) {
            string memory basePath = string.concat("$[", vm.toString(i), "]");
            validatorIds[i] = stdJson.readUint(jsonData, string.concat(basePath, ".validator_id"));
            pubkeys[i] = stdJson.readBytes(jsonData, string.concat(basePath, ".pubkey"));
            signatures[i] = new bytes(96); // Dummy signature
        }
        
        console2.log("");
        
        // Analyze node distribution
        console2.log("=== NODE ANALYSIS ===");
        address firstNode = nodesManager.etherfiNodeAddress(validatorIds[0]);
        console2.log("First validator:", validatorIds[0]);
        console2.log("First node:", firstNode);
        
        bool allSameNode = true;
        uint256 mismatchIndex = 0;
        for (uint256 i = 1; i < count; i++) {
            address node = nodesManager.etherfiNodeAddress(validatorIds[i]);
            if (node != firstNode) {
                allSameNode = false;
                mismatchIndex = i;
                console2.log("");
                console2.log("MISMATCH at index:", i);
                console2.log("  Validator:", validatorIds[i]);
                console2.log("  Node:", node);
                console2.log("  Expected:", firstNode);
                break;
            }
        }
        
        if (allSameNode) {
            console2.log("All", count, "validators belong to same node");
        }
        
        console2.log("");
        console2.log("=== SIMULATING batchApproveRegistration ===");
        console2.log("Caller: EtherFiAdmin", ETHERFI_ADMIN);
        console2.log("Validators:", count);
        console2.log("");
        
        vm.prank(ETHERFI_ADMIN);
        
        try liquidityPool.batchApproveRegistration(validatorIds, pubkeys, signatures) {
            console2.log("RESULT: SUCCESS");
            console2.log("");
            console2.log("The batch would succeed with valid signatures.");
        } catch (bytes memory err) {
            bytes4 selector = bytes4(err);
            
            if (selector == bytes4(keccak256("InvalidEtherFiNode()"))) {
                console2.log("RESULT: FAILED - InvalidEtherFiNode()");
                console2.log("");
                console2.log("Validators belong to different EtherFiNodes.");
                console2.log("Split into separate batches by node.");
            } else if (selector == bytes4(keccak256("UnlinkedPubkey()"))) {
                console2.log("RESULT: PASSED node check, failed at UnlinkedPubkey()");
                console2.log("");
                console2.log("All validators are in same node. Would succeed with valid signatures.");
            } else if (selector == bytes4(keccak256("IncorrectRole()"))) {
                console2.log("RESULT: FAILED - IncorrectRole()");
                console2.log("");
                console2.log("Caller doesn't have LIQUIDITY_POOL_VALIDATOR_APPROVER_ROLE");
            } else {
                console2.log("RESULT: FAILED - Unknown error");
                console2.log("  Selector:", vm.toString(selector));
            }
        }
    }
    
    function _resolvePath(string memory path) internal view returns (string memory) {
        if (bytes(path).length > 0 && bytes(path)[0] == '/') {
            return path;
        }
        // Check if path starts with "script/"
        bytes memory pathBytes = bytes(path);
        if (pathBytes.length >= 7 && 
            pathBytes[0] == 's' && pathBytes[1] == 'c' && pathBytes[2] == 'r' && 
            pathBytes[3] == 'i' && pathBytes[4] == 'p' && pathBytes[5] == 't' && pathBytes[6] == '/') {
            return string.concat(vm.projectRoot(), "/", path);
        }
        return string.concat(vm.projectRoot(), "/", path);
    }
}

