// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";

/// Unit + fuzz tests for the pause / pauseUntil / unpause feature on EETH.
/// Role model under test (per branch yash/feat/pause-transfers):
///   EETH_PAUSER_ROLE         -> monitoring EOA  : can call pauseUntil() (1-day timer)
///   EETH_EXTEND_PAUSER_ROLE  -> security council: can call pause() and unpause() (indefinite)
contract EETHPauseTest is TestSetup {
    // Re-declare events so vm.expectEmit can match by topic.
    event Paused();
    event PausedUntil(uint64 pausedUntil);
    event Unpaused();
    event Transfer(address indexed from, address indexed to, uint256 value);

    address pauser;          // monitoring EOA (EETH_PAUSER_ROLE)
    address extendPauser;    // security council (EETH_EXTEND_PAUSER_ROLE)
    address unauthorized;    // no pause roles

    uint64 constant ONE_DAY = 1 days;

    function setUp() public {
        setUpTests();

        pauser = vm.addr(0xA11CE_1);
        extendPauser = vm.addr(0xA11CE_2);
        unauthorized = vm.addr(0xA11CE_3);

        // owner owns the RoleRegistry in setUpTests()
        vm.startPrank(owner);
        roleRegistryInstance.grantRole(eETHInstance.EETH_PAUSER_ROLE(), pauser);
        roleRegistryInstance.grantRole(eETHInstance.EETH_EXTEND_PAUSER_ROLE(), extendPauser);
        vm.stopPrank();

        // Deposit so alice/bob have eETH balances for transfer tests.
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.prank(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
    }

    // -------------------------------------------------------------------
    //                             ROLE GATING
    // -------------------------------------------------------------------

    function test_pause_onlyExtendPauserRole() public {
        // unauthorized caller cannot pause
        vm.prank(unauthorized);
        vm.expectRevert("IncorrectRole");
        eETHInstance.pause();

        // monitoring EOA (only has EETH_PAUSER_ROLE) cannot pause either
        vm.prank(pauser);
        vm.expectRevert("IncorrectRole");
        eETHInstance.pause();

        // extendPauser succeeds
        vm.prank(extendPauser);
        eETHInstance.pause();
        assertTrue(eETHInstance.paused());
    }

    function test_pauseUntil_onlyPauserRole() public {
        vm.prank(unauthorized);
        vm.expectRevert("IncorrectRole");
        eETHInstance.pauseUntil();

        // extendPauser (multisig) does NOT have EETH_PAUSER_ROLE so must fail
        vm.prank(extendPauser);
        vm.expectRevert("IncorrectRole");
        eETHInstance.pauseUntil();

        vm.prank(pauser);
        eETHInstance.pauseUntil();
        assertEq(eETHInstance.pausedUntil(), uint64(block.timestamp) + ONE_DAY);
    }

    function test_unpause_onlyExtendPauserRole() public {
        // First pause so unpause has meaningful state to clear
        vm.prank(extendPauser);
        eETHInstance.pause();

        vm.prank(unauthorized);
        vm.expectRevert("IncorrectRole");
        eETHInstance.unpause();

        vm.prank(pauser);
        vm.expectRevert("IncorrectRole");
        eETHInstance.unpause();

        vm.prank(extendPauser);
        eETHInstance.unpause();
        assertFalse(eETHInstance.paused());
    }

    // -------------------------------------------------------------------
    //                        TRANSFER BLOCKING
    // -------------------------------------------------------------------

    function test_transfer_blockedWhen_paused() public {
        vm.prank(extendPauser);
        eETHInstance.pause();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        eETHInstance.transfer(bob, 1 ether);
    }

    function test_transferFrom_blockedWhen_paused() public {
        vm.prank(alice);
        eETHInstance.approve(bob, 1 ether);

        vm.prank(extendPauser);
        eETHInstance.pause();

        vm.prank(bob);
        vm.expectRevert("PAUSED");
        eETHInstance.transferFrom(alice, bob, 1 ether);
    }

    function test_transfer_blockedWhen_pauseUntilActive() public {
        vm.prank(pauser);
        eETHInstance.pauseUntil();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        eETHInstance.transfer(bob, 1 ether);
    }

    function test_transfer_blockedAtBoundary_justBeforeExpiry() public {
        vm.prank(pauser);
        eETHInstance.pauseUntil();

        // Warp to exactly pausedUntil; check still blocks (require uses <, so == is paused).
        uint64 expiry = eETHInstance.pausedUntil();
        vm.warp(expiry);

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        eETHInstance.transfer(bob, 1 ether);
    }

    function test_transfer_unblockedAfterPauseUntilExpiry() public {
        vm.prank(pauser);
        eETHInstance.pauseUntil();

        uint64 expiry = eETHInstance.pausedUntil();
        vm.warp(uint256(expiry) + 1);

        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);
    }

    function test_transfer_notBlockedWhen_notPaused() public {
        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);
        // no revert means success
    }

    // -------------------------------------------------------------------
    //              STATE / EVENT SEMANTICS (CURRENT SOURCE)
    // -------------------------------------------------------------------

    function test_pause_emitsPausedEvent() public {
        vm.expectEmit(false, false, false, true);
        emit Paused();
        vm.prank(extendPauser);
        eETHInstance.pause();
    }

    function test_pauseUntil_emitsPausedUntilEvent() public {
        vm.expectEmit(false, false, false, true);
        emit PausedUntil(uint64(block.timestamp) + ONE_DAY);
        vm.prank(pauser);
        eETHInstance.pauseUntil();
    }

    function test_unpause_emitsUnpausedEvent() public {
        vm.expectEmit(false, false, false, true);
        emit Unpaused();
        vm.prank(extendPauser);
        eETHInstance.unpause();
    }

    /// @dev Documents CURRENT behavior: pauseUntil is a silent no-op if already paused.
    /// Flagged as M-1 in the security review.
    function test_pauseUntil_silentNoOp_whilePaused() public {
        vm.prank(extendPauser);
        eETHInstance.pause();
        uint64 before = eETHInstance.pausedUntil();

        // Should NOT revert, should NOT emit, should NOT change pausedUntil.
        vm.prank(pauser);
        eETHInstance.pauseUntil();

        assertEq(eETHInstance.pausedUntil(), before, "pausedUntil should not change");
        assertTrue(eETHInstance.paused(), "paused should remain true");
    }

    /// @dev Documents CURRENT behavior: pauseUntil cannot extend an active timer.
    /// Flagged as M-1 in the security review.
    function test_pauseUntil_cannotExtend_whileTimerActive() public {
        vm.prank(pauser);
        eETHInstance.pauseUntil();
        uint64 firstExpiry = eETHInstance.pausedUntil();

        vm.warp(block.timestamp + 12 hours);

        vm.prank(pauser);
        eETHInstance.pauseUntil(); // silent no-op

        assertEq(eETHInstance.pausedUntil(), firstExpiry, "pausedUntil should not be extended");
    }

    function test_pauseUntil_canRenew_afterExpiry() public {
        vm.prank(pauser);
        eETHInstance.pauseUntil();
        uint64 firstExpiry = eETHInstance.pausedUntil();

        vm.warp(uint256(firstExpiry) + 1);

        vm.prank(pauser);
        eETHInstance.pauseUntil();

        assertEq(eETHInstance.pausedUntil(), uint64(block.timestamp) + ONE_DAY);
        assertGt(eETHInstance.pausedUntil(), firstExpiry);
    }

    function test_unpause_clearsBothFlags() public {
        vm.prank(pauser);
        eETHInstance.pauseUntil();
        vm.prank(extendPauser);
        eETHInstance.pause();

        assertTrue(eETHInstance.paused());
        assertGt(eETHInstance.pausedUntil(), block.timestamp);

        vm.prank(extendPauser);
        eETHInstance.unpause();

        assertFalse(eETHInstance.paused());
        assertLt(eETHInstance.pausedUntil(), block.timestamp);

        // Transfer should work.
        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);
    }

    function test_unpause_whenPausedUntilAlreadyExpired_leavesStale() public {
        vm.prank(pauser);
        eETHInstance.pauseUntil();
        uint64 expiry = eETHInstance.pausedUntil();

        vm.warp(uint256(expiry) + 1);

        vm.prank(extendPauser);
        eETHInstance.unpause();

        // pausedUntil NOT rewound because the if-branch (pausedUntil >= block.timestamp) is false.
        assertEq(eETHInstance.pausedUntil(), expiry);
        assertFalse(eETHInstance.paused());
    }

    /// @dev CURRENT behavior: unpause() succeeds even when contract was never paused (M-2).
    function test_unpause_noop_whenNeverPaused() public {
        vm.prank(extendPauser);
        eETHInstance.unpause();

        assertFalse(eETHInstance.paused());
        assertEq(eETHInstance.pausedUntil(), 0);
    }

    // -------------------------------------------------------------------
    //                   NON-TRANSFER PATHS DURING PAUSE
    // -------------------------------------------------------------------

    /// @dev Documents CURRENT behavior (L-2): LiquidityPool deposit path still mints eETH shares
    ///      while paused because mintShares bypasses the pause check.
    function test_mintShares_notBlockedByPause() public {
        vm.prank(extendPauser);
        eETHInstance.pause();

        uint256 sharesBefore = eETHInstance.shares(alice);
        vm.prank(address(liquidityPoolInstance));
        eETHInstance.mintShares(alice, 5 ether);
        assertEq(eETHInstance.shares(alice), sharesBefore + 5 ether);
    }

    function test_burnShares_notBlockedByPause() public {
        vm.prank(extendPauser);
        eETHInstance.pause();

        uint256 sharesBefore = eETHInstance.shares(alice);
        vm.prank(address(liquidityPoolInstance));
        eETHInstance.burnShares(alice, 1 ether);
        assertEq(eETHInstance.shares(alice), sharesBefore - 1 ether);
    }

    function test_approve_notBlockedByPause() public {
        vm.prank(extendPauser);
        eETHInstance.pause();

        vm.prank(alice);
        eETHInstance.approve(bob, 1 ether);
        assertEq(eETHInstance.allowance(alice, bob), 1 ether);
    }

    function test_permit_notBlockedByPause() public {
        // Alice priv key = 2 (per TestSetup convention)
        ILiquidityPool.PermitInput memory p = createPermitInput(
            2,
            bob,
            1 ether,
            eETHInstance.nonces(alice),
            type(uint256).max,
            eETHInstance.DOMAIN_SEPARATOR()
        );

        vm.prank(extendPauser);
        eETHInstance.pause();

        eETHInstance.permit(alice, bob, 1 ether, type(uint256).max, p.v, p.r, p.s);
        assertEq(eETHInstance.allowance(alice, bob), 1 ether);
    }

    // -------------------------------------------------------------------
    //                  INTERLEAVED / LIFECYCLE SEQUENCES
    // -------------------------------------------------------------------

    function test_sequence_pauseUntil_then_extendPauser_locks() public {
        // Monitoring triggers 1-day pause
        vm.prank(pauser);
        eETHInstance.pauseUntil();

        // Security council escalates to indefinite pause
        vm.prank(extendPauser);
        eETHInstance.pause();

        // Warp past the 1-day window: paused flag still blocks
        vm.warp(block.timestamp + 2 days);

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        eETHInstance.transfer(bob, 1 ether);

        // Only extendPauser can release
        vm.prank(pauser);
        vm.expectRevert("IncorrectRole");
        eETHInstance.unpause();

        vm.prank(extendPauser);
        eETHInstance.unpause();

        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);
    }

    function test_sequence_revokeRole_disablesPauser() public {
        bytes32 role = eETHInstance.EETH_PAUSER_ROLE();
        vm.prank(owner);
        roleRegistryInstance.revokeRole(role, pauser);

        vm.prank(pauser);
        vm.expectRevert("IncorrectRole");
        eETHInstance.pauseUntil();
    }

    // -------------------------------------------------------------------
    //                             FUZZING
    // -------------------------------------------------------------------

    function testFuzz_pause_revertsForNonExtendPauser(address caller) public {
        vm.assume(caller != extendPauser);
        // RoleRegistry.hasRole reverts/returns false depending on impl; either way pause() must revert.
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        eETHInstance.pause();
    }

    function testFuzz_pauseUntil_revertsForNonPauser(address caller) public {
        vm.assume(caller != pauser);
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        eETHInstance.pauseUntil();
    }

    function testFuzz_unpause_revertsForNonExtendPauser(address caller) public {
        vm.assume(caller != extendPauser);
        vm.prank(caller);
        vm.expectRevert("IncorrectRole");
        eETHInstance.unpause();
    }

    function testFuzz_pauseUntil_setsOneDayFromWarpedTimestamp(uint64 warpTo) public {
        // Keep within uint64 bounds; ensure we can add 1 day without overflow.
        warpTo = uint64(bound(uint256(warpTo), block.timestamp + 1, type(uint64).max - ONE_DAY - 1));
        vm.warp(warpTo);

        vm.prank(pauser);
        eETHInstance.pauseUntil();

        assertEq(eETHInstance.pausedUntil(), warpTo + ONE_DAY);
    }

    function testFuzz_transferBlockedWhenPaused(uint256 amount) public {
        amount = bound(amount, 1, eETHInstance.shares(alice));

        vm.prank(extendPauser);
        eETHInstance.pause();

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        eETHInstance.transfer(bob, amount);
    }

    function testFuzz_transferWorksAfterExpiry(uint256 amount, uint64 extra) public {
        amount = bound(amount, 1, eETHInstance.shares(alice));
        extra = uint64(bound(uint256(extra), 1, 365 days));

        vm.prank(pauser);
        eETHInstance.pauseUntil();

        vm.warp(uint256(eETHInstance.pausedUntil()) + extra);

        uint256 aliceBefore = eETHInstance.shares(alice);
        uint256 bobBefore = eETHInstance.shares(bob);

        vm.prank(alice);
        eETHInstance.transfer(bob, amount);

        // Share accounting preserved
        uint256 sharesMoved = aliceBefore - eETHInstance.shares(alice);
        assertEq(eETHInstance.shares(bob), bobBefore + sharesMoved);
    }

    function testFuzz_transferAtOrBeforeExpiry_blocks(uint64 delta) public {
        delta = uint64(bound(uint256(delta), 0, ONE_DAY));

        vm.prank(pauser);
        eETHInstance.pauseUntil();
        uint64 expiry = eETHInstance.pausedUntil();

        vm.warp(uint256(expiry) - delta);

        vm.prank(alice);
        vm.expectRevert("PAUSED");
        eETHInstance.transfer(bob, 1);
    }

    function testFuzz_unpauseSucceedsRegardlessOfPriorState(bool pauseFirst, bool pauseUntilFirst) public {
        if (pauseUntilFirst) {
            vm.prank(pauser);
            eETHInstance.pauseUntil();
        }
        if (pauseFirst) {
            vm.prank(extendPauser);
            eETHInstance.pause();
        }

        vm.prank(extendPauser);
        eETHInstance.unpause();

        assertFalse(eETHInstance.paused());
        // pausedUntil is either < now (cleared or never set) or never touched if it was already expired.
        assertTrue(eETHInstance.pausedUntil() < block.timestamp || eETHInstance.pausedUntil() == 0);

        // Transfer must succeed.
        vm.prank(alice);
        eETHInstance.transfer(bob, 1);
    }

    function testFuzz_roleAuthorization_pauseUntil_onlyHolder(address holder, address other) public {
        bytes32 role = eETHInstance.EETH_PAUSER_ROLE();
        vm.assume(holder != address(0));
        vm.assume(other != holder);
        vm.assume(!roleRegistryInstance.hasRole(role, other));

        vm.prank(owner);
        roleRegistryInstance.grantRole(role, holder);

        vm.prank(holder);
        eETHInstance.pauseUntil();
        assertGt(eETHInstance.pausedUntil(), block.timestamp);

        vm.prank(other);
        vm.expectRevert("IncorrectRole");
        eETHInstance.pauseUntil();
    }
}
