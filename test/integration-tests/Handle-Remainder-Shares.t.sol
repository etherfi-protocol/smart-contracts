// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "@tests/TestSetup.sol";
import "@scripts/deploys/Deployed.s.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract HandleRemainderSharesIntegrationTest is TestSetup, Deployed {

    function _newLpImpl() internal returns (address) {
        return address(new LiquidityPool(
            ILiquidityPool.ConstructorAddresses({
                stakingManager: STAKING_MANAGER,
                nodesManager: ETHERFI_NODES_MANAGER,
                eETH: EETH,
                withdrawRequestNFT: WITHDRAW_REQUEST_NFT,
                liquifier: LIQUIFIER,
                etherFiRedemptionManager: ETHERFI_REDEMPTION_MANAGER,
                roleRegistry: ROLE_REGISTRY,
                priorityWithdrawalQueue: PRIORITY_WITHDRAWAL_QUEUE,
                blacklister: address(blacklisterInstance),
                etherFiAdminContract: ETHERFI_ADMIN,
                membershipManager: MEMBERSHIP_MANAGER
            })
        ));
    }

    function _newWrnImpl() internal returns (address) {
        return address(new WithdrawRequestNFT(buybackWallet, EETH, LIQUIDITY_POOL, MEMBERSHIP_MANAGER, ROLE_REGISTRY, address(blacklisterInstance), address(etherFiAdminInstance)));
    }

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);
        vm.etch(alice, bytes(""));
        vm.etch(bob, bytes(""));

        // Upgrade LP and NFT to the new escrow-aware implementations so that
        // finalizeRequests + claimWithdraw work with the new ETH-escrow flow.
        address lpOwner = liquidityPoolInstance.owner();
        // Deploy the impl BEFORE pranking: `_newLpImpl()` performs a CREATE that
        // would otherwise consume the single-shot vm.prank, leaving upgradeTo to
        // run as the test contract (OnlyUpgradeTimelock after the RoleRegistry swap).
        address newLpImpl = _newLpImpl();
        vm.prank(lpOwner);
        liquidityPoolInstance.upgradeTo(newLpImpl);

        address wrnOwner = withdrawRequestNFTInstance.owner();
        address newWrnImpl = _newWrnImpl();
        vm.prank(wrnOwner);
        withdrawRequestNFTInstance.upgradeTo(newWrnImpl);

        // The production queue proxy on mainnet still runs the master impl which
        // has no receive(); initializeOnUpgradeV2 below sweeps queue-locked ETH
        // into the queue and would revert with SendFail. Upgrade the queue first.
        address newPQ = address(new PriorityWithdrawalQueue(
            address(liquidityPoolInstance), address(eETHInstance), address(weEthInstance),
            address(blacklisterInstance), address(roleRegistryInstance), treasuryInstance, 1 hours
        ));
        vm.prank(UPGRADE_TIMELOCK);
        PriorityWithdrawalQueue(payable(PRIORITY_WITHDRAWAL_QUEUE)).upgradeTo(newPQ);

        // One-shot migration: move pre-existing locked ETH into NFT escrow.
        if (!liquidityPoolInstance.escrowMigrationCompleted()) {
            vm.prank(lpOwner);
            liquidityPoolInstance.initializeOnUpgradeV2();
        }

        vm.startPrank(owner);
        liquidityPoolInstance.setMaxWithdrawAmount(1000 ether);
        liquidityPoolInstance.setMinWithdrawAmount(0.001 ether);
        vm.stopPrank();

        // Admin-gated setters on WithdrawRequestNFT (e.g. updateShareRemainderSplitToTreasuryInBps)
        // route through OPERATION_TIMELOCK_ROLE. Grant it to `admin` so the test can drive them.
        // Resolve every argument before vm.prank so unrelated view calls don't consume it.
        bytes32 opTimelockRole = roleRegistryInstance.OPERATION_TIMELOCK_ROLE();
        address rrOwner = roleRegistryInstance.owner();
        vm.prank(rrOwner);
        roleRegistryInstance.grantRole(opTimelockRole, admin);
    }

    function test_HandleRemainder() public {
        // Setup: Create remainder by depositing, requesting withdrawal, rebase, and claiming
        vm.deal(bob, 10 ether);
        vm.startPrank(bob);
        liquidityPoolInstance.deposit{value: 10 ether}();
        eETHInstance.approve(address(liquidityPoolInstance), 5 ether);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(bob, 5 ether);
        vm.stopPrank();

        // Rebase to create remainder (increase liquidity pool's ETH backing)
        vm.prank(address(etherFiAdminInstance));
        liquidityPoolInstance.rebase(5 ether);

        // Finalize and claim the withdrawal to create remainder
        vm.prank(ETHERFI_ADMIN);
        withdrawRequestNFTInstance.finalizeRequests(requestId);

        vm.prank(bob);
        withdrawRequestNFTInstance.claimWithdraw(requestId);

        uint256 remainderAmount = withdrawRequestNFTInstance.getEEthRemainderAmount();
        assertGt(remainderAmount, 0, "Remainder amount should be greater than 0");

        // Grant the IMPLICIT_FEE_CLAIMER_ROLE to alice
        vm.startPrank(address(roleRegistryInstance.owner()));
        withdrawRequestNFTInstance.upgradeTo(_newWrnImpl());
        roleRegistryInstance.grantRole(roleRegistryInstance.HOUSEKEEPING_OPERATIONS_ROLE(), alice);
        vm.stopPrank();

        // Record state before handling remainder
        uint256 treasuryBalanceBefore = eETHInstance.balanceOf(buybackWallet);
        uint256 contractSharesBefore = eETHInstance.shares(address(withdrawRequestNFTInstance));
        uint256 totalRemainderBefore = withdrawRequestNFTInstance.totalRemainderEEthShares();

        // Calculate expected values
        uint256 shareRemainderSplitToTreasury = withdrawRequestNFTInstance.shareRemainderSplitToTreasuryInBps();
        uint256 expectedToTreasury = Math.mulDiv(remainderAmount, shareRemainderSplitToTreasury, 10000);
        uint256 expectedToBurn = remainderAmount - expectedToTreasury;

        uint256 expectedSharesToBurn = liquidityPoolInstance.sharesForAmount(expectedToBurn);
        uint256 expectedSharesToTreasury = liquidityPoolInstance.sharesForAmount(expectedToTreasury);
        uint256 expectedTotalSharesMoved = expectedSharesToBurn + expectedSharesToTreasury;

        // Handle the remainder
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit WithdrawRequestNFT.HandledRemainderOfClaimedWithdrawRequests(expectedToTreasury, expectedToBurn);
        withdrawRequestNFTInstance.handleRemainder(remainderAmount);

        // Verify state changes
        uint256 treasuryBalanceAfter = eETHInstance.balanceOf(buybackWallet);
        uint256 contractSharesAfter = eETHInstance.shares(address(withdrawRequestNFTInstance));
        uint256 totalRemainderAfter = withdrawRequestNFTInstance.totalRemainderEEthShares();

        // Treasury received correct amount
        assertApproxEqAbs(treasuryBalanceAfter - treasuryBalanceBefore, expectedToTreasury, 1e9, "Treasury should receive correct portion");

        // Contract shares decreased by expected amount
        assertApproxEqAbs(contractSharesBefore - contractSharesAfter, expectedTotalSharesMoved, 1e9, "Contract shares should decrease by moved amount");

        // Total remainder shares decreased correctly
        assertApproxEqAbs(totalRemainderBefore - totalRemainderAfter, expectedTotalSharesMoved, 1e9, "Total remainder shares should decrease");

        // Invariant: contract shares should match expected after accounting for moves
        assertApproxEqAbs(contractSharesAfter, contractSharesBefore - expectedTotalSharesMoved, 1e9, "Contract shares invariant check");
    }

    function test_HandleRemainder_PartialHandling() public {
        // Setup: Create remainder and handle only part of it
        vm.deal(bob, 500 ether);
        vm.startPrank(bob);
        liquidityPoolInstance.deposit{value: 500 ether}();
        eETHInstance.approve(address(liquidityPoolInstance), 200 ether);

        // Create multiple withdrawal requests to generate larger remainder
        uint256[] memory requestIds = new uint256[](20);
        for (uint256 i = 0; i < 20; i++) {
            requestIds[i] = liquidityPoolInstance.requestWithdraw(bob, 10 ether);
        }
        vm.stopPrank();

        // Scale rebase to TVL so the remainder stays drift-proof: total_remainder
        // ≈ rebase × (bob_locked / TVL), so picking rebase = TVL × p collapses to
        // total_remainder ≈ bob_locked × p. With bob_locked = 200 ETH and p = 0.5%,
        // expected remainder ≈ 1 ETH, well above the 0.05 floor below.
        int128 rebaseAmount = int128(int256(liquidityPoolInstance.getTotalPooledEther() / 200));
        _rebaseUncapped(rebaseAmount);

        // Finalize and claim all requests
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(ETHERFI_ADMIN);
            withdrawRequestNFTInstance.finalizeRequests(requestIds[i]);

            vm.prank(bob);
            withdrawRequestNFTInstance.claimWithdraw(requestIds[i]);
        }

        uint256 remainderAmount = withdrawRequestNFTInstance.getEEthRemainderAmount();
        assertGt(remainderAmount, 0.05 ether, "Remainder amount should be greater than 0.05 ether for partial handling");

        // Now upgrade the contract and grant roles
        vm.startPrank(address(roleRegistryInstance.owner()));
        withdrawRequestNFTInstance.upgradeTo(_newWrnImpl());
        roleRegistryInstance.grantRole(roleRegistryInstance.HOUSEKEEPING_OPERATIONS_ROLE(), alice);
        vm.stopPrank();

        uint256 partialAmount = remainderAmount / 2;

        // Record state before
        uint256 treasuryBalanceBefore = eETHInstance.balanceOf(buybackWallet);
        uint256 totalRemainderBefore = withdrawRequestNFTInstance.totalRemainderEEthShares();

        // Handle partial remainder
        vm.prank(alice);
        withdrawRequestNFTInstance.handleRemainder(partialAmount);

        // Verify partial handling
        uint256 treasuryBalanceAfter = eETHInstance.balanceOf(buybackWallet);
        uint256 totalRemainderAfter = withdrawRequestNFTInstance.totalRemainderEEthShares();

        uint256 shareRemainderSplitToTreasury = withdrawRequestNFTInstance.shareRemainderSplitToTreasuryInBps();
        uint256 expectedToTreasury = Math.mulDiv(partialAmount, shareRemainderSplitToTreasury, 10000);

        assertApproxEqAbs(treasuryBalanceAfter - treasuryBalanceBefore, expectedToTreasury, 1e9, "Treasury should receive partial amount");
        assertLt(totalRemainderAfter, totalRemainderBefore, "Total remainder should decrease");

        // Remaining remainder should be available for further handling
        uint256 remainingRemainder = withdrawRequestNFTInstance.getEEthRemainderAmount();
        assertGt(remainingRemainder, 0, "Remaining remainder should be greater than 0");

        // Handle remaining remainder
        vm.prank(alice);
        withdrawRequestNFTInstance.handleRemainder(remainingRemainder);

        // Should be no remainder left
        assertApproxEqAbs(withdrawRequestNFTInstance.getEEthRemainderAmount(), 0, 1e9, "All remainder should be handled");
    }

    function test_HandleRemainder_DifferentSplitRatios() public {
        // Test with different treasury split ratios
        uint16[] memory splitRatios = new uint16[](3);
        splitRatios[0] = 2000; // 20%
        splitRatios[1] = 5000; // 50%
        splitRatios[2] = 8000; // 80%

        address[] memory testUsers = new address[](3);
        testUsers[0] = bob;
        testUsers[1] = makeAddr("user2");
        vm.etch(testUsers[1], bytes(""));
        testUsers[2] = makeAddr("user3");
        vm.etch(testUsers[2], bytes(""));

        for (uint256 i = 0; i < splitRatios.length; i++) {
            address user = testUsers[i];

            // Setup: Create remainder by depositing, requesting withdrawal, rebase, and claiming
            vm.deal(user, 10 ether);
            vm.startPrank(user);
            liquidityPoolInstance.deposit{value: 10 ether}();
            eETHInstance.approve(address(liquidityPoolInstance), 5 ether);
            uint256 requestId = liquidityPoolInstance.requestWithdraw(user, 5 ether);
            vm.stopPrank();

            // Rebase to create remainder (increase liquidity pool's ETH backing)
            vm.prank(address(etherFiAdminInstance));
            liquidityPoolInstance.rebase(5 ether);

            // Finalize and claim the withdrawal to create remainder
            vm.prank(ETHERFI_ADMIN);
            withdrawRequestNFTInstance.finalizeRequests(requestId);

            vm.prank(user);
            withdrawRequestNFTInstance.claimWithdraw(requestId);

            uint256 remainderAmount = withdrawRequestNFTInstance.getEEthRemainderAmount();
            assertGt(remainderAmount, 0, "Remainder amount should be greater than 0");

            // Update split ratio — onlyAdmin now resolves to OPERATION_TIMELOCK_ROLE,
            // which `admin` is granted in TestSetup.
            vm.prank(admin);
            withdrawRequestNFTInstance.updateShareRemainderSplitToTreasuryInBps(splitRatios[i]);

            // Grant the IMPLICIT_FEE_CLAIMER_ROLE to alice
            vm.startPrank(address(roleRegistryInstance.owner()));
            withdrawRequestNFTInstance.upgradeTo(_newWrnImpl());
            roleRegistryInstance.grantRole(roleRegistryInstance.HOUSEKEEPING_OPERATIONS_ROLE(), alice);
            vm.stopPrank();

            uint256 nominalToTreasury = Math.mulDiv(remainderAmount, splitRatios[i], 10000);
            uint256 expectedSharesToTreasury = liquidityPoolInstance.sharesForAmount(nominalToTreasury);

            uint256 treasurySharesBefore = eETHInstance.shares(buybackWallet);

            vm.prank(alice);
            withdrawRequestNFTInstance.handleRemainder(remainderAmount);

            uint256 treasurySharesAfter = eETHInstance.shares(buybackWallet);

            assertApproxEqAbs(treasurySharesAfter - treasurySharesBefore, expectedSharesToTreasury, 10,
                string(abi.encodePacked("Treasury should receive correct shares for ratio ", vm.toString(splitRatios[i]))));
        }
    }
}
