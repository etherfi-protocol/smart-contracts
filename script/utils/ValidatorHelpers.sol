// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/StdJson.sol";
import "../../src/interfaces/IEtherFiNodesManager.sol";
import "../../src/interfaces/IEtherFiNode.sol";
import "../../src/eigenlayer-interfaces/IEigenPod.sol";

/**
 * @title Validator Helpers Library
 * @notice Utility functions for parsing validator data and resolving pods
 * @dev Library functions for validator operations (requires vm context for JSON parsing)
 */
library ValidatorHelpers {
    using stdJson for string;
    
    /**
     * @notice Parses validators from JSON data string
     * @param jsonData JSON data string (already read from file)
     * @param maxValidators Maximum number of validators to parse (prevents infinite loops)
     * @return pubkeys Array of validator public keys
     * @return ids Array of validator IDs
     * @return targetEigenPod EigenPod address extracted from withdrawal credentials
     * @return validatorCount Actual number of validators found
     */
    function parseValidatorsFromJson(
        string memory jsonData,
        uint256 maxValidators
    )
        internal
        view
        returns (
            bytes[] memory pubkeys,
            uint256[] memory ids,
            address targetEigenPod,
            uint256 validatorCount
        )
    {
        // Count validators first (with safety limit)
        validatorCount = 0;
        for (uint256 i = 0; i < maxValidators; i++) {
            string memory basePath = _buildJsonPath(i);
            if (!stdJson.keyExists(jsonData, string.concat(basePath, ".pubkey"))) {
                break;
            }
            validatorCount++;
        }
        
        // Return early if no validators found
        if (validatorCount == 0) {
            pubkeys = new bytes[](0);
            ids = new uint256[](0);
            targetEigenPod = address(0);
            return (pubkeys, ids, targetEigenPod, validatorCount);
        }
        
        // Extract withdrawal credentials from first validator to get EigenPod address
        bytes memory withdrawalCredentials = stdJson.readBytes(jsonData, "$[0].withdrawal_credentials");
        targetEigenPod = address(uint160(uint256(bytes32(withdrawalCredentials))));
        
        pubkeys = new bytes[](validatorCount);
        ids = new uint256[](validatorCount);
        
        for (uint256 i = 0; i < validatorCount; i++) {
            string memory basePath = _buildJsonPath(i);
            ids[i] = stdJson.readUint(jsonData, string.concat(basePath, ".id"));
            pubkeys[i] = stdJson.readBytes(jsonData, string.concat(basePath, ".pubkey"));
        }
    }
    
    /**
     * @notice Resolves EigenPod from validator pubkey
     * @param nodesManager EtherFiNodesManager contract instance
     * @param pubkey Validator public key
     * @return etherFiNode EtherFiNode instance
     * @return pod EigenPod instance
     */
    function resolvePod(IEtherFiNodesManager nodesManager, bytes memory pubkey)
        internal
        view
        returns (IEtherFiNode etherFiNode, IEigenPod pod)
    {
        bytes32 pkHash = nodesManager.calculateValidatorPubkeyHash(pubkey);
        etherFiNode = nodesManager.etherFiNodeFromPubkeyHash(pkHash);
        require(address(etherFiNode) != address(0), "ValidatorHelpers: validator not linked");
        pod = etherFiNode.getEigenPod();
        require(address(pod) != address(0), "ValidatorHelpers: node has no pod");
    }
    
    /**
     * @notice Helper to build JSON path for array index
     */
    function _buildJsonPath(uint256 index) private pure returns (string memory) {
        // Handle single-digit cases (0-9) for performance
        if (index < 10) {
            bytes memory single = new bytes(1);
            single[0] = bytes1(uint8(48 + index));
            return string.concat("$[", string(single), "]");
        }
        
        // For larger numbers (10+), convert to string
        uint256 temp = index;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        temp = index;
        while (temp != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(temp % 10)));
            temp /= 10;
        }
        return string.concat("$[", string(buffer), "]");
    }
}

