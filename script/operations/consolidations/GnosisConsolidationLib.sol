// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../../../src/interfaces/IEtherFiNodesManager.sol";
import "../../../src/eigenlayer-interfaces/IEigenPod.sol";

/**
 * @title Consolidation Transaction Library
 * @notice Pure library for creating consolidation requests and generating transaction data
 * @dev Provides reusable functions for consolidation operations
 * 
 * Usage:
 *   import "./GnosisConsolidationLib.sol";
 *   GnosisConsolidationLib.createConsolidationRequests(...)
 */

library GnosisConsolidationLib {
    /**
     * @notice Creates auto-compounding consolidation requests (0x02)
     * @dev For auto-compounding, srcPubkey == targetPubkey (self-consolidation)
     * @param pubkeys Array of validator public keys to upgrade to auto-compounding
     * @return reqs Array of ConsolidationRequest structs
     */
    function createAutoCompoundRequests(bytes[] memory pubkeys)
        internal
        pure
        returns (IEigenPodTypes.ConsolidationRequest[] memory reqs)
    {
        reqs = new IEigenPodTypes.ConsolidationRequest[](pubkeys.length);
        for (uint256 i = 0; i < pubkeys.length; ++i) {
            reqs[i] = IEigenPodTypes.ConsolidationRequest({
                srcPubkey: pubkeys[i],
                targetPubkey: pubkeys[i] // Self-consolidation for auto-compounding (0x02)
            });
        }
    }

    /**
     * @notice Creates consolidation requests to a target pubkey
     * @dev Consolidates all source pubkeys to a single target pubkey (same pod consolidation)
     * @param pubkeys Array of source validator public keys to consolidate
     * @param targetPubkey Target validator public key to consolidate to
     * @return reqs Array of ConsolidationRequest structs
     */
    function createConsolidationRequests(bytes[] memory pubkeys, bytes memory targetPubkey)
        internal
        pure
        returns (IEigenPodTypes.ConsolidationRequest[] memory reqs)
    {
        reqs = new IEigenPodTypes.ConsolidationRequest[](pubkeys.length);
        for (uint256 i = 0; i < pubkeys.length; ++i) {
            reqs[i] = IEigenPodTypes.ConsolidationRequest({
                srcPubkey: pubkeys[i],
                targetPubkey: targetPubkey // Same pod consolidation
            });
        }
    }

    /**
     * @notice Generates calldata for requestConsolidation with custom requests
     * @dev Helper function to encode consolidation requests into calldata
     * @param reqs Array of ConsolidationRequest structs
     * @return data Encoded calldata for requestConsolidation call
     */
    function generateConsolidationCalldata(
        IEigenPodTypes.ConsolidationRequest[] memory reqs
    ) internal pure returns (bytes memory data) {
        data = abi.encodeWithSelector(
            IEtherFiNodesManager.requestConsolidation.selector,
            reqs
        );
    }

    /**
     * @notice Generates a single Gnosis Safe transaction for requestConsolidation (auto-compounding)
     * @dev Similar to _executeTimelockBatch but outputs Gnosis Safe transaction format
     * @param pubkeys Array of validator public keys to consolidate (auto-compounding)
     * @param feePerRequest Fee per consolidation request (from pod.getConsolidationRequestFee())
     * @param nodesManagerAddress Address of EtherFiNodesManager contract
     * @return to Target address (nodesManagerAddress)
     * @return value Total ETH value to send (feePerRequest * pubkeys.length)
     * @return data Encoded calldata for requestConsolidation call
     */
    function generateConsolidationTransaction(
        bytes[] memory pubkeys,
        uint256 feePerRequest,
        address nodesManagerAddress
    )
        internal
        pure
        returns (
            address to,
            uint256 value,
            bytes memory data
        )
    {
        require(pubkeys.length > 0, "Empty pubkeys array");
        
        // Create consolidation requests for auto-compounding (0x02)
        IEigenPodTypes.ConsolidationRequest[] memory reqs = createAutoCompoundRequests(pubkeys);
        
        // Encode calldata
        data = generateConsolidationCalldata(reqs);
        
        // Calculate total fee
        value = feePerRequest * pubkeys.length;
        
        to = nodesManagerAddress;
    }

    /**
     * @notice Generates a single transaction for requestConsolidation to a target pubkey
     * @dev Generates transaction data for consolidating to a target validator
     * @param pubkeys Array of source validator public keys to consolidate
     * @param targetPubkey Target validator public key to consolidate to
     * @param feePerRequest Fee per consolidation request (from pod.getConsolidationRequestFee())
     * @param nodesManagerAddress Address of EtherFiNodesManager contract
     * @return to Target address (nodesManagerAddress)
     * @return value Total ETH value to send (feePerRequest * pubkeys.length)
     * @return data Encoded calldata for requestConsolidation call
     */
    function generateConsolidationTransactionToTarget(
        bytes[] memory pubkeys,
        bytes memory targetPubkey,
        uint256 feePerRequest,
        address nodesManagerAddress
    )
        internal
        pure
        returns (
            address to,
            uint256 value,
            bytes memory data
        )
    {
        require(pubkeys.length > 0, "Empty pubkeys array");
        
        // Create consolidation requests to target pubkey
        IEigenPodTypes.ConsolidationRequest[] memory reqs = createConsolidationRequests(pubkeys, targetPubkey);
        
        // Encode calldata
        data = generateConsolidationCalldata(reqs);
        
        // Calculate total fee
        value = feePerRequest * pubkeys.length;
        
        to = nodesManagerAddress;
    }

}

