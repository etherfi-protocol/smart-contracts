// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";

/// Unit + fuzz tests for the pause / pauseUntil / unpause feature on WeETH.
///
/// Role gating (post H-1 fix, aligned with EETH):
///   pause()      -> WEETH_EXTEND_PAUSER_ROLE  (security council multisig)
///   pauseUntil() -> WEETH_PAUSER_ROLE         (monitoring EOA, 1-day timer)
///   unpause()    -> WEETH_EXTEND_PAUSER_ROLE  (security council multisig)
contract WeETHPauseTest is TestSetup {
    // Re-declared events for vm.expectEmit.
    event Paused();
    event PausedUntil(uint64 pausedUntil);
    event Unpaused();

    address pauser;          // monitoring EOA (WEETH_PAUSER_ROLE) — pauseUntil only
    address extendPauser;    // security council (WEETH_EXTEND_PAUSER_ROLE) — pause + unpause
    address unauthorized;    // no weETH roles

    uint64 constant ONE_DAY = 1 days;

    function setUp() public {
        setUpTests();

        pauser = vm.addr(0xB0B1);
        extendPauser = vm.addr(0xB0B2);
        unauthorized = vm.addr(0xB0B3);

        vm.startPrank(owner);
        roleRegistryInstance.grantRole(weEthInstance.WEETH_PAUSER_ROLE(), pauser);
        roleRegistryInstance.grantRole(weEthInstance.WEETH_EXTEND_PAUSER_ROLE(), extendPauser);
        vm.stopPrank();

        // Give alice + bob eETH, then wrap some into weETH so we have weETH balances.
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 20 ether}();
        vm.prank(bob);
        liquidityPoolInstance.deposit{value: 20 ether}();

        vm.prank(alice);
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        vm.prank(alice);
        weEthInstance.wrap(10 ether);

        vm.prank(bob);
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        vm.prank(bob);
        weEthInstance.wrap(10 ether);
    }

    // -------------------------------------------------------------------
    //                     ROLE GATING (current source)
    // -------------------------------------------------------------------

    function test_pause_onlyExtendPauserRole() public {
        vm.prank(unauthorized);
        vm.expectRevert("IncorrectRole");
        weEthInstance.pause();

        // pauser holds only WEETH_PAUSER_ROLE — cannot pause indefinitely
        vm.prank(pauser);
        vm.expectRevert("IncorrectRole");
        weEthInstance.pause();

        vm.prank(extendPauser);
        weEthInstance.pause();
        assertTrue(weEthInstance.paused());
    }

    function test_pauseUntil_onlyPauserRole() public {
        vm.prank(unauthorized);
        vm.expectRevert("IncorrectRole");
        weEthInstance.pauseUntil();

        vm.prank(extendPauser);
        vm.expectRevert("IncorrectRole");
        weEthInstance.pauseUntil();

        vm.prank(pauser);
        weEthInstance.pauseUntil();
        // NOTE: currently FAILS because src/WeETH.sol:113 writes `pausedUntil = 0`.
        // Restore to `uint64(block.timestamp) + 1 days` to fix.
        assertEq(weEthInstance.pausedUntil(), uint64(block.timestamp) + ONE_DAY);
    }

    function test_unpause_onlyExtendPauserRole() public {
        vm.prank(extendPauser);
        weEthInstance.pause();

        vm.prank(unauthorized);
        vm.expectRevert("IncorrectRole");
        weEthInstance.unpause();

        // pauser holds only WEETH_PAUSER_ROLE — cannot unpause
        vm.prank(pauser);
        vm.expectRevert("IncorrectRole");
        weEthInstance.unpause();

        vm.prank(extendPauser);
        weEthInstance.unpause();
        assertFalse(weEthInstance.paused());
    }

    // -------------------------------------------------------------------
    //            TRANSFER / MINT / BURN BLOCKING WHILE PAUSED
    //    (WeETH uses _beforeTokenTransfer, so _mint and _burn also block)
    // -------------------------------------------------------------------

    function test_transfer_blockedWhen_paused() public {
        vm.prank(extendPauser);
        weEthInstance.pause();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        weEthInstance.transfer(bob, 1 ether);
    }

    function test_transferFrom_blockedWhen_paused() public {
        vm.prank(alice);
        weEthInstance.approve(bob, 1 ether);

        vm.prank(extendPauser);
        weEthInstance.pause();

        vm.prank(bob);
        vm.expectRevert("PAUSED");
        weEthInstance.transferFrom(alice, bob, 1 ether);
    }

    function test_wrap_blockedWhen_paused() public {
        vm.prank(extendPauser);
        weEthInstance.pause();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        weEthInstance.wrap(1 ether);
    }

    function test_wrapWithPermit_blockedWhen_paused() public {
        ILiquidityPool.PermitInput memory p = createPermitInput(
            2, // alice pk
            address(weEthInstance),
            1 ether,
            eETHInstance.nonces(alice),
            type(uint256).max,
            eETHInstance.DOMAIN_SEPARATOR()
        );

        vm.prank(extendPauser);
        weEthInstance.pause();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        weEthInstance.wrapWithPermit(1 ether, p);
    }

    function test_unwrap_blockedWhen_paused() public {
        vm.prank(extendPauser);
        weEthInstance.pause();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        weEthInstance.unwrap(1 ether);
    }

    function test_transfer_blockedWhen_pauseUntilActive() public {
        vm.prank(pauser);
        weEthInstance.pauseUntil();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        weEthInstance.transfer(bob, 1 ether);
    }

    function test_transfer_unblockedAfterPauseUntilExpiry() public {
        vm.prank(pauser);
        weEthInstance.pauseUntil();
        uint64 expiry = weEthInstance.pausedUntil();

        vm.warp(uint256(expiry) + 1);

        vm.prank(alice);
        weEthInstance.transfer(bob, 1 ether);
    }

    function test_transfer_blockedAtBoundary() public {
        vm.prank(pauser);
        weEthInstance.pauseUntil();
        uint64 expiry = weEthInstance.pausedUntil();
        vm.warp(expiry); // exactly pausedUntil

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        weEthInstance.transfer(bob, 1 ether);
    }

    // -------------------------------------------------------------------
    //                 CROSS-TOKEN COUPLING WITH eETH PAUSE
    // -------------------------------------------------------------------

    /// @dev When eETH is paused, weETH.unwrap reverts because unwrap calls eETH.transfer.
    function test_eETHPause_blocks_weETH_unwrap_transitively() public {
        vm.startPrank(owner);
        roleRegistryInstance.grantRole(eETHInstance.EETH_EXTEND_PAUSER_ROLE(), extendPauser);
        vm.stopPrank();

        vm.prank(extendPauser);
        eETHInstance.pause();

        // weETH itself is not paused, but unwrap routes through eETH.transfer.
        assertFalse(weEthInstance.paused());
        vm.prank(alice);
        vm.expectRevert("PAUSED");
        weEthInstance.unwrap(1 ether);
    }

    /// @dev When eETH is paused, weETH.wrap reverts because wrap calls eETH.transferFrom.
    function test_eETHPause_blocks_weETH_wrap_transitively() public {
        vm.startPrank(owner);
        roleRegistryInstance.grantRole(eETHInstance.EETH_EXTEND_PAUSER_ROLE(), extendPauser);
        vm.stopPrank();

        vm.prank(extendPauser);
        eETHInstance.pause();

        assertFalse(weEthInstance.paused());
        vm.prank(alice);
        vm.expectRevert("PAUSED");
        weEthInstance.wrap(1 ether);
    }

    /// @dev weETH-only pause does NOT prevent eETH transfers between users.
    function test_weETHPause_doesNotBlock_eETHTransfer() public {
        vm.prank(extendPauser);
        weEthInstance.pause();

        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether); // must succeed
    }

    // -------------------------------------------------------------------
    //                        STATE / EVENT SEMANTICS
    // -------------------------------------------------------------------

    function test_pause_emitsPausedEvent() public {
        vm.expectEmit(false, false, false, true);
        emit Paused();
        vm.prank(extendPauser);
        weEthInstance.pause();
    }

    function test_pauseUntil_emitsPausedUntilEvent() public {
        // NOTE: currently FAILS because src/WeETH.sol:113 emits PausedUntil(0)
        // instead of PausedUntil(block.timestamp + 1 days).
        vm.expectEmit(false, false, false, true);
        emit PausedUntil(uint64(block.timestamp) + ONE_DAY);
        vm.prank(pauser);
        weEthInstance.pauseUntil();
    }

    function test_unpause_emitsUnpausedEvent() public {
        vm.expectEmit(false, false, false, true);
        emit Unpaused();
        vm.prank(extendPauser);
        weEthInstance.unpause();
    }

    function test_pauseUntil_silentNoOp_whilePaused() public {
        vm.prank(extendPauser);
        weEthInstance.pause();
        uint64 before = weEthInstance.pausedUntil();

        vm.prank(pauser);
        weEthInstance.pauseUntil();

        assertEq(weEthInstance.pausedUntil(), before);
        assertTrue(weEthInstance.paused());
    }

    function test_pauseUntil_cannotExtend_whileTimerActive() public {
        vm.prank(pauser);
        weEthInstance.pauseUntil();
        uint64 firstExpiry = weEthInstance.pausedUntil();

        vm.warp(block.timestamp + 6 hours);

        vm.prank(pauser);
        weEthInstance.pauseUntil();

        assertEq(weEthInstance.pausedUntil(), firstExpiry);
    }

    function test_pauseUntil_canRenew_afterExpiry() public {
        vm.prank(pauser);
        weEthInstance.pauseUntil();
        uint64 firstExpiry = weEthInstance.pausedUntil();

        vm.warp(uint256(firstExpiry) + 1);
        vm.prank(pauser);
        weEthInstance.pauseUntil();

        assertGt(weEthInstance.pausedUntil(), firstExpiry);
    }

    function test_unpause_clearsBothFlags() public {
        vm.prank(pauser);
        weEthInstance.pauseUntil();
        vm.prank(extendPauser);
        weEthInstance.pause();

        assertTrue(weEthInstance.paused());
        // NOTE: assertion on pausedUntil being in the future currently FAILS
        // because pauseUntil writes 0. Restore the pause timer fix to make this pass.
        assertGt(weEthInstance.pausedUntil(), block.timestamp);

        vm.prank(extendPauser);
        weEthInstance.unpause();

        assertFalse(weEthInstance.paused());
        assertLt(weEthInstance.pausedUntil(), block.timestamp);

        vm.prank(alice);
        weEthInstance.transfer(bob, 1 ether);
    }

    function test_unpause_whenPausedUntilAlreadyExpired_leavesStale() public {
        vm.prank(pauser);
        weEthInstance.pauseUntil();
        uint64 expiry = weEthInstance.pausedUntil();

        vm.warp(uint256(expiry) + 1);

        vm.prank(extendPauser);
        weEthInstance.unpause();

        assertEq(weEthInstance.pausedUntil(), expiry);
        assertFalse(weEthInstance.paused());
    }

    function test_unpause_noop_whenNeverPaused() public {
        vm.prank(extendPauser);
        weEthInstance.unpause();
        assertFalse(weEthInstance.paused());
        assertEq(weEthInstance.pausedUntil(), 0);
    }

    // -------------------------------------------------------------------
    //                   NON-TRANSFER PATHS DURING PAUSE
    // -------------------------------------------------------------------

    function test_approve_notBlockedByPause() public {
        vm.prank(extendPauser);
        weEthInstance.pause();

        vm.prank(alice);
        weEthInstance.approve(bob, 1 ether);
        assertEq(weEthInstance.allowance(alice, bob), 1 ether);
    }

    function test_getters_workWhilePaused() public {
        vm.prank(extendPauser);
        weEthInstance.pause();

        // getRate, getEETHByWeETH, getWeETHByeETH are all view; must not revert.
        weEthInstance.getRate();
        weEthInstance.getEETHByWeETH(1 ether);
        weEthInstance.getWeETHByeETH(1 ether);
    }

    // -------------------------------------------------------------------
    //                             FUZZING
    // -------------------------------------------------------------------

    function testFuzz_pause_revertsForNonExtendPauser(address caller) public {
        vm.assume(caller != extendPauser);
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        weEthInstance.pause();
    }

    function testFuzz_pauseUntil_revertsForNonPauser(address caller) public {
        vm.assume(caller != pauser);
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        weEthInstance.pauseUntil();
    }

    function testFuzz_unpause_revertsForNonExtendPauser(address caller) public {
        vm.assume(caller != extendPauser);
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        weEthInstance.unpause();
    }

    function testFuzz_pauseUntil_setsOneDayFromWarpedTimestamp(uint64 warpTo) public {
        warpTo = uint64(bound(uint256(warpTo), block.timestamp + 1, type(uint64).max - ONE_DAY - 1));
        vm.warp(warpTo);

        vm.prank(pauser);
        weEthInstance.pauseUntil();

        assertEq(weEthInstance.pausedUntil(), warpTo + ONE_DAY);
    }

    function testFuzz_transferBlockedWhenPaused(uint256 amount) public {
        amount = bound(amount, 1, weEthInstance.balanceOf(alice));

        vm.prank(extendPauser);
        weEthInstance.pause();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        weEthInstance.transfer(bob, amount);
    }

    function testFuzz_wrapBlockedWhenPaused(uint256 amount) public {
        amount = bound(amount, 1, eETHInstance.balanceOf(alice));

        vm.prank(extendPauser);
        weEthInstance.pause();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        weEthInstance.wrap(amount);
    }

    function testFuzz_unwrapBlockedWhenPaused(uint256 amount) public {
        amount = bound(amount, 1, weEthInstance.balanceOf(alice));

        vm.prank(extendPauser);
        weEthInstance.pause();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        weEthInstance.unwrap(amount);
    }

    function testFuzz_transferAtOrBeforeExpiry_blocks(uint64 delta) public {
        delta = uint64(bound(uint256(delta), 0, ONE_DAY));

        vm.prank(pauser);
        weEthInstance.pauseUntil();
        uint64 expiry = weEthInstance.pausedUntil();

        vm.warp(uint256(expiry) - delta);

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        weEthInstance.transfer(bob, 1);
    }

    function testFuzz_transferWorksAfterExpiry(uint256 amount, uint64 extra) public {
        amount = bound(amount, 1, weEthInstance.balanceOf(alice));
        extra = uint64(bound(uint256(extra), 1, 365 days));

        vm.prank(pauser);
        weEthInstance.pauseUntil();

        vm.warp(uint256(weEthInstance.pausedUntil()) + extra);

        uint256 aliceBefore = weEthInstance.balanceOf(alice);
        uint256 bobBefore = weEthInstance.balanceOf(bob);

        vm.prank(alice);
        weEthInstance.transfer(bob, amount);

        assertEq(weEthInstance.balanceOf(alice), aliceBefore - amount);
        assertEq(weEthInstance.balanceOf(bob), bobBefore + amount);
    }

    function testFuzz_unpauseClearsState(bool pauseFirst, bool pauseUntilFirst) public {
        if (pauseUntilFirst) {
            vm.prank(pauser);
            weEthInstance.pauseUntil();
        }
        if (pauseFirst) {
            vm.prank(extendPauser);
            weEthInstance.pause();
        }

        vm.prank(extendPauser);
        weEthInstance.unpause();

        assertFalse(weEthInstance.paused());
        assertTrue(weEthInstance.pausedUntil() < block.timestamp || weEthInstance.pausedUntil() == 0);

        vm.prank(alice);
        weEthInstance.transfer(bob, 1);
    }
}
