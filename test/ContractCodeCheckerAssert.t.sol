// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {ContractCodeChecker} from "@scripts/ContractCodeChecker.sol";

/// @dev Bakes its own address into the runtime code via an immutable, exactly like
///      OpenZeppelin's `UUPSUpgradeable.__self`. Two deploys differ ONLY by these 20 bytes.
contract SelfRef {
    address public immutable self = address(this);
    function ping() external view returns (address) { return self; }
}

/// @dev Bakes a 32-byte address-derived word (like an EIP-712 cached domain separator) AND
///      its own address. Two deploys differ by the 20-byte self-address AND the 32-byte word.
contract WordRef {
    address public immutable self = address(this);
    bytes32 public immutable word = keccak256(abi.encode(address(this), "domain"));
    function W() external view returns (bytes32) { return word; }
}

/// @dev Structurally different contract (different length / content) — must always be rejected.
contract Other {
    uint256 public a;
    uint256 public b;
    function set(uint256 x, uint256 y) external { a = x; b = y; }
}

/// @notice Unit tests for the strict, reverting bytecode gate added for security-review Vuln 1.
///         Fork-free: deploys two copies of the same source so the only differences are the
///         address-derived immutables the gate is designed to tolerate.
contract ContractCodeCheckerAssertTest is Test {
    ContractCodeChecker internal checker;

    function setUp() public {
        checker = new ContractCodeChecker();
    }

    function test_passes_whenOnlySelfAddressDiffers() public {
        SelfRef a = new SelfRef();
        SelfRef b = new SelfRef();
        assertTrue(address(a).code.length == address(b).code.length, "precondition: equal length");
        // Only the 20-byte self-address differs -> gate must accept.
        checker.assertByteCodeMatch(address(a), address(b));
    }

    function test_passes_whenAllowedWordProvided() public {
        WordRef a = new WordRef();
        WordRef b = new WordRef();
        // self-address (20 bytes) + the verified 32-byte word -> accept when the word is supplied.
        checker.assertByteCodeMatch(address(a), address(b), a.W(), b.W());
    }

    function test_reverts_whenAllowedWordMissing() public {
        WordRef a = new WordRef();
        WordRef b = new WordRef();
        // The 32-byte word differs but is NOT whitelisted -> must revert.
        vm.expectRevert();
        checker.assertByteCodeMatch(address(a), address(b));
    }

    function test_reverts_whenAllowedWordWrong() public {
        WordRef a = new WordRef();
        WordRef b = new WordRef();
        // Supplying the wrong words must not let the diff through.
        vm.expectRevert();
        checker.assertByteCodeMatch(address(a), address(b), bytes32(uint256(1)), bytes32(uint256(2)));
    }

    function test_reverts_onDifferentContract() public {
        SelfRef a = new SelfRef();
        Other o = new Other();
        vm.expectRevert();
        checker.assertByteCodeMatch(address(a), address(o));
    }

    function test_reverts_onEmptyOnchainCode() public {
        SelfRef b = new SelfRef();
        // address(0xdead) has no code -> "on-chain bytecode empty".
        vm.expectRevert();
        checker.assertByteCodeMatch(address(0xdEaD), address(b));
    }

    function test_identicalContract_passes() public {
        // Same address vs itself: trivially identical, no diffs at all.
        SelfRef a = new SelfRef();
        checker.assertByteCodeMatch(address(a), address(a));
    }

    /// @dev Regression for the "immutable mask misaligned mid-slot" bug: when the on-chain and
    ///      local addresses share leading bytes, the difference first appears at an interior
    ///      offset of the embedded-address region. The gate must still recognize the region at
    ///      its true boundary and accept. Here X and Y share their first 19 bytes (differ only
    ///      in the last), so the mismatch is at offset+19 — the worst case for the old anchor.
    function test_passes_whenSelfAddressesShareLeadingBytes() public {
        address X = 0x1111111111111111111111111111111111111101;
        address Y = 0x1111111111111111111111111111111111111102;
        // Identical surrounding code; the only difference is each address embedded as its own
        // 20-byte self-reference, exactly like UUPSUpgradeable.__self.
        bytes memory codeX = abi.encodePacked(hex"60006000", bytes20(X), hex"00fe");
        bytes memory codeY = abi.encodePacked(hex"60006000", bytes20(Y), hex"00fe");
        vm.etch(X, codeX);
        vm.etch(Y, codeY);
        // Must NOT revert: the sole difference is the aligned 20-byte self-address.
        checker.assertByteCodeMatch(X, Y);
    }

    /// @dev Same shared-leading-bytes layout, but with an EXTRA genuine code difference outside
    ///      the address region — must still revert.
    function test_reverts_whenRealDiffAlongsideSharedLeadingAddress() public {
        address X = 0x2222222222222222222222222222222222222201;
        address Y = 0x2222222222222222222222222222222222222202;
        bytes memory codeX = abi.encodePacked(hex"60006000", bytes20(X), hex"00fe", hex"aa");
        bytes memory codeY = abi.encodePacked(hex"60006000", bytes20(Y), hex"00fe", hex"bb");
        vm.etch(X, codeX);
        vm.etch(Y, codeY);
        vm.expectRevert();
        checker.assertByteCodeMatch(X, Y);
    }
}
