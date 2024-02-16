// WithdrawRequestNFTTest.sol

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "./TestSetup.sol";

contract WithdrawRequestNFTTest is TestSetup {
    bytes32[] public aliceProof;
    bytes32[] public bobProof;

    function setUp() public {
        setUpTests();
        aliceProof = merkle.getProof(whiteListedAddresses, 3);
        bobProof = merkle.getProof(whiteListedAddresses, 4);
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
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, amountOfEEth);

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
        uint256 requestId1 = liquidityPoolInstance.requestWithdraw(bob, amountOfEEth);

        assertEq(requestId1, 1, "Request id should be 1");

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), amountOfEEth);

        vm.prank(bob);
        uint256 requestId2 = liquidityPoolInstance.requestWithdraw(bob, amountOfEEth);

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

    function testInvalidClaimWithdraw() public {
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
        assertEq(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)), 0 ether, "eETH balance should be 0 ether");

        // Case 1.
        // Even after the rebase, the withdrawal amount should remain the same; 1 eth
        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 1 ether);

        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 1 ether);

        assertEq(withdrawRequestNFTInstance.accumulatedDustEEthShares(), 0, "Accumulated dust should be 0");
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
        withdrawRequestNFTInstance.claimWithdraw(requestId);

        uint256 bobsEndingBalance = address(bob).balance;

        assertEq(bobsEndingBalance, bobsStartingBalance + 1 ether, "Bobs balance should be 1 ether higher");
        assertEq(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)), 1 ether, "eETH balance should be 1 ether");
        assertEq(liquidityPoolInstance.amountForShare(withdrawRequestNFTInstance.accumulatedDustEEthShares()), 1 ether);

        vm.prank(alice);
        withdrawRequestNFTInstance.burnAccumulatedDustEEthShares();
        assertEq(eETHInstance.balanceOf(address(withdrawRequestNFTInstance)), 0 ether, "eETH balance should be 0 ether");
        assertEq(eETHInstance.balanceOf(bob), 18 ether + 1 ether); // 1 ether eETH in `withdrawRequestNFT` contract is re-distributed to the eETH holders
    }

    function test_ValidClaimWithdrawWithNegativeRebase() public {
        launch_validator();

        startHoax(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        vm.stopPrank();

        uint256 bobsStartingBalance = address(bob).balance;

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

        assertEq(bobsEndingBalance, bobsStartingBalance + 0.5 ether, "Bobs balance should be 1 ether higher");
    }

    function test_withdraw_with_zero_liquidity() public {
        // bob mints 60 eETH and alilce spins up 2 validators with the deposited 60 ETH
        launch_validator();

        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), 60 ether);

        // bob requests withdrawal
        vm.prank(bob);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 60 ether);

        // Somehow, LP gets some ETH
        // For example, alice deposits 100 ETH :D
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
}
