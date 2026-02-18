// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "forge-std/console2.sol";

import "../src/PriorityWithdrawalQueue.sol";
import "../src/interfaces/IPriorityWithdrawalQueue.sol";

contract PriorityWithdrawalQueueTest is TestSetup {
    PriorityWithdrawalQueue public priorityQueue;
    PriorityWithdrawalQueue public priorityQueueImpl;

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
        priorityQueueImpl = new PriorityWithdrawalQueue(
            address(liquidityPoolInstance),
            address(eETHInstance),
            address(roleRegistryInstance),
            treasury,
            1 hours
        );
        UUPSProxy proxy = new UUPSProxy(
            address(priorityQueueImpl),
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
        return _createWithdrawRequestWithMinOut(user, amount, 0);
    }

    /// @dev Helper to create a withdrawal request with custom minAmountOut
    function _createWithdrawRequestWithMinOut(address user, uint96 amount, uint96 minAmountOut) 
        internal 
        returns (bytes32 requestId, IPriorityWithdrawalQueue.WithdrawRequest memory request) 
    {
        uint32 nonceBefore = priorityQueue.nonce();
        uint96 shareAmount = uint96(liquidityPoolInstance.sharesForAmount(amount));
        uint32 timestamp = uint32(block.timestamp);

        vm.startPrank(user);
        eETHInstance.approve(address(priorityQueue), amount);
        requestId = priorityQueue.requestWithdraw(amount, minAmountOut);
        vm.stopPrank();

        // Reconstruct the request struct
        request = IPriorityWithdrawalQueue.WithdrawRequest({
            user: user,
            amountOfEEth: amount,
            shareOfEEth: shareAmount,
            minAmountOut: minAmountOut,
            nonce: uint32(nonceBefore),
            creationTime: timestamp
        });

        // Warp time past MIN_DELAY (1 hour) to allow fulfill/cancel/claim operations
        vm.warp(block.timestamp + 1 hours + 1);
        vm.roll(block.number + 1);
    }

    function _rebase(int128 accruedRewards) internal {
        vm.prank(liquidityPoolInstance.membershipManager());
        liquidityPoolInstance.rebase(accruedRewards);
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

    function test_requestWithdrawWithPermit() public {
        uint256 userPrivKey = 999;
        address permitUser = vm.addr(userPrivKey);
        uint96 withdrawAmount = 1 ether;

        // Whitelist and fund the permit user
        vm.prank(alice);
        priorityQueue.addToWhitelist(permitUser);
        vm.deal(permitUser, 10 ether);
        vm.prank(permitUser);
        liquidityPoolInstance.deposit{value: 5 ether}();

        // Record initial state
        uint256 initialEethBalance = eETHInstance.balanceOf(permitUser);
        uint256 initialQueueEethBalance = eETHInstance.balanceOf(address(priorityQueue));
        uint96 initialNonce = priorityQueue.nonce();

        // Create valid permit
        IPriorityWithdrawalQueue.PermitInput memory permit = _createEEthPermitInput(
            userPrivKey,
            address(priorityQueue),
            withdrawAmount,
            eETHInstance.nonces(permitUser),
            block.timestamp + 1 hours
        );

        // Request withdrawal with permit
        vm.prank(permitUser);
        bytes32 requestId = priorityQueue.requestWithdrawWithPermit(withdrawAmount, 0, permit);

        // Verify state changes
        assertEq(priorityQueue.nonce(), initialNonce + 1, "Nonce should increment");
        assertApproxEqAbs(eETHInstance.balanceOf(permitUser), initialEethBalance - withdrawAmount, 2, "User eETH balance should decrease");
        assertApproxEqAbs(eETHInstance.balanceOf(address(priorityQueue)), initialQueueEethBalance + withdrawAmount, 2, "Queue eETH balance should increase");
        assertTrue(priorityQueue.requestExists(requestId), "Request should exist");
    }

    function test_requestWithdrawWithPermit_invalidPermit_reverts() public {
        uint256 userPrivKey = 999;
        address permitUser = vm.addr(userPrivKey);
        uint96 withdrawAmount = 1 ether;

        // Whitelist and fund the permit user
        vm.prank(alice);
        priorityQueue.addToWhitelist(permitUser);
        vm.deal(permitUser, 10 ether);
        vm.prank(permitUser);
        liquidityPoolInstance.deposit{value: 5 ether}();

        // Create invalid permit (wrong signature)
        IPriorityWithdrawalQueue.PermitInput memory invalidPermit = IPriorityWithdrawalQueue.PermitInput({
            value: withdrawAmount,
            deadline: block.timestamp + 1 hours,
            v: 27,
            r: bytes32(uint256(1)),
            s: bytes32(uint256(2))
        });

        // Request should revert with PermitFailedAndAllowanceTooLow
        vm.prank(permitUser);
        vm.expectRevert(PriorityWithdrawalQueue.PermitFailedAndAllowanceTooLow.selector);
        priorityQueue.requestWithdrawWithPermit(withdrawAmount, 0, invalidPermit);
    }

    function test_requestWithdrawWithPermit_expiredDeadline_reverts() public {
        uint256 userPrivKey = 999;
        address permitUser = vm.addr(userPrivKey);
        uint96 withdrawAmount = 1 ether;

        // Whitelist and fund the permit user
        vm.prank(alice);
        priorityQueue.addToWhitelist(permitUser);
        vm.deal(permitUser, 10 ether);
        vm.prank(permitUser);
        liquidityPoolInstance.deposit{value: 5 ether}();

        // Create permit with expired deadline
        IPriorityWithdrawalQueue.PermitInput memory expiredPermit = _createEEthPermitInput(
            userPrivKey,
            address(priorityQueue),
            withdrawAmount,
            eETHInstance.nonces(permitUser),
            block.timestamp - 1 // expired
        );

        // Request should revert with PermitFailedAndAllowanceTooLow
        vm.prank(permitUser);
        vm.expectRevert(PriorityWithdrawalQueue.PermitFailedAndAllowanceTooLow.selector);
        priorityQueue.requestWithdrawWithPermit(withdrawAmount, 0, expiredPermit);
    }

    function test_requestWithdrawWithPermit_replayAttack_reverts() public {
        uint256 userPrivKey = 999;
        address permitUser = vm.addr(userPrivKey);
        uint96 withdrawAmount = 1 ether;

        // Whitelist and fund the permit user
        vm.prank(alice);
        priorityQueue.addToWhitelist(permitUser);
        vm.deal(permitUser, 10 ether);
        vm.prank(permitUser);
        liquidityPoolInstance.deposit{value: 5 ether}();

        // Create valid permit
        IPriorityWithdrawalQueue.PermitInput memory permit = _createEEthPermitInput(
            userPrivKey,
            address(priorityQueue),
            withdrawAmount,
            eETHInstance.nonces(permitUser),
            block.timestamp + 1 hours
        );

        // First request should succeed
        vm.prank(permitUser);
        priorityQueue.requestWithdrawWithPermit(withdrawAmount, 0, permit);

        // Second request with same permit should revert (nonce already used)
        vm.prank(permitUser);
        vm.expectRevert(PriorityWithdrawalQueue.PermitFailedAndAllowanceTooLow.selector);
        priorityQueue.requestWithdrawWithPermit(withdrawAmount, 0, permit);
    }

    /// @dev Helper to create eETH permit input
    function _createEEthPermitInput(
        uint256 privKey,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (IPriorityWithdrawalQueue.PermitInput memory) {
        address _owner = vm.addr(privKey);
        bytes32 domainSeparator = eETHInstance.DOMAIN_SEPARATOR();
        bytes32 digest = _calculatePermitDigest(_owner, spender, value, nonce, deadline, domainSeparator);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, digest);
        return IPriorityWithdrawalQueue.PermitInput({
            value: value,
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });
    }

    /// @dev Calculate EIP-2612 permit digest
    function _calculatePermitDigest(
        address _owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline,
        bytes32 domainSeparator
    ) internal pure returns (bytes32) {
        bytes32 PERMIT_TYPEHASH = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, _owner, spender, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
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
        uint128 lpLockedBefore = priorityQueue.ethAmountLockedForPriorityWithdrawal();

        // Request manager fulfills the request
        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;

        vm.prank(requestManager);
        priorityQueue.fulfillRequests(requests);

        // Verify state changes
        assertEq(
            priorityQueue.ethAmountLockedForPriorityWithdrawal(),
            lpLockedBefore + withdrawAmount,
            "LP locked for priority should increase by raw request amount"
        );

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
        priorityQueue.requestWithdraw(withdrawAmount, 0);
        vm.stopPrank();

        IPriorityWithdrawalQueue.WithdrawRequest memory request = IPriorityWithdrawalQueue.WithdrawRequest({
            user: vipUser,
            amountOfEEth: withdrawAmount,
            shareOfEEth: shareAmount,
            minAmountOut: 0,
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

        // Anyone can send the ETH to the request user
        vm.prank(regularUser);
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

    function test_batchClaimWithdraw_singleRequest() public {
        uint96 withdrawAmount = 10 ether;

        (, IPriorityWithdrawalQueue.WithdrawRequest memory request) =
            _createWithdrawRequest(vipUser, withdrawAmount);

        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;

        vm.prank(requestManager);
        priorityQueue.fulfillRequests(requests);

        uint256 ethBefore = vipUser.balance;

        vm.prank(regularUser);
        priorityQueue.batchClaimWithdraw(requests);

        assertApproxEqRel(vipUser.balance, ethBefore + withdrawAmount, 0.001e18, "Single-item batch should deliver ETH");
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

        uint128 lpLockedBefore = priorityQueue.ethAmountLockedForPriorityWithdrawal();

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
        assertLt(priorityQueue.ethAmountLockedForPriorityWithdrawal(), lpLockedBefore, "LP locked should decrease");
    }

    function test_cancelWithdraw_afterNegativeRebase_returnsCurrentShareValue() public {
        uint96 withdrawAmount = 10 ether;

        (, IPriorityWithdrawalQueue.WithdrawRequest memory request) =
            _createWithdrawRequest(vipUser, withdrawAmount);

        // Create room for a slash and then apply a net negative rebase.
        _rebase(20 ether);
        _rebase(-25 ether);

        uint256 expectedReturned = liquidityPoolInstance.amountForShare(request.shareOfEEth);
        uint256 userBalanceBeforeCancel = eETHInstance.balanceOf(vipUser);
        assertLt(expectedReturned, withdrawAmount, "Share value should be lower after slash");

        vm.prank(vipUser);
        priorityQueue.cancelWithdraw(request);

        // User should only receive current value of their originally submitted shares.
        assertApproxEqAbs(
            eETHInstance.balanceOf(vipUser),
            userBalanceBeforeCancel + expectedReturned,
            2,
            "User balance increase should match slash-adjusted amount"
        );
        assertEq(priorityQueue.totalRemainderShares(), 0, "No remainder expected for this exact-ratio case");
    }

    function test_cancelWithdraw_afterPositiveRebase_tracksRemainderShares() public {
        uint96 withdrawAmount = 10 ether;

        (, IPriorityWithdrawalQueue.WithdrawRequest memory request) =
            _createWithdrawRequest(vipUser, withdrawAmount);

        // Positive rebase raises amount value per share.
        _rebase(5 ether);

        uint256 remainderBefore = priorityQueue.totalRemainderShares();
        uint256 userBalanceBeforeCancel = eETHInstance.balanceOf(vipUser);
        uint256 expectedReturned = liquidityPoolInstance.amountForShare(request.shareOfEEth);

        vm.prank(vipUser);
        priorityQueue.cancelWithdraw(request);

        assertGt(expectedReturned, withdrawAmount, "Share value should be higher after positive rebase");
        assertApproxEqAbs(
            eETHInstance.balanceOf(vipUser),
            userBalanceBeforeCancel + expectedReturned,
            2,
            "User balance increase should match current share value"
        );
        assertEq(
            priorityQueue.totalRemainderShares(),
            remainderBefore,
            "Cancel should not modify remainder shares"
        );
    }

    function test_claimWithdraw_recoveryAfterFulfill_doesNotDriftOrRevert() public {
        uint96 withdrawAmount = 10 ether;

        (, IPriorityWithdrawalQueue.WithdrawRequest memory request) =
            _createWithdrawRequest(vipUser, withdrawAmount);

        // Slash before fulfill, then partial recovery before claim.
        _rebase(20 ether);
        _rebase(-25 ether);

        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;
        vm.prank(requestManager);
        priorityQueue.fulfillRequests(requests);

        uint256 lockedAtFulfill = request.amountOfEEth;
        assertEq(lockedAtFulfill, withdrawAmount, "Lock should use raw request amount");

        // Recover after fulfill. Claim should not exceed the stored lock.
        _rebase(15 ether);

        uint256 ethBefore = vipUser.balance;
        vm.prank(vipUser);
        priorityQueue.claimWithdraw(request);

        uint256 expectedClaim = liquidityPoolInstance.amountForShare(request.shareOfEEth);
        if (expectedClaim > request.amountOfEEth) expectedClaim = request.amountOfEEth;

        assertApproxEqAbs(vipUser.balance, ethBefore + expectedClaim, 2, "Claim amount should follow min(request, current share value)");
        assertEq(priorityQueue.ethAmountLockedForPriorityWithdrawal(), 0, "Global lock should clear exactly");
    }

    function test_cancelWithdraw_finalizedRecoveryAfterFulfill_doesNotDrift() public {
        uint96 withdrawAmount = 10 ether;

        (, IPriorityWithdrawalQueue.WithdrawRequest memory request) =
            _createWithdrawRequest(vipUser, withdrawAmount);

        // Slash before fulfill, then strong recovery before invalidate.
        _rebase(20 ether);
        _rebase(-25 ether);

        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;
        vm.prank(requestManager);
        priorityQueue.fulfillRequests(requests);

        uint256 lockedAtFulfill = request.amountOfEEth;
        assertEq(lockedAtFulfill, withdrawAmount, "Lock should use raw request amount");

        // Recover after fulfill then invalidate.
        _rebase(15 ether);
        uint256 userBalanceBeforeCancel = eETHInstance.balanceOf(vipUser);
        uint256 expectedReturned = liquidityPoolInstance.amountForShare(request.shareOfEEth);

        vm.prank(requestManager);
        priorityQueue.invalidateRequests(requests);

        assertGt(expectedReturned, lockedAtFulfill, "Recovery should increase current share value above locked amount");
        assertApproxEqAbs(
            eETHInstance.balanceOf(vipUser),
            userBalanceBeforeCancel + expectedReturned,
            2,
            "Finalized cancel should return current share value"
        );
        assertEq(priorityQueue.ethAmountLockedForPriorityWithdrawal(), 0, "Global lock should clear exactly");
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
        assertGt(priorityQueue.ethAmountLockedForPriorityWithdrawal(), 0, "LP tracks locked amount");

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
        priorityQueue.requestWithdraw(1 ether, 0);
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

    function test_handleRemainder_roundsTreasurySplitUp() public {
        vm.prank(alice);
        priorityQueue.updateShareRemainderSplitToTreasury(5000); // 50%

        // Create and complete a withdrawal to accumulate remainder
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
        if (remainderAmount <= 1) return;

        // Force an odd amount so 50% split requires rounding.
        uint256 amountToHandle = remainderAmount % 2 == 0 ? remainderAmount - 1 : remainderAmount;
        uint256 treasuryBalanceBefore = eETHInstance.balanceOf(treasury);

        vm.prank(alice);
        priorityQueue.handleRemainder(amountToHandle);

        uint256 treasuryReceived = eETHInstance.balanceOf(treasury) - treasuryBalanceBefore;
        uint256 expectedTreasuryAmount = (amountToHandle + 1) / 2;
        assertEq(amountToHandle % 2, 1, "Test setup must use odd amount");
        assertEq(treasuryReceived, expectedTreasuryAmount, "Treasury split should round up");
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
        priorityQueue.requestWithdraw(1 ether, 0);
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
        priorityQueue.requestWithdraw(0.001 ether, 0);
        vm.stopPrank();
    }

    function test_revert_requestNotFound() public {
        // Create a fake request that doesn't exist
        IPriorityWithdrawalQueue.WithdrawRequest memory fakeRequest = IPriorityWithdrawalQueue.WithdrawRequest({
            user: vipUser,
            amountOfEEth: 1 ether,
            shareOfEEth: 1 ether,
            minAmountOut: 0,
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
        uint96 testMinOut = 9.5 ether;
        uint32 testNonce = 1;
        uint32 testTime = uint32(block.timestamp);

        bytes32 generatedId = priorityQueue.generateWithdrawRequestId(
            testUser,
            testAmount,
            testShare,
            testMinOut,
            testNonce,
            testTime
        );

        // Verify it matches keccak256 of the struct
        IPriorityWithdrawalQueue.WithdrawRequest memory req = IPriorityWithdrawalQueue.WithdrawRequest({
            user: testUser,
            amountOfEEth: testAmount,
            shareOfEEth: testShare,
            minAmountOut: testMinOut,
            nonce: testNonce,
            creationTime: testTime
        });
        bytes32 expectedId = keccak256(abi.encode(req));

        assertEq(generatedId, expectedId, "Generated ID should match");
    }

    function test_revert_insufficientOutputAmount() public {
        // User requests with a high minAmountOut that won't be met after fees
        uint96 withdrawAmount = 1 ether;
        uint96 highMinOut = 1.1 ether; // Higher than possible output

        (bytes32 requestId, IPriorityWithdrawalQueue.WithdrawRequest memory request) = 
            _createWithdrawRequestWithMinOut(vipUser, withdrawAmount, highMinOut);

        // Fulfill the request
        IPriorityWithdrawalQueue.WithdrawRequest[] memory requests = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        requests[0] = request;
        
        vm.prank(requestManager);
        priorityQueue.fulfillRequests(requests);

        // Claim should revert due to insufficient output
        vm.prank(vipUser);
        vm.expectRevert(PriorityWithdrawalQueue.InsufficientOutputAmount.selector);
        priorityQueue.claimWithdraw(request);
    }

}
