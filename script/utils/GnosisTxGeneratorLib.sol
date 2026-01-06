// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./StringHelpers.sol";

/**
 * @title Gnosis Transaction Generator Library
 * @notice Generates prettified JSON for Gnosis Safe Transaction Builder
 * @dev Produces JSON compatible with Gnosis Safe Transaction Builder import format
 */
library GnosisTxGeneratorLib {
    using StringHelpers for uint256;
    using StringHelpers for address;
    using StringHelpers for bytes;
    
    /**
     * @notice Transaction data structure for Gnosis Safe
     */
    struct GnosisTx {
        address to;
        uint256 value;
        bytes data;
    }
    
    // Alias for backward compatibility
    struct Transaction {
        address to;
        uint256 value;
        bytes data;
    }
    
    /**
     * @notice Generates a prettified Gnosis Safe transaction batch JSON
     * @param transactions Array of transactions
     * @param chainId Chain ID for the transaction
     * @param safeAddress Address of the Gnosis Safe
     * @return json Prettified JSON string
     */
    function generateTransactionBatch(
        GnosisTx[] memory transactions,
        uint256 chainId,
        address safeAddress
    ) internal pure returns (string memory json) {
        json = string.concat(
            '{\n',
            '  "chainId": "', chainId.uint256ToString(), '",\n',
            '  "safeAddress": "', safeAddress.addressToString(), '",\n',
            '  "meta": {\n',
            '    "txBuilderVersion": "1.16.5"\n',
            '  },\n',
            '  "transactions": [\n'
        );
        
        for (uint256 i = 0; i < transactions.length; i++) {
            json = string.concat(
                json,
                '    {\n',
                '      "to": "', transactions[i].to.addressToString(), '",\n',
                '      "value": "', transactions[i].value.uint256ToString(), '",\n',
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
    }
    
    /**
     * @notice Generates a prettified Gnosis Safe transaction batch JSON with metadata
     * @param transactions Array of transactions
     * @param chainId Chain ID for the transaction
     * @param safeAddress Address of the Gnosis Safe
     * @param metaName Name for the transaction batch
     * @param metaDescription Description for the transaction batch
     * @return json Prettified JSON string
     */
    function generateTransactionBatchWithMeta(
        GnosisTx[] memory transactions,
        uint256 chainId,
        address safeAddress,
        string memory metaName,
        string memory metaDescription
    ) internal pure returns (string memory json) {
        json = string.concat(
            '{\n',
            '  "chainId": "', chainId.uint256ToString(), '",\n',
            '  "safeAddress": "', safeAddress.addressToString(), '",\n',
            '  "meta": {\n',
            '    "txBuilderVersion": "1.16.5",\n',
            '    "name": "', metaName, '",\n',
            '    "description": "', metaDescription, '"\n',
            '  },\n',
            '  "transactions": [\n'
        );
        
        for (uint256 i = 0; i < transactions.length; i++) {
            json = string.concat(
                json,
                '    {\n',
                '      "to": "', transactions[i].to.addressToString(), '",\n',
                '      "value": "', transactions[i].value.uint256ToString(), '",\n',
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
    }
    
    /**
     * @notice Creates a single GnosisTx struct
     */
    function createTx(
        address to,
        uint256 value,
        bytes memory data
    ) internal pure returns (GnosisTx memory) {
        return GnosisTx({
            to: to,
            value: value,
            data: data
        });
    }
    
    /**
     * @notice Generates transaction batch using Transaction struct (backward compatible)
     */
    function generateTransactionBatch(
        Transaction[] memory transactions,
        uint256 chainId,
        address safeAddress,
        string memory metaName,
        string memory metaDescription
    ) internal pure returns (string memory json) {
        json = string.concat(
            '{\n',
            '  "chainId": "', chainId.uint256ToString(), '",\n',
            '  "safeAddress": "', safeAddress.addressToString(), '",\n',
            '  "meta": {\n',
            '    "txBuilderVersion": "1.16.5",\n',
            '    "name": "', metaName, '",\n',
            '    "description": "', metaDescription, '"\n',
            '  },\n',
            '  "transactions": [\n'
        );
        
        for (uint256 i = 0; i < transactions.length; i++) {
            json = string.concat(
                json,
                '    {\n',
                '      "to": "', transactions[i].to.addressToString(), '",\n',
                '      "value": "', transactions[i].value.uint256ToString(), '",\n',
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
    }
}

