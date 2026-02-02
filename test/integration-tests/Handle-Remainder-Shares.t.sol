// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "../TestSetup.sol";
import "../../script/deploys/Deployed.s.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract HandleRemainderSharesIntegrationTest is TestSetup, Deployed {

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);
        vm.etch(alice, bytes(""));
        vm.etch(bob, bytes(""));
    }

    function test_HandleRemainder() public {
        // Setup: Create remainder by depositing, requesting withdrawal, rebase, and claiming
        vm.deal(bob, 10 ether);
        vm.startPrank(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        eETHInstance.approve(address(liquidityPoolInstance), 5 ether);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 5 ether);
        vm.stopPrank();

        // Rebase to create remainder (increase liquidity pool's ETH backing)
        vm.prank(address(membershipManagerV1Instance));
        liquidityPoolInstance.rebase(5 ether);

        // Finalize and claim the withdrawal to create remainder
        vm.prank(ETHERFI_ADMIN);
        withdrawRequestNFTInstance.finalizeRequests(requestId);

        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);

        uint256 remainderAmount = withdrawRequestNFTInstance.getEEthRemainderAmount();
        assertGt(remainderAmount, 0, "Remainder amount should be greater than 0");

        // Grant the IMPLICIT_FEE_CLAIMER_ROLE to alice
        vm.startPrank(address(roleRegistryInstance.owner()));
        withdrawRequestNFTInstance.upgradeTo(address(new WithdrawRequestNFT(address(buybackWallet))));
        roleRegistryInstance.grantRole(withdrawRequestNFTInstance.IMPLICIT_FEE_CLAIMER_ROLE(), alice);
        vm.stopPrank();

        // Record state before handling remainder
        uint256 treasuryBalanceBefore = eETHInstance.balanceOf(buybackWallet);
        uint256 contractSharesBefore = eETHInstance.shares(address(withdrawRequestNFTInstance));
        uint256 totalRemainderBefore = withdrawRequestNFTInstance.totalRemainderEEthShares();

        // Calculate expected values
        uint256 shareRemainderSplitToTreasury = withdrawRequestNFTInstance.shareRemainderSplitToTreasuryInBps();
        uint256 expectedToTreasury = Math.mulDiv(remainderAmount, shareRemainderSplitToTreasury, 10000);
        uint256 expectedToBurn = remainderAmount - expectedToTreasury;

        uint256 expectedSharesToBurn = liquidityPoolInstance.sharesForAmount(expectedToBurn);
        uint256 expectedSharesToTreasury = liquidityPoolInstance.sharesForAmount(expectedToTreasury);
        uint256 expectedTotalSharesMoved = expectedSharesToBurn + expectedSharesToTreasury;

        // Handle the remainder
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit WithdrawRequestNFT.HandledRemainderOfClaimedWithdrawRequests(expectedToTreasury, expectedToBurn);
        withdrawRequestNFTInstance.handleRemainder(remainderAmount);

        // Verify state changes
        uint256 treasuryBalanceAfter = eETHInstance.balanceOf(buybackWallet);
        uint256 contractSharesAfter = eETHInstance.shares(address(withdrawRequestNFTInstance));
        uint256 totalRemainderAfter = withdrawRequestNFTInstance.totalRemainderEEthShares();

        // Treasury received correct amount
        assertApproxEqAbs(treasuryBalanceAfter - treasuryBalanceBefore, expectedToTreasury, 1e9, "Treasury should receive correct portion");

        // Contract shares decreased by expected amount
        assertApproxEqAbs(contractSharesBefore - contractSharesAfter, expectedTotalSharesMoved, 1e9, "Contract shares should decrease by moved amount");

        // Total remainder shares decreased correctly
        assertApproxEqAbs(totalRemainderBefore - totalRemainderAfter, expectedTotalSharesMoved, 1e9, "Total remainder shares should decrease");

        // Invariant: contract shares should match expected after accounting for moves
        assertApproxEqAbs(contractSharesAfter, contractSharesBefore - expectedTotalSharesMoved, 1e9, "Contract shares invariant check");
    }

    function test_HandleRemainder_PartialHandling() public {
        // Setup: Create remainder and handle only part of it
        vm.deal(bob, 500 ether);
        vm.startPrank(bob);
        liquidityPoolInstance.deposit{value: 500 ether}();
        eETHInstance.approve(address(liquidityPoolInstance), 200 ether);

        // Create multiple withdrawal requests to generate larger remainder
        uint256[] memory requestIds = new uint256[](20);
        for (uint256 i = 0; i < 20; i++) {
            requestIds[i] = liquidityPoolInstance.requestWithdraw(bob, 10 ether);
        }
        vm.stopPrank();

        // Skip rebase or do minimal rebase to create larger remainder
        vm.prank(address(membershipManagerV1Instance));
        liquidityPoolInstance.rebase(1 ether);

        // Finalize and claim all requests
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(ETHERFI_ADMIN);
            withdrawRequestNFTInstance.finalizeRequests(requestIds[i]);

            vm.prank(bob);
            withdrawRequestNFTInstance.claimWithdraw(requestIds[i]);
        }

        uint256 remainderAmount = withdrawRequestNFTInstance.getEEthRemainderAmount();
        assertGt(remainderAmount, 0.05 ether, "Remainder amount should be greater than 0.05 ether for partial handling");

        // Now upgrade the contract and grant roles
        vm.startPrank(address(roleRegistryInstance.owner()));
        withdrawRequestNFTInstance.upgradeTo(address(new WithdrawRequestNFT(address(buybackWallet))));
        roleRegistryInstance.grantRole(withdrawRequestNFTInstance.IMPLICIT_FEE_CLAIMER_ROLE(), alice);
        vm.stopPrank();

        uint256 partialAmount = remainderAmount / 2;

        // Record state before
        uint256 treasuryBalanceBefore = eETHInstance.balanceOf(buybackWallet);
        uint256 totalRemainderBefore = withdrawRequestNFTInstance.totalRemainderEEthShares();

        // Handle partial remainder
        vm.prank(alice);
        withdrawRequestNFTInstance.handleRemainder(partialAmount);

        // Verify partial handling
        uint256 treasuryBalanceAfter = eETHInstance.balanceOf(buybackWallet);
        uint256 totalRemainderAfter = withdrawRequestNFTInstance.totalRemainderEEthShares();

        uint256 shareRemainderSplitToTreasury = withdrawRequestNFTInstance.shareRemainderSplitToTreasuryInBps();
        uint256 expectedToTreasury = Math.mulDiv(partialAmount, shareRemainderSplitToTreasury, 10000);

        assertApproxEqAbs(treasuryBalanceAfter - treasuryBalanceBefore, expectedToTreasury, 1e9, "Treasury should receive partial amount");
        assertLt(totalRemainderAfter, totalRemainderBefore, "Total remainder should decrease");

        // Remaining remainder should be available for further handling
        uint256 remainingRemainder = withdrawRequestNFTInstance.getEEthRemainderAmount();
        assertGt(remainingRemainder, 0, "Remaining remainder should be greater than 0");

        // Handle remaining remainder
        vm.prank(alice);
        withdrawRequestNFTInstance.handleRemainder(remainingRemainder);

        // Should be no remainder left
        assertApproxEqAbs(withdrawRequestNFTInstance.getEEthRemainderAmount(), 0, 1e9, "All remainder should be handled");
    }

    function test_HandleRemainder_DifferentSplitRatios() public {
        // Test with different treasury split ratios
        uint16[] memory splitRatios = new uint16[](3);
        splitRatios[0] = 2000; // 20%
        splitRatios[1] = 5000; // 50%
        splitRatios[2] = 8000; // 80%

        address[] memory testUsers = new address[](3);
        testUsers[0] = bob;
        testUsers[1] = makeAddr("user2");
        vm.etch(testUsers[1], bytes(""));
        testUsers[2] = makeAddr("user3");
        vm.etch(testUsers[2], bytes(""));

        for (uint256 i = 0; i < splitRatios.length; i++) {
            address user = testUsers[i];

            // Setup: Create remainder by depositing, requesting withdrawal, rebase, and claiming
            vm.deal(user, 10 ether);
            vm.startPrank(user);
            liquidityPoolInstance.deposit{value: 10 ether}();
            eETHInstance.approve(address(liquidityPoolInstance), 5 ether);
            uint256 requestId = liquidityPoolInstance.requestWithdraw(user, 5 ether);
            vm.stopPrank();

            // Rebase to create remainder (increase liquidity pool's ETH backing)
            vm.prank(address(membershipManagerV1Instance));
            liquidityPoolInstance.rebase(5 ether);

            // Finalize and claim the withdrawal to create remainder
            vm.prank(ETHERFI_ADMIN);
            withdrawRequestNFTInstance.finalizeRequests(requestId);

            vm.prank(user);
            withdrawRequestNFTInstance.claimWithdraw(requestId);

            uint256 remainderAmount = withdrawRequestNFTInstance.getEEthRemainderAmount();
            assertGt(remainderAmount, 0, "Remainder amount should be greater than 0");

            // Update split ratio
            vm.prank(withdrawRequestNFTInstance.owner());
            withdrawRequestNFTInstance.updateShareRemainderSplitToTreasuryInBps(splitRatios[i]);

            // Grant the IMPLICIT_FEE_CLAIMER_ROLE to alice
            vm.startPrank(address(roleRegistryInstance.owner()));
            withdrawRequestNFTInstance.upgradeTo(address(new WithdrawRequestNFT(address(buybackWallet))));
            roleRegistryInstance.grantRole(withdrawRequestNFTInstance.IMPLICIT_FEE_CLAIMER_ROLE(), alice);
            vm.stopPrank();

            uint256 treasuryBalanceBefore = eETHInstance.balanceOf(buybackWallet);

            vm.prank(alice);
            withdrawRequestNFTInstance.handleRemainder(remainderAmount);

            uint256 treasuryBalanceAfter = eETHInstance.balanceOf(buybackWallet);
            uint256 expectedToTreasury = Math.mulDiv(remainderAmount, splitRatios[i], 10000);

            assertApproxEqAbs(treasuryBalanceAfter - treasuryBalanceBefore, expectedToTreasury, 1e14,
                string(abi.encodePacked("Treasury should receive correct portion for ratio ", vm.toString(splitRatios[i]))));
        }
    }
}
