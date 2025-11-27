// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "forge-std/Test.sol";

import "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";

import "../src/eigenlayer-interfaces/IDelegationManager.sol";
import "../src/eigenlayer-interfaces/IStrategyManager.sol";
import "../src/eigenlayer-interfaces/ISignatureUtils.sol";


contract EtherFiRestakerTest is TestSetup {

    address avsOperator;
    address avsOperator2;
    address etherfiOperatingAdmin;

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);

        test_upgrade();

        // setUpLiquifier(MAINNET_FORK);

        avsOperator = 0x5ACCC90436492F24E6aF278569691e2c942A676d; // EigenYields
        avsOperator2 = 0xfB487f216CA24162119C0C6Ae015d680D7569C2f;
        etherfiOperatingAdmin = alice; //

        vm.prank(owner);
        liquifierInstance.updateQuoteStEthWithCurve(false);
    }

    function _deposit_stEth(uint256 _amount) internal {
        uint256 restakerTvl = etherFiRestakerInstance.getTotalPooledEther();
        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();
        uint256 lpBalance = address(liquidityPoolInstance).balance;
        uint256 aliceStEthBalance = stEth.balanceOf(alice);
        uint256 aliceEEthBalance = eETHInstance.balanceOf(alice);

        vm.deal(alice, _amount);
        vm.startPrank(alice);        
        stEth.submit{value: _amount}(address(0));

        stEth.approve(address(liquifierInstance), _amount);

        liquifierInstance.depositWithERC20(address(stEth), _amount, address(0));


        // Aliice has 10 ether eETH
        // Total eETH TVL is 10 ether
        assertApproxEqAbs(stEth.balanceOf(alice), aliceStEthBalance, 2 wei);
        assertApproxEqAbs(eETHInstance.balanceOf(alice), aliceEEthBalance + _amount, 2 wei);
        assertApproxEqAbs(etherFiRestakerInstance.getTotalPooledEther(), restakerTvl + _amount, 2 wei);
        assertApproxEqAbs(liquidityPoolInstance.getTotalPooledEther(), lpTvl + _amount, 2 wei);
        vm.stopPrank();
    }

    function test_withdrawal_of_non_restaked_stEth() public {
        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();
        uint256 lpBalance = address(liquidityPoolInstance).balance;
        uint256 currentEtherFiRestakerTotalPooledEther = etherFiRestakerInstance.getTotalPooledEther();
        uint256 currentStEthBalance = stEth.balanceOf(address(etherFiRestakerInstance));
        uint256 amount = 10 ether;

        _deposit_stEth(amount);

        assertEq(etherFiRestakerInstance.getAmountPendingForRedemption(address(stEth)), 0);

        vm.startPrank(owner);
        uint256 stEthBalance = stEth.balanceOf(address(etherFiRestakerInstance)) - currentStEthBalance;
        uint256[] memory reqIds = etherFiRestakerInstance.stEthRequestWithdrawal(stEthBalance);
        vm.stopPrank();
        
        assertApproxEqAbs(etherFiRestakerInstance.getAmountPendingForRedemption(address(stEth)), amount, 2 wei);
        assertApproxEqAbs(etherFiRestakerInstance.getTotalPooledEther(), currentEtherFiRestakerTotalPooledEther + amount, 2 wei);
        assertApproxEqAbs(liquidityPoolInstance.getTotalPooledEther(), lpTvl + amount, 2 wei);

        bytes32 FINALIZE_ROLE = etherFiRestakerInstance.lidoWithdrawalQueue().FINALIZE_ROLE();
        address finalize_role = etherFiRestakerInstance.lidoWithdrawalQueue().getRoleMember(FINALIZE_ROLE, 0);

        // The redemption is approved by the Lido
        vm.startPrank(finalize_role);
        uint256 currentRate = stEth.getTotalPooledEther() * 1e27 / stEth.getTotalShares();
        etherFiRestakerInstance.lidoWithdrawalQueue().prefinalize(reqIds, currentRate);
        etherFiRestakerInstance.lidoWithdrawalQueue().finalize(reqIds[reqIds.length-1], currentRate);
        vm.stopPrank();

        assertApproxEqAbs(etherFiRestakerInstance.getAmountPendingForRedemption(address(stEth)), amount, 2 wei);
        assertApproxEqAbs(etherFiRestakerInstance.getTotalPooledEther(), currentEtherFiRestakerTotalPooledEther + amount, 2 wei);
        assertApproxEqAbs(liquidityPoolInstance.getTotalPooledEther(), lpTvl + amount, 2 wei);

        // The ether.fi admin claims the finalized withdrawal, which sends the ETH to the liquifier contract
        vm.startPrank(owner);
        uint256 lastCheckPointIndex = etherFiRestakerInstance.lidoWithdrawalQueue().getLastCheckpointIndex();
        uint256[] memory hints = etherFiRestakerInstance.lidoWithdrawalQueue().findCheckpointHints(reqIds, 1, lastCheckPointIndex);
        etherFiRestakerInstance.stEthClaimWithdrawals(reqIds, hints);

        // the cycle completes
        assertApproxEqAbs(etherFiRestakerInstance.getAmountPendingForRedemption(address(stEth)), 0, 2 wei);
        assertApproxEqAbs(etherFiRestakerInstance.getTotalPooledEther(), currentEtherFiRestakerTotalPooledEther, 2 wei);
        assertApproxEqAbs(address(etherFiRestakerInstance).balance, 0, 2);
        assertApproxEqAbs(liquidityPoolInstance.getTotalPooledEther(), lpTvl + amount, 2 wei);
        assertApproxEqAbs(address(liquidityPoolInstance).balance, lpBalance + amount, 3 wei);
    }

    function test_restake_stEth() public {
        uint256 currentStEthRestakedAmount = etherFiRestakerInstance.getRestakedAmount(address(stEth));

        _deposit_stEth(10 ether);

        vm.startPrank(owner);        
        etherFiRestakerInstance.depositIntoStrategy(address(stEth), 5 ether);
        vm.stopPrank();


        assertApproxEqAbs(etherFiRestakerInstance.getRestakedAmount(address(stEth)), currentStEthRestakedAmount + 5 ether, 10 wei);
    }

    function test_queueWithdrawals_1() public returns (bytes32[] memory) {
        test_restake_stEth();

        vm.startPrank(owner);
        uint256 totalPooledEtherBefore = etherFiRestakerInstance.getTotalPooledEther();
        uint256 restakedAmountBefore = etherFiRestakerInstance.getRestakedAmount(address(stEth));
        uint256 pendingSharesBefore = etherFiRestakerInstance.getAmountInEigenLayerPendingForWithdrawals(address(stEth));

        bytes32[] memory withdrawalRoots = etherFiRestakerInstance.queueWithdrawals(address(stEth), 5 ether);

        assertTrue(etherFiRestakerInstance.isPendingWithdrawal(withdrawalRoots[0]));
        assertApproxEqAbs(etherFiRestakerInstance.getTotalPooledEther(), totalPooledEtherBefore, 10 gwei);
        assertApproxEqAbs(etherFiRestakerInstance.getRestakedAmount(address(stEth)), restakedAmountBefore - 5 ether, 10 wei);
        assertApproxEqAbs(etherFiRestakerInstance.getAmountInEigenLayerPendingForWithdrawals(address(stEth)), pendingSharesBefore + 5 ether, 10 wei);
        vm.stopPrank();

        return withdrawalRoots;
    }

    function test_completeQueuedWithdrawals_1() public {
        bytes32[] memory withdrawalRoots = test_queueWithdrawals_1();
        assertTrue(etherFiRestakerInstance.isPendingWithdrawal(withdrawalRoots[0]));

        uint256 totalPooledEtherBefore = etherFiRestakerInstance.getTotalPooledEther();
        uint256 pendingSharesBefore = etherFiRestakerInstance.getAmountInEigenLayerPendingForWithdrawals(address(stEth));

        // Get the queued withdrawal details from EigenLayer
        (IDelegationManager.Withdrawal memory withdrawal, uint256[] memory shares) = eigenLayerDelegationManager.getQueuedWithdrawal(withdrawalRoots[0]);
        
        vm.startPrank(owner);
        
        // It won't complete the withdrawal because the withdrawal is still pending (not enough blocks passed)
        IDelegationManager.Withdrawal[] memory withdrawals = new IDelegationManager.Withdrawal[](1);
        withdrawals[0] = withdrawal;
        
        IERC20[][] memory tokens = new IERC20[][](1);
        tokens[0] = new IERC20[](1);
        tokens[0][0] = IERC20(address(stEth));
        
        // This should fail because withdrawal delay hasn't passed
        vm.expectRevert();
        etherFiRestakerInstance.completeQueuedWithdrawals(withdrawals, tokens);
        
        assertTrue(etherFiRestakerInstance.isPendingWithdrawal(withdrawalRoots[0]));

        // Fast forward past the withdrawal delay (100800 blocks + 1 since it's exclusive)
        vm.roll(block.number + 100800 + 1);

        // Now the withdrawal should complete successfully
        etherFiRestakerInstance.completeQueuedWithdrawals(withdrawals, tokens);
        assertFalse(etherFiRestakerInstance.isPendingWithdrawal(withdrawalRoots[0]));

        assertApproxEqAbs(etherFiRestakerInstance.getTotalPooledEther(), totalPooledEtherBefore, 10 wei);
        assertApproxEqAbs(etherFiRestakerInstance.getAmountInEigenLayerPendingForWithdrawals(address(stEth)) + 5 ether, pendingSharesBefore, 10 wei);
        
        
        vm.stopPrank();
    }

    function test_delegate_to() public {
        if (etherFiRestakerInstance.isDelegated()) {
            vm.prank(owner);
            etherFiRestakerInstance.undelegate();
        }

        _deposit_stEth(10 ether);

        ISignatureUtilsMixinTypes.SignatureWithExpiry memory signature = ISignatureUtilsMixinTypes.SignatureWithExpiry({
            signature: hex"",
            expiry: 0
        });

        vm.startPrank(owner);
        etherFiRestakerInstance.delegateTo(avsOperator, signature, 0x0);
        etherFiRestakerInstance.depositIntoStrategy(address(stEth), 5 ether);
        vm.stopPrank();
    }

    function test_undelegate() public {
        test_delegate_to();

        vm.prank(owner);
        etherFiRestakerInstance.undelegate();
    }

    // 
    function test_change_operator() public {
        test_delegate_to();

        ISignatureUtilsMixinTypes.SignatureWithExpiry memory signature = ISignatureUtilsMixinTypes.SignatureWithExpiry({
            signature: hex"",
            expiry: 0
        });

        vm.startPrank(owner);
        vm.expectRevert("ActivelyDelegated()");
        etherFiRestakerInstance.delegateTo(avsOperator2, signature, 0x0);
        vm.stopPrank();
    }

    function test_claimer_upgrade() public {
        initializeRealisticFork(MAINNET_FORK);
        EtherFiRestaker restaker = EtherFiRestaker(payable(0x1B7a4C3797236A1C37f8741c0Be35c2c72736fFf));
        address _claimer = vm.addr(433);

        address newRestakerImpl = address(new EtherFiRestaker(address(eigenLayerRewardsCoordinator), address(etherFiRedemptionManagerInstance)));
        vm.startPrank(restaker.owner());

        restaker.upgradeTo(newRestakerImpl);
        restaker.setRewardsClaimer(_claimer);

        assertEq(eigenLayerRewardsCoordinator.claimerFor(address(restaker)), _claimer);
    }

    function test_upgrade() public {
        address newRestakerImpl = address(new EtherFiRestaker(
            address(etherFiRestakerInstance.rewardsCoordinator()),
            address(etherFiRestakerInstance.etherFiRedemptionManager())
        ));
        
        vm.startPrank(owner);
        etherFiRestakerInstance.upgradeTo(newRestakerImpl);
        vm.stopPrank();
    }

    function test_updatePendingSharesState_after_upgrade() public {
        etherFiRestakerInstance.getAmountInEigenLayerPendingForWithdrawals(address(stEth));
        etherFiRestakerInstance.getTotalPooledEther();
    }

}