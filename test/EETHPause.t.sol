// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";

/// Unit + fuzz tests for the per-user FREEZE feature on EETH.
/// Role model:
///   EETH_PAUSER_ROLE         -> monitoring EOA   : pauseUntil(user) arms 1-day freeze
///   EETH_EXTEND_PAUSER_ROLE  -> security council : pause(user) / unpause(user)
///
/// Semantics under test:
/// - `paused` / `pausedUntil` are per-address mappings.
/// - `_transferShares` blocks if EITHER sender OR recipient is frozen.
/// - `mintShares` / `burnShares` are NOT gated — documented as C-1 in the review.
contract EETHPauseTest is TestSetup {
    event Paused(address indexed user);
    event PausedUntil(address indexed user, uint64 pausedUntil);
    event Unpaused(address indexed user);
    event Transfer(address indexed from, address indexed to, uint256 value);

    address pauser;
    address extendPauser;
    address unauthorized;

    uint64 constant ONE_DAY = 1 days;

    function setUp() public {
        setUpTests();

        pauser = vm.addr(0xA11CE1);
        extendPauser = vm.addr(0xA11CE2);
        unauthorized = vm.addr(0xA11CE3);

        vm.startPrank(owner);
        roleRegistryInstance.grantRole(eETHInstance.EETH_PAUSER_ROLE(), pauser);
        roleRegistryInstance.grantRole(eETHInstance.EETH_EXTEND_PAUSER_ROLE(), extendPauser);
        vm.stopPrank();

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(chad, 100 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.prank(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.prank(chad);
        liquidityPoolInstance.deposit{value: 10 ether}();
    }

    // -------------------------------------------------------------------
    //                          ZERO-ADDRESS GUARDS
    // -------------------------------------------------------------------

    function test_pause_rejectsZeroAddress() public {
        vm.prank(extendPauser);
        vm.expectRevert("No zero addresses");
        eETHInstance.pause(address(0));
    }

    function test_pauseUntil_rejectsZeroAddress() public {
        vm.prank(pauser);
        vm.expectRevert("No zero addresses");
        eETHInstance.pauseUntil(address(0));
    }

    function test_unpause_rejectsZeroAddress() public {
        vm.prank(extendPauser);
        vm.expectRevert("No zero addresses");
        eETHInstance.unpause(address(0));
    }

    // -------------------------------------------------------------------
    //                              ROLE GATING
    // -------------------------------------------------------------------

    function test_pause_onlyExtendPauserRole() public {
        vm.prank(unauthorized);
        vm.expectRevert("IncorrectRole");
        eETHInstance.pause(alice);

        vm.prank(pauser);
        vm.expectRevert("IncorrectRole");
        eETHInstance.pause(alice);

        vm.prank(extendPauser);
        eETHInstance.pause(alice);
        assertTrue(eETHInstance.paused(alice));
    }

    function test_pauseUntil_onlyPauserRole() public {
        vm.prank(unauthorized);
        vm.expectRevert("IncorrectRole");
        eETHInstance.pauseUntil(alice);

        vm.prank(extendPauser);
        vm.expectRevert("IncorrectRole");
        eETHInstance.pauseUntil(alice);

        vm.prank(pauser);
        eETHInstance.pauseUntil(alice);
        assertEq(eETHInstance.pausedUntil(alice), uint64(block.timestamp) + ONE_DAY);
    }

    function test_unpause_onlyExtendPauserRole() public {
        vm.prank(extendPauser);
        eETHInstance.pause(alice);

        vm.prank(unauthorized);
        vm.expectRevert("IncorrectRole");
        eETHInstance.unpause(alice);

        vm.prank(pauser);
        vm.expectRevert("IncorrectRole");
        eETHInstance.unpause(alice);

        vm.prank(extendPauser);
        eETHInstance.unpause(alice);
        assertFalse(eETHInstance.paused(alice));
    }

    // -------------------------------------------------------------------
    //                      PER-USER FREEZE SELECTIVITY
    // -------------------------------------------------------------------

    function test_freeze_isPerUser_othersUnaffected() public {
        vm.prank(extendPauser);
        eETHInstance.pause(alice);

        // bob -> chad must still succeed
        vm.prank(bob);
        eETHInstance.transfer(chad, 1 ether);

        // chad -> bob must still succeed
        vm.prank(chad);
        eETHInstance.transfer(bob, 1 ether);
    }

    function test_freeze_blocksSender() public {
        vm.prank(extendPauser);
        eETHInstance.pause(alice);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        eETHInstance.transfer(bob, 1 ether);
    }

    function test_freeze_blocksRecipient() public {
        vm.prank(extendPauser);
        eETHInstance.pause(alice);

        vm.prank(bob);
        vm.expectRevert("RECIPIENT PAUSED");
        eETHInstance.transfer(alice, 1 ether);
    }

    function test_freeze_blocksSelfTransfer() public {
        vm.prank(extendPauser);
        eETHInstance.pause(alice);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        eETHInstance.transfer(alice, 1 ether);
    }

    function test_freeze_blocksTransferFrom_viaSender() public {
        vm.prank(alice);
        eETHInstance.approve(bob, 1 ether);

        vm.prank(extendPauser);
        eETHInstance.pause(alice); // owner (sender) frozen

        vm.prank(bob);
        vm.expectRevert("SENDER PAUSED");
        eETHInstance.transferFrom(alice, chad, 1 ether);
    }

    function test_freeze_blocksTransferFrom_viaRecipient() public {
        vm.prank(alice);
        eETHInstance.approve(bob, 1 ether);

        vm.prank(extendPauser);
        eETHInstance.pause(chad); // recipient frozen

        vm.prank(bob);
        vm.expectRevert("RECIPIENT PAUSED");
        eETHInstance.transferFrom(alice, chad, 1 ether);
    }

    function test_freeze_spenderNotChecked() public {
        // Spender (bob) being frozen should NOT block transferFrom between unfrozen parties.
        // Only sender (alice) and recipient (chad) matter.
        vm.prank(alice);
        eETHInstance.approve(bob, 1 ether);

        vm.prank(extendPauser);
        eETHInstance.pause(bob);

        vm.prank(bob);
        eETHInstance.transferFrom(alice, chad, 1 ether); // must succeed
    }

    function test_bothPartiesFrozen_sendErrorFiresFirst() public {
        vm.prank(extendPauser);
        eETHInstance.pause(alice);
        vm.prank(extendPauser);
        eETHInstance.pause(bob);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        eETHInstance.transfer(bob, 1 ether);
    }

    function test_unfreeze_isPerUser() public {
        vm.prank(extendPauser);
        eETHInstance.pause(alice);
        vm.prank(extendPauser);
        eETHInstance.pause(bob);

        // Unfreeze only alice
        vm.prank(extendPauser);
        eETHInstance.unpause(alice);

        // Alice can transfer to chad
        vm.prank(alice);
        eETHInstance.transfer(chad, 1 ether);

        // Bob is still frozen
        vm.prank(bob);
        vm.expectRevert("SENDER PAUSED");
        eETHInstance.transfer(chad, 1 ether);
    }

    // -------------------------------------------------------------------
    //                     pauseUntil TIMER SEMANTICS
    // -------------------------------------------------------------------

    function test_pauseUntil_blocksSender() public {
        vm.prank(pauser);
        eETHInstance.pauseUntil(alice);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        eETHInstance.transfer(bob, 1 ether);
    }

    function test_pauseUntil_blocksRecipient() public {
        vm.prank(pauser);
        eETHInstance.pauseUntil(alice);

        vm.prank(bob);
        vm.expectRevert("RECIPIENT PAUSED");
        eETHInstance.transfer(alice, 1 ether);
    }

    function test_pauseUntil_expiresAfterOneDay() public {
        vm.prank(pauser);
        eETHInstance.pauseUntil(alice);
        uint64 expiry = eETHInstance.pausedUntil(alice);

        vm.warp(uint256(expiry) + 1);

        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);
    }

    function test_pauseUntil_blockedAtBoundary() public {
        vm.prank(pauser);
        eETHInstance.pauseUntil(alice);
        uint64 expiry = eETHInstance.pausedUntil(alice);
        vm.warp(expiry); // exactly at boundary — still frozen (require uses <)

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        eETHInstance.transfer(bob, 1 ether);
    }

    function test_pauseUntil_timerIsPerUser() public {
        vm.prank(pauser);
        eETHInstance.pauseUntil(alice);
        assertEq(eETHInstance.pausedUntil(bob), 0, "bob timer untouched");
    }

    function test_pauseUntil_silentNoOp_whilePaused() public {
        vm.prank(extendPauser);
        eETHInstance.pause(alice);
        uint64 before = eETHInstance.pausedUntil(alice);

        vm.prank(pauser);
        eETHInstance.pauseUntil(alice);

        assertEq(eETHInstance.pausedUntil(alice), before, "no change while indefinitely paused (M-1)");
        assertTrue(eETHInstance.paused(alice));
    }

    function test_pauseUntil_cannotExtend_whileTimerActive() public {
        vm.prank(pauser);
        eETHInstance.pauseUntil(alice);
        uint64 firstExpiry = eETHInstance.pausedUntil(alice);

        vm.warp(block.timestamp + 12 hours);

        vm.prank(pauser);
        eETHInstance.pauseUntil(alice);

        assertEq(eETHInstance.pausedUntil(alice), firstExpiry, "cannot extend live timer (M-1)");
    }

    function test_pauseUntil_canRenew_afterExpiry() public {
        vm.prank(pauser);
        eETHInstance.pauseUntil(alice);
        uint64 firstExpiry = eETHInstance.pausedUntil(alice);

        vm.warp(uint256(firstExpiry) + 1);

        vm.prank(pauser);
        eETHInstance.pauseUntil(alice);

        assertEq(eETHInstance.pausedUntil(alice), uint64(block.timestamp) + ONE_DAY);
        assertGt(eETHInstance.pausedUntil(alice), firstExpiry);
    }

    // -------------------------------------------------------------------
    //                          UNPAUSE SEMANTICS
    // -------------------------------------------------------------------

    function test_unpause_clearsBothFlags_whenFullyFrozen() public {
        vm.prank(pauser);
        eETHInstance.pauseUntil(alice);
        vm.prank(extendPauser);
        eETHInstance.pause(alice);

        assertTrue(eETHInstance.paused(alice));
        assertGt(eETHInstance.pausedUntil(alice), block.timestamp);

        vm.prank(extendPauser);
        eETHInstance.unpause(alice);

        assertFalse(eETHInstance.paused(alice));
        assertEq(eETHInstance.pausedUntil(alice), 0, "timer cleared since it was active");

        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);
    }

    /// @dev Documents M-2: unpause after expiry does not clear pausedUntil.
    function test_unpause_afterExpiry_leavesStaleTimer() public {
        vm.prank(pauser);
        eETHInstance.pauseUntil(alice);
        uint64 expiry = eETHInstance.pausedUntil(alice);

        vm.warp(uint256(expiry) + 1);

        vm.prank(extendPauser);
        eETHInstance.unpause(alice);

        assertEq(eETHInstance.pausedUntil(alice), expiry, "stale expiry remains (M-2)");
        assertFalse(eETHInstance.paused(alice));

        // Functionally still unfrozen (past timestamp).
        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);
    }

    /// @dev Documents M-2: unpause succeeds on never-paused user.
    function test_unpause_noop_whenNeverPaused() public {
        vm.prank(extendPauser);
        eETHInstance.unpause(alice);
        assertFalse(eETHInstance.paused(alice));
        assertEq(eETHInstance.pausedUntil(alice), 0);
    }

    // -------------------------------------------------------------------
    //                           EVENT EMISSION
    // -------------------------------------------------------------------

    function test_pause_emitsIndexedUser() public {
        vm.expectEmit(true, false, false, true);
        emit Paused(alice);
        vm.prank(extendPauser);
        eETHInstance.pause(alice);
    }

    function test_pauseUntil_emitsIndexedUserAndExpiry() public {
        vm.expectEmit(true, false, false, true);
        emit PausedUntil(alice, uint64(block.timestamp) + ONE_DAY);
        vm.prank(pauser);
        eETHInstance.pauseUntil(alice);
    }

    function test_unpause_emitsIndexedUser() public {
        vm.expectEmit(true, false, false, true);
        emit Unpaused(alice);
        vm.prank(extendPauser);
        eETHInstance.unpause(alice);
    }

    // -------------------------------------------------------------------
    //                  NON-TRANSFER PATHS DURING FREEZE
    // -------------------------------------------------------------------

    /// @dev CRITICAL (C-1): LiquidityPool can still mint shares for a frozen user.
    function test_mintShares_bypassesFreeze() public {
        vm.prank(extendPauser);
        eETHInstance.pause(alice);

        uint256 sharesBefore = eETHInstance.shares(alice);
        vm.prank(address(liquidityPoolInstance));
        eETHInstance.mintShares(alice, 5 ether);
        assertEq(eETHInstance.shares(alice), sharesBefore + 5 ether, "freeze did not stop mintShares (C-1)");
    }

    /// @dev CRITICAL (C-1): LiquidityPool can still burn shares for a frozen user.
    function test_burnShares_bypassesFreeze() public {
        vm.prank(extendPauser);
        eETHInstance.pause(alice);

        uint256 sharesBefore = eETHInstance.shares(alice);
        vm.prank(address(liquidityPoolInstance));
        eETHInstance.burnShares(alice, 1 ether);
        assertEq(eETHInstance.shares(alice), sharesBefore - 1 ether, "freeze did not stop burnShares (C-1)");
    }

    /// @dev CRITICAL (C-1): A frozen user can still deposit via LP end-to-end.
    function test_LPDeposit_bypassesFreezeOfDepositor() public {
        vm.prank(extendPauser);
        eETHInstance.pause(alice);

        uint256 sharesBefore = eETHInstance.shares(alice);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 1 ether}();
        assertGt(eETHInstance.shares(alice), sharesBefore, "deposit path not blocked by freeze");
    }

    function test_approve_notBlockedByFreeze() public {
        vm.prank(extendPauser);
        eETHInstance.pause(alice);

        vm.prank(alice);
        eETHInstance.approve(bob, 1 ether);
        assertEq(eETHInstance.allowance(alice, bob), 1 ether);
    }

    function test_permit_notBlockedByFreeze() public {
        ILiquidityPool.PermitInput memory p = createPermitInput(
            2, // alice pk
            bob,
            1 ether,
            eETHInstance.nonces(alice),
            type(uint256).max,
            eETHInstance.DOMAIN_SEPARATOR()
        );

        vm.prank(extendPauser);
        eETHInstance.pause(alice);

        eETHInstance.permit(alice, bob, 1 ether, type(uint256).max, p.v, p.r, p.s);
        assertEq(eETHInstance.allowance(alice, bob), 1 ether);
    }

    // -------------------------------------------------------------------
    //                    INTERLEAVED / LIFECYCLE FLOWS
    // -------------------------------------------------------------------

    function test_sequence_pauseUntil_then_extendPauser_locks() public {
        vm.prank(pauser);
        eETHInstance.pauseUntil(alice);

        vm.prank(extendPauser);
        eETHInstance.pause(alice);

        vm.warp(block.timestamp + 2 days);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        eETHInstance.transfer(bob, 1 ether);

        vm.prank(pauser);
        vm.expectRevert("IncorrectRole");
        eETHInstance.unpause(alice);

        vm.prank(extendPauser);
        eETHInstance.unpause(alice);

        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);
    }

    function test_sequence_revokeRole_disablesPauser() public {
        bytes32 role = eETHInstance.EETH_PAUSER_ROLE();
        vm.prank(owner);
        roleRegistryInstance.revokeRole(role, pauser);

        vm.prank(pauser);
        vm.expectRevert("IncorrectRole");
        eETHInstance.pauseUntil(alice);
    }

    // -------------------------------------------------------------------
    //                                FUZZING
    // -------------------------------------------------------------------

    function testFuzz_pause_revertsForNonExtendPauser(address caller) public {
        vm.assume(caller != extendPauser);
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        eETHInstance.pause(alice);
    }

    function testFuzz_pauseUntil_revertsForNonPauser(address caller) public {
        vm.assume(caller != pauser);
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        eETHInstance.pauseUntil(alice);
    }

    function testFuzz_unpause_revertsForNonExtendPauser(address caller) public {
        vm.assume(caller != extendPauser);
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        eETHInstance.unpause(alice);
    }

    function testFuzz_pauseUntil_setsOneDayFromWarpedTimestamp(uint64 warpTo) public {
        warpTo = uint64(bound(uint256(warpTo), block.timestamp + 1, type(uint64).max - ONE_DAY - 1));
        vm.warp(warpTo);

        vm.prank(pauser);
        eETHInstance.pauseUntil(alice);

        assertEq(eETHInstance.pausedUntil(alice), warpTo + ONE_DAY);
    }

    function testFuzz_senderFrozen_blocksAnyAmount(uint256 amount) public {
        amount = bound(amount, 1, eETHInstance.shares(alice));

        vm.prank(extendPauser);
        eETHInstance.pause(alice);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        eETHInstance.transfer(bob, amount);
    }

    function testFuzz_recipientFrozen_blocksAnyAmount(uint256 amount) public {
        amount = bound(amount, 1, eETHInstance.shares(bob));

        vm.prank(extendPauser);
        eETHInstance.pause(alice);

        vm.prank(bob);
        vm.expectRevert("RECIPIENT PAUSED");
        eETHInstance.transfer(alice, amount);
    }

    function testFuzz_unfrozenUsers_unaffected(uint256 amount) public {
        amount = bound(amount, 1, eETHInstance.shares(bob));

        // Freeze a bystander
        vm.prank(extendPauser);
        eETHInstance.pause(alice);

        uint256 bobBefore = eETHInstance.shares(bob);
        uint256 chadBefore = eETHInstance.shares(chad);

        vm.prank(bob);
        eETHInstance.transfer(chad, amount);

        // Share accounting preserved (allow wei-level rounding from shares/amount conversion)
        assertLe(eETHInstance.shares(bob), bobBefore);
        assertGe(eETHInstance.shares(chad), chadBefore);
    }

    function testFuzz_transferAtOrBeforeExpiry_blocksSender(uint64 delta) public {
        delta = uint64(bound(uint256(delta), 0, ONE_DAY));

        vm.prank(pauser);
        eETHInstance.pauseUntil(alice);
        uint64 expiry = eETHInstance.pausedUntil(alice);

        vm.warp(uint256(expiry) - delta);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        eETHInstance.transfer(bob, 1);
    }

    function testFuzz_transferWorksAfterExpiry(uint256 amount, uint64 extra) public {
        amount = bound(amount, 1, eETHInstance.shares(alice));
        extra = uint64(bound(uint256(extra), 1, 365 days));

        vm.prank(pauser);
        eETHInstance.pauseUntil(alice);

        vm.warp(uint256(eETHInstance.pausedUntil(alice)) + extra);

        uint256 aliceBefore = eETHInstance.shares(alice);
        uint256 bobBefore = eETHInstance.shares(bob);

        vm.prank(alice);
        eETHInstance.transfer(bob, amount);

        uint256 sharesMoved = aliceBefore - eETHInstance.shares(alice);
        assertEq(eETHInstance.shares(bob), bobBefore + sharesMoved);
    }

    function testFuzz_independentUsers_freezingOneDoesNotTouchOther(address userA, address userB) public {
        vm.assume(userA != address(0) && userB != address(0));
        vm.assume(userA != userB);

        vm.prank(extendPauser);
        eETHInstance.pause(userA);

        assertTrue(eETHInstance.paused(userA));
        assertFalse(eETHInstance.paused(userB));
        assertEq(eETHInstance.pausedUntil(userB), 0);
    }

    function testFuzz_pauseUntil_doesNotTouchOtherUser(address userA, address userB) public {
        vm.assume(userA != address(0) && userB != address(0));
        vm.assume(userA != userB);

        vm.prank(pauser);
        eETHInstance.pauseUntil(userA);

        assertGt(eETHInstance.pausedUntil(userA), block.timestamp);
        assertEq(eETHInstance.pausedUntil(userB), 0);
        assertFalse(eETHInstance.paused(userB));
    }
}
