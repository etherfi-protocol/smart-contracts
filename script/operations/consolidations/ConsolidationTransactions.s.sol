// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "forge-std/StdJson.sol";
import "../../utils/utils.sol";
import "../../utils/GnosisTxGeneratorLib.sol";
import "../../utils/StringHelpers.sol";
import "../../utils/ValidatorHelpers.sol";
import "../../../src/interfaces/IEtherFiNodesManager.sol";
import "../../../src/interfaces/IEtherFiNode.sol";
import "../../../src/eigenlayer-interfaces/IEigenPod.sol";
import "./GnosisConsolidationLib.sol";

/**
 * @title ConsolidationTransactions
 * @notice Generates consolidation transaction data in multiple formats (Gnosis Safe JSON or raw JSON)
 * @dev Unified script for generating transactions for Gnosis Safe, timelock, EOA, or other execution methods
 * 
 * Usage for auto-compounding (Gnosis Safe format):
 *   forge script script/operations/consolidations/ConsolidationTransactions.s.sol:ConsolidationTransactions \
 *     --fork-url $MAINNET_RPC_URL \
 *     -- --fs script/operations/consolidations \
 *     --json-file consolidation-two.json \
 *     --output-file gnosis-consolidation-txns.json \
 *     --batch-size 50 \
 *     --mode auto-compound \
 *     --output-format gnosis \
 *     -vvvv
 * 
 * Usage for raw transaction data:
 *   --output-format raw
 * 
 * Usage for consolidation to target:
 *   --mode consolidate --target-pubkey <pubkey>
 */
contract ConsolidationTransactions is Script, Utils {
    using stdJson for string;
    
    // === MAINNET CONTRACT ADDRESSES ===
    IEtherFiNodesManager constant etherFiNodesManager = IEtherFiNodesManager(ETHERFI_NODES_MANAGER);
    
    // Default parameters
    string constant DEFAULT_JSON_FILE = "consolidation-two.json";
    string constant DEFAULT_OUTPUT_FILE = "consolidation-txns.json";
    uint256 constant DEFAULT_BATCH_SIZE = 50;
    uint256 constant DEFAULT_CHAIN_ID = 1;
    string constant DEFAULT_MODE = "auto-compound"; // "auto-compound" or "consolidate"
    string constant DEFAULT_OUTPUT_FORMAT = "raw"; // "raw" or "gnosis"
    
    // Config struct to reduce stack depth
    struct Config {
        string jsonFile;
        string outputFile;
        uint256 batchSize;
        string mode;
        string outputFormat;
        address safeAddress;
        uint256 chainId;
        string root;
    }
    
    struct ConsolidationTx {
        address to;
        uint256 value;
        bytes data;
        uint256 batchIndex;
        uint256 validatorCount;
    }
    
    function run() external {
        console2.log("=== CONSOLIDATION TRANSACTION GENERATOR ===");
        
        // Load config
        Config memory config = _loadConfig();
        
        console2.log("JSON file:", config.jsonFile);
        console2.log("Output file:", config.outputFile);
        console2.log("Batch size:", config.batchSize);
        console2.log("Mode:", config.mode);
        console2.log("");
        
        // Read and parse validators
        string memory jsonFilePath = string.concat(
            config.root,
            "/script/el-exits/val-consolidations/",
            config.jsonFile
        );
        string memory jsonData = vm.readFile(jsonFilePath);
        
        (bytes[] memory pubkeys, , address targetEigenPod, uint256 validatorCount) = 
            ValidatorHelpers.parseValidatorsFromJson(jsonData, 10000);
        
        console2.log("Found", validatorCount, "validators");
        
        if (pubkeys.length == 0) {
            console2.log("No validators to process");
            return;
        }
        
        // Get fee
        uint256 feePerRequest = _getConsolidationFee(pubkeys[0], targetEigenPod);
        console2.log("Fee per consolidation request:", feePerRequest);
        console2.log("");
        
        // Process
        _processAndWrite(pubkeys, feePerRequest, config);
    }
    
    function _loadConfig() internal view returns (Config memory config) {
        config.jsonFile = vm.envOr("JSON_FILE", string(DEFAULT_JSON_FILE));
        config.outputFile = vm.envOr("OUTPUT_FILE", string(DEFAULT_OUTPUT_FILE));
        config.batchSize = vm.envOr("BATCH_SIZE", DEFAULT_BATCH_SIZE);
        config.mode = vm.envOr("MODE", string(DEFAULT_MODE));
        config.outputFormat = vm.envOr("OUTPUT_FORMAT", string(DEFAULT_OUTPUT_FORMAT));
        config.safeAddress = vm.envOr("SAFE_ADDRESS", ETHERFI_OPERATING_ADMIN);
        config.chainId = vm.envOr("CHAIN_ID", DEFAULT_CHAIN_ID);
        config.root = vm.projectRoot();
    }
    
    function _getConsolidationFee(bytes memory pubkey, address targetEigenPod) internal view returns (uint256) {
        (, IEigenPod targetPod) = ValidatorHelpers.resolvePod(etherFiNodesManager, pubkey);
        require(address(targetPod) != address(0), "First validator has no pod");
        require(address(targetPod) == targetEigenPod, "Pod address mismatch");
        return targetPod.getConsolidationRequestFee();
    }
    
    function _processAndWrite(
        bytes[] memory pubkeys,
        uint256 feePerRequest,
        Config memory config
    ) internal {
        // Generate transactions based on mode
        ConsolidationTx[] memory transactions;
        
        if (keccak256(bytes(config.mode)) == keccak256(bytes("auto-compound"))) {
            transactions = _generateAutoCompoundTransactions(pubkeys, feePerRequest, config.batchSize);
        } else if (keccak256(bytes(config.mode)) == keccak256(bytes("consolidate"))) {
            bytes memory targetPubkey = vm.envBytes("TARGET_PUBKEY");
            require(targetPubkey.length == 48, "Target pubkey must be 48 bytes");
            transactions = _generateConsolidationTransactions(pubkeys, targetPubkey, feePerRequest, config.batchSize);
        } else {
            revert("Invalid mode. Use 'auto-compound' or 'consolidate'");
        }
        
        // Output transaction data
        console2.log("=== Generated Transactions ===");
        _logTransactions(transactions);
        
        // Generate output
        string memory outputPath = string.concat(config.root, "/script/el-exits/val-consolidations/", config.outputFile);
        string memory jsonOutput = _generateOutput(transactions, config);
        
        vm.writeFile(outputPath, jsonOutput);
        
        console2.log("");
        console2.log("=== Transactions generated successfully! ===");
        console2.log("Output file:", outputPath);
        console2.log("Total validators:", pubkeys.length);
        console2.log("Number of transactions:", transactions.length);
    }
    
    function _logTransactions(ConsolidationTx[] memory transactions) internal view {
        for (uint256 i = 0; i < transactions.length; i++) {
            console2.log("");
            console2.log("  To:", transactions[i].to);
            console2.log("  Value:", transactions[i].value);
            console2.log("  Validators:", transactions[i].validatorCount);
        }
    }
    
    function _generateOutput(
        ConsolidationTx[] memory transactions,
        Config memory config
    ) internal pure returns (string memory) {
        if (keccak256(bytes(config.outputFormat)) == keccak256(bytes("gnosis"))) {
            GnosisTxGeneratorLib.Transaction[] memory gnosisTxns = _convertToGnosisTransactions(transactions);
            string memory metaName = string.concat("Consolidation Requests (", config.mode, ")");
            string memory metaDescription = string.concat("Transactions for ", config.mode, " mode");
            return GnosisTxGeneratorLib.generateTransactionBatch(
                gnosisTxns,
                config.chainId,
                config.safeAddress,
                metaName,
                metaDescription
            );
        } else {
            return _generateRawJsonOutput(transactions);
        }
    }
    
    function _generateAutoCompoundTransactions(
        bytes[] memory pubkeys,
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
            
            // Generate transaction for this batch
            (address to, uint256 value, bytes memory data) = GnosisConsolidationLib.generateConsolidationTransaction(
                batchPubkeys,
                feePerRequest,
                address(etherFiNodesManager)
            );
            
            transactions[batchIdx] = ConsolidationTx({
                to: to,
                value: value,
                data: data,
                batchIndex: batchIdx,
                validatorCount: batchPubkeys.length
            });
        }
    }
    
    function _generateConsolidationTransactions(
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
            
            // Generate transaction for this batch
            (address to, uint256 value, bytes memory data) = GnosisConsolidationLib.generateConsolidationTransactionToTarget(
                batchPubkeys,
                targetPubkey,
                feePerRequest,
                address(etherFiNodesManager)
            );
            
            transactions[batchIdx] = ConsolidationTx({
                to: to,
                value: value,
                data: data,
                batchIndex: batchIdx,
                validatorCount: batchPubkeys.length
            });
        }
    }
    
    function _convertToGnosisTransactions(ConsolidationTx[] memory transactions)
        internal
        pure
        returns (GnosisTxGeneratorLib.Transaction[] memory gnosisTxns)
    {
        gnosisTxns = new GnosisTxGeneratorLib.Transaction[](transactions.length);
        for (uint256 i = 0; i < transactions.length; i++) {
            gnosisTxns[i] = GnosisTxGeneratorLib.Transaction({
                to: transactions[i].to,
                value: transactions[i].value,
                data: transactions[i].data
            });
        }
    }
    
    function _generateRawJsonOutput(ConsolidationTx[] memory transactions) internal pure returns (string memory) {
        string memory json = string.concat('{"transactions":[');
        
        for (uint256 i = 0; i < transactions.length; i++) {
            if (i > 0) {
                json = string.concat(json, ",");
            }
            
            json = string.concat(
                json,
                '{"batchIndex":',
                vm.toString(transactions[i].batchIndex),
                ',"to":"',
                vm.toString(transactions[i].to),
                '","value":"',
                vm.toString(transactions[i].value),
                '","validatorCount":',
                vm.toString(transactions[i].validatorCount),
                ',"data":"',
                StringHelpers.bytesToHexString(transactions[i].data),
                '"}'
            );
        }
        
        json = string.concat(json, "]}");
        return json;
    }
}
