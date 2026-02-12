// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "forge-std/StdJson.sol";

/**
 * @title SimulateTransactions
 * @notice Simulates timelock-gated transactions with time warping
 * @dev Executes schedule transactions, warps time, then executes execute transactions
 * 
 * Usage:
 *   TXNS=schedule.json,execute.json DELAY=28800 forge script \
 *     script/operations/utils/SimulateTransactions.s.sol:SimulateTransactions \
 *     --fork-url $MAINNET_RPC_URL -vvvv
 * 
 * Environment Variables:
 *   - TXNS: Comma-separated list of transaction JSON files
 *   - DELAY: Timelock delay in seconds (default: 28800 = 8 hours)
 *   - SAFE_ADDRESS: Address to execute transactions from
 */
contract SimulateTransactions is Script {
    using stdJson for string;
    
    // Default values
    uint256 constant DEFAULT_DELAY = 28800; // 8 hours
    address constant DEFAULT_SAFE = 0x2aCA71020De61bb532008049e1Bd41E451aE8AdC;
    
    // Transaction struct - fields ordered alphabetically for JSON parsing
    struct Transaction {
        bytes data;     // 'd' comes first alphabetically
        address to;     // 't' comes second
        string value;   // 'v' comes third (string to handle "0" values)
    }
    
    struct TransactionFile {
        Transaction[] transactions;
    }
    
    function run() external {
        console2.log("=== TRANSACTION SIMULATION ===");
        console2.log("");
        
        // Parse environment
        string memory txnsEnv = vm.envString("TXNS");
        uint256 delay = vm.envOr("DELAY", DEFAULT_DELAY);
        address safeAddress = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        // DELAY_AFTER_FILE: only warp time after this file index (default: warp after all except last)
        // Use max uint256 as sentinel to mean "warp after all files except last"
        uint256 delayAfterFile = vm.envOr("DELAY_AFTER_FILE", type(uint256).max);
        
        console2.log("Safe address:", safeAddress);
        console2.log("Timelock delay:", delay, "seconds");
        console2.log("");
        
        // Split transaction files
        string[] memory txnFiles = _splitString(txnsEnv, ",");
        console2.log("Transaction files:", txnFiles.length);
        
        // Fund the safe address for transactions
        vm.deal(safeAddress, 1000 ether);
        
        // Execute each file
        for (uint256 i = 0; i < txnFiles.length; i++) {
            console2.log("");
            console2.log("--- Processing file ---");
            console2.log("File:", txnFiles[i]);
            
            _executeTransactionsFromFile(txnFiles[i], safeAddress);
            
            // Warp time only after specific file index (for schedule→execute delay)
            // If delayAfterFile is max uint256, warp after all files except last (legacy behavior)
            bool shouldWarp;
            if (delayAfterFile == type(uint256).max) {
                shouldWarp = i < txnFiles.length - 1;
            } else {
                shouldWarp = i == delayAfterFile;
            }
            
            if (shouldWarp && delay > 0) {
                console2.log("");
                console2.log("Warping time by", delay, "seconds...");
                vm.warp(block.timestamp + delay);
                console2.log("New timestamp:", block.timestamp);
            }
        }
        
        console2.log("");
        console2.log("=== SIMULATION COMPLETE ===");
    }
    
    function _executeTransactionsFromFile(string memory filename, address safeAddress) internal {
        string memory root = vm.projectRoot();
        string memory path = _resolvePath(root, filename);
        
        console2.log("Reading:", path);
        
        string memory jsonData = vm.readFile(path);
        
        // Parse transactions array
        bytes memory txnsRaw = jsonData.parseRaw(".transactions");
        Transaction[] memory txns = abi.decode(txnsRaw, (Transaction[]));
        
        console2.log("Found", txns.length, "transaction(s)");
        
        for (uint256 i = 0; i < txns.length; i++) {
            console2.log("");
            console2.log("Executing transaction", i + 1);
            console2.log("  To:", txns[i].to);
            
            // Parse value from string
            uint256 value = _parseUint(txns[i].value);
            console2.log("  Value:", value);
            
            // Execute transaction
            vm.prank(safeAddress);
            (bool success, bytes memory returnData) = txns[i].to.call{value: value}(txns[i].data);
            
            if (success) {
                console2.log("  Status: SUCCESS");
            } else {
                console2.log("  Status: FAILED");
                console2.log("  Error:");
                console2.logBytes(returnData);
            }
        }
    }
    
    function _resolvePath(string memory root, string memory filename) internal pure returns (string memory) {
        // If filename starts with /, it's absolute
        bytes memory filenameBytes = bytes(filename);
        if (filenameBytes.length > 0 && filenameBytes[0] == '/') {
            return filename;
        }
        
        // Check if it already has script/operations in the path
        if (_contains(filename, "script/operations")) {
            return string.concat(root, "/", filename);
        }
        
        // Default to auto-compound directory
        return string.concat(root, "/script/operations/auto-compound/", filename);
    }
    
    function _contains(string memory str, string memory substr) internal pure returns (bool) {
        bytes memory strBytes = bytes(str);
        bytes memory substrBytes = bytes(substr);
        
        if (substrBytes.length > strBytes.length) return false;
        
        for (uint256 i = 0; i <= strBytes.length - substrBytes.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < substrBytes.length; j++) {
                if (strBytes[i + j] != substrBytes[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }
    
    function _splitString(string memory str, string memory delimiter) internal pure returns (string[] memory) {
        bytes memory strBytes = bytes(str);
        bytes memory delimBytes = bytes(delimiter);
        
        // Count delimiters
        uint256 count = 1;
        for (uint256 i = 0; i < strBytes.length; i++) {
            if (strBytes[i] == delimBytes[0]) {
                count++;
            }
        }
        
        string[] memory parts = new string[](count);
        uint256 partIndex = 0;
        uint256 start = 0;
        
        for (uint256 i = 0; i < strBytes.length; i++) {
            if (strBytes[i] == delimBytes[0]) {
                parts[partIndex] = _substring(str, start, i);
                partIndex++;
                start = i + 1;
            }
        }
        
        // Last part
        parts[partIndex] = _substring(str, start, strBytes.length);
        
        return parts;
    }
    
    function _substring(string memory str, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            result[i - start] = strBytes[i];
        }
        return string(result);
    }
    
    function _parseUint(string memory str) internal pure returns (uint256) {
        bytes memory b = bytes(str);
        uint256 result = 0;
        
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c >= 48 && c <= 57) {
                result = result * 10 + (c - 48);
            }
        }
        
        return result;
    }
}

