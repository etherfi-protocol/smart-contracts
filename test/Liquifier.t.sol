// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "forge-std/Test.sol";

contract LiquifierTest is TestSetup {

    uint256 public testnetFork;

    function setUp() public {
        setUpTests();

        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);

        vm.startPrank(owner);
        liquifierInstance.updateWhitelistedToken(address(stEth), true);
        vm.stopPrank();
    }

    function test_rando_deposit_fails() public {
        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        vm.expectRevert("not allowed");
        payable(address(liquifierInstance)).call{value: 10 ether}("");
        vm.stopPrank();
    }

    function test_deposit_above_cap() public {
        vm.startPrank(0x6D44bfB8432d17882bB6e84652f5C3B36fcC8280);
        cbEth.mint(alice, 100 ether);
        vm.stopPrank();

        vm.deal(alice, 1000 ether);

        assertEq(liquifierInstance.isDepositCapReached(address(stEth), 50 ether), false);
        assertTrue(!liquifierInstance.isDepositCapReached(address(cbEth), 0));
        assertTrue(!liquifierInstance.isDepositCapReached(address(wbEth), 0));

        vm.startPrank(alice);
        stEth.submit{value: 1000 ether}(address(0));
        stEth.approve(address(liquifierInstance), 50 ether);
        liquifierInstance.depositWithERC20(address(stEth), 50 ether, address(0));
        vm.stopPrank();

        _assertWithinRange(liquifierInstance.totalDeposited(address(stEth)), 50 ether, 0.1 ether);
        assertEq(liquifierInstance.isDepositCapReached(address(stEth), 1 ether), true);
        assertTrue(!liquifierInstance.isDepositCapReached(address(cbEth), 1 ether));
        assertTrue(!liquifierInstance.isDepositCapReached(address(wbEth), 1 ether));

        skip(3600);
        assertEq(liquifierInstance.isDepositCapReached(address(stEth), 50 ether), false);

        vm.startPrank(owner);
        liquifierInstance.updateDepositCap(address(stEth), 10, 1000, false);
        vm.stopPrank();

        vm.startPrank(alice);
        stEth.approve(address(liquifierInstance), 10 ether);
        liquifierInstance.depositWithERC20(address(stEth), 10 ether, address(0));
        _assertWithinRange(liquifierInstance.totalDeposited(address(stEth)), 60 ether, 0.1 ether);

        stEth.approve(address(liquifierInstance), 10 ether);
        vm.expectRevert("CapReached");
        liquifierInstance.depositWithERC20(address(stEth), 10 ether, address(0));

        cbEth.approve(address(liquifierInstance), 10 ether);
        liquifierInstance.depositWithERC20(address(cbEth), 10 ether, address(0));

        vm.startPrank(owner);
        liquifierInstance.updateDepositCap(address(stEth), 10, 1000, true);
        vm.stopPrank();

        assertEq(liquifierInstance.isDepositCapReached(address(stEth), 10 ether), false);

        // Set the total cap to 100 ether
        vm.startPrank(owner);
        liquifierInstance.updateDepositCap(address(stEth), 100, 100, true);
        vm.stopPrank();

        // CHeck
        _assertWithinRange(liquifierInstance.totalDeposited(address(stEth)), 60 ether, 0.1 ether);
        assertEq(liquifierInstance.isDepositCapReached(address(stEth), 40 ether), false);
        assertEq(liquifierInstance.isDepositCapReached(address(stEth), 40 ether + 1 ether), true);
    }

    function test_deopsit_cbEth() public {
        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();

        vm.deal(alice, 100 ether);

        assertEq(eETHInstance.balanceOf(alice), 0);
        assertEq(liquifierInstance.getTotalPooledEther(), 0);

        vm.startPrank(0x6D44bfB8432d17882bB6e84652f5C3B36fcC8280);
        cbEth.mint(alice, 20 ether);
        vm.stopPrank();

        vm.startPrank(alice);
        cbEth.approve(address(liquifierInstance), 10 ether);
        liquifierInstance.depositWithERC20(address(cbEth), 10 ether, address(0));

        assertGe(eETHInstance.balanceOf(alice), 10 ether);
        assertGe(liquifierInstance.getTotalPooledEther(), 10 ether);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 10 ether);
        assertEq(address(liquifierInstance).balance, 0 ether);

        liquifierInstance.swapCbEthToEth(10 ether, 10 ether);

        assertGe(liquifierInstance.getTotalPooledEther(), 10 ether);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 10 ether);
        assertGe(address(liquifierInstance).balance, 10 ether);
    }

    function test_deopsit_wBEth() public {
        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();
        uint256 lpBalance = address(liquidityPoolInstance).balance;

        vm.deal(alice, 100 ether);

        assertEq(eETHInstance.balanceOf(alice), 0);
        assertEq(liquifierInstance.getTotalPooledEther(), 0);

        vm.startPrank(alice);
        wbEth.deposit{value: 20 ether}(address(0));
        wbEth.approve(address(liquifierInstance), 10 ether);
        liquifierInstance.depositWithERC20(address(wbEth), 10 ether, address(0));

        assertGe(eETHInstance.balanceOf(alice), 10 ether);
        assertGe(liquifierInstance.getTotalPooledEther(), 10 ether);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 10 ether);
        assertEq(address(liquifierInstance).balance, 0 ether);

        liquifierInstance.swapWbEthToEth(10 ether, 10 ether);

        assertGe(liquifierInstance.getTotalPooledEther(), 10 ether);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 10 ether);
        assertGe(address(liquifierInstance).balance, 10 ether);
    }

    function test_deopsit_stEth_and_swap() public {
        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();
        vm.deal(alice, 100 ether);

        assertEq(eETHInstance.balanceOf(alice), 0);
        assertEq(liquifierInstance.getTotalPooledEther(), 0);

        vm.startPrank(alice);
        stEth.submit{value: 20 ether}(address(0));
        stEth.approve(address(liquifierInstance), 10 ether);
        liquifierInstance.depositWithERC20(address(stEth), 10 ether, address(0));

        assertGe(eETHInstance.balanceOf(alice), 10 ether - 0.1 ether);
        assertGe(liquifierInstance.getTotalPooledEther(), 10 ether - 0.1 ether);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 10 ether - 0.1 ether);
        assertEq(address(liquifierInstance).balance, 0 ether);

        lpTvl = liquidityPoolInstance.getTotalPooledEther();

        liquifierInstance.swapStEthToEth(1 ether, 1 ether  - 0.01 ether);

        assertGe(liquifierInstance.getTotalPooledEther(), 1 ether - 0.01 ether);
        assertGe(address(liquifierInstance).balance, 1 ether - 0.01 ether);
        _assertWithinRange(liquidityPoolInstance.getTotalPooledEther(), lpTvl, 0.001 ether);

        lpTvl = liquidityPoolInstance.getTotalPooledEther();

        liquifierInstance.withdrawEther();

        assertEq(liquidityPoolInstance.getTotalPooledEther(), lpTvl);
        _assertWithinRange(liquifierInstance.getTotalPooledEther(), 0, 0.000001 ether);
    }

    function test_deopsit_stEth_with_discount() public {
        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();
        uint256 lpBalance = address(liquidityPoolInstance).balance;

        vm.startPrank(owner);
        liquifierInstance.updateDiscountInBasisPoints(address(stEth), 5000); // discount by -50%
        vm.stopPrank();

        vm.deal(alice, 100 ether);

        assertEq(eETHInstance.balanceOf(alice), 0);
        assertEq(liquifierInstance.getTotalPooledEther(), 0);

        vm.startPrank(alice);

        stEth.submit{value: 20 ether}(address(0));
        stEth.approve(address(liquifierInstance), 20 ether);
        liquifierInstance.depositWithERC20(address(stEth), 20 ether, address(0));

        assertLe(eETHInstance.balanceOf(alice), 10 ether);
        assertGe(liquifierInstance.getTotalPooledEther(), 20 ether - 10);
        assertLe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 10 ether );
    }

    function test_deopsit_stEth_with_explicit_permit() public {
        vm.deal(alice, 100 ether);

        assertEq(eETHInstance.balanceOf(alice), 0);
        assertEq(liquifierInstance.getTotalPooledEther(), 0);

        vm.startPrank(alice);
        
        // Alice minted 2000 stETH
        stEth.submit{value: 20 ether}(address(0));

        // But, she noticed that eETH is a much better choice 
        // and decided to convert her stETH to eETH
        
        // Deposit 1000 stETH after approvals
        stEth.approve(address(liquifierInstance), 10 ether - 1);
        vm.expectRevert("ALLOWANCE_EXCEEDED");
        liquifierInstance.depositWithERC20(address(stEth), 10 ether, address(0));

        stEth.approve(address(liquifierInstance), 10 ether);
        liquifierInstance.depositWithERC20(address(stEth), 10 ether, address(0));

        // Deposit 1000 stETH with the approval signature
        ILiquidityPool.PermitInput memory permitInput = createPermitInput(2, address(liquifierInstance), 10 ether - 1, stEth.nonces(alice), 2**256 - 1, stEth.DOMAIN_SEPARATOR());
        ILiquifier.PermitInput memory permitInput2 = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});
        vm.expectRevert("ALLOWANCE_EXCEEDED");
        liquifierInstance.depositWithERC20WithPermit(address(stEth), 10 ether, address(0), permitInput2);

        permitInput = createPermitInput(2, address(liquifierInstance), 10 ether, stEth.nonces(alice), 2**256 - 1, stEth.DOMAIN_SEPARATOR());
        permitInput2 = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});
        liquifierInstance.depositWithERC20WithPermit(address(stEth), 10 ether, address(0), permitInput2);
    }

    function test_withdrawal_of_non_restaked_stEth() public {
        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();
        uint256 lpBalance = address(liquidityPoolInstance).balance;

        assertEq(eETHInstance.balanceOf(alice), 0);
        assertEq(liquifierInstance.getTotalPooledEther(), 0);

        vm.deal(alice, 100 ether);
        vm.startPrank(alice);        
        stEth.submit{value: 10 ether}(address(0));
        
        ILiquidityPool.PermitInput memory permitInput = createPermitInput(2, address(liquifierInstance), 10 ether, stEth.nonces(alice), 2**256 - 1, stEth.DOMAIN_SEPARATOR());
        ILiquifier.PermitInput memory permitInput2 = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});
        liquifierInstance.depositWithERC20WithPermit(address(stEth), 10 ether, address(0), permitInput2);

        // Aliice has 10 ether eETH
        // Total eETH TVL is 10 ether
        assertGe(eETHInstance.balanceOf(alice), 10 ether - 0.1 ether);
        assertGe(liquifierInstance.getTotalPooledEther(), 10 ether - 0.1 ether);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 10 ether - 0.1 ether);

        // The protocol admin initiates the redemption process for 3500 stETH
        uint256[] memory reqIds = liquifierInstance.stEthRequestWithdrawal();
        vm.stopPrank();

        assertGe(eETHInstance.balanceOf(alice), 10 ether - 0.1 ether);
        assertGe(liquifierInstance.getTotalPooledEther(), 10 ether - 0.1 ether);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 10 ether - 0.1 ether);

        bytes32 FINALIZE_ROLE = liquifierInstance.lidoWithdrawalQueue().FINALIZE_ROLE();
        address finalize_role = liquifierInstance.lidoWithdrawalQueue().getRoleMember(FINALIZE_ROLE, 0);

        // The redemption is approved by the Lido
        vm.startPrank(finalize_role);
        uint256 currentRate = stEth.getTotalPooledEther() * 1e27 / stEth.getTotalShares();
        (uint256 ethToLock, uint256 sharesToBurn) = liquifierInstance.lidoWithdrawalQueue().prefinalize(reqIds, currentRate);
        liquifierInstance.lidoWithdrawalQueue().finalize(reqIds[reqIds.length-1], currentRate);
        vm.stopPrank();

        assertGe(eETHInstance.balanceOf(alice), 10 ether - 0.1 ether);
        assertGe(liquifierInstance.getTotalPooledEther(), 10 ether - 0.1 ether);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 10 ether - 0.1 ether);

        // The ether.fi admin claims the finalized withdrawal, which sends the ETH to the liquifier contract
        vm.startPrank(alice);
        uint256 lastCheckPointIndex = liquifierInstance.lidoWithdrawalQueue().getLastCheckpointIndex();
        uint256[] memory hints = liquifierInstance.lidoWithdrawalQueue().findCheckpointHints(reqIds, 1, lastCheckPointIndex);
        liquifierInstance.stEthClaimWithdrawals(reqIds, hints);

        assertGe(eETHInstance.balanceOf(alice), 10 ether - 0.1 ether);
        assertGe(liquifierInstance.getTotalPooledEther(), 10 ether - 0.1 ether);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 10 ether - 0.1 ether);
        assertGe(address(liquidityPoolInstance).balance, lpBalance - 0.1 ether);

        // The ether.fi admin withdraws the ETH from the liquifier contract to the liquidity pool contract
        liquifierInstance.withdrawEther();
        vm.stopPrank();

        // the cycle completes
        assertGe(eETHInstance.balanceOf(alice), 10 ether - 0.1 ether);
        assertEq(liquifierInstance.getTotalPooledEther() / 100, 0);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 10 ether - 0.1 ether);
        assertGe(address(liquidityPoolInstance).balance + liquifierInstance.getTotalPooledEther(), lpBalance + 10 ether - 0.1 ether);
    }

    function _enable_deposit(address _strategy) internal {
        IEigenLayerStrategyTVLLimits strategyTVLLimits = IEigenLayerStrategyTVLLimits(_strategy);

        address role = strategyTVLLimits.pauserRegistry().unpauser();
        vm.startPrank(role);
        eigenLayerStrategyManager.unpause(0);
        strategyTVLLimits.unpause(0);
        strategyTVLLimits.setTVLLimits(1_000_000_0 ether, 1_000_000_0 ether);
        vm.stopPrank();
    }

    function _complete_queued_withdrawal(IStrategyManager.DeprecatedStruct_QueuedWithdrawal memory queuedWithdrawal, IStrategy strategy) internal {
        vm.roll(block.number + eigenLayerDelayedWithdrawalRouter.withdrawalDelayBlocks());

        IStrategyManager.DeprecatedStruct_QueuedWithdrawal[] memory queuedWithdrawals = new IStrategyManager.DeprecatedStruct_QueuedWithdrawal[](1);
        queuedWithdrawals[0] = queuedWithdrawal;
        IERC20[][] memory tokens = new IERC20[][](1);
        tokens[0] = new IERC20[](1);
        tokens[0][0] = strategy.underlyingToken();
        uint256[] memory middlewareTimesIndexes = new uint256[](1);
        middlewareTimesIndexes[0] = 0;
        liquifierInstance.completeQueuedWithdrawals(queuedWithdrawals, tokens, middlewareTimesIndexes);

        vm.expectRevert();
        liquifierInstance.completeQueuedWithdrawals(queuedWithdrawals, tokens, middlewareTimesIndexes);
    }

}
