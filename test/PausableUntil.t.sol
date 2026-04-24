// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "../src/utils/PausableUntil.sol";
import "../src/EtherFiRateLimiter.sol";
import "../src/UUPSProxy.sol";
import "../src/interfaces/IRoleRegistry.sol";
import "../src/interfaces/IEtherFiRateLimiter.sol";

contract PausableUntilHarness is PausableUntil {
    function pauseUntil() external { _pauseUntil(); }
    function unpauseUntil() external { _unpauseUntil(); }
    function requireNotPausedUntil() external view { _requireNotPausedUntil(); }
    function requirePausedUntil() external view { _requirePausedUntil(); }

    function pausedUntil() external view returns (uint256) {
        return _getPausableUntilStorage().pausedUntil;
    }

    function lastPauseTimestamp(address pauser) external view returns (uint256) {
        return _getPausableUntilStorage().lastPauseTimestamp[pauser];
    }

    function gated() external view whenNotPausedUntil returns (bool) { return true; }
}

contract MockRegistry is IRoleRegistry {
    mapping(bytes32 => mapping(address => bool)) private _roles;
    address public override owner;

    bytes32 public constant PAUSE_UNTIL_ROLE = keccak256("PAUSE_UNTIL_ROLE");
    bytes32 public constant UNPAUSE_UNTIL_ROLE = keccak256("UNPAUSE_UNTIL_ROLE");
    bytes32 public constant PROTOCOL_PAUSER = keccak256("PROTOCOL_PAUSER");
    bytes32 public constant PROTOCOL_UNPAUSER = keccak256("PROTOCOL_UNPAUSER");

    constructor() { owner = msg.sender; }
    function initialize(address _o) external override { owner = _o; }
    function MAX_ROLE() external pure override returns (uint256) { return type(uint256).max; }
    function grantRole(bytes32 r, address a) external override { _roles[r][a] = true; }
    function revokeRole(bytes32 r, address a) external override { _roles[r][a] = false; }
    function hasRole(bytes32 r, address a) external view override returns (bool) { return _roles[r][a]; }
    function roleHolders(bytes32) external pure override returns (address[] memory) { return new address[](0); }
    function checkRoles(address, bytes memory) external pure override {}
    function onlyProtocolUpgrader(address) external pure override {}
}

contract PausableUntilTest is Test {
    PausableUntilHarness harness;
    address pauserA = makeAddr("pauserA");
    address pauserB = makeAddr("pauserB");

    bytes32 constant EXPECTED_SLOT = 0x2c7e4bc092c2002f0baaf2f47367bc442b098266b43d189dafe4cb25f1e1fea2;

    event PausedUntil(uint256 pausedUntil);
    event UnpausedUntil();

    function setUp() public {
        harness = new PausableUntilHarness();
        // warp past MAX_PAUSE_DURATION + PAUSER_UNTIL_COOLDOWN so the initial cooldown check
        // (which treats lastPauseTimestamp[pauser] = 0 as literally "last paused at unix 0")
        // does not block the first pause in tests. On mainnet this is a non-issue.
        vm.warp(1_700_000_000);
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
        assertEq(harness.MAX_PAUSE_DURATION(), 1 days);
        assertEq(harness.PAUSER_UNTIL_COOLDOWN(), 1 days);
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

// --------------------------------------------------------
//  Integration: role-gated paths through EtherFiRateLimiter
// --------------------------------------------------------

contract PausableUntilIntegrationTest is Test {
    EtherFiRateLimiter limiter;
    MockRegistry registry;

    address admin = makeAddr("admin");
    address pauser = makeAddr("pauser");
    address unpauser = makeAddr("unpauser");
    address pauseUntilPauser = makeAddr("pauseUntilPauser");
    address unpauseUntilUnpauser = makeAddr("unpauseUntilUnpauser");
    address consumer = makeAddr("consumer");
    address outsider = makeAddr("outsider");

    bytes32 constant LIMIT_ID = keccak256("LIMIT");

    function setUp() public {
        registry = new MockRegistry();
        EtherFiRateLimiter impl = new EtherFiRateLimiter(address(registry));
        UUPSProxy proxy = new UUPSProxy(address(impl), "");
        limiter = EtherFiRateLimiter(address(proxy));
        limiter.initialize();

        registry.grantRole(limiter.ETHERFI_RATE_LIMITER_ADMIN_ROLE(), admin);
        registry.grantRole(registry.PROTOCOL_PAUSER(), pauser);
        registry.grantRole(registry.PROTOCOL_UNPAUSER(), unpauser);
        registry.grantRole(registry.PAUSE_UNTIL_ROLE(), pauseUntilPauser);
        registry.grantRole(registry.UNPAUSE_UNTIL_ROLE(), unpauseUntilUnpauser);

        vm.startPrank(admin);
        limiter.createNewLimiter(LIMIT_ID, 1_000_000_000_000, 1_000_000);
        limiter.updateConsumers(LIMIT_ID, consumer, true);
        vm.stopPrank();

        vm.warp(1_700_000_000);
    }

    // --- role gating ---

    function test_pauseContractUntil_requiresRole() public {
        vm.prank(outsider);
        vm.expectRevert(IEtherFiRateLimiter.IncorrectRole.selector);
        limiter.pauseContractUntil();
    }

    function test_pauseContractUntil_protocolPauserCannotCall() public {
        // PROTOCOL_PAUSER alone must not be able to invoke pauseContractUntil
        vm.prank(pauser);
        vm.expectRevert(IEtherFiRateLimiter.IncorrectRole.selector);
        limiter.pauseContractUntil();
    }

    function test_unPauseContractUntil_requiresRole() public {
        vm.prank(pauseUntilPauser);
        limiter.pauseContractUntil();

        vm.prank(outsider);
        vm.expectRevert(IEtherFiRateLimiter.IncorrectRole.selector);
        limiter.unPauseContractUntil();

        // PROTOCOL_UNPAUSER alone must not be able to invoke unPauseContractUntil
        vm.prank(unpauser);
        vm.expectRevert(IEtherFiRateLimiter.IncorrectRole.selector);
        limiter.unPauseContractUntil();
    }

    // --- functional: consume() gated by both pause paths ---

    function test_consume_blockedByPauseUntil() public {
        vm.prank(pauseUntilPauser);
        limiter.pauseContractUntil();

        vm.prank(consumer);
        vm.expectRevert();
        limiter.consume(LIMIT_ID, 1_000);
    }

    function test_consume_unblockedAfterPauseUntilExpires() public {
        vm.prank(pauseUntilPauser);
        limiter.pauseContractUntil();
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(consumer);
        limiter.consume(LIMIT_ID, 1_000);
    }

    function test_consume_unblockedAfterExplicitUnpauseUntil() public {
        vm.prank(pauseUntilPauser);
        limiter.pauseContractUntil();

        vm.prank(unpauseUntilUnpauser);
        limiter.unPauseContractUntil();

        vm.prank(consumer);
        limiter.consume(LIMIT_ID, 1_000);
    }

    function test_consume_blockedByEitherPause() public {
        // protocol pauser pauses fully
        vm.prank(pauser);
        limiter.pauseContract();
        vm.prank(consumer);
        vm.expectRevert();
        limiter.consume(LIMIT_ID, 1_000);

        vm.prank(unpauser);
        limiter.unPauseContract();

        // now pauseUntil alone blocks
        vm.prank(pauseUntilPauser);
        limiter.pauseContractUntil();
        vm.prank(consumer);
        vm.expectRevert();
        limiter.consume(LIMIT_ID, 1_000);
    }

    function test_pauseContractUntil_and_pauseContract_areIndependent() public {
        vm.prank(pauseUntilPauser);
        limiter.pauseContractUntil();

        // full pause still works while paused-until is active
        vm.prank(pauser);
        limiter.pauseContract();
        assertTrue(limiter.paused());

        // and unpausing the full pause does not clear paused-until
        vm.prank(unpauser);
        limiter.unPauseContract();
        vm.prank(consumer);
        vm.expectRevert();
        limiter.consume(LIMIT_ID, 1_000);
    }

    // --- storage: namespaced slot must not collide with limiter's sequential storage ---

    function test_namespacedSlot_doesNotCollideWithLimiterStorage() public {
        vm.prank(pauseUntilPauser);
        limiter.pauseContractUntil();

        bytes32 raw = vm.load(address(limiter), 0x2c7e4bc092c2002f0baaf2f47367bc442b098266b43d189dafe4cb25f1e1fea2);
        assertGt(uint256(raw), 0);

        // the first few sequential slots (where EtherFiRateLimiter's storage lives) should not
        // have been affected by PausableUntil writes
        for (uint256 i = 0; i < 10; i++) {
            bytes32 sequential = vm.load(address(limiter), bytes32(i));
            // these slots are either PausableUpgradeable's or mapping heads; whichever they are,
            // they must not equal our pausedUntil value.
            if (sequential == raw) {
                revert("unexpected slot collision");
            }
        }
    }
}
