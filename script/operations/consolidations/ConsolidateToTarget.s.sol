// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../../utils/utils.sol";
import "../../utils/GnosisTxGeneratorLib.sol";
import "../../utils/StringHelpers.sol";
import "../../utils/ValidatorHelpers.sol";
import "../../../src/EtherFiNodesManager.sol";
import "../../../src/eigenlayer-interfaces/IEigenPod.sol";
import "./GnosisConsolidationLib.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "../../../src/EtherFiTimelock.sol";

/**
 * @title ConsolidateToTarget
 * @notice Generates transactions to consolidate multiple validators to target validators
 * @dev Reads consolidation-data.json and processes all targets in a single run.
 *      Automatically detects unlinked validators and generates linking transactions via timelock.
 * 
 * Usage:
 *   CONSOLIDATION_DATA_FILE=consolidation-data.json SAFE_NONCE=42 forge script \
 *     script/operations/consolidations/ConsolidateToTarget.s.sol:ConsolidateToTarget \
 *     --fork-url $MAINNET_RPC_URL -vvvv
 * 
 * Environment Variables:
 *   - CONSOLIDATION_DATA_FILE: Path to consolidation-data.json (required)
 *   - OUTPUT_DIR: Output directory for generated files (default: same as CONSOLIDATION_DATA_FILE)
 *   - BATCH_SIZE: Number of validators per transaction (default: 50)
 *   - OUTPUT_FORMAT: "gnosis" or "raw" (default: gnosis)
 *   - SAFE_ADDRESS: Gnosis Safe address (default: ETHERFI_OPERATING_ADMIN)
 *   - CHAIN_ID: Chain ID for transaction (default: 1)
 *   - SAFE_NONCE: Starting nonce for Safe tx hash computation (default: 0)
 *
 * Output Files:
 *   - consolidation-txns.json: All consolidation transactions combined
 *   - link-schedule.json: Timelock schedule transaction (if linking needed)
 *   - link-execute.json: Timelock execute transaction (if linking needed)
 */
contract ConsolidateToTarget is Script, Utils {
    using StringHelpers for uint256;
    using StringHelpers for address;
    using StringHelpers for bytes;
    
    // === MAINNET CONTRACT ADDRESSES ===
    EtherFiNodesManager constant nodesManager = EtherFiNodesManager(ETHERFI_NODES_MANAGER);
    EtherFiTimelock constant etherFiTimelock = EtherFiTimelock(payable(OPERATING_TIMELOCK));
    
    // Selector for EtherFiNodesManager.linkLegacyValidatorIds(uint256[],bytes[])
    bytes4 constant LINK_LEGACY_VALIDATOR_IDS_SELECTOR = bytes4(keccak256("linkLegacyValidatorIds(uint256[],bytes[])"));
    
    // Default parameters
    uint256 constant DEFAULT_BATCH_SIZE = 50;
    uint256 constant DEFAULT_CHAIN_ID = 1;
    string constant DEFAULT_OUTPUT_FORMAT = "gnosis";
    
    // Config struct to avoid stack too deep
    struct Config {
        string outputDir;
        uint256 batchSize;
        string outputFormat;
        uint256 chainId;
        address safeAddress;
        string root;
        uint256 safeNonce;
        uint256 currentNonce;
    }

    // Struct for target validator in consolidation-data.json
    struct JsonTarget {
        bytes pubkey;
        uint256 validator_index;
        uint256 id;
        uint256 current_balance_eth;
        bytes withdrawal_credentials;
    }

    // Struct for source validator in consolidation-data.json
    struct JsonSource {
        bytes pubkey;
        uint256 validator_index;
        uint256 id;
        uint256 balance_eth;
        bytes withdrawal_credentials;
    }

    // Storage for unlinked validators across all targets
    uint256[] internal allUnlinkedIds;
    bytes[] internal allUnlinkedPubkeys;
    
    // Storage for all consolidation transactions
    GnosisTxGeneratorLib.GnosisTx[] internal allConsolidationTxs;
    
    function run() external {
        console2.log("=== CONSOLIDATE TO TARGET TRANSACTION GENERATOR ===");
        console2.log("");
        
        // Load config
        Config memory config = _loadConfig();
        
        // Read consolidation data file
        string memory consolidationDataFile = vm.envString("CONSOLIDATION_DATA_FILE");
        string memory jsonFilePath = _resolvePath(config.root, consolidationDataFile);
        string memory jsonData = vm.readFile(jsonFilePath);
        
        console2.log("Consolidation data file:", consolidationDataFile);
        console2.log("Batch size:", config.batchSize);
        console2.log("Safe nonce:", config.safeNonce);
        console2.log("");
        
        // Set output directory (default: same directory as consolidation data file)
        string memory outputDir = vm.envOr("OUTPUT_DIR", string(""));
        if (bytes(outputDir).length == 0) {
            // Extract directory from consolidation data file path
            outputDir = _getDirectory(jsonFilePath);
        }
        config.outputDir = outputDir;
        
        // Get number of consolidations
        uint256 numConsolidations = _countConsolidations(jsonData);
        console2.log("Number of consolidation targets:", numConsolidations);
        console2.log("");
        
        if (numConsolidations == 0) {
            console2.log("No consolidations to process");
            return;
        }
        
        // Process each consolidation target
        for (uint256 i = 0; i < numConsolidations; i++) {
            _processConsolidation(jsonData, i, config);
        }
        
        // Handle linking if any validators need it
        bool needsLinking = allUnlinkedIds.length > 0;
        if (needsLinking) {
            console2.log("");
            console2.log("=== GENERATING LINKING TRANSACTIONS ===");
            console2.log("Total unlinked validators:", allUnlinkedIds.length);
            _generateLinkingTransactions(config);
        }
        
        // Write all consolidation transactions to a single file
        _writeConsolidationFile(config, needsLinking);
        
        // Summary
        console2.log("");
        console2.log("=== CONSOLIDATION COMPLETE ===");
        console2.log("Total consolidation targets:", numConsolidations);
        console2.log("Total consolidation transactions:", allConsolidationTxs.length);
        if (needsLinking) {
            console2.log("Link transactions included: YES");
            console2.log("  Schedule nonce:", config.safeNonce);
            console2.log("  Execute nonce:", config.safeNonce + 1);
            console2.log("  Consolidation nonce:", config.safeNonce + 2);
        } else {
            console2.log("  Consolidation nonce:", config.safeNonce);
        }
    }
    
    function _processConsolidation(string memory jsonData, uint256 index, Config memory config) internal {
        console2.log("================================================================================================================");
        console2.log("Processing consolidation target", index + 1);
        
        // Parse target
        string memory targetPath = string.concat("$.consolidations[", index.uint256ToString(), "].target");
        bytes memory targetPubkey = stdJson.readBytes(jsonData, string.concat(targetPath, ".pubkey"));
        uint256 targetValidatorId = stdJson.readUint(jsonData, string.concat(targetPath, ".id"));
        
        console2.log("  Target pubkey:", targetPubkey.bytesToHexString());
        console2.log("  Target validator ID:", targetValidatorId);
        
        // Parse sources
        uint256 numSources = _countSources(jsonData, index);
        console2.log("  Number of sources:", numSources);
        
        bytes[] memory sourcePubkeys = new bytes[](numSources);
        uint256[] memory sourceIds = new uint256[](numSources);
        
        for (uint256 i = 0; i < numSources; i++) {
            string memory sourcePath = string.concat("$.consolidations[", index.uint256ToString(), "].sources[", i.uint256ToString(), "]");
            sourcePubkeys[i] = stdJson.readBytes(jsonData, string.concat(sourcePath, ".pubkey"));
            sourceIds[i] = stdJson.readUint(jsonData, string.concat(sourcePath, ".id"));
        }
        
        // Collect unlinked validators
        _collectUnlinkedValidators(targetPubkey, targetValidatorId, sourcePubkeys, sourceIds, config.batchSize);
        
        // Get fee using target pubkey
        // Note: We need to get the fee after simulating linking on fork (done in _generateLinkingTransactions)
        // For now, we'll use a placeholder and update later
        uint256 feePerRequest = _getConsolidationFeeSafe(targetPubkey);
        
        // Generate consolidation transactions for this target
        _generateConsolidationTxs(sourcePubkeys, targetPubkey, feePerRequest, config.batchSize);
    }
    
    function _loadConfig() internal view returns (Config memory config) {
        config.batchSize = vm.envOr("BATCH_SIZE", DEFAULT_BATCH_SIZE);
        config.outputFormat = vm.envOr("OUTPUT_FORMAT", string(DEFAULT_OUTPUT_FORMAT));
        config.chainId = vm.envOr("CHAIN_ID", DEFAULT_CHAIN_ID);
        config.safeAddress = vm.envOr("SAFE_ADDRESS", ETHERFI_OPERATING_ADMIN);
        config.root = vm.projectRoot();
        config.safeNonce = vm.envOr("SAFE_NONCE", uint256(0));
        config.currentNonce = config.safeNonce;
    }
    
    function _countConsolidations(string memory jsonData) internal view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < 1000; i++) {
            string memory path = string.concat("$.consolidations[", i.uint256ToString(), "].target.pubkey");
            if (!stdJson.keyExists(jsonData, path)) {
                break;
            }
            count++;
        }
        return count;
    }
    
    function _countSources(string memory jsonData, uint256 consolidationIndex) internal view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < 10000; i++) {
            string memory path = string.concat(
                "$.consolidations[", consolidationIndex.uint256ToString(), "].sources[", i.uint256ToString(), "].pubkey"
            );
            if (!stdJson.keyExists(jsonData, path)) {
                break;
            }
            count++;
        }
        return count;
    }
    
    function _getConsolidationFeeSafe(bytes memory targetPubkey) internal view returns (uint256) {
        // Try to get fee, return default if target not linked yet
        bytes32 pubkeyHash = nodesManager.calculateValidatorPubkeyHash(targetPubkey);
        address nodeAddr = address(nodesManager.etherFiNodeFromPubkeyHash(pubkeyHash));
        
        if (nodeAddr == address(0)) {
            // Not linked yet, return estimate (will be accurate after linking simulation)
            return 1; // 1 wei minimum, actual fee will be calculated after linking
        }
        
        IEtherFiNode node = IEtherFiNode(nodeAddr);
        IEigenPod pod = node.getEigenPod();
        return pod.getConsolidationRequestFee();
    }
    
    function _isPubkeyLinked(bytes memory pubkey) internal view returns (bool) {
        bytes32 pubkeyHash = nodesManager.calculateValidatorPubkeyHash(pubkey);
        address nodeAddr = address(nodesManager.etherFiNodeFromPubkeyHash(pubkeyHash));
        return nodeAddr != address(0);
    }
    
    function _collectUnlinkedValidators(
        bytes memory targetPubkey,
        uint256 targetValidatorId,
        bytes[] memory sourcePubkeys,
        uint256[] memory sourceIds,
        uint256 batchSize
    ) internal {
        // Check target
        if (!_isPubkeyLinked(targetPubkey)) {
            _addUnlinkedIfNew(targetValidatorId, targetPubkey);
            console2.log("  Target needs linking");
        }
        
        // Check first pubkey of each batch
        uint256 numBatches = (sourcePubkeys.length + batchSize - 1) / batchSize;
        
        for (uint256 batchIdx = 0; batchIdx < numBatches; batchIdx++) {
            uint256 firstPubkeyIdx = batchIdx * batchSize;
            if (!_isPubkeyLinked(sourcePubkeys[firstPubkeyIdx])) {
                _addUnlinkedIfNew(sourceIds[firstPubkeyIdx], sourcePubkeys[firstPubkeyIdx]);
                console2.log("  Batch", batchIdx + 1, "head needs linking");
            }
        }
    }
    
    function _addUnlinkedIfNew(uint256 id, bytes memory pubkey) internal {
        // Check if already added
        for (uint256 i = 0; i < allUnlinkedIds.length; i++) {
            if (allUnlinkedIds[i] == id) {
                return; // Already added
            }
        }
        allUnlinkedIds.push(id);
        allUnlinkedPubkeys.push(pubkey);
    }
    
    function _generateLinkingTransactions(Config memory config) internal {
        // Build timelock calldata
        (bytes memory scheduleCalldata, bytes memory executeCalldata) = _buildTimelockCalldata();
        
        // Write schedule transaction
        _writeLinkingTx(config, scheduleCalldata, "link-schedule");
        
        // Write execute transaction
        _writeLinkingTx(config, executeCalldata, "link-execute");
    }
    
    function _writeLinkingTx(
        Config memory config,
        bytes memory callData,
        string memory txType
    ) internal {
        GnosisTxGeneratorLib.GnosisTx[] memory txns = new GnosisTxGeneratorLib.GnosisTx[](1);
        txns[0] = GnosisTxGeneratorLib.GnosisTx({
            to: OPERATING_TIMELOCK,
            value: 0,
            data: callData
        });
        
        string memory jsonContent = GnosisTxGeneratorLib.generateTransactionBatch(
            txns,
            config.chainId,
            config.safeAddress
        );
        
        string memory fileName = string.concat(txType, ".json");
        string memory filePath = string.concat(config.outputDir, "/", fileName);
        
        vm.writeFile(filePath, jsonContent);
        console2.log("Transaction written to:", filePath);
    }
    
    function _buildTimelockCalldata() internal returns (bytes memory scheduleCalldata, bytes memory executeCalldata) {
        // Build linkLegacyValidatorIds calldata
        bytes memory linkCalldata = abi.encodeWithSelector(
            LINK_LEGACY_VALIDATOR_IDS_SELECTOR,
            allUnlinkedIds,
            allUnlinkedPubkeys
        );
        
        // Build batch targets
        address[] memory targets = new address[](1);
        targets[0] = ETHERFI_NODES_MANAGER;
        
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = linkCalldata;
        
        bytes32 salt = keccak256(abi.encode(allUnlinkedIds, allUnlinkedPubkeys, "link-legacy-validators-consolidation"));
        
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

        // Simulate on fork so subsequent operations work
        vm.prank(address(ETHERFI_OPERATING_ADMIN));
        etherFiTimelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, MIN_DELAY_OPERATING_TIMELOCK);
        vm.warp(block.timestamp + MIN_DELAY_OPERATING_TIMELOCK + 1);
        vm.prank(address(ETHERFI_OPERATING_ADMIN));
        etherFiTimelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        
        console2.log("Linking simulated on fork successfully");
    }
    
    function _generateConsolidationTxs(
        bytes[] memory sourcePubkeys,
        bytes memory targetPubkey,
        uint256 feePerRequest,
        uint256 batchSize
    ) internal {
        uint256 numBatches = (sourcePubkeys.length + batchSize - 1) / batchSize;
        
        for (uint256 batchIdx = 0; batchIdx < numBatches; batchIdx++) {
            uint256 startIdx = batchIdx * batchSize;
            uint256 endIdx = startIdx + batchSize;
            if (endIdx > sourcePubkeys.length) {
                endIdx = sourcePubkeys.length;
            }
            
            // Extract batch
            bytes[] memory batchPubkeys = new bytes[](endIdx - startIdx);
            for (uint256 i = 0; i < batchPubkeys.length; i++) {
                batchPubkeys[i] = sourcePubkeys[startIdx + i];
            }
            
            // Generate transaction
            (address to, uint256 value, bytes memory data) = 
                GnosisConsolidationLib.generateConsolidationTransactionToTarget(
                    batchPubkeys,
                    targetPubkey,
                    feePerRequest,
                    address(nodesManager)
                );
            
            // Add to storage
            allConsolidationTxs.push(GnosisTxGeneratorLib.GnosisTx({
                to: to,
                value: value,
                data: data
            }));
        }
    }
    
    function _writeConsolidationFile(Config memory config, bool /* needsLinking */) internal {
        // Write each consolidation transaction to a separate file
        for (uint256 i = 0; i < allConsolidationTxs.length; i++) {
            GnosisTxGeneratorLib.GnosisTx[] memory txns = new GnosisTxGeneratorLib.GnosisTx[](1);
            txns[0] = allConsolidationTxs[i];
            
            string memory jsonContent = GnosisTxGeneratorLib.generateTransactionBatch(
                txns,
                config.chainId,
                config.safeAddress
            );
            
            string memory fileName = string.concat("consolidation-txns-", (i + 1).uint256ToString(), ".json");
            string memory filePath = string.concat(config.outputDir, "/", fileName);
            
            vm.writeFile(filePath, jsonContent);
            console2.log("Transaction written to:", filePath);
        }
        console2.log("  Total transactions:", allConsolidationTxs.length);
    }
    
    function _resolvePath(string memory root, string memory path) internal pure returns (string memory) {
        // If path starts with /, it's already absolute
        if (bytes(path).length > 0 && bytes(path)[0] == '/') {
            return path;
        }
        // Otherwise, prepend root
        return string.concat(root, "/", path);
    }
    
    function _getDirectory(string memory filePath) internal pure returns (string memory) {
        bytes memory pathBytes = bytes(filePath);
        uint256 lastSlash = 0;
        
        for (uint256 i = 0; i < pathBytes.length; i++) {
            if (pathBytes[i] == '/') {
                lastSlash = i;
            }
        }
        
        if (lastSlash == 0) {
            return ".";
        }
        
        bytes memory dirBytes = new bytes(lastSlash);
        for (uint256 i = 0; i < lastSlash; i++) {
            dirBytes[i] = pathBytes[i];
        }
        
        return string(dirBytes);
    }
}
