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
 * @notice Generates transactions to consolidate multiple validators to a single target validator
 * @dev Focused script for consolidating validators within the same EigenPod.
 *      Automatically detects unlinked validators and generates linking transactions via timelock.
 * 
 * Usage:
 *   JSON_FILE=validators.json TARGET_PUBKEY=0x... TARGET_VALIDATOR_ID=123 SAFE_NONCE=42 forge script \
 *     script/operations/consolidations/ConsolidateToTarget.s.sol:ConsolidateToTarget \
 *     --fork-url $MAINNET_RPC_URL -vvvv
 * 
 * Environment Variables:
 *   - JSON_FILE: Path to JSON file with validator data (required)
 *   - TARGET_PUBKEY: 48-byte hex pubkey of target validator (required)
 *   - TARGET_VALIDATOR_ID: Validator ID of the target (required for linking if not linked)
 *   - OUTPUT_FILE: Output filename (default: consolidate-to-target-txns.json)
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
        uint256 safeNonce;
        bytes targetPubkey;
        uint256 targetValidatorId;
        uint256 feePerRequest;
        bool needsLinking;
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
        
        // Load config and parse validators
        (Config memory config, bytes[] memory pubkeys, uint256[] memory ids) = _initialize();
        
        if (pubkeys.length == 0) {
            console2.log("No validators to process");
            return;
        }
        
        // Collect all pubkeys that need linking and handle linking
        _handleLinking(config, pubkeys, ids);
        
        // Get fee using target pubkey (now linked on fork)
        config.feePerRequest = _getConsolidationFee(config.targetPubkey);
        console2.log("");
        console2.log("Fee per consolidation request:", config.feePerRequest);
        console2.log("================================================================================================================");
        
        // Generate and write consolidation transactions
        _processAndWrite(pubkeys, config);
    }
    
    function _initialize() internal returns (Config memory config, bytes[] memory pubkeys, uint256[] memory ids) {
        config = _loadConfig();
        
        // Required: JSON file, target pubkey, and target validator ID
        string memory jsonFile = vm.envString("JSON_FILE");
        config.targetPubkey = vm.envBytes("TARGET_PUBKEY");
        config.targetValidatorId = vm.envUint("TARGET_VALIDATOR_ID");
        require(config.targetPubkey.length == 48, "TARGET_PUBKEY must be 48 bytes");
        
        console2.log("JSON file:", jsonFile);
        console2.log("Target pubkey:", config.targetPubkey.bytesToHexString());
        console2.log("Target validator ID:", config.targetValidatorId);
        console2.log("Output file:", config.outputFile);
        console2.log("Batch size:", config.batchSize);
        console2.log("Safe nonce:", config.safeNonce);
        console2.log("");
        
        // Read and parse validators
        string memory jsonFilePath = _resolvePath(config.root, jsonFile);
        string memory jsonData = vm.readFile(jsonFilePath);
        
        uint256 validatorCount;
        (pubkeys, ids, , validatorCount) = ValidatorHelpers.parseValidatorsFromJson(jsonData, 10000);
        
        console2.log("Found", validatorCount, "validators");
    }
    
    function _handleLinking(Config memory config, bytes[] memory pubkeys, uint256[] memory ids) internal {
        // Collect all pubkeys that need linking
        (uint256[] memory unlinkedIds, bytes[] memory unlinkedPubkeys) = _collectUnlinkedValidators(
            config.targetPubkey, config.targetValidatorId, pubkeys, ids
        );
        
        config.needsLinking = unlinkedIds.length > 0;
        
        // If linking is needed, generate linking transactions and simulate on fork
        if (config.needsLinking) {
            console2.log("");
            console2.log("=== GENERATING LINKING TRANSACTIONS ===");
            console2.log("Unlinked validators found:", unlinkedIds.length);
            _generateLinkingTransactions(unlinkedIds, unlinkedPubkeys, config);
        }
    }
    
    function _loadConfig() internal view returns (Config memory config) {
        config.outputFile = vm.envOr("OUTPUT_FILE", string(DEFAULT_OUTPUT_FILE));
        config.batchSize = vm.envOr("BATCH_SIZE", DEFAULT_BATCH_SIZE);
        config.outputFormat = vm.envOr("OUTPUT_FORMAT", string(DEFAULT_OUTPUT_FORMAT));
        config.chainId = vm.envOr("CHAIN_ID", DEFAULT_CHAIN_ID);
        config.safeAddress = vm.envOr("SAFE_ADDRESS", ETHERFI_OPERATING_ADMIN);
        config.root = vm.projectRoot();
        config.safeNonce = vm.envOr("SAFE_NONCE", uint256(0));
    }
    
    function _getConsolidationFee(bytes memory targetPubkey) internal view returns (uint256) {
        (, IEigenPod targetPod) = ValidatorHelpers.resolvePod(nodesManager, targetPubkey);
        require(address(targetPod) != address(0), "Target validator has no pod");
        return targetPod.getConsolidationRequestFee();
    }
    
    /// @notice Check if a pubkey is linked to an EtherFiNode
    function _isPubkeyLinked(bytes memory pubkey) internal view returns (bool) {
        bytes32 pubkeyHash = nodesManager.calculateValidatorPubkeyHash(pubkey);
        address nodeAddr = address(nodesManager.etherFiNodeFromPubkeyHash(pubkeyHash));
        return nodeAddr != address(0);
    }
    
    /// @notice Collect all validators that need linking (target + first source)
    function _collectUnlinkedValidators(
        bytes memory targetPubkey,
        uint256 targetValidatorId,
        bytes[] memory sourcePubkeys,
        uint256[] memory sourceIds
    ) internal view returns (uint256[] memory unlinkedIds, bytes[] memory unlinkedPubkeys) {
        // Check target and first source
        bool targetNeedsLink = !_isPubkeyLinked(targetPubkey);
        bool firstSourceNeedsLink = !_isPubkeyLinked(sourcePubkeys[0]);
        
        if (targetNeedsLink) {
            console2.log("Target pubkey needs linking:");
            console2.log("  Pubkey:", targetPubkey.bytesToHexString());
            console2.log("  Validator ID:", targetValidatorId);
        } else {
            console2.log("Target pubkey is already linked");
        }
        
        if (firstSourceNeedsLink) {
            console2.log("First source pubkey needs linking:");
            console2.log("  Pubkey:", sourcePubkeys[0].bytesToHexString());
            console2.log("  Validator ID:", sourceIds[0]);
        } else {
            console2.log("First source pubkey is already linked");
        }
        
        // Count how many need linking
        uint256 count = 0;
        if (targetNeedsLink) count++;
        if (firstSourceNeedsLink) count++;
        
        // Build arrays
        unlinkedIds = new uint256[](count);
        unlinkedPubkeys = new bytes[](count);
        
        uint256 idx = 0;
        if (targetNeedsLink) {
            unlinkedIds[idx] = targetValidatorId;
            unlinkedPubkeys[idx] = targetPubkey;
            idx++;
        }
        if (firstSourceNeedsLink) {
            unlinkedIds[idx] = sourceIds[0];
            unlinkedPubkeys[idx] = sourcePubkeys[0];
        }
    }
    
    /// @notice Generate linking transactions via timelock and simulate on fork
    function _generateLinkingTransactions(
        uint256[] memory unlinkedIds,
        bytes[] memory unlinkedPubkeys,
        Config memory config
    ) internal {
        // Build timelock calldata
        (bytes memory scheduleCalldata, bytes memory executeCalldata) = 
            _buildTimelockCalldata(unlinkedIds, unlinkedPubkeys);
        
        // Write schedule transaction (nonce N)
        _writeLinkingTx(config, scheduleCalldata, config.safeNonce, "link-schedule");
        
        // Write execute transaction (nonce N+1)
        _writeLinkingTx(config, executeCalldata, config.safeNonce + 1, "link-execute");
    }
    
    function _writeLinkingTx(
        Config memory config,
        bytes memory callData,
        uint256 nonce,
        string memory txType
    ) internal {
        // Create transaction
        GnosisTxGeneratorLib.GnosisTx[] memory txns = new GnosisTxGeneratorLib.GnosisTx[](1);
        txns[0] = GnosisTxGeneratorLib.GnosisTx({
            to: OPERATING_TIMELOCK,
            value: 0,
            data: callData
        });
        
        // Generate JSON
        string memory jsonContent = GnosisTxGeneratorLib.generateTransactionBatch(
            txns,
            config.chainId,
            config.safeAddress
        );
        
        // Write file with nonce prefix
        string memory fileName = string.concat(nonce.uint256ToString(), "-", txType, ".json");
        string memory filePath = string.concat(
            config.root, "/script/operations/consolidations/", fileName
        );
        
        vm.writeFile(filePath, jsonContent);
        console2.log("Transaction written to:", filePath);
    }
    
    function _buildTimelockCalldata(
        uint256[] memory unlinkedIds,
        bytes[] memory unlinkedPubkeys
    ) internal returns (bytes memory scheduleCalldata, bytes memory executeCalldata) {
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
        
        bytes32 salt = keccak256(abi.encode(unlinkedIds, unlinkedPubkeys, "link-legacy-validators-consolidation"));
        
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
    
    function _processAndWrite(
        bytes[] memory pubkeys,
        Config memory config
    ) internal {
        ConsolidationTx[] memory consolidationTxs = _generateTransactions(
            pubkeys,
            config.targetPubkey,
            config.feePerRequest,
            config.batchSize
        );
        
        // Starting nonce for consolidation transactions
        // If linking was needed, nonces N and N+1 are used for link-schedule and link-execute
        uint256 startNonce = config.needsLinking ? config.safeNonce + 2 : config.safeNonce;
        
        // Write each consolidation transaction to its own file
        _writeConsolidationFiles(consolidationTxs, config, startNonce);
        
        console2.log("");
        console2.log("=== CONSOLIDATION COMPLETE ===");
        console2.log("Total validators:", pubkeys.length);
        console2.log("Number of consolidation batches:", consolidationTxs.length);
        if (config.needsLinking) {
            console2.log("Link transactions included: YES");
            console2.log("  Schedule nonce:", config.safeNonce);
            console2.log("  Execute nonce:", config.safeNonce + 1);
        }
    }
    
    function _writeConsolidationFiles(
        ConsolidationTx[] memory consolidationTxs,
        Config memory config,
        uint256 startNonce
    ) internal {
        for (uint256 i = 0; i < consolidationTxs.length; i++) {
            uint256 currentNonce = startNonce + i;
            
            GnosisTxGeneratorLib.GnosisTx[] memory txns = new GnosisTxGeneratorLib.GnosisTx[](1);
            txns[0] = GnosisTxGeneratorLib.GnosisTx({
                to: consolidationTxs[i].to,
                value: consolidationTxs[i].value,
                data: consolidationTxs[i].data
            });
            
            string memory jsonContent = GnosisTxGeneratorLib.generateTransactionBatch(
                txns,
                config.chainId,
                config.safeAddress
            );
            
            string memory fileName = string.concat(currentNonce.uint256ToString(), "-consolidation.json");
            string memory filePath = string.concat(
                config.root, "/script/operations/consolidations/", fileName
            );
            
            vm.writeFile(filePath, jsonContent);
            console2.log("Consolidation tx written to:", filePath);
        }
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
    
    function _resolvePath(string memory root, string memory path) internal pure returns (string memory) {
        // If path starts with /, it's already absolute
        if (bytes(path).length > 0 && bytes(path)[0] == '/') {
            return path;
        }
        // Otherwise, prepend root
        return string.concat(root, "/", path);
    }
}
