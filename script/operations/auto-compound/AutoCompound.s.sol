// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "forge-std/StdJson.sol";
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
 * @notice Generates auto-compounding (0x02) consolidation transactions grouped by EigenPod
 * @dev Automatically detects unlinked validators and generates linking transactions via timelock.
 *      Groups validators by withdrawal credentials (EigenPod) and creates separate consolidation
 *      transactions for each EigenPod group.
 *
 * Usage:
 *   JSON_FILE=validators.json SAFE_NONCE=42 forge script \
 *     script/operations/auto-compound/AutoCompound.s.sol:AutoCompound \
 *     --fork-url $MAINNET_RPC_URL -vvvv
 *
 * Environment Variables:
 *   - JSON_FILE: Path to JSON file with validator data (required)
 *   - OUTPUT_FILE: Output filename (default: auto-compound-txns.json)
 *   - BATCH_SIZE: Number of validators per EigenPod transaction (default: 50)
 *   - OUTPUT_FORMAT: "gnosis" or "raw" (default: gnosis)
 *   - SAFE_ADDRESS: Gnosis Safe address (default: ETHERFI_OPERATING_ADMIN)
 *   - CHAIN_ID: Chain ID for transaction (default: 1)
 *   - SAFE_NONCE: Starting nonce for Safe tx hash computation (default: 0)
 *
 * Output Files (when linking is needed):
 *   - *-link-schedule.json: Timelock schedule transaction (nonce N)
 *   - *-link-execute.json: Timelock execute transaction (nonce N+1)
 *   - *-consolidation.json: Array of consolidation transactions (nonces N+2, N+3, ...)
 *
 * The script groups validators by EigenPod (withdrawal credentials) and generates
 * separate consolidation transactions for each group. All transactions are output
 * in a single JSON array that can be processed by simulation tools.
 */
contract AutoCompound is Script, Utils {
    using stdJson for string;
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
        
        (bytes[] memory pubkeys, uint256[] memory ids, address[] memory podAddrs, uint256 validatorCount) =
            _parseValidatorsWithWithdrawalCredentials(jsonData, 10000);
        
        console2.log("Found", validatorCount, "validators");
        console2.log("Grouping by", _countUniquePods(podAddrs), "unique EigenPods (withdrawal credentials)");
        
        if (pubkeys.length == 0) {
            console2.log("No validators to process");
            return;
        }
        
        // Process validators
        _processValidators(pubkeys, ids, podAddrs, config);
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
        // console2.log("Output file:", config.outputFile);
        // console2.log("Batch size:", config.batchSize);
        // console2.log("Output format:", config.outputFormat);
        // console2.log("Safe nonce:", config.safeNonce);
        console2.log("");
    }
    
    function _processValidators(
        bytes[] memory pubkeys,
        uint256[] memory ids,
        address[] memory podAddrs,
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
        
        // Note: Fee per request will be determined per pod group during processing
        console2.log("");
        
        // Generate linking transactions if needed
        bool needsLinking = unlinkedIds.length > 0;
        
        if (needsLinking) {
            console2.log("=== GENERATING LINKING TRANSACTIONS ===");
            _generateLinkingTransactions(unlinkedIds, unlinkedPubkeys, config);
        }
        
        // Generate consolidation transactions grouped by EigenPod
        console2.log("");
        console2.log("=== GENERATING CONSOLIDATION TRANSACTIONS ===");
        console2.log("Validators will be grouped by withdrawal credentials (EigenPod)");
        _generateAndWriteConsolidation(pubkeys, ids, podAddrs, config, needsLinking);
        
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
            config.root, "/script/operations/auto-compound/", fileName
        );
        
        vm.writeFile(filePath, jsonContent);
        console2.log("Transaction written to:", filePath);
        
        // Output EIP-712 signing data
        _outputSigningData(
            config.chainId,
            config.safeAddress,
            txns[0].to,
            txns[0].value,
            txns[0].data,
            nonce,
            fileName
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
        uint256[] memory ids,
        address[] memory podAddrs,
        Config memory config,
        bool needsLinking
    ) internal {
        // Group validators by pod address and generate consolidation transactions
        ConsolidationTx[] memory transactions = _generateConsolidationTransactionsByPod(pubkeys, podAddrs, config);

        // Write output
        _writeConsolidationOutput(transactions, config, needsLinking);
    }
    
    function _writeConsolidationOutput(
        ConsolidationTx[] memory transactions,
        Config memory config,
        bool needsLinking
    ) internal {
        // Starting nonce for consolidation transactions
        uint256 startNonce = needsLinking ? config.safeNonce + 2 : config.safeNonce;

        // Determine output filename with starting nonce prefix
        string memory outputFileName = string.concat(
            startNonce.uint256ToString(), "-consolidation.json"
        );

        string memory outputPath = string.concat(
            config.root, "/script/operations/auto-compound/", outputFileName
        );

        // Generate JSON - separate Safe transactions for each pod group in one file
        string memory jsonOutput;

        if (keccak256(bytes(config.outputFormat)) == keccak256(bytes("gnosis"))) {
            jsonOutput = _generateMultiSafeTransactionJson(transactions, config);
        } else {
            jsonOutput = _generateRawJson(transactions);
        }

        vm.writeFile(outputPath, jsonOutput);
        console2.log("Consolidation transactions written to:", outputPath);

        // Output EIP-712 signing data for each consolidation transaction
        for (uint256 i = 0; i < transactions.length; i++) {
            uint256 currentNonce = startNonce + i;
            string memory txName = string.concat(
                currentNonce.uint256ToString(),
                "-consolidation-tx",
                (i + 1).uint256ToString()
            );

            _outputSigningData(
                config.chainId,
                config.safeAddress,
                transactions[i].to,
                transactions[i].value,
                transactions[i].data,
                currentNonce,
                txName
            );
        }

        console2.log("");
        console2.log("=== CONSOLIDATION SUMMARY ===");
        console2.log("Generated", transactions.length, "consolidation transactions (one per EigenPod)");
        console2.log("Starting nonce:", startNonce);
        console2.log("Ending nonce:", startNonce + transactions.length - 1);
        console2.log("All transactions in single JSON array for batch processing");
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
        bytes memory pathBytes = bytes(path);
        
        // If absolute path, return as-is
        if (pathBytes.length > 0 && pathBytes[0] == '/') {
            return path;
        }
        
        // If path already starts with "script/", treat as relative to project root
        if (pathBytes.length >= 7 && 
            pathBytes[0] == 's' && pathBytes[1] == 'c' && pathBytes[2] == 'r' && 
            pathBytes[3] == 'i' && pathBytes[4] == 'p' && pathBytes[5] == 't' && pathBytes[6] == '/') {
            return string.concat(root, "/", path);
        }
        
        // Otherwise, assume it's relative to auto-compound directory
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

    /**
     * @notice Parses validators from JSON data and returns pod addresses for each validator
     * @param jsonData JSON data string (already read from file)
     * @param maxValidators Maximum number of validators to parse (prevents infinite loops)
     * @return pubkeys Array of validator public keys
     * @return ids Array of validator IDs
     * @return podAddrs Array of pod addresses derived from withdrawal credentials
     * @return validatorCount Actual number of validators found
     */
    function _parseValidatorsWithWithdrawalCredentials(
        string memory jsonData,
        uint256 maxValidators
    )
        internal
        view
        returns (
            bytes[] memory pubkeys,
            uint256[] memory ids,
            address[] memory podAddrs,
            uint256 validatorCount
        )
    {
        // Count validators first (with safety limit)
        validatorCount = 0;
        for (uint256 i = 0; i < maxValidators; i++) {
            string memory basePath = string.concat("$[", vm.toString(i), "]");
            if (!stdJson.keyExists(jsonData, string.concat(basePath, ".pubkey"))) {
                break;
            }
            validatorCount++;
        }

        // Return early if no validators found
        if (validatorCount == 0) {
            pubkeys = new bytes[](0);
            ids = new uint256[](0);
            podAddrs = new address[](0);
            return (pubkeys, ids, podAddrs, validatorCount);
        }

        pubkeys = new bytes[](validatorCount);
        ids = new uint256[](validatorCount);
        podAddrs = new address[](validatorCount);

        for (uint256 i = 0; i < validatorCount; i++) {
            string memory basePath = string.concat("$[", vm.toString(i), "]");
            ids[i] = stdJson.readUint(jsonData, string.concat(basePath, ".id"));
            pubkeys[i] = stdJson.readBytes(jsonData, string.concat(basePath, ".pubkey"));

            bytes memory withdrawalCredentials = stdJson.readBytes(jsonData, string.concat(basePath, ".withdrawal_credentials"));
            require(withdrawalCredentials.length == 32, "Invalid withdrawal credentials length");
            podAddrs[i] = address(uint160(uint256(bytes32(withdrawalCredentials))));
        }
    }

    /**
     * @notice Counts unique pod addresses in the array
     */
    function _countUniquePods(address[] memory podAddrs) internal pure returns (uint256) {
        if (podAddrs.length == 0) return 0;

        address[] memory uniquePods = new address[](podAddrs.length);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < podAddrs.length; i++) {
            bool seen = false;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (uniquePods[j] == podAddrs[i]) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                uniquePods[uniqueCount] = podAddrs[i];
                unchecked { ++uniqueCount; }
            }
        }
        return uniqueCount;
    }

    /**
     * @notice Groups validators by pod address and generates consolidation transactions
     */
    function _generateConsolidationTransactionsByPod(
        bytes[] memory pubkeys,
        address[] memory podAddrs,
        Config memory config
    ) internal view returns (ConsolidationTx[] memory) {
        require(pubkeys.length == podAddrs.length, "pubkeys/pods length mismatch");

        // Find unique pod addresses
        address[] memory uniquePods = new address[](pubkeys.length);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < podAddrs.length; i++) {
            bool seen = false;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (uniquePods[j] == podAddrs[i]) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                uniquePods[uniqueCount] = podAddrs[i];
                unchecked { ++uniqueCount; }
            }
        }

        // Shrink unique pods array
        address[] memory podAddresses = new address[](uniqueCount);
        for (uint256 i = 0; i < uniqueCount; i++) {
            podAddresses[i] = uniquePods[i];
        }

        console2.log("Found", uniqueCount, "unique EigenPods");

        // Generate transactions for each pod
        ConsolidationTx[] memory allTransactions = new ConsolidationTx[](uniqueCount);
        uint256 txCount = 0;

        for (uint256 p = 0; p < uniqueCount; p++) {
            address targetPodAddr = podAddresses[p];

            // Collect validators for this pod
            bytes[] memory podPubkeysTmp = new bytes[](pubkeys.length);
            uint256 podValidatorCount = 0;

            for (uint256 i = 0; i < pubkeys.length; i++) {
                if (podAddrs[i] == targetPodAddr) {
                    podPubkeysTmp[podValidatorCount] = pubkeys[i];
                    unchecked { ++podValidatorCount; }
                }
            }

            if (podValidatorCount == 0) continue;

            // Shrink pubkeys array
            bytes[] memory podPubkeys = new bytes[](podValidatorCount);
            for (uint256 i = 0; i < podValidatorCount; i++) {
                podPubkeys[i] = podPubkeysTmp[i];
            }

            // Create one consolidation transaction per pod
            console2.log(string.concat("EigenPod ", targetPodAddr.addressToString(), " - validators: ", podValidatorCount.uint256ToString()));

            // For now, create one transaction per pod (no sub-batching)
            // Get consolidation fee for this pod
            uint256 feePerRequest = _getConsolidationFeeForPod(podPubkeys, targetPodAddr);

            // Generate consolidation transaction
            (address to, uint256 value, bytes memory data) =
                GnosisConsolidationLib.generateConsolidationTransaction(
                    podPubkeys,
                    feePerRequest,
                    address(nodesManager)
                );

            allTransactions[txCount] = ConsolidationTx({
                to: to,
                value: value,
                data: data,
                validatorCount: podValidatorCount
            });

            unchecked { ++txCount; }
        }

        // Shrink final array if needed
        if (txCount < uniqueCount) {
            ConsolidationTx[] memory finalTransactions = new ConsolidationTx[](txCount);
            for (uint256 i = 0; i < txCount; i++) {
                finalTransactions[i] = allTransactions[i];
            }
            return finalTransactions;
        }

        return allTransactions;
    }

    /**
     * @notice Gets consolidation fee for a specific pod
     */
    function _getConsolidationFeeForPod(bytes[] memory pubkeys, address targetPodAddr) internal view returns (uint256) {
        // Try to find a linked validator from this pod to resolve fee
        for (uint256 i = 0; i < pubkeys.length; i++) {
            if (_isLinked(pubkeys[i])) {
                (, IEigenPod pod) = ValidatorHelpers.resolvePod(nodesManager, pubkeys[i]);
                if (address(pod) == targetPodAddr) {
                    return pod.getConsolidationRequestFee();
                }
            }
        }

        // If no linked validators in this pod, use the target pod directly
        console2.log(string.concat("No linked validators found for pod ", targetPodAddr.addressToString(), " - using pod directly"));
        IEigenPod targetPod = IEigenPod(targetPodAddr);
        require(address(targetPod) != address(0), "Cannot resolve EigenPod");
        return targetPod.getConsolidationRequestFee();
    }

    /**
     * @notice Generates JSON with multiple separate Safe transactions (one per pod group)
     */
    function _generateMultiSafeTransactionJson(
        ConsolidationTx[] memory transactions,
        Config memory config
    ) internal pure returns (string memory) {
        string memory json = '[\n';

        for (uint256 i = 0; i < transactions.length; i++) {
            // Create single transaction array for this pod group
            GnosisTxGeneratorLib.GnosisTx[] memory singleTx = new GnosisTxGeneratorLib.GnosisTx[](1);
            singleTx[0] = GnosisTxGeneratorLib.GnosisTx({
                to: transactions[i].to,
                value: transactions[i].value,
                data: transactions[i].data
            });

            // Generate individual Safe transaction JSON
            string memory txJson = GnosisTxGeneratorLib.generateTransactionBatch(
                singleTx,
                config.chainId,
                config.safeAddress
            );

            // Add to array
            json = string.concat(json, '  ', txJson);

            if (i < transactions.length - 1) {
                json = string.concat(json, ',\n');
            } else {
                json = string.concat(json, '\n');
            }
        }

        json = string.concat(json, ']');
        return json;
    }

}

