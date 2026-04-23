// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";

/// Unit + fuzz tests for the per-user FREEZE feature on WeETH.
/// Role model:
///   WEETH_PAUSER_ROLE         -> monitoring EOA   : pauseUntil(user) arms 1-day freeze
///   WEETH_EXTEND_PAUSER_ROLE  -> security council : pause(user) / unpause(user)
///
/// WeETH uses `_beforeTokenTransfer`, which fires on `_mint`/`_burn` too — so a freeze
/// on either party blocks transfer, wrap (mint), and unwrap (burn).
contract WeETHPauseTest is TestSetup {
    event Paused(address indexed user);
    event PausedUntil(address indexed user, uint64 pausedUntil);
    event Unpaused(address indexed user);

    address pauser;
    address extendPauser;
    address unauthorized;

    uint64 constant ONE_DAY = 1 days;

    function setUp() public {
        setUpTests();

        pauser = vm.addr(0xB0B01);
        extendPauser = vm.addr(0xB0B02);
        unauthorized = vm.addr(0xB0B03);

        vm.startPrank(owner);
        roleRegistryInstance.grantRole(weEthInstance.WEETH_PAUSER_ROLE(), pauser);
        roleRegistryInstance.grantRole(weEthInstance.WEETH_EXTEND_PAUSER_ROLE(), extendPauser);
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

    // -------------------------------------------------------------------
    //                          ZERO-ADDRESS GUARDS
    // -------------------------------------------------------------------

    function test_pause_rejectsZeroAddress() public {
        vm.prank(extendPauser);
        vm.expectRevert("No zero addresses");
        weEthInstance.pause(address(0));
    }

    function test_pauseUntil_rejectsZeroAddress() public {
        vm.prank(pauser);
        vm.expectRevert("No zero addresses");
        weEthInstance.pauseUntil(address(0));
    }

    function test_unpause_rejectsZeroAddress() public {
        vm.prank(extendPauser);
        vm.expectRevert("No zero addresses");
        weEthInstance.unpause(address(0));
    }

    // -------------------------------------------------------------------
    //                               ROLE GATING
    // -------------------------------------------------------------------

    function test_pause_onlyExtendPauserRole() public {
        vm.prank(unauthorized);
        vm.expectRevert("IncorrectRole");
        weEthInstance.pause(alice);

        vm.prank(pauser);
        vm.expectRevert("IncorrectRole");
        weEthInstance.pause(alice);

        vm.prank(extendPauser);
        weEthInstance.pause(alice);
        assertTrue(weEthInstance.paused(alice));
    }

    function test_pauseUntil_onlyPauserRole() public {
        vm.prank(unauthorized);
        vm.expectRevert("IncorrectRole");
        weEthInstance.pauseUntil(alice);

        vm.prank(extendPauser);
        vm.expectRevert("IncorrectRole");
        weEthInstance.pauseUntil(alice);

        vm.prank(pauser);
        weEthInstance.pauseUntil(alice);
        assertEq(weEthInstance.pausedUntil(alice), uint64(block.timestamp) + ONE_DAY);
    }

    function test_unpause_onlyExtendPauserRole() public {
        vm.prank(extendPauser);
        weEthInstance.pause(alice);

        vm.prank(unauthorized);
        vm.expectRevert("IncorrectRole");
        weEthInstance.unpause(alice);

        vm.prank(pauser);
        vm.expectRevert("IncorrectRole");
        weEthInstance.unpause(alice);

        vm.prank(extendPauser);
        weEthInstance.unpause(alice);
        assertFalse(weEthInstance.paused(alice));
    }

    // -------------------------------------------------------------------
    //                      PER-USER FREEZE SELECTIVITY
    // -------------------------------------------------------------------

    function test_freeze_isPerUser_othersUnaffected() public {
        vm.prank(extendPauser);
        weEthInstance.pause(alice);

        vm.prank(bob);
        weEthInstance.transfer(chad, 1 ether);
        vm.prank(chad);
        weEthInstance.transfer(bob, 1 ether);
    }

    function test_freeze_blocksSender() public {
        vm.prank(extendPauser);
        weEthInstance.pause(alice);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.transfer(bob, 1 ether);
    }

    function test_freeze_blocksRecipient() public {
        vm.prank(extendPauser);
        weEthInstance.pause(alice);

        vm.prank(bob);
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.transfer(alice, 1 ether);
    }

    function test_freeze_blocksSelfTransfer() public {
        vm.prank(extendPauser);
        weEthInstance.pause(alice);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.transfer(alice, 1 ether);
    }

    function test_freeze_blocksTransferFrom_viaSender() public {
        vm.prank(alice);
        weEthInstance.approve(bob, 1 ether);

        vm.prank(extendPauser);
        weEthInstance.pause(alice);

        vm.prank(bob);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.transferFrom(alice, chad, 1 ether);
    }

    function test_freeze_blocksTransferFrom_viaRecipient() public {
        vm.prank(alice);
        weEthInstance.approve(bob, 1 ether);

        vm.prank(extendPauser);
        weEthInstance.pause(chad);

        vm.prank(bob);
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.transferFrom(alice, chad, 1 ether);
    }

    // -------------------------------------------------------------------
    //                  WRAP / UNWRAP UNDER FREEZE (WeETH side)
    // -------------------------------------------------------------------

    /// @dev Frozen on WeETH -> wrap fails at _mint's _beforeTokenTransfer (recipient check).
    function test_wrap_blocked_whenCallerFrozenOnWeETH() public {
        vm.prank(extendPauser);
        weEthInstance.pause(alice);

        vm.prank(alice);
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.wrap(1 ether);
    }

    /// @dev Frozen on WeETH -> unwrap fails at _burn's _beforeTokenTransfer (sender check).
    function test_unwrap_blocked_whenCallerFrozenOnWeETH() public {
        vm.prank(extendPauser);
        weEthInstance.pause(alice);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.unwrap(1 ether);
    }

    function test_wrapWithPermit_blocked_whenCallerFrozenOnWeETH() public {
        ILiquidityPool.PermitInput memory p = createPermitInput(
            2, address(weEthInstance), 1 ether, eETHInstance.nonces(alice),
            type(uint256).max, eETHInstance.DOMAIN_SEPARATOR()
        );

        vm.prank(extendPauser);
        weEthInstance.pause(alice);

        vm.prank(alice);
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.wrapWithPermit(1 ether, p);
    }

    // -------------------------------------------------------------------
    //       CROSS-TOKEN FREEZE — eETH freeze affects WeETH flows
    // -------------------------------------------------------------------

    /// @dev Frozen on eETH -> wrap fails at eETH.transferFrom (sender check on eETH side).
    function test_wrap_blocked_whenCallerFrozenOnEETH() public {
        vm.startPrank(owner);
        roleRegistryInstance.grantRole(eETHInstance.EETH_EXTEND_PAUSER_ROLE(), extendPauser);
        vm.stopPrank();

        vm.prank(extendPauser);
        eETHInstance.pause(alice);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.wrap(1 ether);
    }

    /// @dev Frozen on eETH -> unwrap fails at eETH.transfer (recipient check on eETH side).
    function test_unwrap_blocked_whenCallerFrozenOnEETH() public {
        vm.startPrank(owner);
        roleRegistryInstance.grantRole(eETHInstance.EETH_EXTEND_PAUSER_ROLE(), extendPauser);
        vm.stopPrank();

        vm.prank(extendPauser);
        eETHInstance.pause(alice);

        vm.prank(alice);
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.unwrap(1 ether);
    }

    /// @dev Freezing WeETH on its own account on eETH bricks wrap for EVERYONE (C-2 hazard).
    function test_SECURITY_freezingWeETHOnEETH_bricksWrapForAll() public {
        vm.startPrank(owner);
        roleRegistryInstance.grantRole(eETHInstance.EETH_EXTEND_PAUSER_ROLE(), extendPauser);
        vm.stopPrank();

        // Security council accidentally freezes the weETH contract's eETH account.
        vm.prank(extendPauser);
        eETHInstance.pause(address(weEthInstance));

        // Bob (not frozen) can no longer wrap because eETH.transferFrom routes tokens
        // TO address(weEthInstance), which is now frozen on eETH.
        vm.prank(bob);
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.wrap(1 ether);
    }

    /// @dev Same hazard for unwrap.
    function test_SECURITY_freezingWeETHOnEETH_bricksUnwrapForAll() public {
        vm.startPrank(owner);
        roleRegistryInstance.grantRole(eETHInstance.EETH_EXTEND_PAUSER_ROLE(), extendPauser);
        vm.stopPrank();

        vm.prank(extendPauser);
        eETHInstance.pause(address(weEthInstance));

        vm.prank(bob);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.unwrap(1 ether);
    }

    /// @dev Freeze on weETH does NOT restrict user's eETH activity.
    function test_weETHFreeze_doesNotTouchEETH() public {
        vm.prank(extendPauser);
        weEthInstance.pause(alice);

        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether); // must succeed
    }

    // -------------------------------------------------------------------
    //                       TIMER SEMANTICS (WeETH)
    // -------------------------------------------------------------------

    function test_pauseUntil_expiresAfterOneDay() public {
        vm.prank(pauser);
        weEthInstance.pauseUntil(alice);
        uint64 expiry = weEthInstance.pausedUntil(alice);

        vm.warp(uint256(expiry) + 1);

        vm.prank(alice);
        weEthInstance.transfer(bob, 1 ether);
    }

    function test_pauseUntil_blockedAtBoundary() public {
        vm.prank(pauser);
        weEthInstance.pauseUntil(alice);
        uint64 expiry = weEthInstance.pausedUntil(alice);
        vm.warp(expiry);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.transfer(bob, 1 ether);
    }

    function test_pauseUntil_silentNoOp_whilePaused() public {
        vm.prank(extendPauser);
        weEthInstance.pause(alice);
        uint64 before = weEthInstance.pausedUntil(alice);

        vm.prank(pauser);
        weEthInstance.pauseUntil(alice);

        assertEq(weEthInstance.pausedUntil(alice), before);
        assertTrue(weEthInstance.paused(alice));
    }

    function test_pauseUntil_cannotExtend_whileTimerActive() public {
        vm.prank(pauser);
        weEthInstance.pauseUntil(alice);
        uint64 firstExpiry = weEthInstance.pausedUntil(alice);

        vm.warp(block.timestamp + 6 hours);

        vm.prank(pauser);
        weEthInstance.pauseUntil(alice);

        assertEq(weEthInstance.pausedUntil(alice), firstExpiry);
    }

    function test_pauseUntil_canRenew_afterExpiry() public {
        vm.prank(pauser);
        weEthInstance.pauseUntil(alice);
        uint64 firstExpiry = weEthInstance.pausedUntil(alice);

        vm.warp(uint256(firstExpiry) + 1);
        vm.prank(pauser);
        weEthInstance.pauseUntil(alice);

        assertGt(weEthInstance.pausedUntil(alice), firstExpiry);
    }

    // -------------------------------------------------------------------
    //                            UNPAUSE SEMANTICS
    // -------------------------------------------------------------------

    function test_unpause_clearsBothFlags_whenFullyFrozen() public {
        vm.prank(pauser);
        weEthInstance.pauseUntil(alice);
        vm.prank(extendPauser);
        weEthInstance.pause(alice);

        assertTrue(weEthInstance.paused(alice));
        assertGt(weEthInstance.pausedUntil(alice), block.timestamp);

        vm.prank(extendPauser);
        weEthInstance.unpause(alice);

        assertFalse(weEthInstance.paused(alice));
        assertEq(weEthInstance.pausedUntil(alice), 0);

        vm.prank(alice);
        weEthInstance.transfer(bob, 1 ether);
    }

    function test_unpause_afterExpiry_leavesStaleTimer() public {
        vm.prank(pauser);
        weEthInstance.pauseUntil(alice);
        uint64 expiry = weEthInstance.pausedUntil(alice);

        vm.warp(uint256(expiry) + 1);

        vm.prank(extendPauser);
        weEthInstance.unpause(alice);

        assertEq(weEthInstance.pausedUntil(alice), expiry, "stale expiry remains (M-2)");
        assertFalse(weEthInstance.paused(alice));
    }

    function test_unpause_noop_whenNeverPaused() public {
        vm.prank(extendPauser);
        weEthInstance.unpause(alice);
        assertFalse(weEthInstance.paused(alice));
        assertEq(weEthInstance.pausedUntil(alice), 0);
    }

    // -------------------------------------------------------------------
    //                              EVENTS
    // -------------------------------------------------------------------

    function test_pause_emitsIndexedUser() public {
        vm.expectEmit(true, false, false, true);
        emit Paused(alice);
        vm.prank(extendPauser);
        weEthInstance.pause(alice);
    }

    function test_pauseUntil_emitsIndexedUserAndExpiry() public {
        vm.expectEmit(true, false, false, true);
        emit PausedUntil(alice, uint64(block.timestamp) + ONE_DAY);
        vm.prank(pauser);
        weEthInstance.pauseUntil(alice);
    }

    function test_unpause_emitsIndexedUser() public {
        vm.expectEmit(true, false, false, true);
        emit Unpaused(alice);
        vm.prank(extendPauser);
        weEthInstance.unpause(alice);
    }

    // -------------------------------------------------------------------
    //                     NON-TRANSFER PATHS DURING FREEZE
    // -------------------------------------------------------------------

    function test_approve_notBlockedByFreeze() public {
        vm.prank(extendPauser);
        weEthInstance.pause(alice);

        vm.prank(alice);
        weEthInstance.approve(bob, 1 ether);
        assertEq(weEthInstance.allowance(alice, bob), 1 ether);
    }

    function test_getters_workWhileFrozen() public {
        vm.prank(extendPauser);
        weEthInstance.pause(alice);

        weEthInstance.getRate();
        weEthInstance.getEETHByWeETH(1 ether);
        weEthInstance.getWeETHByeETH(1 ether);
        weEthInstance.balanceOf(alice);
    }

    // -------------------------------------------------------------------
    //                               FUZZING
    // -------------------------------------------------------------------

    function testFuzz_pause_revertsForNonExtendPauser(address caller) public {
        vm.assume(caller != extendPauser);
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        weEthInstance.pause(alice);
    }

    function testFuzz_pauseUntil_revertsForNonPauser(address caller) public {
        vm.assume(caller != pauser);
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        weEthInstance.pauseUntil(alice);
    }

    function testFuzz_unpause_revertsForNonExtendPauser(address caller) public {
        vm.assume(caller != extendPauser);
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        weEthInstance.unpause(alice);
    }

    function testFuzz_pauseUntil_setsOneDayFromWarpedTimestamp(uint64 warpTo) public {
        warpTo = uint64(bound(uint256(warpTo), block.timestamp + 1, type(uint64).max - ONE_DAY - 1));
        vm.warp(warpTo);

        vm.prank(pauser);
        weEthInstance.pauseUntil(alice);

        assertEq(weEthInstance.pausedUntil(alice), warpTo + ONE_DAY);
    }

    function testFuzz_senderFrozen_blocksAnyAmount(uint256 amount) public {
        amount = bound(amount, 1, weEthInstance.balanceOf(alice));

        vm.prank(extendPauser);
        weEthInstance.pause(alice);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.transfer(bob, amount);
    }

    function testFuzz_recipientFrozen_blocksAnyAmount(uint256 amount) public {
        amount = bound(amount, 1, weEthInstance.balanceOf(bob));

        vm.prank(extendPauser);
        weEthInstance.pause(alice);

        vm.prank(bob);
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.transfer(alice, amount);
    }

    function testFuzz_wrapBlockedWhenFrozen(uint256 amount) public {
        amount = bound(amount, 1, eETHInstance.balanceOf(alice));

        vm.prank(extendPauser);
        weEthInstance.pause(alice);

        vm.prank(alice);
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.wrap(amount);
    }

    function testFuzz_unwrapBlockedWhenFrozen(uint256 amount) public {
        amount = bound(amount, 1, weEthInstance.balanceOf(alice));

        vm.prank(extendPauser);
        weEthInstance.pause(alice);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.unwrap(amount);
    }

    function testFuzz_unfrozenUsers_unaffected(uint256 amount) public {
        amount = bound(amount, 1, weEthInstance.balanceOf(bob));

        vm.prank(extendPauser);
        weEthInstance.pause(alice);

        uint256 bobBefore = weEthInstance.balanceOf(bob);
        uint256 chadBefore = weEthInstance.balanceOf(chad);

        vm.prank(bob);
        weEthInstance.transfer(chad, amount);

        assertEq(weEthInstance.balanceOf(bob), bobBefore - amount);
        assertEq(weEthInstance.balanceOf(chad), chadBefore + amount);
    }

    function testFuzz_independentUsers_freezeIsolated(address userA, address userB) public {
        vm.assume(userA != address(0) && userB != address(0));
        vm.assume(userA != userB);

        vm.prank(extendPauser);
        weEthInstance.pause(userA);

        assertTrue(weEthInstance.paused(userA));
        assertFalse(weEthInstance.paused(userB));
    }
}
