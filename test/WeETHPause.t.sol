// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";

/// Unit + fuzz tests for the per-user FREEZE feature on WeETH.
/// Role model (post-rename):
///   WEETH_PAUSER_ROLE        -> security council : pause(user) / unpause(user) (strong)
///   WEETH_PAUSER_UNTIL_ROLE  -> monitoring EOA   : pauseUntil(user) arms 1-day freeze
///
/// WeETH uses `_beforeTokenTransfer`, which fires on `_mint`/`_burn` too — so a freeze
/// on either party blocks transfer, wrap (mint), and unwrap (burn).
contract WeETHPauseTest is TestSetup {
    event Paused(address indexed user);
    event PausedUntil(address indexed user, uint64 pausedUntil);
    event Unpaused(address indexed user);

    address pauser;        // WEETH_PAUSER_ROLE (strong)
    address pauserUntil;   // WEETH_PAUSER_UNTIL_ROLE (weak)
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

    /// @dev Shared helper — grants eETH pause role to a council address so tests can
    /// exercise cross-token freeze interactions without repeating the dance.
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

    function test_pause_rejectsZeroAddress() public {
        vm.prank(pauser);
        vm.expectRevert("No zero addresses");
        weEthInstance.pause(address(0));
    }

    function test_pauseUntil_rejectsZeroAddress() public {
        vm.prank(pauserUntil);
        vm.expectRevert("No zero addresses");
        weEthInstance.pauseUntil(address(0));
    }

    function test_unpause_rejectsZeroAddress() public {
        vm.prank(pauser);
        vm.expectRevert("No zero addresses");
        weEthInstance.unpause(address(0));
    }

    // -------------------------------------------------------------------
    //                               ROLE GATING
    // -------------------------------------------------------------------

    function test_pause_onlyPauserRole() public {
        vm.prank(unauthorized);
        vm.expectRevert("IncorrectRole");
        weEthInstance.pause(alice);

        vm.prank(pauserUntil);
        vm.expectRevert("IncorrectRole");
        weEthInstance.pause(alice);

        vm.prank(pauser);
        weEthInstance.pause(alice);
        assertTrue(weEthInstance.paused(alice));
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

    function test_unpause_onlyPauserRole() public {
        vm.prank(pauser);
        weEthInstance.pause(alice);

        vm.prank(unauthorized);
        vm.expectRevert("IncorrectRole");
        weEthInstance.unpause(alice);

        vm.prank(pauserUntil);
        vm.expectRevert("IncorrectRole");
        weEthInstance.unpause(alice);

        vm.prank(pauser);
        weEthInstance.unpause(alice);
        assertFalse(weEthInstance.paused(alice));
    }

    // -------------------------------------------------------------------
    //                     PER-USER FREEZE SELECTIVITY
    // -------------------------------------------------------------------

    function test_freeze_isPerUser_othersUnaffected() public {
        vm.prank(pauser);
        weEthInstance.pause(alice);

        vm.prank(bob);
        weEthInstance.transfer(chad, 1 ether);
        vm.prank(chad);
        weEthInstance.transfer(bob, 1 ether);
    }

    function test_freeze_blocksSender() public {
        vm.prank(pauser);
        weEthInstance.pause(alice);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.transfer(bob, 1 ether);
    }

    function test_freeze_blocksRecipient() public {
        vm.prank(pauser);
        weEthInstance.pause(alice);

        vm.prank(bob);
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.transfer(alice, 1 ether);
    }

    function test_freeze_blocksSelfTransfer() public {
        vm.prank(pauser);
        weEthInstance.pause(alice);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.transfer(alice, 1 ether);
    }

    function test_freeze_blocksTransferFrom_viaSender() public {
        vm.prank(alice);
        weEthInstance.approve(bob, 1 ether);

        vm.prank(pauser);
        weEthInstance.pause(alice);

        vm.prank(bob);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.transferFrom(alice, chad, 1 ether);
    }

    function test_freeze_blocksTransferFrom_viaRecipient() public {
        vm.prank(alice);
        weEthInstance.approve(bob, 1 ether);

        vm.prank(pauser);
        weEthInstance.pause(chad);

        vm.prank(bob);
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.transferFrom(alice, chad, 1 ether);
    }

    // -------------------------------------------------------------------
    //           WRAP UNDER FREEZE — weETH side (_beforeTokenTransfer)
    // -------------------------------------------------------------------

    /// @dev pause() on WeETH -> wrap reverts at _mint's _beforeTokenTransfer.
    function test_wrap_blocked_whenCallerFrozenOnWeETH() public {
        vm.prank(pauser);
        weEthInstance.pause(alice);

        vm.prank(alice);
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.wrap(1 ether);
    }

    /// @dev pauseUntil() on WeETH -> wrap reverts while timer active.
    function test_wrap_blocked_underPauseUntil_onWeETH() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);

        vm.prank(alice);
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.wrap(1 ether);
    }

    function test_wrap_blockedAtPauseUntilBoundary_onWeETH() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint64 expiry = weEthInstance.pausedUntil(alice);
        vm.warp(expiry);

        vm.prank(alice);
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.wrap(1 ether);
    }

    function test_wrap_worksAfterPauseUntilExpiry_onWeETH() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint64 expiry = weEthInstance.pausedUntil(alice);
        vm.warp(uint256(expiry) + 1);

        vm.prank(alice);
        weEthInstance.wrap(1 ether);
    }

    function test_wrapWithPermit_blocked_whenCallerFrozenOnWeETH() public {
        ILiquidityPool.PermitInput memory p = createPermitInput(
            2, address(weEthInstance), 1 ether, eETHInstance.nonces(alice),
            type(uint256).max, eETHInstance.DOMAIN_SEPARATOR()
        );

        vm.prank(pauser);
        weEthInstance.pause(alice);

        vm.prank(alice);
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.wrapWithPermit(1 ether, p);
    }

    function test_wrapWithPermit_blocked_underPauseUntil_onWeETH() public {
        ILiquidityPool.PermitInput memory p = createPermitInput(
            2, address(weEthInstance), 1 ether, eETHInstance.nonces(alice),
            type(uint256).max, eETHInstance.DOMAIN_SEPARATOR()
        );

        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);

        vm.prank(alice);
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.wrapWithPermit(1 ether, p);
    }

    // -------------------------------------------------------------------
    //                        UNWRAP UNDER FREEZE — weETH side
    // -------------------------------------------------------------------

    function test_unwrap_blocked_whenCallerFrozenOnWeETH() public {
        vm.prank(pauser);
        weEthInstance.pause(alice);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.unwrap(1 ether);
    }

    function test_unwrap_blocked_underPauseUntil_onWeETH() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.unwrap(1 ether);
    }

    function test_unwrap_blockedAtPauseUntilBoundary_onWeETH() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint64 expiry = weEthInstance.pausedUntil(alice);
        vm.warp(expiry);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.unwrap(1 ether);
    }

    function test_unwrap_worksAfterPauseUntilExpiry_onWeETH() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint64 expiry = weEthInstance.pausedUntil(alice);
        vm.warp(uint256(expiry) + 1);

        vm.prank(alice);
        weEthInstance.unwrap(1 ether);
    }

    // -------------------------------------------------------------------
    //     CROSS-TOKEN FREEZE — freeze on eETH propagates to WeETH flows
    // -------------------------------------------------------------------

    function test_wrap_blocked_whenCallerFrozenOnEETH() public {
        _grantEETHPauserRole(pauser);
        vm.prank(pauser);
        eETHInstance.pause(alice);

        vm.prank(alice);
        // wrap's eETH.transferFrom fails before weETH._mint runs, because mintShares
        // routes through _transferShares (sender=alice is frozen on eETH).
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.wrap(1 ether);
    }

    function test_wrap_blocked_underPauseUntil_onEETH() public {
        _grantEETHPauserUntilRole(pauserUntil);
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.wrap(1 ether);
    }

    function test_unwrap_blocked_whenCallerFrozenOnEETH() public {
        _grantEETHPauserRole(pauser);
        vm.prank(pauser);
        eETHInstance.pause(alice);

        vm.prank(alice);
        // weETH._burn succeeds (msg.sender frozen on eETH, not weETH), but the
        // subsequent eETH.transfer(alice, ...) fails with recipient=alice frozen.
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.unwrap(1 ether);
    }

    function test_unwrap_blocked_underPauseUntil_onEETH() public {
        _grantEETHPauserUntilRole(pauserUntil);
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(alice);

        vm.prank(alice);
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.unwrap(1 ether);
    }

    /// @dev C-2: freezing the WeETH contract's own eETH account bricks wrap for all.
    function test_SECURITY_freezingWeETHOnEETH_bricksWrapForAll() public {
        _grantEETHPauserRole(pauser);
        vm.prank(pauser);
        eETHInstance.pause(address(weEthInstance));

        vm.prank(bob); // bob is NOT frozen on either token
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.wrap(1 ether);
    }

    function test_SECURITY_freezingWeETHOnEETH_bricksUnwrapForAll() public {
        _grantEETHPauserRole(pauser);
        vm.prank(pauser);
        eETHInstance.pause(address(weEthInstance));

        vm.prank(bob);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.unwrap(1 ether);
    }

    function test_weETHFreeze_doesNotTouchEETH() public {
        vm.prank(pauser);
        weEthInstance.pause(alice);

        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether); // must succeed
    }

    // -------------------------------------------------------------------
    //                       TIMER SEMANTICS (WeETH)
    // -------------------------------------------------------------------

    function test_pauseUntil_expiresAfterOneDay() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint64 expiry = weEthInstance.pausedUntil(alice);

        vm.warp(uint256(expiry) + 1);

        vm.prank(alice);
        weEthInstance.transfer(bob, 1 ether);
    }

    function test_pauseUntil_blockedAtBoundary() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint64 expiry = weEthInstance.pausedUntil(alice);
        vm.warp(expiry);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.transfer(bob, 1 ether);
    }

    function test_pauseUntil_silentNoOp_whilePaused() public {
        vm.prank(pauser);
        weEthInstance.pause(alice);
        uint64 before = weEthInstance.pausedUntil(alice);

        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);

        assertEq(weEthInstance.pausedUntil(alice), before);
        assertTrue(weEthInstance.paused(alice));
    }

    function test_pauseUntil_cannotExtend_whileTimerActive() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint64 firstExpiry = weEthInstance.pausedUntil(alice);

        vm.warp(block.timestamp + 6 hours);

        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);

        assertEq(weEthInstance.pausedUntil(alice), firstExpiry);
    }

    function test_pauseUntil_canRenew_afterExpiry() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint64 firstExpiry = weEthInstance.pausedUntil(alice);

        vm.warp(uint256(firstExpiry) + 1);
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);

        assertGt(weEthInstance.pausedUntil(alice), firstExpiry);
    }

    // -------------------------------------------------------------------
    //                            UNPAUSE SEMANTICS
    // -------------------------------------------------------------------

    function test_unpause_clearsBothFlags_whenFullyFrozen() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        vm.prank(pauser);
        weEthInstance.pause(alice);

        assertTrue(weEthInstance.paused(alice));
        assertGt(weEthInstance.pausedUntil(alice), block.timestamp);

        vm.prank(pauser);
        weEthInstance.unpause(alice);

        assertFalse(weEthInstance.paused(alice));
        assertEq(weEthInstance.pausedUntil(alice), 0);

        vm.prank(alice);
        weEthInstance.transfer(bob, 1 ether);
    }

    function test_unpause_afterExpiry_leavesStaleTimer() public {
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint64 expiry = weEthInstance.pausedUntil(alice);

        vm.warp(uint256(expiry) + 1);

        vm.prank(pauser);
        weEthInstance.unpause(alice);

        assertEq(weEthInstance.pausedUntil(alice), expiry, "stale expiry remains (M-2)");
        assertFalse(weEthInstance.paused(alice));
    }

    function test_unpause_noop_whenNeverPaused() public {
        vm.prank(pauser);
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
        vm.prank(pauser);
        weEthInstance.pause(alice);
    }

    function test_pauseUntil_emitsIndexedUserAndExpiry() public {
        vm.expectEmit(true, false, false, true);
        emit PausedUntil(alice, uint64(block.timestamp) + ONE_DAY);
        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
    }

    function test_unpause_emitsIndexedUser() public {
        vm.expectEmit(true, false, false, true);
        emit Unpaused(alice);
        vm.prank(pauser);
        weEthInstance.unpause(alice);
    }

    // -------------------------------------------------------------------
    //                     NON-TRANSFER PATHS DURING FREEZE
    // -------------------------------------------------------------------

    function test_approve_notBlockedByFreeze() public {
        vm.prank(pauser);
        weEthInstance.pause(alice);

        vm.prank(alice);
        weEthInstance.approve(bob, 1 ether);
        assertEq(weEthInstance.allowance(alice, bob), 1 ether);
    }

    function test_getters_workWhileFrozen() public {
        vm.prank(pauser);
        weEthInstance.pause(alice);

        weEthInstance.getRate();
        weEthInstance.getEETHByWeETH(1 ether);
        weEthInstance.getWeETHByeETH(1 ether);
        weEthInstance.balanceOf(alice);
    }

    // -------------------------------------------------------------------
    //                               FUZZING
    // -------------------------------------------------------------------

    function testFuzz_pause_revertsForNonPauser(address caller) public {
        vm.assume(caller != pauser);
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        weEthInstance.pause(alice);
    }

    function testFuzz_pauseUntil_revertsForNonPauserUntil(address caller) public {
        vm.assume(caller != pauserUntil);
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        weEthInstance.pauseUntil(alice);
    }

    function testFuzz_unpause_revertsForNonPauser(address caller) public {
        vm.assume(caller != pauser);
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        weEthInstance.unpause(alice);
    }

    function testFuzz_pauseUntil_setsOneDayFromWarpedTimestamp(uint64 warpTo) public {
        warpTo = uint64(bound(uint256(warpTo), block.timestamp + 1, type(uint64).max - ONE_DAY - 1));
        vm.warp(warpTo);

        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);

        assertEq(weEthInstance.pausedUntil(alice), warpTo + ONE_DAY);
    }

    function testFuzz_senderFrozen_blocksAnyAmount(uint256 amount) public {
        amount = bound(amount, 1, weEthInstance.balanceOf(alice));

        vm.prank(pauser);
        weEthInstance.pause(alice);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.transfer(bob, amount);
    }

    function testFuzz_recipientFrozen_blocksAnyAmount(uint256 amount) public {
        amount = bound(amount, 1, weEthInstance.balanceOf(bob));

        vm.prank(pauser);
        weEthInstance.pause(alice);

        vm.prank(bob);
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.transfer(alice, amount);
    }

    function testFuzz_wrapBlockedWhenFrozenOnWeETH(uint256 amount) public {
        amount = bound(amount, 1, eETHInstance.balanceOf(alice));

        vm.prank(pauser);
        weEthInstance.pause(alice);

        vm.prank(alice);
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.wrap(amount);
    }

    function testFuzz_wrapBlockedUnderPauseUntil_onWeETH(uint256 amount, uint64 delta) public {
        amount = bound(amount, 1, eETHInstance.balanceOf(alice));
        delta = uint64(bound(uint256(delta), 0, ONE_DAY));

        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint64 expiry = weEthInstance.pausedUntil(alice);
        vm.warp(uint256(expiry) - delta);

        vm.prank(alice);
        vm.expectRevert("RECIPIENT PAUSED");
        weEthInstance.wrap(amount);
    }

    function testFuzz_unwrapBlockedWhenFrozenOnWeETH(uint256 amount) public {
        amount = bound(amount, 1, weEthInstance.balanceOf(alice));

        vm.prank(pauser);
        weEthInstance.pause(alice);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.unwrap(amount);
    }

    function testFuzz_unwrapBlockedUnderPauseUntil_onWeETH(uint256 amount, uint64 delta) public {
        amount = bound(amount, 1, weEthInstance.balanceOf(alice));
        delta = uint64(bound(uint256(delta), 0, ONE_DAY));

        vm.prank(pauserUntil);
        weEthInstance.pauseUntil(alice);
        uint64 expiry = weEthInstance.pausedUntil(alice);
        vm.warp(uint256(expiry) - delta);

        vm.prank(alice);
        vm.expectRevert("SENDER PAUSED");
        weEthInstance.unwrap(amount);
    }

    function testFuzz_unfrozenUsers_unaffected(uint256 amount) public {
        amount = bound(amount, 1, weEthInstance.balanceOf(bob));

        vm.prank(pauser);
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

        vm.prank(pauser);
        weEthInstance.pause(userA);

        assertTrue(weEthInstance.paused(userA));
        assertFalse(weEthInstance.paused(userB));
    }
}
