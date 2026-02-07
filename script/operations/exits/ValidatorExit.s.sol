// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../../../src/interfaces/IEtherFiNode.sol";
import "../../../src/interfaces/IEtherFiNodesManager.sol";
import {IEigenPod, IEigenPodTypes} from "../../../src/eigenlayer-interfaces/IEigenPod.sol";
import "forge-std/Script.sol";
import "forge-std/console2.sol";

/**
 * @title ValidatorExit
 * @notice Generates EL-triggered exit transactions for validators
 * @dev Supports both single validator and batch exits using requestExecutionLayerTriggeredWithdrawal
 * 
 * Usage for single validator:
 *   PUBKEY=0x... forge script \
 *     script/operations/exits/ValidatorExit.s.sol:ValidatorExit \
 *     --fork-url $MAINNET_RPC_URL -vvvv
 * 
 * Environment Variables:
 *   - PUBKEY: Validator pubkey to exit (hex string)
 *   - NODE_ID: Alternative to PUBKEY - use node ID
 */
contract ValidatorExit is Script {
    // === MAINNET CONTRACT ADDRESSES ===
    address constant ETHERFI_NODES_MANAGER_ADDR = 0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F;
    
    IEtherFiNodesManager constant nodesManager = IEtherFiNodesManager(ETHERFI_NODES_MANAGER_ADDR);
    
    function run() public {
        console2.log("================================================");
        console2.log("====== Validator Exit Transactions ======");
        console2.log("================================================");
        
        // Try to get pubkey from environment
        bytes memory pubkey;
        try vm.envBytes("PUBKEY") returns (bytes memory pk) {
            pubkey = pk;
        } catch {
            // Try node ID instead
            uint256 nodeId = vm.envUint("NODE_ID");
            pubkey = _getPubkeyFromNodeId(nodeId);
        }
        
        require(pubkey.length == 48, "Invalid pubkey length - must be 48 bytes");
        
        console2.log("Validator pubkey:");
        console2.logBytes(pubkey);
        console2.log("");
        
        // Resolve the EtherFi node and EigenPod
        bytes32 pkHash = nodesManager.calculateValidatorPubkeyHash(pubkey);
        IEtherFiNode etherFiNode = nodesManager.etherFiNodeFromPubkeyHash(pkHash);
        require(address(etherFiNode) != address(0), "Validator not found in EtherFiNodesManager");
        
        IEigenPod pod = etherFiNode.getEigenPod();
        require(address(pod) != address(0), "Node has no EigenPod");
        
        console2.log("EtherFi Node:", address(etherFiNode));
        console2.log("EigenPod:", address(pod));
        console2.log("");
        
        // Get exit request fee (full exit uses amountGwei = 0)
        uint256 exitFee = pod.getWithdrawalRequestFee();
        console2.log("Withdrawal request fee:", exitFee);
        
        // Generate exit request (amountGwei = 0 means full exit)
        IEigenPodTypes.WithdrawalRequest[] memory exitRequests = new IEigenPodTypes.WithdrawalRequest[](1);
        exitRequests[0] = IEigenPodTypes.WithdrawalRequest({
            pubkey: pubkey,
            amountGwei: 0  // 0 = full exit
        });
        
        // Encode the calldata
        bytes memory callData = abi.encodeWithSelector(
            IEtherFiNodesManager.requestExecutionLayerTriggeredWithdrawal.selector,
            exitRequests
        );
        
        console2.log("");
        console2.log("=== Transaction Data ===");
        console2.log("To:", ETHERFI_NODES_MANAGER_ADDR);
        console2.log("Value:", exitFee);
        console2.log("Calldata:");
        console2.logBytes(callData);
        
        // Output Gnosis Safe format
        console2.log("");
        console2.log("=== Gnosis Safe Transaction JSON ===");
        string memory json = _generateGnosisJson(callData, exitFee);
        console2.log(json);
    }
    
    function _getPubkeyFromNodeId(uint256 nodeId) internal view returns (bytes memory) {
        // This would need to be implemented based on how node IDs map to pubkeys
        // For now, revert with a helpful message
        revert("NODE_ID lookup not implemented - please provide PUBKEY directly");
    }
    
    function _generateGnosisJson(bytes memory callData, uint256 value) internal pure returns (string memory) {
        return string.concat(
            '{\n',
            '  "chainId": "1",\n',
            '  "safeAddress": "0x2aCA71020De61bb532008049e1Bd41E451aE8AdC",\n',
            '  "meta": {\n',
            '    "txBuilderVersion": "1.16.5",\n',
            '    "name": "Validator Exit Request"\n',
            '  },\n',
            '  "transactions": [\n',
            '    {\n',
            '      "to": "', _addressToHex(ETHERFI_NODES_MANAGER_ADDR), '",\n',
            '      "value": "', _uint256ToString(value), '",\n',
            '      "data": "', _bytesToHex(callData), '"\n',
            '    }\n',
            '  ]\n',
            '}'
        );
    }
    
    function _uint256ToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
    
    function _addressToHex(address addr) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory data = abi.encodePacked(addr);
        bytes memory str = new bytes(42);
        str[0] = '0';
        str[1] = 'x';
        for (uint256 i = 0; i < 20; i++) {
            str[2 + i * 2] = alphabet[uint8(data[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }
    
    function _bytesToHex(bytes memory data) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(2 + data.length * 2);
        str[0] = '0';
        str[1] = 'x';
        for (uint256 i = 0; i < data.length; i++) {
            str[2 + i * 2] = alphabet[uint8(data[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }
}

