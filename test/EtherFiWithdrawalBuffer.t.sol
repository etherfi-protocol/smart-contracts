// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "./TestSetup.sol";

contract EtherFiWithdrawalBufferTest is TestSetup {

    address user = vm.addr(999);

    function setUp() public {
        setUpTests();

        vm.startPrank(owner);
        etherFiWithdrawalBufferInstance.setCapacity(10 ether);
        etherFiWithdrawalBufferInstance.setRefillRatePerSecond(0.001 ether);
        etherFiWithdrawalBufferInstance.setExitFeeSplitToTreasuryInBps(1e4);
        vm.stopPrank();

        vm.warp(block.timestamp + 5 * 1000); // 0.001 ether * 5000 = 5 ether refilled


    }

    function test_rate_limit() public {
        assertEq(etherFiWithdrawalBufferInstance.canRedeem(1 ether), true);
        assertEq(etherFiWithdrawalBufferInstance.canRedeem(5 ether - 1), true);
        assertEq(etherFiWithdrawalBufferInstance.canRedeem(5 ether + 1), false);
        assertEq(etherFiWithdrawalBufferInstance.canRedeem(10 ether), false);
        assertEq(etherFiWithdrawalBufferInstance.totalRedeemableAmount(), 5 ether);
    }

    function test_lowwatermark_guardrail() public {
        vm.deal(user, 100 ether);
        
        assertEq(etherFiWithdrawalBufferInstance.lowWatermarkInETH(), 0 ether);

        vm.prank(user);
        liquidityPoolInstance.deposit{value: 100 ether}();

        vm.startPrank(etherFiWithdrawalBufferInstance.owner());
        etherFiWithdrawalBufferInstance.setLowWatermarkInBpsOfTvl(1_00); // 1%
        assertEq(etherFiWithdrawalBufferInstance.lowWatermarkInETH(), 1 ether);

        etherFiWithdrawalBufferInstance.setLowWatermarkInBpsOfTvl(50_00); // 50%
        assertEq(etherFiWithdrawalBufferInstance.lowWatermarkInETH(), 50 ether);

        etherFiWithdrawalBufferInstance.setLowWatermarkInBpsOfTvl(100_00); // 100%
        assertEq(etherFiWithdrawalBufferInstance.lowWatermarkInETH(), 100 ether);
    }

    function test_redeem_eEth() public {
        vm.deal(user, 100 ether);
        vm.startPrank(user);

        assertEq(etherFiWithdrawalBufferInstance.canRedeem(1 ether), true);
        assertEq(etherFiWithdrawalBufferInstance.canRedeem(10 ether), false);

        liquidityPoolInstance.deposit{value: 1 ether}();

        eETHInstance.approve(address(etherFiWithdrawalBufferInstance), 0.5 ether);
        vm.expectRevert("TRANSFER_AMOUNT_EXCEEDS_ALLOWANCE");
        etherFiWithdrawalBufferInstance.redeemEEth(1 ether, user, user);

        eETHInstance.approve(address(etherFiWithdrawalBufferInstance), 2 ether);
        vm.expectRevert("EtherFiWithdrawalBuffer: Insufficient balance");
        etherFiWithdrawalBufferInstance.redeemEEth(2 ether, user, user);

        liquidityPoolInstance.deposit{value: 10 ether}();

        uint256 totalRedeemableAmount = etherFiWithdrawalBufferInstance.totalRedeemableAmount();
        uint256 userBalance = address(user).balance;
        uint256 treasuryBalance = eETHInstance.balanceOf(address(treasuryInstance));
        eETHInstance.approve(address(etherFiWithdrawalBufferInstance), 1 ether);
        etherFiWithdrawalBufferInstance.redeemEEth(1 ether, user, user);
        assertEq(eETHInstance.balanceOf(address(treasuryInstance)), treasuryBalance + 0.01 ether);
        assertEq(address(user).balance, userBalance + 0.99 ether);
        assertEq(etherFiWithdrawalBufferInstance.totalRedeemableAmount(), totalRedeemableAmount - 1 ether);

        eETHInstance.approve(address(etherFiWithdrawalBufferInstance), 10 ether);
        vm.expectRevert("EtherFiWithdrawalBuffer: Exceeded total redeemable amount");
        etherFiWithdrawalBufferInstance.redeemEEth(10 ether, user, user);

        vm.stopPrank();
    }

    function test_redeem_weEth() public {
        vm.deal(user, 100 ether);
        vm.startPrank(user);

        assertEq(etherFiWithdrawalBufferInstance.canRedeem(1 ether), true);
        assertEq(etherFiWithdrawalBufferInstance.canRedeem(10 ether), false);

        liquidityPoolInstance.deposit{value: 1 ether}();
        eETHInstance.approve(address(weEthInstance), 1 ether);
        weEthInstance.wrap(1 ether);

        weEthInstance.approve(address(etherFiWithdrawalBufferInstance), 0.5 ether);
        vm.expectRevert("ERC20: insufficient allowance");
        etherFiWithdrawalBufferInstance.redeemWeEth(1 ether, user, user);

        weEthInstance.approve(address(etherFiWithdrawalBufferInstance), 2 ether);
        vm.expectRevert("EtherFiWithdrawalBuffer: Insufficient balance");
        etherFiWithdrawalBufferInstance.redeemWeEth(2 ether, user, user);

        liquidityPoolInstance.deposit{value: 10 ether}();

        uint256 totalRedeemableAmount = etherFiWithdrawalBufferInstance.totalRedeemableAmount();
        uint256 userBalance = address(user).balance;
        uint256 treasuryBalance = eETHInstance.balanceOf(address(treasuryInstance));
        weEthInstance.approve(address(etherFiWithdrawalBufferInstance), 1 ether);
        etherFiWithdrawalBufferInstance.redeemWeEth(1 ether, user, user);
        assertEq(eETHInstance.balanceOf(address(treasuryInstance)), treasuryBalance + 0.01 ether);
        assertEq(address(user).balance, userBalance + 0.99 ether);
        assertEq(etherFiWithdrawalBufferInstance.totalRedeemableAmount(), totalRedeemableAmount - 1 ether);

        weEthInstance.approve(address(etherFiWithdrawalBufferInstance), 10 ether);
        vm.expectRevert("EtherFiWithdrawalBuffer: Exceeded total redeemable amount");
        etherFiWithdrawalBufferInstance.redeemWeEth(10 ether, user, user);

        vm.stopPrank();
    }

    function test_redeem_weEth_with_varying_exchange_rate() public {
        vm.deal(user, 100 ether);
        
        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: 10 ether}();
        eETHInstance.approve(address(weEthInstance), 1 ether);
        weEthInstance.wrap(1 ether);
        vm.stopPrank();

        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(1 ether); // 10 eETH earned 1 ETH

        vm.startPrank(user);
        uint256 userBalance = address(user).balance;
        uint256 treasuryBalance = eETHInstance.balanceOf(address(treasuryInstance));
        weEthInstance.approve(address(etherFiWithdrawalBufferInstance), 1 ether);
        etherFiWithdrawalBufferInstance.redeemWeEth(1 ether, user, user);
        assertEq(eETHInstance.balanceOf(address(treasuryInstance)), treasuryBalance + 0.011 ether);
        assertEq(address(user).balance, userBalance + (1.1 ether - 0.011 ether));
        vm.stopPrank();
    }
}
