// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../../utils/utils.sol";
import "../../utils/GnosisTxGeneratorLib.sol";
import "../../utils/StringHelpers.sol";
import "../../utils/ValidatorHelpers.sol";
import "../../../src/interfaces/IEtherFiNodesManager.sol";
import "../../../src/eigenlayer-interfaces/IEigenPod.sol";
import "./GnosisConsolidationLib.sol";

/**
 * @title ConsolidateToTarget
 * @notice Generates transactions to consolidate multiple validators to a single target validator
 * @dev Focused script for consolidating validators within the same EigenPod
 * 
 * Usage:
 *   JSON_FILE=validators.json TARGET_PUBKEY=0x... forge script \
 *     script/operations/consolidations/ConsolidateToTarget.s.sol:ConsolidateToTarget \
 *     --fork-url $MAINNET_RPC_URL -vvvv
 * 
 * Environment Variables:
 *   - JSON_FILE: Path to JSON file with validator data (required)
 *   - TARGET_PUBKEY: 48-byte hex pubkey of target validator (required)
 *   - OUTPUT_FILE: Output filename (default: consolidate-to-target-txns.json)
 *   - BATCH_SIZE: Number of validators per transaction (default: 50)
 *   - OUTPUT_FORMAT: "gnosis" or "raw" (default: gnosis)
 *   - SAFE_ADDRESS: Gnosis Safe address (default: ETHERFI_OPERATING_ADMIN)
 *   - CHAIN_ID: Chain ID for transaction (default: 1)
 */
contract ConsolidateToTarget is Script, Utils {
    using StringHelpers for uint256;
    using StringHelpers for address;
    using StringHelpers for bytes;
    
    // === MAINNET CONTRACT ADDRESSES ===
    IEtherFiNodesManager constant nodesManager = IEtherFiNodesManager(ETHERFI_NODES_MANAGER);
    
    // Default parameters
    string constant DEFAULT_OUTPUT_FILE = "consolidate-to-target-txns.json";
    uint256 constant DEFAULT_BATCH_SIZE = 50;
    uint256 constant DEFAULT_CHAIN_ID = 1;
    string constant DEFAULT_OUTPUT_FORMAT = "gnosis";
    
    // Config struct to avoid stack too deep
    struct Config {
        string outputFile;
        uint256 batchSize;
        string outputFormat;
        uint256 chainId;
        address safeAddress;
        string root;
    }
    
    struct ConsolidationTx {
        address to;
        uint256 value;
        bytes data;
        uint256 validatorCount;
    }
    
    function run() external {
        console2.log("=== CONSOLIDATE TO TARGET TRANSACTION GENERATOR ===");
        console2.log("");
        
        // Load config
        Config memory config = _loadConfig();
        
        // Required: JSON file and target pubkey
        string memory jsonFile = vm.envString("JSON_FILE");
        bytes memory targetPubkey = vm.envBytes("TARGET_PUBKEY");
        require(targetPubkey.length == 48, "TARGET_PUBKEY must be 48 bytes");
        
        console2.log("JSON file:", jsonFile);
        console2.log("Target pubkey:", targetPubkey.bytesToHexString());
        console2.log("Output file:", config.outputFile);
        console2.log("Batch size:", config.batchSize);
        console2.log("");
        
        // Read and parse validators
        string memory jsonFilePath = _resolvePath(config.root, jsonFile);
        string memory jsonData = vm.readFile(jsonFilePath);
        
        (bytes[] memory pubkeys, , , uint256 validatorCount) = 
            ValidatorHelpers.parseValidatorsFromJson(jsonData, 10000);
        
        console2.log("Found", validatorCount, "validators");
        
        if (pubkeys.length == 0) {
            console2.log("No validators to process");
            return;
        }
        
        // Get fee
        uint256 feePerRequest = _getConsolidationFee(targetPubkey);
        console2.log("Fee per consolidation request:", feePerRequest);
        console2.log("");
        
        // Generate and write transactions
        _processAndWrite(pubkeys, targetPubkey, feePerRequest, config);
    }
    
    function _loadConfig() internal view returns (Config memory config) {
        config.outputFile = vm.envOr("OUTPUT_FILE", string(DEFAULT_OUTPUT_FILE));
        config.batchSize = vm.envOr("BATCH_SIZE", DEFAULT_BATCH_SIZE);
        config.outputFormat = vm.envOr("OUTPUT_FORMAT", string(DEFAULT_OUTPUT_FORMAT));
        config.chainId = vm.envOr("CHAIN_ID", DEFAULT_CHAIN_ID);
        config.safeAddress = vm.envOr("SAFE_ADDRESS", ETHERFI_OPERATING_ADMIN);
        config.root = vm.projectRoot();
    }
    
    function _getConsolidationFee(bytes memory targetPubkey) internal view returns (uint256) {
        (, IEigenPod targetPod) = ValidatorHelpers.resolvePod(nodesManager, targetPubkey);
        require(address(targetPod) != address(0), "Target validator has no pod");
        return targetPod.getConsolidationRequestFee();
    }
    
    function _processAndWrite(
        bytes[] memory pubkeys,
        bytes memory targetPubkey,
        uint256 feePerRequest,
        Config memory config
    ) internal {
        ConsolidationTx[] memory transactions = _generateTransactions(
            pubkeys,
            targetPubkey,
            feePerRequest,
            config.batchSize
        );
        
        _writeOutput(transactions, config);
        
        console2.log("");
        console2.log("=== CONSOLIDATION COMPLETE ===");
        console2.log("Total validators:", pubkeys.length);
        console2.log("Number of batches:", transactions.length);
    }
    
    function _generateTransactions(
        bytes[] memory pubkeys,
        bytes memory targetPubkey,
        uint256 feePerRequest,
        uint256 batchSize
    ) internal pure returns (ConsolidationTx[] memory transactions) {
        uint256 numBatches = (pubkeys.length + batchSize - 1) / batchSize;
        transactions = new ConsolidationTx[](numBatches);
        
        for (uint256 batchIdx = 0; batchIdx < numBatches; batchIdx++) {
            uint256 startIdx = batchIdx * batchSize;
            uint256 endIdx = startIdx + batchSize;
            if (endIdx > pubkeys.length) {
                endIdx = pubkeys.length;
            }
            
            // Extract batch
            bytes[] memory batchPubkeys = new bytes[](endIdx - startIdx);
            for (uint256 i = 0; i < batchPubkeys.length; i++) {
                batchPubkeys[i] = pubkeys[startIdx + i];
            }
            
            // Generate transaction
            (address to, uint256 value, bytes memory data) = 
                GnosisConsolidationLib.generateConsolidationTransactionToTarget(
                    batchPubkeys,
                    targetPubkey,
                    feePerRequest,
                    address(nodesManager)
                );
            
            transactions[batchIdx] = ConsolidationTx({
                to: to,
                value: value,
                data: data,
                validatorCount: batchPubkeys.length
            });
        }
    }
    
    function _writeOutput(
        ConsolidationTx[] memory transactions,
        Config memory config
    ) internal {
        string memory outputPath = string.concat(config.root, "/script/operations/consolidations/", config.outputFile);
        string memory jsonOutput;
        
        if (keccak256(bytes(config.outputFormat)) == keccak256(bytes("gnosis"))) {
            GnosisTxGeneratorLib.GnosisTx[] memory gnosisTxns = new GnosisTxGeneratorLib.GnosisTx[](transactions.length);
            for (uint256 i = 0; i < transactions.length; i++) {
                gnosisTxns[i] = GnosisTxGeneratorLib.GnosisTx({
                    to: transactions[i].to,
                    value: transactions[i].value,
                    data: transactions[i].data
                });
            }
            jsonOutput = GnosisTxGeneratorLib.generateTransactionBatch(gnosisTxns, config.chainId, config.safeAddress);
        } else {
            jsonOutput = _generateRawJson(transactions);
        }
        
        vm.writeFile(outputPath, jsonOutput);
        console2.log("Output written to:", outputPath);
    }
    
    function _generateRawJson(ConsolidationTx[] memory transactions) internal pure returns (string memory) {
        string memory json = '{\n  "transactions": [\n';
        
        for (uint256 i = 0; i < transactions.length; i++) {
            json = string.concat(
                json,
                '    {\n',
                '      "to": "', transactions[i].to.addressToString(), '",\n',
                '      "value": "', transactions[i].value.uint256ToString(), '",\n',
                '      "validatorCount": ', transactions[i].validatorCount.uint256ToString(), ',\n',
                '      "data": "', transactions[i].data.bytesToHexString(), '"\n',
                '    }'
            );
            if (i < transactions.length - 1) {
                json = string.concat(json, ',\n');
            } else {
                json = string.concat(json, '\n');
            }
        }
        
        json = string.concat(json, '  ]\n}');
        return json;
    }
    
    function _resolvePath(string memory root, string memory path) internal pure returns (string memory) {
        // If path starts with /, it's already absolute
        if (bytes(path).length > 0 && bytes(path)[0] == '/') {
            return path;
        }
        // Otherwise, prepend root
        return string.concat(root, "/", path);
    }
}

