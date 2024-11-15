
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
        etherfiOperatingAdmin = alice;

        vm.startPrank(owner);
        liquifierInstance.updateQuoteStEthWithCurve(false);
        roleRegistryInstance.grantRole(etherFiRestakeManagerInstance.RESTAKING_MANAGER_ADMIN_ROLE(), etherfiOperatingAdmin);
        etherFiRestakeManagerInstance.instantiateEtherFiRestaker(3);
        vm.stopPrank();

    }

    function _deposit_stEth(uint256 _amount) internal {
        uint256 restakerTvl = etherFiRestakeManagerInstance.getTotalPooledEther();
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


        // Alice has 10 ether eETH
        // Total eETH TVL is 10 ether
        assertApproxEqAbs(stEth.balanceOf(alice), aliceStEthBalance, 1 wei);
        assertApproxEqAbs(eETHInstance.balanceOf(alice), aliceEEthBalance + _amount, 1 wei);
        assertApproxEqAbs(etherFiRestakeManagerInstance.getTotalPooledEther(), restakerTvl + _amount, 1 wei);
        assertApproxEqAbs(liquidityPoolInstance.getTotalPooledEther(), lpTvl + _amount, 1 wei);
        vm.stopPrank();
    }

    function test_withdrawal_of_non_restaked_stEth() public {
        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();
        uint256 lpBalance = address(liquidityPoolInstance).balance;

        uint256 amount = 10 ether;

        // deposit stETH into liquifier
        _deposit_stEth(amount);

        assertEq(etherFiRestakeManagerInstance.getEthAmountPendingForRedemption(address(stEth)), 0);

        vm.startPrank(alice);
        uint256 stEthBalance = stEth.balanceOf(address(etherFiRestakeManagerInstance));
        uint256[] memory reqIds = etherFiRestakeManagerInstance.stEthRequestWithdrawal(stEthBalance);
        vm.stopPrank();
        
        assertApproxEqAbs(etherFiRestakeManagerInstance.getEthAmountPendingForRedemption(address(stEth)), amount, 3 wei);
        assertApproxEqAbs(etherFiRestakeManagerInstance.getTotalPooledEther(), amount, 3 wei);
        assertApproxEqAbs(liquidityPoolInstance.getTotalPooledEther(), lpTvl + amount, 3 wei);

        bytes32 FINALIZE_ROLE = etherFiRestakeManagerInstance.lidoWithdrawalQueue().FINALIZE_ROLE();
        address finalize_role = etherFiRestakeManagerInstance.lidoWithdrawalQueue().getRoleMember(FINALIZE_ROLE, 0);

        // The redemption is approved by the Lido
        vm.startPrank(finalize_role);
        uint256 currentRate = stEth.getTotalPooledEther() * 1e27 / stEth.getTotalShares();
        (uint256 ethToLock, uint256 sharesToBurn) = etherFiRestakeManagerInstance.lidoWithdrawalQueue().prefinalize(reqIds, currentRate);
        etherFiRestakeManagerInstance.lidoWithdrawalQueue().finalize(reqIds[reqIds.length-1], currentRate);
        vm.stopPrank();

        assertApproxEqAbs(etherFiRestakeManagerInstance.getEthAmountPendingForRedemption(address(stEth)), amount, 3 wei);
        assertApproxEqAbs(etherFiRestakeManagerInstance.getTotalPooledEther(), amount, 3 wei);
        assertApproxEqAbs(liquidityPoolInstance.getTotalPooledEther(), lpTvl + amount, 3 wei);

        // The ether.fi admin claims the finalized withdrawal, which sends the ETH to the liquifier contract
        vm.startPrank(alice);
        uint256 lastCheckPointIndex = etherFiRestakeManagerInstance.lidoWithdrawalQueue().getLastCheckpointIndex();
        uint256[] memory hints = etherFiRestakeManagerInstance.lidoWithdrawalQueue().findCheckpointHints(reqIds, 1, lastCheckPointIndex);
        etherFiRestakeManagerInstance.stEthClaimWithdrawals(reqIds, hints);

        // the cycle completes
        assertApproxEqAbs(etherFiRestakeManagerInstance.getEthAmountPendingForRedemption(address(stEth)), 0, 3 wei);
        assertApproxEqAbs(etherFiRestakeManagerInstance.getTotalPooledEther(), 0, 3 wei);
        assertApproxEqAbs(address(etherFiRestakeManagerInstance).balance, 0, 2);

        assertApproxEqAbs(liquidityPoolInstance.getTotalPooledEther(), lpTvl + amount, 3 wei);
        assertApproxEqAbs(address(liquidityPoolInstance).balance, lpBalance + amount, 3 wei);
    }

    function test_restake_stEth() public {
        (,,uint256 stEthRestakedAmountBefore,) = etherFiRestakeManagerInstance.getTotalPooledEtherSplits();

        _deposit_stEth(10 ether);

        vm.startPrank(alice);        
        etherFiRestakeManagerInstance.depositIntoStrategy(1, address(stEth), 5 ether);
        vm.stopPrank();

        (,,uint256 stEthRestakedAmountAfter,) = etherFiRestakeManagerInstance.getTotalPooledEtherSplits();

        assertApproxEqAbs(stEthRestakedAmountAfter, stEthRestakedAmountBefore + 5 ether, 3 wei);
    }

    function test_queueWithdrawals_1() public returns (bytes32[] memory) {
        test_restake_stEth();

        vm.prank(etherfiOperatingAdmin);
        return etherFiRestakeManagerInstance.queueWithdrawals(1, address(stEth), 5 ether - 2);
    }

    function test_queueWithdrawals_2() public returns (bytes32[] memory) {
        test_restake_stEth();

        address etherFiRestakerInstance = address(etherFiRestakeManagerInstance.etherFiRestaker(1));

        IDelegationManager.QueuedWithdrawalParams[] memory params = new IDelegationManager.QueuedWithdrawalParams[](1);
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = EtherFiRestaker(payable(etherFiRestakerInstance)).getEigenLayerRestakingStrategy(address(stEth));
        uint256[] memory shares = new uint256[](1);
        shares[0] = eigenLayerStrategyManager.stakerStrategyShares(address(etherFiRestakerInstance), strategies[0]);
        
        params[0] = IDelegationManager.QueuedWithdrawalParams({
            strategies: strategies,
            shares: shares,
            withdrawer: address(etherFiRestakerInstance)
        });

        vm.prank(etherfiOperatingAdmin);
        return etherFiRestakeManagerInstance.queueWithdrawalsAdvanced(1, params);
    }

    function test_completeQueuedWithdrawals_1() public {
        bytes32[] memory withdrawalRoots = test_queueWithdrawals_1();


        EtherFiRestaker etherFiRestakerInstance = etherFiRestakeManagerInstance.etherFiRestaker(1);

        assertTrue(etherFiRestakerInstance.isPendingWithdrawal(withdrawalRoots[0]));
        assertApproxEqAbs(etherFiRestakeManagerInstance.getTotalPooledEther(), 10 ether, 3);

        vm.startPrank(etherfiOperatingAdmin);
        // It won't complete the withdrawal because the withdrawal is still pending
        etherFiRestakeManagerInstance.completeQueuedWithdrawals(1, 1000);
        assertTrue(etherFiRestakerInstance.isPendingWithdrawal(withdrawalRoots[0]));
        assertApproxEqAbs(etherFiRestakerInstance.getEthAmountInEigenLayerPendingForWithdrawals(address(stEth)), 5 ether, 3 wei);

        vm.roll(block.number + 50400);

        etherFiRestakeManagerInstance.completeQueuedWithdrawals(1, 1000);
        assertFalse(etherFiRestakerInstance.isPendingWithdrawal(withdrawalRoots[0]));
        assertApproxEqAbs(etherFiRestakerInstance.getEthAmountInEigenLayerPendingForWithdrawals(address(stEth)), 0, 3 wei);
        assertApproxEqAbs(etherFiRestakeManagerInstance.getTotalPooledEther(), 10 ether, 4);
        vm.stopPrank();
    }

    function test_completeQueuedWithdrawals_2() public {
        bytes32[] memory withdrawalRoots1 = test_queueWithdrawals_1();

        vm.roll(block.number + 50400 / 2);

        bytes32[] memory withdrawalRoots2 = test_queueWithdrawals_1();

        EtherFiRestaker etherFiRestakerInstance = etherFiRestakeManagerInstance.etherFiRestaker(1);

        assertTrue(etherFiRestakerInstance.isPendingWithdrawal(withdrawalRoots1[0]));
        assertTrue(etherFiRestakerInstance.isPendingWithdrawal(withdrawalRoots2[0]));

        vm.roll(block.number + 50400 / 2);

        // The first withdrawal is completed
        // But, the second withdrawal is still pending
        // Therefore, `completeQueuedWithdrawals` will not complete the second withdrawal
        vm.startPrank(etherfiOperatingAdmin);
        etherFiRestakeManagerInstance.completeQueuedWithdrawals(1, 1000);

        assertFalse(etherFiRestakerInstance.isPendingWithdrawal(withdrawalRoots1[0]));
        assertTrue(etherFiRestakerInstance.isPendingWithdrawal(withdrawalRoots2[0]));

        vm.roll(block.number + 50400 / 2);

        etherFiRestakeManagerInstance.completeQueuedWithdrawals(1, 1000);
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
        etherFiRestakeManagerInstance.delegateTo(1, avsOperator, signature, 0x0);
        etherFiRestakeManagerInstance.depositIntoStrategy(1, address(stEth), 5 ether);
        vm.stopPrank();
    }

    function test_undelegate() public {
        test_delegate_to();

        vm.prank(etherfiOperatingAdmin);
        etherFiRestakeManagerInstance.undelegate(1);
    }

    function test_change_operator() public {
        test_delegate_to();

        ISignatureUtils.SignatureWithExpiry memory signature = ISignatureUtils.SignatureWithExpiry({
            signature: hex"",
            expiry: 0
        });

        vm.startPrank(etherfiOperatingAdmin);
        vm.expectRevert("DelegationManager._delegate: staker is already actively delegated");
        etherFiRestakeManagerInstance.delegateTo(1, avsOperator2, signature, 0x0);
        vm.stopPrank();
    }

    function test_multi_restakers_multi_states() public {
        EtherFiRestaker etherFiRestakerInstance = etherFiRestakeManagerInstance.etherFiRestaker(1);
        
        test_queueWithdrawals_1();

        (uint256 holding, uint256 pendingForWithdrawals, uint256 restaked, uint256 unrestaking) = etherFiRestakeManagerInstance.getTotalPooledEtherSplits();
        
        assertApproxEqAbs(holding, 5 ether, 3);
        assertApproxEqAbs(pendingForWithdrawals, 0, 3);
        assertApproxEqAbs(restaked, 0, 3);
        assertApproxEqAbs(unrestaking, 5 ether, 3);

        vm.prank(etherfiOperatingAdmin);
        etherFiRestakeManagerInstance.stEthRequestWithdrawal(1 ether);

        (holding, pendingForWithdrawals, restaked, unrestaking) = etherFiRestakeManagerInstance.getTotalPooledEtherSplits();
        
        assertApproxEqAbs(holding, 4 ether, 3);
        assertApproxEqAbs(pendingForWithdrawals, 1 ether, 3);
        assertApproxEqAbs(restaked, 0, 3);
        assertApproxEqAbs(unrestaking, 5 ether, 3);

        vm.startPrank(alice);        
        etherFiRestakeManagerInstance.depositIntoStrategy(3, address(stEth), 2 ether);

        (holding, pendingForWithdrawals, restaked, unrestaking) = etherFiRestakeManagerInstance.getTotalPooledEtherSplits();

        assertApproxEqAbs(holding, 2 ether, 3);
        assertApproxEqAbs(pendingForWithdrawals, 1 ether, 3);
        assertApproxEqAbs(restaked, 2 ether, 3);
        assertApproxEqAbs(unrestaking, 5 ether, 3);

        vm.startPrank(etherfiOperatingAdmin);
        vm.roll(block.number + 50400);
        etherFiRestakeManagerInstance.completeQueuedWithdrawals(1, 1000);

        (holding, pendingForWithdrawals, restaked, unrestaking) = etherFiRestakeManagerInstance.getTotalPooledEtherSplits();

        assertApproxEqAbs(holding, 7 ether, 3);
        assertApproxEqAbs(pendingForWithdrawals, 1 ether, 3);
        assertApproxEqAbs(restaked, 2 ether, 3);
        assertApproxEqAbs(unrestaking, 0, 3);

    }

    function test_beacon_upgrade() public {
        _deposit_stEth(10 ether);

        vm.prank(owner);
        etherFiRestakeManagerInstance.upgradeEtherFiRestaker(address(roleRegistryInstance));

        vm.prank(alice);
        vm.expectRevert();
        etherFiRestakeManagerInstance.depositIntoStrategy(1, address(stEth), 5 ether);

        vm.startPrank(owner);
        etherFiRestakeManagerInstance.upgradeEtherFiRestaker(address(new EtherFiRestaker()));
        vm.stopPrank();
        

        vm.startPrank(alice);
        etherFiRestakeManagerInstance.depositIntoStrategy(1, address(stEth), 5 ether);
        etherFiRestakeManagerInstance.depositIntoStrategy(3, address(stEth), 5 ether);

    }
}
