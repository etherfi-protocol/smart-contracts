// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "forge-std/console2.sol";

import "../src/PriorityWithdrawalQueue.sol";
import "../src/interfaces/IPriorityWithdrawalQueue.sol";

contract PriorityWithdrawalQueueTest is TestSetup {
    PriorityWithdrawalQueue public priorityQueue;
    PriorityWithdrawalQueue public priorityQueueImplementation;

    address public oracle;
    address public vipUser;
    address public regularUser;

    bytes32 public constant PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE = keccak256("PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE");
    bytes32 public constant PRIORITY_WITHDRAWAL_QUEUE_ORACLE_ROLE = keccak256("PRIORITY_WITHDRAWAL_QUEUE_ORACLE_ROLE");

    // Default deadline for tests
    uint24 public constant DEFAULT_DEADLINE = 7 days;

    function setUp() public {
        setUpTests();

        // Setup actors
        oracle = makeAddr("oracle");
        vipUser = makeAddr("vipUser");
        regularUser = makeAddr("regularUser");

        // Deploy PriorityWithdrawalQueue
        vm.startPrank(owner);
        priorityQueueImplementation = new PriorityWithdrawalQueue();
        UUPSProxy proxy = new UUPSProxy(
            address(priorityQueueImplementation),
            abi.encodeWithSelector(
                PriorityWithdrawalQueue.initialize.selector,
                address(liquidityPoolInstance),
                address(eETHInstance),
                address(roleRegistryInstance)
            )
        );
        priorityQueue = PriorityWithdrawalQueue(address(proxy));

        // Grant roles
        roleRegistryInstance.grantRole(PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE, alice);
        roleRegistryInstance.grantRole(PRIORITY_WITHDRAWAL_QUEUE_ORACLE_ROLE, oracle);
        vm.stopPrank();

        // Configure LiquidityPool to use PriorityWithdrawalQueue
        vm.prank(alice);
        liquidityPoolInstance.setPriorityWithdrawalQueue(address(priorityQueue));

        // Whitelist the VIP user
        vm.prank(alice);
        priorityQueue.addToWhitelist(vipUser);

        // Give VIP user some ETH and deposit to get eETH
        vm.deal(vipUser, 100 ether);
        vm.startPrank(vipUser);
        liquidityPoolInstance.deposit{value: 50 ether}();
        vm.stopPrank();
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  HELPER FUNCTIONS  ------------------------------------
    //--------------------------------------------------------------------------------------

    /// @dev Helper to create a withdrawal request and return both the requestId and request struct
    function _createWithdrawRequest(address user, uint128 amount, uint24 deadline) 
        internal 
        returns (bytes32 requestId, IPriorityWithdrawalQueue.WithdrawRequest memory request) 
    {
        uint96 nonceBefore = priorityQueue.nonce();
        uint128 shareAmount = uint128(liquidityPoolInstance.sharesForAmount(amount));
        uint40 timestamp = uint40(block.timestamp);
        IPriorityWithdrawalQueue.WithdrawConfig memory config = priorityQueue.withdrawConfig();

        vm.startPrank(user);
        eETHInstance.approve(address(priorityQueue), amount);
        requestId = priorityQueue.requestWithdraw(amount, deadline);
        vm.stopPrank();

        // Reconstruct the request struct
        request = IPriorityWithdrawalQueue.WithdrawRequest({
            nonce: nonceBefore,
            user: user,
            amountOfEEth: amount,
            shareOfEEth: shareAmount,
            creationTime: timestamp,
            secondsToMaturity: config.secondsToMaturity,
            secondsToDeadline: deadline
        });
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  REQUEST TESTS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    function test_requestWithdraw() public {
        uint128 withdrawAmount = 10 ether;
        
        // Record initial state
        uint256 initialEethBalance = eETHInstance.balanceOf(vipUser);
        uint256 initialQueueEethBalance = eETHInstance.balanceOf(address(priorityQueue));
        uint96 initialNonce = priorityQueue.nonce();

        // Create request
        (bytes32 requestId, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, withdrawAmount, DEFAULT_DEADLINE);

        // Verify state changes
        assertEq(priorityQueue.nonce(), initialNonce + 1, "Nonce should increment");
        assertEq(eETHInstance.balanceOf(vipUser), initialEethBalance - withdrawAmount, "VIP user eETH balance should decrease");
        assertEq(eETHInstance.balanceOf(address(priorityQueue)), initialQueueEethBalance + withdrawAmount, "Queue eETH balance should increase");

        // Verify request exists
        assertTrue(priorityQueue.requestExists(requestId), "Request should exist");
        assertFalse(priorityQueue.isFinalized(requestId), "Request should not be finalized yet");

        // Verify request ID matches
        bytes32 expectedId = keccak256(abi.encode(request));
        assertEq(requestId, expectedId, "Request ID should match hash of request");
    }

    function test_requestWithdrawWithPermit() public {
        uint128 withdrawAmount = 10 ether;
        
        // For this test, we'll use regular approval since permit requires signatures
        // The permit flow is tested by checking the fallback to allowance
        
        vm.startPrank(vipUser);
        eETHInstance.approve(address(priorityQueue), withdrawAmount);
        
        // Create permit input (will fail but fallback to allowance)
        IPriorityWithdrawalQueue.PermitInput memory permit = IPriorityWithdrawalQueue.PermitInput({
            value: withdrawAmount,
            deadline: block.timestamp + 1 days,
            v: 0,
            r: bytes32(0),
            s: bytes32(0)
        });
        
        bytes32 requestId = priorityQueue.requestWithdrawWithPermit(withdrawAmount, DEFAULT_DEADLINE, permit);
        vm.stopPrank();

        assertTrue(priorityQueue.requestExists(requestId), "Request should exist");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  FULFILL TESTS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    function test_fulfillRequests() public {
        uint128 withdrawAmount = 10 ether;

        // Setup: VIP user creates a withdrawal request
        (bytes32 requestId, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, withdrawAmount, DEFAULT_DEADLINE);

        // Record state before fulfillment
        uint256 pendingSharesBefore = priorityQueue.totalPendingShares();
        uint256 finalizedSharesBefore = priorityQueue.totalFinalizedShares();
        uint128 lpLockedBefore = liquidityPoolInstance.ethAmountLockedForPriorityWithdrawal();

        // Oracle fulfills the request
        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;

        vm.prank(oracle);
        priorityQueue.fulfillRequests(requests);

        // Verify state changes
        assertLt(priorityQueue.totalPendingShares(), pendingSharesBefore, "Pending shares should decrease");
        assertGt(priorityQueue.totalFinalizedShares(), finalizedSharesBefore, "Finalized shares should increase");
        assertGt(liquidityPoolInstance.ethAmountLockedForPriorityWithdrawal(), lpLockedBefore, "LP locked for priority should increase");

        // Verify request is finalized
        assertTrue(priorityQueue.isFinalized(requestId), "Request should be finalized");
    }

    function test_fulfillRequests_revertNotMatured() public {
        uint128 withdrawAmount = 10 ether;

        // Update config to require maturity time
        vm.prank(alice);
        priorityQueue.updateWithdrawConfig(1 days, 1 days, 0.01 ether);

        // Create request
        (bytes32 requestId, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, withdrawAmount, DEFAULT_DEADLINE);

        // Try to fulfill immediately (should fail - not matured)
        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;

        vm.prank(oracle);
        vm.expectRevert(PriorityWithdrawalQueue.NotMatured.selector);
        priorityQueue.fulfillRequests(requests);

        // Warp time and try again
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(oracle);
        priorityQueue.fulfillRequests(requests);

        assertTrue(priorityQueue.isFinalized(requestId), "Request should be finalized after maturity");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  CLAIM TESTS  -----------------------------------------
    //--------------------------------------------------------------------------------------

    function test_claimWithdraw() public {
        uint128 withdrawAmount = 10 ether;

        // Setup: VIP user creates a withdrawal request
        (, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, withdrawAmount, DEFAULT_DEADLINE);

        // Oracle fulfills the request
        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;
        vm.prank(oracle);
        priorityQueue.fulfillRequests(requests);

        // Record state before claim
        uint256 userEthBefore = vipUser.balance;
        uint256 finalizedSharesBefore = priorityQueue.totalFinalizedShares();
        uint256 queueEethBefore = eETHInstance.balanceOf(address(priorityQueue));

        // VIP user claims their ETH
        vm.prank(vipUser);
        priorityQueue.claimWithdraw(request);

        // Verify state changes
        assertLt(priorityQueue.totalFinalizedShares(), finalizedSharesBefore, "Finalized shares should decrease");
        
        // Verify ETH was received (approximately, due to share price)
        assertApproxEqRel(vipUser.balance, userEthBefore + withdrawAmount, 0.001e18, "User should receive ETH");
        
        // Verify eETH was burned from queue
        assertLt(eETHInstance.balanceOf(address(priorityQueue)), queueEethBefore, "Queue eETH balance should decrease");

        // Verify request was removed
        bytes32 requestId = keccak256(abi.encode(request));
        assertFalse(priorityQueue.requestExists(requestId), "Request should be removed");
    }

    function test_batchClaimWithdraw() public {
        uint128 amount1 = 5 ether;
        uint128 amount2 = 3 ether;

        // Create two requests
        (, IPriorityWithdrawalQueue.WithdrawRequest memory request1) = 
            _createWithdrawRequest(vipUser, amount1, DEFAULT_DEADLINE);
        (, IPriorityWithdrawalQueue.WithdrawRequest memory request2) = 
            _createWithdrawRequest(vipUser, amount2, DEFAULT_DEADLINE);

        // Fulfill both
        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](2);
        requests[0] = request1;
        requests[1] = request2;
        vm.prank(oracle);
        priorityQueue.fulfillRequests(requests);

        // Batch claim
        uint256 ethBefore = vipUser.balance;
        vm.prank(vipUser);
        priorityQueue.batchClaimWithdraw(requests);

        // Verify ETH received
        assertApproxEqRel(vipUser.balance, ethBefore + amount1 + amount2, 0.001e18, "All ETH should be received");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  CANCEL TESTS  ----------------------------------------
    //--------------------------------------------------------------------------------------

    function test_cancelWithdraw() public {
        uint128 withdrawAmount = 10 ether;

        // Create request
        uint256 eethBefore = eETHInstance.balanceOf(vipUser);
        (bytes32 requestId, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, withdrawAmount, DEFAULT_DEADLINE);
        uint256 eethAfterRequest = eETHInstance.balanceOf(vipUser);

        // Cancel request
        vm.prank(vipUser);
        bytes32 cancelledId = priorityQueue.cancelWithdraw(request);

        // Verify
        assertEq(cancelledId, requestId, "Cancelled ID should match");
        assertFalse(priorityQueue.requestExists(requestId), "Request should be removed");
        assertEq(eETHInstance.balanceOf(vipUser), eethBefore, "eETH should be returned");
    }

    function test_replaceWithdraw() public {
        uint128 withdrawAmount = 10 ether;
        uint24 newDeadline = 14 days;

        // Create initial request
        (bytes32 oldRequestId, IPriorityWithdrawalQueue.WithdrawRequest memory oldRequest) = 
            _createWithdrawRequest(vipUser, withdrawAmount, DEFAULT_DEADLINE);

        // Replace with new deadline
        vm.prank(vipUser);
        (bytes32 returnedOldId, bytes32 newRequestId) = priorityQueue.replaceWithdraw(oldRequest, newDeadline);

        // Verify
        assertEq(returnedOldId, oldRequestId, "Old ID should match");
        assertFalse(priorityQueue.requestExists(oldRequestId), "Old request should be removed");
        assertTrue(priorityQueue.requestExists(newRequestId), "New request should exist");
        assertTrue(newRequestId != oldRequestId, "New ID should be different");
    }

    function test_adminCancelUserWithdraws() public {
        uint128 withdrawAmount = 10 ether;

        // Create request
        (, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, withdrawAmount, DEFAULT_DEADLINE);

        uint256 eethBefore = eETHInstance.balanceOf(vipUser);

        // Admin cancels
        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;
        
        vm.prank(alice);
        bytes32[] memory cancelledIds = priorityQueue.cancelUserWithdraws(requests);

        // Verify
        assertEq(cancelledIds.length, 1, "Should cancel one request");
        assertEq(eETHInstance.balanceOf(vipUser), eethBefore + withdrawAmount, "eETH should be returned");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  FULL FLOW TESTS  -------------------------------------
    //--------------------------------------------------------------------------------------

    function test_fullWithdrawalFlow() public {
        // This test verifies the complete flow from deposit to withdrawal
        uint128 withdrawAmount = 5 ether;

        // 1. VIP user already has eETH from setUp
        uint256 initialEethBalance = eETHInstance.balanceOf(vipUser);
        uint256 initialEthBalance = vipUser.balance;

        // 2. Request withdrawal
        (, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, withdrawAmount, DEFAULT_DEADLINE);

        // Verify intermediate state
        assertEq(eETHInstance.balanceOf(vipUser), initialEethBalance - withdrawAmount, "eETH transferred to queue");
        assertGt(priorityQueue.totalPendingShares(), 0, "Pending shares tracked");

        // 3. Oracle fulfills the request
        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;
        vm.prank(oracle);
        priorityQueue.fulfillRequests(requests);

        // Verify fulfilled state
        assertEq(priorityQueue.totalPendingShares(), 0, "No pending shares after fulfill");
        assertGt(priorityQueue.totalFinalizedShares(), 0, "Shares finalized");
        assertGt(liquidityPoolInstance.ethAmountLockedForPriorityWithdrawal(), 0, "LP tracks locked amount");

        // 4. VIP user claims ETH
        vm.prank(vipUser);
        priorityQueue.claimWithdraw(request);

        // Verify final state
        assertEq(priorityQueue.totalPendingShares(), 0, "No pending");
        assertEq(priorityQueue.totalFinalizedShares(), 0, "No finalized");
        assertApproxEqRel(vipUser.balance, initialEthBalance + withdrawAmount, 0.001e18, "ETH received");
    }

    function test_multipleRequests() public {
        uint128 amount1 = 5 ether;
        uint128 amount2 = 3 ether;

        // Create two requests
        (, IPriorityWithdrawalQueue.WithdrawRequest memory request1) = 
            _createWithdrawRequest(vipUser, amount1, DEFAULT_DEADLINE);
        (, IPriorityWithdrawalQueue.WithdrawRequest memory request2) = 
            _createWithdrawRequest(vipUser, amount2, DEFAULT_DEADLINE);

        // Verify both requests tracked
        assertEq(priorityQueue.totalActiveRequests(), 2, "Should have 2 active requests");
        assertEq(priorityQueue.nonce(), 3, "Nonce should be 3");

        // Fulfill both at once
        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](2);
        requests[0] = request1;
        requests[1] = request2;
        vm.prank(oracle);
        priorityQueue.fulfillRequests(requests);

        // Verify both fulfilled
        assertEq(priorityQueue.totalPendingShares(), 0, "No pending after fulfill");
        assertGt(priorityQueue.totalFinalizedShares(), 0, "Shares finalized");

        // Claim both
        uint256 ethBefore = vipUser.balance;
        vm.startPrank(vipUser);
        priorityQueue.claimWithdraw(request1);
        priorityQueue.claimWithdraw(request2);
        vm.stopPrank();

        // Verify final state
        assertEq(priorityQueue.totalFinalizedShares(), 0, "All claimed");
        assertApproxEqRel(vipUser.balance, ethBefore + amount1 + amount2, 0.001e18, "All ETH received");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  WHITELIST TESTS  -------------------------------------
    //--------------------------------------------------------------------------------------

    function test_whitelistManagement() public {
        address newUser = makeAddr("newUser");

        // Initially not whitelisted
        assertFalse(priorityQueue.isWhitelisted(newUser), "Should not be whitelisted initially");

        // Admin adds to whitelist
        vm.prank(alice);
        priorityQueue.addToWhitelist(newUser);
        assertTrue(priorityQueue.isWhitelisted(newUser), "Should be whitelisted after add");

        // Admin removes from whitelist
        vm.prank(alice);
        priorityQueue.removeFromWhitelist(newUser);
        assertFalse(priorityQueue.isWhitelisted(newUser), "Should not be whitelisted after remove");
    }

    function test_batchUpdateWhitelist() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        bool[] memory statuses = new bool[](2);
        statuses[0] = true;
        statuses[1] = true;

        vm.prank(alice);
        priorityQueue.batchUpdateWhitelist(users, statuses);

        assertTrue(priorityQueue.isWhitelisted(user1), "User1 should be whitelisted");
        assertTrue(priorityQueue.isWhitelisted(user2), "User2 should be whitelisted");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  INVALIDATION TESTS  ----------------------------------
    //--------------------------------------------------------------------------------------

    function test_invalidateRequest() public {
        uint128 withdrawAmount = 10 ether;

        // Create request
        (bytes32 requestId, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, withdrawAmount, DEFAULT_DEADLINE);

        // Admin invalidates
        vm.prank(alice);
        priorityQueue.invalidateRequest(request);

        // Verify invalidated
        assertTrue(priorityQueue.invalidatedRequests(requestId), "Request should be invalidated");

        // Oracle cannot fulfill invalidated request
        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;
        vm.prank(oracle);
        vm.expectRevert(PriorityWithdrawalQueue.RequestInvalidated.selector);
        priorityQueue.fulfillRequests(requests);
    }

    function test_validateRequest() public {
        uint128 withdrawAmount = 10 ether;

        // Create and invalidate request
        (bytes32 requestId, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, withdrawAmount, DEFAULT_DEADLINE);
        vm.prank(alice);
        priorityQueue.invalidateRequest(request);

        // Re-validate
        vm.prank(alice);
        priorityQueue.validateRequest(requestId);

        // Verify no longer invalidated
        assertFalse(priorityQueue.invalidatedRequests(requestId), "Request should not be invalidated");

        // Oracle can now fulfill
        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;
        vm.prank(oracle);
        priorityQueue.fulfillRequests(requests);

        assertTrue(priorityQueue.isFinalized(requestId), "Request should be finalized");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  CONFIG TESTS  ----------------------------------------
    //--------------------------------------------------------------------------------------

    function test_updateWithdrawConfig() public {
        uint24 newMaturity = 12 hours;
        uint24 newMinDeadline = 2 days;
        uint96 newMinAmount = 1 ether;

        vm.prank(alice);
        priorityQueue.updateWithdrawConfig(newMaturity, newMinDeadline, newMinAmount);

        IPriorityWithdrawalQueue.WithdrawConfig memory config = priorityQueue.withdrawConfig();
        assertEq(config.secondsToMaturity, newMaturity, "Maturity should be updated");
        assertEq(config.minimumSecondsToDeadline, newMinDeadline, "Min deadline should be updated");
        assertEq(config.minimumAmount, newMinAmount, "Min amount should be updated");
    }

    function test_setWithdrawCapacity() public {
        uint256 newCapacity = 100 ether;

        vm.prank(alice);
        priorityQueue.setWithdrawCapacity(newCapacity);

        IPriorityWithdrawalQueue.WithdrawConfig memory config = priorityQueue.withdrawConfig();
        assertEq(config.withdrawCapacity, newCapacity, "Capacity should be updated");
    }

    function test_stopWithdraws() public {
        vm.prank(alice);
        priorityQueue.stopWithdraws();

        IPriorityWithdrawalQueue.WithdrawConfig memory config = priorityQueue.withdrawConfig();
        assertFalse(config.allowWithdraws, "Withdraws should be stopped");

        // Cannot create new requests
        vm.startPrank(vipUser);
        eETHInstance.approve(address(priorityQueue), 1 ether);
        vm.expectRevert(PriorityWithdrawalQueue.WithdrawsNotAllowed.selector);
        priorityQueue.requestWithdraw(1 ether, DEFAULT_DEADLINE);
        vm.stopPrank();
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  REVERT TESTS  ----------------------------------------
    //--------------------------------------------------------------------------------------

    function test_revert_notWhitelisted() public {
        vm.deal(regularUser, 10 ether);
        vm.startPrank(regularUser);
        liquidityPoolInstance.deposit{value: 5 ether}();
        eETHInstance.approve(address(priorityQueue), 1 ether);
        
        vm.expectRevert(PriorityWithdrawalQueue.NotWhitelisted.selector);
        priorityQueue.requestWithdraw(1 ether, DEFAULT_DEADLINE);
        vm.stopPrank();
    }

    function test_revert_claimNotFinalized() public {
        // Create request but don't fulfill
        (, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, 1 ether, DEFAULT_DEADLINE);
        
        vm.prank(vipUser);
        vm.expectRevert(PriorityWithdrawalQueue.RequestNotFinalized.selector);
        priorityQueue.claimWithdraw(request);
    }

    function test_revert_claimWrongOwner() public {
        // VIP creates request
        (, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, 1 ether, DEFAULT_DEADLINE);

        // Fulfill
        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;
        vm.prank(oracle);
        priorityQueue.fulfillRequests(requests);

        // Another user tries to claim
        vm.prank(regularUser);
        vm.expectRevert(PriorityWithdrawalQueue.NotRequestOwner.selector);
        priorityQueue.claimWithdraw(request);
    }

    function test_revert_fulfillNonOracle() public {
        (, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, 1 ether, DEFAULT_DEADLINE);

        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;

        vm.prank(regularUser);
        vm.expectRevert(PriorityWithdrawalQueue.IncorrectRole.selector);
        priorityQueue.fulfillRequests(requests);
    }

    function test_revert_cancelWrongOwner() public {
        (, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, 1 ether, DEFAULT_DEADLINE);

        vm.prank(regularUser);
        vm.expectRevert(PriorityWithdrawalQueue.NotRequestOwner.selector);
        priorityQueue.cancelWithdraw(request);
    }

    function test_revert_deadlineTooShort() public {
        vm.startPrank(vipUser);
        eETHInstance.approve(address(priorityQueue), 1 ether);
        
        // Default minimum deadline is 1 day
        vm.expectRevert(PriorityWithdrawalQueue.InvalidDeadline.selector);
        priorityQueue.requestWithdraw(1 ether, 1 hours);
        vm.stopPrank();
    }

    function test_revert_amountTooSmall() public {
        vm.startPrank(vipUser);
        eETHInstance.approve(address(priorityQueue), 0.001 ether);
        
        // Default minimum amount is 0.01 ether
        vm.expectRevert(PriorityWithdrawalQueue.InvalidAmount.selector);
        priorityQueue.requestWithdraw(0.001 ether, DEFAULT_DEADLINE);
        vm.stopPrank();
    }

    function test_revert_notEnoughCapacity() public {
        // Set low capacity
        vm.prank(alice);
        priorityQueue.setWithdrawCapacity(1 ether);

        vm.startPrank(vipUser);
        eETHInstance.approve(address(priorityQueue), 10 ether);
        
        vm.expectRevert(PriorityWithdrawalQueue.NotEnoughWithdrawCapacity.selector);
        priorityQueue.requestWithdraw(10 ether, DEFAULT_DEADLINE);
        vm.stopPrank();
    }
}
