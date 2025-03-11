// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "./TestSetup.sol";

contract EtherFiRedemptionManagerTest is TestSetup {

    address user = vm.addr(999);
    address op_admin = vm.addr(1000);

    function setUp() public {
        setUpTests();
    }

    function setUp_Fork() public {
        setUpTests();
        initializeRealisticFork(MAINNET_FORK);

        vm.startPrank(roleRegistryInstance.owner());
        roleRegistryInstance.grantRole(keccak256("PROTOCOL_ADMIN"), op_admin);
        vm.stopPrank();

    }

    function test_upgrade_only_by_owner() public {
        setUp_Fork();

        address impl = etherFiRedemptionManagerInstance.getImplementation();
        vm.prank(chad);
        vm.expectRevert();
        etherFiRedemptionManagerInstance.upgradeTo(impl);

        vm.prank(admin);
        etherFiRedemptionManagerInstance.upgradeTo(impl);
    }

    function test_rate_limit() public {
        vm.deal(user, 1000 ether);
        vm.prank(user);
        liquidityPoolInstance.deposit{value: 1000 ether}();

        assertEq(etherFiRedemptionManagerInstance.canRedeem(1 ether), true);
        assertEq(etherFiRedemptionManagerInstance.canRedeem(5 ether - 1), true);
        assertEq(etherFiRedemptionManagerInstance.canRedeem(5 ether + 1), false);
        assertEq(etherFiRedemptionManagerInstance.canRedeem(10 ether), false);
        assertEq(etherFiRedemptionManagerInstance.totalRedeemableAmount(), 5 ether);
    }

    function test_lowwatermark_guardrail() public {
        vm.deal(user, 100 ether);
        
        assertEq(etherFiRedemptionManagerInstance.lowWatermarkInETH(), 0 ether);

        vm.prank(user);
        liquidityPoolInstance.deposit{value: 100 ether}();

        vm.startPrank(owner);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(1_00); // 1%
        assertEq(etherFiRedemptionManagerInstance.lowWatermarkInETH(), 1 ether);

        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(50_00); // 50%
        assertEq(etherFiRedemptionManagerInstance.lowWatermarkInETH(), 50 ether);

        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(100_00); // 100%
        assertEq(etherFiRedemptionManagerInstance.lowWatermarkInETH(), 100 ether);

        vm.expectRevert("INVALID");
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(100_01); // 100.01%
    }

    function test_admin_permission() public {
        vm.startPrank(alice);
        vm.expectRevert();
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(1_00); // 1%
        vm.expectRevert();
        etherFiRedemptionManagerInstance.setExitFeeSplitToTreasuryInBps(1_000); // 10%
        vm.expectRevert();
        etherFiRedemptionManagerInstance.setExitFeeBasisPoints(40); // 0.4%
        vm.expectRevert();
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(1_00); // 1%
        vm.expectRevert();
        etherFiRedemptionManagerInstance.setCapacity(1_00); // 1%
        vm.expectRevert();
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(1_00); // 1%
        vm.stopPrank();
    }

    function testFuzz_redeemEEth(
        uint256 depositAmount,
        uint256 redeemAmount,
        uint256 exitFeeSplitBps,
        uint16 exitFeeBps,
        uint16 lowWatermarkBps
    ) public {
        
        vm.assume(depositAmount >= redeemAmount);
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
        etherFiRedemptionManagerInstance.setExitFeeSplitToTreasuryInBps(uint16(exitFeeSplitBps));

        // Set exitFeeBasisPoints and lowWatermarkInBpsOfTvl
        vm.prank(owner);
        etherFiRedemptionManagerInstance.setExitFeeBasisPoints(exitFeeBps);

        vm.prank(owner);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(lowWatermarkBps);

        vm.startPrank(user);
        if (etherFiRedemptionManagerInstance.canRedeem(redeemAmount)) {
            uint256 userBalanceBefore = address(user).balance;
            uint256 treasuryBalanceBefore = eETHInstance.balanceOf(address(treasuryInstance));
            
            IeETH.PermitInput memory permit = eEth_createPermitInput(999, address(etherFiRedemptionManagerInstance), redeemAmount, eETHInstance.nonces(user), 2**256 - 1, eETHInstance.DOMAIN_SEPARATOR());
            etherFiRedemptionManagerInstance.redeemEEthWithPermit(redeemAmount, user, permit);

            uint256 totalFee = (redeemAmount * exitFeeBps) / 10000;
            uint256 treasuryFee = (totalFee * exitFeeSplitBps) / 10000;
            uint256 userReceives = redeemAmount - totalFee;

            assertApproxEqAbs(
                eETHInstance.balanceOf(address(treasuryInstance)),
                treasuryBalanceBefore + treasuryFee,
                1e2
            );
            assertApproxEqAbs(
                address(user).balance,
                userBalanceBefore + userReceives,
                1e2
            );

        } else {
            vm.expectRevert();
            etherFiRedemptionManagerInstance.redeemEEth(redeemAmount, user);
        }
        vm.stopPrank();
    }

    function testFuzz_redeemWeEth(
        uint256 depositAmount,
        uint256 redeemAmount,
        uint16 exitFeeSplitBps,
        int256 rebase,
        uint16 exitFeeBps,
        uint16 lowWatermarkBps
    ) public {
        // Bound the parameters
        depositAmount = bound(depositAmount, 1 ether, 1000 ether);
        console2.log(depositAmount);
        redeemAmount = bound(redeemAmount, 0.1 ether, depositAmount);
        exitFeeSplitBps = uint16(bound(exitFeeSplitBps, 0, 10000));
        exitFeeBps = uint16(bound(exitFeeBps, 0, 10000));
        lowWatermarkBps = uint16(bound(lowWatermarkBps, 0, 10000));
        rebase = bound(rebase, 0, int128(uint128(depositAmount) / 10));

        // Deal Ether to user and perform deposit
        vm.deal(user, depositAmount);
        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: depositAmount}();
        vm.stopPrank();

        // Apply rebase
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(int128(rebase));

        // Set fee and watermark configurations
        vm.prank(owner);
        etherFiRedemptionManagerInstance.setExitFeeSplitToTreasuryInBps(uint16(exitFeeSplitBps));

        vm.prank(owner);
        etherFiRedemptionManagerInstance.setExitFeeBasisPoints(exitFeeBps);

        vm.prank(owner);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(lowWatermarkBps);

        // Convert redeemAmount from ETH to weETH
        vm.startPrank(user);
        eETHInstance.approve(address(weEthInstance), redeemAmount);
        weEthInstance.wrap(redeemAmount);
        uint256 weEthAmount = weEthInstance.balanceOf(user);

        if (etherFiRedemptionManagerInstance.canRedeem(redeemAmount)) {
            uint256 userBalanceBefore = address(user).balance;
            uint256 treasuryBalanceBefore = eETHInstance.balanceOf(address(treasuryInstance));

            uint256 eEthAmount = liquidityPoolInstance.amountForShare(weEthAmount);

            IWeETH.PermitInput memory permit = weEth_createPermitInput(999, address(etherFiRedemptionManagerInstance), weEthAmount, weEthInstance.nonces(user), 2**256 - 1, weEthInstance.DOMAIN_SEPARATOR());
            etherFiRedemptionManagerInstance.redeemWeEthWithPermit(weEthAmount, user, permit);

            uint256 totalFee = (eEthAmount * exitFeeBps) / 10000;
            uint256 treasuryFee = (totalFee * exitFeeSplitBps) / 10000;
            uint256 userReceives = eEthAmount - totalFee;

            assertApproxEqAbs(
                eETHInstance.balanceOf(address(treasuryInstance)),
                treasuryBalanceBefore + treasuryFee,
                1e2
            );
            assertApproxEqAbs(
                address(user).balance,
                userBalanceBefore + userReceives,
                1e2
            );

        } else {
            vm.expectRevert();
            etherFiRedemptionManagerInstance.redeemWeEth(weEthAmount, user);
        }
        vm.stopPrank();
    }

    function testFuzz_role_management(address admin, address pauser, address unpauser, address user) public {
        address owner = roleRegistryInstance.owner();
        bytes32 PROTOCOL_ADMIN = keccak256("PROTOCOL_ADMIN");
        bytes32 PROTOCOL_PAUSER = keccak256("PROTOCOL_PAUSER");
        bytes32 PROTOCOL_UNPAUSER = keccak256("PROTOCOL_UNPAUSER");

        vm.assume(admin != address(0) && admin != owner);
        vm.assume(pauser != address(0) && pauser != owner && pauser != admin);
        vm.assume(unpauser != address(0) && unpauser != owner && unpauser != admin && unpauser != pauser);
        vm.assume(user != address(0) && user != owner && user != admin && user != pauser && user != unpauser);

        // Grant roles to respective addresses
        vm.prank(owner);
        roleRegistryInstance.grantRole(PROTOCOL_ADMIN, admin);
        vm.prank(owner);
        roleRegistryInstance.grantRole(PROTOCOL_PAUSER, pauser);
        vm.prank(owner);
        roleRegistryInstance.grantRole(PROTOCOL_UNPAUSER, unpauser);

        // Admin performs admin-only actions
        vm.startPrank(admin);
        etherFiRedemptionManagerInstance.setCapacity(10 ether);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(0.001 ether);
        etherFiRedemptionManagerInstance.setExitFeeSplitToTreasuryInBps(1e4);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(1e2);
        etherFiRedemptionManagerInstance.setExitFeeBasisPoints(1e2);
        vm.stopPrank();

        // Pauser pauses the contract
        vm.startPrank(pauser);
        etherFiRedemptionManagerInstance.pauseContract();
        assertTrue(etherFiRedemptionManagerInstance.paused());
        vm.stopPrank();

        // Unpauser unpauses the contract
        vm.startPrank(unpauser);
        etherFiRedemptionManagerInstance.unPauseContract();
        assertFalse(etherFiRedemptionManagerInstance.paused());
        vm.stopPrank();

        // Revoke PROTOCOL_ADMIN role from admin
        vm.prank(owner);
        roleRegistryInstance.revokeRole(PROTOCOL_ADMIN, admin);

        // Admin attempts admin-only actions after role revocation
        vm.startPrank(admin);
        vm.expectRevert("EtherFiRedemptionManager: Unauthorized");
        etherFiRedemptionManagerInstance.setCapacity(10 ether);
        vm.stopPrank();

        // Pauser attempts to unpause (should fail)
        vm.startPrank(pauser);
        vm.expectRevert("EtherFiRedemptionManager: Unauthorized");
        etherFiRedemptionManagerInstance.unPauseContract();
        vm.stopPrank();

        // Unpauser attempts to pause (should fail)
        vm.startPrank(unpauser);
        vm.expectRevert("EtherFiRedemptionManager: Unauthorized");
        etherFiRedemptionManagerInstance.pauseContract();
        vm.stopPrank();

        // User without role attempts admin-only actions
        vm.startPrank(user);
        vm.expectRevert("EtherFiRedemptionManager: Unauthorized");
        etherFiRedemptionManagerInstance.pauseContract();
        vm.expectRevert("EtherFiRedemptionManager: Unauthorized");
        etherFiRedemptionManagerInstance.unPauseContract();
        vm.stopPrank();
    }

    function test_mainnet_redeem_eEth() public {
        setUp_Fork();

        vm.deal(alice, 100000 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 100000 ether}();

        vm.deal(user, 100 ether);
        vm.startPrank(user);

        liquidityPoolInstance.deposit{value: 10 ether}();

        uint256 redeemableAmount = etherFiRedemptionManagerInstance.totalRedeemableAmount();
        uint256 userBalance = address(user).balance;
        uint256 treasuryBalance = eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury()));

        eETHInstance.approve(address(etherFiRedemptionManagerInstance), 1 ether);
        etherFiRedemptionManagerInstance.redeemEEth(1 ether, user);

        uint256 totalFee = (1 ether * 1e2) / 1e4;
        uint256 treasuryFee = (totalFee * 1e3) / 1e4;
        uint256 userReceives = 1 ether - totalFee;

        assertApproxEqAbs(eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury())), treasuryBalance + treasuryFee, 1e1);
        assertApproxEqAbs(address(user).balance, userBalance + userReceives, 1e1);

        eETHInstance.approve(address(etherFiRedemptionManagerInstance), 5 ether);
        vm.expectRevert("EtherFiRedemptionManager: Exceeded total redeemable amount");
        etherFiRedemptionManagerInstance.redeemEEth(5 ether, user);

        vm.stopPrank();
    }

    function test_mainnet_redeem_weEth_with_rebase() public {
        setUp_Fork();

        vm.deal(alice, 50000 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 50000 ether}();

        vm.deal(user, 100 ether);

        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: 10 ether}();
        eETHInstance.approve(address(weEthInstance), 10 ether);
        weEthInstance.wrap(1 ether);
        vm.stopPrank();

        uint256 one_percent_of_tvl = liquidityPoolInstance.getTotalPooledEther() / 100;

        vm.prank(address(membershipManagerV1Instance));
        liquidityPoolInstance.rebase(int128(uint128(one_percent_of_tvl))); // 10 eETH earned 1 ETH

        vm.startPrank(user);
        uint256 weEthAmount = weEthInstance.balanceOf(user);
        uint256 eEthAmount = liquidityPoolInstance.amountForShare(weEthAmount);
        uint256 userBalance = address(user).balance;
        uint256 treasuryBalance = eETHInstance.balanceOf(address(treasuryInstance));
        weEthInstance.approve(address(etherFiRedemptionManagerInstance), 1 ether);
        etherFiRedemptionManagerInstance.redeemWeEth(weEthAmount, user);
        
        uint256 totalFee = (eEthAmount * 1e2) / 1e4;
        uint256 treasuryFee = (totalFee * 1e3) / 1e4;
        uint256 userReceives = eEthAmount - totalFee;
        
        assertApproxEqAbs(eETHInstance.balanceOf(address(treasuryInstance)), treasuryBalance + treasuryFee, 1e1);
        assertApproxEqAbs(address(user).balance, userBalance + userReceives, 1e1);

        vm.stopPrank();
    }

    function test_mainnet_redeem_beyond_liquidity_fails() public {
        setUp_Fork();

        uint256 redeemAmount = liquidityPoolInstance.getTotalPooledEther() / 2;
        vm.prank(address(liquidityPoolInstance));
        eETHInstance.mintShares(user, 2 * redeemAmount);

        vm.startPrank(op_admin);
        etherFiRedemptionManagerInstance.setCapacity(2 * redeemAmount);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(2 * redeemAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        vm.startPrank(user);

        uint256 userBalance = address(user).balance;
        uint256 treasuryBalance = eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury()));

        eETHInstance.approve(address(etherFiRedemptionManagerInstance), redeemAmount);
        vm.expectRevert("EtherFiRedemptionManager: Exceeded total redeemable amount");
        etherFiRedemptionManagerInstance.redeemEEth(redeemAmount, user);

        vm.stopPrank();
    }
}
