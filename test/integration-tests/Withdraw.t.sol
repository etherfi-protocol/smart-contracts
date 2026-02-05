// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "../TestSetup.sol";
import "lib/BucketLimiter.sol";
import "../../script/deploys/Deployed.s.sol";
import "../../src/interfaces/IWeETHWithdrawAdapter.sol";

contract WithdrawIntegrationTest is TestSetup, Deployed {
    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address public constant LIDO_ADDRESS = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);
        vm.etch(alice, bytes(""));

        // Handle any pending oracle report that hasn't been processed yet
        _syncOracleReportState();
    }

    /// @dev Syncs the oracle's lastPublishedReportRefSlot with the admin's lastHandledReportRefSlot
    ///      This is necessary when forking mainnet where there may be a pending report
    function _syncOracleReportState() internal {
        uint32 lastPublished = etherFiOracleInstance.lastPublishedReportRefSlot();
        uint32 lastHandled = etherFiAdminInstance.lastHandledReportRefSlot();

        if (lastPublished != lastHandled) {
            // Use the oracle's admin function to sync the state
            // Get the oracle admin (owner in this case)
            address oracleOwner = etherFiOracleInstance.owner();
            uint32 lastPublishedBlock = etherFiOracleInstance.lastPublishedReportRefBlock();
            
            vm.prank(oracleOwner);
            etherFiOracleInstance.updateLastPublishedBlockStamps(lastHandled, lastPublishedBlock);
        }
    }

    function test_Withdraw_EtherFiRedemptionManager_redeemEEth() public {
        // setUp();
        vm.startPrank(OPERATING_TIMELOCK);
        // Ensure bucket limiter has enough capacity and is fully refilled
        etherFiRedemptionManagerInstance.setCapacity(3000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(3000 ether, ETH_ADDRESS);
        vm.stopPrank();
        
        // Warp time forward to ensure bucket is fully refilled
        vm.warp(block.timestamp + 1);
        vm.deal(alice, 2010 ether);
        vm.startPrank(alice);

        liquidityPoolInstance.deposit{value: 2005 ether}();
        address receiver = makeAddr("withdraw-receiver");
        vm.etch(receiver, bytes(""));

        uint256 beforeEETHBalance = eETHInstance.balanceOf(alice);
        uint256 eETHAmountToRedeem = 2000 ether;
        uint256 beforeReceiverBalance = address(receiver).balance;
        uint256 beforeTreasuryBalance = eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury()));
        address treasury = address(etherFiRedemptionManagerInstance.treasury());

        // Get actual fee configuration from contract
        (, uint16 exitFeeSplitToTreasuryBps, uint16 exitFeeBps, ) = 
            etherFiRedemptionManagerInstance.tokenToRedemptionInfo(ETH_ADDRESS);
        
        // Calculate expected values using shares (more accurate)
        uint256 eEthShares = liquidityPoolInstance.sharesForAmount(eETHAmountToRedeem);
        uint256 expectedAmountToReceiver = liquidityPoolInstance.amountForShare((eEthShares * (10000 - exitFeeBps)) / 10000);
        uint256 eEthShareFee = eEthShares - liquidityPoolInstance.sharesForWithdrawalAmount(expectedAmountToReceiver);
        uint256 expectedTreasuryFee = liquidityPoolInstance.amountForShare((eEthShareFee * exitFeeSplitToTreasuryBps) / 10000);

        eETHInstance.approve(address(etherFiRedemptionManagerInstance), eETHAmountToRedeem);
        etherFiRedemptionManagerInstance.redeemEEth(eETHAmountToRedeem, receiver, ETH_ADDRESS);

        assertApproxEqAbs(address(receiver).balance, beforeReceiverBalance + expectedAmountToReceiver, 1e15); // receiver gets ETH
        assertApproxEqAbs(eETHInstance.balanceOf(alice), beforeEETHBalance - eETHAmountToRedeem, 1e15); // eETH is consumed from alice
        assertApproxEqAbs(eETHInstance.balanceOf(treasury), beforeTreasuryBalance + expectedTreasuryFee, 1e15); // treasury gets ETH

        vm.stopPrank();
    }

    function test_Withdraw_EtherFiRedemptionManager_redeemEEthWithPermit() public {
        vm.startPrank(OPERATING_TIMELOCK);
        // Ensure bucket limiter has enough capacity and is fully refilled
        etherFiRedemptionManagerInstance.setCapacity(3000 ether, ETH_ADDRESS);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(3000 ether, ETH_ADDRESS);
        vm.stopPrank();
        
        // Warp time forward to ensure bucket is fully refilled
        vm.warp(block.timestamp + 1);
        vm.deal(alice, 2010 ether);
        vm.startPrank(alice);

        liquidityPoolInstance.deposit{value: 2005 ether}();
        address receiver = makeAddr("withdraw-receiver");
        vm.etch(receiver, bytes(""));

        uint256 beforeEETHBalance = eETHInstance.balanceOf(alice);
        uint256 eETHAmountToRedeem = 2000 ether;
        uint256 beforeReceiverBalance = address(receiver).balance;
        uint256 beforeTreasuryBalance = eETHInstance.balanceOf(address(etherFiRedemptionManagerInstance.treasury()));
        address treasury = address(etherFiRedemptionManagerInstance.treasury());

        IeETH.PermitInput memory permit = eEth_createPermitInput(2, address(etherFiRedemptionManagerInstance), eETHAmountToRedeem, eETHInstance.nonces(alice), 2**256 - 1, eETHInstance.DOMAIN_SEPARATOR()); // alice = vm.addr(2)

        // Get actual fee configuration from contract
        (, uint16 exitFeeSplitToTreasuryBps, uint16 exitFeeBps, ) = 
            etherFiRedemptionManagerInstance.tokenToRedemptionInfo(ETH_ADDRESS);
        
        // Calculate expected values using shares (more accurate)
        uint256 eEthShares = liquidityPoolInstance.sharesForAmount(eETHAmountToRedeem);
        uint256 expectedAmountToReceiver = liquidityPoolInstance.amountForShare((eEthShares * (10000 - exitFeeBps)) / 10000);
        uint256 eEthShareFee = eEthShares - liquidityPoolInstance.sharesForWithdrawalAmount(expectedAmountToReceiver);
        uint256 expectedTreasuryFee = liquidityPoolInstance.amountForShare((eEthShareFee * exitFeeSplitToTreasuryBps) / 10000);

        eETHInstance.approve(address(etherFiRedemptionManagerInstance), eETHAmountToRedeem);
        etherFiRedemptionManagerInstance.redeemEEthWithPermit(eETHAmountToRedeem, receiver, permit, ETH_ADDRESS);

        assertApproxEqAbs(address(receiver).balance, beforeReceiverBalance + expectedAmountToReceiver, 1e15); // receiver gets ETH
        assertApproxEqAbs(eETHInstance.balanceOf(alice), beforeEETHBalance - eETHAmountToRedeem, 1e15); // eETH is consumed from alice
        assertApproxEqAbs(eETHInstance.balanceOf(treasury), beforeTreasuryBalance + expectedTreasuryFee, 1e15); // treasury gets ETH

        vm.stopPrank();
    }

    function test_Withdraw_EtherFiRedemptionManager_redeemWeEth() public {
        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: 10 ether}(); // to get eETH to generate weETH
        eETHInstance.approve(address(weEthInstance), 10 ether);
        weEthInstance.wrap(1 ether); // to get weETH to redeem

        uint256 weEthAmount = weEthInstance.balanceOf(alice);
        uint256 eEthAmount = weEthInstance.getEETHByWeETH(weEthAmount);
        uint256 eEthShares = liquidityPoolInstance.sharesForAmount(eEthAmount);
        // NOTE: on mainnet forks, vm.addr(N) can map to an address that already has code
        // and may forward ETH in its receive/fallback, making balance-based asserts flaky.
        address receiver = makeAddr("withdraw-receiver");
        vm.etch(receiver, bytes(""));
        uint256 receiverBalance = address(receiver).balance;
        address treasury = etherFiRedemptionManagerInstance.treasury();
        uint256 treasuryBalanceBefore = eETHInstance.balanceOf(treasury);
        uint256 beforeWeETHBalance = weEthInstance.balanceOf(alice);

        weEthInstance.approve(address(etherFiRedemptionManagerInstance), 1 ether);
        etherFiRedemptionManagerInstance.redeemWeEth(weEthAmount, receiver, ETH_ADDRESS);

        // Use exact same calculation flow as _calcRedemption to account for rounding differences
        (, uint16 exitFeeSplitToTreasuryBps, uint16 exitFeeBps, ) = 
            etherFiRedemptionManagerInstance.tokenToRedemptionInfo(ETH_ADDRESS);
        uint256 expectedAmountToReceiver = liquidityPoolInstance.amountForShare(
            eEthShares * (10000 - exitFeeBps) / 10000
        );
        uint256 sharesToBurn = liquidityPoolInstance.sharesForWithdrawalAmount(expectedAmountToReceiver);
        uint256 eEthShareFee = eEthShares - sharesToBurn;
        uint256 feeShareToTreasury = eEthShareFee * exitFeeSplitToTreasuryBps / 10000;
        uint256 expectedTreasuryFee = liquidityPoolInstance.amountForShare(feeShareToTreasury);
        
        assertApproxEqAbs(eETHInstance.balanceOf(treasury), treasuryBalanceBefore + expectedTreasuryFee, 1e15); // treasury gets ETH
        assertApproxEqAbs(address(receiver).balance, receiverBalance + expectedAmountToReceiver, 1e15); // receiver gets ETH
        vm.stopPrank();
    }

    function test_Withdraw_EtherFiRedemptionManager_redeemWeEthWithPermit() public {

        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: 10 ether}(); // to get eETH to generate weETH
        eETHInstance.approve(address(weEthInstance), 10 ether);
        weEthInstance.wrap(1 ether); // to get weETH to redeem

        uint256 weEthAmount = weEthInstance.balanceOf(alice);
        uint256 eEthAmount = weEthInstance.getEETHByWeETH(weEthAmount);
        uint256 eEthShares = liquidityPoolInstance.sharesForAmount(eEthAmount);
        // NOTE: on mainnet forks, vm.addr(N) can map to an address that already has code
        // and may forward ETH in its receive/fallback, making balance-based asserts flaky.
        address receiver = makeAddr("withdraw-receiver");
        vm.etch(receiver, bytes(""));
        uint256 receiverBalance = address(receiver).balance;
        address treasury = etherFiRedemptionManagerInstance.treasury();
        uint256 treasuryBalanceBefore = eETHInstance.balanceOf(treasury);
        uint256 beforeWeETHBalance = weEthInstance.balanceOf(alice);

        IWeETH.PermitInput memory permit = weEth_createPermitInput(2, address(etherFiRedemptionManagerInstance), weEthAmount, weEthInstance.nonces(alice), 2**256 - 1, weEthInstance.DOMAIN_SEPARATOR()); // alice = vm.addr(2)

        weEthInstance.approve(address(etherFiRedemptionManagerInstance), 1 ether);
        etherFiRedemptionManagerInstance.redeemWeEthWithPermit(weEthAmount, receiver, permit, ETH_ADDRESS);

        // Use exact same calculation flow as _calcRedemption to account for rounding differences
        (, uint16 exitFeeSplitToTreasuryBps, uint16 exitFeeBps, ) = 
            etherFiRedemptionManagerInstance.tokenToRedemptionInfo(ETH_ADDRESS);
        uint256 expectedAmountToReceiver = liquidityPoolInstance.amountForShare(
            eEthShares * (10000 - exitFeeBps) / 10000
        );
        uint256 sharesToBurn = liquidityPoolInstance.sharesForWithdrawalAmount(expectedAmountToReceiver);
        uint256 eEthShareFee = eEthShares - sharesToBurn;
        uint256 feeShareToTreasury = eEthShareFee * exitFeeSplitToTreasuryBps / 10000;
        uint256 expectedTreasuryFee = liquidityPoolInstance.amountForShare(feeShareToTreasury);
        
        assertApproxEqAbs(eETHInstance.balanceOf(treasury), treasuryBalanceBefore + expectedTreasuryFee, 1e15); // treasury gets ETH
        assertApproxEqAbs(address(receiver).balance, receiverBalance + expectedAmountToReceiver, 1e15); // receiver gets ETH
        vm.stopPrank();
    }

    function test_LiquidityPool_requestWithdraw() public {
        vm.deal(alice, 100 ether);
        uint256 amountToWithdraw = 1 ether;
        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: amountToWithdraw}();

        uint256 nextRequestId = withdrawRequestNFTInstance.nextRequestId();

        uint256 beforeAliceBalance = alice.balance;
        eETHInstance.approve(address(liquidityPoolInstance), amountToWithdraw);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(alice, amountToWithdraw);
        assertEq(requestId, nextRequestId);
        assertEq(withdrawRequestNFTInstance.ownerOf(requestId), alice);
        assertEq(withdrawRequestNFTInstance.getRequest(requestId).isValid, true);
        assertEq(withdrawRequestNFTInstance.getRequest(requestId).feeGwei, 0);
        vm.stopPrank();
        // Advance time until the oracle considers the next report epoch finalized.
        // Condition inside oracle: (slotEpoch + 2 < currEpoch)  <=>  currEpoch >= slotEpoch + 3
        while (true) {
            uint32 slot = etherFiOracleInstance.slotForNextReport();
            uint32 curr = etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp);
            uint32 min = ((slot / 32) + 3) * 32;
            if (curr >= min) break;
            uint256 d = min - curr;
            vm.roll(block.number + d);
            vm.warp(etherFiOracleInstance.beaconGenesisTimestamp() + 12 * (curr + uint32(d)));
        }

        IEtherFiOracle.OracleReport memory report;
        uint256[] memory emptyVals = new uint256[](0);
        report = IEtherFiOracle.OracleReport(
            etherFiOracleInstance.consensusVersion(), 0, 0, 0, 0, 0, 0, emptyVals, emptyVals, 0, 0
        );
        report.lastFinalizedWithdrawalRequestId = uint32(requestId);

        (report.refSlotFrom, report.refSlotTo, report.refBlockFrom) = etherFiOracleInstance.blockStampForNextReport();
        // Set refBlockTo to a block number that is < block.number and > lastAdminExecutionBlock
        report.refBlockTo = uint32(block.number - 1);
        if (report.refBlockTo <= etherFiAdminInstance.lastAdminExecutionBlock()) {
            report.refBlockTo = etherFiAdminInstance.lastAdminExecutionBlock() + 1;
        }

        vm.prank(AVS_OPERATOR_1);
        etherFiOracleInstance.submitReport(report);

        vm.prank(AVS_OPERATOR_2);
        etherFiOracleInstance.submitReport(report);

        // Advance time for postReportWaitTimeInSlots
        uint256 slotsToWait = uint256(etherFiAdminInstance.postReportWaitTimeInSlots() + 1);
        uint32 slotAfterReport = etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp);
        vm.roll(block.number + slotsToWait);
        vm.warp(etherFiOracleInstance.beaconGenesisTimestamp() + 12 * (slotAfterReport + slotsToWait));

        vm.prank(ADMIN_EOA);
        etherFiAdminInstance.executeTasks(report);

        vm.startPrank(alice);
        withdrawRequestNFTInstance.claimWithdraw(requestId);
        assertApproxEqAbs(alice.balance, beforeAliceBalance + amountToWithdraw, 1e3);
        vm.stopPrank();
    }

    function test_LiquidityPool_requestWithdrawWithPermit() public {
        vm.deal(alice, 100 ether);
        uint256 amountToWithdraw = 1 ether;
        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: amountToWithdraw}();

        uint256 nextRequestId = withdrawRequestNFTInstance.nextRequestId();

        ILiquidityPool.PermitInput memory permit = createPermitInput(2, address(liquidityPoolInstance), amountToWithdraw, eETHInstance.nonces(alice), 2**256 - 1, eETHInstance.DOMAIN_SEPARATOR()); // alice = vm.addr(2)

        uint256 beforeAliceBalance = alice.balance;
        uint256 requestId = liquidityPoolInstance.requestWithdrawWithPermit(alice, amountToWithdraw, permit);
        assertEq(requestId, nextRequestId);
        assertEq(withdrawRequestNFTInstance.ownerOf(requestId), alice);
        assertEq(withdrawRequestNFTInstance.getRequest(requestId).isValid, true);
        assertEq(withdrawRequestNFTInstance.getRequest(requestId).feeGwei, 0);
        vm.stopPrank();
        // Advance time until the oracle considers the next report epoch finalized.
        // Condition inside oracle: (slotEpoch + 2 < currEpoch)  <=>  currEpoch >= slotEpoch + 3
        while (true) {
            uint32 slot = etherFiOracleInstance.slotForNextReport();
            uint32 curr = etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp);
            uint32 min = ((slot / 32) + 3) * 32;
            if (curr >= min) break;
            uint256 d = min - curr;
            vm.roll(block.number + d);
            vm.warp(etherFiOracleInstance.beaconGenesisTimestamp() + 12 * (curr + uint32(d)));
        }

                IEtherFiOracle.OracleReport memory report;
        uint256[] memory emptyVals = new uint256[](0);
        report = IEtherFiOracle.OracleReport(
            etherFiOracleInstance.consensusVersion(), 0, 0, 0, 0, 0, 0, emptyVals, emptyVals, 0, 0
        );
        report.lastFinalizedWithdrawalRequestId = uint32(requestId);

        (report.refSlotFrom, report.refSlotTo, report.refBlockFrom) = etherFiOracleInstance.blockStampForNextReport();
        // Set refBlockTo to a block number that is < block.number and > lastAdminExecutionBlock
        report.refBlockTo = uint32(block.number - 1);
        if (report.refBlockTo <= etherFiAdminInstance.lastAdminExecutionBlock()) {
            report.refBlockTo = etherFiAdminInstance.lastAdminExecutionBlock() + 1;
        }

        vm.prank(AVS_OPERATOR_1);
        etherFiOracleInstance.submitReport(report);

        vm.prank(AVS_OPERATOR_2);
        etherFiOracleInstance.submitReport(report);

        // Advance time for postReportWaitTimeInSlots
        uint256 slotsToWait = uint256(etherFiAdminInstance.postReportWaitTimeInSlots() + 1);
        uint32 slotAfterReport = etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp);
        vm.roll(block.number + slotsToWait);
        vm.warp(etherFiOracleInstance.beaconGenesisTimestamp() + 12 * (slotAfterReport + slotsToWait));

        vm.prank(ADMIN_EOA);
        etherFiAdminInstance.executeTasks(report);

        vm.startPrank(alice);
        withdrawRequestNFTInstance.claimWithdraw(requestId);
        assertApproxEqAbs(alice.balance, beforeAliceBalance + amountToWithdraw, 1e3);
        vm.stopPrank();
    }

    function test_LiquidityPool_requestWithdraw_batchClaimWithdraw() public {
        vm.deal(alice, 100 ether);
        uint256 numRequests = 3;
        uint256 amountPerRequest = 1 ether;
        uint256 totalAmountToWithdraw = amountPerRequest * numRequests;
        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: totalAmountToWithdraw}();

        uint256 nextRequestId = withdrawRequestNFTInstance.nextRequestId();

        uint256 beforeAliceBalance = alice.balance;
        eETHInstance.approve(address(liquidityPoolInstance), totalAmountToWithdraw);

        uint256[] memory tokenIds = new uint256[](numRequests);
        uint256 requestId;
        for (uint256 i = 0; i < numRequests; i++) {
            requestId = liquidityPoolInstance.requestWithdraw(alice, amountPerRequest);
            tokenIds[i] = requestId;

            assertEq(requestId, nextRequestId + i);
            assertEq(withdrawRequestNFTInstance.ownerOf(requestId), alice);
            assertEq(withdrawRequestNFTInstance.getRequest(requestId).isValid, true);
            assertEq(withdrawRequestNFTInstance.getRequest(requestId).feeGwei, 0);
        }
        vm.stopPrank();
        // Advance time until the oracle considers the next report epoch finalized.
        // Condition inside oracle: (slotEpoch + 2 < currEpoch)  <=>  currEpoch >= slotEpoch + 3
        while (true) {
            uint32 slot = etherFiOracleInstance.slotForNextReport();
            uint32 curr = etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp);
            uint32 min = ((slot / 32) + 3) * 32;
            if (curr >= min) break;
            uint256 d = min - curr;
            vm.roll(block.number + d);
            vm.warp(etherFiOracleInstance.beaconGenesisTimestamp() + 12 * (curr + uint32(d)));
        }

        IEtherFiOracle.OracleReport memory report;
        uint256[] memory emptyVals = new uint256[](0);
        report = IEtherFiOracle.OracleReport(
            etherFiOracleInstance.consensusVersion(), 0, 0, 0, 0, 0, 0, emptyVals, emptyVals, 0, 0
        );
        report.lastFinalizedWithdrawalRequestId = uint32(requestId);

        (report.refSlotFrom, report.refSlotTo, report.refBlockFrom) = etherFiOracleInstance.blockStampForNextReport();
        // Set refBlockTo to a block number that is < block.number and > lastAdminExecutionBlock
        report.refBlockTo = uint32(block.number - 1);
        if (report.refBlockTo <= etherFiAdminInstance.lastAdminExecutionBlock()) {
            report.refBlockTo = etherFiAdminInstance.lastAdminExecutionBlock() + 1;
        }

        vm.prank(AVS_OPERATOR_1);
        etherFiOracleInstance.submitReport(report);

        vm.prank(AVS_OPERATOR_2);
        etherFiOracleInstance.submitReport(report);

        // Advance time for postReportWaitTimeInSlots
        uint256 slotsToWait = uint256(etherFiAdminInstance.postReportWaitTimeInSlots() + 1);
        uint32 slotAfterReport = etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp);
        vm.roll(block.number + slotsToWait);
        vm.warp(etherFiOracleInstance.beaconGenesisTimestamp() + 12 * (slotAfterReport + slotsToWait));

        vm.prank(ADMIN_EOA);
        etherFiAdminInstance.executeTasks(report);

        vm.startPrank(alice);
        withdrawRequestNFTInstance.batchClaimWithdraw(tokenIds);
        assertApproxEqAbs(alice.balance, beforeAliceBalance + totalAmountToWithdraw, 1e3);
        vm.stopPrank();
    }

    function test_EtherFiRestaker_withdrawEther_sendsEthToLiquidityPool() public {
        uint256 amount = 3 ether;
        vm.deal(address(etherFiRestakerInstance), amount);

        uint256 lpBalanceBefore = address(liquidityPoolInstance).balance;
        uint256 restakerBalanceBefore = address(etherFiRestakerInstance).balance;
        assertEq(restakerBalanceBefore, amount);

        vm.prank(etherFiRestakerInstance.owner());
        etherFiRestakerInstance.withdrawEther();

        assertEq(address(etherFiRestakerInstance).balance, 0);
        assertEq(address(liquidityPoolInstance).balance, lpBalanceBefore + amount);
    }

    function test_EtherFiRestaker_undelegate_tracksWithdrawalRoots() public {
        bool delegatedBefore = etherFiRestakerInstance.isDelegated();

        vm.prank(etherFiRestakerInstance.owner());
        if (!delegatedBefore) {
            vm.expectRevert();
            etherFiRestakerInstance.undelegate();
            return;
        }

        bytes32[] memory roots = etherFiRestakerInstance.undelegate();

        assertEq(etherFiRestakerInstance.isDelegated(), false);
        for (uint256 i = 0; i < roots.length; i++) {
            assertEq(etherFiRestakerInstance.isPendingWithdrawal(roots[i]), true);
        }
    }

    function test_Withdraw_WeETHWithdrawAdapter_requestWithdraw() public {
        vm.deal(alice, 100 ether);

        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: 10 ether}(); // mint eETH for wrapping

        uint256 eEthToWrap = 1 ether;
        eETHInstance.approve(address(weEthInstance), eEthToWrap);
        weEthInstance.wrap(eEthToWrap);

        uint256 weEthAmountToWithdraw = weEthInstance.balanceOf(alice);
        weEthInstance.approve(address(weEthWithdrawAdapterInstance), weEthAmountToWithdraw);

        uint256 nextRequestId = withdrawRequestNFTInstance.nextRequestId();
        uint256 requestId = weEthWithdrawAdapterInstance.requestWithdraw(weEthAmountToWithdraw, alice);
        assertEq(requestId, nextRequestId);
        assertEq(withdrawRequestNFTInstance.ownerOf(requestId), alice);
        assertEq(withdrawRequestNFTInstance.getRequest(requestId).isValid, true);
        assertEq(withdrawRequestNFTInstance.getRequest(requestId).feeGwei, 0);
        vm.stopPrank();
        // Advance time until the oracle considers the next report epoch finalized.
        // Condition inside oracle: (slotEpoch + 2 < currEpoch)  <=>  currEpoch >= slotEpoch + 3
        while (true) {
            uint32 slot = etherFiOracleInstance.slotForNextReport();
            uint32 curr = etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp);
            uint32 min = ((slot / 32) + 3) * 32;
            if (curr >= min) break;
            uint256 d = min - curr;
            vm.roll(block.number + d);
            vm.warp(etherFiOracleInstance.beaconGenesisTimestamp() + 12 * (curr + uint32(d)));
        }

        IEtherFiOracle.OracleReport memory report;
        uint256[] memory emptyVals = new uint256[](0);
        report = IEtherFiOracle.OracleReport(
            etherFiOracleInstance.consensusVersion(), 0, 0, 0, 0, 0, 0, emptyVals, emptyVals, 0, 0
        );
        report.lastFinalizedWithdrawalRequestId = uint32(requestId);

        (report.refSlotFrom, report.refSlotTo, report.refBlockFrom) = etherFiOracleInstance.blockStampForNextReport();
        // Set refBlockTo to a block number that is < block.number and > lastAdminExecutionBlock
        report.refBlockTo = uint32(block.number - 1);
        if (report.refBlockTo <= etherFiAdminInstance.lastAdminExecutionBlock()) {
            report.refBlockTo = etherFiAdminInstance.lastAdminExecutionBlock() + 1;
        }

        vm.prank(AVS_OPERATOR_1);
        etherFiOracleInstance.submitReport(report);

        vm.prank(AVS_OPERATOR_2);
        etherFiOracleInstance.submitReport(report);

        // Advance time for postReportWaitTimeInSlots
        uint256 slotsToWait = uint256(etherFiAdminInstance.postReportWaitTimeInSlots() + 1);
        uint32 slotAfterReport = etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp);
        vm.roll(block.number + slotsToWait);
        vm.warp(etherFiOracleInstance.beaconGenesisTimestamp() + 12 * (slotAfterReport + slotsToWait));

        vm.prank(ADMIN_EOA);
        etherFiAdminInstance.executeTasks(report);

        vm.startPrank(alice);
        uint256 claimableAmount = withdrawRequestNFTInstance.getClaimableAmount(requestId);
        uint256 beforeClaimBalance = alice.balance;
        withdrawRequestNFTInstance.claimWithdraw(requestId);
        assertApproxEqAbs(alice.balance, beforeClaimBalance + claimableAmount, 1e3);
        vm.stopPrank();
    }

    function test_Withdraw_WeETHWithdrawAdapter_requestWithdrawWithPermit() public {
        vm.deal(alice, 100 ether);

        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: 10 ether}(); // mint eETH for wrapping

        uint256 eEthToWrap = 1 ether;
        eETHInstance.approve(address(weEthInstance), eEthToWrap);
        weEthInstance.wrap(eEthToWrap);

        uint256 weEthAmountToWithdraw = weEthInstance.balanceOf(alice);

        IWeETH.PermitInput memory weEthPermit = weEth_createPermitInput(
            2,
            address(weEthWithdrawAdapterInstance),
            weEthAmountToWithdraw,
            weEthInstance.nonces(alice),
            2 ** 256 - 1,
            weEthInstance.DOMAIN_SEPARATOR()
        );

        IWeETHWithdrawAdapter.PermitInput memory permit = IWeETHWithdrawAdapter.PermitInput({
            value: weEthPermit.value,
            deadline: weEthPermit.deadline,
            v: weEthPermit.v,
            r: weEthPermit.r,
            s: weEthPermit.s
        });

        uint256 nextRequestId = withdrawRequestNFTInstance.nextRequestId();
        uint256 requestId = weEthWithdrawAdapterInstance.requestWithdrawWithPermit(weEthAmountToWithdraw, alice, permit);
        assertEq(requestId, nextRequestId);
        assertEq(withdrawRequestNFTInstance.ownerOf(requestId), alice);
        assertEq(withdrawRequestNFTInstance.getRequest(requestId).isValid, true);
        assertEq(withdrawRequestNFTInstance.getRequest(requestId).feeGwei, 0);
        vm.stopPrank();
        // Advance time until the oracle considers the next report epoch finalized.
        // Condition inside oracle: (slotEpoch + 2 < currEpoch)  <=>  currEpoch >= slotEpoch + 3
        while (true) {
            uint32 slot = etherFiOracleInstance.slotForNextReport();
            uint32 curr = etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp);
            uint32 min = ((slot / 32) + 3) * 32;
            if (curr >= min) break;
            uint256 d = min - curr;
            vm.roll(block.number + d);
            vm.warp(etherFiOracleInstance.beaconGenesisTimestamp() + 12 * (curr + uint32(d)));
        }

        IEtherFiOracle.OracleReport memory report;
        uint256[] memory emptyVals = new uint256[](0);
        report = IEtherFiOracle.OracleReport(
            etherFiOracleInstance.consensusVersion(), 0, 0, 0, 0, 0, 0, emptyVals, emptyVals, 0, 0
        );
        report.lastFinalizedWithdrawalRequestId = uint32(requestId);

        (report.refSlotFrom, report.refSlotTo, report.refBlockFrom) = etherFiOracleInstance.blockStampForNextReport();
        // Set refBlockTo to a block number that is < block.number and > lastAdminExecutionBlock
        report.refBlockTo = uint32(block.number - 1);
        if (report.refBlockTo <= etherFiAdminInstance.lastAdminExecutionBlock()) {
            report.refBlockTo = etherFiAdminInstance.lastAdminExecutionBlock() + 1;
        }

        vm.prank(AVS_OPERATOR_1);
        etherFiOracleInstance.submitReport(report);

        vm.prank(AVS_OPERATOR_2);
        etherFiOracleInstance.submitReport(report);

        // Advance time for postReportWaitTimeInSlots
        uint256 slotsToWait = uint256(etherFiAdminInstance.postReportWaitTimeInSlots() + 1);
        uint32 slotAfterReport = etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp);
        vm.roll(block.number + slotsToWait);
        vm.warp(etherFiOracleInstance.beaconGenesisTimestamp() + 12 * (slotAfterReport + slotsToWait));

        vm.prank(ADMIN_EOA);
        etherFiAdminInstance.executeTasks(report);

        vm.startPrank(alice);
        uint256 claimableAmount = withdrawRequestNFTInstance.getClaimableAmount(requestId);
        uint256 beforeClaimBalance = alice.balance;
        withdrawRequestNFTInstance.claimWithdraw(requestId);
        assertApproxEqAbs(alice.balance, beforeClaimBalance + claimableAmount, 1e3);
        vm.stopPrank();
    }

    
}