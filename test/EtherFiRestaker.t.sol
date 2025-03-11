
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

        setUpLiquifier(MAINNET_FORK);

        avsOperator = 0x5ACCC90436492F24E6aF278569691e2c942A676d; // EigenYields
        avsOperator2 = 0xfB487f216CA24162119C0C6Ae015d680D7569C2f;
        etherfiOperatingAdmin = alice; //

        vm.startPrank(owner);
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
        
        ILiquidityPool.PermitInput memory permitInput = createPermitInput(2, address(liquifierInstance), _amount, stEth.nonces(alice), 2**256 - 1, stEth.DOMAIN_SEPARATOR());
        ILiquifier.PermitInput memory permitInput2 = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});
        liquifierInstance.depositWithERC20WithPermit(address(stEth), _amount, address(0), permitInput2);


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

        uint256 amount = 10 ether;

        _deposit_stEth(amount);

        assertEq(etherFiRestakerInstance.getEthAmountPendingForRedemption(address(stEth)), 0);

        vm.startPrank(alice);
        uint256 stEthBalance = stEth.balanceOf(address(etherFiRestakerInstance));
        uint256[] memory reqIds = etherFiRestakerInstance.stEthRequestWithdrawal(stEthBalance);
        vm.stopPrank();
        
        assertApproxEqAbs(etherFiRestakerInstance.getEthAmountPendingForRedemption(address(stEth)), amount, 2 wei);
        assertApproxEqAbs(etherFiRestakerInstance.getTotalPooledEther(), amount, 2 wei);
        assertApproxEqAbs(liquidityPoolInstance.getTotalPooledEther(), lpTvl + amount, 2 wei);

        bytes32 FINALIZE_ROLE = etherFiRestakerInstance.lidoWithdrawalQueue().FINALIZE_ROLE();
        address finalize_role = etherFiRestakerInstance.lidoWithdrawalQueue().getRoleMember(FINALIZE_ROLE, 0);

        // The redemption is approved by the Lido
        vm.startPrank(finalize_role);
        uint256 currentRate = stEth.getTotalPooledEther() * 1e27 / stEth.getTotalShares();
        (uint256 ethToLock, uint256 sharesToBurn) = etherFiRestakerInstance.lidoWithdrawalQueue().prefinalize(reqIds, currentRate);
        etherFiRestakerInstance.lidoWithdrawalQueue().finalize(reqIds[reqIds.length-1], currentRate);
        vm.stopPrank();

        assertApproxEqAbs(etherFiRestakerInstance.getEthAmountPendingForRedemption(address(stEth)), amount, 2 wei);
        assertApproxEqAbs(etherFiRestakerInstance.getTotalPooledEther(), amount, 2 wei);
        assertApproxEqAbs(liquidityPoolInstance.getTotalPooledEther(), lpTvl + amount, 2 wei);

        // The ether.fi admin claims the finalized withdrawal, which sends the ETH to the liquifier contract
        vm.startPrank(alice);
        uint256 lastCheckPointIndex = etherFiRestakerInstance.lidoWithdrawalQueue().getLastCheckpointIndex();
        uint256[] memory hints = etherFiRestakerInstance.lidoWithdrawalQueue().findCheckpointHints(reqIds, 1, lastCheckPointIndex);
        etherFiRestakerInstance.stEthClaimWithdrawals(reqIds, hints);

        // the cycle completes
        assertApproxEqAbs(etherFiRestakerInstance.getEthAmountPendingForRedemption(address(stEth)), 0, 2 wei);
        assertApproxEqAbs(etherFiRestakerInstance.getTotalPooledEther(), 0, 2 wei);
        assertApproxEqAbs(address(etherFiRestakerInstance).balance, 0, 2);
        assertApproxEqAbs(liquidityPoolInstance.getTotalPooledEther(), lpTvl + amount, 2 wei);
        assertApproxEqAbs(address(liquidityPoolInstance).balance, lpBalance + amount, 3 wei);
    }

    function test_restake_stEth() public {
        uint256 currentStEthRestakedAmount = etherFiRestakerInstance.getRestakedAmount(address(stEth));

        _deposit_stEth(10 ether);

        vm.startPrank(alice);        
        etherFiRestakerInstance.depositIntoStrategy(address(stEth), 5 ether);
        vm.stopPrank();


        assertApproxEqAbs(etherFiRestakerInstance.getRestakedAmount(address(stEth)), currentStEthRestakedAmount + 5 ether, 2 wei);
    }

    function test_queueWithdrawals_1() public returns (bytes32[] memory) {
        test_restake_stEth();

        vm.prank(etherfiOperatingAdmin);
        return etherFiRestakerInstance.queueWithdrawals(address(stEth), 5 ether);
    }

    function test_queueWithdrawals_2() public returns (bytes32[] memory) {
        test_restake_stEth();

        IDelegationManager.QueuedWithdrawalParams[] memory params = new IDelegationManager.QueuedWithdrawalParams[](1);
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = etherFiRestakerInstance.getEigenLayerRestakingStrategy(address(stEth));
        uint256[] memory shares = new uint256[](1);
        shares[0] = eigenLayerStrategyManager.stakerStrategyShares(address(etherFiRestakerInstance), strategies[0]);
        
        params[0] = IDelegationManager.QueuedWithdrawalParams({
            strategies: strategies,
            shares: shares,
            withdrawer: address(etherFiRestakerInstance)
        });

        vm.prank(etherfiOperatingAdmin);
        return etherFiRestakerInstance.queueWithdrawals(params);
    }

    function test_completeQueuedWithdrawals_1() public {
        bytes32[] memory withdrawalRoots = test_queueWithdrawals_1();
        assertTrue(etherFiRestakerInstance.isPendingWithdrawal(withdrawalRoots[0]));

        vm.startPrank(etherfiOperatingAdmin);
        // It won't complete the withdrawal because the withdrawal is still pending
        etherFiRestakerInstance.completeQueuedWithdrawals(1000);
        assertTrue(etherFiRestakerInstance.isPendingWithdrawal(withdrawalRoots[0]));
        assertApproxEqAbs(etherFiRestakerInstance.getEthAmountInEigenLayerPendingForWithdrawals(address(stEth)), 5 ether, 2 wei);

        vm.roll(block.number + 50400);

        etherFiRestakerInstance.completeQueuedWithdrawals(1000);
        assertFalse(etherFiRestakerInstance.isPendingWithdrawal(withdrawalRoots[0]));
        assertApproxEqAbs(etherFiRestakerInstance.getEthAmountInEigenLayerPendingForWithdrawals(address(stEth)), 0, 2 wei);
        vm.stopPrank();
    }

    function test_completeQueuedWithdrawals_2() public {
        bytes32[] memory withdrawalRoots1 = test_queueWithdrawals_1();

        vm.roll(block.number + 50400 / 2);

        bytes32[] memory withdrawalRoots2 = test_queueWithdrawals_1();

        assertTrue(etherFiRestakerInstance.isPendingWithdrawal(withdrawalRoots1[0]));
        assertTrue(etherFiRestakerInstance.isPendingWithdrawal(withdrawalRoots2[0]));

        vm.roll(block.number + 50400 / 2);

        // The first withdrawal is completed
        // But, the second withdrawal is still pending
        // Therefore, `completeQueuedWithdrawals` will not complete the second withdrawal
        vm.startPrank(etherfiOperatingAdmin);
        etherFiRestakerInstance.completeQueuedWithdrawals(1000);

        assertFalse(etherFiRestakerInstance.isPendingWithdrawal(withdrawalRoots1[0]));
        assertTrue(etherFiRestakerInstance.isPendingWithdrawal(withdrawalRoots2[0]));

        vm.roll(block.number + 50400 / 2);

        etherFiRestakerInstance.completeQueuedWithdrawals(1000);
        assertFalse(etherFiRestakerInstance.isPendingWithdrawal(withdrawalRoots1[0]));
        assertFalse(etherFiRestakerInstance.isPendingWithdrawal(withdrawalRoots2[0]));
        vm.stopPrank();
    }

    function test_delegate_to() public {
        _deposit_stEth(10 ether);

        ISignatureUtils.SignatureWithExpiry memory signature = ISignatureUtils.SignatureWithExpiry({
            signature: hex"",
            expiry: 0
        });

        vm.startPrank(etherfiOperatingAdmin);
        etherFiRestakerInstance.delegateTo(avsOperator, signature, 0x0);
        etherFiRestakerInstance.depositIntoStrategy(address(stEth), 5 ether);
        vm.stopPrank();
    }

    function test_undelegate() public {
        test_delegate_to();

        vm.prank(etherfiOperatingAdmin);
        etherFiRestakerInstance.undelegate();
    }

    // 
    function test_change_operator() public {
        test_delegate_to();

        ISignatureUtils.SignatureWithExpiry memory signature = ISignatureUtils.SignatureWithExpiry({
            signature: hex"",
            expiry: 0
        });

        vm.startPrank(etherfiOperatingAdmin);
        vm.expectRevert("DelegationManager._delegate: staker is already actively delegated");
        etherFiRestakerInstance.delegateTo(avsOperator2, signature, 0x0);
        vm.stopPrank();
    }
}