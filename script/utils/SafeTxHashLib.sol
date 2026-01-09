// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./StringHelpers.sol";

/**
 * @title Safe Transaction Hash Library
 * @notice Computes EIP-712 domain separator and SafeTxHash for Gnosis Safe
 * @dev Used to output signing data for transaction verification
 */
library SafeTxHashLib {
    using StringHelpers for bytes32;
    
    // EIP-712 Domain Typehash for Gnosis Safe
    bytes32 constant private DOMAIN_SEPARATOR_TYPEHASH = keccak256(
        "EIP712Domain(uint256 chainId,address verifyingContract)"
    );
    
    // Safe Transaction Typehash
    bytes32 constant private SAFE_TX_TYPEHASH = keccak256(
        "SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)"
    );
    
    /**
     * @notice Computes the EIP-712 domain separator for a Gnosis Safe
     * @param chainId The chain ID
     * @param safeAddress The Gnosis Safe address
     * @return The domain separator hash
     */
    function getDomainSeparator(
        uint256 chainId,
        address safeAddress
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_SEPARATOR_TYPEHASH,
                chainId,
                safeAddress
            )
        );
    }
    
    /**
     * @notice Computes the SafeTxHash for a transaction
     * @param to Destination address
     * @param value ETH value
     * @param data Transaction calldata
     * @param operation Operation type (0 = Call, 1 = DelegateCall)
     * @param safeTxGas Gas for the safe transaction
     * @param baseGas Base gas cost
     * @param gasPrice Gas price
     * @param gasToken Token for gas payment (address(0) for ETH)
     * @param refundReceiver Address to receive gas refund
     * @param nonce Safe nonce
     * @return The transaction hash
     */
    function getSafeTxHash(
        address to,
        uint256 value,
        bytes memory data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                SAFE_TX_TYPEHASH,
                to,
                value,
                keccak256(data),
                operation,
                safeTxGas,
                baseGas,
                gasPrice,
                gasToken,
                refundReceiver,
                nonce
            )
        );
    }
    
    /**
     * @notice Computes the final message hash to sign
     * @param domainSeparator The EIP-712 domain separator
     * @param safeTxHash The Safe transaction hash
     * @return The final hash to sign
     */
    function getMessageHash(
        bytes32 domainSeparator,
        bytes32 safeTxHash
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                bytes1(0x19),
                bytes1(0x01),
                domainSeparator,
                safeTxHash
            )
        );
    }
    
    /**
     * @notice Helper to compute signing data for a simple transaction
     * @dev Uses default values for gas parameters (0) and ETH for gas
     */
    function computeSigningData(
        uint256 chainId,
        address safeAddress,
        address to,
        uint256 value,
        bytes memory data,
        uint256 nonce
    ) internal pure returns (
        bytes32 domainSeparator,
        bytes32 safeTxHash,
        bytes32 messageHash
    ) {
        domainSeparator = getDomainSeparator(chainId, safeAddress);
        safeTxHash = getSafeTxHash(
            to,
            value,
            data,
            0, // operation: Call
            0, // safeTxGas
            0, // baseGas
            0, // gasPrice
            address(0), // gasToken: ETH
            address(0), // refundReceiver
            nonce
        );
        messageHash = getMessageHash(domainSeparator, safeTxHash);
    }
}

