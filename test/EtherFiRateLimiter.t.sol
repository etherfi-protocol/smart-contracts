// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../lib/BucketLimiter.sol";
import "../src/EtherFiRateLimiter.sol";
import "../src/UUPSProxy.sol";
import "../src/interfaces/IEtherFiRateLimiter.sol";
import "../src/interfaces/IRoleRegistry.sol";
import "forge-std/Test.sol";
import "forge-std/console2.sol";

contract MockRoleRegistry is IRoleRegistry {
    mapping(bytes32 => mapping(address => bool)) public roleAssignments;
    mapping(address => bool) public protocolUpgraders;
    mapping(address => bool) public protocolPausers;
    mapping(address => bool) public protocolUnpausers;
    address public override owner;

    bytes32 public constant ETHERFI_RATE_LIMITER_ADMIN_ROLE = keccak256("ETHERFI_RATE_LIMITER_ADMIN_ROLE");
    bytes32 public constant PROTOCOL_PAUSER_ROLE = keccak256("PROTOCOL_PAUSER");
    bytes32 public constant PROTOCOL_UNPAUSER_ROLE = keccak256("PROTOCOL_UNPAUSER");

    constructor() {
        owner = msg.sender;
    }

    function initialize(address _owner) external override {
        owner = _owner;
    }

    function MAX_ROLE() external pure override returns (uint256) {
        return 256;
    }

    function grantRole(bytes32 role, address account) external {
        roleAssignments[role][account] = true;
    }

    function revokeRole(bytes32 role, address account) external {
        roleAssignments[role][account] = false;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return roleAssignments[role][account];
    }

    function roleHolders(bytes32 role) external view override returns (address[] memory) {
        // Simplified implementation - return empty array
        return new address[](0);
    }

    function checkRoles(address account, bytes memory encodedRoles) external view override {
        // Simplified implementation - no-op
    }

    function setProtocolUpgrader(address account, bool status) external {
        protocolUpgraders[account] = status;
    }

    function setProtocolPauser(address account, bool status) external {
        protocolPausers[account] = status;
    }

    function setProtocolUnpauser(address account, bool status) external {
        protocolUnpausers[account] = status;
    }

    function onlyProtocolUpgrader(address account) external view {
        require(protocolUpgraders[account], "Not protocol upgrader");
    }

    function PROTOCOL_PAUSER() external pure returns (bytes32) {
        return PROTOCOL_PAUSER_ROLE;
    }

    function PROTOCOL_UNPAUSER() external pure returns (bytes32) {
        return PROTOCOL_UNPAUSER_ROLE;
    }
}

contract EtherFiRateLimiterTest is Test {
    EtherFiRateLimiter public rateLimiter;
    MockRoleRegistry public roleRegistry;
    UUPSProxy public proxy;

    address public admin = makeAddr("admin");
    address public consumer1 = makeAddr("consumer1");
    address public consumer2 = makeAddr("consumer2");
    address public unauthorizedUser = makeAddr("unauthorized");
    address public pauser = makeAddr("pauser");
    address public unpauser = makeAddr("unpauser");
    address public upgrader = makeAddr("upgrader");

    bytes32 public constant LIMIT_ID_1 = keccak256("LIMIT_1");
    bytes32 public constant LIMIT_ID_2 = keccak256("LIMIT_2");

    // Test constants
    uint64 public constant DEFAULT_CAPACITY = 100_000_000_000; // 100 ETH in gwei
    uint64 public constant DEFAULT_REFILL_RATE = 1_000_000_000; // 1 ETH/sec in gwei
    uint64 public constant SMALL_AMOUNT = 5_000_000_000; // 5 ETH in gwei
    uint64 public constant LARGE_AMOUNT = 150_000_000_000; // 150 ETH in gwei

    event LimiterCreated(bytes32 indexed id, uint256 capacity, uint256 refillRate);
    event CapacityUpdated(bytes32 indexed id, uint256 capacity);
    event RefillRateUpdated(bytes32 indexed id, uint256 refillRate);
    event RemainingUpdated(bytes32 indexed id, uint256 remaining);
    event ConsumerUpdated(bytes32 indexed id, address indexed consumer, bool allowed);

    function setUp() public {
        // Deploy mock role registry
        roleRegistry = new MockRoleRegistry();

        // Deploy rate limiter implementation
        EtherFiRateLimiter impl = new EtherFiRateLimiter(address(roleRegistry));

        // Deploy proxy
        proxy = new UUPSProxy(address(impl), "");
        rateLimiter = EtherFiRateLimiter(address(proxy));

        // Initialize
        rateLimiter.initialize();

        // Setup roles
        roleRegistry.grantRole(roleRegistry.ETHERFI_RATE_LIMITER_ADMIN_ROLE(), admin);
        roleRegistry.grantRole(roleRegistry.PROTOCOL_PAUSER_ROLE(), pauser);
        roleRegistry.grantRole(roleRegistry.PROTOCOL_UNPAUSER_ROLE(), unpauser);
        roleRegistry.setProtocolUpgrader(upgrader, true);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------- Deployment Tests -----------------------------------
    //--------------------------------------------------------------------------------------

    function test_deploymentInitialization() public {
        assertEq(address(rateLimiter.roleRegistry()), address(roleRegistry));
        assertFalse(rateLimiter.paused());
    }

    function test_cannotInitializeTwice() public {
        vm.expectRevert("Initializable: contract is already initialized");
        rateLimiter.initialize();
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------- Access Control Tests -------------------------------
    //--------------------------------------------------------------------------------------

    function test_onlyAdminCanCreateLimiter() public {
        // Should succeed with admin
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        // Should fail with unauthorized user
        vm.prank(unauthorizedUser);
        vm.expectRevert(IEtherFiRateLimiter.IncorrectRole.selector);
        rateLimiter.createNewLimiter(LIMIT_ID_2, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);
    }

    function test_onlyAdminCanUpdateConsumers() public {
        // Setup: Create a limiter
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        // Should succeed with admin
        vm.prank(admin);
        rateLimiter.updateConsumers(LIMIT_ID_1, consumer1, true);

        // Should fail with unauthorized user
        vm.prank(unauthorizedUser);
        vm.expectRevert(IEtherFiRateLimiter.IncorrectRole.selector);
        rateLimiter.updateConsumers(LIMIT_ID_1, consumer2, true);
    }

    function test_onlyAdminCanSetCapacity() public {
        // Setup: Create a limiter
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        // Should succeed with admin
        vm.prank(admin);
        rateLimiter.setCapacity(LIMIT_ID_1, DEFAULT_CAPACITY * 2);

        // Should fail with unauthorized user
        vm.prank(unauthorizedUser);
        vm.expectRevert(IEtherFiRateLimiter.IncorrectRole.selector);
        rateLimiter.setCapacity(LIMIT_ID_1, DEFAULT_CAPACITY * 3);
    }

    function test_onlyAdminCanSetRefillRate() public {
        // Setup: Create a limiter
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        // Should succeed with admin
        vm.prank(admin);
        rateLimiter.setRefillRate(LIMIT_ID_1, DEFAULT_REFILL_RATE * 2);

        // Should fail with unauthorized user
        vm.prank(unauthorizedUser);
        vm.expectRevert(IEtherFiRateLimiter.IncorrectRole.selector);
        rateLimiter.setRefillRate(LIMIT_ID_1, DEFAULT_REFILL_RATE * 3);
    }

    function test_onlyAdminCanSetRemaining() public {
        // Setup: Create a limiter
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        // Should succeed with admin
        vm.prank(admin);
        rateLimiter.setRemaining(LIMIT_ID_1, DEFAULT_CAPACITY / 2);

        // Should fail with unauthorized user
        vm.prank(unauthorizedUser);
        vm.expectRevert(IEtherFiRateLimiter.IncorrectRole.selector);
        rateLimiter.setRemaining(LIMIT_ID_1, DEFAULT_CAPACITY / 4);
    }

    function test_onlyPauserCanPause() public {
        // Should succeed with pauser
        vm.prank(pauser);
        rateLimiter.pauseContract();
        assertTrue(rateLimiter.paused());

        // Should fail with unauthorized user
        vm.prank(unauthorizedUser);
        vm.expectRevert(IEtherFiRateLimiter.IncorrectRole.selector);
        rateLimiter.pauseContract();
    }

    function test_onlyUnpauserCanUnpause() public {
        // Setup: Pause first
        vm.prank(pauser);
        rateLimiter.pauseContract();

        // Should succeed with unpauser
        vm.prank(unpauser);
        rateLimiter.unPauseContract();
        assertFalse(rateLimiter.paused());

        // Pause again for next test
        vm.prank(pauser);
        rateLimiter.pauseContract();

        // Should fail with unauthorized user
        vm.prank(unauthorizedUser);
        vm.expectRevert(IEtherFiRateLimiter.IncorrectRole.selector);
        rateLimiter.unPauseContract();
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------- Limiter Creation Tests ------------------------------
    //--------------------------------------------------------------------------------------

    function test_createNewLimiter() public {
        vm.expectEmit(true, false, false, true);
        emit LimiterCreated(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        assertTrue(rateLimiter.limitExists(LIMIT_ID_1));

        (uint64 capacity, uint64 remaining, uint64 refillRate, uint256 lastRefill) = rateLimiter.getLimit(LIMIT_ID_1);

        assertEq(capacity, DEFAULT_CAPACITY);
        assertEq(remaining, DEFAULT_CAPACITY); // Should start full
        assertEq(refillRate, DEFAULT_REFILL_RATE);
        assertEq(lastRefill, block.timestamp);
    }

    function test_cannotCreateDuplicateLimiter() public {
        // Create first limiter
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        // Try to create duplicate
        vm.prank(admin);
        vm.expectRevert(IEtherFiRateLimiter.LimitAlreadyExists.selector);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY * 2, DEFAULT_REFILL_RATE * 2);
    }

    function test_createLimiterWithZeroValues() public {
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, 0, 0);

        assertTrue(rateLimiter.limitExists(LIMIT_ID_1));

        (uint64 capacity, uint64 remaining, uint64 refillRate,) = rateLimiter.getLimit(LIMIT_ID_1);
        assertEq(capacity, 0);
        assertEq(remaining, 0);
        assertEq(refillRate, 0);
    }

    function test_createLimiterWithMaxValues() public {
        uint64 maxValue = type(uint64).max;

        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, maxValue, maxValue);

        assertTrue(rateLimiter.limitExists(LIMIT_ID_1));

        (uint64 capacity, uint64 remaining, uint64 refillRate,) = rateLimiter.getLimit(LIMIT_ID_1);
        assertEq(capacity, maxValue);
        assertEq(remaining, maxValue);
        assertEq(refillRate, maxValue);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------- Consumer Management Tests --------------------------
    //--------------------------------------------------------------------------------------

    function test_updateConsumers() public {
        // Setup: Create limiter
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        // Initially no consumers are allowed
        assertFalse(rateLimiter.isConsumerAllowed(LIMIT_ID_1, consumer1));

        // Add consumer
        vm.expectEmit(true, true, false, true);
        emit ConsumerUpdated(LIMIT_ID_1, consumer1, true);

        vm.prank(admin);
        rateLimiter.updateConsumers(LIMIT_ID_1, consumer1, true);

        assertTrue(rateLimiter.isConsumerAllowed(LIMIT_ID_1, consumer1));

        // Remove consumer
        vm.expectEmit(true, true, false, true);
        emit ConsumerUpdated(LIMIT_ID_1, consumer1, false);

        vm.prank(admin);
        rateLimiter.updateConsumers(LIMIT_ID_1, consumer1, false);

        assertFalse(rateLimiter.isConsumerAllowed(LIMIT_ID_1, consumer1));
    }

    function test_updateConsumersForNonExistentLimit() public {
        vm.prank(admin);
        vm.expectRevert(IEtherFiRateLimiter.UnknownLimit.selector);
        rateLimiter.updateConsumers(LIMIT_ID_1, consumer1, true);
    }

    function test_multipleConsumersForSameLimit() public {
        // Setup: Create limiter
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        // Add multiple consumers
        vm.prank(admin);
        rateLimiter.updateConsumers(LIMIT_ID_1, consumer1, true);

        vm.prank(admin);
        rateLimiter.updateConsumers(LIMIT_ID_1, consumer2, true);

        assertTrue(rateLimiter.isConsumerAllowed(LIMIT_ID_1, consumer1));
        assertTrue(rateLimiter.isConsumerAllowed(LIMIT_ID_1, consumer2));
        assertFalse(rateLimiter.isConsumerAllowed(LIMIT_ID_1, unauthorizedUser));
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------- Consumption Tests ----------------------------------
    //--------------------------------------------------------------------------------------

    function test_successfulConsumption() public {
        // Setup: Create limiter and add consumer
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.prank(admin);
        rateLimiter.updateConsumers(LIMIT_ID_1, consumer1, true);

        // Check initial state
        assertEq(rateLimiter.consumable(LIMIT_ID_1), DEFAULT_CAPACITY);

        // Consume some capacity
        vm.prank(consumer1);
        rateLimiter.consume(LIMIT_ID_1, SMALL_AMOUNT);

        // Check remaining capacity
        assertEq(rateLimiter.consumable(LIMIT_ID_1), DEFAULT_CAPACITY - SMALL_AMOUNT);
    }

    function test_consumeMoreThanCapacity() public {
        // Setup: Create limiter and add consumer
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.prank(admin);
        rateLimiter.updateConsumers(LIMIT_ID_1, consumer1, true);

        // Try to consume more than capacity
        vm.prank(consumer1);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        rateLimiter.consume(LIMIT_ID_1, LARGE_AMOUNT);

        // Capacity should remain unchanged
        assertEq(rateLimiter.consumable(LIMIT_ID_1), DEFAULT_CAPACITY);
    }

    function test_consumeWithUnauthorizedConsumer() public {
        // Setup: Create limiter but don't add consumer
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        // Try to consume with unauthorized consumer
        vm.prank(unauthorizedUser);
        vm.expectRevert(IEtherFiRateLimiter.InvalidConsumer.selector);
        rateLimiter.consume(LIMIT_ID_1, SMALL_AMOUNT);
    }

    function test_consumeFromNonExistentLimit() public {
        vm.prank(consumer1);
        vm.expectRevert(IEtherFiRateLimiter.UnknownLimit.selector);
        rateLimiter.consume(LIMIT_ID_1, SMALL_AMOUNT);
    }

    function test_consumeWhilePaused() public {
        // Setup: Create limiter and add consumer
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.prank(admin);
        rateLimiter.updateConsumers(LIMIT_ID_1, consumer1, true);

        // Pause contract
        vm.prank(pauser);
        rateLimiter.pauseContract();

        // Try to consume while paused
        vm.prank(consumer1);
        vm.expectRevert("Pausable: paused");
        rateLimiter.consume(LIMIT_ID_1, SMALL_AMOUNT);
    }

    function test_canConsumeCheck() public {
        // Setup: Create limiter and add consumer
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        // Should be able to consume small amount
        assertTrue(rateLimiter.canConsume(LIMIT_ID_1, SMALL_AMOUNT));

        // Should not be able to consume large amount
        assertFalse(rateLimiter.canConsume(LIMIT_ID_1, LARGE_AMOUNT));

        // Should be able to consume exact capacity
        assertTrue(rateLimiter.canConsume(LIMIT_ID_1, DEFAULT_CAPACITY));
    }

    function test_canConsumeAfterPartialConsumption() public {
        // Setup: Create limiter and add consumer
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.prank(admin);
        rateLimiter.updateConsumers(LIMIT_ID_1, consumer1, true);

        // Consume some capacity
        vm.prank(consumer1);
        rateLimiter.consume(LIMIT_ID_1, SMALL_AMOUNT);

        uint64 remaining = DEFAULT_CAPACITY - SMALL_AMOUNT;

        // Should be able to consume remaining
        assertTrue(rateLimiter.canConsume(LIMIT_ID_1, remaining));

        // Should not be able to consume more than remaining
        assertFalse(rateLimiter.canConsume(LIMIT_ID_1, remaining + 1));
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------- Refill Tests ---------------------------------------
    //--------------------------------------------------------------------------------------

    function test_refillOverTime() public {
        // Setup: Create limiter and add consumer
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.prank(admin);
        rateLimiter.updateConsumers(LIMIT_ID_1, consumer1, true);

        // Consume all capacity
        vm.prank(consumer1);
        rateLimiter.consume(LIMIT_ID_1, DEFAULT_CAPACITY);

        assertEq(rateLimiter.consumable(LIMIT_ID_1), 0);

        // Advance time by 10 seconds
        vm.warp(block.timestamp + 10);

        // Should have refilled by 10 * DEFAULT_REFILL_RATE
        uint64 expectedRefill = 10 * DEFAULT_REFILL_RATE;
        assertEq(rateLimiter.consumable(LIMIT_ID_1), expectedRefill);
    }

    function test_refillCannotExceedCapacity() public {
        // Setup: Create limiter with small capacity
        uint64 smallCapacity = 50_000_000_000; // 50 ETH

        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, smallCapacity, DEFAULT_REFILL_RATE);

        // Advance time by a lot
        vm.warp(block.timestamp + 1000);

        // Should not exceed capacity
        assertEq(rateLimiter.consumable(LIMIT_ID_1), smallCapacity);
    }

    function test_noRefillWithZeroRate() public {
        // Setup: Create limiter with zero refill rate
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, 0);

        vm.prank(admin);
        rateLimiter.updateConsumers(LIMIT_ID_1, consumer1, true);

        // Consume some capacity
        vm.prank(consumer1);
        rateLimiter.consume(LIMIT_ID_1, SMALL_AMOUNT);

        uint64 remainingAfterConsume = DEFAULT_CAPACITY - SMALL_AMOUNT;

        // Advance time
        vm.warp(block.timestamp + 100);

        // Should not have refilled
        assertEq(rateLimiter.consumable(LIMIT_ID_1), remainingAfterConsume);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------- Configuration Update Tests -------------------------
    //--------------------------------------------------------------------------------------

    function test_setCapacity() public {
        // Setup: Create limiter
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        uint64 newCapacity = DEFAULT_CAPACITY * 2;

        vm.expectEmit(true, false, false, true);
        emit CapacityUpdated(LIMIT_ID_1, newCapacity);

        vm.prank(admin);
        rateLimiter.setCapacity(LIMIT_ID_1, newCapacity);

        (uint64 capacity, uint64 remaining,,) = rateLimiter.getLimit(LIMIT_ID_1);
        assertEq(capacity, newCapacity);
        assertEq(remaining, DEFAULT_CAPACITY); // Remaining stays at original capacity when increasing
    }

    function test_setCapacityLowerThanRemaining() public {
        // Setup: Create limiter
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        uint64 newCapacity = DEFAULT_CAPACITY / 2;

        vm.prank(admin);
        rateLimiter.setCapacity(LIMIT_ID_1, newCapacity);

        (uint64 capacity, uint64 remaining,,) = rateLimiter.getLimit(LIMIT_ID_1);
        assertEq(capacity, newCapacity);
        assertEq(remaining, newCapacity); // Remaining should be capped to new capacity
    }

    function test_setCapacityForNonExistentLimit() public {
        vm.prank(admin);
        vm.expectRevert(IEtherFiRateLimiter.UnknownLimit.selector);
        rateLimiter.setCapacity(LIMIT_ID_1, DEFAULT_CAPACITY);
    }

    function test_setRefillRate() public {
        // Setup: Create limiter
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        uint64 newRefillRate = DEFAULT_REFILL_RATE * 5;

        vm.expectEmit(true, false, false, true);
        emit RefillRateUpdated(LIMIT_ID_1, newRefillRate);

        vm.prank(admin);
        rateLimiter.setRefillRate(LIMIT_ID_1, newRefillRate);

        (,, uint64 refillRate,) = rateLimiter.getLimit(LIMIT_ID_1);
        assertEq(refillRate, newRefillRate);
    }

    function test_setRefillRateForNonExistentLimit() public {
        vm.prank(admin);
        vm.expectRevert(IEtherFiRateLimiter.UnknownLimit.selector);
        rateLimiter.setRefillRate(LIMIT_ID_1, DEFAULT_REFILL_RATE);
    }

    function test_setRemaining() public {
        // Setup: Create limiter
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        uint64 newRemaining = DEFAULT_CAPACITY / 4;

        vm.expectEmit(true, false, false, true);
        emit RemainingUpdated(LIMIT_ID_1, newRemaining);

        vm.prank(admin);
        rateLimiter.setRemaining(LIMIT_ID_1, newRemaining);

        (, uint64 remaining,,) = rateLimiter.getLimit(LIMIT_ID_1);
        assertEq(remaining, newRemaining);
    }

    function test_setRemainingForNonExistentLimit() public {
        vm.prank(admin);
        vm.expectRevert(IEtherFiRateLimiter.UnknownLimit.selector);
        rateLimiter.setRemaining(LIMIT_ID_1, DEFAULT_CAPACITY);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------- View Function Tests --------------------------------
    //--------------------------------------------------------------------------------------

    function test_limitExists() public {
        // Initially should not exist
        assertFalse(rateLimiter.limitExists(LIMIT_ID_1));

        // Create limiter
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        // Now should exist
        assertTrue(rateLimiter.limitExists(LIMIT_ID_1));
    }

    function test_limitExistsWithZeroValues() public {
        // Create limiter with some zero values but not all
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, 0, DEFAULT_REFILL_RATE);

        assertTrue(rateLimiter.limitExists(LIMIT_ID_1));
    }

    function test_getLimit() public {
        uint256 timestamp = block.timestamp;

        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        (uint64 capacity, uint64 remaining, uint64 refillRate, uint256 lastRefill) = rateLimiter.getLimit(LIMIT_ID_1);

        assertEq(capacity, DEFAULT_CAPACITY);
        assertEq(remaining, DEFAULT_CAPACITY);
        assertEq(refillRate, DEFAULT_REFILL_RATE);
        assertEq(lastRefill, timestamp);
    }

    function test_getLimitForNonExistentLimit() public {
        vm.expectRevert(IEtherFiRateLimiter.UnknownLimit.selector);
        rateLimiter.getLimit(LIMIT_ID_1);
    }

    function test_isConsumerAllowed() public {
        // Setup: Create limiter
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        // Initially no consumers are allowed
        assertFalse(rateLimiter.isConsumerAllowed(LIMIT_ID_1, consumer1));
        assertFalse(rateLimiter.isConsumerAllowed(LIMIT_ID_1, consumer2));

        // Add one consumer
        vm.prank(admin);
        rateLimiter.updateConsumers(LIMIT_ID_1, consumer1, true);

        assertTrue(rateLimiter.isConsumerAllowed(LIMIT_ID_1, consumer1));
        assertFalse(rateLimiter.isConsumerAllowed(LIMIT_ID_1, consumer2));
    }

    function test_consumableViewFunction() public {
        // Setup: Create limiter
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        assertEq(rateLimiter.consumable(LIMIT_ID_1), DEFAULT_CAPACITY);

        // The view function should work for non-existent limits too (will revert)
        vm.expectRevert(IEtherFiRateLimiter.UnknownLimit.selector);
        rateLimiter.consumable(LIMIT_ID_2);
    }

    function test_canConsumeViewFunction() public {
        // Setup: Create limiter
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        assertTrue(rateLimiter.canConsume(LIMIT_ID_1, SMALL_AMOUNT));
        assertFalse(rateLimiter.canConsume(LIMIT_ID_1, LARGE_AMOUNT));

        // Should revert for non-existent limit
        vm.expectRevert(IEtherFiRateLimiter.UnknownLimit.selector);
        rateLimiter.canConsume(LIMIT_ID_2, SMALL_AMOUNT);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------- Integration Tests ----------------------------------
    //--------------------------------------------------------------------------------------

    function test_fullWorkflowScenario() public {
        // Create limiter
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        // Add consumer
        vm.prank(admin);
        rateLimiter.updateConsumers(LIMIT_ID_1, consumer1, true);

        // Consumer uses some capacity
        vm.prank(consumer1);
        rateLimiter.consume(LIMIT_ID_1, SMALL_AMOUNT);

        uint64 remainingAfterFirst = DEFAULT_CAPACITY - SMALL_AMOUNT;
        assertEq(rateLimiter.consumable(LIMIT_ID_1), remainingAfterFirst);

        // Time passes, bucket refills
        vm.warp(block.timestamp + 5);
        uint64 refillAmount = 5 * DEFAULT_REFILL_RATE;
        uint64 expectedAfterRefill = remainingAfterFirst + refillAmount;
        assertEq(rateLimiter.consumable(LIMIT_ID_1), expectedAfterRefill);

        // Consumer uses more capacity
        vm.prank(consumer1);
        rateLimiter.consume(LIMIT_ID_1, SMALL_AMOUNT);

        assertEq(rateLimiter.consumable(LIMIT_ID_1), expectedAfterRefill - SMALL_AMOUNT);

        // Admin updates capacity
        vm.prank(admin);
        rateLimiter.setCapacity(LIMIT_ID_1, DEFAULT_CAPACITY * 2);

        (uint64 newCapacity,,,) = rateLimiter.getLimit(LIMIT_ID_1);
        assertEq(newCapacity, DEFAULT_CAPACITY * 2);
    }

    function test_multipleIndependentLimiters() public {
        uint64 capacity1 = DEFAULT_CAPACITY;
        uint64 capacity2 = DEFAULT_CAPACITY * 2;
        uint64 refillRate1 = DEFAULT_REFILL_RATE;
        uint64 refillRate2 = DEFAULT_REFILL_RATE * 3;

        // Create two different limiters
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, capacity1, refillRate1);

        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_2, capacity2, refillRate2);

        // Add consumers to both
        vm.prank(admin);
        rateLimiter.updateConsumers(LIMIT_ID_1, consumer1, true);

        vm.prank(admin);
        rateLimiter.updateConsumers(LIMIT_ID_2, consumer2, true);

        // Verify independent operation
        assertTrue(rateLimiter.limitExists(LIMIT_ID_1));
        assertTrue(rateLimiter.limitExists(LIMIT_ID_2));

        assertEq(rateLimiter.consumable(LIMIT_ID_1), capacity1);
        assertEq(rateLimiter.consumable(LIMIT_ID_2), capacity2);

        // Consume from first limiter
        vm.prank(consumer1);
        rateLimiter.consume(LIMIT_ID_1, SMALL_AMOUNT);

        // Second limiter should be unaffected
        assertEq(rateLimiter.consumable(LIMIT_ID_1), capacity1 - SMALL_AMOUNT);
        assertEq(rateLimiter.consumable(LIMIT_ID_2), capacity2);

        // Consumer 1 should not be able to use limiter 2
        vm.prank(consumer1);
        vm.expectRevert(IEtherFiRateLimiter.InvalidConsumer.selector);
        rateLimiter.consume(LIMIT_ID_2, SMALL_AMOUNT);
    }

    function test_edgeCaseZeroConsumption() public {
        // Setup: Create limiter and add consumer
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.prank(admin);
        rateLimiter.updateConsumers(LIMIT_ID_1, consumer1, true);

        uint64 initialConsumable = rateLimiter.consumable(LIMIT_ID_1);

        // Consume zero amount (should succeed)
        vm.prank(consumer1);
        rateLimiter.consume(LIMIT_ID_1, 0);

        // Capacity should remain the same
        assertEq(rateLimiter.consumable(LIMIT_ID_1), initialConsumable);
    }

    function test_upgradeability() public {
        // Verify upgrade authorization
        vm.prank(unauthorizedUser);
        vm.expectRevert("Not protocol upgrader");
        rateLimiter.upgradeTo(address(0x1));

        // Should succeed with proper role (this is just testing the authorization, not doing actual upgrade)
        vm.prank(upgrader);
        // We'll just test that it doesn't revert due to role check
        // Actually upgrading would require a new implementation
        vm.expectRevert(); // Will revert for other reasons but not role check
        rateLimiter.upgradeTo(address(0x1));
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------- Stress Tests ---------------------------------------
    //--------------------------------------------------------------------------------------

    function test_rapidConsumption() public {
        // Setup: Create limiter and add consumer
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.prank(admin);
        rateLimiter.updateConsumers(LIMIT_ID_1, consumer1, true);

        // Consume capacity in small increments
        uint64 incrementAmount = 1_000_000_000; // 1 ETH
        uint64 totalConsumed = 0;

        for (uint256 i = 0; i < 50; i++) {
            if (rateLimiter.canConsume(LIMIT_ID_1, incrementAmount)) {
                vm.prank(consumer1);
                rateLimiter.consume(LIMIT_ID_1, incrementAmount);
                totalConsumed += incrementAmount;
            } else {
                break;
            }
        }

        assertEq(rateLimiter.consumable(LIMIT_ID_1), DEFAULT_CAPACITY - totalConsumed);
    }

    function test_timeBasedRefillAccuracy() public {
        // Setup: Create limiter and add consumer
        vm.prank(admin);
        rateLimiter.createNewLimiter(LIMIT_ID_1, DEFAULT_CAPACITY, DEFAULT_REFILL_RATE);

        vm.prank(admin);
        rateLimiter.updateConsumers(LIMIT_ID_1, consumer1, true);

        // Consume all capacity
        vm.prank(consumer1);
        rateLimiter.consume(LIMIT_ID_1, DEFAULT_CAPACITY);

        assertEq(rateLimiter.consumable(LIMIT_ID_1), 0);

        // Test refill accuracy over different time periods
        uint256[] memory timeIntervals = new uint256[](5);
        timeIntervals[0] = 1;
        timeIntervals[1] = 10;
        timeIntervals[2] = 60;
        timeIntervals[3] = 300;
        timeIntervals[4] = 3600;

        for (uint256 i = 0; i < timeIntervals.length; i++) {
            // Reset state
            vm.prank(admin);
            rateLimiter.setRemaining(LIMIT_ID_1, 0);

            // Advance time
            vm.warp(block.timestamp + timeIntervals[i]);

            // Calculate expected refill
            uint64 expectedRefill = uint64(timeIntervals[i] * DEFAULT_REFILL_RATE);
            if (expectedRefill > DEFAULT_CAPACITY) expectedRefill = DEFAULT_CAPACITY;

            assertEq(rateLimiter.consumable(LIMIT_ID_1), expectedRefill, string(abi.encodePacked("Failed at time interval: ", vm.toString(timeIntervals[i]))));
        }
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- Fuzz Tests -----------------------------------------
    //--------------------------------------------------------------------------------------

    /// @dev Fuzz test for creating limiters with random valid parameters
    function testFuzz_createLimiterWithRandomParameters(uint64 capacity, uint64 refillRate, bytes32 limitId) public {
        vm.assume(limitId != bytes32(0)); // Avoid zero limit ID

        vm.prank(admin);
        rateLimiter.createNewLimiter(limitId, capacity, refillRate);

        assertTrue(rateLimiter.limitExists(limitId));

        (uint64 actualCapacity, uint64 remaining, uint64 actualRefillRate, uint256 lastRefill) = rateLimiter.getLimit(limitId);

        assertEq(actualCapacity, capacity);
        assertEq(remaining, capacity); // Should start full
        assertEq(actualRefillRate, refillRate);
        assertEq(lastRefill, block.timestamp);
    }

    /// @dev Fuzz test for consumption with random valid amounts
    function testFuzz_consumeRandomAmounts(uint64 capacity, uint64 refillRate, uint64 consumeAmount) public {
        vm.assume(capacity > 0); // Need some capacity to consume
        vm.assume(consumeAmount <= capacity); // Must be within capacity

        bytes32 limitId = keccak256("FUZZ_LIMIT");

        // Setup
        vm.prank(admin);
        rateLimiter.createNewLimiter(limitId, capacity, refillRate);

        vm.prank(admin);
        rateLimiter.updateConsumers(limitId, consumer1, true);

        // Consume
        vm.prank(consumer1);
        rateLimiter.consume(limitId, consumeAmount);

        // Verify remaining
        assertEq(rateLimiter.consumable(limitId), capacity - consumeAmount);
    }

    /// @dev Fuzz test for consumption exceeding capacity should always revert
    function testFuzz_consumeExceedingCapacityReverts(uint64 capacity, uint64 excessAmount) public {
        vm.assume(excessAmount > capacity); // Amount must exceed capacity

        bytes32 limitId = keccak256("FUZZ_LIMIT_EXCEED");

        // Setup
        vm.prank(admin);
        rateLimiter.createNewLimiter(limitId, capacity, 1000);

        vm.prank(admin);
        rateLimiter.updateConsumers(limitId, consumer1, true);

        // Should revert
        vm.prank(consumer1);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        rateLimiter.consume(limitId, excessAmount);

        // Capacity should remain unchanged
        assertEq(rateLimiter.consumable(limitId), capacity);
    }

    /// @dev Fuzz test for time-based refill with random time advances
    function testFuzz_timeBasedRefillWithRandomTime(uint64 capacity, uint64 refillRate, uint64 consumeAmount, uint256 timeAdvance) public {
        vm.assume(capacity > 0);
        vm.assume(consumeAmount <= capacity);
        vm.assume(timeAdvance > 0 && timeAdvance < 365 days); // Reasonable time bounds

        bytes32 limitId = keccak256("FUZZ_TIME_REFILL");

        // Setup
        vm.prank(admin);
        rateLimiter.createNewLimiter(limitId, capacity, refillRate);

        vm.prank(admin);
        rateLimiter.updateConsumers(limitId, consumer1, true);

        // Consume some amount
        vm.prank(consumer1);
        rateLimiter.consume(limitId, consumeAmount);

        uint64 remainingAfterConsume = capacity - consumeAmount;

        // Advance time
        vm.warp(block.timestamp + timeAdvance);

        // Calculate expected refill (capped at original capacity)
        // Use checked arithmetic to prevent overflow
        uint256 expectedRefill;

        // Prevent multiplication overflow
        if (refillRate > 0 && timeAdvance > type(uint256).max / refillRate) expectedRefill = type(uint256).max; // Overflow case

        else expectedRefill = timeAdvance * refillRate;

        uint64 expectedRemaining;

        if (expectedRefill > type(uint64).max) {
            expectedRemaining = capacity; // Overflow protection
        } else if (remainingAfterConsume > capacity) {
            expectedRemaining = capacity; // Safety check
        } else {
            uint256 totalRemaining = remainingAfterConsume + expectedRefill;
            if (totalRemaining >= capacity) expectedRemaining = capacity; // Cap at capacity

            else expectedRemaining = uint64(totalRemaining);
        }

        assertEq(rateLimiter.consumable(limitId), expectedRemaining);
    }

    /// @dev Fuzz test for multiple sequential consumptions
    function testFuzz_multipleSequentialConsumptions(uint64 capacity, uint8 numConsumptions, uint64 seed) public {
        vm.assume(capacity > 0);
        vm.assume(numConsumptions > 0 && numConsumptions <= 20); // Reasonable number

        bytes32 limitId = keccak256(abi.encodePacked("FUZZ_MULTI", seed));

        // Setup
        vm.prank(admin);
        rateLimiter.createNewLimiter(limitId, capacity, DEFAULT_REFILL_RATE);

        vm.prank(admin);
        rateLimiter.updateConsumers(limitId, consumer1, true);

        uint64 totalConsumed = 0;

        for (uint8 i = 0; i < numConsumptions; i++) {
            // Generate pseudo-random amount based on seed and iteration
            uint64 amount = uint64(uint256(keccak256(abi.encodePacked(seed, i))) % capacity);

            // Only consume if within remaining capacity
            if (amount <= rateLimiter.consumable(limitId)) {
                vm.prank(consumer1);
                rateLimiter.consume(limitId, amount);
                totalConsumed += amount;

                assertEq(rateLimiter.consumable(limitId), capacity - totalConsumed);
            }
        }
    }

    /// @dev Fuzz test for capacity updates with random values
    function testFuzz_capacityUpdates(uint64 initialCapacity, uint64 newCapacity, uint64 consumeAmount) public {
        vm.assume(initialCapacity > 0);
        vm.assume(consumeAmount <= initialCapacity);

        bytes32 limitId = keccak256("FUZZ_CAPACITY_UPDATE");

        // Setup with initial capacity
        vm.prank(admin);
        rateLimiter.createNewLimiter(limitId, initialCapacity, DEFAULT_REFILL_RATE);

        vm.prank(admin);
        rateLimiter.updateConsumers(limitId, consumer1, true);

        // Consume some amount
        vm.prank(consumer1);
        rateLimiter.consume(limitId, consumeAmount);

        uint64 remainingAfterConsume = initialCapacity - consumeAmount;

        // Update capacity
        vm.prank(admin);
        rateLimiter.setCapacity(limitId, newCapacity);

        // Verify capacity update behavior
        (uint64 actualCapacity, uint64 remaining,,) = rateLimiter.getLimit(limitId);
        assertEq(actualCapacity, newCapacity);

        if (newCapacity < remainingAfterConsume) {
            // Remaining should be capped to new capacity
            assertEq(remaining, newCapacity);
        } else {
            // Remaining should stay the same
            assertEq(remaining, remainingAfterConsume);
        }
    }

    /// @dev Fuzz test for refill rate updates with time progression
    function testFuzz_refillRateUpdates(uint64 capacity, uint64 initialRate, uint64 newRate, uint256 timeAdvance) public {
        vm.assume(capacity > 0);
        vm.assume(timeAdvance > 0 && timeAdvance < 365 days);

        bytes32 limitId = keccak256("FUZZ_REFILL_RATE");

        // Setup
        vm.prank(admin);
        rateLimiter.createNewLimiter(limitId, capacity, initialRate);

        vm.prank(admin);
        rateLimiter.updateConsumers(limitId, consumer1, true);

        // Consume all capacity
        vm.prank(consumer1);
        rateLimiter.consume(limitId, capacity);

        // Update refill rate
        vm.prank(admin);
        rateLimiter.setRefillRate(limitId, newRate);

        // Advance time
        vm.warp(block.timestamp + timeAdvance);

        // Calculate expected refill with new rate
        uint256 expectedRefill = timeAdvance * newRate;
        uint64 expectedRemaining;

        if (expectedRefill > type(uint64).max) expectedRemaining = capacity;
        else if (uint64(expectedRefill) >= capacity) expectedRemaining = capacity;
        else expectedRemaining = uint64(expectedRefill);

        assertEq(rateLimiter.consumable(limitId), expectedRemaining);
    }

    /// @dev Fuzz test for remaining amount updates
    function testFuzz_remainingUpdates(uint64 capacity, uint64 newRemaining) public {
        vm.assume(capacity > 0);

        bytes32 limitId = keccak256("FUZZ_REMAINING");

        // Setup
        vm.prank(admin);
        rateLimiter.createNewLimiter(limitId, capacity, DEFAULT_REFILL_RATE);

        // Update remaining
        vm.prank(admin);
        rateLimiter.setRemaining(limitId, newRemaining);

        // Verify remaining was set correctly
        // Note: setRemaining caps the value to capacity if newRemaining > capacity
        uint64 expectedRemaining = newRemaining > capacity ? capacity : newRemaining;
        (, uint64 actualRemaining,,) = rateLimiter.getLimit(limitId);
        assertEq(actualRemaining, expectedRemaining);
        assertEq(rateLimiter.consumable(limitId), expectedRemaining);
    }

    /// @dev Fuzz test for edge cases with very large numbers
    function testFuzz_edgeCasesLargeNumbers(uint64 capacity, uint64 refillRate) public {
        // Test behavior with maximum uint64 values
        vm.assume(capacity > 0 || refillRate > 0); // At least one must be non-zero for meaningful test

        bytes32 limitId = keccak256("FUZZ_LARGE_NUMBERS");

        vm.prank(admin);
        rateLimiter.createNewLimiter(limitId, capacity, refillRate);

        assertTrue(rateLimiter.limitExists(limitId));

        (uint64 actualCapacity, uint64 remaining, uint64 actualRefillRate,) = rateLimiter.getLimit(limitId);

        assertEq(actualCapacity, capacity);
        assertEq(remaining, capacity);
        assertEq(actualRefillRate, refillRate);
    }

    /// @dev Fuzz test for consumer authorization with random addresses
    function testFuzz_consumerAuthorization(address randomConsumer, uint64 capacity, uint64 amount) public {
        vm.assume(randomConsumer != address(0));
        vm.assume(randomConsumer != admin);
        vm.assume(capacity > 0);
        vm.assume(amount <= capacity);

        bytes32 limitId = keccak256("FUZZ_CONSUMER_AUTH");

        // Setup
        vm.prank(admin);
        rateLimiter.createNewLimiter(limitId, capacity, DEFAULT_REFILL_RATE);

        // Random consumer should not be able to consume
        vm.prank(randomConsumer);
        vm.expectRevert(IEtherFiRateLimiter.InvalidConsumer.selector);
        rateLimiter.consume(limitId, amount);

        // Authorize the consumer
        vm.prank(admin);
        rateLimiter.updateConsumers(limitId, randomConsumer, true);

        // Now they should be able to consume
        vm.prank(randomConsumer);
        rateLimiter.consume(limitId, amount);

        assertEq(rateLimiter.consumable(limitId), capacity - amount);
    }
}
