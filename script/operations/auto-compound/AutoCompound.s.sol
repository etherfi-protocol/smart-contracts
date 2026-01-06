// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../../utils/utils.sol";
import "../../utils/GnosisTxGeneratorLib.sol";
import "../../utils/StringHelpers.sol";
import "../../utils/ValidatorHelpers.sol";
import "../../utils/SafeTxHashLib.sol";
import "../../../src/interfaces/IEtherFiNodesManager.sol";
import "../../../src/interfaces/IEtherFiNode.sol";
import "../../../src/eigenlayer-interfaces/IEigenPod.sol";
import "../consolidations/GnosisConsolidationLib.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title AutoCompound
 * @notice Generates auto-compounding (0x02) consolidation transactions with automatic linking detection
 * @dev Automatically detects unlinked validators and generates linking transactions via timelock
 * 
 * Usage:
 *   JSON_FILE=validators.json SAFE_NONCE=42 forge script \
 *     script/operations/auto-compound/AutoCompound.s.sol:AutoCompound \
 *     --fork-url $MAINNET_RPC_URL -vvvv
 * 
 * Environment Variables:
 *   - JSON_FILE: Path to JSON file with validator data (required)
 *   - OUTPUT_FILE: Output filename (default: auto-compound-txns.json)
 *   - BATCH_SIZE: Number of validators per transaction (default: 50)
 *   - OUTPUT_FORMAT: "gnosis" or "raw" (default: gnosis)
 *   - SAFE_ADDRESS: Gnosis Safe address (default: ETHERFI_OPERATING_ADMIN)
 *   - CHAIN_ID: Chain ID for transaction (default: 1)
 *   - SAFE_NONCE: Starting nonce for Safe tx hash computation (default: 0)
 * 
 * Output Files (when linking is needed):
 *   - *-link-schedule.json: Timelock schedule transaction (nonce N)
 *   - *-link-execute.json: Timelock execute transaction (nonce N+1)
 *   - *-consolidation.json: Consolidation transaction (nonce N+2)
 * 
 * The script outputs EIP-712 signing data (Domain Separator, SafeTx Hash, Message Hash)
 * for each generated transaction file when SAFE_NONCE is provided.
 */
contract AutoCompound is Script, Utils {
    using StringHelpers for uint256;
    using StringHelpers for address;
    using StringHelpers for bytes;
    using StringHelpers for bytes32;
    
    // === MAINNET CONTRACT ADDRESSES ===
    IEtherFiNodesManager constant nodesManager = IEtherFiNodesManager(ETHERFI_NODES_MANAGER);
    
    // Note: MIN_DELAY_OPERATING_TIMELOCK is inherited from Utils (via TimelockUtils)
    
    // Default parameters
    string constant DEFAULT_OUTPUT_FILE = "auto-compound-txns.json";
    uint256 constant DEFAULT_BATCH_SIZE = 50;
    uint256 constant DEFAULT_CHAIN_ID = 1;
    string constant DEFAULT_OUTPUT_FORMAT = "gnosis";
    
    // Configuration struct to reduce stack depth
    struct Config {
        string jsonFile;
        string outputFile;
        uint256 batchSize;
        string outputFormat;
        uint256 chainId;
        address safeAddress;
        string root;
        uint256 safeNonce;  // Starting nonce for Safe transaction hash computation
    }
    
    struct ConsolidationTx {
        address to;
        uint256 value;
        bytes data;
        uint256 validatorCount;
    }
    
    function run() external {
        console2.log("=== AUTO-COMPOUND TRANSACTION GENERATOR ===");
        console2.log("");
        
        // Load configuration
        Config memory config = _loadConfig();
        
        // Read and parse validators
        string memory jsonFilePath = _resolvePath(config.root, config.jsonFile);
        string memory jsonData = vm.readFile(jsonFilePath);
        
        (bytes[] memory pubkeys, uint256[] memory ids, address targetEigenPod, uint256 validatorCount) = 
            ValidatorHelpers.parseValidatorsFromJson(jsonData, 10000);
        
        console2.log("Found", validatorCount, "validators");
        console2.log("EigenPod from withdrawal credentials:", targetEigenPod);
        
        if (pubkeys.length == 0) {
            console2.log("No validators to process");
            return;
        }
        
        // Process validators
        _processValidators(pubkeys, ids, targetEigenPod, config);
    }
    
    function _loadConfig() internal view returns (Config memory config) {
        config.jsonFile = vm.envString("JSON_FILE");
        config.outputFile = vm.envOr("OUTPUT_FILE", string(DEFAULT_OUTPUT_FILE));
        config.batchSize = vm.envOr("BATCH_SIZE", DEFAULT_BATCH_SIZE);
        config.outputFormat = vm.envOr("OUTPUT_FORMAT", string(DEFAULT_OUTPUT_FORMAT));
        config.chainId = vm.envOr("CHAIN_ID", DEFAULT_CHAIN_ID);
        config.safeAddress = vm.envOr("SAFE_ADDRESS", ETHERFI_OPERATING_ADMIN);
        config.root = vm.projectRoot();
        config.safeNonce = vm.envOr("SAFE_NONCE", uint256(0));
        
        console2.log("JSON file:", config.jsonFile);
        console2.log("Output file:", config.outputFile);
        console2.log("Batch size:", config.batchSize);
        console2.log("Output format:", config.outputFormat);
        console2.log("Safe nonce:", config.safeNonce);
        console2.log("");
    }
    
    function _processValidators(
        bytes[] memory pubkeys,
        uint256[] memory ids,
        address targetEigenPod,
        Config memory config
    ) internal {
        // Check linking status
        (
            uint256[] memory unlinkedIds,
            bytes[] memory unlinkedPubkeys,
            uint256 linkedCount
        ) = _checkLinkingStatus(pubkeys, ids);
        
        console2.log("Linked validators:", linkedCount);
        console2.log("Unlinked validators:", unlinkedIds.length);
        console2.log("");
        
        // Get consolidation fee (handles case when no validators are linked)
        uint256 feePerRequest = _getConsolidationFee(pubkeys, targetEigenPod);
        console2.log("Fee per consolidation request:", feePerRequest);
        console2.log("");
        
        // Generate linking transactions if needed
        bool needsLinking = unlinkedIds.length > 0;
        
        if (needsLinking) {
            console2.log("=== GENERATING LINKING TRANSACTIONS ===");
            _generateLinkingTransactions(unlinkedIds, unlinkedPubkeys, config);
        }
        
        // Generate consolidation transactions
        console2.log("");
        console2.log("=== GENERATING CONSOLIDATION TRANSACTIONS ===");
        _generateAndWriteConsolidation(pubkeys, feePerRequest, config, needsLinking);
        
        // Print summary
        _printSummary(pubkeys.length, linkedCount, unlinkedIds.length, needsLinking, config);
    }
    
    function _checkLinkingStatus(
        bytes[] memory pubkeys,
        uint256[] memory ids
    ) internal view returns (
        uint256[] memory unlinkedIds,
        bytes[] memory unlinkedPubkeys,
        uint256 linkedCount
    ) {
        uint256 unlinkedCount = 0;
        
        // First pass: count unlinked
        for (uint256 i = 0; i < pubkeys.length; i++) {
            if (!_isLinked(pubkeys[i])) {
                unlinkedCount++;
            }
        }
        
        linkedCount = pubkeys.length - unlinkedCount;
        
        // Allocate arrays
        unlinkedIds = new uint256[](unlinkedCount);
        unlinkedPubkeys = new bytes[](unlinkedCount);
        
        // Second pass: populate arrays
        uint256 idx = 0;
        for (uint256 i = 0; i < pubkeys.length; i++) {
            if (!_isLinked(pubkeys[i])) {
                unlinkedIds[idx] = ids[i];
                unlinkedPubkeys[idx] = pubkeys[i];
                idx++;
            }
        }
    }
    
    function _isLinked(bytes memory pubkey) internal view returns (bool) {
        bytes32 pkHash = nodesManager.calculateValidatorPubkeyHash(pubkey);
        IEtherFiNode node = nodesManager.etherFiNodeFromPubkeyHash(pkHash);
        return address(node) != address(0);
    }
    
    function _getConsolidationFee(bytes[] memory pubkeys, address targetEigenPod) internal view returns (uint256) {
        // Try to find a linked validator to resolve pod
        for (uint256 i = 0; i < pubkeys.length; i++) {
            if (_isLinked(pubkeys[i])) {
                (, IEigenPod pod) = ValidatorHelpers.resolvePod(nodesManager, pubkeys[i]);
                return pod.getConsolidationRequestFee();
            }
        }
        
        // If no linked validators, use the targetEigenPod from withdrawal credentials
        console2.log("No linked validators found. Using EigenPod from withdrawal credentials.");
        IEigenPod pod = IEigenPod(targetEigenPod);
        require(address(pod) != address(0), "Cannot resolve EigenPod");
        return pod.getConsolidationRequestFee();
    }
    
    function _generateLinkingTransactions(
        uint256[] memory unlinkedIds,
        bytes[] memory unlinkedPubkeys,
        Config memory config
    ) internal {
        // Build timelock calldata
        (bytes memory scheduleCalldata, bytes memory executeCalldata) = 
            _buildTimelockCalldata(unlinkedIds, unlinkedPubkeys);
        
        // Create schedule transaction
        GnosisTxGeneratorLib.GnosisTx[] memory scheduleTxns = new GnosisTxGeneratorLib.GnosisTx[](1);
        scheduleTxns[0] = GnosisTxGeneratorLib.GnosisTx({
            to: OPERATING_TIMELOCK,
            value: 0,
            data: scheduleCalldata
        });
        
        // Create execute transaction
        GnosisTxGeneratorLib.GnosisTx[] memory executeTxns = new GnosisTxGeneratorLib.GnosisTx[](1);
        executeTxns[0] = GnosisTxGeneratorLib.GnosisTx({
            to: OPERATING_TIMELOCK,
            value: 0,
            data: executeCalldata
        });
        
        // Generate JSON
        string memory scheduleJson = GnosisTxGeneratorLib.generateTransactionBatch(
            scheduleTxns,
            config.chainId,
            config.safeAddress
        );
        
        string memory executeJson = GnosisTxGeneratorLib.generateTransactionBatch(
            executeTxns,
            config.chainId,
            config.safeAddress
        );
        
        // Write files
        string memory baseName = _removeExtension(config.outputFile);
        string memory schedulePath = string.concat(
            config.root, "/script/operations/auto-compound/", baseName, "-link-schedule.json"
        );
        string memory executePath = string.concat(
            config.root, "/script/operations/auto-compound/", baseName, "-link-execute.json"
        );
        
        vm.writeFile(schedulePath, scheduleJson);
        vm.writeFile(executePath, executeJson);
        
        console2.log("Linking schedule transaction written to:", schedulePath);
        console2.log("Linking execute transaction written to:", executePath);
        
        // Output EIP-712 signing data for schedule (nonce N)
        _outputSigningData(
            config.chainId,
            config.safeAddress,
            scheduleTxns[0].to,
            scheduleTxns[0].value,
            scheduleTxns[0].data,
            config.safeNonce,
            "link-schedule.json"
        );
        
        // Output EIP-712 signing data for execute (nonce N+1)
        _outputSigningData(
            config.chainId,
            config.safeAddress,
            executeTxns[0].to,
            executeTxns[0].value,
            executeTxns[0].data,
            config.safeNonce + 1,
            "link-execute.json"
        );
    }
    
    // Selector for EtherFiNodesManager.linkLegacyValidatorIds(uint256[],bytes[])
    bytes4 constant LINK_LEGACY_VALIDATOR_IDS_SELECTOR = bytes4(keccak256("linkLegacyValidatorIds(uint256[],bytes[])"));
    
    function _buildTimelockCalldata(
        uint256[] memory unlinkedIds,
        bytes[] memory unlinkedPubkeys
    ) internal view returns (bytes memory scheduleCalldata, bytes memory executeCalldata) {
        // Build linkLegacyValidatorIds calldata
        bytes memory linkCalldata = abi.encodeWithSelector(
            LINK_LEGACY_VALIDATOR_IDS_SELECTOR,
            unlinkedIds,
            unlinkedPubkeys
        );
        
        // Build batch targets
        address[] memory targets = new address[](1);
        targets[0] = ETHERFI_NODES_MANAGER;
        
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = linkCalldata;
        
        bytes32 salt = keccak256(abi.encode(unlinkedIds, unlinkedPubkeys, "link-legacy-validators"));
        
        // Build schedule calldata
        scheduleCalldata = abi.encodeWithSelector(
            TimelockController.scheduleBatch.selector,
            targets,
            values,
            payloads,
            bytes32(0), // predecessor
            salt,
            MIN_DELAY_OPERATING_TIMELOCK
        );
        
        // Build execute calldata
        executeCalldata = abi.encodeWithSelector(
            TimelockController.executeBatch.selector,
            targets,
            values,
            payloads,
            bytes32(0), // predecessor
            salt
        );
    }
    
    function _generateAndWriteConsolidation(
        bytes[] memory pubkeys,
        uint256 feePerRequest,
        Config memory config,
        bool needsLinking
    ) internal {
        // Generate consolidation transactions
        uint256 numBatches = (pubkeys.length + config.batchSize - 1) / config.batchSize;
        ConsolidationTx[] memory transactions = new ConsolidationTx[](numBatches);
        
        for (uint256 batchIdx = 0; batchIdx < numBatches; batchIdx++) {
            uint256 startIdx = batchIdx * config.batchSize;
            uint256 endIdx = startIdx + config.batchSize;
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
                GnosisConsolidationLib.generateConsolidationTransaction(
                    batchPubkeys,
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
        
        // Write output
        _writeConsolidationOutput(transactions, config, needsLinking);
    }
    
    function _writeConsolidationOutput(
        ConsolidationTx[] memory transactions,
        Config memory config,
        bool needsLinking
    ) internal {
        // Determine output filename
        string memory baseName = _removeExtension(config.outputFile);
        string memory outputFileName;
        
        if (needsLinking) {
            outputFileName = string.concat(baseName, "-consolidation.json");
        } else {
            outputFileName = config.outputFile;
        }
        
        string memory outputPath = string.concat(
            config.root, "/script/operations/auto-compound/", outputFileName
        );
        
        // Generate JSON
        string memory jsonOutput;
        GnosisTxGeneratorLib.GnosisTx[] memory gnosisTxns;
        
        if (keccak256(bytes(config.outputFormat)) == keccak256(bytes("gnosis"))) {
            gnosisTxns = new GnosisTxGeneratorLib.GnosisTx[](transactions.length);
            for (uint256 i = 0; i < transactions.length; i++) {
                gnosisTxns[i] = GnosisTxGeneratorLib.GnosisTx({
                    to: transactions[i].to,
                    value: transactions[i].value,
                    data: transactions[i].data
                });
            }
            jsonOutput = GnosisTxGeneratorLib.generateTransactionBatch(
                gnosisTxns,
                config.chainId,
                config.safeAddress
            );
        } else {
            jsonOutput = _generateRawJson(transactions);
        }
        
        vm.writeFile(outputPath, jsonOutput);
        console2.log("Consolidation transactions written to:", outputPath);
        
        // Output EIP-712 signing data for consolidation
        // Nonce is N+2 if linking was needed (schedule=N, execute=N+1), else N
        uint256 consolidationNonce = needsLinking ? config.safeNonce + 2 : config.safeNonce;
        
        // For multiple transactions, they would be wrapped in MultiSend
        // For simplicity, output signing data for each transaction
        if (transactions.length == 1) {
            _outputSigningData(
                config.chainId,
                config.safeAddress,
                transactions[0].to,
                transactions[0].value,
                transactions[0].data,
                consolidationNonce,
                outputFileName
            );
        } else {
            // Multiple batches - output for each (nonce increments)
            for (uint256 i = 0; i < transactions.length; i++) {
                string memory txName = string.concat("consolidation-batch-", (i + 1).uint256ToString(), ".json");
                _outputSigningData(
                    config.chainId,
                    config.safeAddress,
                    transactions[i].to,
                    transactions[i].value,
                    transactions[i].data,
                    consolidationNonce + i,
                    txName
                );
            }
        }
    }
    
    function _outputSigningData(
        uint256 chainId,
        address safeAddress,
        address to,
        uint256 value,
        bytes memory data,
        uint256 nonce,
        string memory txName
    ) internal view {
        (bytes32 domainSeparator, bytes32 safeTxHash, bytes32 messageHash) = 
            SafeTxHashLib.computeSigningData(chainId, safeAddress, to, value, data, nonce);
        
        console2.log("");
        console2.log("=== EIP-712 SIGNING DATA:", txName, "===");
        console2.log("Nonce:", nonce);
        console2.log("Domain Separator:", domainSeparator.bytes32ToHexString());
        console2.log("SafeTx Hash:", safeTxHash.bytes32ToHexString());
        console2.log("Message Hash (to sign):", messageHash.bytes32ToHexString());
    }
    
    function _printSummary(
        uint256 totalValidators,
        uint256 linkedCount,
        uint256 unlinkedCount,
        bool needsLinking,
        Config memory config
    ) internal view {
        console2.log("");
        console2.log("=== SUMMARY ===");
        console2.log("Total validators:", totalValidators);
        console2.log("Already linked:", linkedCount);
        console2.log("Need linking:", unlinkedCount);
        console2.log("");
        
        if (needsLinking) {
            console2.log("EXECUTION ORDER:");
            console2.log("1. Execute schedule transaction (link-schedule.json)");
            console2.log("2. Wait", MIN_DELAY_OPERATING_TIMELOCK / 3600, "hours for timelock delay");
            console2.log("3. Execute execute transaction (link-execute.json)");
            console2.log("4. Execute consolidation transaction (consolidation.json)");
        } else {
            console2.log("All validators are linked. Execute consolidation directly.");
        }
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
        if (bytes(path).length > 0 && bytes(path)[0] == '/') {
            return path;
        }
        return string.concat(root, "/script/operations/auto-compound/", path);
    }
    
    function _removeExtension(string memory filename) internal pure returns (string memory) {
        bytes memory b = bytes(filename);
        for (uint256 i = b.length; i > 0; i--) {
            if (b[i-1] == '.') {
                bytes memory result = new bytes(i-1);
                for (uint256 j = 0; j < i-1; j++) {
                    result[j] = b[j];
                }
                return string(result);
            }
        }
        return filename;
    }
}

