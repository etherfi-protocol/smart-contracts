// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "../TestSetup.sol";
import "lib/BucketLimiter.sol";
import "../../script/deploys/Deployed.s.sol";

contract WithdrawIntegrationTest is TestSetup, Deployed {
    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address public constant LIDO_ADDRESS = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);
    }

    function test_Withdraw_EtherFiRedemptionManager_redeemEEth() public {
        // setUp();
        vm.startPrank(OPERATING_TIMELOCK);
        // Ensure bucket limiter has enough capacity and is fully refilled
        etherFiRedemptionManagerInstance.setCapacity(3000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(3000 ether, ETH_ADDRESS);
        vm.stopPrank();
        
        // Warp time forward to ensure bucket is fully refilled
        vm.warp(block.timestamp + 1);
        vm.deal(alice, 2010 ether);
        vm.startPrank(alice);

        liquidityPoolInstance.deposit{value: 2005 ether}();
        address receiver = makeAddr("withdraw-receiver");
        vm.etch(receiver, bytes(""));

        uint256 beforeEETHBalance = eETHInstance.balanceOf(alice);
        uint256 eETHAmountToRedeem = 2000 ether;
        uint256 beforeReceiverBalance = address(receiver).balance;
        uint256 beforeTreasuryBalance = eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury()));
        address treasury = address(etherFiRedemptionManagerInstance.treasury());

        // Get actual fee configuration from contract
        (, uint16 exitFeeSplitToTreasuryBps, uint16 exitFeeBps, ) = 
            etherFiRedemptionManagerInstance.tokenToRedemptionInfo(ETH_ADDRESS);
        
        // Calculate expected values using shares (more accurate)
        uint256 eEthShares = liquidityPoolInstance.sharesForAmount(eETHAmountToRedeem);
        uint256 expectedAmountToReceiver = liquidityPoolInstance.amountForShare((eEthShares * (10000 - exitFeeBps)) / 10000);
        uint256 eEthShareFee = eEthShares - liquidityPoolInstance.sharesForWithdrawalAmount(expectedAmountToReceiver);
        uint256 expectedTreasuryFee = liquidityPoolInstance.amountForShare((eEthShareFee * exitFeeSplitToTreasuryBps) / 10000);

        eETHInstance.approve(address(etherFiRedemptionManagerInstance), eETHAmountToRedeem);
        etherFiRedemptionManagerInstance.redeemEEth(eETHAmountToRedeem, receiver, ETH_ADDRESS);

        assertApproxEqAbs(address(receiver).balance, beforeReceiverBalance + expectedAmountToReceiver, 1e11); // receiver gets ETH
        assertApproxEqAbs(eETHInstance.balanceOf(alice), beforeEETHBalance - eETHAmountToRedeem, 1e11); // eETH is consumed from alice
        assertApproxEqAbs(eETHInstance.balanceOf(treasury), beforeTreasuryBalance + expectedTreasuryFee, 1e11); // treasury gets ETH

        vm.stopPrank();
    }

    function test_Withdraw_EtherFiRedemptionManager_redeemEEthWithPermit() public {
        vm.startPrank(OPERATING_TIMELOCK);
        // Ensure bucket limiter has enough capacity and is fully refilled
        etherFiRedemptionManagerInstance.setCapacity(3000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(3000 ether, ETH_ADDRESS);
        vm.stopPrank();
        
        // Warp time forward to ensure bucket is fully refilled
        vm.warp(block.timestamp + 1);
        vm.deal(alice, 2010 ether);
        vm.startPrank(alice);

        liquidityPoolInstance.deposit{value: 2005 ether}();
        address receiver = makeAddr("withdraw-receiver");
        vm.etch(receiver, bytes(""));

        uint256 beforeEETHBalance = eETHInstance.balanceOf(alice);
        uint256 eETHAmountToRedeem = 2000 ether;
        uint256 beforeReceiverBalance = address(receiver).balance;
        uint256 beforeTreasuryBalance = eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury()));
        address treasury = address(etherFiRedemptionManagerInstance.treasury());

        IeETH.PermitInput memory permit = eEth_createPermitInput(2, address(etherFiRedemptionManagerInstance), eETHAmountToRedeem, eETHInstance.nonces(alice), 2**256 - 1, eETHInstance.DOMAIN_SEPARATOR()); // alice = vm.addr(2)

        // Get actual fee configuration from contract
        (, uint16 exitFeeSplitToTreasuryBps, uint16 exitFeeBps, ) = 
            etherFiRedemptionManagerInstance.tokenToRedemptionInfo(ETH_ADDRESS);
        
        // Calculate expected values using shares (more accurate)
        uint256 eEthShares = liquidityPoolInstance.sharesForAmount(eETHAmountToRedeem);
        uint256 expectedAmountToReceiver = liquidityPoolInstance.amountForShare((eEthShares * (10000 - exitFeeBps)) / 10000);
        uint256 eEthShareFee = eEthShares - liquidityPoolInstance.sharesForWithdrawalAmount(expectedAmountToReceiver);
        uint256 expectedTreasuryFee = liquidityPoolInstance.amountForShare((eEthShareFee * exitFeeSplitToTreasuryBps) / 10000);

        eETHInstance.approve(address(etherFiRedemptionManagerInstance), eETHAmountToRedeem);
        etherFiRedemptionManagerInstance.redeemEEthWithPermit(eETHAmountToRedeem, receiver, permit, ETH_ADDRESS);

        assertApproxEqAbs(address(receiver).balance, beforeReceiverBalance + expectedAmountToReceiver, 1e11); // receiver gets ETH
        assertApproxEqAbs(eETHInstance.balanceOf(alice), beforeEETHBalance - eETHAmountToRedeem, 1e11); // eETH is consumed from alice
        assertApproxEqAbs(eETHInstance.balanceOf(treasury), beforeTreasuryBalance + expectedTreasuryFee, 1e11); // treasury gets ETH

        vm.stopPrank();
    }

    function test_Withdraw_EtherFiRedemptionManager_redeemWeEth() public {
        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: 10 ether}(); // to get eETH to generate weETH
        eETHInstance.approve(address(weEthInstance), 10 ether);
        weEthInstance.wrap(1 ether); // to get weETH to redeem

        uint256 weEthAmount = weEthInstance.balanceOf(alice);
        uint256 eEthAmount = weEthInstance.getEETHByWeETH(weEthAmount);
        uint256 eEthShares = liquidityPoolInstance.sharesForAmount(eEthAmount);
        // NOTE: on mainnet forks, vm.addr(N) can map to an address that already has code
        // and may forward ETH in its receive/fallback, making balance-based asserts flaky.
        address receiver = makeAddr("withdraw-receiver");
        vm.etch(receiver, bytes(""));
        uint256 receiverBalance = address(receiver).balance;
        address treasury = etherFiRedemptionManagerInstance.treasury();
        uint256 treasuryBalanceBefore = eETHInstance.balanceOf(treasury);
        uint256 beforeWeETHBalance = weEthInstance.balanceOf(alice);

        weEthInstance.approve(address(etherFiRedemptionManagerInstance), 1 ether);
        etherFiRedemptionManagerInstance.redeemWeEth(weEthAmount, receiver, ETH_ADDRESS);

        // Use exact same calculation flow as _calcRedemption to account for rounding differences
        (, uint16 exitFeeSplitToTreasuryBps, uint16 exitFeeBps, ) = 
            etherFiRedemptionManagerInstance.tokenToRedemptionInfo(ETH_ADDRESS);
        uint256 expectedAmountToReceiver = liquidityPoolInstance.amountForShare(
            eEthShares * (10000 - exitFeeBps) / 10000
        );
        uint256 sharesToBurn = liquidityPoolInstance.sharesForWithdrawalAmount(expectedAmountToReceiver);
        uint256 eEthShareFee = eEthShares - sharesToBurn;
        uint256 feeShareToTreasury = eEthShareFee * exitFeeSplitToTreasuryBps / 10000;
        uint256 expectedTreasuryFee = liquidityPoolInstance.amountForShare(feeShareToTreasury);
        
        assertApproxEqAbs(eETHInstance.balanceOf(treasury), treasuryBalanceBefore + expectedTreasuryFee, 1e11); // treasury gets ETH
        assertApproxEqAbs(address(receiver).balance, receiverBalance + expectedAmountToReceiver, 1e11); // receiver gets ETH
        vm.stopPrank();
    }

    function test_Withdraw_EtherFiRedemptionManager_redeemWeEthWithPermit() public {

        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: 10 ether}(); // to get eETH to generate weETH
        eETHInstance.approve(address(weEthInstance), 10 ether);
        weEthInstance.wrap(1 ether); // to get weETH to redeem

        uint256 weEthAmount = weEthInstance.balanceOf(alice);
        uint256 eEthAmount = weEthInstance.getEETHByWeETH(weEthAmount);
        uint256 eEthShares = liquidityPoolInstance.sharesForAmount(eEthAmount);
        // NOTE: on mainnet forks, vm.addr(N) can map to an address that already has code
        // and may forward ETH in its receive/fallback, making balance-based asserts flaky.
        address receiver = makeAddr("withdraw-receiver");
        vm.etch(receiver, bytes(""));
        uint256 receiverBalance = address(receiver).balance;
        address treasury = etherFiRedemptionManagerInstance.treasury();
        uint256 treasuryBalanceBefore = eETHInstance.balanceOf(treasury);
        uint256 beforeWeETHBalance = weEthInstance.balanceOf(alice);

        IWeETH.PermitInput memory permit = weEth_createPermitInput(2, address(etherFiRedemptionManagerInstance), weEthAmount, weEthInstance.nonces(alice), 2**256 - 1, weEthInstance.DOMAIN_SEPARATOR()); // alice = vm.addr(2)

        weEthInstance.approve(address(etherFiRedemptionManagerInstance), 1 ether);
        etherFiRedemptionManagerInstance.redeemWeEthWithPermit(weEthAmount, receiver, permit, ETH_ADDRESS);

        // Use exact same calculation flow as _calcRedemption to account for rounding differences
        (, uint16 exitFeeSplitToTreasuryBps, uint16 exitFeeBps, ) = 
            etherFiRedemptionManagerInstance.tokenToRedemptionInfo(ETH_ADDRESS);
        uint256 expectedAmountToReceiver = liquidityPoolInstance.amountForShare(
            eEthShares * (10000 - exitFeeBps) / 10000
        );
        uint256 sharesToBurn = liquidityPoolInstance.sharesForWithdrawalAmount(expectedAmountToReceiver);
        uint256 eEthShareFee = eEthShares - sharesToBurn;
        uint256 feeShareToTreasury = eEthShareFee * exitFeeSplitToTreasuryBps / 10000;
        uint256 expectedTreasuryFee = liquidityPoolInstance.amountForShare(feeShareToTreasury);
        
        assertApproxEqAbs(eETHInstance.balanceOf(treasury), treasuryBalanceBefore + expectedTreasuryFee, 1e11); // treasury gets ETH
        assertApproxEqAbs(address(receiver).balance, receiverBalance + expectedAmountToReceiver, 1e11); // receiver gets ETH
        vm.stopPrank();
    }
}