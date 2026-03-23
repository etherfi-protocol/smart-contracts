// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "forge-std/Test.sol";

import "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";

import "../src/eigenlayer-interfaces/IDelegationManager.sol";
import "../src/eigenlayer-interfaces/IStrategyManager.sol";
import "../src/eigenlayer-interfaces/ISignatureUtils.sol";
import "../src/interfaces/IEtherFiRateLimiter.sol";


contract EtherFiRestakerTest is TestSetup {

    address avsOperator;
    address avsOperator2;
    address etherfiOperatingAdmin;

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);

        test_upgrade();

        rateLimiterInstance = EtherFiRateLimiter(deployed.ETHERFI_RATE_LIMITER());

        vm.startPrank(owner);
        _grantRestakerRoles(owner);
        _grantRestakerRoles(alice);

        roleRegistryInstance.grantRole(rateLimiterInstance.ETHERFI_RATE_LIMITER_ADMIN_ROLE(), owner);
        vm.stopPrank();

        // Setup rate limiters for the restaker
        vm.startPrank(owner);
        if (!rateLimiterInstance.limitExists(etherFiRestakerInstance.STETH_REQUEST_WITHDRAWAL_LIMIT_ID())) {
            rateLimiterInstance.createNewLimiter(etherFiRestakerInstance.STETH_REQUEST_WITHDRAWAL_LIMIT_ID(), 172_800_000_000_000, 2_000_000_000);
        }
        if (!rateLimiterInstance.limitExists(etherFiRestakerInstance.QUEUE_WITHDRAWALS_LIMIT_ID())) {
            rateLimiterInstance.createNewLimiter(etherFiRestakerInstance.QUEUE_WITHDRAWALS_LIMIT_ID(), 172_800_000_000_000, 2_000_000_000);
        }
        rateLimiterInstance.updateConsumers(etherFiRestakerInstance.STETH_REQUEST_WITHDRAWAL_LIMIT_ID(), address(etherFiRestakerInstance), true);
        rateLimiterInstance.updateConsumers(etherFiRestakerInstance.QUEUE_WITHDRAWALS_LIMIT_ID(), address(etherFiRestakerInstance), true);
        vm.stopPrank();

        // setUpLiquifier(MAINNET_FORK);

        avsOperator = 0x5ACCC90436492F24E6aF278569691e2c942A676d; // EigenYields
        avsOperator2 = 0xfB487f216CA24162119C0C6Ae015d680D7569C2f;
        etherfiOperatingAdmin = alice; //

        vm.prank(owner);
        liquifierInstance.updateQuoteStEthWithCurve(false);
    }

    function _grantRestakerRoles(address _account) internal {
        roleRegistryInstance.grantRole(etherFiRestakerInstance.ETHERFI_RESTAKER_STETH_REQUEST_WITHDRAWAL_ROLE(), _account);
        roleRegistryInstance.grantRole(etherFiRestakerInstance.ETHERFI_RESTAKER_STETH_CLAIM_WITHDRAWALS_ROLE(), _account);
        roleRegistryInstance.grantRole(etherFiRestakerInstance.ETHERFI_RESTAKER_QUEUE_WITHDRAWALS_ROLE(), _account);
        roleRegistryInstance.grantRole(etherFiRestakerInstance.ETHERFI_RESTAKER_COMPLETE_QUEUED_WITHDRAWALS_ROLE(), _account);
        roleRegistryInstance.grantRole(etherFiRestakerInstance.ETHERFI_RESTAKER_DEPOSIT_INTO_STRATEGY_ROLE(), _account);
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

        address newRestakerImpl = address(new EtherFiRestaker(deployed.EIGENLAYER_REWARDS_COORDINATOR(), deployed.ETHERFI_REDEMPTION_MANAGER(), deployed.ROLE_REGISTRY(), deployed.ETHERFI_RATE_LIMITER()));
        vm.startPrank(restaker.owner());

        restaker.upgradeTo(newRestakerImpl);
        restaker.setRewardsClaimer(_claimer);

        vm.stopPrank();
        assertEq(eigenLayerRewardsCoordinator.claimerFor(address(restaker)), _claimer);
    }

    function test_upgrade() public {
        address newRestakerImpl = address(new EtherFiRestaker(
            deployed.EIGENLAYER_REWARDS_COORDINATOR(),
            deployed.ETHERFI_REDEMPTION_MANAGER(),
            deployed.ROLE_REGISTRY(),
            deployed.ETHERFI_RATE_LIMITER()
        ));

        vm.startPrank(owner);
        etherFiRestakerInstance.upgradeTo(newRestakerImpl);
        vm.stopPrank();
    }

    function test_updatePendingSharesState_after_upgrade() public {
        etherFiRestakerInstance.getAmountInEigenLayerPendingForWithdrawals(address(stEth));
        etherFiRestakerInstance.getTotalPooledEther();
    }

    // -------------------------------------------------------------------------
    // Rate Limiter Tests
    // -------------------------------------------------------------------------

    // Use a small capacity (100 ETH) to stay within Lido's staking limit.
    // Refill rate: 1 ETH/sec (1_000_000_000 gwei/sec)
    uint64 constant TEST_CAPACITY = 100_000_000_000; // 100 ETH in gwei
    uint64 constant TEST_REFILL_RATE = 1_000_000_000; // 1 ETH/sec in gwei

    function _setUpSmallRateLimiters() internal {
        vm.startPrank(owner);
        rateLimiterInstance.setCapacity(etherFiRestakerInstance.STETH_REQUEST_WITHDRAWAL_LIMIT_ID(), TEST_CAPACITY);
        rateLimiterInstance.setRemaining(etherFiRestakerInstance.STETH_REQUEST_WITHDRAWAL_LIMIT_ID(), TEST_CAPACITY);
        rateLimiterInstance.setRefillRate(etherFiRestakerInstance.STETH_REQUEST_WITHDRAWAL_LIMIT_ID(), TEST_REFILL_RATE);

        rateLimiterInstance.setCapacity(etherFiRestakerInstance.QUEUE_WITHDRAWALS_LIMIT_ID(), TEST_CAPACITY);
        rateLimiterInstance.setRemaining(etherFiRestakerInstance.QUEUE_WITHDRAWALS_LIMIT_ID(), TEST_CAPACITY);
        rateLimiterInstance.setRefillRate(etherFiRestakerInstance.QUEUE_WITHDRAWALS_LIMIT_ID(), TEST_REFILL_RATE);
        vm.stopPrank();
    }

    function _stethConsumable() internal view returns (uint64) {
        return rateLimiterInstance.consumable(etherFiRestakerInstance.STETH_REQUEST_WITHDRAWAL_LIMIT_ID());
    }

    function _queueConsumable() internal view returns (uint64) {
        return rateLimiterInstance.consumable(etherFiRestakerInstance.QUEUE_WITHDRAWALS_LIMIT_ID());
    }

    function _toGwei(uint256 ethAmount) internal pure returns (uint64) {
        return uint64(ethAmount / 1 gwei);
    }

    function test_rateLimiter_stEthRequestWithdrawal_exactCapacity() public {
        _setUpSmallRateLimiters();
        _deposit_stEth(150 ether);

        // Verify initial remaining = full capacity
        assertEq(_stethConsumable(), TEST_CAPACITY);

        vm.startPrank(owner);
        etherFiRestakerInstance.stEthRequestWithdrawal(100 ether);
        vm.stopPrank();

        // After consuming exactly capacity, remaining should be 0
        assertEq(_stethConsumable(), 0);
    }

    function test_rateLimiter_stEthRequestWithdrawal_exceedsCapacity() public {
        _setUpSmallRateLimiters();
        _deposit_stEth(150 ether);

        assertEq(_stethConsumable(), TEST_CAPACITY);

        vm.startPrank(owner);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        etherFiRestakerInstance.stEthRequestWithdrawal(101 ether);
        vm.stopPrank();

        // Remaining unchanged after failed call
        assertEq(_stethConsumable(), TEST_CAPACITY);
    }

    function test_rateLimiter_stEthRequestWithdrawal_twoCallsExceedCapacity() public {
        _setUpSmallRateLimiters();
        _deposit_stEth(150 ether);

        assertEq(_stethConsumable(), TEST_CAPACITY);

        vm.startPrank(owner);
        etherFiRestakerInstance.stEthRequestWithdrawal(60 ether);
        assertEq(_stethConsumable(), _toGwei(40 ether));

        etherFiRestakerInstance.stEthRequestWithdrawal(40 ether);
        assertEq(_stethConsumable(), 0);

        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        etherFiRestakerInstance.stEthRequestWithdrawal(1 ether);

        // Still 0 after failed call
        assertEq(_stethConsumable(), 0);
        vm.stopPrank();
    }

    function test_rateLimiter_stEthRequestWithdrawal_refillAfterDrain() public {
        _setUpSmallRateLimiters();
        _deposit_stEth(150 ether);

        vm.startPrank(owner);
        etherFiRestakerInstance.stEthRequestWithdrawal(100 ether);
        assertEq(_stethConsumable(), 0);

        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        etherFiRestakerInstance.stEthRequestWithdrawal(1 ether);
        vm.stopPrank();

        // Wait 5 seconds: refills 5 * 1 ETH/sec = 5 ETH
        vm.warp(block.timestamp + 5);
        assertEq(_stethConsumable(), _toGwei(5 ether));

        _deposit_stEth(10 ether);

        vm.startPrank(owner);
        etherFiRestakerInstance.stEthRequestWithdrawal(5 ether);
        assertEq(_stethConsumable(), 0);

        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        etherFiRestakerInstance.stEthRequestWithdrawal(1 ether);
        vm.stopPrank();
    }

    function test_rateLimiter_stEthRequestWithdrawal_refillCapsAtCapacity() public {
        _setUpSmallRateLimiters();
        _deposit_stEth(150 ether);

        vm.startPrank(owner);
        etherFiRestakerInstance.stEthRequestWithdrawal(10 ether);
        assertEq(_stethConsumable(), _toGwei(90 ether));
        vm.stopPrank();

        // Wait a very long time -- refill should cap at capacity, not exceed it
        vm.warp(block.timestamp + 1 days);
        assertEq(_stethConsumable(), TEST_CAPACITY);

        _deposit_stEth(150 ether);

        vm.startPrank(owner);
        etherFiRestakerInstance.stEthRequestWithdrawal(100 ether);
        assertEq(_stethConsumable(), 0);

        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        etherFiRestakerInstance.stEthRequestWithdrawal(1 ether);
        vm.stopPrank();
    }

    function test_rateLimiter_queueWithdrawals_exactCapacity() public {
        _setUpSmallRateLimiters();
        _deposit_stEth(150 ether);

        assertEq(_queueConsumable(), TEST_CAPACITY);

        vm.startPrank(owner);
        etherFiRestakerInstance.depositIntoStrategy(address(stEth), 100 ether);
        etherFiRestakerInstance.queueWithdrawals(address(stEth), 100 ether);
        vm.stopPrank();

        assertEq(_queueConsumable(), 0);
    }

    function test_rateLimiter_queueWithdrawals_exceedsCapacity() public {
        _setUpSmallRateLimiters();
        _deposit_stEth(150 ether);

        assertEq(_queueConsumable(), TEST_CAPACITY);

        vm.startPrank(owner);
        etherFiRestakerInstance.depositIntoStrategy(address(stEth), 110 ether);

        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        etherFiRestakerInstance.queueWithdrawals(address(stEth), 101 ether);
        vm.stopPrank();

        // Unchanged after failed call
        assertEq(_queueConsumable(), TEST_CAPACITY);
    }

    function test_rateLimiter_queueWithdrawals_refillAfterDrain() public {
        _setUpSmallRateLimiters();
        _deposit_stEth(150 ether);

        vm.startPrank(owner);
        etherFiRestakerInstance.depositIntoStrategy(address(stEth), 130 ether);

        etherFiRestakerInstance.queueWithdrawals(address(stEth), 100 ether);
        assertEq(_queueConsumable(), 0);

        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        etherFiRestakerInstance.queueWithdrawals(address(stEth), 1 ether);
        vm.stopPrank();

        // Wait 10 seconds: refills 10 * 1 = 10 ETH
        vm.warp(block.timestamp + 10);
        assertEq(_queueConsumable(), _toGwei(10 ether));

        vm.startPrank(owner);
        etherFiRestakerInstance.queueWithdrawals(address(stEth), 10 ether);
        assertEq(_queueConsumable(), 0);

        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        etherFiRestakerInstance.queueWithdrawals(address(stEth), 1 ether);
        vm.stopPrank();
    }

    function test_rateLimiter_stEthAndQueueWithdrawals_independent() public {
        _setUpSmallRateLimiters();

        _deposit_stEth(150 ether);
        vm.startPrank(owner);
        etherFiRestakerInstance.depositIntoStrategy(address(stEth), 100 ether);
        vm.stopPrank();

        _deposit_stEth(150 ether);

        // Both start at full capacity
        assertEq(_stethConsumable(), TEST_CAPACITY);
        assertEq(_queueConsumable(), TEST_CAPACITY);

        vm.startPrank(owner);

        // Drain stETH limiter -- queue limiter unaffected
        etherFiRestakerInstance.stEthRequestWithdrawal(100 ether);
        assertEq(_stethConsumable(), 0);
        assertEq(_queueConsumable(), TEST_CAPACITY);

        // Drain queue limiter -- stETH limiter still 0
        etherFiRestakerInstance.queueWithdrawals(address(stEth), 100 ether);
        assertEq(_stethConsumable(), 0);
        assertEq(_queueConsumable(), 0);

        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        etherFiRestakerInstance.stEthRequestWithdrawal(1 ether);

        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        etherFiRestakerInstance.queueWithdrawals(address(stEth), 1 ether);
        vm.stopPrank();
    }

    function test_rateLimiter_partialRefill_boundary() public {
        _setUpSmallRateLimiters();
        _deposit_stEth(110 ether);

        vm.startPrank(owner);
        etherFiRestakerInstance.stEthRequestWithdrawal(100 ether);
        assertEq(_stethConsumable(), 0);
        vm.stopPrank();

        // Wait exactly 2 seconds: refills 2 ETH
        vm.warp(block.timestamp + 2);
        assertEq(_stethConsumable(), _toGwei(2 ether));

        _deposit_stEth(5 ether);

        vm.startPrank(owner);
        etherFiRestakerInstance.stEthRequestWithdrawal(2 ether);
        assertEq(_stethConsumable(), 0);

        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        etherFiRestakerInstance.stEthRequestWithdrawal(1 ether);
        vm.stopPrank();
    }

    function test_rateLimiter_adminCanAdjustCapacity() public {
        _setUpSmallRateLimiters();
        _deposit_stEth(20 ether);

        assertEq(_stethConsumable(), TEST_CAPACITY);

        vm.startPrank(owner);
        rateLimiterInstance.setCapacity(
            etherFiRestakerInstance.STETH_REQUEST_WITHDRAWAL_LIMIT_ID(),
            10_000_000_000 // 10 ETH in gwei
        );
        rateLimiterInstance.setRemaining(
            etherFiRestakerInstance.STETH_REQUEST_WITHDRAWAL_LIMIT_ID(),
            10_000_000_000 // 10 ETH in gwei
        );
        vm.stopPrank();

        assertEq(_stethConsumable(), _toGwei(10 ether));

        vm.startPrank(owner);
        etherFiRestakerInstance.stEthRequestWithdrawal(10 ether);
        assertEq(_stethConsumable(), 0);

        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        etherFiRestakerInstance.stEthRequestWithdrawal(1 ether);
        vm.stopPrank();
    }

    function test_rateLimiter_adminCanAdjustRefillRate() public {
        _setUpSmallRateLimiters();
        _deposit_stEth(150 ether);

        vm.startPrank(owner);
        etherFiRestakerInstance.stEthRequestWithdrawal(100 ether);
        assertEq(_stethConsumable(), 0);
        vm.stopPrank();

        // Increase refill rate to 10 ETH/sec
        vm.startPrank(owner);
        rateLimiterInstance.setRefillRate(
            etherFiRestakerInstance.STETH_REQUEST_WITHDRAWAL_LIMIT_ID(),
            10_000_000_000 // 10 ETH/sec in gwei
        );
        vm.stopPrank();

        // Wait 1 second: should refill 10 ETH (not 1 ETH)
        vm.warp(block.timestamp + 1);
        assertEq(_stethConsumable(), _toGwei(10 ether));

        _deposit_stEth(15 ether);

        vm.startPrank(owner);
        etherFiRestakerInstance.stEthRequestWithdrawal(10 ether);
        assertEq(_stethConsumable(), 0);

        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        etherFiRestakerInstance.stEthRequestWithdrawal(1 ether);
        vm.stopPrank();
    }
}
