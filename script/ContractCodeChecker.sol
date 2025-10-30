// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {console} from "forge-std/console.sol";
import {console2} from "forge-std/console2.sol";

contract ContractCodeChecker {
    event ByteMismatchSegment(uint256 startIndex, uint256 endIndex, bytes aSegment, bytes bSegment);

    function compareBytes(bytes memory a, bytes memory b) internal returns (bool) {
        if (a.length != b.length) {
            // Length mismatch, emit one big segment for the difference if that’s desirable
            // or just return false. For clarity, we can just return false here.
            return false;
        }

        uint256 len = a.length;
        uint256 start = 0;
        bool inMismatch = false;
        bool anyMismatch = false;

        for (uint256 i = 0; i < len; i++) {
            bool mismatch = (a[i] != b[i]);
            if (mismatch && !inMismatch) {
                // Starting a new mismatch segment
                start = i;
                inMismatch = true;
            } else if (!mismatch && inMismatch) {
                // Ending the current mismatch segment at i-1
                emitMismatchSegment(a, b, start, i - 1);
                inMismatch = false;
                anyMismatch = true;
            }
        }

        // If we ended with a mismatch still open, close it out
        if (inMismatch) {
            emitMismatchSegment(a, b, start, len - 1);
            anyMismatch = true;
        }

        // If no mismatch segments were found, everything matched
        return !anyMismatch;
    }

    function emitMismatchSegment(bytes memory a, bytes memory b, uint256 start, uint256 end) internal {
        // endIndex is inclusive
        uint256 segmentLength = end - start + 1;

        bytes memory aSegment = new bytes(segmentLength);
        bytes memory bSegment = new bytes(segmentLength);

        for (uint256 i = 0; i < segmentLength; i++) {
            aSegment[i] = a[start + i];
            bSegment[i] = b[start + i];
        }

        string memory aHex = bytesToHexString(aSegment);
        string memory bHex = bytesToHexString(bSegment);

        console2.log("- Mismatch segment at index [%s, %s]", start, end);
        console2.logString(string.concat(" - ", aHex));
        console2.logString(string.concat(" - ", bHex));

        emit ByteMismatchSegment(start, end, aSegment, bSegment);
    }

    function bytesToHexString(bytes memory data) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";

        // Every byte corresponds to two hex characters
        bytes memory str = new bytes(2 + data.length * 2);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < data.length; i++) {
            str[2 + i * 2] = alphabet[uint8(data[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }

    // Compare the full bytecode of two deployed contracts, ensuring a perfect match.
    function verifyFullMatch(address deployedImpl, address localDeployed) public {
        console2.log("Verifying full bytecode match...");
        bytes memory localBytecode = address(localDeployed).code;
        bytes memory onchainRuntimeBytecode = address(deployedImpl).code;

        if (compareBytes(localBytecode, onchainRuntimeBytecode)) console2.log("-> Full Bytecode Match: Success\n");
        else console2.log("-> Full Bytecode Match: Fail\n");
    }

    function verifyPartialMatch(address deployedImpl, address localDeployed) public {
        console2.log("Verifying partial bytecode match...");

        // Fetch runtime bytecode from on-chain addresses
        bytes memory localBytecode = localDeployed.code;
        bytes memory onchainRuntimeBytecode = deployedImpl.code;

        // Optionally check length first (not strictly necessary if doing a partial match)
        if (localBytecode.length == 0 || onchainRuntimeBytecode.length == 0) revert("One of the bytecode arrays is empty, cannot verify.");

        // Attempt to trim metadata from both local and on-chain bytecode
        bytes memory trimmedLocal = trimMetadata(localBytecode);
        bytes memory trimmedOnchain = trimMetadata(onchainRuntimeBytecode);

        // If trimmed lengths differ significantly, it suggests structural differences in code
        if (trimmedLocal.length != trimmedOnchain.length) revert("Post-trim length mismatch: potential code differences.");

        // Compare trimmed arrays byte-by-byte
        if (compareBytes(trimmedLocal, trimmedOnchain)) console2.log("-> Partial Bytecode Match: Success\n");
        else console2.log("-> Partial Bytecode Match: Fail\n");
    }

    function verifyLengthMatch(address deployedImpl, address localDeployed) public {
        console2.log("Verifying length match...");
        bytes memory localBytecode = localDeployed.code;
        bytes memory onchainRuntimeBytecode = deployedImpl.code;

        if (localBytecode.length == onchainRuntimeBytecode.length) console2.log("-> Length Match: Success\n");
        else console2.log("-> Length Match: Fail\n");
    }

    function verifyContractByteCodeMatch(address deployedImpl, address localDeployed) public {
        verifyLengthMatch(deployedImpl, localDeployed);
        verifyPartialMatch(deployedImpl, localDeployed);
        verifyFullMatch(deployedImpl, localDeployed);
    }

    // A helper function to remove metadata (CBOR encoded) from the end of the bytecode.
    // This is a heuristic based on known patterns in the metadata.
    function trimMetadata(bytes memory code) internal pure returns (bytes memory) {
        // Metadata usually starts with 0xa2 or a similar tag near the end.
        // We can scan backward for a known marker.
        // In Solidity 0.8.x, metadata often starts near the end with 0xa2 0x64 ... pattern.
        // This is a simplified approach and may need refinement.

        // For a more robust approach, you'd analyze the last bytes.
        // Typically, the CBOR metadata is at the very end of the bytecode.
        uint256 length = code.length;
        if (length < 4) {
            // Bytecode too short to have metadata
            return code;
        }

        // Scan backward for a CBOR header (0xa2).
        // We'll just look for 0xa2 from the end and truncate there.
        for (uint256 i = length - 1; i > 0; i--) {
            if (code[i] == 0xa2) {
                console2.log("Found metadata start at index: ", i);
                // print 8 bytes from this point
                bytes memory tmp = new bytes(8);
                for (uint256 j = 0; j < 8; j++) {
                    tmp[j] = code[i + j];
                }

                // Found a possible metadata start. We'll cut just before 0xa2.
                bytes memory trimmed = new bytes(i);
                for (uint256 j = 0; j < i; j++) {
                    trimmed[j] = code[j];
                }
                return trimmed;
            }
        }

        // If no metadata marker found, return as is.
        return code;
    }
}
