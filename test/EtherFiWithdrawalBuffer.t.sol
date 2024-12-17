// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "./TestSetup.sol";

contract EtherFiWithdrawalBufferTest is TestSetup {

    address user = vm.addr(999);
    address op_admin = vm.addr(1000);

    function setUp() public {
        setUpTests();

        vm.startPrank(owner);
        etherFiWithdrawalBufferInstance.setCapacity(10 ether);
        etherFiWithdrawalBufferInstance.setRefillRatePerSecond(0.001 ether);
        etherFiWithdrawalBufferInstance.setExitFeeSplitToTreasuryInBps(1e4);
        vm.stopPrank();

        vm.warp(block.timestamp + 5 * 1000); // 0.001 ether * 5000 = 5 ether refilled
    }

    function setUp_Fork() public {
        initializeRealisticFork(MAINNET_FORK);

        vm.startPrank(owner);
        roleRegistry.grantRole(keccak256("PROTOCOL_ADMIN"), op_admin);
        vm.stopPrank();

        etherFiWithdrawalBufferProxy = new UUPSProxy(address(new EtherFiWithdrawalBuffer(address(liquidityPoolInstance), address(eETHInstance), address(weEthInstance), address(treasuryInstance), address(roleRegistry))), "");
        etherFiWithdrawalBufferInstance = EtherFiWithdrawalBuffer(payable(etherFiWithdrawalBufferProxy));
        etherFiWithdrawalBufferInstance.initialize(1e4, 1_00, 10_00); // 10% fee split to treasury, 1% exit fee, 10% low watermark
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

        eETHInstance.approve(address(etherFiWithdrawalBufferInstance), 5 ether);
        vm.expectRevert("EtherFiWithdrawalBuffer: Exceeded total redeemable amount");
        etherFiWithdrawalBufferInstance.redeemEEth(5 ether, user, user);

        vm.stopPrank();
    }

    function test_mainnet_redeem_weEth_with_rebase() public {
        vm.deal(user, 100 ether);

        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: 10 ether}();
        eETHInstance.approve(address(weEthInstance), 10 ether);
        weEthInstance.wrap(10 ether);
        vm.stopPrank();

        uint256 one_percent_of_tvl = liquidityPoolInstance.getTotalPooledEther() / 100;

        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(int128(uint128(one_percent_of_tvl))); // 10 eETH earned 1 ETH

        vm.startPrank(user);
        uint256 userBalance = address(user).balance;
        uint256 treasuryBalance = eETHInstance.balanceOf(address(treasuryInstance));
        weEthInstance.approve(address(etherFiWithdrawalBufferInstance), 1 ether);
        etherFiWithdrawalBufferInstance.redeemWeEth(1 ether, user, user);
        assertEq(eETHInstance.balanceOf(address(treasuryInstance)), treasuryBalance + 0.0101 ether);
        assertEq(address(user).balance, userBalance + 0.9999 ether);
        vm.stopPrank();
    }

    function test_redeem_weEth_1() public {
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

        eETHInstance.approve(address(weEthInstance), 6 ether);
        weEthInstance.wrap(6 ether);
        weEthInstance.approve(address(etherFiWithdrawalBufferInstance), 5 ether);
        vm.expectRevert("EtherFiWithdrawalBuffer: Exceeded total redeemable amount");
        etherFiWithdrawalBufferInstance.redeemWeEth(5 ether, user, user);

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

    // The test ensures that:
    // - Redemption works correctly within allowed limits.
    // - Fees are applied accurately.
    // - The function properly reverts when redemption conditions aren't met.
    function testFuzz_redeemEEth(
        uint256 depositAmount,
        uint256 redeemAmount,
        uint256 exitFeeSplitBps,
        uint16 exitFeeBps,
        uint16 lowWatermarkBps
    ) public {
        depositAmount = bound(depositAmount, 1 ether, 1000 ether);
        redeemAmount = bound(redeemAmount, 0.1 ether, depositAmount);
        exitFeeSplitBps = bound(exitFeeSplitBps, 0, 10000);
        exitFeeBps = uint16(bound(uint256(exitFeeBps), 0, 10000));
        lowWatermarkBps = uint16(bound(uint256(lowWatermarkBps), 0, 10000));

        vm.deal(user, depositAmount);
        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: depositAmount}();
        vm.stopPrank();

        // Set exitFeeSplitToTreasuryInBps
        vm.prank(owner);
        etherFiWithdrawalBufferInstance.setExitFeeSplitToTreasuryInBps(uint16(exitFeeSplitBps));

        // Set exitFeeBasisPoints and lowWatermarkInBpsOfTvl
        vm.prank(owner);
        etherFiWithdrawalBufferInstance.setExitFeeBasisPoints(exitFeeBps);

        vm.prank(owner);
        etherFiWithdrawalBufferInstance.setLowWatermarkInBpsOfTvl(lowWatermarkBps);

        vm.startPrank(user);
        eETHInstance.approve(address(etherFiWithdrawalBufferInstance), redeemAmount);
        uint256 totalRedeemableAmount = etherFiWithdrawalBufferInstance.totalRedeemableAmount();

        if (redeemAmount <= totalRedeemableAmount && etherFiWithdrawalBufferInstance.canRedeem(redeemAmount)) {
            uint256 userBalanceBefore = address(user).balance;
            uint256 treasuryBalanceBefore = eETHInstance.balanceOf(address(treasuryInstance));

            etherFiWithdrawalBufferInstance.redeemEEth(redeemAmount, user, user);

            uint256 totalFee = (redeemAmount * exitFeeBps) / 10000;
            uint256 treasuryFee = (totalFee * exitFeeSplitBps) / 10000;
            uint256 userReceives = redeemAmount - totalFee;

            assertApproxEqAbs(
                eETHInstance.balanceOf(address(treasuryInstance)),
                treasuryBalanceBefore + treasuryFee,
                1e1
            );
            assertApproxEqAbs(
                address(user).balance,
                userBalanceBefore + userReceives,
                1e1
            );

        } else {
            vm.expectRevert();
            etherFiWithdrawalBufferInstance.redeemEEth(redeemAmount, user, user);
        }
        vm.stopPrank();
    }

    function testFuzz_redeemWeEth(
        uint256 depositAmount,
        uint256 redeemAmount,
        uint256 exitFeeSplitBps,
        uint16 exitFeeBps,
        uint16 lowWatermarkBps
    ) public {
        // Bound the parameters
        depositAmount = bound(depositAmount, 1 ether, 1000 ether);
        redeemAmount = bound(redeemAmount, 0.1 ether, depositAmount);
        exitFeeSplitBps = bound(exitFeeSplitBps, 0, 10000);
        exitFeeBps = uint16(bound(uint256(exitFeeBps), 0, 10000));
        lowWatermarkBps = uint16(bound(uint256(lowWatermarkBps), 0, 10000));

        // Deal Ether to user and perform deposit
        vm.deal(user, depositAmount);
        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: depositAmount}();
        vm.stopPrank();

        // Set fee and watermark configurations
        vm.prank(owner);
        etherFiWithdrawalBufferInstance.setExitFeeSplitToTreasuryInBps(uint16(exitFeeSplitBps));

        vm.prank(owner);
        etherFiWithdrawalBufferInstance.setExitFeeBasisPoints(exitFeeBps);

        vm.prank(owner);
        etherFiWithdrawalBufferInstance.setLowWatermarkInBpsOfTvl(lowWatermarkBps);

        // User approves weETH and attempts redemption
        vm.startPrank(user);
        weEthInstance.approve(address(etherFiWithdrawalBufferInstance), redeemAmount);
        uint256 totalRedeemableAmount = etherFiWithdrawalBufferInstance.totalRedeemableAmount();

        if (redeemAmount <= totalRedeemableAmount && etherFiWithdrawalBufferInstance.canRedeem(redeemAmount)) {
            uint256 userBalanceBefore = address(user).balance;
            uint256 treasuryBalanceBefore = eETHInstance.balanceOf(address(treasuryInstance));

            etherFiWithdrawalBufferInstance.redeemWeEth(redeemAmount, user, user);

            uint256 totalFee = (redeemAmount * exitFeeBps) / 10000;
            uint256 treasuryFee = (totalFee * exitFeeSplitBps) / 10000;
            uint256 userReceives = redeemAmount - totalFee;

            assertApproxEqAbs(
                eETHInstance.balanceOf(address(treasuryInstance)),
                treasuryBalanceBefore + treasuryFee,
                1e1
            );
            assertApproxEqAbs(
                address(user).balance,
                userBalanceBefore + userReceives,
                1e1
            );

        } else {
            vm.expectRevert();
            etherFiWithdrawalBufferInstance.redeemWeEth(redeemAmount, user, user);
        }
        vm.stopPrank();
    }

    function testFuzz_role_management(address admin, address pauser, address unpauser, address user) public {
        address owner = roleRegistry.owner();
        bytes32 PROTOCOL_ADMIN = keccak256("PROTOCOL_ADMIN");
        bytes32 PROTOCOL_PAUSER = keccak256("PROTOCOL_PAUSER");
        bytes32 PROTOCOL_UNPAUSER = keccak256("PROTOCOL_UNPAUSER");

        vm.assume(admin != address(0) && admin != owner);
        vm.assume(pauser != address(0) && pauser != owner && pauser != admin);
        vm.assume(unpauser != address(0) && unpauser != owner && unpauser != admin && unpauser != pauser);
        vm.assume(user != address(0) && user != owner && user != admin && user != pauser && user != unpauser);

        // Grant roles to respective addresses
        vm.prank(owner);
        roleRegistry.grantRole(PROTOCOL_ADMIN, admin);
        vm.prank(owner);
        roleRegistry.grantRole(PROTOCOL_PAUSER, pauser);
        vm.prank(owner);
        roleRegistry.grantRole(PROTOCOL_UNPAUSER, unpauser);

        // Admin performs admin-only actions
        vm.startPrank(admin);
        etherFiWithdrawalBufferInstance.setCapacity(10 ether);
        etherFiWithdrawalBufferInstance.setRefillRatePerSecond(0.001 ether);
        etherFiWithdrawalBufferInstance.setExitFeeSplitToTreasuryInBps(1e4);
        etherFiWithdrawalBufferInstance.setLowWatermarkInBpsOfTvl(1e2);
        etherFiWithdrawalBufferInstance.setExitFeeBasisPoints(1e2);
        vm.stopPrank();

        // Pauser pauses the contract
        vm.startPrank(pauser);
        etherFiWithdrawalBufferInstance.pauseContract();
        assertTrue(etherFiWithdrawalBufferInstance.paused());
        vm.stopPrank();

        // Unpauser unpauses the contract
        vm.startPrank(unpauser);
        etherFiWithdrawalBufferInstance.unPauseContract();
        assertFalse(etherFiWithdrawalBufferInstance.paused());
        vm.stopPrank();

        // Revoke PROTOCOL_ADMIN role from admin
        vm.prank(owner);
        roleRegistry.revokeRole(PROTOCOL_ADMIN, admin);

        // Admin attempts admin-only actions after role revocation
        vm.startPrank(admin);
        vm.expectRevert("EtherFiWithdrawalBuffer: Unauthorized");
        etherFiWithdrawalBufferInstance.setCapacity(10 ether);
        vm.stopPrank();

        // Pauser attempts to unpause (should fail)
        vm.startPrank(pauser);
        vm.expectRevert("EtherFiWithdrawalBuffer: Unauthorized");
        etherFiWithdrawalBufferInstance.unPauseContract();
        vm.stopPrank();

        // Unpauser attempts to pause (should fail)
        vm.startPrank(unpauser);
        vm.expectRevert("EtherFiWithdrawalBuffer: Unauthorized");
        etherFiWithdrawalBufferInstance.pauseContract();
        vm.stopPrank();

        // User without role attempts admin-only actions
        vm.startPrank(user);
        vm.expectRevert("EtherFiWithdrawalBuffer: Unauthorized");
        etherFiWithdrawalBufferInstance.pauseContract();
        vm.expectRevert("EtherFiWithdrawalBuffer: Unauthorized");
        etherFiWithdrawalBufferInstance.unPauseContract();
        vm.stopPrank();
    }

    function test_mainnet_redeem_eEth() public {
        vm.deal(user, 100 ether);
        vm.startPrank(user);

        assertEq(etherFiWithdrawalBufferInstance.canRedeem(1 ether), true);
        assertEq(etherFiWithdrawalBufferInstance.canRedeem(10 ether), false);

        liquidityPoolInstance.deposit{value: 1 ether}();

        uint256 userBalance = address(user).balance;
        uint256 treasuryBalance = eETHInstance.balanceOf(address(etherFiWithdrawalBufferInstance.treasury()));

        eETHInstance.approve(address(etherFiWithdrawalBufferInstance), 1 ether);
        etherFiWithdrawalBufferInstance.redeemEEth(1 ether, user, user);

        assertEq(eETHInstance.balanceOf(address(etherFiWithdrawalBufferInstance.treasury())), treasuryBalance + 0.01 ether);
        assertEq(address(user).balance, userBalance + 0.99 ether);

        eETHInstance.approve(address(etherFiWithdrawalBufferInstance), 5 ether);
        vm.expectRevert("EtherFiWithdrawalBuffer: Exceeded total redeemable amount");
        etherFiWithdrawalBufferInstance.redeemEEth(5 ether, user, user);

        vm.stopPrank();
    }
}
