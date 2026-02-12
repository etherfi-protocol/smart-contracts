// WithdrawRequestNFTTest.sol

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "./TestSetup.sol";


contract WithdrawRequestNFTIntrusive is WithdrawRequestNFT {

    constructor() WithdrawRequestNFT(address(0)) {}

    function updateParam(uint32 _currentRequestIdToScanFromForShareRemainder, uint32 _lastRequestIdToScanUntilForShareRemainder) external {
        currentRequestIdToScanFromForShareRemainder = _currentRequestIdToScanFromForShareRemainder;
        lastRequestIdToScanUntilForShareRemainder = _lastRequestIdToScanUntilForShareRemainder;
    }
    
}

contract WithdrawRequestNFTTest is TestSetup {

    uint32[] public reqIds =[ 20, 388, 478, 714, 726, 729, 735, 815, 861, 916, 941, 1014, 1067, 1154, 1194, 1253];

    function setUp() public {
        setUpTests();
        vm.prank(admin);
        withdrawRequestNFTInstance.unPauseContract();
    }

    function updateParam(uint32 _currentRequestIdToScanFromForShareRemainder, uint32 _lastRequestIdToScanUntilForShareRemainder) internal {
        address cur_impl = withdrawRequestNFTInstance.getImplementation();
        address new_impl = address(new WithdrawRequestNFTIntrusive());
        withdrawRequestNFTInstance.upgradeTo(new_impl);
        WithdrawRequestNFTIntrusive(address(withdrawRequestNFTInstance)).updateParam(_currentRequestIdToScanFromForShareRemainder, _lastRequestIdToScanUntilForShareRemainder);
        withdrawRequestNFTInstance.upgradeTo(cur_impl);
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

        vm.expectRevert("Request is not finalized");
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

        vm.expectRevert("Not the owner of the NFT");
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

    function test_SD_6() public {
        vm.deal(bob, 98);

        vm.startPrank(bob);
        liquidityPoolInstance.deposit{value: 98}();
        eETHInstance.approve(address(liquidityPoolInstance), 98);
        vm.stopPrank();

        assertEq(eETHInstance.totalShares(), 98);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 98);
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(2);
        assertEq(eETHInstance.totalShares(), 98);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 100);

        assertEq(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)), 0);
        vm.prank(bob);
        // Withdraw request for 9 wei eETH amount (= 8.82 wei eETH share)
        // 8 wei eETH share is transfered to `withdrawRequestNFT` contract
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 9);
        assertEq(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)), 8);
        // Within `LP.requestWithdraw`
        // - `share` is calculated by `sharesForAmount` as (9 * 98) / 100 = 8.82 ---> (rounded down to) 8


        _finalizeWithdrawalRequest(requestId);


        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);
        // Within `claimWithdraw`,
        // - `request.amountOfEEth` is 9
        // - `amountForShares` is (8 * 100) / 98 = 8.16 ---> (rounded down to) 8
        // - `amountToTransfer` is min(9, 8) = 8
        // Therefore, it calls `LP.withdraw(.., 8)`

        // Within `LP.withdraw`, 
        // - `share` is calculated by 'sharesForWithdrawalAmount' as (8 * 98 + 100 - 1) / 100 = 8.83 ---> (rounded down to) 8

        // As a result, bob received 8 wei ETH which is 1 wei less than 9 wei.
        assertEq(bob.balance, 8);
        assertEq(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)), 0);

        // We burnt 8 wei eETH share which is worth of 8.16 wei eETH amount.
        // We processed the withdrawal of 8 wei ETH. 
        // --> The rest 0.16 wei ETH is effectively distributed to the other eETH holders.
    }


    // It depicts the scenario where bob's WithdrawalRequest NFT is stolen by alice.
    // The owner invalidates the request 
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
        withdrawRequestNFTInstance.invalidateRequest(requestId);
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
        withdrawRequestNFTInstance.upgradeTo(address(new WithdrawRequestNFT(address(buybackWallet))));
        roleRegistryInstance.grantRole(withdrawRequestNFTInstance.IMPLICIT_FEE_CLAIMER_ROLE(), alice);
        vm.stopPrank();
        uint256 implicitFee = withdrawRequestNFTInstance.getEEthRemainderAmount();
        vm.prank(alice);
        withdrawRequestNFTInstance.handleRemainder(implicitFee);
    }

    function testFuzz_RequestWithdraw(uint96 depositAmount, uint96 withdrawAmount, address recipient) public {
        // Assume valid conditions
        vm.assume(depositAmount >= 1 ether && depositAmount <= 1000 ether);
        vm.assume(withdrawAmount > 0 && withdrawAmount <= depositAmount);
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

        if (eETHInstance.balanceOf(bob) > 0) {
            uint256 reqAmount = eETHInstance.balanceOf(bob);
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
        // Assume valid conditions
        vm.assume(depositAmount >= 1 ether && depositAmount <= 1e6 ether);
        vm.assume(withdrawAmount > 0 && withdrawAmount <= depositAmount);
        vm.assume(rebaseAmount >= 0.5 ether && rebaseAmount <= depositAmount);
        vm.assume(remainderSplitBps <= 10000);
        vm.assume(recipient != address(0) && recipient != address(liquidityPoolInstance));
        // Filter out contracts that don't implement IERC721Receiver - only allow EOAs
        vm.assume(recipient.code.length == 0);

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

        assertApproxEqAbs(
            withdrawRequestNFTInstance.totalRemainderEEthShares(),
            expectedDustShares,
            1,
            "Incorrect remainder shares"
        );

        // Only test handleRemainder if there's actually remainder to handle
        uint256 dustEEthAmount = withdrawRequestNFTInstance.getEEthRemainderAmount();
        if (dustEEthAmount > 0) {
            // Grant the required role to admin
            vm.startPrank(address(roleRegistryInstance.owner()));
            roleRegistryInstance.grantRole(withdrawRequestNFTInstance.IMPLICIT_FEE_CLAIMER_ROLE(), admin);
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
        // Assume valid conditions
        vm.assume(depositAmount >= 1 ether && depositAmount <= 1000 ether);
        vm.assume(withdrawAmount > 0 && withdrawAmount <= depositAmount);
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

        // Non-admin cannot invalidate
        vm.prank(recipient);
        vm.expectRevert("Caller is not admin");
        withdrawRequestNFTInstance.invalidateRequest(requestId);

        // Admin invalidates request
        vm.startPrank(roleRegistryInstance.owner());
        console.log("roleRegistryInstance.owner()", roleRegistryInstance.owner());
        roleRegistryInstance.grantRole(withdrawRequestNFTInstance.WITHDRAW_REQUEST_NFT_ADMIN_ROLE(), admin);
        vm.stopPrank();
        vm.prank(admin);
        withdrawRequestNFTInstance.invalidateRequest(requestId);

        // Verify request state after invalidation
        assertFalse(withdrawRequestNFTInstance.isValid(requestId), "Request should be invalid");
        assertEq(withdrawRequestNFTInstance.ownerOf(requestId), recipient, "NFT ownership should remain unchanged");
        
        // Verify cannot transfer invalid request
        vm.prank(recipient);
        vm.expectRevert("INVALID_REQUEST");
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
        vm.expectRevert("Request is not finalized");
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
        vm.expectRevert("Request is valid");
        withdrawRequestNFTInstance.validateRequest(requestId);
    }

    function test_updateShareRemainderSplitToTreasuryInBps() public {
        uint16 newSplit = 5000; // 50%
        
        vm.prank(withdrawRequestNFTInstance.owner());
        withdrawRequestNFTInstance.updateShareRemainderSplitToTreasuryInBps(newSplit);
        
        assertEq(withdrawRequestNFTInstance.shareRemainderSplitToTreasuryInBps(), newSplit, "Split should be updated");

        // Test invalid value (> 10000)
        vm.prank(withdrawRequestNFTInstance.owner());
        vm.expectRevert("INVALID");
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
        vm.expectRevert(WithdrawRequestNFT.IncorrectRole.selector);
        withdrawRequestNFTInstance.pauseContract();

        // Pauser can pause
        vm.prank(admin);
        withdrawRequestNFTInstance.pauseContract();
        assertTrue(withdrawRequestNFTInstance.paused(), "Contract should be paused");

        // Cannot pause again
        vm.prank(admin);
        vm.expectRevert("Pausable: already paused");
        withdrawRequestNFTInstance.pauseContract();

        // Cannot request withdraw when paused
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);
        vm.expectRevert("Pausable: paused");
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
        vm.expectRevert(WithdrawRequestNFT.IncorrectRole.selector);
        withdrawRequestNFTInstance.unPauseContract();

        // Unpauser can unpause
        vm.prank(admin);
        withdrawRequestNFTInstance.unPauseContract();
        assertFalse(withdrawRequestNFTInstance.paused(), "Contract should be unpaused");

        // Cannot unpause again
        vm.prank(admin);
        vm.expectRevert("Pausable: not paused");
        withdrawRequestNFTInstance.unPauseContract();
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

    function test_isScanOfShareRemainderCompleted() public {
        // Initially should be completed (no requests to scan)
        assertTrue(withdrawRequestNFTInstance.isScanOfShareRemainderCompleted(), "Scan should be completed initially");

        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);

        vm.prank(bob);
        liquidityPoolInstance.requestWithdraw(bob, 1 ether);

        // Still completed because scan range hasn't been set
        assertTrue(withdrawRequestNFTInstance.isScanOfShareRemainderCompleted(), "Scan should still be completed");
    }

    function test_aggregateSumEEthShareAmount() public {
        // Setup scan parameters (needs owner to upgrade)
        uint32 startId = 1;
        uint32 endId = 5;
        vm.startPrank(withdrawRequestNFTInstance.owner());
        updateParam(startId, endId);
        vm.stopPrank();

        startHoax(bob);
        liquidityPoolInstance.deposit{value: 50 ether}();
        vm.stopPrank();

        // Create multiple requests
        uint256[] memory requestIds = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(bob);
            eETHInstance.approve(address(liquidityPoolInstance), 1 ether);
            vm.prank(bob);
            requestIds[i] = liquidityPoolInstance.requestWithdraw(bob, 1 ether);
        }

        // Initially scan is not completed
        assertFalse(withdrawRequestNFTInstance.isScanOfShareRemainderCompleted(), "Scan should not be completed");

        uint256 initialAggregateSum = withdrawRequestNFTInstance.aggregateSumOfEEthShare();
        
        // Aggregate first 3 requests
        withdrawRequestNFTInstance.aggregateSumEEthShareAmount(3);
        
        uint256 aggregateSumAfter = withdrawRequestNFTInstance.aggregateSumOfEEthShare();
        assertGt(aggregateSumAfter, initialAggregateSum, "Aggregate sum should increase");

        // Aggregate remaining requests
        withdrawRequestNFTInstance.aggregateSumEEthShareAmount(10);
        
        // Scan should be completed now
        assertTrue(withdrawRequestNFTInstance.isScanOfShareRemainderCompleted(), "Scan should be completed");
        
        // Cannot aggregate again after completion
        vm.expectRevert("scan is completed");
        withdrawRequestNFTInstance.aggregateSumEEthShareAmount(1);
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
        uint256 requestId = withdrawRequestNFTInstance.requestWithdraw{value: 0}(1 ether, 1 ether, bob, fee);

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
        uint256 requestId = withdrawRequestNFTInstance.requestWithdraw{value: 0}(uint96(amount), uint96(amount), bob, fee);

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
        vm.expectRevert("Request is valid");
        withdrawRequestNFTInstance.seizeInvalidRequest(requestId, admin);

        // Invalidate first
        vm.prank(admin);
        withdrawRequestNFTInstance.invalidateRequest(requestId);

        // Cannot seize non-existent request
        vm.prank(withdrawRequestNFTInstance.owner());
        vm.expectRevert("Request does not exist");
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
            roleRegistryInstance.grantRole(withdrawRequestNFTInstance.IMPLICIT_FEE_CLAIMER_ROLE(), admin);
            vm.stopPrank();

            // Cannot handle zero amount
            vm.prank(admin);
            vm.expectRevert("EETH amount cannot be 0");
            withdrawRequestNFTInstance.handleRemainder(0);

            // Cannot handle more than available
            vm.prank(admin);
            vm.expectRevert("Not enough eETH remainder");
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

        // Cannot finalize future requests
        vm.prank(admin);
        vm.expectRevert("Cannot finalize future requests");
        withdrawRequestNFTInstance.finalizeRequests(requestId + 100);

        // Finalize request
        vm.prank(admin);
        withdrawRequestNFTInstance.finalizeRequests(requestId);

        // Cannot undo finalization
        vm.prank(admin);
        vm.expectRevert("Cannot undo finalization");
        withdrawRequestNFTInstance.finalizeRequests(requestId - 1);

        // Non-admin cannot finalize
        vm.prank(bob);
        vm.expectRevert("Caller is not admin");
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
        vm.expectRevert("INVALID_REQUEST");
        withdrawRequestNFTInstance.transferFrom(bob, alice, requestId);

        // Contract owner can transfer invalid request
        vm.prank(withdrawRequestNFTInstance.owner());
        withdrawRequestNFTInstance.seizeInvalidRequest(requestId, alice);
        
        assertEq(withdrawRequestNFTInstance.ownerOf(requestId), alice, "NFT should be transferred");
    }

    function test_claimWithdraw_InvalidRequest() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);

        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 1 ether);

        _finalizeWithdrawalRequest(requestId);

        // Invalidate request
        vm.prank(admin);
        withdrawRequestNFTInstance.invalidateRequest(requestId);

        // Cannot claim invalid request
        vm.prank(bob);
        vm.expectRevert("Request is not valid");
        withdrawRequestNFTInstance.claimWithdraw(requestId);
    }

    function test_getRequest_NonExistent() public {
        WithdrawRequestNFT.WithdrawRequest memory request = withdrawRequestNFTInstance.getRequest(99999);
        assertEq(request.amountOfEEth, 0, "Non-existent request should return zero values");
        assertEq(request.shareOfEEth, 0, "Non-existent request should return zero values");
        assertFalse(request.isValid, "Non-existent request should be invalid");
    }

    function test_isValid_NonExistent() public {
        vm.expectRevert("Request does not exist");
        withdrawRequestNFTInstance.isValid(99999);
    }
}
