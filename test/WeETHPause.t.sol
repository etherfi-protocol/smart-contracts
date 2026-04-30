// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";

/// Unit + fuzz tests for the hybrid pause feature on WeETH.
/// - global `paused` (bool)       : pause() / unpause()                       -> PAUSER_ROLE (strong)
/// - per-user `pausedUntil[u]`    : pauseUntil(user)                          -> PAUSER_UNTIL_ROLE (weak)
///                                : extendPauseUntil(user, duration)          -> PAUSER_ROLE (strong)
///                                : cancelPauseUntil(user)                    -> PAUSER_ROLE (strong)
contract WeETHPauseTest is TestSetup {
    event Paused();
    event PausedUntil(address indexed user, uint256 pausedUntil);
    event CancelledPauseUntil(address indexed user);
    event Unpaused();

    address pauser;
    address pauserUntil;
    address unauthorized;

    uint64 constant ONE_DAY = 1 days;

    function setUp() public {
        setUpTests();

        pauser = vm.addr(0xB0B01);
        pauserUntil = vm.addr(0xB0B02);
        unauthorized = vm.addr(0xB0B03);

        vm.startPrank(owner);
        roleRegistryInstance.grantRole(weEthInstance.WEETH_PAUSER_ROLE(), pauser);
        roleRegistryInstance.grantRole(weEthInstance.WEETH_PAUSER_UNTIL_ROLE(), pauserUntil);
        vm.stopPrank();

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(chad, 100 ether);

        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 20 ether}();
        vm.prank(bob);
        liquidityPoolInstance.deposit{value: 20 ether}();
        vm.prank(chad);
        liquidityPoolInstance.deposit{value: 20 ether}();

        vm.prank(alice);
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        vm.prank(alice);
        weEthInstance.wrap(10 ether);

        vm.prank(bob);
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        vm.prank(bob);
        weEthInstance.wrap(10 ether);

        vm.prank(chad);
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        vm.prank(chad);
        weEthInstance.wrap(10 ether);
    }

    function _grantEETHPauserRole(address to) internal {
        vm.startPrank(owner);
        roleRegistryInstance.grantRole(eETHInstance.EETH_PAUSER_ROLE(), to);
        vm.stopPrank();
    }

    function _grantEETHPauserUntilRole(address to) internal {
        vm.startPrank(owner);
        roleRegistryInstance.grantRole(eETHInstance.EETH_PAUSER_UNTIL_ROLE(), to);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------
    //                          ZERO-ADDRESS GUARDS
    // -------------------------------------------------------------------

    function test_pauseUntil_rejectsZeroAddress() public {
        vm.prank(pauserUntil);
        vm.expectRevert("No zero addresses");
        weEthInstance.pauseUntil(address(0));
    }

    function test_extendPauseUntil_rejectsZeroAddress() public {
        vm.prank(pauser);
        vm.expectRevert("No zero addresses");
        weEthInstance.extendPauseUntil(address(0), ONE_DAY);
    }

    function test_cancelPauseUntil_rejectsZeroAddress() public {
        vm.prank(pauser);
        vm.expectRevert("No zero addresses");
        weEthInstance.cancelPauseUntil(address(0));
    }

    // -------------------------------------------------------------------
    //                               ROLE GATING
    // -------------------------------------------------------------------

    function test_pause_onlyPauserRole() public {
        vm.prank(unauthorized);
        vm.expectRevert("IncorrectRole");
        weEthInstance.pause();

        vm.prank(pauserUntil);
        vm.expectRevert("IncorrectRole");
        weEthInstance.pause();

        vm.prank(pauser);
        weEthInstance.pause();
        assertTrue(weEthInstance.paused());
    }

    function test_pauseUntil_onlyPauserUntilRole() public {
        vm.prank(unauthorized);
        vm.expectRevert("IncorrectRole");
        weEthInstance.pauseUntil(alice);

        vm.prank(pauser);
        vm.expectRevert("IncorrectRole");
        weEthInstance.pauseUntil(alice);

        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        assertEq(weEthInstance.pausedUntil(alice), uint64(block.timestamp) + ONE_DAY);
    }

    function test_extendPauseUntil_onlyPauserRole() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint256 armedAt = block.timestamp;

        vm.prank(unauthorized);
        vm.expectRevert("IncorrectRole");
        weEthInstance.extendPauseUntil(alice, 2 days);

        vm.prank(pauserUntil);
        vm.expectRevert("IncorrectRole");
        weEthInstance.extendPauseUntil(alice, 2 days);

        vm.prank(pauser);
        weEthInstance.extendPauseUntil(alice, 2 days);
        // Extension adds onto the existing deadline (armedAt + ONE_DAY).
        assertEq(weEthInstance.pausedUntil(alice), armedAt + ONE_DAY + 2 days);
    }

    function test_cancelPauseUntil_onlyPauserRole() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);

        vm.prank(unauthorized);
        vm.expectRevert("IncorrectRole");
        weEthInstance.cancelPauseUntil(alice);

        vm.prank(pauserUntil);
        vm.expectRevert("IncorrectRole");
        weEthInstance.cancelPauseUntil(alice);

        vm.prank(pauser);
        weEthInstance.cancelPauseUntil(alice);
        assertEq(weEthInstance.pausedUntil(alice), 0);
    }

    function test_unpause_onlyPauserRole() public {
        vm.prank(pauser);
        weEthInstance.pause();

        vm.prank(unauthorized);
        vm.expectRevert("IncorrectRole");
        weEthInstance.unpause();

        vm.prank(pauserUntil);
        vm.expectRevert("IncorrectRole");
        weEthInstance.unpause();

        vm.prank(pauser);
        weEthInstance.unpause();
        assertFalse(weEthInstance.paused());
    }

    // -------------------------------------------------------------------
    //                     GLOBAL PAUSE SEMANTICS
    // -------------------------------------------------------------------

    function test_globalPause_blocksTransfer() public {
        vm.prank(pauser);
        weEthInstance.pause();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        weEthInstance.transfer(bob, 1 ether);
    }

    function test_globalPause_blocksWrap() public {
        vm.prank(pauser);
        weEthInstance.pause();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        weEthInstance.wrap(1 ether);
    }

    function test_globalPause_blocksUnwrap() public {
        vm.prank(pauser);
        weEthInstance.pause();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        weEthInstance.unwrap(1 ether);
    }

    function test_globalPause_blocksWrapWithPermit() public {
        ILiquidityPool.PermitInput memory p = createPermitInput(
            2, address(weEthInstance), 1 ether, eETHInstance.nonces(alice),
            type(uint256).max, eETHInstance.DOMAIN_SEPARATOR()
        );

        vm.prank(pauser);
        weEthInstance.pause();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        weEthInstance.wrapWithPermit(1 ether, p);
    }

    function test_globalUnpause_restoresFlow() public {
        vm.prank(pauser);
        weEthInstance.pause();

        vm.prank(pauser);
        weEthInstance.unpause();

        vm.prank(alice);
        weEthInstance.transfer(bob, 1 ether);
    }

    /// @dev M-2 carry-over: unpause has no is-paused guard.
    function test_unpause_noop_whenNotPaused() public {
        assertFalse(weEthInstance.paused());
        vm.prank(pauser);
        weEthInstance.unpause();
        assertFalse(weEthInstance.paused());
    }

    // -------------------------------------------------------------------
    //                   WRAP / UNWRAP UNDER PER-USER TIMER
    //              (WeETH side uses _beforeTokenTransfer on _mint/_burn)
    // -------------------------------------------------------------------

    function test_wrap_blockedWhenCallerOnWeETHTimer() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);

        vm.prank(alice);
        // _mint(alice, ...) triggers _beforeTokenTransfer(0, alice, ...); recipient check fires.
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.wrap(1 ether);
    }

    function test_wrap_blockedAtTimerBoundary_onWeETH() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint256 expiry = weEthInstance.pausedUntil(alice);
        vm.warp(expiry);

        vm.prank(alice);
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.wrap(1 ether);
    }

    function test_wrap_worksAfterTimerExpiry_onWeETH() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint256 expiry = weEthInstance.pausedUntil(alice);
        vm.warp(uint256(expiry) + 1);

        vm.prank(alice);
        weEthInstance.wrap(1 ether);
    }

    function test_unwrap_blockedWhenCallerOnWeETHTimer() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);

        vm.prank(alice);
        // _burn(alice, ...) triggers _beforeTokenTransfer(alice, 0, ...); sender check fires.
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.unwrap(1 ether);
    }

    function test_unwrap_blockedAtTimerBoundary_onWeETH() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint256 expiry = weEthInstance.pausedUntil(alice);
        vm.warp(expiry);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.unwrap(1 ether);
    }

    function test_unwrap_worksAfterTimerExpiry_onWeETH() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint256 expiry = weEthInstance.pausedUntil(alice);
        vm.warp(uint256(expiry) + 1);

        vm.prank(alice);
        weEthInstance.unwrap(1 ether);
    }

    // -------------------------------------------------------------------
    //                 WRAP / UNWRAP UNDER CROSS-TOKEN TIMER (eETH side)
    // -------------------------------------------------------------------

    function test_wrap_blockedWhenCallerOnEETHTimer() public {
        _grantEETHPauserUntilRole(pauserUntil);
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.wrap(1 ether);
    }

    function test_unwrap_blockedWhenCallerOnEETHTimer() public {
        _grantEETHPauserUntilRole(pauserUntil);
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(alice);
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.unwrap(1 ether);
    }

    function test_wrap_blockedWhenGlobalPausedOnEETH() public {
        _grantEETHPauserRole(pauserUntil); // reuse the EOA; grant separate strong role on eETH
        vm.prank(pauserUntil);
        eETHInstance.pause();

        vm.prank(alice);
        // wrap path goes through eETH._transferShares which now reverts "PAUSED" (global).
        vm.expectRevert("PAUSED");
        weEthInstance.wrap(1 ether);
    }

    function test_unwrap_blockedWhenGlobalPausedOnEETH() public {
        _grantEETHPauserRole(pauserUntil);
        vm.prank(pauserUntil);
        eETHInstance.pause();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        weEthInstance.unwrap(1 ether);
    }

    function test_weETHFreeze_doesNotTouchEETHTransfers() public {
        vm.prank(pauser);
        weEthInstance.pause();

        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether); // must succeed
    }

    // -------------------------------------------------------------------
    //                     PER-USER TIMER BASIC TRANSFERS
    // -------------------------------------------------------------------

    function test_pauseUntil_blocksSender() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.transfer(bob, 1 ether);
    }

    function test_pauseUntil_blocksRecipient() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);

        vm.prank(bob);
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.transfer(alice, 1 ether);
    }

    function test_pauseUntil_blocksSelfTransfer() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.transfer(alice, 1 ether);
    }

    function test_pauseUntil_isPerUser_othersUnaffected() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);

        vm.prank(bob);
        weEthInstance.transfer(chad, 1 ether);
    }

    function test_pauseUntil_blockedAtBoundary() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint256 expiry = weEthInstance.pausedUntil(alice);
        vm.warp(expiry);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.transfer(bob, 1 ether);
    }

    function test_pauseUntil_expiresAfterOneDay() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint256 expiry = weEthInstance.pausedUntil(alice);

        vm.warp(uint256(expiry) + 1);

        vm.prank(alice);
        weEthInstance.transfer(bob, 1 ether);
    }

    function test_pauseUntil_cannotExtend_whileTimerActive() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint256 firstExpiry = weEthInstance.pausedUntil(alice);

        vm.warp(block.timestamp + 6 hours);

        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);

        assertEq(weEthInstance.pausedUntil(alice), firstExpiry);
    }

    function test_pauseUntil_canRenew_afterExpiry() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint256 firstExpiry = weEthInstance.pausedUntil(alice);

        vm.warp(uint256(firstExpiry) + 1);
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);

        assertGt(weEthInstance.pausedUntil(alice), firstExpiry);
    }

    // -------------------------------------------------------------------
    //                        extendPauseUntil SEMANTICS
    // -------------------------------------------------------------------

    function test_extendPauseUntil_extendsLiveTimer() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint256 armedAt = block.timestamp;

        vm.prank(pauser);
        weEthInstance.extendPauseUntil(alice, 7 days);

        assertEq(weEthInstance.pausedUntil(alice), armedAt + ONE_DAY + 7 days);
    }

    /// @dev I-02 regression: extendPauseUntil must never produce a shorter deadline than the existing one.
    function test_extendPauseUntil_neverShortensTimer() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint256 originalDeadline = weEthInstance.pausedUntil(alice);

        vm.prank(pauser);
        weEthInstance.extendPauseUntil(alice, 1 hours);

        assertGt(weEthInstance.pausedUntil(alice), originalDeadline,
                 "extension must move deadline forward, never shorten (I-02)");
        assertEq(weEthInstance.pausedUntil(alice), originalDeadline + 1 hours);
    }

    function test_extendPauseUntil_silentNoOp_whenTimerExpired() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint256 expiry = weEthInstance.pausedUntil(alice);

        vm.warp(uint256(expiry) + 1);

        vm.prank(pauser);
        weEthInstance.extendPauseUntil(alice, 3 days);

        assertEq(weEthInstance.pausedUntil(alice), expiry, "no-op on expired (M-1-new)");
    }

    function test_extendPauseUntil_silentNoOp_whenNeverArmed() public {
        vm.prank(pauser);
        weEthInstance.extendPauseUntil(alice, 3 days);
        assertEq(weEthInstance.pausedUntil(alice), 0);
    }

    // -------------------------------------------------------------------
    //                        cancelPauseUntil SEMANTICS
    // -------------------------------------------------------------------

    function test_cancelPauseUntil_clearsActiveTimer() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);

        vm.prank(pauser);
        weEthInstance.cancelPauseUntil(alice);

        assertEq(weEthInstance.pausedUntil(alice), 0);

        vm.prank(alice);
        weEthInstance.transfer(bob, 1 ether);
    }

    /// @dev I-03 regression: cancelPauseUntil must not emit when the user was never paused.
    function test_cancelPauseUntil_doesNotEmit_whenNeverArmed() public {
        vm.recordLogs();
        vm.prank(pauser);
        weEthInstance.cancelPauseUntil(alice);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no event when there is nothing to cancel (I-03)");
        assertEq(weEthInstance.pausedUntil(alice), 0);
    }

    /// @dev I-03 regression: cancelPauseUntil is a no-op once the timer has already expired.
    function test_cancelPauseUntil_isNoOp_whenExpired() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint256 staleDeadline = weEthInstance.pausedUntil(alice);
        vm.warp(block.timestamp + 2 days);

        vm.recordLogs();
        vm.prank(pauser);
        weEthInstance.cancelPauseUntil(alice);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0, "no event when timer already expired");
        assertEq(weEthInstance.pausedUntil(alice), staleDeadline, "expired value is left as-is");
    }

    function test_cancelPauseUntil_isPerUser() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(bob);

        vm.prank(pauser);
        weEthInstance.cancelPauseUntil(alice);

        assertEq(weEthInstance.pausedUntil(alice), 0);
        assertGt(weEthInstance.pausedUntil(bob), block.timestamp);
    }

    // -------------------------------------------------------------------
    //                       GLOBAL ⨯ PER-USER INTERACTION
    // -------------------------------------------------------------------

    function test_globalPause_dominatesTimer() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);

        vm.prank(pauser);
        weEthInstance.pause();

        vm.prank(bob);
        vm.expectRevert("PAUSED");
        weEthInstance.transfer(chad, 1 ether);
    }

    function test_globalUnpause_leavesTimerInEffect() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);

        vm.prank(pauser);
        weEthInstance.pause();
        vm.prank(pauser);
        weEthInstance.unpause();

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.transfer(bob, 1 ether);
    }

    // -------------------------------------------------------------------
    //                              EVENTS
    // -------------------------------------------------------------------

    function test_pause_emitsPaused() public {
        vm.expectEmit(false, false, false, true);
        emit Paused();
        vm.prank(pauser);
        weEthInstance.pause();
    }

    function test_unpause_emitsUnpaused() public {
        vm.expectEmit(false, false, false, true);
        emit Unpaused();
        vm.prank(pauser);
        weEthInstance.unpause();
    }

    function test_pauseUntil_emitsIndexedUserAndExpiry() public {
        vm.expectEmit(true, false, false, true);
        emit PausedUntil(alice, uint64(block.timestamp) + ONE_DAY);
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
    }

    function test_extendPauseUntil_emitsPausedUntil_whenActive() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);

        uint64 expected = uint64(block.timestamp) + ONE_DAY + 3 days;
        vm.expectEmit(true, false, false, true);
        emit PausedUntil(alice, expected);
        vm.prank(pauser);
        weEthInstance.extendPauseUntil(alice, 3 days);
    }

    function test_cancelPauseUntil_emitsCancelledPauseUntil() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);

        vm.expectEmit(true, false, false, true);
        emit CancelledPauseUntil(alice);
        vm.prank(pauser);
        weEthInstance.cancelPauseUntil(alice);
    }

    // -------------------------------------------------------------------
    //                     NON-TRANSFER PATHS DURING FREEZE
    // -------------------------------------------------------------------

    function test_approve_worksDuringGlobalPause() public {
        vm.prank(pauser);
        weEthInstance.pause();

        vm.prank(alice);
        weEthInstance.approve(bob, 1 ether);
        assertEq(weEthInstance.allowance(alice, bob), 1 ether);
    }

    function test_getters_workWhileFrozen() public {
        vm.prank(pauser);
        weEthInstance.pause();

        weEthInstance.getRate();
        weEthInstance.getEETHByWeETH(1 ether);
        weEthInstance.getWeETHByeETH(1 ether);
        weEthInstance.balanceOf(alice);
    }

    // -------------------------------------------------------------------
    //                                FUZZING
    // -------------------------------------------------------------------

    function testFuzz_pause_revertsForNonPauser(address caller) public {
        vm.assume(caller != pauser);
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        weEthInstance.pause();
    }

    function testFuzz_unpause_revertsForNonPauser(address caller) public {
        vm.assume(caller != pauser);
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        weEthInstance.unpause();
    }

    function testFuzz_pauseUntil_revertsForNonPauserUntil(address caller) public {
        vm.assume(caller != pauserUntil);
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        weEthInstance.pauseUntil(alice);
    }

    function testFuzz_extendPauseUntil_revertsForNonPauser(address caller) public {
        vm.assume(caller != pauser);
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        weEthInstance.extendPauseUntil(alice, ONE_DAY);
    }

    function testFuzz_cancelPauseUntil_revertsForNonPauser(address caller) public {
        vm.assume(caller != pauser);
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        weEthInstance.cancelPauseUntil(alice);
    }

    function testFuzz_pauseUntil_setsOneDayFromWarpedTimestamp(uint64 warpTo) public {
        warpTo = uint64(bound(uint256(warpTo), block.timestamp + 1, type(uint64).max - ONE_DAY - 1));
        vm.warp(warpTo);

        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);

        assertEq(weEthInstance.pausedUntil(alice), warpTo + ONE_DAY);
    }

    function testFuzz_extendPauseUntil_setsArbitraryDuration(uint64 duration) public {
        duration = uint64(bound(uint256(duration), 1, 365 days));

        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint256 originalDeadline = weEthInstance.pausedUntil(alice);

        vm.prank(pauser);
        weEthInstance.extendPauseUntil(alice, duration);

        assertEq(weEthInstance.pausedUntil(alice), originalDeadline + duration);
    }

    function testFuzz_globalPause_blocksTransferAnyAmount(uint256 amount) public {
        amount = bound(amount, 1, weEthInstance.balanceOf(alice));

        vm.prank(pauser);
        weEthInstance.pause();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        weEthInstance.transfer(bob, amount);
    }

    function testFuzz_globalPause_blocksWrap(uint256 amount) public {
        amount = bound(amount, 1, eETHInstance.balanceOf(alice));

        vm.prank(pauser);
        weEthInstance.pause();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        weEthInstance.wrap(amount);
    }

    function testFuzz_globalPause_blocksUnwrap(uint256 amount) public {
        amount = bound(amount, 1, weEthInstance.balanceOf(alice));

        vm.prank(pauser);
        weEthInstance.pause();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        weEthInstance.unwrap(amount);
    }

    function testFuzz_senderTimer_blocksAnyAmount(uint256 amount) public {
        amount = bound(amount, 1, weEthInstance.balanceOf(alice));

        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.transfer(bob, amount);
    }

    function testFuzz_recipientTimer_blocksAnyAmount(uint256 amount) public {
        amount = bound(amount, 1, weEthInstance.balanceOf(bob));

        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);

        vm.prank(bob);
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.transfer(alice, amount);
    }

    function testFuzz_wrapBlockedUnderPauseUntil_onWeETH(uint256 amount, uint64 delta) public {
        amount = bound(amount, 1, eETHInstance.balanceOf(alice));
        delta = uint64(bound(uint256(delta), 0, ONE_DAY));

        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint256 expiry = weEthInstance.pausedUntil(alice);
        vm.warp(uint256(expiry) - delta);

        vm.prank(alice);
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.wrap(amount);
    }

    function testFuzz_unwrapBlockedUnderPauseUntil_onWeETH(uint256 amount, uint64 delta) public {
        amount = bound(amount, 1, weEthInstance.balanceOf(alice));
        delta = uint64(bound(uint256(delta), 0, ONE_DAY));

        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint256 expiry = weEthInstance.pausedUntil(alice);
        vm.warp(uint256(expiry) - delta);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.unwrap(amount);
    }

    function testFuzz_independentUsers_timerIsolated(address userA, address userB) public {
        vm.assume(userA != address(0) && userB != address(0));
        vm.assume(userA != userB);

        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(userA);

        assertGt(weEthInstance.pausedUntil(userA), block.timestamp);
        assertEq(weEthInstance.pausedUntil(userB), 0);
    }
}
