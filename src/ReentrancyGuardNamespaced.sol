// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title ReentrancyGuardNamespaced
/// @notice Reentrancy guard that stores its `_status` flag at a fixed, namespaced
///         keccak storage slot instead of a sequential contract-storage slot.
/// @dev    This repo uses OpenZeppelin Upgradeable v4.8.2, whose
///         `ReentrancyGuardUpgradeable` declares `uint256 _status` + `uint256[49] __gap`
///         as regular (sequential) storage. Adding it as a parent to already-deployed
///         upgradeable contracts (e.g. LiquidityPool, WithdrawRequestNFT) would shift
///         every existing state variable by 50 slots and corrupt storage on upgrade.
///         This namespaced variant keeps `_status` at a deterministic slot so it can be
///         safely mixed into existing UUPS contracts without disturbing their layout.
abstract contract ReentrancyGuardNamespaced {
    // keccak256("etherfi.storage.ReentrancyGuard.v1")
    bytes32 private constant REENTRANCY_GUARD_SLOT =
        0xcd24049d7dcc1fde21494dba8ad7a067afb6b8f14dfe804abeeec84903344e97;

    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    error ReentrancyGuardReentrantCall();

    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        bytes32 slot = REENTRANCY_GUARD_SLOT;
        uint256 status;
        assembly { status := sload(slot) }
        // Treat both 0 (uninitialized) and NOT_ENTERED as "not entered".
        if (status == ENTERED) revert ReentrancyGuardReentrantCall();
        assembly { sstore(slot, ENTERED) }
    }

    function _nonReentrantAfter() private {
        bytes32 slot = REENTRANCY_GUARD_SLOT;
        assembly { sstore(slot, NOT_ENTERED) }
    }
}
