// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@tests/TestSetup.sol";
import "forge-std/Test.sol";

import "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";

import "@etherfi/interfaces/eigenlayer-interfaces/IDelegationManager.sol";
import "@etherfi/governance/utils/PausableUntil.sol";
import "@etherfi/interfaces/eigenlayer-interfaces/IStrategyManager.sol";
import "@etherfi/interfaces/eigenlayer-interfaces/ISignatureUtils.sol";


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

    /// Pin the Liquifier's stETH/ETH feed to a fresh ~1:1 answer so deposits
    /// don't revert StalePriceFeed after vm.warp on a realistic fork.
    function _mockFreshStEthFeed() internal {
        vm.mockCall(
            address(liquifierInstance.stEthPriceFeed()),
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(0), int256(1 ether), uint256(0), block.timestamp, uint80(0))
        );
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

        liquifierInstance.depositWithERC20(address(stEth), _amount, 0, address(0));


        // Aliice has 10 ether eETH
        // Total eETH TVL is 10 ether
        assertApproxEqAbs(stEth.balanceOf(alice), aliceStEthBalance, 4 wei);
        assertApproxEqAbs(eETHInstance.balanceOf(alice), aliceEEthBalance + _amount, 4 wei);
        assertApproxEqAbs(etherFiRestakerInstance.getTotalPooledEther(), restakerTvl + _amount, 4 wei);
        assertApproxEqAbs(liquidityPoolInstance.getTotalPooledEther(), lpTvl + _amount, 4 wei);
        vm.stopPrank();
    }

    function test_withdrawal_of_non_restaked_stEth() public {
        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();
        uint256 lpBalance = address(liquidityPoolInstance).balance;
        uint256 currentEtherFiRestakerTotalPooledEther = etherFiRestakerInstance.getTotalPooledEther();
        uint256 currentStEthBalance = stEth.balanceOf(address(etherFiRestakerInstance));
        uint256 initialPendingRedemption = etherFiRestakerInstance.getAmountPendingForRedemption(address(stEth));
        uint256 amount = 10 ether;

        _deposit_stEth(amount);

        assertEq(etherFiRestakerInstance.getAmountPendingForRedemption(address(stEth)), initialPendingRedemption);

        vm.startPrank(owner);
        uint256 stEthBalance = stEth.balanceOf(address(etherFiRestakerInstance)) - currentStEthBalance;
        uint256[] memory reqIds = etherFiRestakerInstance.stEthRequestWithdrawal(stEthBalance);
        vm.stopPrank();
        
        assertApproxEqAbs(etherFiRestakerInstance.getAmountPendingForRedemption(address(stEth)), initialPendingRedemption + amount, 2 wei);
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

        assertApproxEqAbs(etherFiRestakerInstance.getAmountPendingForRedemption(address(stEth)), initialPendingRedemption + amount, 2 wei);
        assertApproxEqAbs(etherFiRestakerInstance.getTotalPooledEther(), currentEtherFiRestakerTotalPooledEther + amount, 2 wei);
        assertApproxEqAbs(liquidityPoolInstance.getTotalPooledEther(), lpTvl + amount, 2 wei);

        // The ether.fi admin claims the finalized withdrawal, which sends the ETH to the liquifier contract
        vm.startPrank(owner);
        uint256 lastCheckPointIndex = etherFiRestakerInstance.lidoWithdrawalQueue().getLastCheckpointIndex();
        uint256[] memory hints = etherFiRestakerInstance.lidoWithdrawalQueue().findCheckpointHints(reqIds, 1, lastCheckPointIndex);
        etherFiRestakerInstance.stEthClaimWithdrawals(reqIds, hints);

        // the cycle completes - only the newly requested amount should be redeemed, initial pending remains
        assertApproxEqAbs(etherFiRestakerInstance.getAmountPendingForRedemption(address(stEth)), initialPendingRedemption, 2 wei);
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

        uint32 timeBoundCapRefreshInterval = liquifierInstance.timeBoundCapRefreshInterval();
        vm.warp(block.timestamp + timeBoundCapRefreshInterval + 1);

        // The realistic fork wires the Liquifier to the live stETH/ETH Chainlink
        // aggregator (~24h heartbeat). Warping past timeBoundCapRefreshInterval
        // pushes block.timestamp beyond updatedAt + stalePriceWindow, so the
        // deposit below would revert StalePriceFeed. Pin a fresh ~1:1 round.
        _mockFreshStEthFeed();

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
        // initializeRealisticFork(MAINNET_FORK);
        EtherFiRestaker restaker = EtherFiRestaker(payable(deployed.ETHERFI_RESTAKER()));
        address _claimer = address(liquidityPoolInstance); // dummy claimer

        address newRestakerImpl = address(new EtherFiRestaker(address(liquidityPoolInstance), address(liquifierInstance), address(eigenLayerRewardsCoordinator), address(etherFiRedemptionManagerInstance), address(roleRegistryInstance), address(rateLimiterInstance), address(eigenLayerStrategyManager), address(eigenLayerDelegationManager)));

        address restakerOwner = roleRegistryInstance.owner();
        vm.startPrank(roleRegistryInstance.owner());
        // ETHERFI_RESTAKER_ADMIN_ROLE consolidated into OPERATION_MULTISIG_ROLE.
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_MULTISIG_ROLE(), restakerOwner);
        vm.stopPrank();

        vm.startPrank(restakerOwner);
        restaker.upgradeTo(newRestakerImpl);
        restaker.setRewardsClaimer(_claimer);
        vm.stopPrank();

        assertEq(eigenLayerRewardsCoordinator.claimerFor(address(restaker)), _claimer);
    }

    function test_upgrade() public {
        address newRestakerImpl = address(new EtherFiRestaker(
            address(etherFiRestakerInstance.liquidityPool()),
            address(etherFiRestakerInstance.liquifier()),
            address(etherFiRestakerInstance.rewardsCoordinator()),
            address(etherFiRestakerInstance.etherFiRedemptionManager()),
            address(roleRegistryInstance),
            address(rateLimiterInstance),
            address(eigenLayerStrategyManager),
            address(eigenLayerDelegationManager)
        ));

        vm.startPrank(owner);
        etherFiRestakerInstance.upgradeTo(newRestakerImpl);
        vm.stopPrank();

        // Grant all restaker roles to owner so existing tests continue to work.
        // onlyOperations (delegateTo/undelegate/withdrawEther/setRewardsClaimer/pause) → OPERATION_MULTISIG_ROLE.
        // RateLimiter mutators are onlyAdmin → OPERATION_TIMELOCK_ROLE.
        // stEthRequestWithdrawal / depositIntoStrategy / queueWithdrawals → HOUSEKEEPING_OPERATIONS_ROLE.
        // stEthClaimWithdrawals / completeQueuedWithdrawals → EXECUTOR_OPERATIONS_ROLE.
        vm.startPrank(roleRegistryInstance.owner());
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_MULTISIG_ROLE(), owner);
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_TIMELOCK_ROLE(), owner);
        roleRegistryInstance.grantRole(roleRegistryInstance.HOUSEKEEPING_OPERATIONS_ROLE(), owner);
        roleRegistryInstance.grantRole(roleRegistryInstance.EXECUTOR_OPERATIONS_ROLE(), owner);
        vm.stopPrank();

        // Create the stETH-withdrawal rate-limiter bucket and register the restaker as a
        // consumer (idempotent). queue-withdrawals / deposit-into-strategy are no longer
        // rate-limited, so they have no bucket.
        uint64 maxUint64 = type(uint64).max;
        address restakerAddr = address(etherFiRestakerInstance);
        vm.startPrank(owner);
        bytes32 stEthId = etherFiRestakerInstance.STETH_REQUEST_WITHDRAWAL_LIMIT_ID();
        if (!rateLimiterInstance.limitExists(stEthId)) rateLimiterInstance.createNewLimiter(stEthId, maxUint64, maxUint64);
        rateLimiterInstance.updateConsumers(stEthId, restakerAddr, true);
        vm.stopPrank();
    }

    function test_updatePendingSharesState_after_upgrade() public {
        etherFiRestakerInstance.getAmountInEigenLayerPendingForWithdrawals(address(stEth));
        etherFiRestakerInstance.getTotalPooledEther();
    }

    // PR #385 security review (H1 + Yash's review): the restaker's pause previously gated
    // nothing — pauseContract() flipped a flag but no money-movement function checked it.
    // It now uses the protocol-wide PausableUntil model: the Guardian (HN/EOA keys) fires
    // an auto-expiring halt, the multisig has a boolean pause, and both stop fund movement.
    function test_guardianPauseUntil_halts_fund_movement() public {
        vm.startPrank(roleRegistryInstance.owner());
        roleRegistryInstance.grantRole(roleRegistryInstance.GUARDIAN_ROLE(), bob);
        vm.stopPrank();

        // operating timelock (owner) sets the auto-expiry duration
        vm.prank(owner);
        etherFiRestakerInstance.setPauseUntilDuration(8 hours);

        // Guardian fast-halt (auto-expiring)
        vm.prank(bob);
        etherFiRestakerInstance.pauseUntil();
        uint256 until = etherFiRestakerInstance.pausedUntil();
        assertGt(until, block.timestamp);

        // whenNotHalted is the first gate on transferStETH, so the halt fires before the
        // caller check — proves fund movement is actually stopped.
        vm.expectRevert(abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, until));
        etherFiRestakerInstance.transferStETH(bob, 1);

        // undelegate (owner holds OPERATION_MULTISIG) queues withdrawal of ALL restaked
        // assets — same fund-flow category, so it must also be halted.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, until));
        etherFiRestakerInstance.undelegate();

        // a non-guardian cannot fire the auto-expiring halt
        vm.prank(alice);
        vm.expectRevert(RoleRegistry.OnlyGuardian.selector);
        etherFiRestakerInstance.pauseUntil();

        // resume is deliberate / multisig-only
        vm.prank(owner);
        etherFiRestakerInstance.unpauseUntil();
        assertEq(etherFiRestakerInstance.pausedUntil(), 0);
    }

    // The boolean multisig pause also halts fund movement (reverts via OZ Pausable).
    function test_booleanPause_also_halts_fund_movement() public {
        vm.prank(owner); // owner holds OPERATION_MULTISIG
        etherFiRestakerInstance.pause();
        assertTrue(etherFiRestakerInstance.paused());

        vm.expectRevert(Pausable.ContractPaused.selector);
        etherFiRestakerInstance.transferStETH(bob, 1);

        vm.prank(owner);
        etherFiRestakerInstance.unpause();
        assertFalse(etherFiRestakerInstance.paused());
    }

}
