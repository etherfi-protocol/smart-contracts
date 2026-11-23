// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "@tests/TestSetup.sol";
import "@etherfi/governance/utils/PausableUntil.sol";

contract PausableUntilHarness is PausableUntil {
    // These unit tests exercise the internal pause-until mechanics (expiry,
    // storage isolation) independent of role gating. `pauseUntil` is virtual in the base
    // (eETH/weETH override its gating), so we override it ungated here. `unpauseUntil` and
    // `setPauseUntilDuration` are intentionally non-virtual, so we expose ungated test-only
    // twins that replicate their logic against the same namespaced storage.
    constructor(address _roleRegistry) RolesLibrary(_roleRegistry) {}
    function pauseUntil() external override { _pauseUntil(); }
    function harnessUnpauseUntil() external {
        _requirePausedUntil();
        _getPausableUntilStorage().pausedUntil = 0;
        emit UnpausedUntil();
    }
    function harnessSetPauseUntilDuration(uint256 d) external {
        if (d < MIN_PAUSE_DURATION || d > MAX_PAUSE_DURATION) revert InvalidPauseUntilDuration();
        _getPausableUntilStorage().pauseUntilDuration = d;
        emit PauseUntilDurationSet(d);
    }
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
        harness = new PausableUntilHarness(address(0));
        vm.warp(1_700_000_000);
        harness.harnessSetPauseUntilDuration(harness.MAX_PAUSE_DURATION());
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
    }

    // --------------------------------------------------------
    //  _setPauseUntilDuration
    // --------------------------------------------------------

    function test_setPauseUntilDuration_setsStateAndEmits() public {
        uint256 d = harness.MIN_PAUSE_DURATION() + 1 hours;
        vm.expectEmit(false, false, false, true);
        emit PauseUntilDurationSet(d);
        harness.harnessSetPauseUntilDuration(d);
        assertEq(harness.pauseUntilDuration(), d);
    }

    function test_setPauseUntilDuration_acceptsMinBoundary() public {
        harness.harnessSetPauseUntilDuration(harness.MIN_PAUSE_DURATION());
        assertEq(harness.pauseUntilDuration(), harness.MIN_PAUSE_DURATION());
    }

    function test_setPauseUntilDuration_acceptsMaxBoundary() public {
        harness.harnessSetPauseUntilDuration(harness.MAX_PAUSE_DURATION());
        assertEq(harness.pauseUntilDuration(), harness.MAX_PAUSE_DURATION());
    }

    function test_setPauseUntilDuration_revertsBelowMin() public {
        uint256 belowMin = harness.MIN_PAUSE_DURATION() - 1;
        vm.expectRevert(PausableUntil.InvalidPauseUntilDuration.selector);
        harness.harnessSetPauseUntilDuration(belowMin);
    }

    function test_setPauseUntilDuration_revertsAboveMax() public {
        uint256 aboveMax = harness.MAX_PAUSE_DURATION() + 1;
        vm.expectRevert(PausableUntil.InvalidPauseUntilDuration.selector);
        harness.harnessSetPauseUntilDuration(aboveMax);
    }

    function test_setPauseUntilDuration_revertsOnZero() public {
        vm.expectRevert(PausableUntil.InvalidPauseUntilDuration.selector);
        harness.harnessSetPauseUntilDuration(0);
    }

    function test_setPauseUntilDuration_pausesForUpdatedDuration() public {
        uint256 d = harness.MIN_PAUSE_DURATION();
        harness.harnessSetPauseUntilDuration(d);

        vm.prank(pauserA);
        harness.pauseUntil();
        assertEq(harness.pausedUntil(), block.timestamp + d);
    }

    function testFuzz_setPauseUntilDuration_acceptsInRange(uint256 d) public {
        d = bound(d, harness.MIN_PAUSE_DURATION(), harness.MAX_PAUSE_DURATION());
        harness.harnessSetPauseUntilDuration(d);
        assertEq(harness.pauseUntilDuration(), d);
    }

    function testFuzz_setPauseUntilDuration_rejectsOutOfRange(uint256 d) public {
        vm.assume(d < harness.MIN_PAUSE_DURATION() || d > harness.MAX_PAUSE_DURATION());
        vm.expectRevert(PausableUntil.InvalidPauseUntilDuration.selector);
        harness.harnessSetPauseUntilDuration(d);
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

    function test_pauseUntil_samePauserCanPauseAgainRightAfterExpiry() public {
        vm.prank(pauserA);
        harness.pauseUntil();
        uint256 until = harness.pausedUntil();

        // first second after expiry — no per-pauser cooldown applies
        vm.warp(until + 1);

        vm.prank(pauserA);
        harness.pauseUntil();
        assertEq(harness.pausedUntil(), block.timestamp + harness.MAX_PAUSE_DURATION());
    }

    function test_pauseUntil_differentPauser_canPauseAfterExpiry() public {
        vm.prank(pauserA);
        harness.pauseUntil();
        uint256 firstPauseStart = block.timestamp;

        vm.warp(firstPauseStart + harness.MAX_PAUSE_DURATION() + 1);

        vm.prank(pauserB);
        harness.pauseUntil();
        assertEq(harness.pausedUntil(), block.timestamp + harness.MAX_PAUSE_DURATION());
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
        harness.harnessUnpauseUntil();

        assertEq(harness.pausedUntil(), 0);
        harness.gated(); // should pass
    }

    function test_unpauseUntil_revertsWhenNotPaused() public {
        vm.expectRevert(PausableUntil.ContractNotPausedUntil.selector);
        harness.harnessUnpauseUntil();
    }

    function test_unpauseUntil_revertsAfterExpiry() public {
        vm.prank(pauserA);
        harness.pauseUntil();
        uint256 firstPauseStart = block.timestamp;
        vm.warp(firstPauseStart + harness.MAX_PAUSE_DURATION() + 1);

        // pause has already naturally expired — unpause should revert
        vm.expectRevert(PausableUntil.ContractNotPausedUntil.selector);
        harness.harnessUnpauseUntil();
    }

    function test_unpauseUntil_samePauserCanPauseImmediately() public {
        vm.prank(pauserA);
        harness.pauseUntil();
        harness.harnessUnpauseUntil();

        // early unpause lets the same pauser re-pause in the same block
        vm.prank(pauserA);
        harness.pauseUntil();
        assertEq(harness.pausedUntil(), block.timestamp + harness.MAX_PAUSE_DURATION());
    }

    function test_unpauseUntil_newPauserCanPauseImmediately() public {
        vm.prank(pauserA);
        harness.pauseUntil();
        harness.harnessUnpauseUntil();

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

    function testFuzz_samePauser_revertsWhilePausedThenRepausesAfterExpiry(uint256 jitter) public {
        vm.prank(pauserA);
        harness.pauseUntil();
        uint256 pauseStart = block.timestamp;
        uint256 pausedUntilVal = harness.pausedUntil();

        // any time up to and including pausedUntil, re-pausing hits _requireNotPausedUntil
        jitter = bound(jitter, 1, 2 * harness.MAX_PAUSE_DURATION());
        vm.warp(pauseStart + jitter);

        if (pauseStart + jitter <= pausedUntilVal) {
            vm.expectRevert(abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, pausedUntilVal));
            vm.prank(pauserA);
            harness.pauseUntil();
        } else {
            vm.prank(pauserA);
            harness.pauseUntil();
            assertEq(harness.pausedUntil(), block.timestamp + harness.MAX_PAUSE_DURATION());
        }
    }
}
