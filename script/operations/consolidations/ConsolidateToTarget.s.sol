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

/**
 * @title ConsolidateToTarget
 * @notice Generates transactions to consolidate multiple validators to target validators
 * @dev Reads consolidation-data.json and processes all targets in a single run.
 *      Automatically detects unlinked validators and generates direct linking transactions.
 *      Uses ADMIN_EOA for all transactions (no timelock).
 *
 * Usage (Simulation - generates JSON files):
 *   CONSOLIDATION_DATA_FILE=consolidation-data.json forge script \
 *     script/operations/consolidations/ConsolidateToTarget.s.sol:ConsolidateToTarget \
 *     --fork-url $MAINNET_RPC_URL -vvvv
 *
 * Usage (Mainnet broadcast):
 *   CONSOLIDATION_DATA_FILE=consolidation-data.json BROADCAST=true forge script \
 *     script/operations/consolidations/ConsolidateToTarget.s.sol:ConsolidateToTarget \
 *     --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv
 *
 * Environment Variables:
 *   - CONSOLIDATION_DATA_FILE: Path to consolidation-data.json (required)
 *   - OUTPUT_DIR: Output directory for generated files (default: same as CONSOLIDATION_DATA_FILE)
 *   - BATCH_SIZE: Number of validators per transaction (default: 50)
 *   - BROADCAST: Set to "true" to broadcast transactions on mainnet (default: false)
 *   - CHAIN_ID: Chain ID for transaction (default: 1)
 *
 * Output Files (simulation mode only):
 *   - link-validators.json: Direct linking transaction (if linking needed)
 *   - consolidation-txns-N.json: Consolidation transactions
 */
contract ConsolidateToTarget is Script, Utils {
    using StringHelpers for uint256;
    using StringHelpers for address;
    using StringHelpers for bytes;
    
    // === MAINNET CONTRACT ADDRESSES ===
    EtherFiNodesManager constant nodesManager = EtherFiNodesManager(ETHERFI_NODES_MANAGER);
    
    // Selector for EtherFiNodesManager.linkLegacyValidatorIds(uint256[],bytes[])
    bytes4 constant LINK_LEGACY_VALIDATOR_IDS_SELECTOR = bytes4(keccak256("linkLegacyValidatorIds(uint256[],bytes[])"));
    
    // Default parameters
    uint256 constant DEFAULT_BATCH_SIZE = 50;
    uint256 constant DEFAULT_CHAIN_ID = 1;
    uint256 constant GAS_WARNING_THRESHOLD = 12_000_000;
    
    // Config struct to avoid stack too deep
    struct Config {
        string outputDir;
        uint256 batchSize;
        uint256 chainId;
        address adminAddress;
        string root;
        bool broadcast;
        bool skipGasEstimate;
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

    // Selector for EtherFiNodesManager.queueETHWithdrawal(address,uint256)
    bytes4 constant QUEUE_ETH_WITHDRAWAL_SELECTOR = bytes4(keccak256("queueETHWithdrawal(address,uint256)"));

    // Storage for consolidation data (to process after linking)
    struct ConsolidationData {
        bytes targetPubkey;
        bytes[] sourcePubkeys;
        uint256 withdrawalAmountGwei;
    }
    ConsolidationData[] internal allConsolidations;


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
        console2.log("Admin address:", config.adminAddress);
        console2.log("Broadcast mode:", config.broadcast);
        console2.log("Skip gas estimate:", config.skipGasEstimate);
        console2.log("");

        // Set output directory (default: same directory as consolidation data file)
        string memory outputDir = vm.envOr("OUTPUT_DIR", string(""));
        if (bytes(outputDir).length == 0) {
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

        // =====================================================================
        // PHASE 1: Collect unlinked validators (no fee fetching yet)
        // =====================================================================
        console2.log("=== PHASE 1: Collecting unlinked validators ===");
        for (uint256 i = 0; i < numConsolidations; i++) {
            _collectConsolidationData(jsonData, i, config);
        }

        // =====================================================================
        // PHASE 2: Execute linking if needed (before fee fetching)
        // =====================================================================
        bool needsLinking = allUnlinkedIds.length > 0;
        if (needsLinking) {
            console2.log("");
            console2.log("=== PHASE 2: Linking validators ===");
            console2.log("Total unlinked validators:", allUnlinkedIds.length);
            _executeLinking(config);
        } else {
            console2.log("");
            console2.log("=== PHASE 2: No linking needed ===");
        }

        // =====================================================================
        // PHASE 3: Execute consolidations (fetch fee -> execute, one at a time)
        // =====================================================================
        console2.log("");
        console2.log("=== PHASE 3: Executing consolidations (fee fetched per tx) ===");
        _executeConsolidationsWithDynamicFee(config);

        // =====================================================================
        // PHASE 4: Queue ETH withdrawals (one per pod)
        // =====================================================================
        console2.log("");
        console2.log("=== PHASE 4: Queue ETH Withdrawals ===");
        _executeQueueETHWithdrawals(config);

        // Summary
        console2.log("");
        console2.log("=== CONSOLIDATION COMPLETE ===");
        console2.log("Total consolidation targets:", numConsolidations);
        if (config.broadcast) {
            console2.log("Mode: MAINNET BROADCAST");
            if (needsLinking) {
                console2.log("Linking transaction: BROADCAST");
            }
        } else {
            console2.log("Mode: SIMULATION (JSON files generated)");
            if (needsLinking) {
                console2.log("Link transaction: link-validators.json");
            }
            console2.log("Queue withdrawals: queue-withdrawals.json");
        }
        console2.log("Admin address:", config.adminAddress);
    }

    /// @notice Phase 1: Collect consolidation data and unlinked validators
    function _collectConsolidationData(string memory jsonData, uint256 index, Config memory config) internal {
        console2.log("Collecting data for consolidation target", index + 1);

        // Parse target
        string memory targetPath = string.concat("$.consolidations[", index.uint256ToString(), "].target");
        bytes memory targetPubkey = stdJson.readBytes(jsonData, string.concat(targetPath, ".pubkey"));
        uint256 targetValidatorId = stdJson.readUint(jsonData, string.concat(targetPath, ".id"));

        console2.log("  Target pubkey:", targetPubkey.bytesToHexString());

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

        // Read withdrawal amount (0 if not present, e.g. non-submarine consolidations)
        uint256 withdrawalAmountGwei = 0;
        string memory withdrawalPath = string.concat("$.consolidations[", index.uint256ToString(), "].withdrawal_amount_gwei");
        if (stdJson.keyExists(jsonData, withdrawalPath)) {
            withdrawalAmountGwei = stdJson.readUint(jsonData, withdrawalPath);
        }
        if (withdrawalAmountGwei > 0) {
            console2.log("  Withdrawal amount:", withdrawalAmountGwei, "gwei");
        }

        // Store consolidation data for Phase 3
        allConsolidations.push();
        uint256 idx = allConsolidations.length - 1;
        allConsolidations[idx].targetPubkey = targetPubkey;
        allConsolidations[idx].sourcePubkeys = sourcePubkeys;
        allConsolidations[idx].withdrawalAmountGwei = withdrawalAmountGwei;
    }

    // Counter for transaction numbering
    uint256 internal txCount;

    /// @notice Phase 3: Execute consolidations with dynamic fee fetching per transaction
    /// @dev Fee is fetched immediately before each transaction to account for non-linear fee changes
    function _executeConsolidationsWithDynamicFee(Config memory config) internal {
        txCount = 0;

        for (uint256 i = 0; i < allConsolidations.length; i++) {
            console2.log("Processing target", i + 1, "of", allConsolidations.length);
            _processConsolidationTarget(i, config);
        }

        console2.log("Total transactions executed/written:", txCount);
    }

    function _processConsolidationTarget(uint256 targetIdx, Config memory config) internal {
        ConsolidationData storage consolidation = allConsolidations[targetIdx];
        uint256 numSources = consolidation.sourcePubkeys.length;
        uint256 numBatches = (numSources + config.batchSize - 1) / config.batchSize;

        for (uint256 batchIdx = 0; batchIdx < numBatches; batchIdx++) {
            _processBatch(targetIdx, batchIdx, config);
        }
    }

    function _processBatch(uint256 targetIdx, uint256 batchIdx, Config memory config) internal {
        ConsolidationData storage consolidation = allConsolidations[targetIdx];
        uint256 startIdx = batchIdx * config.batchSize;
        uint256 endIdx = startIdx + config.batchSize;
        if (endIdx > consolidation.sourcePubkeys.length) {
            endIdx = consolidation.sourcePubkeys.length;
        }

        // Extract batch pubkeys
        bytes[] memory batchPubkeys = new bytes[](endIdx - startIdx);
        for (uint256 j = 0; j < batchPubkeys.length; j++) {
            batchPubkeys[j] = consolidation.sourcePubkeys[startIdx + j];
        }

        // Fetch fee RIGHT BEFORE this transaction (fee changes non-linearly)
        uint256 feePerRequest = _getConsolidationFee(consolidation.targetPubkey);
        console2.log("  Batch", batchIdx + 1, "- Fee:", feePerRequest);

        // Generate and execute/write transaction
        txCount++;
        _executeOrWriteTx(batchPubkeys, consolidation.targetPubkey, feePerRequest, config);
    }

    function _executeOrWriteTx(
        bytes[] memory batchPubkeys,
        bytes memory targetPubkey,
        uint256 feePerRequest,
        Config memory config
    ) internal {
        (address to, uint256 value, bytes memory data) =
            GnosisConsolidationLib.generateConsolidationTransactionToTarget(
                batchPubkeys,
                targetPubkey,
                feePerRequest,
                address(nodesManager)
            );

        if (config.broadcast) {
            if (!config.skipGasEstimate) {
                // Estimate gas before broadcasting
                vm.prank(config.adminAddress);
                uint256 gasBefore = gasleft();
                (bool simSuccess, ) = to.call{value: value}(data);
                uint256 gasEstimate = gasBefore - gasleft();
                require(simSuccess, "Consolidation gas estimation failed");

                console2.log("  Broadcasting tx", txCount, "- Estimated gas:", gasEstimate);
                if (gasEstimate > GAS_WARNING_THRESHOLD) {
                    console2.log("  *** WARNING: Gas exceeds 12M threshold! ***");
                    console2.log("  *** Consider reducing batch size ***");
                }
            } else {
                console2.log("  Broadcasting tx", txCount, "(gas estimation skipped)");
            }

            vm.startBroadcast();
            (bool success, ) = to.call{value: value}(data);
            require(success, "Consolidation transaction failed");
            vm.stopBroadcast();
        } else {
            _writeAndSimulateTx(to, value, data, config);
        }
    }

    function _writeAndSimulateTx(address to, uint256 value, bytes memory data, Config memory config) internal {
        GnosisTxGeneratorLib.GnosisTx[] memory txns = new GnosisTxGeneratorLib.GnosisTx[](1);
        txns[0] = GnosisTxGeneratorLib.GnosisTx({to: to, value: value, data: data});

        string memory jsonContent = GnosisTxGeneratorLib.generateTransactionBatch(
            txns,
            config.chainId,
            config.adminAddress
        );

        string memory fileName = string.concat("consolidation-txns-", txCount.uint256ToString(), ".json");
        string memory filePath = string.concat(config.outputDir, "/", fileName);
        vm.writeFile(filePath, jsonContent);
        console2.log("  Written:", fileName);

        // Simulate on fork to update fee state and estimate gas
        vm.prank(config.adminAddress);
        uint256 gasBefore = gasleft();
        (bool success, ) = to.call{value: value}(data);
        uint256 gasUsed = gasBefore - gasleft();
        require(success, "Consolidation simulation failed");

        console2.log("  Estimated gas:", gasUsed);
        if (gasUsed > GAS_WARNING_THRESHOLD) {
            console2.log("  *** WARNING: Gas exceeds 12M threshold! ***");
            console2.log("  *** Consider reducing batch size ***");
        }
    }
    
    /// @notice Phase 4: Generate/broadcast queueETHWithdrawal for each pod with a withdrawal amount
    /// @dev Bundles all queueETHWithdrawal calls into a single transaction for gas efficiency
    function _executeQueueETHWithdrawals(Config memory config) internal {
        // Collect withdrawals
        uint256 withdrawalCount = 0;
        for (uint256 i = 0; i < allConsolidations.length; i++) {
            if (allConsolidations[i].withdrawalAmountGwei > 0) {
                withdrawalCount++;
            }
        }

        if (withdrawalCount == 0) {
            console2.log("No ETH withdrawals to queue (no withdrawal_amount_gwei in consolidation data)");
            return;
        }

        console2.log("Pods with ETH withdrawals:", withdrawalCount);

        // Build an array of (nodeAddress, amountWei) for each pod
        GnosisTxGeneratorLib.GnosisTx[] memory withdrawalTxns = new GnosisTxGeneratorLib.GnosisTx[](withdrawalCount);
        uint256 txIdx = 0;

        for (uint256 i = 0; i < allConsolidations.length; i++) {
            ConsolidationData storage c = allConsolidations[i];
            if (c.withdrawalAmountGwei == 0) continue;

            // Resolve node address from target pubkey
            bytes32 pubkeyHash = nodesManager.calculateValidatorPubkeyHash(c.targetPubkey);
            address nodeAddr = address(nodesManager.etherFiNodeFromPubkeyHash(pubkeyHash));
            require(nodeAddr != address(0), "Target pubkey not linked - cannot resolve node for withdrawal");

            uint256 amountWei = c.withdrawalAmountGwei * 1 gwei;

            console2.log("  Pod", i + 1);
            console2.log("    Node:", nodeAddr);
            console2.log("    Amount (gwei):", c.withdrawalAmountGwei);

            bytes memory callData = abi.encodeWithSelector(
                QUEUE_ETH_WITHDRAWAL_SELECTOR,
                nodeAddr,
                amountWei
            );

            withdrawalTxns[txIdx] = GnosisTxGeneratorLib.GnosisTx({
                to: address(nodesManager),
                value: 0,
                data: callData
            });
            txIdx++;
        }

        if (config.broadcast) {
            console2.log("  Broadcasting queueETHWithdrawal transactions...");
            vm.startBroadcast();
            for (uint256 i = 0; i < withdrawalTxns.length; i++) {
                (bool success, ) = withdrawalTxns[i].to.call{value: withdrawalTxns[i].value}(withdrawalTxns[i].data);
                require(success, "queueETHWithdrawal transaction failed");
            }
            vm.stopBroadcast();
            console2.log("  All queueETHWithdrawal transactions broadcast successfully");
        } else {
            // Write all withdrawal calls into a single transaction file
            string memory jsonContent = GnosisTxGeneratorLib.generateTransactionBatch(
                withdrawalTxns,
                config.chainId,
                config.adminAddress
            );

            string memory postSweepDir = string.concat(config.outputDir, "/post-sweep");
            string memory filePath = string.concat(postSweepDir, "/queue-withdrawals.json");
            vm.writeFile(filePath, jsonContent);
            console2.log("  Written: queue-withdrawals.json");

            // Simulate on fork
            for (uint256 i = 0; i < withdrawalTxns.length; i++) {
                vm.prank(config.adminAddress);
                (bool success, ) = withdrawalTxns[i].to.call{value: withdrawalTxns[i].value}(withdrawalTxns[i].data);
                require(success, "queueETHWithdrawal simulation failed");
            }
            console2.log("  queueETHWithdrawal simulated on fork successfully");
        }
    }

    function _loadConfig() internal view returns (Config memory config) {
        config.batchSize = vm.envOr("BATCH_SIZE", DEFAULT_BATCH_SIZE);
        config.chainId = vm.envOr("CHAIN_ID", DEFAULT_CHAIN_ID);
        config.adminAddress = vm.envOr("ADMIN_ADDRESS", ADMIN_EOA);
        config.root = vm.projectRoot();
        config.broadcast = vm.envOr("BROADCAST", false);
        config.skipGasEstimate = vm.envOr("SKIP_GAS_ESTIMATE", false);
    }
    
    function _countConsolidations(string memory jsonData) internal view returns (uint256) {
        // Fast path: read pre-computed count from JSON (added by query_validators_consolidation.py)
        if (stdJson.keyExists(jsonData, "$.num_consolidations")) {
            return stdJson.readUint(jsonData, "$.num_consolidations");
        }
        // Fallback: iterate (slow for large files)
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
        // Fast path: read pre-computed count from JSON (added by query_validators_consolidation.py)
        string memory countPath = string.concat("$.consolidations[", consolidationIndex.uint256ToString(), "].source_count");
        if (stdJson.keyExists(jsonData, countPath)) {
            return stdJson.readUint(jsonData, countPath);
        }
        // Fallback: iterate (slow for large files)
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
    
    /// @notice Get consolidation fee from the EigenPod (must be called after linking)
    function _getConsolidationFee(bytes memory targetPubkey) internal view returns (uint256) {
        bytes32 pubkeyHash = nodesManager.calculateValidatorPubkeyHash(targetPubkey);
        address nodeAddr = address(nodesManager.etherFiNodeFromPubkeyHash(pubkeyHash));
        require(nodeAddr != address(0), "Target pubkey not linked");

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
    
    /// @notice Phase 2: Execute linking (broadcast or simulate)
    function _executeLinking(Config memory config) internal {
        if (config.broadcast) {
            // Broadcast mode: execute linking transaction on mainnet
            console2.log("Broadcasting linking transaction...");
            vm.startBroadcast();
            nodesManager.linkLegacyValidatorIds(allUnlinkedIds, allUnlinkedPubkeys);
            vm.stopBroadcast();
            console2.log("Linking transaction broadcast successfully");
        } else {
            // Simulation mode: generate JSON file and simulate on fork
            bytes memory linkCalldata = abi.encodeWithSelector(
                LINK_LEGACY_VALIDATOR_IDS_SELECTOR,
                allUnlinkedIds,
                allUnlinkedPubkeys
            );

            GnosisTxGeneratorLib.GnosisTx[] memory txns = new GnosisTxGeneratorLib.GnosisTx[](1);
            txns[0] = GnosisTxGeneratorLib.GnosisTx({
                to: ETHERFI_NODES_MANAGER,
                value: 0,
                data: linkCalldata
            });

            string memory jsonContent = GnosisTxGeneratorLib.generateTransactionBatch(
                txns,
                config.chainId,
                config.adminAddress
            );

            string memory filePath = string.concat(config.outputDir, "/link-validators.json");
            vm.writeFile(filePath, jsonContent);
            console2.log("Linking transaction written to:", filePath);

            // Simulate on fork so fee fetching works
            vm.prank(config.adminAddress);
            nodesManager.linkLegacyValidatorIds(allUnlinkedIds, allUnlinkedPubkeys);
            console2.log("Linking simulated on fork successfully");
        }
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
        bool foundSlash = false;
        
        for (uint256 i = 0; i < pathBytes.length; i++) {
            if (pathBytes[i] == '/') {
                lastSlash = i;
                foundSlash = true;
            }
        }
        
        // No slash found - return current directory
        if (!foundSlash) {
            return ".";
        }
        
        // Slash at index 0 (root path like /file.json) - return root
        if (lastSlash == 0) {
            return "/";
        }
        
        bytes memory dirBytes = new bytes(lastSlash);
        for (uint256 i = 0; i < lastSlash; i++) {
            dirBytes[i] = pathBytes[i];
        }
        
        return string(dirBytes);
    }
}
