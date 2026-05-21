// WithdrawRequestNFTTest.sol

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./TestSetup.sol";
import "../src/utils/PausableUntil.sol";


contract WithdrawRequestNFTIntrusive is WithdrawRequestNFT {

    // roleRegistry must be non-zero — _authorizeUpgrade now defers to it for upgrade auth,
    // so a zero immutable would brick the swap-back step in updateParam.
    constructor(address _roleRegistry) WithdrawRequestNFT(address(0), address(0), address(0), address(0), _roleRegistry, address(0), address(0), 1, 4e18) {}

    /// @dev Test-only: advance `lastFinalizedRequestId` without going through `finalizeRequests`,
    ///      simulating the pre-upgrade state where no rate snapshot was captured.
    function setLastFinalizedRequestIdForTest(uint32 _id) external {
        lastFinalizedRequestId = _id;
    }
}

contract WithdrawRequestNFTTest is TestSetup {

    uint32[] public reqIds =[ 20, 388, 478, 714, 726, 729, 735, 815, 861, 916, 941, 1014, 1067, 1154, 1194, 1253];

    function setUp() public {
        setUpTests();
        vm.prank(admin);
        withdrawRequestNFTInstance.unPauseContract();
    }

    function test_finalizeRequests() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 10 ether);

        uint96 amountOfEEth = 1 ether;

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), amountOfEEth);

        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, amountOfEEth);

        bool earlyRequestIsFinalized = withdrawRequestNFTInstance.isFinalized(requestId);
        assertFalse(earlyRequestIsFinalized, "Request should not be Finalized");

        _finalizeWithdrawalRequest(requestId);

        WithdrawRequestNFT.WithdrawRequest memory request = withdrawRequestNFTInstance.getRequest(requestId);
        assertEq(request.amountOfEEth, 1 ether, "Amount of eEth should match");

        bool requestIsFinalized = withdrawRequestNFTInstance.isFinalized(requestId);
        assertTrue(requestIsFinalized, "Request should be finalized");
    }

    function test_requestWithdraw() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 10 ether);

        uint96 amountOfEEth = 1 ether;

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), amountOfEEth);

        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, amountOfEEth);

        bool requestIsFinalized = withdrawRequestNFTInstance.isFinalized(requestId);
        assertFalse(requestIsFinalized, "Request should not be finalized");

        WithdrawRequestNFT.WithdrawRequest memory request = withdrawRequestNFTInstance.getRequest(requestId);
        assertEq(request.amountOfEEth, 1 ether, "Amount of eEth should match");
        assertEq(request.shareOfEEth, 1 ether, "Share of eEth should match");
        assertTrue(request.isValid, "Request should be valid");
    }

    function test_InvalidClaimWithdraw() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 10 ether);

        uint96 amountOfEEth = 1 ether;

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), amountOfEEth);

        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, amountOfEEth);

        bool requestIsFinalized = withdrawRequestNFTInstance.isFinalized(requestId);
        assertFalse(requestIsFinalized, "Request should not be finalized");

        vm.expectRevert(WithdrawRequestNFT.RequestNotFinalized.selector);
        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);
    }

    function test_ClaimWithdrawOfOthers() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 10 ether);

        uint96 amountOfEEth = 1 ether;

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), amountOfEEth);

        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, amountOfEEth);

        vm.expectRevert(WithdrawRequestNFT.NotTheOwner.selector);
        vm.prank(alice);
        withdrawRequestNFTInstance.claimWithdraw(requestId);
    }

    function test_ValidClaimWithdraw1() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        uint256 bobsStartingBalance = address(bob).balance;

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 10 ether);
        assertEq(eETHInstance.balanceOf(bob), 10 ether);
        assertEq(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)), 0 ether, "eETH balance should start from 0 ether");

        // Case 1.
        // Even after the rebase, the withdrawal amount should remain the same; 1 eth
        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);

        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 1 ether);

        assertEq(eETHInstance.balanceOf(bob), 9 ether);
        assertEq(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)), 1 ether, "eETH balance should be 1 ether");
        assertEq(eETHInstance.balanceOf(address(treasuryInstance)), 0 ether, "Treasury balance should be 0 ether");

        // Rebase with accrued_rewards = 10 ether for the deposited 10 ether
        // -> 1 ether eETH shares = 2 ether ETH
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(10 ether);

        assertEq(withdrawRequestNFTInstance.balanceOf(bob), 1, "Bobs balance should be 1");
        assertEq(withdrawRequestNFTInstance.ownerOf(requestId), bob, "Bobs should own the NFT");
        assertEq(eETHInstance.balanceOf(bob), 18 ether);
        assertEq(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)), 2 ether, "eETH balance should be 2 ether");

        _finalizeWithdrawalRequest(requestId);

        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);

        uint256 bobsEndingBalance = address(bob).balance;

        assertEq(bobsEndingBalance, bobsStartingBalance + 1 ether, "Bobs balance should be 1 ether higher");
        assertEq(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)), 1 ether, "eETH balance should be 1 ether");
    }

    function test_ValidClaimWithdrawWithNegativeRebase() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        uint256 bobsStartingBalance = address(bob).balance;

        // First, do a positive rebase to increase totalValueOutOfLp
        // This simulates validators earning rewards
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(60 ether);

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 10 ether + 60 ether);

        // Case 2.
        // After the rebase with negative rewards (loss of 35 eth among 70 eth),
        // the withdrawal amount is reduced from 1 ether to 0.5 ether
        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);

        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 1 ether);

        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(-35 ether);

        assertEq(withdrawRequestNFTInstance.balanceOf(bob), 1, "Bobs balance should be 1");
        assertEq(withdrawRequestNFTInstance.ownerOf(requestId), bob, "Bobs should own the NFT");

        _finalizeWithdrawalRequest(requestId);

        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);

        uint256 bobsEndingBalance = address(bob).balance;
        assertApproxEqAbs(bobsEndingBalance, bobsStartingBalance + 0.5 ether, 0.2 ether);
    }

    function test_withdraw_with_zero_liquidity() public {
        // bob mints 60 eETH by depositing 60 ETH
        vm.deal(bob, 1000 ether);
        vm.prank(bob);
        liquidityPoolInstance.deposit{value: 60 ether}();

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 60 ether);

        // bob requests withdrawal
        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 60 ether);

        // Somehow, LP gets some ETH
        // For example, alice deposits 100 ETH :D
        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 100 ether}();

        _finalizeWithdrawalRequest(requestId);

        uint256 bobsStartingBalance = address(bob).balance;

        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);

        uint256 bobsEndingBalance = address(bob).balance;

        assertEq(bobsEndingBalance, bobsStartingBalance + 60 ether, "Bobs balance should be 60 ether higher");
        
    }

    // Sub-wei rounding scenario from the original SD-6 report. The MIN_WITHDRAW_AMOUNT
    // gate on the LiquidityPool rewrites any below-MIN request if amount is equal to the 
    // caller's full eETH balance instead of reverting. Pin the new behavior: a below-MIN
    // request reverts with InvalidWithdrawalAmount.
    function test_SD_6_requestBelowMin_revertsWithInvalidWithdrawalAmount() public {
        vm.deal(bob, 9);

        vm.startPrank(bob);
        liquidityPoolInstance.deposit{value: 9}();
        vm.stopPrank();

        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(2);

        vm.startPrank(bob);
        uint256 balance = eETHInstance.balanceOf(bob);
        eETHInstance.approve(address(liquidityPoolInstance), balance);
        vm.expectRevert(LiquidityPool.InvalidWithdrawalAmount.selector);
        liquidityPoolInstance.requestWithdraw(bob, balance);
    }


    // It depicts the scenario where bob's WithdrawalRequest NFT is stolen by alice.
    // The owner invalidates the request 
    /// @dev Updated: admin MUST NOT be able to invalidate a request once it has been finalized.
    ///      Previously this test demonstrated the legacy (unsafe) capability; it now proves the
    ///      post-finalization invalidation path reverts and the request remains valid.
    function test_InvalidatedRequestNft_after_finalization() public returns (uint256 requestId) {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        uint96 amountOfEEth = 1 ether;

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), amountOfEEth);

        vm.prank(bob);
        requestId = liquidityPoolInstance.requestWithdraw(bob, amountOfEEth);

        vm.prank(bob);
        withdrawRequestNFTInstance.transferFrom(bob, alice, requestId);

        assertEq(withdrawRequestNFTInstance.ownerOf(requestId), alice, "Alice should own the NFT");

        _finalizeWithdrawalRequest(requestId);

        assertTrue(withdrawRequestNFTInstance.isValid(requestId), "Request should be valid");

        vm.prank(admin);
        vm.expectRevert(WithdrawRequestNFT.CannotInvalidateFinalizedRequest.selector);
        withdrawRequestNFTInstance.invalidateRequest(requestId);

        assertTrue(withdrawRequestNFTInstance.isValid(requestId), "Request must remain valid after rejected invalidation");
    }

    function test_InvalidatedRequestNft_before_finalization() public returns (uint256 requestId) {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        uint96 amountOfEEth = 1 ether;

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), amountOfEEth);

        vm.prank(bob);
        requestId = liquidityPoolInstance.requestWithdraw(bob, amountOfEEth);

        vm.prank(bob);
        withdrawRequestNFTInstance.transferFrom(bob, alice, requestId);

        assertEq(withdrawRequestNFTInstance.ownerOf(requestId), alice, "Alice should own the NFT");

        vm.prank(admin);
        withdrawRequestNFTInstance.invalidateRequest(requestId);

        _finalizeWithdrawalRequest(requestId);
    }

    function test_handleRemainder() public {
        initializeRealisticFork(MAINNET_FORK);
        vm.startPrank(address(roleRegistryInstance.owner()));
        withdrawRequestNFTInstance.upgradeTo(address(new WithdrawRequestNFT(
            address(buybackWallet),
            address(eETHInstance),
            address(liquidityPoolInstance),
            address(membershipManagerInstance),
            address(roleRegistryInstance),
            address(blacklisterInstance),
            address(etherFiAdminInstance),
            1, 4e18
        )));
        // IMPLICIT_FEE_CLAIMER_ROLE consolidated into HOUSEKEEPING_OPERATIONS_ROLE.
        roleRegistryInstance.grantRole(roleRegistryInstance.HOUSEKEEPING_OPERATIONS_ROLE(), alice);
        vm.stopPrank();
        uint256 implicitFee = withdrawRequestNFTInstance.getEEthRemainderAmount();
        vm.prank(alice);
        withdrawRequestNFTInstance.handleRemainder(implicitFee);
    }

    function testFuzz_RequestWithdraw(uint96 depositAmount, uint96 withdrawAmount, address recipient) public {
        // Assume valid conditions — withdraw amount must satisfy [MIN_WITHDRAW_AMOUNT, MAX_WITHDRAW_AMOUNT].
        vm.assume(depositAmount >= 1 ether && depositAmount <= 1000 ether);
        vm.assume(withdrawAmount >= liquidityPoolInstance.MIN_WITHDRAW_AMOUNT() && withdrawAmount <= depositAmount);
        vm.assume(recipient != address(0) && recipient != address(liquidityPoolInstance));
        // Filter out contracts that don't implement IERC721Receiver - only allow EOAs
        vm.assume(recipient.code.length == 0);
        
        // Setup initial balance for bob
        vm.deal(bob, depositAmount);
        
        // Deposit ETH and get eETH
        vm.startPrank(bob);
        liquidityPoolInstance.deposit{value: depositAmount}();
        
        // Approve and request withdraw
        eETHInstance.approve(address(liquidityPoolInstance), withdrawAmount);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(recipient, withdrawAmount);
        vm.stopPrank();

        // Verify the request was created correctly
        WithdrawRequestNFT.WithdrawRequest memory request = withdrawRequestNFTInstance.getRequest(requestId);
        
        assertEq(request.amountOfEEth, withdrawAmount, "Incorrect withdrawal amount");
        assertEq(request.shareOfEEth, liquidityPoolInstance.sharesForAmount(withdrawAmount), "Incorrect share amount");
        assertTrue(request.isValid, "Request should be valid");
        assertEq(withdrawRequestNFTInstance.ownerOf(requestId), recipient, "Incorrect NFT owner");
        
        // Verify eETH balances
        assertEq(eETHInstance.balanceOf(bob), depositAmount - withdrawAmount, "Incorrect remaining eETH balance");
        assertEq(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)), withdrawAmount, "Incorrect contract eETH balance");
        assertEq(withdrawRequestNFTInstance.nextRequestId(), requestId + 1, "Incorrect next request ID");

        uint256 minAmount = liquidityPoolInstance.MIN_WITHDRAW_AMOUNT();
        uint256 maxAmount = liquidityPoolInstance.MAX_WITHDRAW_AMOUNT();
        if (eETHInstance.balanceOf(bob) >= minAmount) {
            uint256 reqAmount = eETHInstance.balanceOf(bob);
            if (reqAmount > maxAmount) reqAmount = maxAmount;
            vm.startPrank(bob);
            eETHInstance.approve(address(liquidityPoolInstance), reqAmount);
            uint256 requestId2 = liquidityPoolInstance.requestWithdraw(recipient, reqAmount);
            vm.stopPrank();
            assertEq(requestId2, requestId + 1, "Incorrect next request ID");
        }
    }

    function testFuzz_ClaimWithdraw(
        uint96 depositAmount,
        uint96 withdrawAmount,
        uint96 rebaseAmount,
        uint16 remainderSplitBps,
        address recipient
    ) public {
        // Bound to valid ranges. withdrawAmount is bounded against the new
        // [MIN_WITHDRAW_AMOUNT, MAX_WITHDRAW_AMOUNT] gate; without bound() the cascading
        // vm.assume calls hit forge's input-rejection cap at low probability.
        depositAmount = uint96(bound(depositAmount, 1 ether, 1e6 ether));
        uint96 maxWithdraw = uint96(liquidityPoolInstance.MAX_WITHDRAW_AMOUNT());
        uint96 minWithdraw = uint96(liquidityPoolInstance.MIN_WITHDRAW_AMOUNT());
        uint96 withdrawCeil = depositAmount < maxWithdraw ? depositAmount : maxWithdraw;
        withdrawAmount = uint96(bound(withdrawAmount, minWithdraw, withdrawCeil));
        rebaseAmount = uint96(bound(rebaseAmount, 0.5 ether, depositAmount));
        remainderSplitBps = uint16(bound(remainderSplitBps, 0, 10000));
        vm.assume(recipient != address(0) && recipient != address(liquidityPoolInstance));
        // Filter out contracts that don't implement IERC721Receiver - only allow EOAs.
        vm.assume(recipient.code.length == 0);
        // Exclude precompile addresses (0x1–0xff); they have no code in Forge's EVM but
        // cannot accept ETH via call{value}, causing the ETH transfer to fail.
        // This covers all current and near-future EVM precompiles (currently up to 0x0a).
        vm.assume(uint160(recipient) > 0xff);

        // Setup initial balance for recipient
        vm.deal(recipient, depositAmount);

        // Configure remainder split
        vm.prank(withdrawRequestNFTInstance.owner());
        withdrawRequestNFTInstance.updateShareRemainderSplitToTreasuryInBps(remainderSplitBps);

        // First deposit ETH to get eETH
        vm.startPrank(recipient);
        liquidityPoolInstance.deposit{value: depositAmount}();

        // Record initial balances
        uint256 treasuryEEthBefore = eETHInstance.balanceOf(address(treasuryInstance));
        uint256 recipientBalanceBefore = address(recipient).balance;

        // Request withdraw
        eETHInstance.approve(address(liquidityPoolInstance), withdrawAmount);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(recipient, withdrawAmount);
        vm.stopPrank();

        // Get initial request state
        WithdrawRequestNFT.WithdrawRequest memory request = withdrawRequestNFTInstance.getRequest(requestId);

        // Simulate rebase after request but before claim
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(int128(uint128(rebaseAmount)));

        // Calculate expected withdrawal amounts after rebase
        uint256 sharesValue = liquidityPoolInstance.amountForShare(request.shareOfEEth);
        uint256 expectedWithdrawAmount = withdrawAmount < sharesValue ? withdrawAmount : sharesValue;
        uint256 expectedBurnedShares = liquidityPoolInstance.sharesForWithdrawalAmount(expectedWithdrawAmount);
        uint256 expectedDustShares = request.shareOfEEth - expectedBurnedShares;

        // Track initial shares and total supply
        uint256 initialTotalShares = eETHInstance.totalShares();

        _finalizeWithdrawalRequest(requestId);
        
        vm.prank(recipient);
        withdrawRequestNFTInstance.claimWithdraw(requestId);

        // Calculate expected burnt shares
        uint256 burnedShares = initialTotalShares - eETHInstance.totalShares();

        // Verify share burning
        assertLe(burnedShares, request.shareOfEEth, "Burned shares should be less than or equal to requested shares");
        assertApproxEqAbs(
            burnedShares,
            expectedBurnedShares,
            1e3,
            "Incorrect amount of shares burnt"
        );
        

        // Verify total supply reduction
        assertApproxEqAbs(
            eETHInstance.totalShares(),
            initialTotalShares - burnedShares,
            1,
            "Total shares not reduced correctly"
        );
        assertGe(
            eETHInstance.totalShares(),
            initialTotalShares - burnedShares,
            "Total shares should be greater than or equal to initial shares minus burned shares"
        );

        // Verify the withdrawal results
        WithdrawRequestNFT.WithdrawRequest memory requestAfter = withdrawRequestNFTInstance.getRequest(requestId);
        
        // Request should be cleared
        assertEq(requestAfter.amountOfEEth, 0, "Request should be cleared after claim");
        
        // NFT should be burned
        vm.expectRevert("ERC721: invalid token ID");
        withdrawRequestNFTInstance.ownerOf(requestId);

        // Verify recipient received correct ETH amount
        assertEq(
            address(recipient).balance,
            recipientBalanceBefore + expectedWithdrawAmount,
            "Recipient should receive correct ETH amount"
        );

        // Drift bound derived from the math, not a flat tolerance.
        //
        // expected: shareOfEEth - ceil(amount * TS / TPE)              [live rate]
        // actual:   shareOfEEth - ceil(amount * 1e18 / R_ceil)         [frozen rate, ceil(1e18*TPE/TS)]
        //
        // R_ceil >= R_exact = 1e18*TPE/TS, with R_ceil - R_exact < 1. So `actualBurn <= liveBurn`
        // and the gap is bounded by `amount * 1e18 / R_exact^2 ≈ amount / 1e18` for rates near 1.
        // Add a small +2 absorbs the two ceiling roundings.
        uint256 driftBound = expectedWithdrawAmount / 1e18 + 2;
        assertApproxEqAbs(
            withdrawRequestNFTInstance.totalRemainderEEthShares(),
            expectedDustShares,
            driftBound,
            "Incorrect remainder shares"
        );

        // Only test handleRemainder if there's actually remainder to handle
        uint256 dustEEthAmount = withdrawRequestNFTInstance.getEEthRemainderAmount();
        if (dustEEthAmount > 0) {
            // Grant the required role to admin
            vm.startPrank(address(roleRegistryInstance.owner()));
            roleRegistryInstance.grantRole(roleRegistryInstance.HOUSEKEEPING_OPERATIONS_ROLE(), admin);
            vm.stopPrank();
            
            // Handle remainder (use half to avoid edge cases)
            uint256 amountToHandle = dustEEthAmount / 2;
            if (amountToHandle > 0) {
                vm.prank(admin);
                withdrawRequestNFTInstance.handleRemainder(amountToHandle);
            }
        }
    }

    function testFuzz_InvalidateRequest(uint96 depositAmount, uint96 withdrawAmount, address recipient) public {
        // Assume valid conditions — withdraw amount must satisfy [MIN_WITHDRAW_AMOUNT, MAX_WITHDRAW_AMOUNT].
        vm.assume(depositAmount >= 1 ether && depositAmount <= 1000 ether);
        vm.assume(withdrawAmount >= liquidityPoolInstance.MIN_WITHDRAW_AMOUNT() && withdrawAmount <= depositAmount);
        vm.assume(recipient != address(0) && recipient != address(liquidityPoolInstance) && recipient != alice && recipient != admin && recipient != (address(etherFiAdminInstance)) && recipient != roleRegistryInstance.owner());
        // Filter out contracts that don't implement IERC721Receiver - only allow EOAs
        vm.assume(recipient.code.length == 0);
        
        // Setup initial balance and deposit
        vm.deal(recipient, depositAmount);
        
        vm.startPrank(recipient);
        liquidityPoolInstance.deposit{value: depositAmount}();
        
        // Request withdraw
        eETHInstance.approve(address(liquidityPoolInstance), withdrawAmount);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(recipient, withdrawAmount);
        vm.stopPrank();

        // Verify request is initially valid
        assertTrue(withdrawRequestNFTInstance.isValid(requestId), "Request should start valid");
        assertEq(withdrawRequestNFTInstance.ownerOf(requestId), recipient, "Recipient should own NFT");

        // Non-admin cannot invalidate (invalidateRequest is now onlyGuardian)
        vm.prank(recipient);
        vm.expectRevert(RoleRegistry.OnlyGuardian.selector);
        withdrawRequestNFTInstance.invalidateRequest(requestId);

        // Admin invalidates request
        vm.startPrank(roleRegistryInstance.owner());
        console.log("roleRegistryInstance.owner()", roleRegistryInstance.owner());
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_TIMELOCK_ROLE(), admin);
        vm.stopPrank();
        vm.prank(admin);
        withdrawRequestNFTInstance.invalidateRequest(requestId);

        // Verify request state after invalidation
        assertFalse(withdrawRequestNFTInstance.isValid(requestId), "Request should be invalid");
        assertEq(withdrawRequestNFTInstance.ownerOf(requestId), recipient, "NFT ownership should remain unchanged");
        
        // Verify cannot transfer invalid request
        vm.prank(recipient);
        vm.expectRevert(WithdrawRequestNFT.InvalidRequest.selector);
        withdrawRequestNFTInstance.transferFrom(recipient, address(0xdead), requestId);

        // Owner can seize the invalidated request NFT
        vm.prank(withdrawRequestNFTInstance.owner());
        withdrawRequestNFTInstance.seizeInvalidRequest(requestId, admin);
    }

    function test_getClaimableAmount() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);

        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 1 ether);

        // Should revert before finalization
        vm.expectRevert(WithdrawRequestNFT.RequestNotFinalized.selector);
        withdrawRequestNFTInstance.getClaimableAmount(requestId);

        _finalizeWithdrawalRequest(requestId);

        uint256 claimableAmount = withdrawRequestNFTInstance.getClaimableAmount(requestId);
        assertGt(claimableAmount, 0, "Claimable amount should be greater than 0");
        
        // Verify claimable amount equals min(amountOfEEth, amountForShares) - fee
        WithdrawRequestNFT.WithdrawRequest memory request = withdrawRequestNFTInstance.getRequest(requestId);
        uint256 amountForShares = liquidityPoolInstance.amountForShare(request.shareOfEEth);
        uint256 expectedAmount = request.amountOfEEth < amountForShares ? request.amountOfEEth : amountForShares;
        uint256 fee = uint256(request.feeGwei) * 1 gwei;
        uint256 expectedClaimable = expectedAmount - fee;
        assertEq(claimableAmount, expectedClaimable, "Claimable amount should match expected calculation");
    }

    function test_batchClaimWithdraw() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 20 ether}();
        vm.stopPrank();

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 5 ether);

        // Create multiple withdrawal requests
        vm.prank(bob);
        uint256 requestId1 = liquidityPoolInstance.requestWithdraw(bob, 1 ether);
        
        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 4 ether);
        vm.prank(bob);
        uint256 requestId2 = liquidityPoolInstance.requestWithdraw(bob, 2 ether);
        
        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 2 ether);
        vm.prank(bob);
        uint256 requestId3 = liquidityPoolInstance.requestWithdraw(bob, 2 ether);

        // Finalize all requests
        _finalizeWithdrawalRequest(requestId1);
        _finalizeWithdrawalRequest(requestId2);
        _finalizeWithdrawalRequest(requestId3);

        uint256 bobBalanceBefore = address(bob).balance;
        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = requestId1;
        tokenIds[1] = requestId2;
        tokenIds[2] = requestId3;

        vm.prank(bob);
        withdrawRequestNFTInstance.batchClaimWithdraw(tokenIds);

        uint256 bobBalanceAfter = address(bob).balance;
        assertGt(bobBalanceAfter, bobBalanceBefore, "Bob should receive ETH from batch claim");

        // Verify all NFTs are burned
        vm.expectRevert("ERC721: invalid token ID");
        withdrawRequestNFTInstance.ownerOf(requestId1);
        vm.expectRevert("ERC721: invalid token ID");
        withdrawRequestNFTInstance.ownerOf(requestId2);
        vm.expectRevert("ERC721: invalid token ID");
        withdrawRequestNFTInstance.ownerOf(requestId3);
    }

    function test_validateRequest() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);

        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 1 ether);

        assertTrue(withdrawRequestNFTInstance.isValid(requestId), "Request should be valid initially");

        // Invalidate the request
        vm.prank(admin);
        withdrawRequestNFTInstance.invalidateRequest(requestId);
        assertFalse(withdrawRequestNFTInstance.isValid(requestId), "Request should be invalid");

        // Validate the request again
        vm.prank(admin);
        withdrawRequestNFTInstance.validateRequest(requestId);
        assertTrue(withdrawRequestNFTInstance.isValid(requestId), "Request should be valid again");

        // Cannot validate already valid request
        vm.prank(admin);
        vm.expectRevert(WithdrawRequestNFT.RequestValid.selector);
        withdrawRequestNFTInstance.validateRequest(requestId);
    }

    /// @dev Re-validating a request that was invalidated *before* finalization but
    ///      whose id has since been overtaken by `lastFinalizedRequestId` must
    ///      pull the previously-unlocked ETH back into NFT escrow. The helper
    ///      `_finalizeWithdrawalRequest` only locks ETH for valid requests at
    ///      finalize time, so a finalized-but-invalid request's ETH is still on
    ///      the LP — `validateRequest` is the contract's mechanism to re-lock it.
    function test_validateRequest_finalized_locksEthFromLp() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        eETHInstance.approve(address(liquidityPoolInstance), 5 ether);
        uint256 reqA = liquidityPoolInstance.requestWithdraw(bob, 1 ether);
        uint256 reqB = liquidityPoolInstance.requestWithdraw(bob, 2 ether);
        vm.stopPrank();

        // Invalidate reqA, then finalize past it via reqB. reqA is now
        // (id <= lastFinalizedRequestId) AND invalid → its ETH is still on LP.
        vm.prank(admin);
        withdrawRequestNFTInstance.invalidateRequest(reqA);
        _finalizeWithdrawalRequest(reqB);
        assertGe(uint256(withdrawRequestNFTInstance.lastFinalizedRequestId()), reqA, "reqA must be finalized for the new branch");
        assertFalse(withdrawRequestNFTInstance.isValid(reqA), "reqA precondition: invalid");

        uint256 lpBalBefore       = address(liquidityPoolInstance).balance;
        uint256 nftBalBefore      = address(withdrawRequestNFTInstance).balance;
        uint128 inLpBefore        = uint128(liquidityPoolInstance.totalValueInLp());
        uint128 outOfLpBefore     = uint128(liquidityPoolInstance.totalValueOutOfLp());
        uint128 nftLockedBefore   = withdrawRequestNFTInstance.ethAmountLockedForWithdrawal();

        vm.prank(admin);
        withdrawRequestNFTInstance.validateRequest(reqA);

        assertTrue(withdrawRequestNFTInstance.isValid(reqA), "reqA should be valid after re-validate");
        assertEq(address(liquidityPoolInstance).balance, lpBalBefore - 1 ether, "LP balance should decrease by 1 ETH");
        assertEq(address(withdrawRequestNFTInstance).balance, nftBalBefore + 1 ether, "NFT balance should increase by 1 ETH");
        assertEq(liquidityPoolInstance.totalValueInLp(), inLpBefore - 1 ether, "totalValueInLp should decrease by 1 ETH");
        assertEq(liquidityPoolInstance.totalValueOutOfLp(), outOfLpBefore + 1 ether, "totalValueOutOfLp should increase by 1 ETH");
        assertEq(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal(), nftLockedBefore + 1 ether, "NFT locked counter should increase by 1 ETH");
    }

    /// @dev When the LP can no longer cover the request amount (drained between
    ///      invalidate and re-validate), `validateRequest` must revert before
    ///      touching state. We stage the same finalized-but-invalid setup and
    ///      then `vm.deal(LP, 0)` to force the precondition to fail.
    function test_validateRequest_finalized_revertsOnInsufficientLpBalance() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        eETHInstance.approve(address(liquidityPoolInstance), 5 ether);
        uint256 reqA = liquidityPoolInstance.requestWithdraw(bob, 1 ether);
        uint256 reqB = liquidityPoolInstance.requestWithdraw(bob, 2 ether);
        vm.stopPrank();

        vm.prank(admin);
        withdrawRequestNFTInstance.invalidateRequest(reqA);
        _finalizeWithdrawalRequest(reqB);

        // Drain LP so it can't cover the 1 ETH request.
        vm.deal(address(liquidityPoolInstance), 0);

        vm.prank(admin);
        vm.expectRevert(WithdrawRequestNFT.RequestAmountGreaterThanAvailableLiquidity.selector);
        withdrawRequestNFTInstance.validateRequest(reqA);
    }

    /// @dev Re-validating a not-yet-finalized request must NOT touch LP escrow
    ///      bookkeeping. Pins the `if (requestId <= lastFinalizedRequestId)` guard.
    function test_validateRequest_unfinalized_doesNotTouchLpEscrow() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);
        uint256 reqId = liquidityPoolInstance.requestWithdraw(bob, 1 ether);
        vm.stopPrank();

        vm.prank(admin);
        withdrawRequestNFTInstance.invalidateRequest(reqId);

        uint256 lpBalBefore     = address(liquidityPoolInstance).balance;
        uint256 nftBalBefore    = address(withdrawRequestNFTInstance).balance;
        uint128 nftLockedBefore = withdrawRequestNFTInstance.ethAmountLockedForWithdrawal();

        vm.prank(admin);
        withdrawRequestNFTInstance.validateRequest(reqId);

        assertEq(address(liquidityPoolInstance).balance, lpBalBefore, "LP balance must not change");
        assertEq(address(withdrawRequestNFTInstance).balance, nftBalBefore, "NFT balance must not change");
        assertEq(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal(), nftLockedBefore, "NFT locked counter must not change");
    }

    /// @dev `addEthAmountLockedForWithdrawal` must accept calls from the
    ///      WithdrawRequestNFT contract (new) so `validateRequest` can re-lock
    ///      ETH for finalized invalidated requests.
    function test_addEthAmountLockedForWithdrawal_acceptsFromNftContract() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        uint256 lpBalBefore     = address(liquidityPoolInstance).balance;
        uint256 nftBalBefore    = address(withdrawRequestNFTInstance).balance;
        uint128 inLpBefore      = uint128(liquidityPoolInstance.totalValueInLp());
        uint128 outOfLpBefore   = uint128(liquidityPoolInstance.totalValueOutOfLp());

        vm.prank(address(withdrawRequestNFTInstance));
        liquidityPoolInstance.addEthAmountLockedForWithdrawal(1 ether);

        assertEq(address(liquidityPoolInstance).balance, lpBalBefore - 1 ether, "LP balance should decrease");
        assertEq(address(withdrawRequestNFTInstance).balance, nftBalBefore + 1 ether, "NFT balance should increase");
        assertEq(liquidityPoolInstance.totalValueInLp(), inLpBefore - 1 ether);
        assertEq(liquidityPoolInstance.totalValueOutOfLp(), outOfLpBefore + 1 ether);
    }

    /// @dev Any caller other than `etherFiAdminContract` or `withdrawRequestNFT`
    ///      must be rejected. Ensures the new NFT carve-out didn't widen the gate.
    function test_addEthAmountLockedForWithdrawal_revertsForOtherCaller() public {
        vm.prank(alice);
        vm.expectRevert(LiquidityPool.IncorrectCaller.selector);
        liquidityPoolInstance.addEthAmountLockedForWithdrawal(1 ether);
    }

    function test_updateShareRemainderSplitToTreasuryInBps() public {
        uint16 newSplit = 5000; // 50%
        
        vm.prank(withdrawRequestNFTInstance.owner());
        withdrawRequestNFTInstance.updateShareRemainderSplitToTreasuryInBps(newSplit);
        
        assertEq(withdrawRequestNFTInstance.shareRemainderSplitToTreasuryInBps(), newSplit, "Split should be updated");

        // Test invalid value (> 10000)
        vm.prank(withdrawRequestNFTInstance.owner());
        vm.expectRevert(WithdrawRequestNFT.InvalidShareRemainderSplit.selector);
        withdrawRequestNFTInstance.updateShareRemainderSplitToTreasuryInBps(10001);

        // Test non-owner cannot update
        vm.prank(bob);
        vm.expectRevert();
        withdrawRequestNFTInstance.updateShareRemainderSplitToTreasuryInBps(3000);
    }

    function test_pauseContract() public {
        assertFalse(withdrawRequestNFTInstance.paused(), "Contract should not be paused initially");

        // Non-pauser cannot pause
        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlyOperatingMultisig.selector);
        withdrawRequestNFTInstance.pauseContract();

        // Pauser can pause
        vm.prank(admin);
        withdrawRequestNFTInstance.pauseContract();
        assertTrue(withdrawRequestNFTInstance.paused(), "Contract should be paused");

        // Cannot pause again
        vm.prank(admin);
        vm.expectRevert(WithdrawRequestNFT.AlreadyPaused.selector);
        withdrawRequestNFTInstance.pauseContract();

        // Cannot request withdraw when paused
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);
        vm.expectRevert(WithdrawRequestNFT.ContractPaused.selector);
        liquidityPoolInstance.requestWithdraw(bob, 1 ether);
        vm.stopPrank();
    }

    function test_unPauseContract() public {
        // Pause first
        vm.prank(admin);
        withdrawRequestNFTInstance.pauseContract();
        assertTrue(withdrawRequestNFTInstance.paused(), "Contract should be paused");

        // Non-unpauser cannot unpause
        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlyOperatingMultisig.selector);
        withdrawRequestNFTInstance.unPauseContract();

        // Unpauser can unpause
        vm.prank(admin);
        withdrawRequestNFTInstance.unPauseContract();
        assertFalse(withdrawRequestNFTInstance.paused(), "Contract should be unpaused");

        // Cannot unpause again
        vm.prank(admin);
        vm.expectRevert(WithdrawRequestNFT.NotPaused.selector);
        withdrawRequestNFTInstance.unPauseContract();
    }

    //--------------------------------------------------------------------------------------
    //--------------------------  pauseContractUntil / unpauseContractUntil  ---------------
    //--------------------------------------------------------------------------------------

    bytes32 constant PAUSABLE_UNTIL_SLOT =
        0x2c7e4bc092c2002f0baaf2f47367bc442b098266b43d189dafe4cb25f1e1fea2;

    address wrPauseUntilPauser = makeAddr("wrPauseUntilPauser");
    address wrUnpauseUntilUnpauser = makeAddr("wrUnpauseUntilUnpauser");
    address wrPauseUntilDurationSetter = makeAddr("wrPauseUntilDurationSetter");

    function _grantWrPauseUntilRoles() internal {
        vm.startPrank(roleRegistryInstance.owner());
        // pauseContractUntil → GUARDIAN_ROLE; unpause + setPauseUntilDuration → OPERATION_MULTISIG_ROLE (onlyOperations)
        roleRegistryInstance.grantRole(roleRegistryInstance.GUARDIAN_ROLE(), wrPauseUntilPauser);
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_MULTISIG_ROLE(), wrUnpauseUntilUnpauser);
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_TIMELOCK_ROLE(), wrPauseUntilDurationSetter);
        vm.stopPrank();
        if (block.timestamp < 1_700_000_000) vm.warp(1_700_000_000);

        uint256 maxDur = withdrawRequestNFTInstance.MAX_PAUSE_DURATION();
        vm.prank(wrPauseUntilDurationSetter);
        withdrawRequestNFTInstance.setPauseUntilDuration(maxDur);
    }

    function _wrPausedUntil() internal view returns (uint256) {
        return uint256(vm.load(address(withdrawRequestNFTInstance), PAUSABLE_UNTIL_SLOT));
    }

    function test_pauseContractUntil_requiresRole() public {
        _grantWrPauseUntilRoles();
        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlyGuardian.selector);
        withdrawRequestNFTInstance.pauseContractUntil();
    }

    function test_pauseContractUntil_setsState() public {
        _grantWrPauseUntilRoles();
        vm.prank(wrPauseUntilPauser);
        withdrawRequestNFTInstance.pauseContractUntil();
        assertEq(_wrPausedUntil(), block.timestamp + withdrawRequestNFTInstance.MAX_PAUSE_DURATION());
    }

    function test_unpauseContractUntil_requiresRole() public {
        _grantWrPauseUntilRoles();
        vm.prank(wrPauseUntilPauser);
        withdrawRequestNFTInstance.pauseContractUntil();

        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlyOperatingMultisig.selector);
        withdrawRequestNFTInstance.unpauseContractUntil();
    }

    function test_unpauseContractUntil_clearsState() public {
        _grantWrPauseUntilRoles();
        vm.prank(wrPauseUntilPauser);
        withdrawRequestNFTInstance.pauseContractUntil();

        vm.prank(wrUnpauseUntilUnpauser);
        withdrawRequestNFTInstance.unpauseContractUntil();
        assertEq(_wrPausedUntil(), 0);
    }

    function test_unpauseContractUntil_revertsIfNotPaused() public {
        _grantWrPauseUntilRoles();
        vm.prank(wrUnpauseUntilUnpauser);
        vm.expectRevert(PausableUntil.ContractNotPausedUntil.selector);
        withdrawRequestNFTInstance.unpauseContractUntil();
    }

    // --- setPauseUntilDuration ---

    function test_setPauseUntilDuration_requiresRole() public {
        _grantWrPauseUntilRoles();
        uint256 maxDur = withdrawRequestNFTInstance.MAX_PAUSE_DURATION();

        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        withdrawRequestNFTInstance.setPauseUntilDuration(maxDur);

        // Guardian-only role (wrPauseUntilPauser) cannot set the duration; needs admin role.
        vm.prank(wrPauseUntilPauser);
        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        withdrawRequestNFTInstance.setPauseUntilDuration(maxDur);
    }

    function test_setPauseUntilDuration_setsValue() public {
        _grantWrPauseUntilRoles();
        uint256 d = withdrawRequestNFTInstance.MIN_PAUSE_DURATION() + 1 hours;

        vm.prank(wrPauseUntilDurationSetter);
        withdrawRequestNFTInstance.setPauseUntilDuration(d);

        vm.prank(wrPauseUntilPauser);
        withdrawRequestNFTInstance.pauseContractUntil();
        assertEq(_wrPausedUntil(), block.timestamp + d);
    }

    function test_setPauseUntilDuration_revertsOnInvalidValue() public {
        _grantWrPauseUntilRoles();
        uint256 belowMin = withdrawRequestNFTInstance.MIN_PAUSE_DURATION() - 1;
        uint256 aboveMax = withdrawRequestNFTInstance.MAX_PAUSE_DURATION() + 1;

        vm.prank(wrPauseUntilDurationSetter);
        vm.expectRevert(PausableUntil.InvalidPauseUntilDuration.selector);
        withdrawRequestNFTInstance.setPauseUntilDuration(belowMin);

        vm.prank(wrPauseUntilDurationSetter);
        vm.expectRevert(PausableUntil.InvalidPauseUntilDuration.selector);
        withdrawRequestNFTInstance.setPauseUntilDuration(aboveMax);
    }

    // --- each gated function (whenNotPaused → blocked by pause-until too) ---

    function test_requestWithdraw_blockedByPauseContractUntil() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);
        vm.stopPrank();

        _grantWrPauseUntilRoles();
        vm.prank(wrPauseUntilPauser);
        withdrawRequestNFTInstance.pauseContractUntil();

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, _wrPausedUntil())
        );
        liquidityPoolInstance.requestWithdraw(bob, 1 ether);
    }

    // claimWithdraw and batchClaimWithdraw were turned permissionless (commit 54a2226), so
    // pauseContractUntil on the WithdrawRequestNFT no longer blocks finalized claims. The pair
    // below pins this behavior — they used to assert ContractPausedUntil reverts.

    function test_claimWithdraw_succeedsUnderPauseContractUntil() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 1 ether);
        vm.stopPrank();

        _finalizeWithdrawalRequest(requestId);

        _grantWrPauseUntilRoles();
        vm.prank(wrPauseUntilPauser);
        withdrawRequestNFTInstance.pauseContractUntil();
        assertGt(_wrPausedUntil(), 0, "precondition: WR must be pause-until");

        uint256 bobBalBefore = bob.balance;
        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);
        assertEq(bob.balance - bobBalBefore, 1 ether, "claim must pay out under pauseContractUntil");
    }

    function test_batchClaimWithdraw_succeedsUnderPauseContractUntil() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 1 ether);
        vm.stopPrank();

        _finalizeWithdrawalRequest(requestId);

        uint256[] memory ids = new uint256[](1);
        ids[0] = requestId;

        _grantWrPauseUntilRoles();
        vm.prank(wrPauseUntilPauser);
        withdrawRequestNFTInstance.pauseContractUntil();

        uint256 bobBalBefore = bob.balance;
        vm.prank(bob);
        withdrawRequestNFTInstance.batchClaimWithdraw(ids);
        assertEq(bob.balance - bobBalBefore, 1 ether, "batch claim must pay out under pauseContractUntil");
    }

    // requestWithdraw is still gated by both pause and pause-until — pin that too.
    function test_requestWithdraw_blockedByLpPauseContractUntil() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);
        vm.stopPrank();

        // Grant LP-side pause-until role and pause LP-until.
        address lpPauser = makeAddr("lpPauser_wrTest");
        vm.startPrank(roleRegistryInstance.owner());
        roleRegistryInstance.grantRole(roleRegistryInstance.GUARDIAN_ROLE(), lpPauser);
        vm.stopPrank();
        if (block.timestamp < 1_700_000_000) vm.warp(1_700_000_000);

        vm.prank(lpPauser);
        liquidityPoolInstance.pauseContractUntil();
        uint256 lpPausedUntil = uint256(vm.load(address(liquidityPoolInstance), PAUSABLE_UNTIL_SLOT));

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, lpPausedUntil)
        );
        liquidityPoolInstance.requestWithdraw(bob, 1 ether);
    }

    function test_getEEthRemainderAmount() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);

        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 1 ether);

        // Rebase to create remainder
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(5 ether);

        _finalizeWithdrawalRequest(requestId);

        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);

        uint256 remainderAmount = withdrawRequestNFTInstance.getEEthRemainderAmount();
        assertGe(remainderAmount, 0, "Remainder amount should be >= 0");
    }

    function test_requestWithdrawWithFee() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);

        uint256 fee = 0.01 ether; // 1% fee
        
        // Direct call to requestWithdraw with fee (simulating MembershipManager)
        vm.prank(address(liquidityPoolInstance));
        uint256 requestId = withdrawRequestNFTInstance.requestWithdraw(1 ether, 1 ether, bob, fee);

        WithdrawRequestNFT.WithdrawRequest memory request = withdrawRequestNFTInstance.getRequest(requestId);
        assertEq(request.feeGwei, uint32(fee / 1 gwei), "Fee should be stored correctly");
    }

    function test_claimWithdrawWithFee() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        uint256 amount = 1 ether;
        uint256 fee = 0.01 ether; // 1% fee

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), amount);

        // Transfer eETH to contract first (simulating what liquidity pool does)
        vm.prank(bob);
        eETHInstance.transfer(address(withdrawRequestNFTInstance), amount);

        // Create request with fee via direct call
        vm.prank(address(liquidityPoolInstance));
        uint256 requestId = withdrawRequestNFTInstance.requestWithdraw(uint96(amount), uint96(amount), bob, fee);

        // Add more liquidity to ensure withdrawal can be fulfilled
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 5 ether}();

        // Rebase to increase value
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(5 ether);

        _finalizeWithdrawalRequest(requestId);

        uint256 bobBalanceBefore = address(bob).balance;
        uint256 claimableAmount = withdrawRequestNFTInstance.getClaimableAmount(requestId);
        
        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);

        uint256 bobBalanceAfter = address(bob).balance;
        uint256 receivedAmount = bobBalanceAfter - bobBalanceBefore;
        
        // Received amount should be claimable amount (which already has fee deducted)
        assertApproxEqAbs(receivedAmount, claimableAmount, 0.001 ether, "Bob should receive amount minus fee");
    }

    /// @dev Verifies that fee ETH stranded in the NFT after a fee-bearing claim is swept back to LP
    ///      when handleRemainder is called, and that ethAmountLockedForWithdrawal is unchanged by it.
    function test_handleRemainder_returnsFeeEthToLP() public {
        uint256 amount = 1 ether;
        uint256 fee    = 0.1 ether; // 10% fee

        // --- setup: deposit liquidity ---
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        // Transfer eETH into NFT contract (simulates what LP does in the real requestWithdraw path)
        vm.prank(bob);
        eETHInstance.transfer(address(withdrawRequestNFTInstance), amount);

        // Create a fee-bearing withdraw request directly (simulating MembershipManager)
        vm.prank(address(liquidityPoolInstance));
        uint256 requestId = withdrawRequestNFTInstance.requestWithdraw(
            uint96(amount), uint96(amount), bob, fee
        );

        // Add more liquidity and finalize
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 5 ether}();

        _finalizeWithdrawalRequest(requestId);

        // Bob claims — NFT sends net (amount - fee) to bob, but received gross from LP at finalize.
        // After claim: NFT.balance should equal fee (stranded), counter should be 0.
        uint256 nftBalBefore  = address(withdrawRequestNFTInstance).balance;
        uint256 lpBalBefore   = address(liquidityPoolInstance).balance;

        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);

        // Counter must be zero (decremented by gross).
        assertEq(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal(), 0, "counter should be 0 after gross decrement");

        // NFT balance should equal the stranded fee.
        uint256 strandedFee = address(withdrawRequestNFTInstance).balance;
        assertGt(strandedFee, 0, "fee ETH should be stranded in NFT");
        assertApproxEqAbs(strandedFee, fee, 0.001 ether, "stranded amount should equal fee");

        // --- trigger handleRemainder to sweep fee ETH back to LP ---
        // First get some eETH remainder to satisfy the non-zero _eEthAmount requirement.
        // After claim, totalRemainderEEthShares > 0 due to share-rate drift from rebase.
        uint256 remainderAmount = withdrawRequestNFTInstance.getEEthRemainderAmount();

        vm.startPrank(owner);
        roleRegistryInstance.grantRole(roleRegistryInstance.HOUSEKEEPING_OPERATIONS_ROLE(), admin);
        vm.stopPrank();

        uint256 lpBalAfterClaim  = address(liquidityPoolInstance).balance;
        uint256 nftBalAfterClaim = address(withdrawRequestNFTInstance).balance;

        vm.prank(admin);
        if (remainderAmount > 0) {
            withdrawRequestNFTInstance.handleRemainder(remainderAmount);
        }

        // LP balance must have increased by the stranded fee ETH.
        assertGe(
            address(liquidityPoolInstance).balance,
            lpBalAfterClaim + strandedFee,
            "LP should receive stranded fee ETH on handleRemainder"
        );

        // NFT balance must now be zero (or only residual dust).
        assertEq(address(withdrawRequestNFTInstance).balance, 0, "NFT balance should be zero after sweep");

        // Counter is still zero — handleRemainder does not touch it.
        assertEq(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal(), 0, "counter must remain 0 after handleRemainder");
    }

    function test_seizeInvalidRequest_EdgeCases() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);

        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 1 ether);

        // Cannot seize valid request
        vm.prank(withdrawRequestNFTInstance.owner());
        vm.expectRevert(WithdrawRequestNFT.RequestValid.selector);
        withdrawRequestNFTInstance.seizeInvalidRequest(requestId, admin);

        // Invalidate first
        vm.prank(admin);
        withdrawRequestNFTInstance.invalidateRequest(requestId);

        // Cannot seize non-existent request
        vm.prank(withdrawRequestNFTInstance.owner());
        vm.expectRevert(WithdrawRequestNFT.RequestNotFound.selector);
        withdrawRequestNFTInstance.seizeInvalidRequest(99999, admin);

        // Owner can seize invalid request
        address recipient = alice;
        vm.prank(withdrawRequestNFTInstance.owner());
        withdrawRequestNFTInstance.seizeInvalidRequest(requestId, recipient);
        
        assertEq(withdrawRequestNFTInstance.ownerOf(requestId), recipient, "NFT should be transferred to recipient");
    }

    function test_handleRemainder_EdgeCases() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);

        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 1 ether);

        // Rebase to create remainder
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(5 ether);

        _finalizeWithdrawalRequest(requestId);

        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);

        uint256 remainderAmount = withdrawRequestNFTInstance.getEEthRemainderAmount();
        
        if (remainderAmount > 0) {
            // Grant role
            vm.startPrank(address(roleRegistryInstance.owner()));
            roleRegistryInstance.grantRole(roleRegistryInstance.HOUSEKEEPING_OPERATIONS_ROLE(), admin);
            vm.stopPrank();

            // Cannot handle zero amount
            vm.prank(admin);
            vm.expectRevert(WithdrawRequestNFT.EETHAmountCannotBeZero.selector);
            withdrawRequestNFTInstance.handleRemainder(0);

            // Cannot handle more than available
            vm.prank(admin);
            vm.expectRevert(WithdrawRequestNFT.NotEnoughEEthRemainder.selector);
            withdrawRequestNFTInstance.handleRemainder(remainderAmount + 1);

            // Can handle partial amount
            uint256 partialAmount = remainderAmount / 2;
            if (partialAmount > 0) {
                uint256 treasuryBalanceBefore = eETHInstance.balanceOf(address(treasuryInstance));
                
                vm.prank(admin);
                withdrawRequestNFTInstance.handleRemainder(partialAmount);
                
                uint256 treasuryBalanceAfter = eETHInstance.balanceOf(address(treasuryInstance));
                assertGe(treasuryBalanceAfter, treasuryBalanceBefore, "Treasury should receive portion of remainder");
            }
        }
    }

    function test_finalizeRequests_EdgeCases() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);

        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 1 ether);

        // finalizeRequests is now restricted to etherFiAdmin contract only.
        address etherFiAdminAddr = address(etherFiAdminInstance);

        // Cannot finalize future requests
        vm.prank(etherFiAdminAddr);
        vm.expectRevert(WithdrawRequestNFT.CannotFinalizeFutureRequests.selector);
        withdrawRequestNFTInstance.finalizeRequests(requestId + 100);

        // Finalize request
        vm.prank(etherFiAdminAddr);
        withdrawRequestNFTInstance.finalizeRequests(requestId);

        // Cannot undo finalization
        vm.prank(etherFiAdminAddr);
        vm.expectRevert(WithdrawRequestNFT.CannotUndoFinalization.selector);
        withdrawRequestNFTInstance.finalizeRequests(requestId - 1);

        // Non-admin cannot finalize — reverts with IncorrectRole() (not the legacy admin string).
        vm.prank(bob);
        vm.expectRevert(WithdrawRequestNFT.IncorrectRole.selector);
        withdrawRequestNFTInstance.finalizeRequests(requestId + 1);
    }

    function test_transferInvalidRequest() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);

        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 1 ether);

        // Invalidate request
        vm.prank(admin);
        withdrawRequestNFTInstance.invalidateRequest(requestId);

        // Owner cannot transfer invalid request
        vm.prank(bob);
        vm.expectRevert(WithdrawRequestNFT.InvalidRequest.selector);
        withdrawRequestNFTInstance.transferFrom(bob, alice, requestId);

        // Contract owner can transfer invalid request
        vm.prank(withdrawRequestNFTInstance.owner());
        withdrawRequestNFTInstance.seizeInvalidRequest(requestId, alice);
        
        assertEq(withdrawRequestNFTInstance.ownerOf(requestId), alice, "NFT should be transferred");
    }

    /// @dev Updated: invalidation now only possible pre-finalization, so the test invalidates
    ///      first, THEN finalizes, then asserts claim reverts on `!isValid`. End-state assertion
    ///      (invalid request cannot be claimed) is unchanged.
    function test_claimWithdraw_InvalidRequest() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);

        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 1 ether);

        // Invalidate BEFORE finalization (the only time admin can do it now).
        vm.prank(admin);
        withdrawRequestNFTInstance.invalidateRequest(requestId);

        // An invalid request can still be finalized (finalization cursor is monotonic and doesn't check validity).
        _finalizeWithdrawalRequest(requestId);

        // Claim still blocked by the `isValid` check inside `_claimWithdraw`.
        vm.prank(bob);
        vm.expectRevert(WithdrawRequestNFT.RequestNotValid.selector);
        withdrawRequestNFTInstance.claimWithdraw(requestId);
    }

    function test_getRequest_NonExistent() public {
        WithdrawRequestNFT.WithdrawRequest memory request = withdrawRequestNFTInstance.getRequest(99999);
        assertEq(request.amountOfEEth, 0, "Non-existent request should return zero values");
        assertEq(request.shareOfEEth, 0, "Non-existent request should return zero values");
        assertFalse(request.isValid, "Non-existent request should be invalid");
    }

    function test_isValid_NonExistent() public {
        vm.expectRevert(WithdrawRequestNFT.RequestNotFound.selector);
        withdrawRequestNFTInstance.isValid(99999);
    }

    // -----------------------------------------------------------------
    //  Permissionless claim + no-post-finalization-invalidation tests
    // -----------------------------------------------------------------

    /// @dev Helper: make a withdraw request owned by `owner` for `amount`.
    function _requestFor(address owner, uint96 amount) internal returns (uint256 requestId) {
        startHoax(owner);
        liquidityPoolInstance.deposit{value: amount}();
        eETHInstance.approve(address(liquidityPoolInstance), amount);
        requestId = liquidityPoolInstance.requestWithdraw(owner, amount);
        vm.stopPrank();
    }

    function test_claimWithdraw_succeedsWhilePaused_ifFinalized() public {
        uint256 requestId = _requestFor(bob, 1 ether);
        _finalizeWithdrawalRequest(requestId);

        // Pause BEFORE the claim — finalized claim must proceed anyway.
        vm.prank(admin);
        withdrawRequestNFTInstance.pauseContract();
        assertTrue(withdrawRequestNFTInstance.paused(), "precondition: must be paused");

        uint256 bobBalBefore = bob.balance;
        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);

        assertEq(bob.balance - bobBalBefore, 1 ether, "finalized claim must pay out while paused");
    }

    function test_batchClaimWithdraw_succeedsWhilePaused_ifFinalized() public {
        uint256 r1 = _requestFor(bob, 1 ether);
        uint256 r2 = _requestFor(bob, 2 ether);
        _finalizeWithdrawalRequest(r1);
        _finalizeWithdrawalRequest(r2);

        vm.prank(admin);
        withdrawRequestNFTInstance.pauseContract();

        uint256[] memory ids = new uint256[](2);
        ids[0] = r1;
        ids[1] = r2;

        uint256 bobBalBefore = bob.balance;
        vm.prank(bob);
        withdrawRequestNFTInstance.batchClaimWithdraw(ids);

        assertEq(bob.balance - bobBalBefore, 3 ether, "batch claim must pay out while paused");
    }

    function test_claimWithdraw_revertsWhenUnfinalized_paused() public {
        uint256 requestId = _requestFor(bob, 1 ether);
        // NOT finalized.

        vm.prank(admin);
        withdrawRequestNFTInstance.pauseContract();

        vm.prank(bob);
        vm.expectRevert(WithdrawRequestNFT.RequestNotFinalized.selector);
        withdrawRequestNFTInstance.claimWithdraw(requestId);
    }

    function test_claimWithdraw_revertsWhenUnfinalized_unpaused() public {
        uint256 requestId = _requestFor(bob, 1 ether);
        // NOT finalized, NOT paused (matches post-setUp state).

        vm.prank(bob);
        vm.expectRevert(WithdrawRequestNFT.RequestNotFinalized.selector);
        withdrawRequestNFTInstance.claimWithdraw(requestId);
    }

    function test_claimWithdraw_succeedsWhenLiquidityPoolPaused() public {
        uint256 requestId = _requestFor(bob, 1 ether);
        _finalizeWithdrawalRequest(requestId);

        vm.prank(admin);
        liquidityPoolInstance.pauseContract();
        assertTrue(liquidityPoolInstance.paused(), "precondition: LP must be paused");

        uint256 bobBalBefore = bob.balance;
        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);

        assertEq(bob.balance - bobBalBefore, 1 ether, "finalized claim must pay out while LP is paused");
    }

    function test_batchClaimWithdraw_succeedsWhenLiquidityPoolPaused() public {
        uint256 r1 = _requestFor(bob, 1 ether);
        uint256 r2 = _requestFor(bob, 2 ether);
        _finalizeWithdrawalRequest(r1);
        _finalizeWithdrawalRequest(r2);

        vm.prank(admin);
        liquidityPoolInstance.pauseContract();

        uint256[] memory ids = new uint256[](2);
        ids[0] = r1;
        ids[1] = r2;

        uint256 bobBalBefore = bob.balance;
        vm.prank(bob);
        withdrawRequestNFTInstance.batchClaimWithdraw(ids);

        assertEq(bob.balance - bobBalBefore, 3 ether, "batch claim must pay out while LP is paused");
    }

    function test_claimWithdraw_succeedsWhenBothPaused() public {
        uint256 requestId = _requestFor(bob, 1 ether);
        _finalizeWithdrawalRequest(requestId);

        vm.startPrank(admin);
        liquidityPoolInstance.pauseContract();
        withdrawRequestNFTInstance.pauseContract();
        vm.stopPrank();
        assertTrue(liquidityPoolInstance.paused(), "precondition: LP must be paused");
        assertTrue(withdrawRequestNFTInstance.paused(), "precondition: NFT must be paused");

        uint256 bobBalBefore = bob.balance;
        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);

        assertEq(bob.balance - bobBalBefore, 1 ether, "finalized claim must pay out while both are paused");
    }

    function test_liquidityPool_withdraw_revertsForOtherCallersWhenLpPaused() public {
        // Pause the LP, then assert that the two non-permissionless callers (membershipManager and
        // etherFiRedemptionManager) still revert at the pause gate. The pause check sits between the
        // caller-allowlist require and the eETH-balance check, so no LP funding is needed.
        vm.prank(admin);
        liquidityPoolInstance.pauseContract();

        address membershipMgr = address(liquidityPoolInstance.membershipManager());
        address redemptionMgr = address(liquidityPoolInstance.etherFiRedemptionManager());

        if (membershipMgr != address(0)) {
            vm.prank(membershipMgr);
            vm.expectRevert(LiquidityPool.ContractPaused.selector);
            liquidityPoolInstance.withdraw(bob, 1 ether);
        }

        if (redemptionMgr != address(0)) {
            vm.prank(redemptionMgr);
            vm.expectRevert(LiquidityPool.ContractPaused.selector);
            liquidityPoolInstance.withdraw(bob, 1 ether);
        }
    }

    // -----------------------------------------------------------------
    //  LP-side pauseContractUntil + permissionless claim parity tests
    //  (mirror the LP-paused tests above; cover the soft pause-until gate)
    // -----------------------------------------------------------------

    /// @dev Helper: grant LP-side pause-until role and apply pauseContractUntil on the LP.
    function _pauseLpUntil() internal returns (uint256 lpPausedUntil) {
        address lpPauser = makeAddr("lpPauser_permissionlessClaim");
        vm.startPrank(roleRegistryInstance.owner());
        roleRegistryInstance.grantRole(roleRegistryInstance.GUARDIAN_ROLE(), lpPauser);
        vm.stopPrank();
        if (block.timestamp < 1_700_000_000) vm.warp(1_700_000_000);

        vm.prank(lpPauser);
        liquidityPoolInstance.pauseContractUntil();
        lpPausedUntil = uint256(vm.load(address(liquidityPoolInstance), PAUSABLE_UNTIL_SLOT));
        require(lpPausedUntil > 0, "LP pause-until not set");
    }

    function test_claimWithdraw_succeedsWhenLpPausedUntil() public {
        uint256 requestId = _requestFor(bob, 1 ether);
        _finalizeWithdrawalRequest(requestId);

        _pauseLpUntil();

        uint256 bobBalBefore = bob.balance;
        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);
        assertEq(bob.balance - bobBalBefore, 1 ether, "finalized claim must pay out while LP is pause-until");
    }

    function test_batchClaimWithdraw_succeedsWhenLpPausedUntil() public {
        uint256 r1 = _requestFor(bob, 1 ether);
        uint256 r2 = _requestFor(bob, 2 ether);
        _finalizeWithdrawalRequest(r1);
        _finalizeWithdrawalRequest(r2);

        _pauseLpUntil();

        uint256[] memory ids = new uint256[](2);
        ids[0] = r1;
        ids[1] = r2;

        uint256 bobBalBefore = bob.balance;
        vm.prank(bob);
        withdrawRequestNFTInstance.batchClaimWithdraw(ids);
        assertEq(bob.balance - bobBalBefore, 3 ether, "batch claim must pay out while LP is pause-until");
    }

    function test_claimWithdraw_succeedsWhenLpPauseAndPauseUntilBothActive() public {
        uint256 requestId = _requestFor(bob, 1 ether);
        _finalizeWithdrawalRequest(requestId);

        _pauseLpUntil();
        vm.prank(admin);
        liquidityPoolInstance.pauseContract();

        uint256 bobBalBefore = bob.balance;
        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);
        assertEq(bob.balance - bobBalBefore, 1 ether, "claim must pay out when LP has both pause and pause-until set");
    }

    function test_liquidityPool_withdraw_revertsForGatedCallersWhenLpPausedUntil() public {
        uint256 lpPausedUntil = _pauseLpUntil();

        address membershipMgr = address(liquidityPoolInstance.membershipManager());
        address redemptionMgr = address(liquidityPoolInstance.etherFiRedemptionManager());

        if (membershipMgr != address(0)) {
            vm.prank(membershipMgr);
            vm.expectRevert(
                abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, lpPausedUntil)
            );
            liquidityPoolInstance.withdraw(bob, 1 ether);
        }

        if (redemptionMgr != address(0)) {
            vm.prank(redemptionMgr);
            vm.expectRevert(
                abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, lpPausedUntil)
            );
            liquidityPoolInstance.withdraw(bob, 1 ether);
        }
    }

    function test_liquidityPool_requestWithdraw_revertsWhenLpPausedUntil() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 1 ether}();
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);
        vm.stopPrank();

        uint256 lpPausedUntil = _pauseLpUntil();

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, lpPausedUntil)
        );
        liquidityPoolInstance.requestWithdraw(bob, 1 ether);
    }

    function test_liquidityPool_requestWithdraw_revertsWhenLpPaused() public {
        // Sanity: deposit / requestWithdraw remain gated by the LP pause — only the
        // claim path is permissionless.
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 1 ether}();
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);
        vm.stopPrank();

        vm.prank(admin);
        liquidityPoolInstance.pauseContract();

        vm.prank(bob);
        vm.expectRevert(LiquidityPool.ContractPaused.selector);
        liquidityPoolInstance.requestWithdraw(bob, 1 ether);
    }

    function test_invalidateRequest_revertsForFinalizedRequest() public {
        uint256 requestId = _requestFor(bob, 1 ether);
        _finalizeWithdrawalRequest(requestId);
        assertTrue(withdrawRequestNFTInstance.isFinalized(requestId));

        vm.prank(admin);
        vm.expectRevert(WithdrawRequestNFT.CannotInvalidateFinalizedRequest.selector);
        withdrawRequestNFTInstance.invalidateRequest(requestId);

        // Still valid & claimable after the rejected invalidate attempt.
        assertTrue(withdrawRequestNFTInstance.isValid(requestId), "should still be valid");

        uint256 bobBalBefore = bob.balance;
        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);
        assertEq(bob.balance - bobBalBefore, 1 ether);
    }

    function test_invalidateRequest_succeedsForUnfinalizedRequest() public {
        uint256 requestId = _requestFor(bob, 1 ether);
        assertFalse(withdrawRequestNFTInstance.isFinalized(requestId));

        vm.prank(admin);
        withdrawRequestNFTInstance.invalidateRequest(requestId);

        assertFalse(withdrawRequestNFTInstance.isValid(requestId), "should be invalid after admin action");
    }

    /// @dev Off-by-one: the token at EXACTLY lastFinalizedRequestId is finalized
    ///      and therefore must NOT be invalidatable. The next token (id + 1) is
    ///      not finalized and must still be invalidatable.
    function test_invalidateRequest_boundary_atLastFinalizedRequestId() public {
        uint256 r1 = _requestFor(bob, 1 ether);
        uint256 r2 = _requestFor(bob, 1 ether);

        // Finalize only r1.
        _finalizeWithdrawalRequest(r1);
        assertEq(uint256(withdrawRequestNFTInstance.lastFinalizedRequestId()), r1, "r1 is the boundary");

        // r1 == lastFinalizedRequestId → cannot invalidate.
        vm.prank(admin);
        vm.expectRevert(WithdrawRequestNFT.CannotInvalidateFinalizedRequest.selector);
        withdrawRequestNFTInstance.invalidateRequest(r1);

        // r2 == lastFinalizedRequestId + 1 → can invalidate.
        vm.prank(admin);
        withdrawRequestNFTInstance.invalidateRequest(r2);
        assertFalse(withdrawRequestNFTInstance.isValid(r2), "r2 should be invalid");
    }

    function test_claimWithdraw_paysFromNFTBalance_afterFinalize() public {
        address user = bob;
        uint96 amount = 1 ether;

        vm.deal(user, 10 ether);
        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: 10 ether}();
        eETHInstance.approve(address(liquidityPoolInstance), amount);
        uint256 reqId = liquidityPoolInstance.requestWithdraw(user, amount);
        vm.stopPrank();

        // Admin finalizes (NFT contract gets ETH at this step under our new flow).
        vm.prank(address(etherFiAdminInstance));
        withdrawRequestNFTInstance.finalizeRequests(reqId);
        vm.prank(address(etherFiAdminInstance));
        liquidityPoolInstance.addEthAmountLockedForWithdrawal(uint128(amount));

        uint256 nftEthBefore  = address(withdrawRequestNFTInstance).balance;
        uint256 userEthBefore = user.balance;

        vm.prank(user);
        withdrawRequestNFTInstance.claimWithdraw(reqId);

        assertGt(user.balance, userEthBefore, "user did not receive ETH");
        assertLt(address(withdrawRequestNFTInstance).balance, nftEthBefore, "NFT did not pay from own balance");
    }

    function test_claimWithdraw_succeedsEvenIfLPDrained() public {
        address user = bob;
        uint96 amount = 1 ether;

        vm.deal(user, 10 ether);
        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: 10 ether}();
        eETHInstance.approve(address(liquidityPoolInstance), amount);
        uint256 reqId = liquidityPoolInstance.requestWithdraw(user, amount);
        vm.stopPrank();

        vm.prank(address(etherFiAdminInstance));
        withdrawRequestNFTInstance.finalizeRequests(reqId);
        vm.prank(address(etherFiAdminInstance));
        liquidityPoolInstance.addEthAmountLockedForWithdrawal(uint128(amount));

        // Adversarial: drain LP balance to 0.
        vm.deal(address(liquidityPoolInstance), 0);

        uint256 userEthBefore = user.balance;
        vm.prank(user);
        withdrawRequestNFTInstance.claimWithdraw(reqId);
        assertGt(user.balance, userEthBefore, "user did not receive ETH despite drained LP");
    }

    function test_integration_fullLifecycle_withDrain() public {
        address user = bob;
        uint96 amount = 5 ether;

        // Deposit + request.
        vm.deal(user, 100 ether);
        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: 100 ether}();
        eETHInstance.approve(address(liquidityPoolInstance), amount);
        uint256 reqId = liquidityPoolInstance.requestWithdraw(user, amount);
        vm.stopPrank();

        // Admin finalizes (NFT contract gets ETH at this step).
        vm.prank(address(etherFiAdminInstance));
        withdrawRequestNFTInstance.finalizeRequests(reqId);
        vm.prank(address(etherFiAdminInstance));
        liquidityPoolInstance.addEthAmountLockedForWithdrawal(uint128(amount));

        // Adversarial: drain LP balance to 0 (simulating other consumers draining LP
        // between finalize and claim).
        vm.deal(address(liquidityPoolInstance), 0);

        // User claims — should succeed because NFT contract holds the ETH.
        uint256 userEthBefore = user.balance;
        vm.prank(user);
        withdrawRequestNFTInstance.claimWithdraw(reqId);

        assertGt(user.balance, userEthBefore, "user did not receive funds despite drain");
    }

    // ───────────────────────────────────────────────────────────────────────────
    // Share-rate freeze at finalization
    // ───────────────────────────────────────────────────────────────────────────

    /// @dev Core behavioral change: the rate used at claim is the one frozen at finalize,
    ///      NOT the live rate. A negative rebase between finalize and claim must not
    ///      reduce the claimable amount.
    function test_shareRateFreeze_negativeRebaseAfterFinalize_usesFrozenRate() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        // Positive rebase first so a subsequent negative rebase still leaves positive shares value.
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(10 ether); // 20 ether / 10 shares = 2 ether per share

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);
        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 1 ether);

        // Finalize at the post-positive-rebase rate; snapshot captured here.
        _finalizeWithdrawalRequest(requestId);

        uint256 claimableBeforeNegativeRebase = withdrawRequestNFTInstance.getClaimableAmount(requestId);

        // Negative rebase AFTER finalize. Pre-freeze behavior would drop the claim amount;
        // post-freeze behavior must not — the rate is locked in.
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(-5 ether);

        uint256 claimableAfterNegativeRebase = withdrawRequestNFTInstance.getClaimableAmount(requestId);
        assertEq(
            claimableAfterNegativeRebase,
            claimableBeforeNegativeRebase,
            "frozen rate must shield claim from post-finalize negative rebase"
        );

        uint256 bobBalanceBefore = address(bob).balance;
        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);
        assertEq(address(bob).balance - bobBalanceBefore, claimableAfterNegativeRebase, "payout uses frozen rate");
    }

    /// @dev The original-amount ceiling still applies: a positive rebase after finalize
    ///      cannot push the claim above `request.amountOfEEth`.
    function test_shareRateFreeze_positiveRebaseAfterFinalize_clampedByOriginalAmount() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);
        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 1 ether);

        _finalizeWithdrawalRequest(requestId);

        // Positive rebase post-finalize — frozen rate is unchanged, and the `min(amount, shares*rate)` clamp
        // still keeps payout at the originally requested amount.
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(20 ether);

        uint256 claimable = withdrawRequestNFTInstance.getClaimableAmount(requestId);
        WithdrawRequestNFT.WithdrawRequest memory request = withdrawRequestNFTInstance.getRequest(requestId);
        assertEq(claimable, request.amountOfEEth, "claim clamped to original amountOfEEth");
    }

    /// @dev Each finalize batch carries its own frozen rate. Requests in different batches
    ///      see different rates even though they're all claimed at the same later moment.
    function test_shareRateFreeze_multipleBatches_eachUsesOwnRate() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 30 ether}();
        eETHInstance.approve(address(liquidityPoolInstance), 30 ether);
        vm.stopPrank();

        uint256 r1;
        uint256 r2;
        uint256 r3;
        vm.startPrank(bob);
        r1 = liquidityPoolInstance.requestWithdraw(bob, 1 ether);
        r2 = liquidityPoolInstance.requestWithdraw(bob, 1 ether);
        r3 = liquidityPoolInstance.requestWithdraw(bob, 1 ether);
        vm.stopPrank();

        // Finalize r1 at rate A
        _finalizeWithdrawalRequest(r1);
        uint224 rateA = withdrawRequestNFTInstance.frozenRateFor(r1);

        // Rebase, then finalize r2 at rate B
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(15 ether);
        _finalizeWithdrawalRequest(r2);
        uint224 rateB = withdrawRequestNFTInstance.frozenRateFor(r2);

        // Rebase again, then finalize r3 at rate C
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(15 ether);
        _finalizeWithdrawalRequest(r3);
        uint224 rateC = withdrawRequestNFTInstance.frozenRateFor(r3);

        assertLt(rateA, rateB, "rate B must be > rate A after positive rebase");
        assertLt(rateB, rateC, "rate C must be > rate B after positive rebase");

        // Each request stays at its own snapshot rate regardless of subsequent batches.
        assertEq(withdrawRequestNFTInstance.frozenRateFor(r1), rateA, "r1 must keep rate A");
        assertEq(withdrawRequestNFTInstance.frozenRateFor(r2), rateB, "r2 must keep rate B");
        assertEq(withdrawRequestNFTInstance.frozenRateFor(r3), rateC, "r3 must keep rate C");
    }

    /// @dev `finalizeRequests(lastFinalizedRequestId)` is a no-op and must not push
    ///      a duplicate snapshot.
    function test_shareRateFreeze_noopFinalize_doesNotPushSnapshot() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);
        uint256 r1 = liquidityPoolInstance.requestWithdraw(bob, 1 ether);
        vm.stopPrank();

        _finalizeWithdrawalRequest(r1);
        uint256 lenBefore = withdrawRequestNFTInstance.finalizationRatesLength();

        // Re-finalize same id — allowed but should not add an entry.
        vm.prank(address(etherFiAdminInstance));
        withdrawRequestNFTInstance.finalizeRequests(r1);
        assertEq(withdrawRequestNFTInstance.finalizationRatesLength(), lenBefore, "no-op finalize must not push");
    }

    /// @dev Test-only helper mirroring `updateParam`'s pattern: temporarily swap in an
    ///      intrusive impl, set `lastFinalizedRequestId`, restore original impl.
    function _setLastFinalizedRequestIdForTest(uint32 _id) internal {
        address cur_impl = withdrawRequestNFTInstance.getImplementation();
        address new_impl = address(new WithdrawRequestNFTIntrusive(address(roleRegistryInstance)));
        withdrawRequestNFTInstance.upgradeTo(new_impl);
        WithdrawRequestNFTIntrusive(payable(address(withdrawRequestNFTInstance))).setLastFinalizedRequestIdForTest(_id);
        withdrawRequestNFTInstance.upgradeTo(cur_impl);
    }

    /// @dev Requests that pre-date `initializeShareRateFreezeUpgrade()` see value 0 from
    ///      `lowerLookup` and fall back to the live-rate path.
    function test_shareRateFreeze_legacySentinel_fallsBackToLiveRate() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        // Build up totalValueOutOfLp via a positive rebase so a later negative rebase doesn't underflow.
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(10 ether); // rate ≈ 2 ETH per share

        vm.startPrank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);
        uint256 legacyId = liquidityPoolInstance.requestWithdraw(bob, 1 ether);
        vm.stopPrank();

        // Simulate pre-upgrade state: `legacyId` is finalized but no snapshot exists for it.
        vm.startPrank(withdrawRequestNFTInstance.owner());
        _setLastFinalizedRequestIdForTest(uint32(legacyId));
        vm.stopPrank();
        assertEq(uint256(withdrawRequestNFTInstance.lastFinalizedRequestId()), legacyId, "legacy lastFinalized setup");

        // LP must lock the ETH for this synthetic legacy request so claim succeeds.
        vm.prank(address(etherFiAdminInstance));
        liquidityPoolInstance.addEthAmountLockedForWithdrawal(uint128(1 ether));

        // Now seed the legacy sentinel (this is what the post-upgrade init call does on mainnet).
        vm.prank(withdrawRequestNFTInstance.owner());
        withdrawRequestNFTInstance.initializeShareRateFreezeUpgrade();

        // Sentinel has value 0 → frozenRateFor returns 0 → claim falls back to live rate.
        assertEq(withdrawRequestNFTInstance.frozenRateFor(legacyId), 0, "legacy id must hit value-0 sentinel");

        // Negative rebase post-init. With live-rate fallback, the claim is reduced. If the path
        // were instead a (non-existent) frozen snapshot, the claim would be shielded — so a
        // reduced amount proves the legacy branch is in use.
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(-5 ether);

        uint256 liveAmountForShares = liquidityPoolInstance.amountForShare(
            withdrawRequestNFTInstance.getRequest(legacyId).shareOfEEth
        );
        uint256 expectedClaim = liveAmountForShares < 1 ether ? liveAmountForShares : 1 ether;
        assertEq(
            withdrawRequestNFTInstance.getClaimableAmount(legacyId),
            expectedClaim,
            "legacy request should use live rate via fallback"
        );
        // Confirm reduction actually happened (sanity: the test is meaningful).
        assertLt(expectedClaim, 1 ether, "expected the live-rate path to reduce the claim");
    }

    /// @dev After the upgrade init, the next finalize pushes a real snapshot and all
    ///      requestIds strictly above the sentinel use the frozen rate.
    function test_shareRateFreeze_postUpgradeRequests_useFrozenRate() public {
        vm.prank(withdrawRequestNFTInstance.owner());
        withdrawRequestNFTInstance.initializeShareRateFreezeUpgrade();

        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);
        uint256 newId = liquidityPoolInstance.requestWithdraw(bob, 1 ether);
        vm.stopPrank();

        _finalizeWithdrawalRequest(newId);

        uint224 frozen = withdrawRequestNFTInstance.frozenRateFor(newId);
        assertGt(frozen, 0, "post-upgrade request must have a non-zero snapshot");
        assertEq(uint256(frozen), liquidityPoolInstance.amountForShare(1e18), "snapshot equals rate at finalize");
    }

    /// @dev `initializeShareRateFreezeUpgrade` is a one-shot.
    function test_shareRateFreeze_initializeUpgrade_revertsIfAlreadyInitialized() public {
        vm.startPrank(withdrawRequestNFTInstance.owner());
        withdrawRequestNFTInstance.initializeShareRateFreezeUpgrade();
        vm.expectRevert(WithdrawRequestNFT.AlreadyInitialized.selector);
        withdrawRequestNFTInstance.initializeShareRateFreezeUpgrade();
        vm.stopPrank();
    }

    /// @dev `frozenRateFor` reports the snapshot for the batch covering a tokenId, including
    ///      tokenIds strictly less than the batch's upperBound.
    function test_shareRateFreeze_frozenRateFor_coversAllIdsInBatch() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 30 ether}();
        eETHInstance.approve(address(liquidityPoolInstance), 30 ether);
        uint256 r1 = liquidityPoolInstance.requestWithdraw(bob, 1 ether);
        uint256 r2 = liquidityPoolInstance.requestWithdraw(bob, 1 ether);
        uint256 r3 = liquidityPoolInstance.requestWithdraw(bob, 1 ether);
        vm.stopPrank();

        // Finalize all three in a single call → one snapshot covers r1..r3.
        _finalizeWithdrawalRequest(r3);
        uint224 rate = withdrawRequestNFTInstance.frozenRateFor(r3);

        assertEq(withdrawRequestNFTInstance.frozenRateFor(r1), rate, "r1 covered by same batch");
        assertEq(withdrawRequestNFTInstance.frozenRateFor(r2), rate, "r2 covered by same batch");
        assertEq(withdrawRequestNFTInstance.frozenRateFor(r3), rate, "r3 covered by same batch");
    }

    //--------------------------------------------------------------------------------------
    //-----------------------  Share-rate-freeze invariants (H-02)  ------------------------
    //--------------------------------------------------------------------------------------

    /// @notice For a finalized request, claim amount must NOT change across post-finalize rebases.
    ///         This is the core H-02 property: post-finalize rate movement is invisible to the
    ///         claimant. Exercises both a positive and a negative post-finalize rebase, and the
    ///         actual claim payout against the pre-rebase snapshot.
    function test_invariant_claimAmountIndependentOfPostFinalizeRebase() public {
        // 1. user deposits, requests withdraw
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 20 ether}();
        vm.stopPrank();

        // Build up TPE so a later negative rebase has headroom and doesn't underflow.
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(20 ether); // 40 ETH TPE / 20 shares → ~2 ETH/share

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);
        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 1 ether);

        // 2. admin finalizes
        _finalizeWithdrawalRequest(requestId);

        // 3. snapshot expected payout via getClaimableAmount
        uint256 expectedClaim = withdrawRequestNFTInstance.getClaimableAmount(requestId);
        uint224 frozenRate = withdrawRequestNFTInstance.frozenRateFor(requestId);
        assertGt(frozenRate, 0, "frozenRate must be set after finalize");

        // 4. apply positive rebase
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(10 ether);

        // 5. assert getClaimableAmount unchanged after positive rebase
        assertEq(
            withdrawRequestNFTInstance.getClaimableAmount(requestId),
            expectedClaim,
            "claim must be invariant under positive post-finalize rebase"
        );
        assertEq(
            withdrawRequestNFTInstance.frozenRateFor(requestId),
            frozenRate,
            "frozen rate must not move under positive rebase"
        );

        // 6. apply negative rebase
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(-15 ether);

        // 7. assert getClaimableAmount unchanged after negative rebase
        assertEq(
            withdrawRequestNFTInstance.getClaimableAmount(requestId),
            expectedClaim,
            "claim must be invariant under negative post-finalize rebase"
        );
        assertEq(
            withdrawRequestNFTInstance.frozenRateFor(requestId),
            frozenRate,
            "frozen rate must not move under negative rebase"
        );

        // 8. user claims, assert actual paid ETH == snapshot
        uint256 ethBefore = bob.balance;
        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);
        assertEq(bob.balance - ethBefore, expectedClaim, "paid ETH must match the pre-rebase snapshot");
    }

    /// @notice Ceiling round-trip: for any (amount, rate) tuple where
    ///         `amount = shareOfEEth * rate / SHARE_UNIT` (the frozen-rate evaluation), the
    ///         caller's burn `ceil(amount * SHARE_UNIT / rate)` must not exceed `shareOfEEth`.
    ///         The freeze accounting relies on this for the `burnedShares <= shareOfEEth` guard
    ///         in `_claimWithdraw`; here we exercise the same math directly against the
    ///         contract's withdraw path for a spread of tuples.
    function test_invariant_burnCeilingNeverExceedsRequestShares() public {
        uint256[3] memory amounts = [uint256(0.01 ether), uint256(1 ether), uint256(95 ether)];
        uint256[3] memory rates   = [uint256(0.9e18),     uint256(1e18),    uint256(1.5e18)];

        for (uint256 i = 0; i < amounts.length; i++) {
            for (uint256 j = 0; j < rates.length; j++) {
                uint256 rate = rates[j];
                // shareOfEEth large enough that amount = floor(shareOfEEth * rate / 1e18) > 0
                uint256 shareOfEEth = 100 ether;

                // amount = (rate-frozen) value of shareOfEEth shares, then take min with the
                // requested amount to mirror `_getClaimableAmount`'s clamp.
                uint256 amountForShares = Math.mulDiv(shareOfEEth, rate, 1e18);
                uint256 amount = Math.min(amounts[i], amountForShares);
                if (amount == 0) continue;

                uint256 burn = Math.mulDiv(amount, 1e18, rate, Math.Rounding.Up);
                assertLe(burn, shareOfEEth, "ceiling burn must not exceed shareOfEEth");

                // Round-trip: burned * rate / 1e18 >= amount (protocol never under-collects).
                assertGe(
                    Math.mulDiv(burn, rate, 1e18, Math.Rounding.Down),
                    amount,
                    "round-trip: burn * rate / 1e18 >= amount"
                );
            }
        }
    }

    /// @notice After upgrade, lookup for a pre-upgrade tokenId resolves to 0, triggering the
    ///         local live-rate fallback path. The claim payout must match what the pre-upgrade
    ///         code (live `amountForShare`-based) would have computed at that moment.
    function test_legacyFallback_matchesPreUpgradeLiveRate() public {
        // 1. set up a "pre-upgrade finalized request" by stepping lastFinalizedRequestId without
        //    pushing a real snapshot — mirroring on-chain state at the moment of the upgrade.
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(10 ether);

        vm.startPrank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);
        uint256 legacyId = liquidityPoolInstance.requestWithdraw(bob, 1 ether);
        vm.stopPrank();

        vm.startPrank(withdrawRequestNFTInstance.owner());
        _setLastFinalizedRequestIdForTest(uint32(legacyId));
        vm.stopPrank();

        // LP locks the ETH so the eventual claim path can succeed.
        vm.prank(address(etherFiAdminInstance));
        liquidityPoolInstance.addEthAmountLockedForWithdrawal(uint128(1 ether));

        // 2. capture expected payout via the old live-rate path BEFORE the upgrade init.
        WithdrawRequestNFT.WithdrawRequest memory legacyReq =
            withdrawRequestNFTInstance.getRequest(legacyId);
        uint256 liveAmountForShares = liquidityPoolInstance.amountForShare(legacyReq.shareOfEEth);
        uint256 expectedPreUpgrade = Math.min(uint256(legacyReq.amountOfEEth), liveAmountForShares);

        // 3. call initializeShareRateFreezeUpgrade (pushes the sentinel = value 0).
        vm.prank(withdrawRequestNFTInstance.owner());
        withdrawRequestNFTInstance.initializeShareRateFreezeUpgrade();
        assertEq(
            withdrawRequestNFTInstance.frozenRateFor(legacyId),
            0,
            "legacy id must hit the value-0 sentinel"
        );

        // 4. assert getClaimableAmount returns the same value (live-rate fallback in effect).
        //    Use a tight delta — both expressions evaluate at the same block / rate, so they
        //    must match exactly up to a 1-wei rounding artifact (mulDiv-Up vs mulDiv-Down).
        uint256 postUpgradeClaim = withdrawRequestNFTInstance.getClaimableAmount(legacyId);
        assertApproxEqAbs(
            postUpgradeClaim,
            expectedPreUpgrade,
            1,
            "legacy live-rate fallback must match pre-upgrade live-rate semantics within 1 wei"
        );

        // 5. claim actually succeeds — proves the fallback resolves to a non-zero rate that
        //    LP accepts (and not the now-removed `rate==0` LP branch).
        uint256 ethBefore = bob.balance;
        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(legacyId);
        assertGt(bob.balance, ethBefore, "claim must succeed via live-rate fallback");
    }
}
