// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title String Helpers Library
 * @notice Utility functions for string manipulation in Solidity
 * @dev Pure functions for converting types to strings and formatting
 */
library StringHelpers {
    
    /**
     * @notice Converts uint256 to string
     * @param value The uint256 value to convert
     * @return The string representation
     */
    function uint256ToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
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
    
    /**
     * @notice Converts address to lowercase hex string with 0x prefix
     * @param addr The address to convert
     * @return The hex string representation
     */
    function addressToString(address addr) internal pure returns (string memory) {
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
    
    /**
     * @notice Converts bytes to hex string with 0x prefix
     * @param data The bytes to convert
     * @return The hex string representation
     */
    function bytesToHexString(bytes memory data) internal pure returns (string memory) {
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
    
    /**
     * @notice Converts bytes32 to hex string with 0x prefix
     * @param data The bytes32 to convert
     * @return The hex string representation
     */
    function bytes32ToHexString(bytes32 data) internal pure returns (string memory) {
        return bytesToHexString(abi.encodePacked(data));
    }
}

