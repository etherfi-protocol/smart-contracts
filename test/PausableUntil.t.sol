// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "@tests/TestSetup.sol";
import "@etherfi/governance/utils/PausableUntil.sol";

contract PausableUntilHarness is PausableUntil {
    function pauseUntil() external { _pauseUntil(); }
    function unpauseUntil() external { _unpauseUntil(); }
    function setPauseUntilDuration(uint256 d) external { _setPauseUntilDuration(d); }
    function requireNotPausedUntil() external view { _requireNotPausedUntil(); }
    function requirePausedUntil() external view { _requirePausedUntil(); }

    function gated() external view whenNotPausedUntil returns (bool) { return true; }
}

contract PausableUntilTest is Test {
    PausableUntilHarness harness;
    address pauserA = makeAddr("pauserA");
    address pauserB = makeAddr("pauserB");

    bytes32 constant EXPECTED_SLOT = 0x2c7e4bc092c2002f0baaf2f47367bc442b098266b43d189dafe4cb25f1e1fea2;

    event PauseUntilDurationSet(uint256 pauseUntilDuration);
    event PausedUntil(uint256 pausedUntil);
    event UnpausedUntil();

    function setUp() public {
        harness = new PausableUntilHarness();
        // warp past MAX_PAUSE_DURATION + PAUSER_UNTIL_COOLDOWN so the initial cooldown check
        // (which treats lastPauseTimestamp[pauser] = 0 as literally "last paused at unix 0")
        // does not block the first pause in tests. On mainnet this is a non-issue.
        vm.warp(1_700_000_000);
        harness.setPauseUntilDuration(harness.MAX_PAUSE_DURATION());
    }

    // --------------------------------------------------------
    //  Storage slot & constants
    // --------------------------------------------------------

    function test_storageSlotMatchesKeccak() public pure {
        assertEq(EXPECTED_SLOT, keccak256("pausableUntil.storage"));
    }

    function test_storageSlotIsolation() public {
        // write to harness's slot and confirm it's persisted at the expected slot
        vm.prank(pauserA);
        harness.pauseUntil();

        bytes32 raw = vm.load(address(harness), EXPECTED_SLOT);
        assertEq(uint256(raw), harness.pausedUntil());
        assertGt(uint256(raw), 0);
    }

    function test_constants() public view {
        assertEq(harness.MIN_PAUSE_DURATION(), 8 hours);
        assertEq(harness.MAX_PAUSE_DURATION(), 30 days);
        assertEq(harness.PAUSER_UNTIL_COOLDOWN(), 7 days);
    }

    // --------------------------------------------------------
    //  _setPauseUntilDuration
    // --------------------------------------------------------

    function test_setPauseUntilDuration_setsStateAndEmits() public {
        uint256 d = harness.MIN_PAUSE_DURATION() + 1 hours;
        vm.expectEmit(false, false, false, true);
        emit PauseUntilDurationSet(d);
        harness.setPauseUntilDuration(d);
        assertEq(harness.pauseUntilDuration(), d);
    }

    function test_setPauseUntilDuration_acceptsMinBoundary() public {
        harness.setPauseUntilDuration(harness.MIN_PAUSE_DURATION());
        assertEq(harness.pauseUntilDuration(), harness.MIN_PAUSE_DURATION());
    }

    function test_setPauseUntilDuration_acceptsMaxBoundary() public {
        harness.setPauseUntilDuration(harness.MAX_PAUSE_DURATION());
        assertEq(harness.pauseUntilDuration(), harness.MAX_PAUSE_DURATION());
    }

    function test_setPauseUntilDuration_revertsBelowMin() public {
        uint256 belowMin = harness.MIN_PAUSE_DURATION() - 1;
        vm.expectRevert(PausableUntil.InvalidPauseUntilDuration.selector);
        harness.setPauseUntilDuration(belowMin);
    }

    function test_setPauseUntilDuration_revertsAboveMax() public {
        uint256 aboveMax = harness.MAX_PAUSE_DURATION() + 1;
        vm.expectRevert(PausableUntil.InvalidPauseUntilDuration.selector);
        harness.setPauseUntilDuration(aboveMax);
    }

    function test_setPauseUntilDuration_revertsOnZero() public {
        vm.expectRevert(PausableUntil.InvalidPauseUntilDuration.selector);
        harness.setPauseUntilDuration(0);
    }

    function test_setPauseUntilDuration_pausesForUpdatedDuration() public {
        uint256 d = harness.MIN_PAUSE_DURATION();
        harness.setPauseUntilDuration(d);

        vm.prank(pauserA);
        harness.pauseUntil();
        assertEq(harness.pausedUntil(), block.timestamp + d);
    }

    function testFuzz_setPauseUntilDuration_acceptsInRange(uint256 d) public {
        d = bound(d, harness.MIN_PAUSE_DURATION(), harness.MAX_PAUSE_DURATION());
        harness.setPauseUntilDuration(d);
        assertEq(harness.pauseUntilDuration(), d);
    }

    function testFuzz_setPauseUntilDuration_rejectsOutOfRange(uint256 d) public {
        vm.assume(d < harness.MIN_PAUSE_DURATION() || d > harness.MAX_PAUSE_DURATION());
        vm.expectRevert(PausableUntil.InvalidPauseUntilDuration.selector);
        harness.setPauseUntilDuration(d);
    }

    // --------------------------------------------------------
    //  _pauseUntil happy path
    // --------------------------------------------------------

    function test_pauseUntil_setsStateAndEmits() public {
        uint256 expectedUntil = block.timestamp + harness.MAX_PAUSE_DURATION();

        vm.expectEmit(false, false, false, true);
        emit PausedUntil(expectedUntil);

        vm.prank(pauserA);
        harness.pauseUntil();

        assertEq(harness.pausedUntil(), expectedUntil);
        assertEq(harness.lastPauseTimestamp(pauserA), block.timestamp);
    }

    function test_pauseUntil_blocksGatedFunction() public {
        vm.prank(pauserA);
        harness.pauseUntil();

        vm.expectRevert(abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, harness.pausedUntil()));
        harness.gated();
    }

    function test_pauseUntil_revertsIfAlreadyPaused() public {
        vm.prank(pauserA);
        harness.pauseUntil();
        uint256 pausedUntilVal = harness.pausedUntil();

        vm.expectRevert(abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, pausedUntilVal));
        vm.prank(pauserB);
        harness.pauseUntil();
    }

    function test_pauseUntil_canPauseAgainAfterExpiryPlusCooldown() public {
        vm.prank(pauserA);
        harness.pauseUntil();
        uint256 firstPauseStart = block.timestamp;

        // jump to exactly MAX + COOLDOWN after original pause — boundary condition
        vm.warp(firstPauseStart + harness.MAX_PAUSE_DURATION() + harness.PAUSER_UNTIL_COOLDOWN() + 1);

        vm.prank(pauserA);
        harness.pauseUntil(); // should succeed
        assertEq(harness.pausedUntil(), block.timestamp + harness.MAX_PAUSE_DURATION());
    }

    function test_pauseUntil_revertsIfPauserInCooldown() public {
        vm.prank(pauserA);
        harness.pauseUntil();
        uint256 firstPauseStart = block.timestamp;

        // expire the pause but not the cooldown: warp just past pause expiry
        vm.warp(firstPauseStart + harness.MAX_PAUSE_DURATION() + 1);

        vm.prank(pauserA);
        vm.expectRevert(PausableUntil.PauserCooldownStillActive.selector);
        harness.pauseUntil();
    }

    function test_pauseUntil_differentPauser_canPauseAfterExpiry() public {
        vm.prank(pauserA);
        harness.pauseUntil();
        uint256 firstPauseStart = block.timestamp;

        vm.warp(firstPauseStart + harness.MAX_PAUSE_DURATION() + 1);

        vm.prank(pauserB);
        harness.pauseUntil(); // pauserB has no cooldown
        assertEq(harness.pausedUntil(), block.timestamp + harness.MAX_PAUSE_DURATION());
        assertEq(harness.lastPauseTimestamp(pauserB), block.timestamp);
        // pauserA's cooldown is still tracked independently
        assertEq(harness.lastPauseTimestamp(pauserA), firstPauseStart);
    }

    // --------------------------------------------------------
    //  Cooldown snapshot (PR #385 M1) + zero-baseline (M2)
    // --------------------------------------------------------

    // M1: a pauser's cooldown is fixed at the duration in force when they paused; a later
    // setPauseUntilDuration must NOT retroactively shrink it. Pause at MAX, expire the
    // pause, drop the duration to MIN, and confirm the same pauser is STILL on cooldown
    // (the cooldown is anchored to the original MAX duration, not the new MIN).
    function test_cooldown_immuneToDurationChange() public {
        vm.prank(pauserA);
        harness.pauseUntil();
        uint256 start = block.timestamp;
        assertEq(harness.cooldownUntil(pauserA), start + harness.MAX_PAUSE_DURATION() + harness.PAUSER_UNTIL_COOLDOWN());

        // pause expires; still within the original cooldown window
        vm.warp(start + harness.MAX_PAUSE_DURATION() + 1);

        // shrink the duration — must not move pauserA's already-snapshotted cooldown
        harness.setPauseUntilDuration(harness.MIN_PAUSE_DURATION());

        vm.prank(pauserA);
        vm.expectRevert(PausableUntil.PauserCooldownStillActive.selector);
        harness.pauseUntil();
    }

    // M2: a never-paused pauser (cooldownUntil == 0) can always fire the first pause,
    // even on a chain with a low block.timestamp. Under the old recompute-based check
    // (0 + duration + COOLDOWN > now) this spuriously reverted for the first ~37 days of
    // unix time.
    function test_firstPause_worksAtLowTimestamp() public {
        PausableUntilHarness fresh = new PausableUntilHarness();
        fresh.setPauseUntilDuration(fresh.MAX_PAUSE_DURATION());
        vm.warp(100); // low genesis-like timestamp
        assertEq(fresh.cooldownUntil(pauserA), 0);

        vm.prank(pauserA);
        fresh.pauseUntil(); // must not revert
        assertEq(fresh.pausedUntil(), 100 + fresh.MAX_PAUSE_DURATION());
    }

    // --------------------------------------------------------
    //  _unpauseUntil
    // --------------------------------------------------------

    function test_unpauseUntil_clearsStateAndEmits() public {
        vm.prank(pauserA);
        harness.pauseUntil();
        assertGt(harness.pausedUntil(), 0);

        vm.expectEmit(false, false, false, false);
        emit UnpausedUntil();
        harness.unpauseUntil();

        assertEq(harness.pausedUntil(), 0);
        harness.gated(); // should pass
    }

    function test_unpauseUntil_revertsWhenNotPaused() public {
        vm.expectRevert(PausableUntil.ContractNotPausedUntil.selector);
        harness.unpauseUntil();
    }

    function test_unpauseUntil_revertsAfterExpiry() public {
        vm.prank(pauserA);
        harness.pauseUntil();
        uint256 firstPauseStart = block.timestamp;
        vm.warp(firstPauseStart + harness.MAX_PAUSE_DURATION() + 1);

        // pause has already naturally expired — unpause should revert
        vm.expectRevert(PausableUntil.ContractNotPausedUntil.selector);
        harness.unpauseUntil();
    }

    function test_unpauseUntil_doesNotClearPauserCooldown() public {
        vm.prank(pauserA);
        harness.pauseUntil();
        uint256 pauseStart = block.timestamp;

        harness.unpauseUntil();

        // pauserA's cooldown remains — early unpause should NOT let them re-pause
        vm.warp(pauseStart + 1);
        vm.prank(pauserA);
        vm.expectRevert(PausableUntil.PauserCooldownStillActive.selector);
        harness.pauseUntil();

        // one second before cooldown ends — still reverts (strict >)
        vm.warp(pauseStart + harness.MAX_PAUSE_DURATION() + harness.PAUSER_UNTIL_COOLDOWN() - 1);
        vm.prank(pauserA);
        vm.expectRevert(PausableUntil.PauserCooldownStillActive.selector);
        harness.pauseUntil();

        // at exactly MAX + COOLDOWN: cooldown ends (strict >) — succeeds
        vm.warp(pauseStart + harness.MAX_PAUSE_DURATION() + harness.PAUSER_UNTIL_COOLDOWN());
        vm.prank(pauserA);
        harness.pauseUntil();
    }

    function test_unpauseUntil_newPauserCanPauseImmediately() public {
        vm.prank(pauserA);
        harness.pauseUntil();
        harness.unpauseUntil();

        // pauserB hasn't paused before, so no cooldown applies
        vm.prank(pauserB);
        harness.pauseUntil();
        assertGt(harness.pausedUntil(), 0);
    }

    // --------------------------------------------------------
    //  _requireNotPausedUntil boundary
    // --------------------------------------------------------

    function test_requireNotPausedUntil_revertsAtExactPausedUntil() public {
        vm.prank(pauserA);
        harness.pauseUntil();
        uint256 until = harness.pausedUntil();

        // at exact boundary, pausedUntil >= block.timestamp → reverts
        vm.warp(until);
        vm.expectRevert(abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, until));
        harness.requireNotPausedUntil();

        // one second after, passes
        vm.warp(until + 1);
        harness.requireNotPausedUntil();
    }

    function test_requireNotPausedUntil_passesInitially() public view {
        harness.requireNotPausedUntil();
    }

    // --------------------------------------------------------
    //  Fuzz
    // --------------------------------------------------------

    function testFuzz_gated_revertsWhilePaused(uint256 t) public {
        vm.prank(pauserA);
        harness.pauseUntil();
        uint256 until = harness.pausedUntil();

        t = bound(t, block.timestamp, until);
        vm.warp(t);
        vm.expectRevert(abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, until));
        harness.gated();
    }

    function testFuzz_gated_passesAfterExpiry(uint256 t) public {
        vm.prank(pauserA);
        harness.pauseUntil();
        uint256 until = harness.pausedUntil();

        t = bound(t, until + 1, until + 10_000 days);
        vm.warp(t);
        assertTrue(harness.gated());
    }

    function testFuzz_cooldown_enforcesMinInterval(uint256 jitter) public {
        uint256 maxDur = harness.MAX_PAUSE_DURATION();
        uint256 cooldown = harness.PAUSER_UNTIL_COOLDOWN();
        uint256 required = maxDur + cooldown;

        vm.prank(pauserA);
        harness.pauseUntil();
        uint256 pauseStart = block.timestamp;
        uint256 pausedUntilVal = harness.pausedUntil();

        // any time strictly before pauseStart + required must revert for pauserA
        jitter = bound(jitter, 1, required - 1);
        vm.warp(pauseStart + jitter);

        if (jitter <= maxDur) {
            vm.expectRevert(abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, pausedUntilVal));
        } else {
            vm.expectRevert(PausableUntil.PauserCooldownStillActive.selector);
        }
        vm.prank(pauserA);
        harness.pauseUntil();
    }

    function testFuzz_cooldown_allowsAfterRequiredInterval(uint256 extra) public {
        vm.prank(pauserA);
        harness.pauseUntil();
        uint256 pauseStart = block.timestamp;
        uint256 required = harness.MAX_PAUSE_DURATION() + harness.PAUSER_UNTIL_COOLDOWN();

        // at or after pauseStart + required, cooldown has ended (strict >)
        extra = bound(extra, 0, 365 days);
        vm.warp(pauseStart + required + extra);
        vm.prank(pauserA);
        harness.pauseUntil();
        assertEq(harness.lastPauseTimestamp(pauserA), block.timestamp);
    }

    function testFuzz_secondPauser_independentCooldown(uint256 delay) public {
        vm.prank(pauserA);
        harness.pauseUntil();
        uint256 firstStart = block.timestamp;

        // wait for pause-until to lift, then a different pauser pauses
        delay = bound(delay, harness.MAX_PAUSE_DURATION() + 1, harness.MAX_PAUSE_DURATION() + 365 days);
        vm.warp(firstStart + delay);

        vm.prank(pauserB);
        harness.pauseUntil();
        assertEq(harness.lastPauseTimestamp(pauserB), block.timestamp);
        // pauserA's cooldown is unchanged
        assertEq(harness.lastPauseTimestamp(pauserA), firstStart);
    }
}
