// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

contract DepositDataGeneration {
    uint64 constant GWEI = 1e9;

    function generateDepositRoot(bytes memory pubkey, bytes memory signature, bytes memory withdrawal_credentials, uint256 _amountIn) internal pure returns (bytes32) {
        uint64 deposit_amount = uint64(_amountIn / GWEI);
        bytes memory amount = to_little_endian_64(deposit_amount);

        bytes32 pubkey_root = sha256(abi.encodePacked(pubkey, bytes16(0)));

        // Extract first 64 bytes of signature
        bytes memory firstChunk = extractBytes(signature, 0, 64);
        // Extract remaining bytes of signature
        bytes memory secondChunk = extractBytes(signature, 64, signature.length - 64);

        bytes32 signature_root = sha256(abi.encodePacked(sha256(abi.encodePacked(firstChunk)), sha256(abi.encodePacked(secondChunk, bytes32(0)))));
        return sha256(abi.encodePacked(sha256(abi.encodePacked(pubkey_root, withdrawal_credentials)), sha256(abi.encodePacked(amount, bytes24(0), signature_root))));
    }

    // Helper function to extract a portion of a bytes array
    function extractBytes(bytes memory data, uint256 startIndex, uint256 length) internal pure returns (bytes memory) {
        require(startIndex + length <= data.length, "Range out of bounds");

        bytes memory result = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            result[i] = data[startIndex + i];
        }

        return result;
    }

    function to_little_endian_64(uint64 value) internal pure returns (bytes memory ret) {
        ret = new bytes(8);
        bytes8 bytesValue = bytes8(value);
        // Byteswapping during copying to bytes.
        ret[0] = bytesValue[7];
        ret[1] = bytesValue[6];
        ret[2] = bytesValue[5];
        ret[3] = bytesValue[4];
        ret[4] = bytesValue[3];
        ret[5] = bytesValue[2];
        ret[6] = bytesValue[1];
        ret[7] = bytesValue[0];
    }
}
