// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {console} from "forge-std/console.sol";
import {console2} from "forge-std/console2.sol";


contract ContractCodeChecker {

    event ByteMismatchSegment(
        uint256 startIndex,
        uint256 endIndex,
        bytes aSegment,
        bytes bSegment
    );

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

    function emitMismatchSegment(
        bytes memory a,
        bytes memory b,
        uint256 start,
        uint256 end
    ) internal {
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
        str[0] = '0';
        str[1] = 'x';
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

        if (compareBytes(onchainRuntimeBytecode, localBytecode)) {
            console2.log("-> Full Bytecode Match: Success\n");
        } else {
            console2.log("-> Full Bytecode Match: Fail\n");
        }
    }

    function verifyPartialMatch(address deployedImpl, address localDeployed) public {
        console2.log("Verifying partial bytecode match...");

        // Fetch runtime bytecode from on-chain addresses
        bytes memory localBytecode = localDeployed.code;
        bytes memory onchainRuntimeBytecode = deployedImpl.code;
        
        // Optionally check length first (not strictly necessary if doing a partial match)
        if (localBytecode.length == 0 || onchainRuntimeBytecode.length == 0) {
            revert("One of the bytecode arrays is empty, cannot verify.");
        }

        // Attempt to trim metadata from both local and on-chain bytecode
        bytes memory trimmedLocal = trimMetadata(localBytecode);
        bytes memory trimmedOnchain = trimMetadata(onchainRuntimeBytecode);

        // If trimmed lengths differ significantly, it suggests structural differences in code
        if (trimmedLocal.length != trimmedOnchain.length) {
            revert("Post-trim length mismatch: potential code differences.");
        }

        // Compare trimmed arrays byte-by-byte
        if (compareBytes(trimmedOnchain, trimmedLocal)) {
            console2.log("-> Partial Bytecode Match: Success\n");
        } else {
            console2.log("-> Partial Bytecode Match: Fail\n");
        }
    }

    function verifyLengthMatch(address deployedImpl, address localDeployed) public {
        console2.log("Verifying length match...");
        bytes memory localBytecode = localDeployed.code;
        bytes memory onchainRuntimeBytecode = deployedImpl.code;

        if (localBytecode.length == onchainRuntimeBytecode.length) {
            console2.log("-> Length Match: Success\n");
        } else {
            console2.log("-> Length Match: Fail\n");
        }
    }

    function verifyContractByteCodeMatch(address deployedImpl, address localDeployed) public {
        console2.log("Verifying contract bytecode match... for contract: ", address(deployedImpl));
        console2.log("Local deployed contract: ", address(localDeployed));
        console2.log("--------------------------------");
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

    // -------------------------------------------------------------------------
    // STRICT, REVERTING bytecode equality gate.
    //
    // The logging-only `verifyContractByteCodeMatch` above can never fail a
    // script (it only `console2.log`s "Fail"), so a wrong/malicious impl address
    // would still be accepted. `assertByteCodeMatch` is a hard gate: it REVERTS
    // on any genuine bytecode difference.
    //
    // The only legitimate differences between an on-chain UUPS impl and a freshly
    // re-deployed copy of the same source are address-derived immutables:
    //   1. `UUPSUpgradeable.__self == address(this)` — a 20-byte PUSH operand that
    //      equals each contract's OWN deployed address. Present in every impl.
    //   2. EIP-712 cached domain separator — a 32-byte word = keccak256(... , this).
    //      Only contracts that bake it as an immutable (e.g. EETH) carry one.
    // Both are normalized below: occurrence #1 is matched against the respective
    // self-address; occurrence #2 only against a caller-supplied allowed word that
    // the caller independently reads via `DOMAIN_SEPARATOR()`. ANY other differing
    // byte reverts.
    // -------------------------------------------------------------------------

    /// @notice Strict equality gate with no extra allowed words. Use for every
    ///         impl that has no address-derived 32-byte immutable.
    function assertByteCodeMatch(address deployedImpl, address localDeployed) public {
        assertByteCodeMatch(deployedImpl, localDeployed, bytes32(0), bytes32(0));
    }

    /// @notice Strict equality gate that additionally tolerates a single 32-byte
    ///         word (e.g. the EIP-712 domain separator). The on-chain code may
    ///         differ from local code at that word ONLY if the on-chain word
    ///         equals `onchainAllowedWord` and the local word equals
    ///         `localAllowedWord`; the caller must read both off-chain (e.g. via
    ///         `DOMAIN_SEPARATOR()`), so an attacker cannot use this as a hiding
    ///         spot for arbitrary code.
    /// @dev    Reverts unless the two runtime codes are byte-identical after
    ///         masking each contract's own 20-byte address and the allowed word.
    function assertByteCodeMatch(
        address deployedImpl,
        address localDeployed,
        bytes32 onchainAllowedWord,
        bytes32 localAllowedWord
    ) public {
        bytes memory a = deployedImpl.code;   // on-chain runtime code (the thing we trust)
        bytes memory b = localDeployed.code;  // freshly compiled+deployed reference
        require(a.length != 0, "ContractCodeChecker: on-chain bytecode empty (impl not deployed?)");
        require(b.length != 0, "ContractCodeChecker: local bytecode empty");
        require(a.length == b.length, "ContractCodeChecker: bytecode length mismatch");

        bytes20 selfA = bytes20(deployedImpl);
        bytes20 selfB = bytes20(localDeployed);
        bool allowWord = onchainAllowedWord != bytes32(0);

        uint256 len = a.length;

        // Mark every byte that belongs to an address-derived immutable so it is exempt from the
        // equality check. We must NOT key off "the first differing byte starts a region": if the
        // on-chain and local addresses (or words) share leading bytes, the difference first shows
        // up at an interior offset, and a region check anchored there would misalign and wrongly
        // reject matching source. Instead, scan for the region at its TRUE boundary and mask it
        // only where the on-chain side holds its own address/word AND the local side holds its
        // address/word at the SAME offset — so both sides stay aligned. The `selfA[0]` / word[0]
        // first-byte guards keep the scan ~O(n) by skipping the full compare at most positions.
        bool[] memory exempt = new bool[](len);
        bytes1 selfA0 = selfA[0];
        bytes1 word0 = onchainAllowedWord[0];
        for (uint256 p = 0; p < len; p++) {
            if (a[p] == selfA0 && p + 20 <= len && _eq20(a, p, selfA) && _eq20(b, p, selfB)) {
                for (uint256 k = 0; k < 20; k++) exempt[p + k] = true;
            }
            if (allowWord && a[p] == word0 && p + 32 <= len && _eq32(a, p, onchainAllowedWord) && _eq32(b, p, localAllowedWord)) {
                for (uint256 k = 0; k < 32; k++) exempt[p + k] = true;
            }
        }

        for (uint256 i = 0; i < len; i++) {
            if (!exempt[i] && a[i] != b[i]) {
                // Genuine code difference outside any address-derived immutable — fail hard.
                emitMismatchSegment(a, b, i, i);
                revert("ContractCodeChecker: bytecode mismatch beyond address-derived immutables");
            }
        }
    }

    function _eq20(bytes memory data, uint256 offset, bytes20 target) private pure returns (bool) {
        for (uint256 j = 0; j < 20; j++) {
            if (data[offset + j] != target[j]) return false;
        }
        return true;
    }

    function _eq32(bytes memory data, uint256 offset, bytes32 target) private pure returns (bool) {
        for (uint256 j = 0; j < 32; j++) {
            if (data[offset + j] != target[j]) return false;
        }
        return true;
    }
}
