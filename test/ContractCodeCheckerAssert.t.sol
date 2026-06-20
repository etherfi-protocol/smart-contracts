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
}
