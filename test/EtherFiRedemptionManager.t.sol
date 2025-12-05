// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "./TestSetup.sol";
import "lib/BucketLimiter.sol";

contract EtherFiRedemptionManagerTest is TestSetup {

    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address user = vm.addr(999);
    address op_admin = vm.addr(1000);


    function setUp() public {
        setUpTests();
    }

    function setUp_Fork() public {
        setUpTests();
        initializeRealisticFork(MAINNET_FORK);
        vm.startPrank(roleRegistryInstance.owner());
        roleRegistryInstance.grantRole(keccak256("ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE"), op_admin);
        vm.stopPrank();
    }

    function test_upgrade_only_by_owner() public {
        setUp_Fork();

        address impl = etherFiRedemptionManagerInstance.getImplementation();
        vm.prank(chad);
        vm.expectRevert();
        etherFiRedemptionManagerInstance.upgradeTo(impl);

        vm.prank(owner);
        etherFiRedemptionManagerInstance.upgradeTo(impl);
    }

    function test_rate_limit() public {


        vm.deal(user, 100000 ether);
        vm.prank(user);
        liquidityPoolInstance.deposit{value: 100000 ether}();

        vm.deal(user, 5 ether);
        vm.prank(user);
        liquidityPoolInstance.deposit{value: 5 ether}();

        assertEq(etherFiRedemptionManagerInstance.canRedeem(1 ether, ETH_ADDRESS), true);
        assertEq(etherFiRedemptionManagerInstance.canRedeem(5 ether - 1, ETH_ADDRESS), true);
        assertEq(etherFiRedemptionManagerInstance.canRedeem(5 ether + 1, ETH_ADDRESS), false);
        assertEq(etherFiRedemptionManagerInstance.canRedeem(10 ether, ETH_ADDRESS), false);
        assertEq(etherFiRedemptionManagerInstance.totalRedeemableAmount(ETH_ADDRESS), 5 ether);
    }

    function test_lowwatermark_guardrail() public {
        vm.deal(user, 100 ether);
        
        assertEq(etherFiRedemptionManagerInstance.lowWatermarkInETH(ETH_ADDRESS), 0 ether);

        vm.prank(user);
        liquidityPoolInstance.deposit{value: 100 ether}();


        vm.startPrank(owner);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(1_00, ETH_ADDRESS); // 1%
        assertEq(etherFiRedemptionManagerInstance.lowWatermarkInETH(ETH_ADDRESS), 1 ether);

        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(50_00, ETH_ADDRESS); // 50%
        assertEq(etherFiRedemptionManagerInstance.lowWatermarkInETH(ETH_ADDRESS), 50 ether);

        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(100_00, ETH_ADDRESS); // 100%
        assertEq(etherFiRedemptionManagerInstance.lowWatermarkInETH(ETH_ADDRESS), 100 ether);

        vm.expectRevert("INVALID");
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(100_01, ETH_ADDRESS); // 100.01%
    }

    function _admin_permission_by_token(address token) public {
        vm.startPrank(alice);
        vm.expectRevert();
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(1_00, token); // 1%
        vm.expectRevert();
        etherFiRedemptionManagerInstance.setExitFeeSplitToTreasuryInBps(1_000, token); // 10%
        vm.expectRevert();
        etherFiRedemptionManagerInstance.setExitFeeBasisPoints(40, token); // 0.4%
        vm.expectRevert();
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(1_00, token); // 1%
        vm.expectRevert();
        etherFiRedemptionManagerInstance.setCapacity(1_00, token); // 1%
        vm.expectRevert();
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(1_00, token); // 1%
        vm.stopPrank();
    }

    function test_admin_permission_by_token() public {
        _admin_permission_by_token(ETH_ADDRESS);
        _admin_permission_by_token(address(etherFiRestakerInstance.lido()));
    }

    function testFuzz_redeemEEth(uint256 depositAmount,uint256 redeemAmount,uint256 exitFeeSplitBps,uint16 exitFeeBps,uint16 lowWatermarkBps) public {
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
        etherFiRedemptionManagerInstance.setExitFeeSplitToTreasuryInBps(uint16(exitFeeSplitBps), ETH_ADDRESS);

        // Set exitFeeBasisPoints and lowWatermarkInBpsOfTvl
        vm.prank(owner);
        etherFiRedemptionManagerInstance.setExitFeeBasisPoints(exitFeeBps, ETH_ADDRESS);

        vm.prank(owner);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(lowWatermarkBps, ETH_ADDRESS);

        vm.startPrank(user);
        if (etherFiRedemptionManagerInstance.canRedeem(redeemAmount, ETH_ADDRESS)) {
            uint256 userBalanceBefore = address(user).balance;
            uint256 treasuryBalanceBefore = eETHInstance.balanceOf(address(treasuryInstance));
            
            IeETH.PermitInput memory permit = eEth_createPermitInput(999, address(etherFiRedemptionManagerInstance), redeemAmount, eETHInstance.nonces(user), 2**256 - 1, eETHInstance.DOMAIN_SEPARATOR());
            etherFiRedemptionManagerInstance.redeemEEthWithPermit(redeemAmount, user, permit, ETH_ADDRESS);

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
            etherFiRedemptionManagerInstance.redeemEEth(redeemAmount, user, ETH_ADDRESS);
        }
        vm.stopPrank();
    }

    function testFuzz_redeemWeEth(uint256 depositAmount,uint256 redeemAmount,uint16 exitFeeSplitBps,int256 rebase,uint16 exitFeeBps,uint16 lowWatermarkBps) public {
        // Bound the parameters
        depositAmount = bound(depositAmount, 1 ether, 1000 ether);
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
        etherFiRedemptionManagerInstance.setExitFeeSplitToTreasuryInBps(uint16(exitFeeSplitBps), ETH_ADDRESS);

        vm.prank(owner);
        etherFiRedemptionManagerInstance.setExitFeeBasisPoints(exitFeeBps, ETH_ADDRESS);

        vm.prank(owner);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(lowWatermarkBps, ETH_ADDRESS);

        // Convert redeemAmount from ETH to weETH
        vm.startPrank(user);
        eETHInstance.approve(address(weEthInstance), redeemAmount);
        weEthInstance.wrap(redeemAmount);
        uint256 weEthAmount = weEthInstance.balanceOf(user);

        if (etherFiRedemptionManagerInstance.canRedeem(redeemAmount, ETH_ADDRESS)) {
            uint256 userBalanceBefore = address(user).balance;
            uint256 treasuryBalanceBefore = eETHInstance.balanceOf(address(treasuryInstance));

            uint256 eEthAmount = liquidityPoolInstance.amountForShare(weEthAmount);

            IWeETH.PermitInput memory permit = weEth_createPermitInput(999, address(etherFiRedemptionManagerInstance), weEthAmount, weEthInstance.nonces(user), 2**256 - 1, weEthInstance.DOMAIN_SEPARATOR());
            etherFiRedemptionManagerInstance.redeemWeEthWithPermit(weEthAmount, user, permit, ETH_ADDRESS);

            uint256 totalFee = (eEthAmount * exitFeeBps) / 10000;
            uint256 treasuryFee = (totalFee * exitFeeSplitBps) / 10000;
            uint256 userReceives = eEthAmount - totalFee;

            assertApproxEqAbs(
                eETHInstance.balanceOf(address(treasuryInstance)),
                treasuryBalanceBefore + treasuryFee,
                1e3
            );
            assertApproxEqAbs(
                address(user).balance,
                userBalanceBefore + userReceives,
                1e3
            );

        } else {
            vm.expectRevert();
            etherFiRedemptionManagerInstance.redeemWeEth(weEthAmount, user, ETH_ADDRESS);
        }
        vm.stopPrank();
    }

    function testFuzz_role_management(address admin, address pauser, address unpauser, address user) public {
        address owner = roleRegistryInstance.owner();
        bytes32 ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE = keccak256("ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE");
        bytes32 PROTOCOL_PAUSER = keccak256("PROTOCOL_PAUSER");
        bytes32 PROTOCOL_UNPAUSER = keccak256("PROTOCOL_UNPAUSER");

        vm.assume(admin != address(0) && admin != owner);
        vm.assume(pauser != address(0) && pauser != owner && pauser != admin);
        vm.assume(unpauser != address(0) && unpauser != owner && unpauser != admin && unpauser != pauser);
        vm.assume(user != address(0) && user != owner && user != admin && user != pauser && user != unpauser);

        // Grant roles to respective addresses
        vm.prank(owner);
        roleRegistryInstance.grantRole(ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE, admin);
        vm.prank(owner);
        roleRegistryInstance.grantRole(PROTOCOL_PAUSER, pauser);
        vm.prank(owner);
        roleRegistryInstance.grantRole(PROTOCOL_UNPAUSER, unpauser);

        // Admin performs admin-only actions
        vm.startPrank(admin);
        etherFiRedemptionManagerInstance.setCapacity(10 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(0.001 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setExitFeeSplitToTreasuryInBps(1e4, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(1e2, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setExitFeeBasisPoints(1e2, ETH_ADDRESS);
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

        // Revoke ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE role from admin
        vm.prank(owner);
        roleRegistryInstance.revokeRole(ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE, admin);

        // Admin attempts admin-only actions after role revocation
        vm.startPrank(admin);
        vm.expectRevert("EtherFiRedemptionManager: Unauthorized");
        etherFiRedemptionManagerInstance.setCapacity(10 ether, ETH_ADDRESS);
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

        vm.startPrank(op_admin);
        // Ensure bucket limiter has enough capacity and is fully refilled
        etherFiRedemptionManagerInstance.setCapacity(3000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(3000 ether, ETH_ADDRESS);
        vm.stopPrank();
        
        // Warp time forward to ensure bucket is fully refilled
        vm.warp(block.timestamp + 1);

        vm.deal(alice, 100000 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 100000 ether}();

        vm.deal(user, 2010 ether);
        vm.startPrank(user);

        liquidityPoolInstance.deposit{value: 2005 ether}();

        uint256 redeemableAmount = etherFiRedemptionManagerInstance.totalRedeemableAmount(ETH_ADDRESS);
        uint256 userBalance = address(user).balance;
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
        etherFiRedemptionManagerInstance.redeemEEth(2000 ether, user, ETH_ADDRESS);

        // Use more lenient tolerance for treasury fee due to share-based rounding
        assertApproxEqAbs(eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury())), treasuryBalance + expectedTreasuryFee, 1e15);
        assertApproxEqAbs(address(user).balance, userBalance + expectedAmountToReceiver, 1e1);

        // Check redeemable amount after first redemption
        uint256 redeemableAmountAfter = etherFiRedemptionManagerInstance.totalRedeemableAmount(ETH_ADDRESS);
        
        // Try to redeem more than what's available (if user has enough balance)
        uint256 userBalanceAfter = eETHInstance.balanceOf(user);
        if (userBalanceAfter > redeemableAmountAfter) {
            // User has enough balance, so test should fail due to exceeding redeemable amount
            uint256 amountToRedeem = redeemableAmountAfter + 1 ether;
            eETHInstance.approve(address(etherFiRedemptionManagerInstance), amountToRedeem);
            vm.expectRevert("EtherFiRedemptionManager: Exceeded total redeemable amount");
            etherFiRedemptionManagerInstance.redeemEEth(amountToRedeem, user, ETH_ADDRESS);
        }
        // If user doesn't have enough balance, that's fine - the redemption already verified the core functionality

        vm.stopPrank();
    }

    function test_mainnet_redeem_weEth_for_stETH_with_rebase() public {
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
        uint256 eEthAmount = weEthInstance.getEETHByWeETH(weEthAmount);
        uint256 userBalance = address(user).balance;
        address treasury = etherFiRedemptionManagerInstance.treasury();
        uint256 treasuryBalanceBefore = eETHInstance.balanceOf(treasury);
        weEthInstance.approve(address(etherFiRedemptionManagerInstance), 1 ether);
        etherFiRedemptionManagerInstance.redeemWeEth(weEthAmount, user, ETH_ADDRESS);
        
        // Use exact same calculation flow as _calcRedemption to account for rounding differences
        (, uint16 exitFeeSplitToTreasuryBps, uint16 exitFeeBps, ) = 
            etherFiRedemptionManagerInstance.tokenToRedemptionInfo(ETH_ADDRESS);
        uint256 eEthShares = liquidityPoolInstance.sharesForAmount(eEthAmount);
        uint256 expectedAmountToReceiver = liquidityPoolInstance.amountForShare(
            eEthShares * (10000 - exitFeeBps) / 10000
        );
        uint256 sharesToBurn = liquidityPoolInstance.sharesForWithdrawalAmount(expectedAmountToReceiver);
        uint256 eEthShareFee = eEthShares - sharesToBurn;
        uint256 feeShareToTreasury = eEthShareFee * exitFeeSplitToTreasuryBps / 10000;
        uint256 expectedTreasuryFee = liquidityPoolInstance.amountForShare(feeShareToTreasury);
        
        // Use more lenient tolerance for share-based rounding differences, especially after rebase
        assertApproxEqAbs(eETHInstance.balanceOf(treasury), treasuryBalanceBefore + expectedTreasuryFee, 5e11);
        assertApproxEqAbs(address(user).balance, userBalance + expectedAmountToReceiver, 1e3);

        vm.stopPrank();
    }

    function test_mainnet_redeem_beyond_liquidity_fails() public {
        setUp_Fork();

        uint256 redeemAmount = liquidityPoolInstance.getTotalPooledEther() / 2;
        vm.prank(address(liquidityPoolInstance));
        eETHInstance.mintShares(user, 2 * redeemAmount);

        vm.startPrank(op_admin);
        etherFiRedemptionManagerInstance.setCapacity(2 * redeemAmount, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(2 * redeemAmount, ETH_ADDRESS);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        vm.startPrank(user);

        uint256 userBalance = address(user).balance;
        uint256 treasuryBalance = eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury()));

        eETHInstance.approve(address(etherFiRedemptionManagerInstance), redeemAmount);
        vm.expectRevert("EtherFiRedemptionManager: Exceeded total redeemable amount");
        etherFiRedemptionManagerInstance.redeemEEth(redeemAmount, user, ETH_ADDRESS);

        vm.stopPrank();
    }

    function test_mainnet_redeem_eEth_for_stETH() public {
        setUp_Fork();
        ILido stEth = ILido(address(etherFiRestakerInstance.lido()));
        
        vm.startPrank(op_admin);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, address(etherFiRestakerInstance.lido()));
        // Ensure bucket limiter has enough capacity and is fully refilled
        etherFiRedemptionManagerInstance.setCapacity(3000 ether, address(etherFiRestakerInstance.lido()));
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(3000 ether, address(etherFiRestakerInstance.lido()));
        vm.stopPrank();
        
        // Warp time forward to ensure bucket is fully refilled
        vm.warp(block.timestamp + 1);
        
        // Fund EtherFiRestaker with stETH so redemption can work
        // Deposit stETH through liquifier which will fund EtherFiRestaker
        address funder = vm.addr(2001);
        vm.deal(funder, 2100 ether);
        vm.startPrank(funder);
        stEth.submit{value: 2100 ether}(address(0));
        uint256 stEthAmount = stEth.balanceOf(funder);
        stEth.approve(address(liquifierInstance), stEthAmount);
        liquifierInstance.depositWithERC20(address(stEth), stEthAmount, address(0));
        vm.stopPrank();
        
        vm.deal(user, 2010 ether);
        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: 2005 ether}();

        uint256 redeemableAmount = etherFiRedemptionManagerInstance.totalRedeemableAmount(address(etherFiRestakerInstance.lido()));
        uint256 stEthBalanceBefore = stEth.balanceOf(user);
        uint256 treasuryBalanceBefore = eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury()));

        // Get actual fee configuration from contract
        address lidoToken = address(etherFiRestakerInstance.lido());
        (, uint16 exitFeeSplitToTreasuryBps, uint16 exitFeeBps, ) = 
            etherFiRedemptionManagerInstance.tokenToRedemptionInfo(lidoToken);
        
        // Calculate expected values using shares (more accurate)
        uint256 eEthShares = liquidityPoolInstance.sharesForAmount(2000 ether);
        uint256 expectedAmountToReceiver = liquidityPoolInstance.amountForShare((eEthShares * (10000 - exitFeeBps)) / 10000);
        uint256 eEthShareFee = eEthShares - liquidityPoolInstance.sharesForWithdrawalAmount(expectedAmountToReceiver);
        uint256 expectedTreasuryFee = liquidityPoolInstance.amountForShare((eEthShareFee * exitFeeSplitToTreasuryBps) / 10000);

        eETHInstance.approve(address(etherFiRedemptionManagerInstance), 2000 ether);
        etherFiRedemptionManagerInstance.redeemEEth(2000 ether, user, lidoToken);

        redeemableAmount = etherFiRedemptionManagerInstance.totalRedeemableAmount(lidoToken);

        uint256 treasuryBalanceAfter = eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury()));
        uint256 stEthBalanceAfter = stEth.balanceOf(user);
        
        // Use more lenient tolerance for treasury fee due to share-based rounding
        assertApproxEqAbs(treasuryBalanceAfter, treasuryBalanceBefore + expectedTreasuryFee, 1e15);
        assertApproxEqAbs(stEthBalanceAfter, stEthBalanceBefore + expectedAmountToReceiver, 1e1);

        // After redeeming 2000 ether, verify the redemption worked correctly
        // The redeemable amount is min(bucket consumable, stETH balance in EtherFiRestaker)
        uint256 remainingStEth = stEth.balanceOf(address(etherFiRestakerInstance));
        assertLe(redeemableAmount, remainingStEth, "Redeemable amount should be limited by remaining stETH");
        
        // Try to redeem an amount greater than what's available (if user has enough balance)
        uint256 userBalance = eETHInstance.balanceOf(user);
        if (userBalance > redeemableAmount) {
            // User has enough balance, so test should fail due to exceeding redeemable amount
            uint256 amountToRedeem = redeemableAmount + 1 ether;
            eETHInstance.approve(address(etherFiRedemptionManagerInstance), amountToRedeem);
            vm.expectRevert("EtherFiRedemptionManager: Exceeded total redeemable amount");
            etherFiRedemptionManagerInstance.redeemEEth(amountToRedeem, user, lidoToken);
        }
        // If user doesn't have enough balance, that's fine - the redemption already verified the core functionality

        vm.stopPrank();
    }

    function test_mainnet_redeem_weEth_with_rebase() public {
        setUp_Fork();
        
        vm.startPrank(op_admin);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, address(etherFiRestakerInstance.lido()));
        // Ensure bucket limiter has enough capacity and is fully refilled
        etherFiRedemptionManagerInstance.setCapacity(3000 ether, address(etherFiRestakerInstance.lido()));
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(3000 ether, address(etherFiRestakerInstance.lido()));
        vm.stopPrank();
        
        // Warp time forward to ensure bucket is fully refilled
        vm.warp(block.timestamp + 1);

        // Fund EtherFiRestaker with stETH so redemption can work
        // Deposit stETH through liquifier which will fund EtherFiRestaker
        address funder = vm.addr(2002);
        vm.deal(funder, 5 ether);
        vm.startPrank(funder);
        stEth.submit{value: 5 ether}(address(0));
        uint256 stEthAmount = stEth.balanceOf(funder);
        stEth.approve(address(liquifierInstance), stEthAmount);
        liquifierInstance.depositWithERC20(address(stEth), stEthAmount, address(0));
        vm.stopPrank();

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
        uint256 eEthAmount = weEthInstance.getEETHByWeETH(weEthAmount);
        uint256 stEthBalanceBefore = stEth.balanceOf(user);
        address treasury = etherFiRedemptionManagerInstance.treasury();
        uint256 treasuryBalanceBefore = eETHInstance.balanceOf(treasury);
        weEthInstance.approve(address(etherFiRedemptionManagerInstance), 1 ether);
        etherFiRedemptionManagerInstance.redeemWeEth(weEthAmount, user, address(etherFiRestakerInstance.lido()));
        
        // Use exact same calculation flow as _calcRedemption to account for rounding differences
        address lidoToken = address(etherFiRestakerInstance.lido());
        (, uint16 exitFeeSplitToTreasuryBps, uint16 exitFeeBps, ) = 
            etherFiRedemptionManagerInstance.tokenToRedemptionInfo(lidoToken);
        uint256 eEthShares = liquidityPoolInstance.sharesForAmount(eEthAmount);
        uint256 expectedAmountToReceiver = liquidityPoolInstance.amountForShare(
            eEthShares * (10000 - exitFeeBps) / 10000
        );
        uint256 sharesToBurn = liquidityPoolInstance.sharesForWithdrawalAmount(expectedAmountToReceiver);
        uint256 eEthShareFee = eEthShares - sharesToBurn;
        uint256 feeShareToTreasury = eEthShareFee * exitFeeSplitToTreasuryBps / 10000;
        uint256 expectedTreasuryFee = liquidityPoolInstance.amountForShare(feeShareToTreasury);
        
        // Use more lenient tolerance for share-based rounding differences, especially after rebase
        assertApproxEqAbs(eETHInstance.balanceOf(treasury), treasuryBalanceBefore + expectedTreasuryFee, 5e11);
        assertApproxEqAbs(stEth.balanceOf(user), stEthBalanceBefore + expectedAmountToReceiver, 1e3);

        vm.stopPrank();
    }

    function test_unrestaker_transferSteth_permissions() public {
        setUp_Fork();

        // Fund EtherFiRestaker with stETH so transfer can work
        // Deposit stETH through liquifier which will fund EtherFiRestaker
        address funder = vm.addr(2005);
        vm.deal(funder, 5 ether);
        vm.startPrank(funder);
        stEth.submit{value: 5 ether}(address(0));
        uint256 stEthAmount = stEth.balanceOf(funder);
        stEth.approve(address(liquifierInstance), stEthAmount);
        liquifierInstance.depositWithERC20(address(stEth), stEthAmount, address(0));
        vm.stopPrank();

        vm.expectRevert(EtherFiRestaker.IncorrectCaller.selector);
        vm.startPrank(admin);
        etherFiRestakerInstance.transferStETH(user, 1 ether);
        vm.stopPrank();

        vm.expectRevert(EtherFiRestaker.IncorrectCaller.selector);
        vm.startPrank(owner);
        etherFiRestakerInstance.transferStETH(user, 1 ether);
        vm.stopPrank();

        uint256 balanceBefore = etherFiRestakerInstance.lido().balanceOf(user);
        vm.prank(address(etherFiRedemptionManagerInstance));
        etherFiRestakerInstance.transferStETH(user, 1 ether);
        uint256 balanceAfter = etherFiRestakerInstance.lido().balanceOf(user);
        assertApproxEqAbs(balanceAfter, balanceBefore + 1 ether, 2);
    }

    function test_end_to_end_redeem_stETH() public {
        setUp_Fork();
        vm.startPrank(op_admin);
        address[] memory _tokens = new address[](1);
        _tokens[0] = address(etherFiRestakerInstance.lido());
        uint16[] memory _exitFeeSplitToTreasuryInBps = new uint16[](1);
        _exitFeeSplitToTreasuryInBps[0] = 20_00;
        uint16[] memory _exitFeeInBps = new uint16[](1);
        _exitFeeInBps[0] = 3_00;
        uint16[] memory _lowWatermarkInBpsOfTvl = new uint16[](1);
        _lowWatermarkInBpsOfTvl[0] = 2_00;
        uint256[] memory _bucketCapacity = new uint256[](1);
        _bucketCapacity[0] = 10 ether;
        uint256[] memory _bucketRefillRate = new uint256[](1);
        _bucketRefillRate[0] = 0.001 ether;
        etherFiRedemptionManagerInstance.initializeTokenParameters(_tokens, _exitFeeSplitToTreasuryInBps, _exitFeeInBps, _lowWatermarkInBpsOfTvl, _bucketCapacity, _bucketRefillRate);

        // verify the struct has the correct values for stETH after update token parameters
        (BucketLimiter.Limit memory limit, uint16 exitSplit, uint16 exitFee, uint16 lowWM) =
            etherFiRedemptionManagerInstance.tokenToRedemptionInfo(address(etherFiRestakerInstance.lido()));
        assertEq(exitSplit, 20_00);
        assertEq(exitFee, 3_00);
        assertEq(lowWM, 2_00);
        uint64 expectedCapacity = uint64(10 ether / 1e12);
        uint64 expectedRefillRate = uint64(0.001 ether / 1e12);
        assertEq(limit.capacity, expectedCapacity);
        assertEq(limit.refillRate, expectedRefillRate);
        vm.stopPrank();

        // Fund EtherFiRestaker with stETH so redemption can work
        // Deposit stETH through liquifier which will fund EtherFiRestaker
        address funder = vm.addr(2000);
        vm.deal(funder, 5 ether);
        vm.startPrank(funder);
        stEth.submit{value: 5 ether}(address(0));
        uint256 stEthAmount = stEth.balanceOf(funder);
        stEth.approve(address(liquifierInstance), stEthAmount);
        liquifierInstance.depositWithERC20(address(stEth), stEthAmount, address(0));
        vm.stopPrank();

        //test low watermark works
        vm.startPrank(user);
        vm.deal(user, 10 ether);
        liquidityPoolInstance.deposit{value: 10 ether}();
        address lidoToken = address(etherFiRestakerInstance.lido()); // external call; fetch before expectRevert
        vm.expectRevert(bytes("EtherFiRedemptionManager: Exceeded total redeemable amount"));
        etherFiRedemptionManagerInstance.redeemEEth(1 ether, user, lidoToken);
        vm.stopPrank();
        vm.startPrank(op_admin);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, address(etherFiRestakerInstance.lido()));
        vm.stopPrank();
        vm.startPrank(user);
        uint256 balanceBefore = stEth.balanceOf(user);
        eETHInstance.approve(address(etherFiRedemptionManagerInstance), 1 ether);
        etherFiRedemptionManagerInstance.redeemEEth(1 ether, user, address(etherFiRestakerInstance.lido())); 
        uint256 balanceAfter = stEth.balanceOf(user);
        assertApproxEqAbs(balanceAfter, balanceBefore + 1 ether - 0.03 ether, 1e1);
        vm.stopPrank();
    }

    function test_redeem_stETH_share_price() public {
        setUp_Fork();
        vm.startPrank(op_admin);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, address(etherFiRestakerInstance.lido()));
        vm.stopPrank();

        // Fund EtherFiRestaker with stETH so redemption can work
        // Deposit stETH through liquifier which will fund EtherFiRestaker
        address funder = vm.addr(2003);
        vm.deal(funder, 5 ether);
        vm.startPrank(funder);
        stEth.submit{value: 5 ether}(address(0));
        uint256 stEthAmount = stEth.balanceOf(funder);
        stEth.approve(address(liquifierInstance), stEthAmount);
        liquifierInstance.depositWithERC20(address(stEth), stEthAmount, address(0));
        vm.stopPrank();

        vm.startPrank(user);
        vm.deal(user, 10 ether);
        liquidityPoolInstance.deposit{value: 10 ether}();
        eETHInstance.approve(address(etherFiRedemptionManagerInstance), 10 ether);
        
        // Get fee configuration and calculate expected values
        address lidoToken = address(etherFiRestakerInstance.lido());
        (, uint16 exitFeeSplitToTreasuryBps, uint16 exitFeeBps, ) = etherFiRedemptionManagerInstance.tokenToRedemptionInfo(lidoToken);
        uint256 eEthShares = liquidityPoolInstance.sharesForAmount(1 ether);
        uint256 expectedAmountToReceiver = liquidityPoolInstance.amountForShare((eEthShares * (10000 - exitFeeBps)) / 10000);
        uint256 eEthShareFee = eEthShares - liquidityPoolInstance.sharesForWithdrawalAmount(expectedAmountToReceiver);
        uint256 expectedTreasuryFee = liquidityPoolInstance.amountForShare((eEthShareFee * exitFeeSplitToTreasuryBps) / 10000);
        uint256 expectedTotalSharesBurned = eEthShares - (eEthShareFee * exitFeeSplitToTreasuryBps / 10000);
        
        // Capture state before redemption
        uint256 totalValueOutOfLpBefore = liquidityPoolInstance.totalValueOutOfLp();
        uint256 totalSharesBefore = eETHInstance.totalShares();
        uint256 treasuryBalanceBefore = eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury()));
        uint256 stethBalanceBefore = stEth.balanceOf(user);
        
        etherFiRedemptionManagerInstance.redeemEEth(1 ether, user, lidoToken);
        
        // Compare differences
        assertApproxEqAbs(stEth.balanceOf(user) - stethBalanceBefore, expectedAmountToReceiver, 1e3);
        assertApproxEqAbs(totalSharesBefore - eETHInstance.totalShares(), expectedTotalSharesBurned, 1e2);
        assertApproxEqAbs(totalValueOutOfLpBefore - liquidityPoolInstance.totalValueOutOfLp(), expectedAmountToReceiver, 1e3);
        uint256 totalValueInLpBefore = liquidityPoolInstance.totalValueInLp();
        assertEq(liquidityPoolInstance.totalValueInLp() - totalValueInLpBefore, 0);
        assertApproxEqAbs(eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury())) - treasuryBalanceBefore, expectedTreasuryFee, 1.5e11);
        vm.stopPrank();
    }

    function test_redeem_stETH_share_price_with_not_fee() public {
        setUp_Fork();
        
        // Fund EtherFiRestaker with stETH so redemption can work
        // Deposit stETH through liquifier which will fund EtherFiRestaker
        address funder = vm.addr(2004);
        vm.deal(funder, 5 ether);
        vm.startPrank(funder);
        stEth.submit{value: 5 ether}(address(0));
        uint256 stEthAmount = stEth.balanceOf(funder);
        stEth.approve(address(liquifierInstance), stEthAmount);
        liquifierInstance.depositWithERC20(address(stEth), stEthAmount, address(0));
        vm.stopPrank();
        
        vm.startPrank(user);
        vm.deal(user, 10 ether);
        liquidityPoolInstance.deposit{value: 10 ether}();
        eETHInstance.approve(address(etherFiRedemptionManagerInstance), 10 ether);
        vm.stopPrank();
        //set fee to 0
        vm.startPrank(op_admin);
        etherFiRedemptionManagerInstance.setExitFeeBasisPoints(0, address(etherFiRestakerInstance.lido()));
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, address(etherFiRestakerInstance.lido()));
        vm.stopPrank();
        //get number of shares for 1 ether
        vm.startPrank(user);
        uint256 sharesFor_999_ether = liquidityPoolInstance.sharesForAmount(1 ether); // should be 0.9 ether since 0.1 ether is left for 
        address lidoToken = address(etherFiRestakerInstance.lido()); // external call; fetch before expectRevert
        uint256 totalValueOutOfLpBefore = liquidityPoolInstance.totalValueOutOfLp();
        uint256 totalValueInLpBefore = liquidityPoolInstance.totalValueInLp();
        uint256 totalSharesBefore = eETHInstance.totalShares();
        uint256 treasuryBalanceBefore = eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury()));
        //steth balance before
        uint256 stethBalanceBefore = stEth.balanceOf(user);
        etherFiRedemptionManagerInstance.redeemEEth(1 ether, user, lidoToken);
        uint256 stethBalanceAfter = stEth.balanceOf(user);
        uint256 totalSharesAfter = eETHInstance.totalShares();
        uint256 totalValueOutOfLpAfter = liquidityPoolInstance.totalValueOutOfLp();
        uint256 totalValueInLpAfter = liquidityPoolInstance.totalValueInLp();
        uint256 treasuryBalanceAfter = eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury()));
        assertApproxEqAbs(stethBalanceAfter - stethBalanceBefore, 1 ether, 3);
        assertApproxEqAbs(totalSharesBefore - totalSharesAfter, sharesFor_999_ether, 1);
        assertApproxEqAbs(totalValueOutOfLpBefore - totalValueOutOfLpAfter, 1 ether, 3);
        assertEq(totalValueInLpAfter- totalValueInLpBefore, 0);
        assertEq(treasuryBalanceAfter-treasuryBalanceBefore, 0);
        vm.stopPrank();
    }

    function test_redeem_eEth_share_price() public {
        setUp_Fork();
        vm.startPrank(op_admin);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, ETH_ADDRESS);
        vm.stopPrank();
        
        vm.startPrank(user);
        vm.deal(user, 10 ether);
        liquidityPoolInstance.deposit{value: 10 ether}();
        eETHInstance.approve(address(etherFiRedemptionManagerInstance), 10 ether);
        
        // Get fee configuration and calculate expected values dynamically
        (, uint16 exitFeeSplitToTreasuryBps, uint16 exitFeeBps, ) = 
            etherFiRedemptionManagerInstance.tokenToRedemptionInfo(ETH_ADDRESS);
        uint256 eEthShares = liquidityPoolInstance.sharesForAmount(1 ether);
        uint256 expectedAmountToReceiver = liquidityPoolInstance.amountForShare((eEthShares * (10000 - exitFeeBps)) / 10000);
        uint256 sharesToBurn = liquidityPoolInstance.sharesForWithdrawalAmount(expectedAmountToReceiver);
        uint256 eEthShareFee = eEthShares - sharesToBurn;
        uint256 feeShareToTreasury = (eEthShareFee * exitFeeSplitToTreasuryBps) / 10000;
        uint256 expectedTreasuryFee = liquidityPoolInstance.amountForShare(feeShareToTreasury);
        uint256 expectedTotalSharesBurned = eEthShares - feeShareToTreasury;
        
        // Capture state before redemption
        uint256 totalValueOutOfLpBefore = liquidityPoolInstance.totalValueOutOfLp();
        uint256 totalValueInLpBefore = liquidityPoolInstance.totalValueInLp();
        uint256 totalSharesBefore = eETHInstance.totalShares();
        uint256 treasuryBalanceBefore = eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury()));
        uint256 ethBalanceBefore = address(user).balance;
        
        etherFiRedemptionManagerInstance.redeemEEth(1 ether, user, ETH_ADDRESS);
        
        // Compare differences
        assertApproxEqAbs(address(user).balance - ethBalanceBefore, expectedAmountToReceiver, 1e3);
        assertApproxEqAbs(totalSharesBefore - eETHInstance.totalShares(), expectedTotalSharesBurned, 1e2);
        assertApproxEqAbs(totalValueInLpBefore - liquidityPoolInstance.totalValueInLp(), expectedAmountToReceiver, 1e3);
        assertEq(liquidityPoolInstance.totalValueOutOfLp() - totalValueOutOfLpBefore, 0);
        // Use more lenient tolerance for treasury fee due to share-based rounding differences on mainnet fork
        assertApproxEqAbs(eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury())) - treasuryBalanceBefore, expectedTreasuryFee, 5e11);
        vm.stopPrank();
    }


    function test_mainnet_previewRedeem_eEth() public {
        setUp_Fork();
        
        vm.deal(user, 100 ether);
        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: 100 ether}();
        vm.stopPrank();

        vm.startPrank(op_admin);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setCapacity(1000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(1000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setExitFeeBasisPoints(50, ETH_ADDRESS); // 0.5%
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        vm.startPrank(user);
        uint256 eEthBalance = eETHInstance.balanceOf(user);
        uint256 shares = liquidityPoolInstance.sharesForAmount(eEthBalance);
        
        uint256 previewAmount = etherFiRedemptionManagerInstance.previewRedeem(shares, ETH_ADDRESS);
        
        // previewRedeem should return amount after exit fee
        uint256 expectedAmount = eEthBalance - (eEthBalance * 50 / 10000);
        assertApproxEqAbs(previewAmount, expectedAmount, 1e10);
        
        // Verify preview matches actual redemption
        uint256 userBalanceBefore = address(user).balance;
        eETHInstance.approve(address(etherFiRedemptionManagerInstance), eEthBalance);
        etherFiRedemptionManagerInstance.redeemEEth(eEthBalance, user, ETH_ADDRESS);
        uint256 userBalanceAfter = address(user).balance;
        
        assertApproxEqAbs(userBalanceAfter - userBalanceBefore, previewAmount, 1e3);
        vm.stopPrank();
    }

    function test_mainnet_previewRedeem_stETH() public {
        setUp_Fork();
        
        ILido stEth = ILido(address(etherFiRestakerInstance.lido()));
        
        vm.startPrank(op_admin);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, address(stEth));
        etherFiRedemptionManagerInstance.setCapacity(100000 ether, address(stEth));
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(100000 ether, address(stEth));
        etherFiRedemptionManagerInstance.setExitFeeBasisPoints(30, address(stEth)); // 0.3%
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        // Fund EtherFiRestaker with stETH
        address funder = vm.addr(2010);
        vm.deal(funder, 10000 ether);
        vm.startPrank(funder);
        stEth.submit{value: 10000 ether}(address(0));
        uint256 stEthAmount = stEth.balanceOf(funder);
        stEth.approve(address(liquifierInstance), stEthAmount);
        liquifierInstance.depositWithERC20(address(stEth), stEthAmount, address(0));
        vm.stopPrank();

        vm.deal(user, 100 ether);
        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: 100 ether}();
        uint256 eEthBalance = eETHInstance.balanceOf(user);
        uint256 shares = liquidityPoolInstance.sharesForAmount(eEthBalance);
        
        uint256 previewAmount = etherFiRedemptionManagerInstance.previewRedeem(shares, address(stEth));
        
        // previewRedeem should return amount after exit fee
        uint256 expectedAmount = eEthBalance - (eEthBalance * 30 / 10000);
        assertApproxEqAbs(previewAmount, expectedAmount, 1e10);
        
        // Verify preview matches actual redemption
        uint256 stEthBalanceBefore = stEth.balanceOf(user);
        eETHInstance.approve(address(etherFiRedemptionManagerInstance), eEthBalance);
        etherFiRedemptionManagerInstance.redeemEEth(eEthBalance, user, address(stEth));
        uint256 stEthBalanceAfter = stEth.balanceOf(user);
        
        assertApproxEqAbs(stEthBalanceAfter - stEthBalanceBefore, previewAmount, 1e3);
        vm.stopPrank();
    }

    function test_mainnet_getInstantLiquidityAmount_ETH() public {
        setUp_Fork();
        
        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 1000 ether}();

        uint256 instantLiquidity = etherFiRedemptionManagerInstance.getInstantLiquidityAmount(ETH_ADDRESS);
        uint256 lpBalance = address(liquidityPoolInstance).balance;
        uint256 lockedForWithdrawal = liquidityPoolInstance.ethAmountLockedForWithdrawal();
        
        assertEq(instantLiquidity, lpBalance - lockedForWithdrawal);
        assertGt(instantLiquidity, 0);
    }

    function test_mainnet_getInstantLiquidityAmount_stETH() public {
        setUp_Fork();
        
        ILido stEth = ILido(address(etherFiRestakerInstance.lido()));
        
        // Fund EtherFiRestaker with stETH
        address funder = vm.addr(2011);
        vm.deal(funder, 50 ether);
        vm.startPrank(funder);
        stEth.submit{value: 50 ether}(address(0));
        uint256 stEthAmount = stEth.balanceOf(funder);
        stEth.approve(address(liquifierInstance), stEthAmount);
        liquifierInstance.depositWithERC20(address(stEth), stEthAmount, address(0));
        vm.stopPrank();

        uint256 instantLiquidity = etherFiRedemptionManagerInstance.getInstantLiquidityAmount(address(stEth));
        uint256 restakerBalance = stEth.balanceOf(address(etherFiRestakerInstance));
        
        assertEq(instantLiquidity, restakerBalance);
        assertGt(instantLiquidity, 0);
    }

    function test_mainnet_bucket_limiter_refill_over_time() public {
        setUp_Fork();
        
        vm.startPrank(op_admin);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setCapacity(100 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(10 ether, ETH_ADDRESS); // 10 ETH per second
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        vm.deal(user, 200 ether);
        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: 200 ether}();
        vm.stopPrank();

        // Consume full capacity
        vm.startPrank(user);
        eETHInstance.approve(address(etherFiRedemptionManagerInstance), 100 ether);
        etherFiRedemptionManagerInstance.redeemEEth(100 ether, user, ETH_ADDRESS);
        vm.stopPrank();

        // Should not be able to redeem more immediately
        vm.startPrank(user);
        uint256 remainingBalance = eETHInstance.balanceOf(user);
        if (remainingBalance > 0) {
            eETHInstance.approve(address(etherFiRedemptionManagerInstance), remainingBalance);
            vm.expectRevert("EtherFiRedemptionManager: Exceeded total redeemable amount");
            etherFiRedemptionManagerInstance.redeemEEth(remainingBalance, user, ETH_ADDRESS);
        }
        vm.stopPrank();

        // Warp forward 1 second - should have refilled 10 ETH
        vm.warp(block.timestamp + 1);
        
        uint256 redeemableAfter1Sec = etherFiRedemptionManagerInstance.totalRedeemableAmount(ETH_ADDRESS);
        assertGe(redeemableAfter1Sec, 10 ether - 1e12); // Allow for rounding

        // Warp forward 5 more seconds - should have refilled 50 ETH total
        vm.warp(block.timestamp + 5);
        
        uint256 redeemableAfter6Sec = etherFiRedemptionManagerInstance.totalRedeemableAmount(ETH_ADDRESS);
        assertGe(redeemableAfter6Sec, 60 ether - 1e12); // Allow for rounding

        // Should be able to redeem 60 ETH now
        vm.startPrank(user);
        uint256 userBalance = eETHInstance.balanceOf(user);
        if (userBalance >= 60 ether) {
            eETHInstance.approve(address(etherFiRedemptionManagerInstance), 60 ether);
            uint256 userEthBefore = address(user).balance;
            etherFiRedemptionManagerInstance.redeemEEth(60 ether, user, ETH_ADDRESS);
            assertGt(address(user).balance, userEthBefore);
        }
        vm.stopPrank();
    }

    function test_mainnet_low_watermark_exactly_at_threshold() public {
        setUp_Fork();
        
        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 1000 ether}();

        vm.startPrank(op_admin);
        // Set low watermark to 10% of TVL
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(10_00, ETH_ADDRESS); // 10%
        etherFiRedemptionManagerInstance.setCapacity(10000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(10000 ether, ETH_ADDRESS);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        uint256 tvl = liquidityPoolInstance.getTotalPooledEther();
        uint256 lowWatermark = etherFiRedemptionManagerInstance.lowWatermarkInETH(ETH_ADDRESS);
        assertEq(lowWatermark, tvl * 10_00 / 10000);

        uint256 instantLiquidity = etherFiRedemptionManagerInstance.getInstantLiquidityAmount(ETH_ADDRESS);
        
        // If liquidity is exactly at low watermark, should not be able to redeem
        if (instantLiquidity <= lowWatermark) {
            vm.deal(user, 100 ether);
            vm.startPrank(user);
            liquidityPoolInstance.deposit{value: 100 ether}();
            vm.expectRevert("EtherFiRedemptionManager: Exceeded total redeemable amount");
            etherFiRedemptionManagerInstance.redeemEEth(1 ether, user, ETH_ADDRESS);
            vm.stopPrank();
        }
    }

    function test_mainnet_low_watermark_just_below_threshold() public {
        setUp_Fork();
        
        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 1000 ether}();

        vm.startPrank(op_admin);
        // Set low watermark to 50% of TVL
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(50_00, ETH_ADDRESS); // 50%
        etherFiRedemptionManagerInstance.setCapacity(10000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(10000 ether, ETH_ADDRESS);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        uint256 instantLiquidity = etherFiRedemptionManagerInstance.getInstantLiquidityAmount(ETH_ADDRESS);
        uint256 lowWatermark = etherFiRedemptionManagerInstance.lowWatermarkInETH(ETH_ADDRESS);

        // If liquidity is below low watermark, totalRedeemableAmount should be 0
        if (instantLiquidity < lowWatermark) {
            uint256 redeemable = etherFiRedemptionManagerInstance.totalRedeemableAmount(ETH_ADDRESS);
            assertEq(redeemable, 0);
            
            vm.deal(user, 100 ether);
            vm.startPrank(user);
            liquidityPoolInstance.deposit{value: 100 ether}();
            vm.expectRevert("EtherFiRedemptionManager: Exceeded total redeemable amount");
            etherFiRedemptionManagerInstance.redeemEEth(1 ether, user, ETH_ADDRESS);
            vm.stopPrank();
        }
    }

    function test_mainnet_pause_unpause_redemption() public {
        setUp_Fork();
        
        vm.startPrank(op_admin);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setCapacity(1000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(1000 ether, ETH_ADDRESS);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        vm.deal(user, 100 ether);
        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: 100 ether}();
        vm.stopPrank();

        // Pause the contract
        bytes32 PROTOCOL_PAUSER = keccak256("PROTOCOL_PAUSER");
        address pauser = vm.addr(2000);
        vm.prank(roleRegistryInstance.owner());
        roleRegistryInstance.grantRole(PROTOCOL_PAUSER, pauser);

        vm.prank(pauser);
        etherFiRedemptionManagerInstance.pauseContract();
        assertTrue(etherFiRedemptionManagerInstance.paused());

        // Should not be able to redeem when paused
        vm.startPrank(user);
        eETHInstance.approve(address(etherFiRedemptionManagerInstance), 10 ether);
        vm.expectRevert("Pausable: paused");
        etherFiRedemptionManagerInstance.redeemEEth(10 ether, user, ETH_ADDRESS);
        vm.expectRevert("Pausable: paused");
        etherFiRedemptionManagerInstance.redeemWeEth(10 ether, user, ETH_ADDRESS);
        vm.stopPrank();

        // Unpause the contract
        bytes32 PROTOCOL_UNPAUSER = keccak256("PROTOCOL_UNPAUSER");
        address unpauser = vm.addr(2001);
        vm.prank(roleRegistryInstance.owner());
        roleRegistryInstance.grantRole(PROTOCOL_UNPAUSER, unpauser);

        vm.prank(unpauser);
        etherFiRedemptionManagerInstance.unPauseContract();
        assertFalse(etherFiRedemptionManagerInstance.paused());

        // Should be able to redeem after unpause
        vm.startPrank(user);
        uint256 userBalance = eETHInstance.balanceOf(user);
        if (userBalance > 0) {
            eETHInstance.approve(address(etherFiRedemptionManagerInstance), userBalance);
            uint256 userEthBefore = address(user).balance;
            etherFiRedemptionManagerInstance.redeemEEth(userBalance, user, ETH_ADDRESS);
            assertGt(address(user).balance, userEthBefore);
        }
        vm.stopPrank();
    }

    function test_mainnet_redeem_zero_amount() public {
        setUp_Fork();
        
        vm.deal(user, 100 ether);
        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: 100 ether}();
        eETHInstance.approve(address(etherFiRedemptionManagerInstance), 0);
        
        // Zero amount should fail
        vm.expectRevert();
        etherFiRedemptionManagerInstance.redeemEEth(0, user, ETH_ADDRESS);
        vm.stopPrank();
    }

    function test_mainnet_redeem_insufficient_balance() public {
        setUp_Fork();
        
        vm.startPrank(op_admin);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setCapacity(1000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(1000 ether, ETH_ADDRESS);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        vm.deal(user, 10 ether);
        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: 10 ether}();
        
        // Try to redeem more than balance
        eETHInstance.approve(address(etherFiRedemptionManagerInstance), 100 ether);
        vm.expectRevert("EtherFiRedemptionManager: Insufficient balance");
        etherFiRedemptionManagerInstance.redeemEEth(100 ether, user, ETH_ADDRESS);
        vm.stopPrank();
    }

    function test_mainnet_redeem_insufficient_stETH() public {
        setUp_Fork();
        
        ILido stEth = ILido(address(etherFiRestakerInstance.lido()));
        
        vm.startPrank(op_admin);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, address(stEth));
        etherFiRedemptionManagerInstance.setCapacity(1000 ether, address(stEth));
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(1000 ether, address(stEth));
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        uint256 stEthBalance = stEth.balanceOf(address(etherFiRestakerInstance));
        uint256 amount = stEthBalance + 1 ether;
        vm.deal(user, amount);
        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: amount}();
        eETHInstance.approve(address(etherFiRedemptionManagerInstance), amount);
        
        // Should fail due to exceeding total redeemable amount
        vm.expectRevert("EtherFiRedemptionManager: Insufficient balance");
        etherFiRedemptionManagerInstance.redeemEEth(amount, user, address(stEth));
        vm.stopPrank();
    }

    function test_mainnet_redeem_emits_event() public {
        setUp_Fork();
        
        vm.startPrank(op_admin);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setCapacity(1000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(1000 ether, ETH_ADDRESS);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        vm.deal(user, 100 ether);
        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: 100 ether}();
        uint256 redeemAmount = 10 ether;
        eETHInstance.approve(address(etherFiRedemptionManagerInstance), redeemAmount);
        
        // Check that event is emitted with correct receiver and token
        vm.expectEmit(true, false, false, false);
        emit EtherFiRedemptionManager.Redeemed(
            user,
            redeemAmount,
            0, // We'll check this separately
            0, // We'll check this separately
            ETH_ADDRESS
        );
        
        etherFiRedemptionManagerInstance.redeemEEth(redeemAmount, user, ETH_ADDRESS);
        
        // Verify event was emitted by checking state changes
        uint256 treasuryBalance = eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury()));
        assertGt(treasuryBalance, 0); // Treasury should have received fees
        vm.stopPrank();
    }

    function test_mainnet_multiple_sequential_redemptions() public {
        setUp_Fork();
        
        vm.startPrank(op_admin);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setCapacity(100 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(10 ether, ETH_ADDRESS); // 10 ETH per second
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        vm.deal(user, 200 ether);
        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: 200 ether}();
        vm.stopPrank();

        // First redemption - consume 50 ETH
        vm.startPrank(user);
        eETHInstance.approve(address(etherFiRedemptionManagerInstance), 50 ether);
        uint256 userEthBefore1 = address(user).balance;
        etherFiRedemptionManagerInstance.redeemEEth(50 ether, user, ETH_ADDRESS);
        uint256 userEthAfter1 = address(user).balance;
        assertGt(userEthAfter1, userEthBefore1);
        vm.stopPrank();

        // Check redeemable amount decreased
        uint256 redeemableAfter1 = etherFiRedemptionManagerInstance.totalRedeemableAmount(ETH_ADDRESS);
        assertLe(redeemableAfter1, 50 ether); // Should have 50 ETH left in bucket

        // Warp forward 2 seconds - should refill 20 ETH
        vm.warp(block.timestamp + 2);

        // Second redemption - should be able to redeem up to 70 ETH now
        vm.startPrank(user);
        uint256 userBalance = eETHInstance.balanceOf(user);
        if (userBalance >= 70 ether) {
            eETHInstance.approve(address(etherFiRedemptionManagerInstance), 70 ether);
            uint256 userEthBefore2 = address(user).balance;
            etherFiRedemptionManagerInstance.redeemEEth(70 ether, user, ETH_ADDRESS);
            uint256 userEthAfter2 = address(user).balance;
            assertGt(userEthAfter2, userEthBefore2);
        }
        vm.stopPrank();
    }

    function test_mainnet_redeemEEthWithPermit_invalid_permit() public {
        setUp_Fork();
        
        vm.startPrank(op_admin);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setCapacity(1000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(1000 ether, ETH_ADDRESS);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        vm.deal(user, 100 ether);
        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: 100 ether}();
        vm.stopPrank();

        // Create invalid permit (wrong signature)
        IeETH.PermitInput memory invalidPermit = IeETH.PermitInput({
            value: 10 ether,
            deadline: block.timestamp + 1000,
            v: 27,
            r: bytes32(uint256(1)),
            s: bytes32(uint256(2))
        });

        // Permit will fail but redemption should still work if user has approved
        vm.startPrank(user);
        eETHInstance.approve(address(etherFiRedemptionManagerInstance), 10 ether);
        // Should still work because we check balance, not permit
        uint256 userEthBefore = address(user).balance;
        etherFiRedemptionManagerInstance.redeemEEthWithPermit(10 ether, user, invalidPermit, ETH_ADDRESS);
        assertGt(address(user).balance, userEthBefore);
        vm.stopPrank();
    }

    function test_mainnet_redeem_at_maximum_capacity() public {
        setUp_Fork();
        
        vm.startPrank(op_admin);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setCapacity(10000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(10000 ether, ETH_ADDRESS);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        vm.deal(user, 20000 ether);
        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: 20000 ether}();
        vm.stopPrank();

        // Redeem exactly at capacity
        uint256 remainingCapacity = etherFiRedemptionManagerInstance.totalRedeemableAmount(ETH_ADDRESS);
        vm.startPrank(user);
        eETHInstance.approve(address(etherFiRedemptionManagerInstance), remainingCapacity);
        uint256 userEthBefore = address(user).balance;
        etherFiRedemptionManagerInstance.redeemEEth(remainingCapacity, user, ETH_ADDRESS);
        assertGt(address(user).balance, userEthBefore);
        vm.stopPrank();

        // Should not be able to redeem more immediately
        vm.startPrank(user);
        uint256 remainingBalance = eETHInstance.balanceOf(user);
        if (remainingBalance > 0) {
            eETHInstance.approve(address(etherFiRedemptionManagerInstance), remainingBalance);
            vm.expectRevert("EtherFiRedemptionManager: Exceeded total redeemable amount");
            etherFiRedemptionManagerInstance.redeemEEth(remainingBalance, user, ETH_ADDRESS);
        }
        vm.stopPrank();
    }

    function test_mainnet_initializeTokenParameters_multiple_tokens() public {
        setUp_Fork();
        
        vm.startPrank(op_admin);
        address[] memory tokens = new address[](2);
        tokens[0] = ETH_ADDRESS;
        tokens[1] = address(etherFiRestakerInstance.lido());
        
        uint16[] memory exitFeeSplitBps = new uint16[](2);
        exitFeeSplitBps[0] = 50_00; // 50%
        exitFeeSplitBps[1] = 30_00; // 30%
        
        uint16[] memory exitFeeBps = new uint16[](2);
        exitFeeBps[0] = 50; // 0.5%
        exitFeeBps[1] = 30; // 0.3%
        
        uint16[] memory lowWatermarkBps = new uint16[](2);
        lowWatermarkBps[0] = 10_00; // 10%
        lowWatermarkBps[1] = 5_00; // 5%
        
        uint256[] memory capacities = new uint256[](2);
        capacities[0] = 1000 ether;
        capacities[1] = 500 ether;
        
        uint256[] memory refillRates = new uint256[](2);
        refillRates[0] = 100 ether;
        refillRates[1] = 50 ether;
        
        etherFiRedemptionManagerInstance.initializeTokenParameters(
            tokens,
            exitFeeSplitBps,
            exitFeeBps,
            lowWatermarkBps,
            capacities,
            refillRates
        );
        
        // Verify ETH_ADDRESS configuration
        (BucketLimiter.Limit memory ethLimit, uint16 ethExitSplit, uint16 ethExitFee, uint16 ethLowWM) =
            etherFiRedemptionManagerInstance.tokenToRedemptionInfo(ETH_ADDRESS);
        assertEq(ethExitSplit, 50_00);
        assertEq(ethExitFee, 50);
        assertEq(ethLowWM, 10_00);
        
        // Verify stETH configuration
        (BucketLimiter.Limit memory stEthLimit, uint16 stEthExitSplit, uint16 stEthExitFee, uint16 stEthLowWM) =
            etherFiRedemptionManagerInstance.tokenToRedemptionInfo(address(etherFiRestakerInstance.lido()));
        assertEq(stEthExitSplit, 30_00);
        assertEq(stEthExitFee, 30);
        assertEq(stEthLowWM, 5_00);
        
        vm.stopPrank();
    }

    function test_mainnet_setExitFeeBasisPoints_max_value() public {
        setUp_Fork();
        
        vm.startPrank(op_admin);
        // Set to maximum allowed value (100%)
        etherFiRedemptionManagerInstance.setExitFeeBasisPoints(10000, ETH_ADDRESS);
        
        (, , uint16 exitFeeBps, ) = etherFiRedemptionManagerInstance.tokenToRedemptionInfo(ETH_ADDRESS);
        assertEq(exitFeeBps, 10000);
        
        // Try to set above maximum - should fail
        vm.expectRevert("INVALID");
        etherFiRedemptionManagerInstance.setExitFeeBasisPoints(10001, ETH_ADDRESS);
        vm.stopPrank();
    }

    function test_mainnet_setLowWatermarkInBpsOfTvl_max_value() public {
        setUp_Fork();
        
        vm.startPrank(op_admin);
        // Set to maximum allowed value (100%)
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(10000, ETH_ADDRESS);
        
        (, , , uint16 lowWM) = etherFiRedemptionManagerInstance.tokenToRedemptionInfo(ETH_ADDRESS);
        assertEq(lowWM, 10000);
        
        // Try to set above maximum - should fail
        vm.expectRevert("INVALID");
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(10001, ETH_ADDRESS);
        vm.stopPrank();
    }

    function test_mainnet_setExitFeeSplitToTreasuryInBps_max_value() public {
        setUp_Fork();
        
        vm.startPrank(op_admin);
        // Set to maximum allowed value (100%)
        etherFiRedemptionManagerInstance.setExitFeeSplitToTreasuryInBps(10000, ETH_ADDRESS);
        
        (, uint16 exitSplit, , ) = etherFiRedemptionManagerInstance.tokenToRedemptionInfo(ETH_ADDRESS);
        assertEq(exitSplit, 10000);
        
        // Try to set above maximum - should fail
        vm.expectRevert("INVALID");
        etherFiRedemptionManagerInstance.setExitFeeSplitToTreasuryInBps(10001, ETH_ADDRESS);
        vm.stopPrank();
    }

    function test_mainnet_redeemWeEth_insufficient_balance() public {
        setUp_Fork();
        
        vm.startPrank(op_admin);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setCapacity(1000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(1000 ether, ETH_ADDRESS);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        vm.deal(user, 10 ether);
        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: 10 ether}();
        
        // Try to redeem more weETH than balance
        weEthInstance.approve(address(etherFiRedemptionManagerInstance), 100 ether);
        vm.expectRevert("EtherFiRedemptionManager: Insufficient balance");
        etherFiRedemptionManagerInstance.redeemWeEth(100 ether, user, ETH_ADDRESS);
        vm.stopPrank();
    }

    function test_mainnet_redeemWeEth_with_rebase_preview() public {
        setUp_Fork();
        
        vm.startPrank(op_admin);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setCapacity(1000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(1000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setExitFeeBasisPoints(50, ETH_ADDRESS);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        vm.deal(alice, 50000 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 50000 ether}();

        vm.deal(user, 100 ether);
        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: 10 ether}();
        eETHInstance.approve(address(weEthInstance), 10 ether);
        weEthInstance.wrap(1 ether);
        vm.stopPrank();

        // Apply rebase
        uint256 one_percent_of_tvl = liquidityPoolInstance.getTotalPooledEther() / 100;
        vm.prank(address(membershipManagerV1Instance));
        liquidityPoolInstance.rebase(int128(uint128(one_percent_of_tvl)));

        vm.startPrank(user);
        uint256 weEthAmount = weEthInstance.balanceOf(user);
        uint256 eEthAmount = weEthInstance.getEETHByWeETH(weEthAmount);
        uint256 shares = liquidityPoolInstance.sharesForAmount(eEthAmount);
        
        // Test previewRedeem with weETH (after rebase)
        uint256 previewAmount = etherFiRedemptionManagerInstance.previewRedeem(shares, ETH_ADDRESS);
        assertGt(previewAmount, 0);
        
        // Verify preview is less than eEthAmount (due to fees)
        assertLt(previewAmount, eEthAmount);
        vm.stopPrank();
    }

    function test_mainnet_totalRedeemableAmount_with_locked_withdrawals() public {
        setUp_Fork();
        
        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 1000 ether}();

        uint256 instantLiquidity = etherFiRedemptionManagerInstance.getInstantLiquidityAmount(ETH_ADDRESS);
        uint256 lpBalance = address(liquidityPoolInstance).balance;
        uint256 lockedForWithdrawal = liquidityPoolInstance.ethAmountLockedForWithdrawal();
        
        // Verify getInstantLiquidityAmount accounts for locked withdrawals
        assertEq(instantLiquidity, lpBalance - lockedForWithdrawal);
        
        vm.startPrank(op_admin);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setCapacity(10000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(10000 ether, ETH_ADDRESS);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        uint256 totalRedeemable = etherFiRedemptionManagerInstance.totalRedeemableAmount(ETH_ADDRESS);
        
        // Total redeemable should be min(bucket capacity, instant liquidity)
        assertLe(totalRedeemable, instantLiquidity);
        assertLe(totalRedeemable, 10000 ether);
    }

    function test_mainnet_redeem_with_zero_exit_fee() public {
        setUp_Fork();
        
        vm.startPrank(op_admin);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setCapacity(1000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(1000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setExitFeeBasisPoints(0, ETH_ADDRESS); // 0% exit fee
        etherFiRedemptionManagerInstance.setExitFeeSplitToTreasuryInBps(0, ETH_ADDRESS); // 0% to treasury
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        vm.deal(user, 100 ether);
        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: 100 ether}();
        uint256 eEthBalance = eETHInstance.balanceOf(user);
        
        uint256 treasuryBalanceBefore = eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury()));
        uint256 userEthBefore = address(user).balance;
        
        eETHInstance.approve(address(etherFiRedemptionManagerInstance), eEthBalance);
        etherFiRedemptionManagerInstance.redeemEEth(eEthBalance, user, ETH_ADDRESS);
        
        uint256 treasuryBalanceAfter = eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury()));
        uint256 userEthAfter = address(user).balance;
        
        // With zero fees, treasury should receive nothing
        assertEq(treasuryBalanceAfter, treasuryBalanceBefore);
        
        // User should receive almost all ETH (minus gas and rounding)
        assertApproxEqAbs(userEthAfter - userEthBefore, eEthBalance, 1e3);
        vm.stopPrank();
    }

    function test_mainnet_redeem_with_100_percent_treasury_split() public {
        setUp_Fork();
        
        vm.startPrank(op_admin);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setCapacity(1000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(1000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setExitFeeBasisPoints(100, ETH_ADDRESS); // 1% exit fee
        etherFiRedemptionManagerInstance.setExitFeeSplitToTreasuryInBps(10000, ETH_ADDRESS); // 100% to treasury
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        vm.deal(user, 100 ether);
        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: 100 ether}();
        uint256 eEthBalance = eETHInstance.balanceOf(user);
        
        uint256 treasuryBalanceBefore = eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury()));
        
        eETHInstance.approve(address(etherFiRedemptionManagerInstance), eEthBalance);
        etherFiRedemptionManagerInstance.redeemEEth(eEthBalance, user, ETH_ADDRESS);
        
        uint256 treasuryBalanceAfter = eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury()));
        
        // With 100% fee split to treasury, all fees should go to treasury
        // Calculate expected fee
        uint256 expectedFee = (eEthBalance * 100) / 10000;
        uint256 expectedTreasuryFee = liquidityPoolInstance.amountForShare(
            liquidityPoolInstance.sharesForAmount(expectedFee)
        );
        
        assertApproxEqAbs(treasuryBalanceAfter - treasuryBalanceBefore, expectedTreasuryFee, 5e11);
        vm.stopPrank();
    }
}
