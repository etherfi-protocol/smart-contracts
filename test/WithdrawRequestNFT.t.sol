// WithdrawRequestNFTTest.sol

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "./TestSetup.sol";

contract WithdrawRequestNFTTest is TestSetup {

    address[] public users;

    function setUp() public {
        setUpTests();
    }

    function test_WithdrawRequestNftInitializedCorrectly() public {
        assertEq(address(withdrawRequestNFTInstance.liquidityPool()), address(liquidityPoolInstance));
        assertEq(address(withdrawRequestNFTInstance.eETH()), address(eETHInstance));
    }

    function test_RequestWithdraw() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 10 ether);
        assertEq(eETHInstance.balanceOf(address(bob)), 10 ether);

        uint96 amountOfEEth = 1 ether;

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), amountOfEEth);

        vm.prank(bob);
        uint32 requestId = liquidityPoolInstance.requestWithdraw(bob, amountOfEEth);

        WithdrawRequestNFT.WithdrawRequest memory request = withdrawRequestNFTInstance.getRequest(requestId);

        assertEq(request.amountOfEEth, 1 ether, "Amount of eEth should match");
        assertEq(request.shareOfEEth, 1 ether, "Share of eEth should match");
        assertTrue(request.isValid, "Request should be valid");
    }

    function test_RequestIdIncrements() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 10 ether);

        uint96 amountOfEEth = 1 ether;

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), amountOfEEth);

        vm.prank(bob);
        uint32 requestId1 = liquidityPoolInstance.requestWithdraw(bob, amountOfEEth);

        assertEq(requestId1, 1, "Request id should be 1");

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), amountOfEEth);

        vm.prank(bob);
        uint32 requestId2 = liquidityPoolInstance.requestWithdraw(bob, amountOfEEth);

        assertEq(requestId2, 2, "Request id should be 2");
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
        uint32 requestId = liquidityPoolInstance.requestWithdraw(bob, amountOfEEth);

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
        uint32 requestId = liquidityPoolInstance.requestWithdraw(bob, amountOfEEth);

        bool requestIsFinalized = withdrawRequestNFTInstance.isFinalized(requestId);
        assertFalse(requestIsFinalized, "Request should not be finalized");

        WithdrawRequestNFT.WithdrawRequest memory request = withdrawRequestNFTInstance.getRequest(requestId);
        assertEq(request.amountOfEEth, 1 ether, "Amount of eEth should match");
        assertEq(request.shareOfEEth, 1 ether, "Share of eEth should match");
        assertTrue(request.isValid, "Request should be valid");
    }

    function testInvalidClaimWithdraw() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 10 ether);

        uint96 amountOfEEth = 1 ether;

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), amountOfEEth);

        vm.prank(bob);
        uint32 requestId = liquidityPoolInstance.requestWithdraw(bob, amountOfEEth);

        bool requestIsFinalized = withdrawRequestNFTInstance.isFinalized(requestId);
        assertFalse(requestIsFinalized, "Request should not be finalized");

        vm.expectRevert("Request is not finalized");
        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId, 1);
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
        uint32 requestId = liquidityPoolInstance.requestWithdraw(bob, amountOfEEth);

        vm.expectRevert("Not the owner of the NFT");
        vm.prank(alice);
        withdrawRequestNFTInstance.claimWithdraw(requestId, 1);
    }

    function test_ValidClaimWithdraw1() public {
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        uint256 bobsStartingBalance = address(bob).balance;

        assertEq(liquidityPoolInstance.getTotalPooledEther(), 10 ether);
        assertEq(eETHInstance.balanceOf(bob), 10 ether);
        assertEq(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)), 0 ether, "eETH balance should be 0 ether");

        // Case 1.
        // Even after the rebase, the withdrawal amount should remain the same; 1 eth
        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);

        vm.prank(bob);
        uint32 requestId = liquidityPoolInstance.requestWithdraw(bob, 1 ether);

        assertEq(withdrawRequestNFTInstance.getAccumulatedDustEEthAmount(), 0, "Accumulated dust should be 0");
        assertEq(eETHInstance.balanceOf(bob), 9 ether);
        assertEq(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)), 1 ether, "eETH balance should be 1 ether");

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
        withdrawRequestNFTInstance.claimWithdraw(requestId, 1);

        uint256 bobsEndingBalance = address(bob).balance;

        assertEq(bobsEndingBalance, bobsStartingBalance + 1 ether, "Bobs balance should be 1 ether higher");
        assertEq(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)), 1 ether, "eETH balance should be 1 ether");
        assertEq(withdrawRequestNFTInstance.getAccumulatedDustEEthAmount(), 1 ether);

        vm.prank(alice);
        withdrawRequestNFTInstance.withdrawAccumulatedDustEEth(bob);
        assertEq(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)), 0 ether, "eETH balance should be 0 ether");
        assertEq(eETHInstance.balanceOf(bob), 18 ether + 1 ether); // 1 ether eETH in `withdrawRequestNFT` contract is sent to Bob
    }

    function test_ValidClaimWithdrawWithNegativeRebase() public {
        launch_validator();
        
        startHoax(bob);
        liquidityPoolInstance.deposit{value: 11 ether}();
        vm.stopPrank();

        uint256 bobsStartingBalance = address(bob).balance;

        // 71 eth in the protocol, but 1 will be removed by the finalization before the rebase
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 11 ether + 60 ether);

        // Case 2.
        // After the rebase with negative rewards
        // - withdrawal finalized before the rebase should be processed as usual 
        // - withdrawal finalized after the rebase is reduced from 1 ether to 0.5 ether (loss of 35 eth among 70 eth)
        vm.startPrank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 2 ether);
        uint32 requestId1 = liquidityPoolInstance.requestWithdraw(bob, 1 ether);
        uint32 requestId2 = liquidityPoolInstance.requestWithdraw(bob, 1 ether);
        vm.stopPrank();

        _finalizeWithdrawalRequest(requestId1);

        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(-35 ether);

        assertEq(withdrawRequestNFTInstance.balanceOf(bob), 2, "Bobs balance should be 1");
        assertEq(withdrawRequestNFTInstance.ownerOf(requestId2), bob, "Bobs should own the NFT");

        uint32 requestId1Checkpoint = withdrawRequestNFTInstance.findCheckpointIndex(requestId1, 1, withdrawRequestNFTInstance.getLastCheckpointIndex());
        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId1, requestId1Checkpoint);
        uint256 bobBalanceAfterFirstWithdraw = address(bob).balance;
        assertEq(bobBalanceAfterFirstWithdraw, bobsStartingBalance + 1 ether, "Bobs balance should be 1 ether higher");
        
        _finalizeWithdrawalRequest(requestId2);

        uint32 requestId2Checkpoint = withdrawRequestNFTInstance.findCheckpointIndex(requestId2, 1, withdrawRequestNFTInstance.getLastCheckpointIndex());
        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId2, requestId2Checkpoint);
        uint256 bobBalanceAfterSecondWithdraw = address(bob).balance;

        assertEq(bobBalanceAfterSecondWithdraw, bobBalanceAfterFirstWithdraw + 0.5 ether, "Bobs balance should be 0.5 ether higher");
    }

    function test_withdraw_with_zero_liquidity() public {
        // bob mints 60 eETH and alilce spins up 2 validators with the deposited 60 ETH
        launch_validator();

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 60 ether);

        // bob requests withdrawal
        vm.prank(bob);
        uint32 requestId = liquidityPoolInstance.requestWithdraw(bob, 60 ether);

        // Somehow, LP gets some ETH
        // For example, alice deposits 100 ETH :D
        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 100 ether}();

        _finalizeWithdrawalRequest(requestId);

        uint256 bobsStartingBalance = address(bob).balance;

        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId, 1);

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
        uint32 requestId = liquidityPoolInstance.requestWithdraw(bob, 9);
        assertEq(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)), 8);
        // Within `LP.requestWithdraw`
        // - `share` is calculated by `sharesForAmount` as (9 * 98) / 100 = 8.82 ---> (rounded down to) 8
        
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(2);

        _finalizeWithdrawalRequest(requestId);

        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId, 1);

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
    function test_InvalidatedRequestNft_after_finalization() public returns (uint32 requestId) {
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

        vm.prank(alice);
        withdrawRequestNFTInstance.invalidateRequest(requestId);
    }

    function test_InvalidatedRequestNft_before_finalization() public returns (uint32 requestId) {
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

        vm.prank(alice);
        withdrawRequestNFTInstance.invalidateRequest(requestId);

        _finalizeWithdrawalRequest(requestId);
    }

    function test_InvalidatedRequestNft_NonTransferrable() public {
        uint32 requestId = test_InvalidatedRequestNft_after_finalization();

        vm.prank(alice);
        vm.expectRevert("INVALID_REQUEST");
        withdrawRequestNFTInstance.transferFrom(alice, bob, requestId);
    }

    function test_seizeInvalidAndMintNew_revert_if_not_owner() public {
        uint32 requestId = test_InvalidatedRequestNft_after_finalization();
        uint256 claimableAmount = withdrawRequestNFTInstance.getRequest(requestId).amountOfEEth;

        // REVERT if not owner
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        withdrawRequestNFTInstance.seizeInvalidRequest(requestId, chad, 1);
    }

    function test_InvalidatedRequestNft_seizeInvalidAndMintNew_1() public {
        uint32 requestId = test_InvalidatedRequestNft_after_finalization();
        uint256 claimableAmount = withdrawRequestNFTInstance.getRequest(requestId).amountOfEEth;
        uint256 chadBalance = address(chad).balance;

        vm.prank(owner);
        withdrawRequestNFTInstance.seizeInvalidRequest(requestId, chad, 1);

        assertEq(address(chad).balance, chadBalance + claimableAmount, "Chad should receive the claimable amount");
    }

    function test_InvalidatedRequestNft_seizeInvalidAndMintNew_2() public {
        uint32 requestId = test_InvalidatedRequestNft_before_finalization();
        uint256 claimableAmount = withdrawRequestNFTInstance.getRequest(requestId).amountOfEEth;
        uint256 chadBalance = address(chad).balance;

        vm.prank(owner);
        withdrawRequestNFTInstance.seizeInvalidRequest(requestId, chad, 1);

        assertEq(address(chad).balance, chadBalance + claimableAmount, "Chad should receive the claimable amount");
    }

    function test_updated_checkpoint_logic() public {
        for (uint256 i = 0; i < 50; i++) {
            address user = vm.addr(i + 1);
            users.push(user);
            vm.deal(user, 15 ether);
            vm.prank(users[i]);
            liquidityPoolInstance.deposit{value: 1 ether}();
        }

        // first users request withdrawal
        for (uint256 i = 0; i < 25; i++) {
            vm.startPrank(users[i]);
            eETHInstance.approve(address(liquidityPoolInstance), 1 ether);
            liquidityPoolInstance.requestWithdraw(users[i], 1 ether);
            vm.stopPrank();
        }
        
        // rebase
        vm.prank(address(membershipManagerInstance));
        // eETH value doubles
        liquidityPoolInstance.rebase(50 ether);

        // finalize the requests in multiple batches

        _finalizeWithdrawalRequest(5);

        uint256 dustShares1 = withdrawRequestNFTInstance.getAccumulatedDustEEthAmount();
        
        // no new NFTs where finalized during this period
        _finalizeWithdrawalRequest(5);
        // dust should remain the same amount 
        assertEq(dustShares1, withdrawRequestNFTInstance.getAccumulatedDustEEthAmount());
        
        vm.expectRevert("Invalid lastRequestId submitted");
        _finalizeWithdrawalRequest(4);

        _finalizeWithdrawalRequest(11);
        _finalizeWithdrawalRequest(12);
        _finalizeWithdrawalRequest(13);
        _finalizeWithdrawalRequest(17);
        _finalizeWithdrawalRequest(23);
        _finalizeWithdrawalRequest(withdrawRequestNFTInstance.nextRequestId() - 1);

        // claim all but 1 request
        for (uint32 i = 0; i < 24; i++) {
            uint32 requestId = i + 1;
            uint32 requestCheckpointIndex = withdrawRequestNFTInstance.findCheckpointIndex(requestId, 1, withdrawRequestNFTInstance.getLastCheckpointIndex());
            vm.prank(users[i]);
            withdrawRequestNFTInstance.claimWithdraw(requestId, requestCheckpointIndex);
        }

        // claim excess rewards for all requests even the unclaimed one
        assertEq(withdrawRequestNFTInstance.getAccumulatedDustEEthAmount(), 25 ether);

        uint256 aliceBalanceBefore = eETHInstance.balanceOf(alice);
        vm.prank(alice);
        withdrawRequestNFTInstance.withdrawAccumulatedDustEEth(alice);
        uint256 aliceBalanceAfter = eETHInstance.balanceOf(alice);
        assertEq(aliceBalanceAfter - aliceBalanceBefore, 25 ether);

        // claim the last request
        uint32 lastRequestId = 25;
        uint32 lastRequestCheckpointIndex = withdrawRequestNFTInstance.findCheckpointIndex(lastRequestId, 1, withdrawRequestNFTInstance.getLastCheckpointIndex());
        vm.prank(users[24]);
        withdrawRequestNFTInstance.claimWithdraw(lastRequestId, lastRequestCheckpointIndex);

        for (uint256 i = 0; i < 25; i++) {
            assertEq(users[i].balance, 15 ether);
        }
    }
}
