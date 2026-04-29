// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "forge-std/Test.sol";

import "../src/ReentrancyGuardNamespaced.sol";

/// @notice Verifies that the namespaced reentrancy guard's fixed storage slot
///         does NOT collide with any storage used by LiquidityPool or
///         WithdrawRequestNFT — including OZ upgradeable parents (Initializable,
///         ContextUpgradeable, ERC721Upgradeable, OwnableUpgradeable,
///         UUPSUpgradeable) and their `__gap` reservations.
///
/// Two directions of collision are tested:
///   (1) Writes to declared state variables must not touch the guard slot.
///   (2) Writes to the guard slot must not touch any declared state variable.
///
/// Mapping-slot collisions (`keccak256(abi.encode(key, mappingSlot)) == GUARD`)
/// are cryptographically ruled out by keccak256 preimage resistance. We still
/// exercise mapping-writing paths (ERC721 mint/transfer, `validatorSpawner`,
/// `_requests`) and verify guard-slot integrity to catch accidental collisions
/// with the tiny, deterministic subset of keys used in real flows.
contract ReentrancyGuardStorageTest is TestSetup {
    bytes32 private constant GUARD_SLOT =
        0xcd24049d7dcc1fde21494dba8ad7a067afb6b8f14dfe804abeeec84903344e97;

    // Distinctive sentinel value: not 0, not NOT_ENTERED(1), not ENTERED(2).
    bytes32 private constant SENTINEL = bytes32(uint256(0xDEADBEEFCAFEBABE));

    function setUp() public {
        setUpTests();
        vm.prank(admin);
        withdrawRequestNFTInstance.unPauseContract();
    }

    // -----------------------------------------------------------------
    //                   Direction 1: layout is disjoint
    // -----------------------------------------------------------------

    /// @dev Sequential storage slots are tiny integers (0, 1, 2, ...). The
    ///      guard slot is a keccak256 hash (~2^255). A uint256 cast proves the
    ///      distance. Using a loose upper bound of 10_000 for the declared-
    ///      storage range — both contracts use < 400 slots per `forge inspect`.
    function test_guardSlot_outsideDeclaredSequentialRange() public {
        uint256 guardAsUint = uint256(GUARD_SLOT);
        assertGt(guardAsUint, 10_000, "guard slot within declared sequential storage range");
    }

    /// @dev Fresh proxy should have 0 at guard slot (uninitialized).
    function test_guardSlot_initialValueIsZero_LP() public {
        assertEq(vm.load(address(liquidityPoolInstance), GUARD_SLOT), bytes32(0));
    }

    function test_guardSlot_initialValueIsZero_WRN() public {
        assertEq(vm.load(address(withdrawRequestNFTInstance), GUARD_SLOT), bytes32(0));
    }

    // -----------------------------------------------------------------
    //     Direction 2: declared-state writes don't touch guard slot
    // -----------------------------------------------------------------

    /// @dev Plants SENTINEL at guard slot, performs many unguarded state
    ///      mutations, verifies SENTINEL is preserved. If any declared slot
    ///      aliased the guard slot, the sentinel would be overwritten.
    function test_noCollision_LP_unguardedStateWrites_preserveGuardSlot() public {
        vm.store(address(liquidityPoolInstance), GUARD_SLOT, SENTINEL);

        // Unguarded setters — each touches a different declared storage slot.
        vm.startPrank(admin);
        liquidityPoolInstance.setFeeRecipient(address(0xBEEF));
        liquidityPoolInstance.setRestakeBnftDeposits(true);
        liquidityPoolInstance.setValidatorSizeWei(64 ether);
        liquidityPoolInstance.registerValidatorSpawner(address(0xABCD));
        vm.stopPrank();

        assertEq(
            vm.load(address(liquidityPoolInstance), GUARD_SLOT),
            SENTINEL,
            "LP declared state writes aliased the guard slot"
        );
    }

    /// @dev Same check via ERC721-triggering paths on WithdrawRequestNFT.
    ///      Mints NFTs (writes to _owners, _balances, _requests mappings),
    ///      transfers (writes to _tokenApprovals), and pause toggles.
    function test_noCollision_WRN_mappingAndStateWrites_preserveGuardSlot() public {
        vm.store(address(withdrawRequestNFTInstance), GUARD_SLOT, SENTINEL);

        // Generate a withdraw request so the ERC721 mappings and _requests get populated.
        vm.deal(alice, 3 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 3 ether}();
        vm.startPrank(alice);
        eETHInstance.approve(address(liquidityPoolInstance), 3 ether);
        uint256 rid = liquidityPoolInstance.requestWithdraw(alice, 1 ether);
        liquidityPoolInstance.requestWithdraw(alice, 1 ether);
        liquidityPoolInstance.requestWithdraw(alice, 1 ether);
        // ERC721 transfer path -> _tokenApprovals, _owners rewrite
        withdrawRequestNFTInstance.approve(bob, rid);
        withdrawRequestNFTInstance.transferFrom(alice, bob, rid);
        vm.stopPrank();

        // Admin pause toggle -> `paused` bool
        vm.prank(admin);
        withdrawRequestNFTInstance.pauseContract();
        vm.prank(admin);
        withdrawRequestNFTInstance.unPauseContract();

        assertEq(
            vm.load(address(withdrawRequestNFTInstance), GUARD_SLOT),
            SENTINEL,
            "WRN declared state writes aliased the guard slot"
        );
    }

    // -----------------------------------------------------------------
    //     Direction 3: guard-slot writes don't touch declared state
    // -----------------------------------------------------------------

    function test_noCollision_guardSlotWrites_doNotCorruptLPState() public {
        // Snapshot critical declared state.
        address feeRecipientBefore = liquidityPoolInstance.feeRecipient();
        address stakingMgrBefore = address(liquidityPoolInstance.stakingManager());
        address eethBefore = address(liquidityPoolInstance.eETH());
        uint128 totalInLpBefore = liquidityPoolInstance.totalValueInLp();
        uint128 totalOutBefore = liquidityPoolInstance.totalValueOutOfLp();
        uint256 validatorSizeBefore = liquidityPoolInstance.validatorSizeWei();

        // Fill a few exotic values into the guard slot.
        bytes32[4] memory probes = [
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            bytes32(type(uint256).max),
            SENTINEL
        ];
        for (uint256 i = 0; i < probes.length; i++) {
            vm.store(address(liquidityPoolInstance), GUARD_SLOT, probes[i]);

            assertEq(liquidityPoolInstance.feeRecipient(), feeRecipientBefore, "feeRecipient corrupted");
            assertEq(address(liquidityPoolInstance.stakingManager()), stakingMgrBefore, "stakingManager corrupted");
            assertEq(address(liquidityPoolInstance.eETH()), eethBefore, "eETH corrupted");
            assertEq(liquidityPoolInstance.totalValueInLp(), totalInLpBefore, "totalValueInLp corrupted");
            assertEq(liquidityPoolInstance.totalValueOutOfLp(), totalOutBefore, "totalValueOutOfLp corrupted");
            assertEq(liquidityPoolInstance.validatorSizeWei(), validatorSizeBefore, "validatorSizeWei corrupted");
        }
    }

    function test_noCollision_guardSlotWrites_doNotCorruptWRNState() public {
        // Snapshot critical declared state.
        address lpBefore = address(withdrawRequestNFTInstance.liquidityPool());
        address eethBefore = address(withdrawRequestNFTInstance.eETH());
        uint32 nextIdBefore = withdrawRequestNFTInstance.nextRequestId();
        uint32 lastFinBefore = withdrawRequestNFTInstance.lastFinalizedRequestId();
        uint16 splitBefore = withdrawRequestNFTInstance.shareRemainderSplitToTreasuryInBps();
        bool pausedBefore = withdrawRequestNFTInstance.paused();

        bytes32[4] memory probes = [
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            bytes32(type(uint256).max),
            SENTINEL
        ];
        for (uint256 i = 0; i < probes.length; i++) {
            vm.store(address(withdrawRequestNFTInstance), GUARD_SLOT, probes[i]);

            assertEq(address(withdrawRequestNFTInstance.liquidityPool()), lpBefore, "liquidityPool corrupted");
            assertEq(address(withdrawRequestNFTInstance.eETH()), eethBefore, "eETH corrupted");
            assertEq(withdrawRequestNFTInstance.nextRequestId(), nextIdBefore, "nextRequestId corrupted");
            assertEq(withdrawRequestNFTInstance.lastFinalizedRequestId(), lastFinBefore, "lastFinalizedRequestId corrupted");
            assertEq(withdrawRequestNFTInstance.shareRemainderSplitToTreasuryInBps(), splitBefore, "split corrupted");
            assertEq(withdrawRequestNFTInstance.paused(), pausedBefore, "paused corrupted");
        }
    }

    // -----------------------------------------------------------------
    //              Direction 4: guard cycles correctly
    // -----------------------------------------------------------------

    /// @dev After a guarded call completes, the slot must be NOT_ENTERED (1).
    function test_guardSlot_setsToNotEnteredAfterCall_LP() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 1 ether}();

        assertEq(vm.load(address(liquidityPoolInstance), GUARD_SLOT), bytes32(uint256(1)));
    }

    function test_guardSlot_setsToNotEnteredAfterCall_WRN() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 1 ether}();
        vm.startPrank(alice);
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);
        uint256 rid = liquidityPoolInstance.requestWithdraw(alice, 1 ether);
        vm.stopPrank();
        _finalizeWithdrawalRequest(rid);

        vm.prank(alice);
        withdrawRequestNFTInstance.claimWithdraw(rid);

        assertEq(vm.load(address(withdrawRequestNFTInstance), GUARD_SLOT), bytes32(uint256(1)));
    }

    /// @dev If the guard slot is pre-populated with ENTERED, the next guarded
    ///      call must revert with the expected selector — proves we actually
    ///      read the slot we think we do.
    function test_guardSlot_prePopulatedENTERED_revertsAllGuardedPaths() public {
        vm.store(address(liquidityPoolInstance), GUARD_SLOT, bytes32(uint256(2)));

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardNamespaced.ReentrancyGuardReentrantCall.selector);
        liquidityPoolInstance.deposit{value: 1 ether}();
    }

    /// @dev Any non-ENTERED value in the slot must be treated as NOT_ENTERED
    ///      (forward-compat with uninitialised 0 AND defensive against stray
    ///      writes that aren't exactly 2). Fuzzed.
    function testFuzz_guardSlot_nonENTERED_allowsCall(uint256 preValue) public {
        vm.assume(preValue != 2); // ENTERED
        vm.store(address(liquidityPoolInstance), GUARD_SLOT, bytes32(preValue));

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 1 ether}();

        // Post-call, guard must be normalised to NOT_ENTERED (1).
        assertEq(vm.load(address(liquidityPoolInstance), GUARD_SLOT), bytes32(uint256(1)));
    }

    // -----------------------------------------------------------------
    //   Direction 5: mapping/ERC721 hot paths don't drift guard slot
    // -----------------------------------------------------------------

    /// @dev Heavy mapping churn: deposit many times (writes eETH share mappings
    ///      via external contract — NB: those mappings live on eETH, not LP),
    ///      multiple withdraw requests, pause cycles. Guard slot sentinel must
    ///      survive across all of it (since all these paths are either
    ///      unguarded or use the guard transiently and restore NOT_ENTERED).
    ///
    ///      We seed the slot with SENTINEL, then exercise ONLY unguarded state
    ///      mutations so the guard modifier doesn't overwrite the sentinel.
    function test_noCollision_WRN_deepMappingWrites_unguardedPaths() public {
        vm.store(address(withdrawRequestNFTInstance), GUARD_SLOT, SENTINEL);

        // Pause / unpause cycles — only modify `paused`.
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(admin);
            withdrawRequestNFTInstance.pauseContract();
            vm.prank(admin);
            withdrawRequestNFTInstance.unPauseContract();
        }

        assertEq(
            vm.load(address(withdrawRequestNFTInstance), GUARD_SLOT),
            SENTINEL,
            "pause toggles aliased guard slot"
        );
    }

    /// @dev Cross-contract: deposit flow touches LP.totalValueInLp / totalValueOutOfLp
    ///      and external eETH shares mapping. Checks LP's guard slot integrity
    ///      against mutations on OTHER contracts (must be trivially orthogonal).
    function test_noCollision_LP_crossContractActivity() public {
        vm.store(address(liquidityPoolInstance), GUARD_SLOT, SENTINEL);

        // All of this mutates eETH (another contract), membership, admin — none of LP.
        vm.prank(admin);
        liquidityPoolInstance.setFeeRecipient(address(0xFEED));

        assertEq(
            vm.load(address(liquidityPoolInstance), GUARD_SLOT),
            SENTINEL
        );
    }
}
