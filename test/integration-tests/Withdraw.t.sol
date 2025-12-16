// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "../TestSetup.sol";
import "lib/BucketLimiter.sol";
import "../../script/deploys/Deployed.s.sol";

contract WithdrawTest is TestSetup, Deployed {
    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address public constant LIDO_ADDRESS = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);
    }

    function test_Withdraw_EtherFiRedemptionManager_redeemEEthForETH() public {
        setUp();
        vm.startPrank(OPERATING_TIMELOCK);
        // Ensure bucket limiter has enough capacity and is fully refilled
        etherFiRedemptionManagerInstance.setCapacity(3000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(3000 ether, ETH_ADDRESS);
        vm.stopPrank();
        
        // Warp time forward to ensure bucket is fully refilled
        vm.warp(block.timestamp + 1);

        vm.deal(alice, 100000 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 100000 ether}();

        vm.deal(alice, 2010 ether);
        vm.startPrank(alice);

        liquidityPoolInstance.deposit{value: 2005 ether}();

        uint256 redeemableAmount = etherFiRedemptionManagerInstance.totalRedeemableAmount(ETH_ADDRESS);
        uint256 aliceBalance = address(alice).balance;
        uint256 treasuryBalance = eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury()));

        // Get actual fee configuration from contract
        (, uint16 exitFeeSplitToTreasuryBps, uint16 exitFeeBps, ) = 
            etherFiRedemptionManagerInstance.tokenToRedemptionInfo(ETH_ADDRESS);
        
        // Calculate expected values using shares (more accurate)
        uint256 eEthShares = liquidityPoolInstance.sharesForAmount(2000 ether);
        uint256 expectedAmountToReceiver = liquidityPoolInstance.amountForShare((eEthShares * (10000 - exitFeeBps)) / 10000);
        uint256 eEthShareFee = eEthShares - liquidityPoolInstance.sharesForWithdrawalAmount(expectedAmountToReceiver);
        uint256 expectedTreasuryFee = liquidityPoolInstance.amountForShare((eEthShareFee * exitFeeSplitToTreasuryBps) / 10000);

        eETHInstance.approve(address(etherFiRedemptionManagerInstance), 2000 ether);
        etherFiRedemptionManagerInstance.redeemEEth(2000 ether, alice, ETH_ADDRESS);

        vm.stopPrank();
    }

    function test_Withdraw_EtherFiRedemptionManager_redeemWeEthForETH() public {
        setUp();
        vm.startPrank(OPERATING_TIMELOCK);
        // Ensure bucket limiter has enough capacity and is fully refilled
        etherFiRedemptionManagerInstance.setCapacity(3000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(3000 ether, ETH_ADDRESS);
        vm.stopPrank();
        
        // Warp time forward to ensure bucket is fully refilled
        vm.warp(block.timestamp + 1);

        vm.deal(alice, 100000 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 100000 ether}();

        vm.deal(alice, 2010 ether);
        vm.startPrank(alice);

        liquidityPoolInstance.deposit{value: 2005 ether}();

        // Get actual fee configuration from contract
        (, uint16 exitFeeSplitToTreasuryBps, uint16 exitFeeBps, ) = 
            etherFiRedemptionManagerInstance.tokenToRedemptionInfo(ETH_ADDRESS);
        
        // Calculate expected values using shares (more accurate)
        uint256 expectedAmountToReceiver = liquidityPoolInstance.amountForShare((eEthShares * (10000 - exitFeeBps)) / 10000);
        uint256 eEthShareFee = eEthShares - liquidityPoolInstance.sharesForWithdrawalAmount(expectedAmountToReceiver);

        eETHInstance.approve(address(etherFiRedemptionManagerInstance), 2000 ether);
        etherFiRedemptionManagerInstance.redeemWeEth(2000 ether, alice, ETH_ADDRESS);

        vm.stopPrank();
    }

    // function testFuzz_redeemWeEthForETH(uint256 depositAmount,uint256 redeemAmount,uint16 exitFeeSplitBps,int256 rebase,uint16 exitFeeBps,uint16 lowWatermarkBps) public {
    //     // Bound the parameters
    //     depositAmount = bound(depositAmount, 1 ether, 1000 ether);
    //     redeemAmount = bound(redeemAmount, 0.1 ether, depositAmount);
    //     exitFeeSplitBps = uint16(bound(exitFeeSplitBps, 0, 10000));
    //     exitFeeBps = uint16(bound(exitFeeBps, 0, 10000));
    //     lowWatermarkBps = uint16(bound(lowWatermarkBps, 0, 10000));
    //     rebase = bound(rebase, 0, int128(uint128(depositAmount) / 10));

    //     // Deal Ether to alice and perform deposit
    //     vm.deal(alice, depositAmount);
    //     vm.prank(alice);
    //     liquidityPoolInstance.deposit{value: depositAmount}();

    //     // Set fee and watermark configurations
    //     vm.startPrank(OPERATING_TIMELOCK);
    //     etherFiRedemptionManagerInstance.setExitFeeSplitToTreasuryInBps(uint16(exitFeeSplitBps), ETH_ADDRESS);
    //     etherFiRedemptionManagerInstance.setExitFeeBasisPoints(exitFeeBps, ETH_ADDRESS);
    //     etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(lowWatermarkBps, ETH_ADDRESS);
    //     vm.stopPrank();

    //     // // Apply rebase
    //     // vm.prank(address(membershipManagerV1Instance));
    //     // liquidityPoolInstance.rebase(int128(rebase));

    //     // Convert redeemAmount from ETH to weETH
    //     vm.startPrank(alice);
    //     eETHInstance.approve(address(weEthInstance), redeemAmount);
    //     weEthInstance.wrap(redeemAmount);
    //     uint256 weEthAmount = weEthInstance.balanceOf(alice);

    //     if (etherFiRedemptionManagerInstance.canRedeem(redeemAmount, ETH_ADDRESS)) {
    //         uint256 aliceBalanceBefore = address(alice).balance;
    //         uint256 treasuryBalanceBefore = eETHInstance.balanceOf(address(treasuryInstance));

    //         uint256 eEthAmount = liquidityPoolInstance.amountForShare(weEthAmount);

    //         uint256 alicePrivateKey = 2; // alice = vm.addr(2);
    //         IWeETH.PermitInput memory permit = weEth_createPermitInput(alicePrivateKey, address(etherFiRedemptionManagerInstance), weEthAmount, weEthInstance.nonces(alice), 2**256 - 1, weEthInstance.DOMAIN_SEPARATOR());
    //         etherFiRedemptionManagerInstance.redeemWeEthWithPermit(weEthAmount, alice, permit, ETH_ADDRESS);

    //         uint256 totalFee = (eEthAmount * exitFeeBps) / 10000;
    //         uint256 treasuryFee = (totalFee * exitFeeSplitBps) / 10000;
    //         console2.log("treasuryFee --------", treasuryFee);
    //         uint256 aliceReceives = eEthAmount - totalFee;

    //         //weeth balance of alice
    //         assertApproxEqAbs(
    //             weEthInstance.balanceOf(alice),
    //             0,
    //             1e3
    //         );
    //         assertApproxEqAbs(
    //             eETHInstance.balanceOf(address(treasuryInstance)),
    //             treasuryBalanceBefore + treasuryFee,
    //             1e3
    //         );
    //         assertApproxEqAbs(
    //             address(alice).balance,
    //             aliceBalanceBefore + aliceReceives,
    //             1e3
    //         );

    //     } else {
    //         vm.expectRevert();
    //         etherFiRedemptionManagerInstance.redeemWeEth(weEthAmount, alice, ETH_ADDRESS);
    //     }
    //     vm.stopPrank();
    // }

    // 
}