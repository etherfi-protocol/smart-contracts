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
        LiquidityPool liquidityPoolImpl = new LiquidityPool();
        liquidityPoolInstance.upgradeTo(payable(address(liquidityPoolImpl)));
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

        vm.deal(alice, 100000 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 100000 ether}();

        vm.deal(user, 2010 ether);
        vm.startPrank(user);

        liquidityPoolInstance.deposit{value: 2005 ether}();

        uint256 redeemableAmount = etherFiRedemptionManagerInstance.totalRedeemableAmount(ETH_ADDRESS);
        uint256 userBalance = address(user).balance;
        uint256 treasuryBalance = eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury()));

        eETHInstance.approve(address(etherFiRedemptionManagerInstance), 2000 ether);
        etherFiRedemptionManagerInstance.redeemEEth(2000 ether, user, ETH_ADDRESS);

        uint256 totalFee = (2000 ether * 1e2) / 1e4;
        uint256 treasuryFee = (totalFee * 1e3) / 1e4;
        uint256 userReceives = 2000 ether - totalFee;

        assertApproxEqAbs(eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury())), treasuryBalance + treasuryFee, 1e1);
        assertApproxEqAbs(address(user).balance, userBalance + userReceives, 1e1);

        eETHInstance.approve(address(etherFiRedemptionManagerInstance), 1 ether);
        vm.expectRevert("EtherFiRedemptionManager: Exceeded total redeemable amount");
        etherFiRedemptionManagerInstance.redeemEEth(1 ether, user, ETH_ADDRESS);

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
        uint256 eEthAmount = liquidityPoolInstance.amountForShare(weEthAmount);
        uint256 userBalance = address(user).balance;
        uint256 treasuryBalance = eETHInstance.balanceOf(address(treasuryInstance));
        weEthInstance.approve(address(etherFiRedemptionManagerInstance), 1 ether);
        etherFiRedemptionManagerInstance.redeemWeEth(weEthAmount, user, ETH_ADDRESS);
        
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
        vm.stopPrank();
        
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
        console2.log("redeemableAmount", redeemableAmount);
        uint256 userBalance = address(user).balance;
        uint256 treasuryBalance = eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury()));

        eETHInstance.approve(address(etherFiRedemptionManagerInstance), 2000 ether);
        etherFiRedemptionManagerInstance.redeemEEth(2000 ether, user, address(etherFiRestakerInstance.lido()));

        redeemableAmount = etherFiRedemptionManagerInstance.totalRedeemableAmount(address(etherFiRestakerInstance.lido()));
        console2.log("redeemableAmount", redeemableAmount);

        uint256 totalFee = (2000 ether * 1e2) / 1e4;
        uint256 treasuryFee = (totalFee * 1e3) / 1e4;
        uint256 userReceives = 2000 ether - totalFee;
        assertApproxEqAbs(eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury())), treasuryBalance + treasuryFee, 1e1);
        assertApproxEqAbs(stEth.balanceOf(user), userReceives, 1e1);

        eETHInstance.approve(address(etherFiRedemptionManagerInstance), 1 ether);
        address lidoToken = address(etherFiRestakerInstance.lido()); // external call; fetch before expectRevert
        vm.expectRevert("EtherFiRedemptionManager: Exceeded total redeemable amount");
        etherFiRedemptionManagerInstance.redeemEEth(1 ether, user, lidoToken);

        vm.stopPrank();
    }

    function test_mainnet_redeem_weEth_with_rebase() public {
        setUp_Fork();
        
        vm.startPrank(op_admin);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, address(etherFiRestakerInstance.lido()));
        vm.stopPrank();

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
        uint256 eEthAmount = liquidityPoolInstance.amountForShare(weEthAmount);
        uint256 userBalance = address(user).balance;
        uint256 treasuryBalance = eETHInstance.balanceOf(address(treasuryInstance));
        weEthInstance.approve(address(etherFiRedemptionManagerInstance), 1 ether);
        etherFiRedemptionManagerInstance.redeemWeEth(weEthAmount, user, address(etherFiRestakerInstance.lido()));
        
        uint256 totalFee = (eEthAmount * 1e2) / 1e4;
        uint256 treasuryFee = (totalFee * 1e3) / 1e4;
        uint256 userReceives = eEthAmount - totalFee;
        
        assertApproxEqAbs(eETHInstance.balanceOf(address(treasuryInstance)), treasuryBalance + treasuryFee, 1e1);
        assertApproxEqAbs(stEth.balanceOf(user), userReceives, 1e1);

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
        //get number of shares for 1 ether
        uint256 sharesFor_999_ether = liquidityPoolInstance.sharesForAmount(0.999 ether); // should be 0.9 ether since 0.1 ether is left for 
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
        assertApproxEqAbs(stethBalanceAfter - stethBalanceBefore, 0.99 ether, 3);
        assertApproxEqAbs(totalSharesBefore - totalSharesAfter, sharesFor_999_ether, 1);
        assertApproxEqAbs(totalValueOutOfLpBefore - totalValueOutOfLpAfter, 0.99 ether, 3);
        assertEq(totalValueInLpAfter- totalValueInLpBefore, 0);
        assertApproxEqAbs(treasuryBalanceAfter-treasuryBalanceBefore, 0.001 ether, 3);
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
        uint256 sharesFor_999_ether = liquidityPoolInstance.sharesForAmount(0.999 ether); // should be 0.9 ether since 0.1 ether is left for 
        uint256 totalValueOutOfLpBefore = liquidityPoolInstance.totalValueOutOfLp();
        uint256 totalValueInLpBefore = liquidityPoolInstance.totalValueInLp();
        uint256 totalSharesBefore = eETHInstance.totalShares();
        uint256 treasuryBalanceBefore = eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury()));
        uint256 ethBalanceBefore = address(user).balance;
        etherFiRedemptionManagerInstance.redeemEEth(1 ether, user, ETH_ADDRESS);
        uint256 ethBalanceAfter = address(user).balance;
        uint256 totalSharesAfter = eETHInstance.totalShares();
        uint256 totalValueOutOfLpAfter = liquidityPoolInstance.totalValueOutOfLp();
        uint256 totalValueInLpAfter = liquidityPoolInstance.totalValueInLp();
        uint256 treasuryBalanceAfter = eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury()));
        assertApproxEqAbs(ethBalanceAfter - ethBalanceBefore, 0.99 ether, 2);
        assertApproxEqAbs(totalSharesBefore - totalSharesAfter, sharesFor_999_ether, 1);
        assertApproxEqAbs(totalValueInLpBefore - totalValueInLpAfter, 0.99 ether, 2);
        assertEq(totalValueOutOfLpAfter- totalValueOutOfLpBefore, 0);
        assertApproxEqAbs(treasuryBalanceAfter-treasuryBalanceBefore, 0.001 ether, 2);
        vm.stopPrank();
    }
}
