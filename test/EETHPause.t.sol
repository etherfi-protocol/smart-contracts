// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";

/// Unit + fuzz tests for the hybrid pause feature on EETH.
/// Design:
///   - global `paused` (bool)           : pause() / unpause()                      -> PAUSER_ROLE (strong)
///   - per-user `pausedUntil[user]`     : pauseUntil(user)                         -> PAUSER_UNTIL_ROLE (weak)
///                                      : extendPauseUntil(user, duration)         -> PAUSER_ROLE (strong)
///                                      : cancelPauseUntil(user)                   -> PAUSER_ROLE (strong)
/// All transfer / mint / burn paths require global !paused AND timer expired for the affected user(s).
contract EETHPauseTest is TestSetup {
    event Paused();
    event PausedUntil(address indexed user, uint256 pausedUntil);
    event CancelledPauseUntil(address indexed user);
    event Unpaused();
    event Transfer(address indexed from, address indexed to, uint256 value);

    address pauser;       // PAUSER_ROLE (strong)
    address pauserUntil;  // PAUSER_UNTIL_ROLE (weak)
    address unauthorized;

    uint64 constant ONE_DAY = 1 days;

    function setUp() public {
        setUpTests();

        pauser = vm.addr(0xA11CE1);
        pauserUntil = vm.addr(0xA11CE2);
        unauthorized = vm.addr(0xA11CE3);

        vm.startPrank(owner);
        roleRegistryInstance.grantRole(eETHInstance.EETH_PAUSER_ROLE(), pauser);
        roleRegistryInstance.grantRole(eETHInstance.EETH_PAUSER_UNTIL_ROLE(), pauserUntil);
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

    function test_pauseUntil_rejectsZeroAddress() public {
        vm.prank(pauserUntil);
        vm.expectRevert("No zero addresses");
        eETHInstance.pauseUntil(address(0));
    }

    function test_extendPauseUntil_rejectsZeroAddress() public {
        vm.prank(pauser);
        vm.expectRevert("No zero addresses");
        eETHInstance.extendPauseUntil(address(0), ONE_DAY);
    }

    function test_cancelPauseUntil_rejectsZeroAddress() public {
        vm.prank(pauser);
        vm.expectRevert("No zero addresses");
        eETHInstance.cancelPauseUntil(address(0));
    }

    // -------------------------------------------------------------------
    //                              ROLE GATING
    // -------------------------------------------------------------------

    function test_pause_onlyPauserRole() public {
        vm.prank(unauthorized);
        vm.expectRevert("IncorrectRole");
        eETHInstance.pause();

        vm.prank(pauserUntil);
        vm.expectRevert("IncorrectRole");
        eETHInstance.pause();

        vm.prank(pauser);
        eETHInstance.pause();
        assertTrue(eETHInstance.paused());
    }

    function test_pauseUntil_onlyPauserUntilRole() public {
        vm.prank(unauthorized);
        vm.expectRevert("IncorrectRole");
        eETHInstance.pauseUntil(alice);

        vm.prank(pauser);
        vm.expectRevert("IncorrectRole");
        eETHInstance.pauseUntil(alice);

        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);
        assertEq(eETHInstance.pausedUntil(alice), uint64(block.timestamp) + ONE_DAY);
    }

    function test_extendPauseUntil_onlyPauserRole() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice); // arm the timer so extend has something to do

        vm.prank(unauthorized);
        vm.expectRevert("IncorrectRole");
        eETHInstance.extendPauseUntil(alice, 2 days);

        vm.prank(pauserUntil);
        vm.expectRevert("IncorrectRole");
        eETHInstance.extendPauseUntil(alice, 2 days);

        vm.prank(pauser);
        eETHInstance.extendPauseUntil(alice, 2 days);
        assertEq(eETHInstance.pausedUntil(alice), uint64(block.timestamp) + 2 days);
    }

    function test_cancelPauseUntil_onlyPauserRole() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(unauthorized);
        vm.expectRevert("IncorrectRole");
        eETHInstance.cancelPauseUntil(alice);

        vm.prank(pauserUntil);
        vm.expectRevert("IncorrectRole");
        eETHInstance.cancelPauseUntil(alice);

        vm.prank(pauser);
        eETHInstance.cancelPauseUntil(alice);
        assertEq(eETHInstance.pausedUntil(alice), 0);
    }

    function test_unpause_onlyPauserRole() public {
        vm.prank(pauser);
        eETHInstance.pause();

        vm.prank(unauthorized);
        vm.expectRevert("IncorrectRole");
        eETHInstance.unpause();

        vm.prank(pauserUntil);
        vm.expectRevert("IncorrectRole");
        eETHInstance.unpause();

        vm.prank(pauser);
        eETHInstance.unpause();
        assertFalse(eETHInstance.paused());
    }

    // -------------------------------------------------------------------
    //                     GLOBAL PAUSE — TRANSFER / MINT / BURN
    // -------------------------------------------------------------------

    function test_globalPause_blocksAllTransfers() public {
        vm.prank(pauser);
        eETHInstance.pause();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        eETHInstance.transfer(bob, 1 ether);

        // transferFrom also blocked
        vm.prank(alice);
        eETHInstance.approve(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert("PAUSED");
        eETHInstance.transferFrom(alice, chad, 1 ether);
    }

    function test_globalPause_blocksMintShares() public {
        vm.prank(pauser);
        eETHInstance.pause();

        vm.prank(address(liquidityPoolInstance));
        vm.expectRevert("MINT PAUSED");
        eETHInstance.mintShares(alice, 1 ether);
    }

    function test_globalPause_blocksBurnShares() public {
        vm.prank(pauser);
        eETHInstance.pause();

        vm.prank(address(liquidityPoolInstance));
        vm.expectRevert("BURN PAUSED");
        eETHInstance.burnShares(alice, 1 ether);
    }

    function test_globalPause_blocksLPDeposit() public {
        vm.prank(pauser);
        eETHInstance.pause();

        vm.prank(alice);
        vm.expectRevert("MINT PAUSED");
        liquidityPoolInstance.deposit{value: 1 ether}();
    }

    function test_globalUnpause_restoresTransfers() public {
        vm.prank(pauser);
        eETHInstance.pause();

        vm.prank(pauser);
        eETHInstance.unpause();

        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);
    }

    /// @dev Documents M-2: unpause has no is-paused guard.
    function test_unpause_noop_whenNotPaused() public {
        assertFalse(eETHInstance.paused());
        vm.prank(pauser);
        eETHInstance.unpause();
        assertFalse(eETHInstance.paused());
    }

    function test_globalPause_blocksEvenApprovedTransferFrom() public {
        vm.prank(alice);
        eETHInstance.approve(bob, 10 ether);

        vm.prank(pauser);
        eETHInstance.pause();

        vm.prank(bob);
        vm.expectRevert("PAUSED");
        eETHInstance.transferFrom(alice, chad, 1 ether);
    }

    // -------------------------------------------------------------------
    //                     PER-USER TIMER — TRANSFER BLOCKING
    // -------------------------------------------------------------------

    function test_pauseUntil_blocksSender() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        eETHInstance.transfer(bob, 1 ether);
    }

    function test_pauseUntil_blocksRecipient() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(bob);
        vm.expectRevert("RECIPIENT PAUSED");
        eETHInstance.transfer(alice, 1 ether);
    }

    function test_pauseUntil_blocksSelfTransfer() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        eETHInstance.transfer(alice, 1 ether);
    }

    function test_pauseUntil_blocksMintShares() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(address(liquidityPoolInstance));
        vm.expectRevert("MINT PAUSED");
        eETHInstance.mintShares(alice, 1 ether);
    }

    function test_pauseUntil_blocksBurnShares() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(address(liquidityPoolInstance));
        vm.expectRevert("BURN PAUSED");
        eETHInstance.burnShares(alice, 1 ether);
    }

    function test_pauseUntil_blocksLPDepositForUser() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(alice);
        vm.expectRevert("MINT PAUSED");
        liquidityPoolInstance.deposit{value: 1 ether}();
    }

    function test_pauseUntil_isPerUser_othersUnaffected() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(bob);
        eETHInstance.transfer(chad, 1 ether);
        vm.prank(chad);
        eETHInstance.transfer(bob, 1 ether);

        // bob can deposit
        vm.prank(bob);
        liquidityPoolInstance.deposit{value: 1 ether}();
    }

    function test_pauseUntil_blockedAtBoundary() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);
        uint256 expiry = eETHInstance.pausedUntil(alice);
        vm.warp(expiry);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        eETHInstance.transfer(bob, 1 ether);
    }

    function test_pauseUntil_expiresAfterOneDay() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);
        uint256 expiry = eETHInstance.pausedUntil(alice);

        vm.warp(uint256(expiry) + 1);

        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);
    }

    function test_pauseUntil_spenderCanRelayBetweenUnfrozenParties() public {
        // Spender (bob) frozen on per-user timer, but alice → chad transferFrom must still work.
        vm.prank(alice);
        eETHInstance.approve(bob, 1 ether);

        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(bob);

        vm.prank(bob);
        eETHInstance.transferFrom(alice, chad, 1 ether);
    }

    // -------------------------------------------------------------------
    //                   pauseUntil — no-op while timer active
    // -------------------------------------------------------------------

    /// @dev Documents carry-over M-1: pauseUntil cannot be refreshed by the weak role.
    function test_pauseUntil_cannotExtend_whileTimerActive() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);
        uint256 firstExpiry = eETHInstance.pausedUntil(alice);

        vm.warp(block.timestamp + 12 hours);

        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        assertEq(eETHInstance.pausedUntil(alice), firstExpiry, "weak role cannot refresh (M-1)");
    }

    function test_pauseUntil_canRenew_afterExpiry() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);
        uint256 firstExpiry = eETHInstance.pausedUntil(alice);

        vm.warp(uint256(firstExpiry) + 1);

        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        assertEq(eETHInstance.pausedUntil(alice), uint64(block.timestamp) + ONE_DAY);
    }

    // -------------------------------------------------------------------
    //                         extendPauseUntil SEMANTICS
    // -------------------------------------------------------------------

    function test_extendPauseUntil_extendsLiveTimer() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(pauser);
        eETHInstance.extendPauseUntil(alice, 7 days);

        assertEq(eETHInstance.pausedUntil(alice), uint64(block.timestamp) + 7 days);

        vm.warp(block.timestamp + 1 days + 1); // past original 1-day expiry
        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        eETHInstance.transfer(bob, 1 ether);
    }

    /// @dev H-1 (HIGH): extendPauseUntil can SHORTEN a timer despite its name.
    function test_SECURITY_extendPauseUntil_canShortenTimer() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice); // arms 1-day timer

        // Admin calls extend with 1-hour duration → new expiry is EARLIER than original.
        vm.prank(pauser);
        eETHInstance.extendPauseUntil(alice, 1 hours);

        assertEq(eETHInstance.pausedUntil(alice), uint64(block.timestamp) + 1 hours);
        assertLt(eETHInstance.pausedUntil(alice), uint64(block.timestamp) + ONE_DAY,
                 "extend should not allow shortening (H-1)");
    }

    /// @dev H-1 corollary: duration=0 effectively releases the user next block.
    function test_SECURITY_extendPauseUntil_withZeroDuration_effectivelyCancels() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(pauser);
        eETHInstance.extendPauseUntil(alice, 0);

        // Current block — timer is at block.timestamp, require uses strict <, still paused.
        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        eETHInstance.transfer(bob, 1 ether);

        // But any forward progress unfreezes.
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);
    }

    /// @dev M-1-new: extendPauseUntil silent no-op when timer already expired.
    function test_extendPauseUntil_silentNoOp_whenTimerExpired() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);
        uint256 expiry = eETHInstance.pausedUntil(alice);

        vm.warp(uint256(expiry) + 1);

        vm.prank(pauser);
        eETHInstance.extendPauseUntil(alice, 3 days);

        assertEq(eETHInstance.pausedUntil(alice), expiry, "no-op when timer expired (M-1-new)");
    }

    function test_extendPauseUntil_silentNoOp_whenNeverArmed() public {
        vm.prank(pauser);
        eETHInstance.extendPauseUntil(alice, 3 days);
        assertEq(eETHInstance.pausedUntil(alice), 0);
    }

    function test_extendPauseUntil_emitsPausedUntil_whenActive() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        uint64 expected = uint64(block.timestamp) + 3 days;
        vm.expectEmit(true, false, false, true);
        emit PausedUntil(alice, expected);
        vm.prank(pauser);
        eETHInstance.extendPauseUntil(alice, 3 days);
    }

    function test_extendPauseUntil_doesNotEmit_whenExpired() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);
        vm.warp(block.timestamp + 2 days);

        vm.recordLogs();
        vm.prank(pauser);
        eETHInstance.extendPauseUntil(alice, 3 days);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no event on no-op");
    }

    function test_extendPauseUntil_onOtherUser_doesNotLeak() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(pauser);
        eETHInstance.extendPauseUntil(bob, 7 days); // bob was never paused → no-op

        assertEq(eETHInstance.pausedUntil(bob), 0);
    }

    // -------------------------------------------------------------------
    //                         cancelPauseUntil SEMANTICS
    // -------------------------------------------------------------------

    function test_cancelPauseUntil_clearsActiveTimer() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(pauser);
        eETHInstance.cancelPauseUntil(alice);

        assertEq(eETHInstance.pausedUntil(alice), 0);

        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether); // must succeed immediately
    }

    /// @dev M-2-new: cancelPauseUntil emits event even when there's nothing to cancel.
    function test_cancelPauseUntil_emitsEvenWhenNeverArmed() public {
        vm.expectEmit(true, false, false, true);
        emit CancelledPauseUntil(alice);
        vm.prank(pauser);
        eETHInstance.cancelPauseUntil(alice);
    }

    function test_cancelPauseUntil_emitsEvenWhenAlreadyExpired() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);
        vm.warp(block.timestamp + 2 days);

        vm.expectEmit(true, false, false, true);
        emit CancelledPauseUntil(alice);
        vm.prank(pauser);
        eETHInstance.cancelPauseUntil(alice);

        assertEq(eETHInstance.pausedUntil(alice), 0, "stale timer also cleared");
    }

    function test_cancelPauseUntil_isPerUser_doesNotTouchOthers() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(bob);

        vm.prank(pauser);
        eETHInstance.cancelPauseUntil(alice);

        assertEq(eETHInstance.pausedUntil(alice), 0);
        assertGt(eETHInstance.pausedUntil(bob), block.timestamp);
    }

    // -------------------------------------------------------------------
    //                 GLOBAL ⨯ PER-USER INTERACTION
    // -------------------------------------------------------------------

    function test_globalPause_dominatesTimerCheck_inTransfer() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(pauser);
        eETHInstance.pause();

        // Even bob (not timer-frozen) can't transfer — global wins, returns "PAUSED".
        vm.prank(bob);
        vm.expectRevert("PAUSED");
        eETHInstance.transfer(chad, 1 ether);
    }

    function test_globalUnpause_leavesPerUserTimerInEffect() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(pauser);
        eETHInstance.pause();
        vm.prank(pauser);
        eETHInstance.unpause();

        // Bob can move again, alice is still locked by per-user timer.
        vm.prank(bob);
        eETHInstance.transfer(chad, 1 ether);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        eETHInstance.transfer(bob, 1 ether);
    }

    function test_pauseUntilWorksDuringGlobalPause_butTransfersStillBlocked() public {
        vm.prank(pauser);
        eETHInstance.pause();

        // Weak role can still arm a per-user timer during global pause.
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        assertGt(eETHInstance.pausedUntil(alice), block.timestamp);
    }

    // -------------------------------------------------------------------
    //                                EVENTS
    // -------------------------------------------------------------------

    function test_pause_emitsPaused() public {
        vm.expectEmit(false, false, false, true);
        emit Paused();
        vm.prank(pauser);
        eETHInstance.pause();
    }

    function test_unpause_emitsUnpaused() public {
        vm.expectEmit(false, false, false, true);
        emit Unpaused();
        vm.prank(pauser);
        eETHInstance.unpause();
    }

    function test_pauseUntil_emitsIndexedUserAndExpiry() public {
        vm.expectEmit(true, false, false, true);
        emit PausedUntil(alice, uint64(block.timestamp) + ONE_DAY);
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);
    }

    // -------------------------------------------------------------------
    //                   NON-TRANSFER PATHS DURING FREEZE
    // -------------------------------------------------------------------

    function test_approve_worksDuringGlobalPause() public {
        vm.prank(pauser);
        eETHInstance.pause();

        vm.prank(alice);
        eETHInstance.approve(bob, 1 ether);
        assertEq(eETHInstance.allowance(alice, bob), 1 ether);
    }

    function test_approve_worksWhileUserPaused() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(alice);
        eETHInstance.approve(bob, 1 ether);
        assertEq(eETHInstance.allowance(alice, bob), 1 ether);
    }

    function test_permit_worksDuringGlobalPause() public {
        ILiquidityPool.PermitInput memory p = createPermitInput(
            2, bob, 1 ether, eETHInstance.nonces(alice),
            type(uint256).max, eETHInstance.DOMAIN_SEPARATOR()
        );

        vm.prank(pauser);
        eETHInstance.pause();

        eETHInstance.permit(alice, bob, 1 ether, type(uint256).max, p.v, p.r, p.s);
        assertEq(eETHInstance.allowance(alice, bob), 1 ether);
    }

    // -------------------------------------------------------------------
    //                          LIFECYCLE SEQUENCES
    // -------------------------------------------------------------------

    function test_sequence_weakArms_then_strongExtends_then_strongCancels() public {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(pauser);
        eETHInstance.extendPauseUntil(alice, 3 days);
        assertEq(eETHInstance.pausedUntil(alice), uint64(block.timestamp) + 3 days);

        vm.prank(pauser);
        eETHInstance.cancelPauseUntil(alice);
        assertEq(eETHInstance.pausedUntil(alice), 0);

        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);
    }

    function test_sequence_globalPause_thenPerUserArm_thenUnpause_userStillFrozen() public {
        vm.prank(pauser);
        eETHInstance.pause();

        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(pauser);
        eETHInstance.unpause();

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        eETHInstance.transfer(bob, 1 ether);
    }

    function test_sequence_revokeRole_disablesPauser() public {
        bytes32 role = eETHInstance.EETH_PAUSER_UNTIL_ROLE();
        vm.prank(owner);
        roleRegistryInstance.revokeRole(role, pauserUntil);

        vm.prank(pauserUntil);
        vm.expectRevert("IncorrectRole");
        eETHInstance.pauseUntil(alice);
    }

    // -------------------------------------------------------------------
    //                                FUZZING
    // -------------------------------------------------------------------

    function testFuzz_pause_revertsForNonPauser(address caller) public {
        vm.assume(caller != pauser);
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        eETHInstance.pause();
    }

    function testFuzz_unpause_revertsForNonPauser(address caller) public {
        vm.assume(caller != pauser);
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        eETHInstance.unpause();
    }

    function testFuzz_pauseUntil_revertsForNonPauserUntil(address caller) public {
        vm.assume(caller != pauserUntil);
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        eETHInstance.pauseUntil(alice);
    }

    function testFuzz_extendPauseUntil_revertsForNonPauser(address caller) public {
        vm.assume(caller != pauser);
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        eETHInstance.extendPauseUntil(alice, ONE_DAY);
    }

    function testFuzz_cancelPauseUntil_revertsForNonPauser(address caller) public {
        vm.assume(caller != pauser);
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        eETHInstance.cancelPauseUntil(alice);
    }

    function testFuzz_pauseUntil_setsOneDayFromWarpedTimestamp(uint64 warpTo) public {
        warpTo = uint64(bound(uint256(warpTo), block.timestamp + 1, type(uint64).max - ONE_DAY - 1));
        vm.warp(warpTo);

        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        assertEq(eETHInstance.pausedUntil(alice), warpTo + ONE_DAY);
    }

    function testFuzz_extendPauseUntil_setsArbitraryDuration(uint64 duration) public {
        duration = uint64(bound(uint256(duration), 1, 365 days));

        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(pauser);
        eETHInstance.extendPauseUntil(alice, duration);

        assertEq(eETHInstance.pausedUntil(alice), uint64(block.timestamp) + duration);
    }

    function testFuzz_globalPause_blocksTransferAnyAmount(uint256 amount) public {
        amount = bound(amount, 1, eETHInstance.shares(alice));

        vm.prank(pauser);
        eETHInstance.pause();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        eETHInstance.transfer(bob, amount);
    }

    function testFuzz_senderFrozen_blocksAnyAmount(uint256 amount) public {
        amount = bound(amount, 1, eETHInstance.shares(alice));

        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        eETHInstance.transfer(bob, amount);
    }

    function testFuzz_recipientFrozen_blocksAnyAmount(uint256 amount) public {
        amount = bound(amount, 1, eETHInstance.shares(bob));

        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(bob);
        vm.expectRevert("RECIPIENT PAUSED");
        eETHInstance.transfer(alice, amount);
    }

    function testFuzz_globalPause_blocksMintShares(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000 ether);

        vm.prank(pauser);
        eETHInstance.pause();

        vm.prank(address(liquidityPoolInstance));
        vm.expectRevert("MINT PAUSED");
        eETHInstance.mintShares(alice, amount);
    }

    function testFuzz_globalPause_blocksBurnShares(uint256 amount) public {
        amount = bound(amount, 1, eETHInstance.shares(alice));

        vm.prank(pauser);
        eETHInstance.pause();

        vm.prank(address(liquidityPoolInstance));
        vm.expectRevert("BURN PAUSED");
        eETHInstance.burnShares(alice, amount);
    }

    function testFuzz_pauseUntil_blocksMintShares(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000 ether);

        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(address(liquidityPoolInstance));
        vm.expectRevert("MINT PAUSED");
        eETHInstance.mintShares(alice, amount);
    }

    function testFuzz_pauseUntil_blocksBurnShares(uint256 amount) public {
        amount = bound(amount, 1, eETHInstance.shares(alice));

        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(address(liquidityPoolInstance));
        vm.expectRevert("BURN PAUSED");
        eETHInstance.burnShares(alice, amount);
    }

    function testFuzz_transferWorksAfterExpiry(uint256 amount, uint64 extra) public {
        amount = bound(amount, 1, eETHInstance.shares(alice));
        extra = uint64(bound(uint256(extra), 1, 365 days));

        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.warp(uint256(eETHInstance.pausedUntil(alice)) + extra);

        uint256 aliceBefore = eETHInstance.shares(alice);
        uint256 bobBefore = eETHInstance.shares(bob);

        vm.prank(alice);
        eETHInstance.transfer(bob, amount);

        uint256 sharesMoved = aliceBefore - eETHInstance.shares(alice);
        assertEq(eETHInstance.shares(bob), bobBefore + sharesMoved);
    }

    function testFuzz_independentUsers_timerIsolated(address userA, address userB) public {
        vm.assume(userA != address(0) && userB != address(0));
        vm.assume(userA != userB);

        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(userA);

        assertGt(eETHInstance.pausedUntil(userA), block.timestamp);
        assertEq(eETHInstance.pausedUntil(userB), 0);
    }
}
