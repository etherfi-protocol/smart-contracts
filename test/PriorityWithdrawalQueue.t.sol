// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "forge-std/console2.sol";

import "../src/PriorityWithdrawalQueue.sol";
import "../src/interfaces/IPriorityWithdrawalQueue.sol";

contract PriorityWithdrawalQueueTest is TestSetup {
    PriorityWithdrawalQueue public priorityQueue;
    PriorityWithdrawalQueue public priorityQueueImplementation;

    address public requestManager;
    address public vipUser;
    address public regularUser;
    address public treasury;

    bytes32 public constant PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE = keccak256("PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE");
    bytes32 public constant PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE = keccak256("PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE");
    bytes32 public constant PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE = keccak256("PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE");
    bytes32 public constant IMPLICIT_FEE_CLAIMER_ROLE = keccak256("IMPLICIT_FEE_CLAIMER_ROLE");

    function setUp() public {
        // Initialize mainnet fork
        initializeRealisticFork(MAINNET_FORK);

        // Setup actors
        requestManager = makeAddr("requestManager");
        vipUser = makeAddr("vipUser");
        regularUser = makeAddr("regularUser");
        treasury = makeAddr("treasury");

        // Deploy PriorityWithdrawalQueue with constructor args
        vm.startPrank(owner);
        priorityQueueImplementation = new PriorityWithdrawalQueue(
            address(liquidityPoolInstance),
            address(eETHInstance),
            address(roleRegistryInstance),
            treasury
        );
        UUPSProxy proxy = new UUPSProxy(
            address(priorityQueueImplementation),
            abi.encodeWithSelector(PriorityWithdrawalQueue.initialize.selector)
        );
        priorityQueue = PriorityWithdrawalQueue(address(proxy));
        vm.stopPrank();

        // Upgrade LiquidityPool to latest version (needed for setPriorityWithdrawalQueue)
        vm.startPrank(owner);
        LiquidityPool newLpImpl = new LiquidityPool(address(priorityQueue));
        liquidityPoolInstance.upgradeTo(address(newLpImpl));

        // Grant roles
        roleRegistryInstance.grantRole(PRIORITY_WITHDRAWAL_QUEUE_ADMIN_ROLE, alice);
        roleRegistryInstance.grantRole(PRIORITY_WITHDRAWAL_QUEUE_WHITELIST_MANAGER_ROLE, alice);
        roleRegistryInstance.grantRole(PRIORITY_WITHDRAWAL_QUEUE_REQUEST_MANAGER_ROLE, requestManager);
        roleRegistryInstance.grantRole(IMPLICIT_FEE_CLAIMER_ROLE, alice);
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_PAUSER(), alice);
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_UNPAUSER(), alice);
        roleRegistryInstance.grantRole(liquidityPoolInstance.LIQUIDITY_POOL_ADMIN_ROLE(), owner);

        // Configure LiquidityPool to use PriorityWithdrawalQueue (owner has LP admin role now)
        vm.stopPrank();

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
    /// @notice Automatically rolls to the next block to allow cancel/claim operations
    function _createWithdrawRequest(address user, uint96 amount) 
        internal 
        returns (bytes32 requestId, IPriorityWithdrawalQueue.WithdrawRequest memory request) 
    {
        uint32 nonceBefore = priorityQueue.nonce();
        uint96 shareAmount = uint96(liquidityPoolInstance.sharesForAmount(amount));
        uint32 timestamp = uint32(block.timestamp);

        vm.startPrank(user);
        eETHInstance.approve(address(priorityQueue), amount);
        requestId = priorityQueue.requestWithdraw(amount);
        vm.stopPrank();

        // Reconstruct the request struct
        request = IPriorityWithdrawalQueue.WithdrawRequest({
            user: user,
            amountOfEEth: amount,
            shareOfEEth: shareAmount,
            nonce: uint32(nonceBefore),
            creationTime: timestamp
        });

        // Warp time past MIN_DELAY (1 hour) to allow fulfill/cancel/claim operations
        vm.warp(block.timestamp + 1 hours + 1);
        vm.roll(block.number + 1);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  INITIALIZATION TESTS  --------------------------------
    //--------------------------------------------------------------------------------------

    function test_initialization() public view {
        // Verify immutables
        assertEq(address(priorityQueue.liquidityPool()), address(liquidityPoolInstance));
        assertEq(address(priorityQueue.eETH()), address(eETHInstance));
        assertEq(address(priorityQueue.roleRegistry()), address(roleRegistryInstance));
        assertEq(priorityQueue.treasury(), treasury);

        // Verify initial state
        assertEq(priorityQueue.nonce(), 1);
        assertFalse(priorityQueue.paused());
        assertEq(priorityQueue.totalRemainderShares(), 0);
        assertEq(priorityQueue.shareRemainderSplitToTreasuryInBps(), 10000);

        // Verify constants
        assertEq(priorityQueue.MIN_DELAY(), 1 hours);
        assertEq(priorityQueue.MIN_AMOUNT(), 0.01 ether);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  REQUEST TESTS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    function test_requestWithdraw() public {
        uint96 withdrawAmount = 10 ether;
        
        // Record initial state
        uint256 initialEethBalance = eETHInstance.balanceOf(vipUser);
        uint256 initialQueueEethBalance = eETHInstance.balanceOf(address(priorityQueue));
        uint96 initialNonce = priorityQueue.nonce();

        // Create request
        (bytes32 requestId, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, withdrawAmount);

        // Verify state changes
        assertEq(priorityQueue.nonce(), initialNonce + 1, "Nonce should increment");
        // Use approximate comparison due to share/amount rounding (1 wei tolerance)
        assertApproxEqAbs(eETHInstance.balanceOf(vipUser), initialEethBalance - withdrawAmount, 1, "VIP user eETH balance should decrease");
        assertApproxEqAbs(eETHInstance.balanceOf(address(priorityQueue)), initialQueueEethBalance + withdrawAmount, 1, "Queue eETH balance should increase");

        // Verify request exists
        assertTrue(priorityQueue.requestExists(requestId), "Request should exist");
        assertFalse(priorityQueue.isFinalized(requestId), "Request should not be finalized yet");

        // Verify request ID matches
        bytes32 expectedId = keccak256(abi.encode(request));
        assertEq(requestId, expectedId, "Request ID should match hash of request");

        // Verify active requests count
        assertEq(priorityQueue.totalActiveRequests(), 1, "Should have 1 active request");
    }


    //--------------------------------------------------------------------------------------
    //------------------------------  FULFILL TESTS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    function test_fulfillRequests() public {
        uint96 withdrawAmount = 10 ether;

        // Setup: VIP user creates a withdrawal request
        (bytes32 requestId, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, withdrawAmount);

        // Record state before fulfillment
        uint128 lpLockedBefore = liquidityPoolInstance.ethAmountLockedForPriorityWithdrawal();

        // Request manager fulfills the request
        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;

        vm.prank(requestManager);
        priorityQueue.fulfillRequests(requests);

        // Verify state changes
        assertGt(liquidityPoolInstance.ethAmountLockedForPriorityWithdrawal(), lpLockedBefore, "LP locked for priority should increase");

        // Verify request is finalized
        assertTrue(priorityQueue.isFinalized(requestId), "Request should be finalized");
        assertTrue(priorityQueue.requestExists(requestId), "Request should still exist");
    }

    function test_fulfillRequests_revertNotMatured() public {
        uint96 withdrawAmount = 10 ether;

        // Manually create request (don't use helper since it auto-warps time)
        uint32 nonceBefore = priorityQueue.nonce();
        uint96 shareAmount = uint96(liquidityPoolInstance.sharesForAmount(withdrawAmount));
        uint32 timestamp = uint32(block.timestamp);

        vm.startPrank(vipUser);
        eETHInstance.approve(address(priorityQueue), withdrawAmount);
        priorityQueue.requestWithdraw(withdrawAmount);
        vm.stopPrank();

        IPriorityWithdrawalQueue.WithdrawRequest memory request = IPriorityWithdrawalQueue.WithdrawRequest({
            user: vipUser,
            amountOfEEth: withdrawAmount,
            shareOfEEth: shareAmount,
            nonce: uint32(nonceBefore),
            creationTime: timestamp
        });
        bytes32 requestId = keccak256(abi.encode(request));

        // Try to fulfill immediately (should fail - not matured, MIN_DELAY = 1 hour)
        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;

        vm.prank(requestManager);
        vm.expectRevert(PriorityWithdrawalQueue.NotMatured.selector);
        priorityQueue.fulfillRequests(requests);

        // Warp time past MIN_DELAY and try again
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(requestManager);
        priorityQueue.fulfillRequests(requests);

        assertTrue(priorityQueue.isFinalized(requestId), "Request should be finalized after maturity");
    }

    function test_fulfillRequests_revertAlreadyFinalized() public {
        uint96 withdrawAmount = 10 ether;

        (, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, withdrawAmount);

        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;

        // First fulfill succeeds
        vm.prank(requestManager);
        priorityQueue.fulfillRequests(requests);

        // Second fulfill fails
        vm.prank(requestManager);
        vm.expectRevert(PriorityWithdrawalQueue.RequestAlreadyFinalized.selector);
        priorityQueue.fulfillRequests(requests);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  CLAIM TESTS  -----------------------------------------
    //--------------------------------------------------------------------------------------

    function test_claimWithdraw() public {
        uint96 withdrawAmount = 10 ether;

        // Setup: VIP user creates a withdrawal request
        (bytes32 requestId, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, withdrawAmount);

        // Request manager fulfills the request
        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;
        vm.prank(requestManager);
        priorityQueue.fulfillRequests(requests);

        // Record state before claim
        uint256 userEthBefore = vipUser.balance;
        uint256 queueEethBefore = eETHInstance.balanceOf(address(priorityQueue));
        uint256 remainderBefore = priorityQueue.totalRemainderShares();

        // VIP user claims their ETH
        vm.prank(vipUser);
        priorityQueue.claimWithdraw(request);
        
        // Verify ETH was received (approximately, due to share price)
        assertApproxEqRel(vipUser.balance, userEthBefore + withdrawAmount, 0.001e18, "User should receive ETH");
        
        // Verify eETH was burned from queue
        assertLt(eETHInstance.balanceOf(address(priorityQueue)), queueEethBefore, "Queue eETH balance should decrease");

        // Verify request was removed
        assertFalse(priorityQueue.requestExists(requestId), "Request should be removed");
        assertFalse(priorityQueue.isFinalized(requestId), "Request should no longer be finalized");

        // Verify remainder tracking
        assertGe(priorityQueue.totalRemainderShares(), remainderBefore, "Remainder shares should increase or stay same");
    }

    function test_batchClaimWithdraw() public {
        uint96 amount1 = 5 ether;
        uint96 amount2 = 3 ether;

        // Create two requests
        (, IPriorityWithdrawalQueue.WithdrawRequest memory request1) = 
            _createWithdrawRequest(vipUser, amount1);
        (, IPriorityWithdrawalQueue.WithdrawRequest memory request2) = 
            _createWithdrawRequest(vipUser, amount2);

        // Fulfill both
        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](2);
        requests[0] = request1;
        requests[1] = request2;
        vm.prank(requestManager);
        priorityQueue.fulfillRequests(requests);

        // Record state before claim
        uint256 ethBefore = vipUser.balance;

        // Batch claim
        vm.prank(vipUser);
        priorityQueue.batchClaimWithdraw(requests);

        // Verify ETH received
        assertApproxEqRel(vipUser.balance, ethBefore + amount1 + amount2, 0.001e18, "All ETH should be received");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  CANCEL TESTS  ----------------------------------------
    //--------------------------------------------------------------------------------------

    function test_cancelWithdraw() public {
        uint96 withdrawAmount = 10 ether;

        // Create request
        uint256 eethBefore = eETHInstance.balanceOf(vipUser);
        
        (bytes32 requestId, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, withdrawAmount);
        
        uint256 eethAfterRequest = eETHInstance.balanceOf(vipUser);

        // Verify request state (use approximate comparison due to share/amount rounding)
        assertApproxEqAbs(eethAfterRequest, eethBefore - withdrawAmount, 1, "eETH transferred to queue");

        // Cancel request
        vm.prank(vipUser);
        bytes32 cancelledId = priorityQueue.cancelWithdraw(request);

        // Verify state changes
        assertEq(cancelledId, requestId, "Cancelled ID should match");
        assertFalse(priorityQueue.requestExists(requestId), "Request should be removed");
        // eETH returned might have small rounding difference
        assertApproxEqAbs(eETHInstance.balanceOf(vipUser), eethBefore, 1, "eETH should be returned");
    }

    function test_cancelWithdraw_finalized() public {
        uint96 withdrawAmount = 10 ether;

        // Record initial balance
        uint256 eethInitial = eETHInstance.balanceOf(vipUser);

        // Create and fulfill request
        (bytes32 requestId, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, withdrawAmount);

        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;
        vm.prank(requestManager);
        priorityQueue.fulfillRequests(requests);

        uint128 lpLockedBefore = liquidityPoolInstance.ethAmountLockedForPriorityWithdrawal();

        // Request manager cancels finalized request (invalidateRequests requires request manager role)
        vm.prank(requestManager);
        bytes32[] memory cancelledIds = priorityQueue.invalidateRequests(requests);

        // Verify state changes
        assertEq(cancelledIds[0], requestId, "Cancelled ID should match");
        assertFalse(priorityQueue.requestExists(requestId), "Request should be removed");
        assertFalse(priorityQueue.isFinalized(requestId), "Request should no longer be finalized");
        
        // eETH should be returned (approximately due to share rounding)
        assertApproxEqAbs(eETHInstance.balanceOf(vipUser), eethInitial, 1, "eETH should be returned");
        
        // LP locked should decrease
        assertLt(liquidityPoolInstance.ethAmountLockedForPriorityWithdrawal(), lpLockedBefore, "LP locked should decrease");
    }

    function test_admininvalidateRequests() public {
        uint96 withdrawAmount = 10 ether;

        // Record initial balance before request
        uint256 eethInitial = eETHInstance.balanceOf(vipUser);

        // Create request
        (, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, withdrawAmount);

        // Request manager cancels (invalidateRequests requires request manager role)
        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;
        
        vm.prank(requestManager);
        bytes32[] memory cancelledIds = priorityQueue.invalidateRequests(requests);

        // Verify state changes
        assertEq(cancelledIds.length, 1, "Should cancel one request");
        // eETH should return to approximately initial balance (small rounding due to share conversion)
        assertApproxEqAbs(eETHInstance.balanceOf(vipUser), eethInitial, 1, "eETH should be returned");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  FULL FLOW TESTS  -------------------------------------
    //--------------------------------------------------------------------------------------

    function test_fullWithdrawalFlow() public {
        // This test verifies the complete flow from deposit to withdrawal
        uint96 withdrawAmount = 5 ether;

        // 1. VIP user already has eETH from setUp
        uint256 initialEethBalance = eETHInstance.balanceOf(vipUser);
        uint256 initialEthBalance = vipUser.balance;

        // 2. Request withdrawal
        (, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, withdrawAmount);

        // Verify intermediate state (use approximate comparison due to share/amount rounding)
        assertApproxEqAbs(eETHInstance.balanceOf(vipUser), initialEethBalance - withdrawAmount, 1, "eETH transferred to queue");
        assertTrue(priorityQueue.requestExists(priorityQueue.getRequestId(request)), "Request should exist");

        // 3. Request manager fulfills the request
        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;
        vm.prank(requestManager);
        priorityQueue.fulfillRequests(requests);

        // Verify fulfilled state
        assertTrue(priorityQueue.isFinalized(priorityQueue.getRequestId(request)), "Request should be finalized");
        assertGt(liquidityPoolInstance.ethAmountLockedForPriorityWithdrawal(), 0, "LP tracks locked amount");

        // 4. VIP user claims ETH
        vm.prank(vipUser);
        priorityQueue.claimWithdraw(request);

        // Verify final state
        assertFalse(priorityQueue.requestExists(priorityQueue.getRequestId(request)), "Request should be removed");
        assertApproxEqRel(vipUser.balance, initialEthBalance + withdrawAmount, 0.001e18, "ETH received");
    }

    function test_multipleRequests() public {
        uint96 amount1 = 5 ether;
        uint96 amount2 = 3 ether;

        // Create two requests
        (, IPriorityWithdrawalQueue.WithdrawRequest memory request1) = 
            _createWithdrawRequest(vipUser, amount1);
        (, IPriorityWithdrawalQueue.WithdrawRequest memory request2) = 
            _createWithdrawRequest(vipUser, amount2);

        // Verify both requests tracked
        assertEq(priorityQueue.totalActiveRequests(), 2, "Should have 2 active requests");
        assertEq(priorityQueue.nonce(), 3, "Nonce should be 3");

        // Verify request IDs are in the list
        bytes32[] memory requestIds = priorityQueue.getRequestIds();
        assertEq(requestIds.length, 2, "Should have 2 request IDs");

        // Fulfill both at once
        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](2);
        requests[0] = request1;
        requests[1] = request2;
        vm.prank(requestManager);
        priorityQueue.fulfillRequests(requests);

        // Verify finalized request IDs
        bytes32[] memory finalizedIds = priorityQueue.getFinalizedRequestIds();
        assertEq(finalizedIds.length, 2, "Should have 2 finalized request IDs");

        // Claim both
        uint256 ethBefore = vipUser.balance;
        vm.startPrank(vipUser);
        priorityQueue.claimWithdraw(request1);
        priorityQueue.claimWithdraw(request2);
        vm.stopPrank();

        // Verify final state
        assertEq(priorityQueue.totalActiveRequests(), 0, "All claimed");
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

    function test_revert_addZeroAddressToWhitelist() public {
        vm.prank(alice);
        vm.expectRevert(PriorityWithdrawalQueue.AddressZero.selector);
        priorityQueue.addToWhitelist(address(0));
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  CONFIG TESTS  ----------------------------------------
    //--------------------------------------------------------------------------------------

    //--------------------------------------------------------------------------------------
    //------------------------------  PAUSE TESTS  -----------------------------------------
    //--------------------------------------------------------------------------------------

    function test_pauseContract() public {
        assertFalse(priorityQueue.paused(), "Should not be paused initially");

        vm.prank(alice);
        priorityQueue.pauseContract();

        assertTrue(priorityQueue.paused(), "Should be paused after pauseContract");

        // Cannot request withdraw when paused
        vm.startPrank(vipUser);
        eETHInstance.approve(address(priorityQueue), 1 ether);
        vm.expectRevert(PriorityWithdrawalQueue.ContractPaused.selector);
        priorityQueue.requestWithdraw(1 ether);
        vm.stopPrank();
    }

    function test_unPauseContract() public {
        vm.prank(alice);
        priorityQueue.pauseContract();
        assertTrue(priorityQueue.paused(), "Should be paused");

        vm.prank(alice);
        priorityQueue.unPauseContract();
        assertFalse(priorityQueue.paused(), "Should be unpaused");
    }

    function test_revert_pauseWhenAlreadyPaused() public {
        vm.prank(alice);
        priorityQueue.pauseContract();

        vm.prank(alice);
        vm.expectRevert(PriorityWithdrawalQueue.ContractPaused.selector);
        priorityQueue.pauseContract();
    }

    function test_revert_unpauseWhenNotPaused() public {
        vm.prank(alice);
        vm.expectRevert(PriorityWithdrawalQueue.ContractNotPaused.selector);
        priorityQueue.unPauseContract();
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  REMAINDER TESTS  -------------------------------------
    //--------------------------------------------------------------------------------------

    function test_handleRemainder() public {
        // First create and complete a withdrawal to accumulate remainder
        uint96 withdrawAmount = 10 ether;
        (, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, withdrawAmount);

        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;
        
        vm.prank(requestManager);
        priorityQueue.fulfillRequests(requests);

        vm.prank(vipUser);
        priorityQueue.claimWithdraw(request);

        uint256 remainderAmount = priorityQueue.getRemainderAmount();
        
        // Only test if there are remainder shares
        if (remainderAmount > 0) {
            uint256 amountToHandle = remainderAmount / 2;
            uint256 remainderBefore = priorityQueue.totalRemainderShares();

            vm.prank(alice);
            priorityQueue.handleRemainder(amountToHandle);

            assertLt(priorityQueue.totalRemainderShares(), remainderBefore, "Remainder should decrease");
        }
    }

    // function test_handleRemainder_withTreasurySplit() public {
    //     // Set 50% split to treasury (5000 bps)
    //     vm.prank(alice);
    //     priorityQueue.updateShareRemainderSplitToTreasury(5000);

    //     // Create and complete a withdrawal to accumulate remainder
    //     uint96 withdrawAmount = 10 ether;
    //     (, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
    //         _createWithdrawRequest(vipUser, withdrawAmount);

    //     IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
    //     requests[0] = request;
        
    //     vm.prank(requestManager);
    //     priorityQueue.fulfillRequests(requests);

    //     vm.prank(vipUser);
    //     priorityQueue.claimWithdraw(request);

    //     uint256 remainderAmount = priorityQueue.getRemainderAmount();
        
    //     // Only test if there are remainder shares
    //     if (remainderAmount > 0) {
    //         uint256 treasuryBalanceBefore = eETHInstance.balanceOf(treasury);
    //         uint256 remainderSharesBefore = priorityQueue.totalRemainderShares();

    //         vm.prank(alice);
    //         priorityQueue.handleRemainder(remainderAmount);

    //         // Verify treasury received ~50% of remainder as eETH
    //         uint256 treasuryBalanceAfter = eETHInstance.balanceOf(treasury);
    //         assertGt(treasuryBalanceAfter, treasuryBalanceBefore, "Treasury should receive eETH");
            
    //         // Approximately 50% should go to treasury (allowing for rounding)
    //         uint256 expectedToTreasury = remainderAmount / 2;
    //         assertApproxEqRel(treasuryBalanceAfter - treasuryBalanceBefore, expectedToTreasury, 0.01e18, "Treasury should receive ~50%");

    //         // Remainder should be cleared
    //         assertLt(priorityQueue.totalRemainderShares(), remainderSharesBefore, "Remainder shares should decrease");
    //     }
    // }

    // function test_handleRemainder_fullTreasurySplit() public {
    //     // Set 100% split to treasury (10000 bps)
    //     vm.prank(alice);
    //     priorityQueue.updateShareRemainderSplitToTreasury(10000);

    //     // Create and complete a withdrawal to accumulate remainder
    //     uint96 withdrawAmount = 10 ether;
    //     (, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
    //         _createWithdrawRequest(vipUser, withdrawAmount);

    //     IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
    //     requests[0] = request;
        
    //     vm.prank(requestManager);
    //     priorityQueue.fulfillRequests(requests);

    //     vm.prank(vipUser);
    //     priorityQueue.claimWithdraw(request);

    //     uint256 remainderAmount = priorityQueue.getRemainderAmount();
        
    //     if (remainderAmount > 0) {
    //         uint256 treasuryBalanceBefore = eETHInstance.balanceOf(treasury);

    //         vm.prank(alice);
    //         priorityQueue.handleRemainder(remainderAmount);

    //         // Verify treasury received all remainder as eETH (nothing burned)
    //         uint256 treasuryBalanceAfter = eETHInstance.balanceOf(treasury);
    //         assertApproxEqRel(treasuryBalanceAfter - treasuryBalanceBefore, remainderAmount, 0.01e18, "Treasury should receive ~100%");
    //     }
    // }

    // function test_handleRemainder_noBurn() public {
    //     // Set 0% split to treasury (all burn)
    //     vm.prank(alice);
    //     priorityQueue.updateShareRemainderSplitToTreasury(0);

    //     // Create and complete a withdrawal to accumulate remainder
    //     uint96 withdrawAmount = 10 ether;
    //     (, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
    //         _createWithdrawRequest(vipUser, withdrawAmount);

    //     IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
    //     requests[0] = request;
        
    //     vm.prank(requestManager);
    //     priorityQueue.fulfillRequests(requests);

    //     vm.prank(vipUser);
    //     priorityQueue.claimWithdraw(request);

    //     uint256 remainderAmount = priorityQueue.getRemainderAmount();
        
    //     if (remainderAmount > 0) {
    //         uint256 treasuryBalanceBefore = eETHInstance.balanceOf(treasury);

    //         vm.prank(alice);
    //         priorityQueue.handleRemainder(remainderAmount);

    //         // Verify treasury received nothing
    //         uint256 treasuryBalanceAfter = eETHInstance.balanceOf(treasury);
    //         assertEq(treasuryBalanceAfter, treasuryBalanceBefore, "Treasury should receive nothing");
    //     }
    // }

    function test_updateShareRemainderSplitToTreasury() public {
        assertEq(priorityQueue.shareRemainderSplitToTreasuryInBps(), 10000, "Initial split should be 100%");

        vm.prank(alice);
        priorityQueue.updateShareRemainderSplitToTreasury(5000);

        assertEq(priorityQueue.shareRemainderSplitToTreasuryInBps(), 5000, "Split should be updated to 50%");
    }

    function test_revert_updateShareRemainderSplitToTreasury_tooHigh() public {
        vm.prank(alice);
        vm.expectRevert(PriorityWithdrawalQueue.BadInput.selector);
        priorityQueue.updateShareRemainderSplitToTreasury(10001); // > 100%
    }

    function test_revert_updateShareRemainderSplitToTreasury_notAdmin() public {
        vm.prank(regularUser);
        vm.expectRevert(PriorityWithdrawalQueue.IncorrectRole.selector);
        priorityQueue.updateShareRemainderSplitToTreasury(5000);
    }

    function test_revert_handleRemainderTooMuch() public {
        vm.prank(alice);
        vm.expectRevert(PriorityWithdrawalQueue.BadInput.selector);
        priorityQueue.handleRemainder(1 ether);
    }

    function test_revert_handleRemainderZero() public {
        vm.prank(alice);
        vm.expectRevert(PriorityWithdrawalQueue.BadInput.selector);
        priorityQueue.handleRemainder(0);
    }

    function test_revert_handleRemainderNotFeeClaimer() public {
        vm.prank(regularUser);
        vm.expectRevert(PriorityWithdrawalQueue.IncorrectRole.selector);
        priorityQueue.handleRemainder(1 ether);
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
        priorityQueue.requestWithdraw(1 ether);
        vm.stopPrank();
    }

    function test_revert_claimNotFinalized() public {
        // Create request but don't fulfill
        (, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, 1 ether);
        
        vm.prank(vipUser);
        vm.expectRevert(PriorityWithdrawalQueue.RequestNotFinalized.selector);
        priorityQueue.claimWithdraw(request);
    }

    function test_revert_claimWrongOwner() public {
        // VIP creates request
        (, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, 1 ether);

        // Fulfill
        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;
        vm.prank(requestManager);
        priorityQueue.fulfillRequests(requests);

        // Another user tries to claim
        vm.prank(regularUser);
        vm.expectRevert(PriorityWithdrawalQueue.NotRequestOwner.selector);
        priorityQueue.claimWithdraw(request);
    }

    function test_revert_fulfillNonRequestManager() public {
        (, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, 1 ether);

        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;

        vm.prank(regularUser);
        vm.expectRevert(PriorityWithdrawalQueue.IncorrectRole.selector);
        priorityQueue.fulfillRequests(requests);
    }

    function test_revert_cancelWrongOwner() public {
        (, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, 1 ether);

        vm.prank(regularUser);
        vm.expectRevert(PriorityWithdrawalQueue.NotRequestOwner.selector);
        priorityQueue.cancelWithdraw(request);
    }

    function test_revert_amountTooSmall() public {
        vm.startPrank(vipUser);
        eETHInstance.approve(address(priorityQueue), 0.001 ether);
        
        // Default minimum amount is 0.01 ether
        vm.expectRevert(PriorityWithdrawalQueue.InvalidAmount.selector);
        priorityQueue.requestWithdraw(0.001 ether);
        vm.stopPrank();
    }

    function test_revert_requestNotFound() public {
        // Create a fake request that doesn't exist
        IPriorityWithdrawalQueue.WithdrawRequest memory fakeRequest = IPriorityWithdrawalQueue.WithdrawRequest({
            user: vipUser,
            amountOfEEth: 1 ether,
            shareOfEEth: 1 ether,
            nonce: 999,
            creationTime: uint32(block.timestamp)
        });

        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = fakeRequest;

        vm.prank(requestManager);
        vm.expectRevert(PriorityWithdrawalQueue.RequestNotFound.selector);
        priorityQueue.fulfillRequests(requests);
    }

    function test_revert_adminFunctionsNotAdmin() public {
        vm.startPrank(regularUser);
        
        vm.expectRevert(PriorityWithdrawalQueue.IncorrectRole.selector);
        priorityQueue.addToWhitelist(regularUser);

        vm.expectRevert(PriorityWithdrawalQueue.IncorrectRole.selector);
        priorityQueue.removeFromWhitelist(vipUser);

        vm.stopPrank();
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  GETTER TESTS  ----------------------------------------
    //--------------------------------------------------------------------------------------

    function test_getClaimableAmount() public {
        uint96 withdrawAmount = 10 ether;

        (, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequest(vipUser, withdrawAmount);

        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;
        
        vm.prank(requestManager);
        priorityQueue.fulfillRequests(requests);

        uint256 claimable = priorityQueue.getClaimableAmount(request);
        assertApproxEqRel(claimable, withdrawAmount, 0.001e18, "Claimable should be approximately the withdraw amount");
    }

    function test_generateWithdrawRequestId() public view {
        address testUser = vipUser;
        uint96 testAmount = 10 ether;
        uint96 testShare = uint96(liquidityPoolInstance.sharesForAmount(testAmount));
        uint32 testNonce = 1;
        uint32 testTime = uint32(block.timestamp);

        bytes32 generatedId = priorityQueue.generateWithdrawRequestId(
            testUser,
            testAmount,
            testShare,
            testNonce,
            testTime
        );

        // Verify it matches keccak256 of the struct
        IPriorityWithdrawalQueue.WithdrawRequest memory req = IPriorityWithdrawalQueue.WithdrawRequest({
            user: testUser,
            amountOfEEth: testAmount,
            shareOfEEth: testShare,
            nonce: testNonce,
            creationTime: testTime
        });
        bytes32 expectedId = keccak256(abi.encode(req));

        assertEq(generatedId, expectedId, "Generated ID should match");
    }

}
