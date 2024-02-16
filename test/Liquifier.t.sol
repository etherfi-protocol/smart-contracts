// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "forge-std/Test.sol";

contract LiquifierTest is TestSetup {

    uint256 public testnetFork;

    function setUp() public {
        setUpTests();

        initializeRealisticFork(MAINNET_FORK);

        vm.startPrank(owner);
        liquifierInstance.updateWhitelistedToken(address(stEth), true);
        vm.stopPrank();
    }

    function test_rando_deposit_fails() public {
        vm.deal(alice, 10000 ether);
        vm.startPrank(alice);
        vm.expectRevert("not allowed");
        payable(address(liquifierInstance)).call{value: 1000 ether}("");
        vm.stopPrank();
    }

    function test_deposit_above_cap() public {
        vm.deal(alice, 10000 ether);

        vm.startPrank(alice);
        stEth.submit{value: 10000 ether}(address(0));

        assertEq(liquifierInstance.isDepositCapReached(5000 ether), false);
        stEth.approve(address(liquifierInstance), 5000 ether);
        liquifierInstance.depositWithERC20(address(stEth), 5000 ether, address(0));
        assertEq(liquifierInstance.isDepositCapReached(1 ether), true);

        skip(3600);
        assertEq(liquifierInstance.isDepositCapReached(5000 ether), false);
    }

    function test_deopsit_cbEth() public {
        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();

        vm.deal(alice, 10000 ether);

        assertEq(eETHInstance.balanceOf(alice), 0);
        assertEq(liquifierInstance.getTotalPooledEther(), 0);

        vm.startPrank(0x6D44bfB8432d17882bB6e84652f5C3B36fcC8280);
        cbEth.mint(alice, 2000 ether);
        vm.stopPrank();

        vm.startPrank(alice);
        cbEth.approve(address(liquifierInstance), 1000 ether);
        liquifierInstance.depositWithERC20(address(cbEth), 1000 ether, address(0));

        assertGe(eETHInstance.balanceOf(alice), 1000 ether);
        assertGe(liquifierInstance.getTotalPooledEther(), 1000 ether);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 1000 ether);
        assertEq(address(liquifierInstance).balance, 0 ether);

        liquifierInstance.swapCbEthToEth(100 ether, 100 ether);

        assertGe(liquifierInstance.getTotalPooledEther(), 100 ether);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 1000 ether);
        assertGe(address(liquifierInstance).balance, 100 ether);
    }

    function test_deopsit_wBEth() public {
        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();
        uint256 lpBalance = address(liquidityPoolInstance).balance;

        vm.deal(alice, 10000 ether);

        assertEq(eETHInstance.balanceOf(alice), 0);
        assertEq(liquifierInstance.getTotalPooledEther(), 0);

        vm.startPrank(alice);
        wbEth.deposit{value: 2000 ether}(address(0));
        wbEth.approve(address(liquifierInstance), 1000 ether);
        liquifierInstance.depositWithERC20(address(wbEth), 1000 ether, address(0));

        assertGe(eETHInstance.balanceOf(alice), 1000 ether);
        assertGe(liquifierInstance.getTotalPooledEther(), 1000 ether);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 1000 ether);
        assertEq(address(liquifierInstance).balance, 0 ether);

        liquifierInstance.swapWbEthToEth(100 ether, 100 ether);

        assertGe(liquifierInstance.getTotalPooledEther(), 100 ether);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 1000 ether);
        assertGe(address(liquifierInstance).balance, 100 ether);
    }

    function test_deopsit_stEth_with_explicit_permit() public {
        vm.deal(alice, 10000 ether);

        assertEq(eETHInstance.balanceOf(alice), 0);
        assertEq(liquifierInstance.getTotalPooledEther(), 0);

        vm.startPrank(alice);
        
        // Alice minted 2000 stETH
        stEth.submit{value: 2000 ether}(address(0));

        // But, she noticed that eETH is a much better choice 
        // and decided to convert her stETH to eETH
        
        // Deposit 1000 stETH after approvals
        stEth.approve(address(liquifierInstance), 1000 ether - 1);
        vm.expectRevert("ALLOWANCE_EXCEEDED");
        liquifierInstance.depositWithERC20(address(stEth), 1000 ether, address(0));

        stEth.approve(address(liquifierInstance), 1000 ether);
        liquifierInstance.depositWithERC20(address(stEth), 1000 ether, address(0));

        // Deposit 1000 stETH with the approval signature
        ILiquidityPool.PermitInput memory permitInput = createPermitInput(2, address(liquifierInstance), 1000 ether - 1, stEth.nonces(alice), 2**256 - 1, stEth.DOMAIN_SEPARATOR());
        ILiquifier.PermitInput memory permitInput2 = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});
        vm.expectRevert("ALLOWANCE_EXCEEDED");
        liquifierInstance.depositWithERC20WithPermit(address(stEth), 1000 ether, address(0), permitInput2);

        permitInput = createPermitInput(2, address(liquifierInstance), 1000 ether, stEth.nonces(alice), 2**256 - 1, stEth.DOMAIN_SEPARATOR());
        permitInput2 = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});
        liquifierInstance.depositWithERC20WithPermit(address(stEth), 1000 ether, address(0), permitInput2);
    }

    function test_withdrawal_of_non_restaked_stEth() public {
        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();
        uint256 lpBalance = address(liquidityPoolInstance).balance;

        assertEq(eETHInstance.balanceOf(alice), 0);
        assertEq(liquifierInstance.getTotalPooledEther(), 0);

        vm.deal(alice, 10000 ether);
        vm.startPrank(alice);        
        stEth.submit{value: 3500 ether}(address(0));
        
        ILiquidityPool.PermitInput memory permitInput = createPermitInput(2, address(liquifierInstance), 3500 ether, stEth.nonces(alice), 2**256 - 1, stEth.DOMAIN_SEPARATOR());
        ILiquifier.PermitInput memory permitInput2 = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});
        liquifierInstance.depositWithERC20WithPermit(address(stEth), 3500 ether, address(0), permitInput2);

        // Aliice has 3500 ether eETH
        // Total eETH TVL is 3500 ether
        assertEq(eETHInstance.balanceOf(alice), 3500 ether - 2);
        assertEq(liquifierInstance.getTotalPooledEther(), 3500 ether - 1);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 3500 ether - 1);

        // The protocol admin initiates the redemption process for 3500 stETH
        uint256[] memory reqIds = liquifierInstance.stEthRequestWithdrawal();
        vm.stopPrank();

        assertEq(eETHInstance.balanceOf(alice), 3500 ether - 2);
        assertEq(liquifierInstance.getTotalPooledEther(), 3500 ether);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 3500 ether - 1);

        bytes32 FINALIZE_ROLE = liquifierInstance.lidoWithdrawalQueue().FINALIZE_ROLE();
        address finalize_role = liquifierInstance.lidoWithdrawalQueue().getRoleMember(FINALIZE_ROLE, 0);

        // The redemption is approved by the Lido
        vm.startPrank(finalize_role);
        uint256 currentRate = stEth.getTotalPooledEther() * 1e27 / stEth.getTotalShares();
        (uint256 ethToLock, uint256 sharesToBurn) = liquifierInstance.lidoWithdrawalQueue().prefinalize(reqIds, currentRate);
        liquifierInstance.lidoWithdrawalQueue().finalize(reqIds[reqIds.length-1], currentRate);
        vm.stopPrank();

        assertEq(eETHInstance.balanceOf(alice), 3500 ether - 2);
        assertEq(liquifierInstance.getTotalPooledEther(), 3500 ether);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 3500 ether - 1);

        // The ether.fi admin claims the finalized withdrawal, which sends the ETH to the liquifier contract
        vm.startPrank(alice);
        uint256 lastCheckPointIndex = liquifierInstance.lidoWithdrawalQueue().getLastCheckpointIndex();
        uint256[] memory hints = liquifierInstance.lidoWithdrawalQueue().findCheckpointHints(reqIds, 1, lastCheckPointIndex);
        liquifierInstance.stEthClaimWithdrawals(reqIds, hints);

        assertEq(eETHInstance.balanceOf(alice), 3500 ether - 2);
        assertEq(liquifierInstance.getTotalPooledEther(), 3500 ether);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 3500 ether - 1);
        assertEq(address(liquidityPoolInstance).balance, lpBalance);

        // The ether.fi admin withdraws the ETH from the liquifier contract to the liquidity pool contract
        liquifierInstance.withdrawEther();
        vm.stopPrank();

        // the cycle completes
        assertEq(eETHInstance.balanceOf(alice), 3500 ether - 2);
        assertEq(liquifierInstance.getTotalPooledEther() / 10, 0);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 3500 ether - 1);
        assertEq(address(liquidityPoolInstance).balance + liquifierInstance.getTotalPooledEther(), lpBalance + 3500 ether);
    }

    function test_withdrawal_of_restaked_stEth_fails_wrong_withdrawer() public {
        IEigenLayerStrategyTVLLimits stEthStrategyTVLLimits = IEigenLayerStrategyTVLLimits(address(stEthStrategy));
        _enable_deposit(address(stEthStrategy));

        vm.deal(alice, 10000 ether);
        vm.startPrank(alice);        
        stEth.submit{value: 1000 ether}(address(0));

        stEth.approve(address(eigenLayerStrategyManager), 1000 ether);
        uint256 shareAmount = eigenLayerStrategyManager.depositIntoStrategy(stEthStrategy, stEthStrategy.underlyingToken(), 1000 ether);

        uint256[] memory strategyIndexes = new uint256[](1);
        IStrategy[] memory strategies = new IStrategy[](1);
        uint256[] memory shares = new uint256[](1);
        strategyIndexes[0] = 0;
        strategies[0] = stEthStrategy;
        shares[0] = stEthStrategy.shares(alice);
        bytes32 withdrawalRoot = eigenLayerStrategyManager.queueWithdrawal(strategyIndexes, strategies, shares, alice, true);

        IStrategyManager.QueuedWithdrawal memory queuedWithdrawal = IStrategyManager.QueuedWithdrawal({
            strategies: strategies,
            shares: shares,
            depositor: alice,
            withdrawerAndNonce: IStrategyManager.WithdrawerAndNonce({
                withdrawer: alice,
                nonce: 0
            }),
            withdrawalStartBlock: 0,
            delegatedAddress: address(0)
        });
        vm.expectRevert("withdrawer != liquifier");
        liquifierInstance.depositWithQueuedWithdrawal(queuedWithdrawal, address(0));
    }

    function _enable_deposit(address _strategy) internal {
        IEigenLayerStrategyTVLLimits strategyTVLLimits = IEigenLayerStrategyTVLLimits(_strategy);

        address role = strategyTVLLimits.pauserRegistry().unpauser();
        vm.startPrank(role);
        eigenLayerStrategyManager.unpause(0);
        strategyTVLLimits.unpause(0);
        strategyTVLLimits.setTVLLimits(1_000_000_000 ether, 1_000_000_000 ether);
        vm.stopPrank();
    }

    function _deposit_restaked_LST(address _strategy) internal returns (IStrategyManager.QueuedWithdrawal memory) {
        IStrategy strategy = IStrategy(_strategy);

        uint256[] memory strategyIndexes = new uint256[](1);
        IStrategy[] memory strategies = new IStrategy[](1);
        uint256[] memory shares = new uint256[](1);
        strategyIndexes[0] = 0;
        strategies[0] = strategy;
        shares[0] = strategy.shares(alice);
        
        uint32 blockNumber = uint32(block.number);
        IStrategyManager.WithdrawerAndNonce memory withdrawerAndNonce = IStrategyManager.WithdrawerAndNonce({
                                                                            withdrawer: address(liquifierInstance),
                                                                            nonce: uint96(eigenLayerStrategyManager.numWithdrawalsQueued(alice))
                                                                        });
        
        bytes32 withdrawalRoot = eigenLayerStrategyManager.queueWithdrawal(strategyIndexes, strategies, shares, address(liquifierInstance), true);
        assertEq(eigenLayerStrategyManager.withdrawalRootPending(withdrawalRoot), true);

        IStrategyManager.QueuedWithdrawal memory queuedWithdrawal = IStrategyManager.QueuedWithdrawal({
            strategies: strategies,
            shares: shares,
            depositor: alice,
            withdrawerAndNonce: withdrawerAndNonce,
            withdrawalStartBlock: blockNumber,
            delegatedAddress: address(0)
        });
        liquifierInstance.depositWithQueuedWithdrawal(queuedWithdrawal, address(0));

        // multipme mints using the same queued withdrawal fails
        vm.expectRevert("already deposited");
        liquifierInstance.depositWithQueuedWithdrawal(queuedWithdrawal, address(0));

        return queuedWithdrawal;
    }

    function _complete_queued_withdrawal(IStrategyManager.QueuedWithdrawal memory queuedWithdrawal, IStrategy strategy) internal {
        vm.roll(block.number + eigenLayerStrategyManager.withdrawalDelayBlocks());

        IStrategyManager.QueuedWithdrawal[] memory queuedWithdrawals = new IStrategyManager.QueuedWithdrawal[](1);
        queuedWithdrawals[0] = queuedWithdrawal;
        IERC20[][] memory tokens = new IERC20[][](1);
        tokens[0] = new IERC20[](1);
        tokens[0][0] = strategy.underlyingToken();
        uint256[] memory middlewareTimesIndexes = new uint256[](1);
        middlewareTimesIndexes[0] = 0;
        liquifierInstance.completeQueuedWithdrawals(queuedWithdrawals, tokens, middlewareTimesIndexes);
    }

    function test_withdrawal_of_restaked_stEth_succeeds() public {
        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();
        _enable_deposit(address(stEthStrategy));

        vm.deal(alice, 10000 ether);
        vm.startPrank(alice);        
        stEth.submit{value: 1000 ether}(address(0));

        stEth.approve(address(eigenLayerStrategyManager), 1000 ether);
        eigenLayerStrategyManager.depositIntoStrategy(stEthStrategy, stEthStrategy.underlyingToken(), 1000 ether);

        IStrategyManager.QueuedWithdrawal memory queuedWithdrawal = _deposit_restaked_LST(address(stEthStrategy));
        uint256 fee_charge = 1 * liquifierInstance.getFeeAmount();

        assertEq(eETHInstance.balanceOf(alice), liquifierInstance.getTotalPooledEther() - 1);
        assertEq(eETHInstance.balanceOf(alice), 1000 ether - fee_charge - 2);
        assertEq(liquifierInstance.getTotalPooledEther(), 1000 ether - fee_charge - 1);
        assertEq(stEth.balanceOf(address(liquifierInstance)), 0);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 1000 ether - 1 - fee_charge);

        _complete_queued_withdrawal(queuedWithdrawal, stEthStrategy);
        assertEq(stEth.balanceOf(address(liquifierInstance)), 1000 ether - 2);
        assertGe(liquifierInstance.getTotalPooledEther(), 1000 ether - fee_charge - 2);
    }

    function test_withdrawal_of_restaked_wbEth_succeeds() public {
        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();
        _enable_deposit(address(wbEthStrategy));

        vm.deal(alice, 10000 ether);
        vm.startPrank(alice);        
        wbEth.deposit{value: 2000 ether}(address(0));

        wbEth.approve(address(eigenLayerStrategyManager), 2000 ether);
        uint256 shareAmount = eigenLayerStrategyManager.depositIntoStrategy(wbEthStrategy, wbEthStrategy.underlyingToken(), 1000 ether);

        IStrategyManager.QueuedWithdrawal memory queuedWithdrawal = _deposit_restaked_LST(address(wbEthStrategy));
        uint256 fee_charge = 1 * liquifierInstance.getFeeAmount();

        assertEq(eETHInstance.balanceOf(alice), liquifierInstance.getTotalPooledEther() - 1);
        assertGe(eETHInstance.balanceOf(alice), 1000 ether - fee_charge);
        assertGe(liquifierInstance.getTotalPooledEther(), 1000 ether - fee_charge);
        assertEq(wbEth.balanceOf(address(liquifierInstance)), 0);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 1000 ether - fee_charge);

        _complete_queued_withdrawal(queuedWithdrawal, wbEthStrategy);
        assertEq(wbEth.balanceOf(address(liquifierInstance)), 1000 ether);
        assertGe(liquifierInstance.getTotalPooledEther(), 1000 ether - fee_charge - 2);
    }

    function test_withdrawal_of_restaked_cbEth_succeeds() public {
        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();
        _enable_deposit(address(cbEthStrategy));

        vm.startPrank(0x6D44bfB8432d17882bB6e84652f5C3B36fcC8280);
        cbEth.mint(alice, 2000 ether);
        vm.stopPrank();

        vm.deal(alice, 10000 ether);
        vm.startPrank(alice);        
        
        cbEth.approve(address(eigenLayerStrategyManager), 2000 ether);
        uint256 shareAmount = eigenLayerStrategyManager.depositIntoStrategy(cbEthStrategy, cbEthStrategy.underlyingToken(), 1000 ether);

        IStrategyManager.QueuedWithdrawal memory queuedWithdrawal = _deposit_restaked_LST(address(cbEthStrategy));
        uint256 fee_charge = 1 * liquifierInstance.getFeeAmount();

        assertEq(eETHInstance.balanceOf(alice), liquifierInstance.getTotalPooledEther() - 1);
        assertGe(eETHInstance.balanceOf(alice), 1000 ether - fee_charge);
        assertGe(liquifierInstance.getTotalPooledEther(), 1000 ether - fee_charge);
        assertEq(cbEth.balanceOf(address(liquifierInstance)), 0);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 1000 ether - fee_charge);

        _complete_queued_withdrawal(queuedWithdrawal, cbEthStrategy);
        assertEq(cbEth.balanceOf(address(liquifierInstance)), 1000 ether - 1);
        assertGe(liquifierInstance.getTotalPooledEther(), 1000 ether - fee_charge - 1);
    }

}
