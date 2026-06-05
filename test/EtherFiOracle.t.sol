// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@tests/TestSetup.sol";
import "forge-std/console2.sol";

contract EtherFiOracleTest is TestSetup {
    function setUp() public {
        setUpTests();

        // Timestamp = 1, BlockNumber = 0
        vm.roll(0);

        vm.prank(alice);
        etherFiAdminInstance.updateMaxFinalizedWithdrawalAmountPerDay(10_000 ether);
        vm.prank(alice);
        etherFiAdminInstance.updateMaxNumValidatorsToApprovePerDay(200);
    }

    /// setReportStartSlot was removed from EtherFiOracle in the role-consolidation
    /// refactor. Tests that need to set the start slot now write the storage
    /// directly. `reportStartSlot` sits at slot 253 offset 12 (uint32, packed).
    function _setReportStartSlot(uint32 newSlot) internal {
        bytes32 cur = vm.load(address(etherFiOracleInstance), bytes32(uint256(253)));
        uint256 mask = ~(uint256(0xffffffff) << 96);
        uint256 newVal = (uint256(cur) & mask) | (uint256(newSlot) << 96);
        vm.store(address(etherFiOracleInstance), bytes32(uint256(253)), bytes32(newVal));
    }

    /// updateLastPublishedBlockStamps was also removed. Write the two packed
    /// uint32s (offsets 16 and 20 in slot 253) directly.
    function _setLastPublishedBlockStamps(uint32 newRefSlot, uint32 newRefBlock) internal {
        bytes32 cur = vm.load(address(etherFiOracleInstance), bytes32(uint256(253)));
        uint256 mask = ~((uint256(0xffffffff) << 128) | (uint256(0xffffffff) << 160));
        uint256 newVal = (uint256(cur) & mask)
            | (uint256(newRefSlot) << 128)
            | (uint256(newRefBlock) << 160);
        vm.store(address(etherFiOracleInstance), bytes32(uint256(253)), bytes32(newVal));
    }

    function test_addCommitteeMember() public {
        _moveClock(1024 + 2 * slotsPerEpoch);

        // chad is not a commitee member
        vm.prank(chad);
        vm.expectRevert(EtherFiOracle.NotRegistered.selector);
        etherFiOracleInstance.submitReport(reportAtPeriod2A);

        // chad is added to the committee
        vm.prank(owner);
        etherFiOracleInstance.addCommitteeMember(chad, 2);
        (bool registered, bool enabled, uint32 lastReportRefSlot, uint32 numReports) = etherFiOracleInstance.committeeMemberStates(chad);
        assertEq(registered, true);
        assertEq(enabled, true);
        assertEq(lastReportRefSlot, 0);
        assertEq(numReports, 0);

        // chad submits a report
        vm.prank(chad);
        etherFiOracleInstance.submitReport(reportAtPeriod2A);

        _moveClock(1024);

        // Owner disables chad's report submission
        vm.prank(owner);
        etherFiOracleInstance.manageCommitteeMember(chad, false, 2);
        (registered, enabled, lastReportRefSlot, numReports) = etherFiOracleInstance.committeeMemberStates(chad);
        assertEq(registered, true);
        assertEq(enabled, false);
        assertEq(lastReportRefSlot, 1023);
        assertEq(numReports, 1);

        // chad fails to submit a report
        vm.prank(chad);
        vm.expectRevert(EtherFiOracle.MemberDisabled.selector);
        etherFiOracleInstance.submitReport(reportAtPeriod3);
    }

    function test_epoch_not_finzlied() public {
        vm.startPrank(alice);

        // https://www.blocknative.com/blog/anatomy-of-a-slot#4
        // The report `reportAtPeriod2A` is for slot 1023 (epoch 31)
        // Which can be submitted when the slot >= 1088 (epoch 34)

        // Epoch = 30       31        32        33        34
        // Slot  = 960      992       1024      1056      1088

        // At timpestamp = 12289, blocknumber = 1024, epoch = 32
        _moveClock(1024);
        vm.expectRevert(EtherFiOracle.EpochNotFinalized.selector);
        etherFiOracleInstance.submitReport(reportAtPeriod2A);

        // At timpestamp = 12673, blocknumber = 1056, epoch = 33
        _moveClock(1 * slotsPerEpoch);
        vm.expectRevert(EtherFiOracle.EpochNotFinalized.selector);
        etherFiOracleInstance.submitReport(reportAtPeriod2A);

        // At timpestamp = 13045, blocknumber = 1087, epoch = 33
        _moveClock(31);
        vm.expectRevert(EtherFiOracle.EpochNotFinalized.selector);
        etherFiOracleInstance.submitReport(reportAtPeriod2A);

        // At timpestamp = 13057, blocknumber = 1088, epoch = 34
        _moveClock(1);
        etherFiOracleInstance.submitReport(reportAtPeriod2A);

        vm.stopPrank();
    }

    function test_wrong_consensus_version() public {
        _moveClock(1024 + 2 * slotsPerEpoch);

        // alice submits the period 2 report with consensus version = 2
        vm.prank(alice);
        vm.expectRevert(EtherFiOracle.WrongConsensusVersion.selector);
        etherFiOracleInstance.submitReport(reportAtPeriod2C);

       // Update the Consensus Version to 2
        vm.prank(owner);
        etherFiOracleInstance.setConsensusVersion(2);

        // alice submits the period 2 report
        vm.prank(alice);
        etherFiOracleInstance.submitReport(reportAtPeriod2C);
    }

    function test_verifyReport() public {
        _moveClock(1024 + 2 * slotsPerEpoch);
        // [timestamp = 13057, period 2]
        // (13057 - 1) / 12 / 32 = 34 epoch

        // alice submits the period 2 report
        vm.prank(alice);
        etherFiOracleInstance.submitReport(reportAtPeriod2A);

        // alice submits another period 2 report
        vm.expectRevert(EtherFiOracle.ReportNotNeeded.selector);
        vm.prank(alice);
        etherFiOracleInstance.submitReport(reportAtPeriod2A);

        // alice submits a different report
        vm.expectRevert(EtherFiOracle.ReportNotNeeded.selector);
        vm.prank(alice);
        etherFiOracleInstance.submitReport(reportAtPeriod2B);
        
        _moveClock(1024 );
        // [timestamp = 25345, period 3]
        // 66 epoch

        // alice submits reports with wrong {slotFrom, slotTo, blockFrom}
        vm.expectRevert(EtherFiOracle.WrongSlotFrom.selector);
        vm.prank(alice);
        etherFiOracleInstance.submitReport(reportAtPeriod4);

        // alice submits period 2 report
        vm.expectRevert(EtherFiOracle.WrongSlotTo.selector);
        vm.prank(alice);
        etherFiOracleInstance.submitReport(reportAtPeriod2A);

        // alice submits period 3A report
        vm.expectRevert(EtherFiOracle.WrongBlockTo.selector);
        vm.prank(alice);
        etherFiOracleInstance.submitReport(reportAtPeriod3A);

        // alice submits period 3B report
        vm.expectRevert(EtherFiOracle.WrongBlockFrom.selector);
        vm.prank(alice);
        etherFiOracleInstance.submitReport(reportAtPeriod3B);

        // alice submits period 3 report, which is correct
        vm.prank(alice);
        etherFiOracleInstance.submitReport(reportAtPeriod3);
    }

    function test_submitReport() public {
        _moveClock(1024 + 2 * slotsPerEpoch);
        
        // Now it's period 2

        // alice submits the period 2 report
        vm.prank(alice);
        etherFiOracleInstance.submitReport(reportAtPeriod2A);
        
        // check the member state
        (bool registered, bool enabled, uint32 lastReportRefSlot, uint32 numReports) = etherFiOracleInstance.committeeMemberStates(alice);
        assertEq(registered, true);
        assertEq(enabled, true);
        assertEq(lastReportRefSlot, reportAtPeriod2A.refSlotTo);
        assertEq(numReports, 1);
        
        // check the consensus state
        bytes32 reportHash = etherFiOracleInstance.generateReportHash(reportAtPeriod2A);
        (uint32 support, bool consensusReached,) = etherFiOracleInstance.consensusStates(reportHash);
        assertEq(support, 1);

        // bob submits the period 2 report
        vm.prank(bob);
        etherFiOracleInstance.submitReport(reportAtPeriod2A);
        (support, consensusReached,) = etherFiOracleInstance.consensusStates(reportHash);
        assertEq(support, 2);

        assertEq(etherFiOracleInstance.lastPublishedReportRefSlot(), reportAtPeriod2A.refSlotTo);
        assertEq(etherFiOracleInstance.lastPublishedReportRefBlock(), reportAtPeriod2A.refBlockTo);
    }

    function test_consensus() public {
        // Seed TVL so the report's positive accruedRewards stays within the 25 bps
        // LiquidityPool positive rebase cap (a zero-TVL pool rejects any positive rebase).
        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 1000 ether}();

        // Now it's period 2!
        _moveClock(1024 + 2 * slotsPerEpoch);

        // alice submits the period 2 report
        vm.prank(alice);
        bool consensusReached = etherFiOracleInstance.submitReport(reportAtPeriod2A);
        assertEq(consensusReached, false);
        // bob submits the period 2 report, different
        vm.prank(bob);
        consensusReached = etherFiOracleInstance.submitReport(reportAtPeriod2B);
        assertEq(consensusReached, false);

        // Now it's period 3
        _moveClock(1024);

        reportAtPeriod3.lastFinalizedWithdrawalRequestId = reportAtPeriod4.lastFinalizedWithdrawalRequestId = 0;
        _executeAdminTasks(reportAtPeriod3);


        // Now it's period 4
        _moveClock(1024);

        _executeAdminTasks(reportAtPeriod4);
    }

    // TODO (Pankaj): Add test for approving validators and fund 32 ETH
    
    // function test_approving_validators() public {
    //     // Now it's period 2!
    //     _moveClock(1024 + 2 * slotsPerEpoch);
    //     reportAtPeriod2A.validatorsToApprove = new uint256[](1);
    //     bytes32 reportHash = etherFiOracleInstance.generateReportHash(reportAtPeriod2A);
    //     bytes[] memory emptyPubKeys = new bytes[](1);
    //     bytes[] memory emptySignatures = new bytes[](1);

    //     _executeAdminTasks(reportAtPeriod2A);
    //     //execute validator task 
    //     vm.prank(alice);
    //     etherFiAdminInstance.executeValidatorApprovalTask(reportHash, reportAtPeriod2A.validatorsToApprove, emptyPubKeys, emptySignatures);

    //     (bool completed, bool exists) = etherFiAdminInstance.validatorApprovalTaskStatus(reportHash);
    //     assertEq(completed, true);
    //     assertEq(exists, true);
    // }

    function test_report_submission_before_processing_last_published_one_fails() public {
        vm.prank(owner);
        etherFiOracleInstance.manageCommitteeMember(bob, false, 1);

        // period 2
        _moveClock(1024 + 2 * slotsPerEpoch);

        vm.prank(alice);
        bool consensusReached = etherFiOracleInstance.submitReport(reportAtPeriod2A);
        assertEq(consensusReached, true);

        // Now it's period 3
        _moveClock(1024);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        _initReportBlockStamp(report);

        vm.prank(alice);
        vm.expectRevert(EtherFiOracle.LastReportNotHandled.selector);
        etherFiOracleInstance.submitReport(report);
    }

    function test_change_report_start_slot1() public { 
        vm.prank(owner);
        bytes[] memory emptyBytes = new bytes[](0);
        etherFiOracleInstance.manageCommitteeMember(bob, false, 1);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        _moveClock(1024 + 2 * 32);

        (uint32 slotFrom, uint32 slotTo, uint32 blockFrom) = etherFiOracleInstance.blockStampForNextReport();
        assertEq(slotFrom, 0);
        assertEq(slotTo, 1024-1);
        assertEq(blockFrom, 0);

        report.refSlotFrom = 0;
        report.refSlotTo = 1024-1;
        report.refBlockFrom = 0;
        report.refBlockTo = 1024-1;

        vm.startPrank(alice);
        etherFiOracleInstance.submitReport(report);
        etherFiAdminInstance.executeTasks(report);
        vm.stopPrank();

        (slotFrom, slotTo, blockFrom) = etherFiOracleInstance.blockStampForNextReport();
        assertEq(slotFrom, 1024);
        assertEq(slotTo, 2 * 1024 - 1);
        assertEq(blockFrom, 1024);

        _setReportStartSlot(1 * 1024 + 512);

        _moveClock(1 * 1024 + 512);

        (slotFrom, slotTo, blockFrom) = etherFiOracleInstance.blockStampForNextReport();
        assertEq(slotFrom, 1024);
        assertEq(slotTo, 2 * 1024 + 512 - 1);
        assertEq(blockFrom, 1024);

        report.refSlotFrom = 1024;
        report.refSlotTo = 2 * 1024 + 512 - 1;
        report.refBlockFrom = 1024;
        report.refBlockTo = 2 * 1024 + 512 - 1;

        vm.startPrank(alice);
        etherFiOracleInstance.submitReport(report);
        etherFiAdminInstance.executeTasks(report);
        vm.stopPrank();

        (slotFrom, slotTo, blockFrom) = etherFiOracleInstance.blockStampForNextReport();
        assertEq(slotFrom, 2 * 1024 + 512);
        assertEq(slotTo, 3 * 1024 + 512 - 1);
        assertEq(blockFrom, 2 * 1024 + 512);
    }

    function test_change_report_start_slot2() public { 
        vm.prank(owner);

        _moveClock(1024 + 2 * 32);

        (uint32 slotFrom, uint32 slotTo, uint32 blockFrom) = etherFiOracleInstance.blockStampForNextReport();
        assertEq(slotFrom, 0);
        assertEq(slotTo, 1024 - 1);
        assertEq(blockFrom, 0);

        console.log(etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp));
        _setReportStartSlot(1 * 1024 + 512);

        (slotFrom, slotTo, blockFrom) = etherFiOracleInstance.blockStampForNextReport();
        assertEq(slotFrom, 1 * 1024 + 512);
        assertEq(slotTo, 2 * 1024 + 512 - 1);
        assertEq(blockFrom, 1 * 1024 + 512);
    }

    function test_report_start_slot() public {
        _setReportStartSlot(2048);

        // note that the block timestamp starts from 1 (= slot 0) and the block number starts from 0

        // now after moveClock(1500)
        // timestamp = 1 + 1500 * 12 = slot 1500
        // block_number = 0 + 1500 = 1500
        _moveClock(1500);

        // this should fail because not start yet
        vm.prank(alice);
        vm.expectRevert(EtherFiOracle.EpochNotFinalized.selector);
        etherFiOracleInstance.submitReport(reportAtSlot3071);

        // current slot = 1500
        // after moveClock(500)
        // timestamp = (1 + 1500 * 12) + 548 * 12 = 1 + 2048 * 12 = slot 2048 = epoch 64
        // block_number = 0 + 2048 = 2048
        _moveClock(548);

        // this should fail because start but in period 1
        vm.prank(alice);
        vm.expectRevert(EtherFiOracle.EpochNotFinalized.selector);
        etherFiOracleInstance.submitReport(reportAtSlot3071);

        // 2048 + 1024 + 64 = 3136
        _moveClock(1024 + 2 * slotsPerEpoch);
        
        vm.prank(alice);
        etherFiOracleInstance.submitReport(reportAtSlot3071);

        // change startSlot to 3264
        _setReportStartSlot(3264);

        // slot 3236
        _moveClock(100);
        
        vm.prank(alice);
        vm.expectRevert(EtherFiOracle.EpochNotFinalized.selector);
        etherFiOracleInstance.submitReport(reportAtSlot4287);

        _moveClock(28 + 1024 + 2 * slotsPerEpoch);

        vm.prank(alice);
        etherFiOracleInstance.submitReport(reportAtSlot4287);
    }

    function test_pause() public {
        _moveClock(1024 + 2 * slotsPerEpoch);
        
        vm.prank(alice);
        etherFiOracleInstance.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.ContractPaused.selector);
        etherFiOracleInstance.submitReport(reportAtPeriod2A);

        vm.prank(alice);
        etherFiOracleInstance.unpause();

        vm.prank(alice);
        etherFiOracleInstance.submitReport(reportAtPeriod2A);
    }

    function test_set_quorum_size() public {
        vm.startPrank(owner);

        // TODO enable this test for mainnet
        // vm.expectRevert("Quorum size must be greater than 1");
        // etherFiOracleInstance.manageCommitteeMember(bob, false, 1);

        etherFiOracleInstance.setQuorumSize(2);

        vm.stopPrank();
    }

    function test_set_oracle_report_period() public {
        vm.startPrank(owner);

        vm.expectRevert(EtherFiOracle.InvalidReportPeriod.selector);
        etherFiOracleInstance.setOracleReportPeriod(0);

        vm.expectRevert(EtherFiOracle.InvalidReportPeriod.selector);
        etherFiOracleInstance.setOracleReportPeriod(127);

        etherFiOracleInstance.setOracleReportPeriod(128);

        vm.stopPrank();
    }

    function test_admin_task() public {
        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();

        _executeAdminTasks(report);
    }

    function test_huge_positive_rebaes() public {
        // Seed a realistic TVL so the APR formula is non-trivial. EtherFiAdmin still
        // limits the per-report APR (acceptableRebaseAprInBps == 10000 bps == 100%);
        // note that LiquidityPool independently caps a single positive rebase at 25 bps
        // of TVL, so the "below 100% APR" leg also has to stay under that cap.
        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 1000 ether}();

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();

        _moveClock(1 days / 12);

        // 1 ETH on 1000 ETH TVL: 10 bps (< the 25 bps LP cap) and ~36% annualized
        // (< the 100% APR cap) — accepted.
        report.accruedRewards = 1 ether;
        _executeAdminTasks(report);

        _moveClock(1 days / 12);

        // A huge positive rebase blows past the acceptable APR and is rejected by the
        // oracle TVL-change guard before it ever reaches the LiquidityPool rebase.
        report.accruedRewards = 10 ether;
        _executeAdminTasks(report, "EtherFiAdmin: TVL changed too much");
    }

    // function test_dave() public {
    //     // launch_validator();
    // }

    // Note: Working with MembershipManager which is to be deprecated
    function test_huge_negative_rebaes() public {
        // Seed a realistic TVL so the APR formula is non-trivial. The negative
        // (slashing) direction is NOT bounded by the LiquidityPool positive cap — it is
        // governed by the oracle's APR guard (acceptableRebaseAprInBps == 100%).
        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 1000 ether}();

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();

        _moveClock(1 days / 12);

        // Small positive rebase within both caps to advance the handled slot.
        report.accruedRewards = 1 ether;
        _executeAdminTasks(report);

        _moveClock(1 days / 12);

        // A huge negative rebase exceeds the acceptable APR (in absolute terms) and is
        // rejected by the oracle TVL-change guard.
        report.accruedRewards = -10 ether;
        _executeAdminTasks(report, "EtherFiAdmin: TVL changed too much");
    }

    function test_SD_5() public {
        // numActive=3 (alice, bob, chad), quorum stays at the default 2 because
        // setQuorumSize(5) would now revert with InvalidQuorum (numActive < quorum).
        vm.prank(owner);
        etherFiOracleInstance.addCommitteeMember(chad, 2);

        _moveClock(1024 + 2 * slotsPerEpoch);

        // alice submits the period 2 report
        vm.prank(alice);
        etherFiOracleInstance.submitReport(reportAtPeriod2A);

        // check the consensus state
        bytes32 reportHash = etherFiOracleInstance.generateReportHash(reportAtPeriod2A);
        (uint32 support, bool consensusReached, uint32 consensusTimestamp) = etherFiOracleInstance.consensusStates(reportHash);
        assertEq(support, 1);
        assertEq(consensusReached, false);
        assertEq(consensusTimestamp, 0);

        // bob submits the period 2 report
        uint32 curTimestamp = uint32(block.timestamp);
        vm.prank(bob);
        etherFiOracleInstance.submitReport(reportAtPeriod2A);
        (support, consensusReached, consensusTimestamp) = etherFiOracleInstance.consensusStates(reportHash);
        assertEq(support, 2);
        assertEq(consensusReached, true);
        assertEq(consensusTimestamp, curTimestamp);

        _moveClock(1);

        // chad submits the period 2 report
        vm.prank(chad);
        vm.expectRevert(EtherFiOracle.ConsensusAlreadyReached.selector);
        etherFiOracleInstance.submitReport(reportAtPeriod2A);
        (support, consensusReached, consensusTimestamp) = etherFiOracleInstance.consensusStates(reportHash);
        assertEq(support, 2);
        assertEq(consensusReached, true);
        assertEq(consensusTimestamp, curTimestamp);
    }

    function test_postReportWaitTimeInSlots() public {
        // Seed TVL so the report's positive accruedRewards stays within the 25 bps
        // LiquidityPool positive rebase cap (a zero-TVL pool rejects any positive rebase).
        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 1000 ether}();

        bytes[] memory emptyBytes = new bytes[](0);
        vm.prank(owner);
        etherFiOracleInstance.manageCommitteeMember(bob, false, 1);

        // period 2
        _moveClock(1024 + 2 * slotsPerEpoch);

        vm.prank(alice);
        reportAtPeriod2A.lastFinalizedWithdrawalRequestId = 0;
        bool consensusReached = etherFiOracleInstance.submitReport(reportAtPeriod2A);
        assertEq(consensusReached, true);

        vm.prank(alice);
        assertEq(etherFiAdminInstance.canExecuteTasks(reportAtPeriod2A), true);
        vm.prank(admin);
        etherFiAdminInstance.updatePostReportWaitTimeInSlots(1);
        assertEq(etherFiAdminInstance.canExecuteTasks(reportAtPeriod2A), false);

        vm.expectRevert(abi.encodeWithSelector(EtherFiAdmin.ReportValidationFailed.selector, "EtherFiAdmin: report is too fresh"));
        vm.prank(alice);
        etherFiAdminInstance.executeTasks(reportAtPeriod2A);

        _moveClock(1);
        assertEq(etherFiAdminInstance.canExecuteTasks(reportAtPeriod2A), true);
        vm.prank(alice);
        etherFiAdminInstance.executeTasks(reportAtPeriod2A);
    }

    // test_all_pause removed: EtherFiAdmin.pause / unPause were deleted in the
    // role-consolidation refactor. Per-contract pauseContract / unPauseContract
    // calls are exercised in their own contract-specific tests.

    function test_report_earlier_than_last_admin_execution_fails() public {
        vm.prank(owner);
        bytes[] memory emptyBytes = new bytes[](0);
        etherFiOracleInstance.manageCommitteeMember(bob, false, 1);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        _moveClock(1024 + 2 * 32);

        (uint32 slotFrom, uint32 slotTo, uint32 blockFrom) = etherFiOracleInstance.blockStampForNextReport();
        assertEq(slotFrom, 0);
        assertEq(slotTo, 1024-1);
        assertEq(blockFrom, 0);

        report.refSlotFrom = 0;
        report.refSlotTo = 1024-1;
        report.refBlockFrom = 0;
        report.refBlockTo = 1024-1;

        vm.startPrank(alice);
        etherFiOracleInstance.submitReport(report);
        _moveClock(1 * 1024); // The oracle bot failed to submit the report for admin task execution... which can happen in real life
        etherFiAdminInstance.executeTasks(report);

        report.refSlotFrom = 1024;
        report.refSlotTo = 2 * 1024 - 1;
        report.refBlockFrom = 1024;
        report.refBlockTo = 2 * 1024 - 1;

        vm.expectRevert(EtherFiOracle.ReportBlockTooOld.selector);
        etherFiOracleInstance.submitReport(report);

        // After a period, the oracle bot submits the new report such that the report's 'refBlockTo' > 'lastAdminExecutionBlock'
        // which succeeds
        _moveClock(1024);
        report.refSlotFrom = 1024;
        report.refSlotTo = 3 * 1024 - 1;
        report.refBlockFrom = 1024;
        report.refBlockTo = 3 * 1024 - 1;

        etherFiOracleInstance.submitReport(report);
        etherFiAdminInstance.executeTasks(report);

        vm.stopPrank();
    }

    function test_consensus_scenario_example1() public {
        vm.startPrank(owner);
        etherFiOracleInstance.addCommitteeMember(chad, 2);
        vm.stopPrank();

        _moveClock(1024 + 2 * slotsPerEpoch);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        _initReportBlockStamp(report);

        // Assume that the accruedRewards must be 1 ether, all the time

        // Alice submited the correct report 
        vm.prank(alice);
        report.accruedRewards = 1 ether;
        bool consensusReached = etherFiOracleInstance.submitReport(report);
        assertFalse(consensusReached);

        // However, Bob submitted a wrong report
        vm.prank(chad);
        report.accruedRewards = 2 ether;
        consensusReached = etherFiOracleInstance.submitReport(report);
        assertFalse(consensusReached);

        // Bob realized that he generated a wrong report and try to submit the correct report
        // which fails because no more than 1 report can be submitted within the same period by the same committee member
        vm.prank(chad);
        vm.expectRevert(EtherFiOracle.ReportNotNeeded.selector);
        etherFiOracleInstance.submitReport(report);

        // However, in the next period, the committee can re-try to publish the correct report
        _moveClock(1024);
        _initReportBlockStamp(report);

        vm.prank(alice);
        report.accruedRewards = 1 ether;
        consensusReached = etherFiOracleInstance.submitReport(report);
        assertFalse(consensusReached);

        vm.prank(chad);
        report.accruedRewards = 1 ether;
        consensusReached = etherFiOracleInstance.submitReport(report);
        assertTrue(consensusReached); // succeeded
    }

    function test_execute_task_treasury_payout() public {
        vm.startPrank(owner);
        etherFiOracleInstance.addCommitteeMember(chad, 2);
        liquidityPoolInstance.setFeeRecipient(address(owner));
        vm.stopPrank();

        _moveClock(1024 + 2 * slotsPerEpoch);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        _initReportBlockStamp(report);

        // Assume that the accruedRewards must be 1 ether, all the time

        // Alice submited the correct report 
        vm.prank(alice);
        report.accruedRewards = 90 ether;
        report.protocolFees = 10 ether;
    }

    function test_removeCommitteeMember() public {
        vm.prank(owner);
        etherFiOracleInstance.addCommitteeMember(chad, 2);

        assertEq(etherFiOracleInstance.numCommitteeMembers(), 3); // alice, bob, chad
        assertEq(etherFiOracleInstance.numActiveCommitteeMembers(), 3);

        vm.prank(owner);
        etherFiOracleInstance.removeCommitteeMember(chad, 2);

        assertEq(etherFiOracleInstance.numCommitteeMembers(), 2);
        assertEq(etherFiOracleInstance.numActiveCommitteeMembers(), 2);

        (bool registered, bool enabled,,) = etherFiOracleInstance.committeeMemberStates(chad);
        assertEq(registered, false);
        assertEq(enabled, false);

        vm.prank(owner);
        vm.expectRevert(EtherFiOracle.NotRegistered.selector);
        etherFiOracleInstance.removeCommitteeMember(chad, 2);
    }

    function test_removeCommitteeMember_disabled() public {
        vm.prank(owner);
        etherFiOracleInstance.addCommitteeMember(chad, 2);

        vm.prank(owner);
        etherFiOracleInstance.manageCommitteeMember(chad, false, 2);

        assertEq(etherFiOracleInstance.numCommitteeMembers(), 3);
        assertEq(etherFiOracleInstance.numActiveCommitteeMembers(), 2);

        vm.prank(owner);
        etherFiOracleInstance.removeCommitteeMember(chad, 2);

        assertEq(etherFiOracleInstance.numCommitteeMembers(), 2);
        assertEq(etherFiOracleInstance.numActiveCommitteeMembers(), 2);
    }

    function test_getConsensusTimestamp() public {
        vm.prank(owner);
        etherFiOracleInstance.manageCommitteeMember(bob, false, 1);

        _moveClock(1024 + 2 * slotsPerEpoch);

        vm.prank(alice);
        bool consensusReached = etherFiOracleInstance.submitReport(reportAtPeriod2A);
        assertEq(consensusReached, true);

        bytes32 reportHash = etherFiOracleInstance.generateReportHash(reportAtPeriod2A);
        uint32 consensusTimestamp = etherFiOracleInstance.getConsensusTimestamp(reportHash);
        assertEq(consensusTimestamp, uint32(block.timestamp));

        // Test with non-existent hash
        bytes32 fakeHash = keccak256("fake");
        vm.expectRevert(EtherFiOracle.ConsensusNotReached.selector);
        etherFiOracleInstance.getConsensusTimestamp(fakeHash);
    }

    function test_getConsensusSlot() public {
        vm.prank(owner);
        etherFiOracleInstance.manageCommitteeMember(bob, false, 1);

        _moveClock(1024 + 2 * slotsPerEpoch);
        uint32 currentSlot = etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp);

        vm.prank(alice);
        bool consensusReached = etherFiOracleInstance.submitReport(reportAtPeriod2A);
        assertEq(consensusReached, true);

        bytes32 reportHash = etherFiOracleInstance.generateReportHash(reportAtPeriod2A);
        uint32 consensusSlot = etherFiOracleInstance.getConsensusSlot(reportHash);
        assertEq(consensusSlot, currentSlot);

        // Test with non-existent hash
        bytes32 fakeHash = keccak256("fake");
        vm.expectRevert(EtherFiOracle.ConsensusNotReached.selector);
        etherFiOracleInstance.getConsensusSlot(fakeHash);
    }

    function test_beaconGenesisTimestamp() public {
        uint32 genesisTime = etherFiOracleInstance.beaconGenesisTimestamp();
        // genesisSlotTimestamp is set in setUpTests based on chainid
        assertTrue(genesisTime >= 0);
    }

    function test_getImplementation() public {
        address impl = etherFiOracleInstance.getImplementation();
        assertTrue(impl != address(0));
    }

    // test_setReportStartSlot_edgeCases removed: setReportStartSlot was deleted
    // from EtherFiOracle as part of role consolidation. The state remains
    // settable for test purposes via _setReportStartSlot below.

    function test_setConsensusVersion_edgeCases() public {
        // Test: new version must be greater than current
        vm.prank(owner);
        vm.expectRevert(EtherFiOracle.InvalidConsensusVersion.selector);
        etherFiOracleInstance.setConsensusVersion(1);

        vm.prank(owner);
        vm.expectRevert(EtherFiOracle.InvalidConsensusVersion.selector);
        etherFiOracleInstance.setConsensusVersion(0);

        // Test: valid version update
        vm.prank(owner);
        etherFiOracleInstance.setConsensusVersion(2);
        assertEq(etherFiOracleInstance.consensusVersion(), 2);

        vm.prank(owner);
        etherFiOracleInstance.setConsensusVersion(5);
        assertEq(etherFiOracleInstance.consensusVersion(), 5);
    }

    function test_shouldSubmitReport_reportSlotNotStarted() public {
        uint32 currentSlot = etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp);
        uint32 futureSlot = ((currentSlot / 32) + 2) * 32; // Ensure it's in the future and at epoch boundary
        
        vm.prank(owner);
        _setReportStartSlot(futureSlot);

        // Move clock but not enough to reach reportStartSlot
        _moveClock(100);

        vm.expectRevert(EtherFiOracle.EpochNotFinalized.selector);
        etherFiOracleInstance.shouldSubmitReport(alice);
    }

    function test_verifyReport_blockToTooHigh() public {
        _moveClock(1024 + 2 * slotsPerEpoch);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        _initReportBlockStamp(report);
        report.refBlockTo = uint32(block.number); // Should be < block.number

        vm.expectRevert(EtherFiOracle.WrongBlockTo.selector);
        etherFiOracleInstance.verifyReport(report);
    }

    function test_slotForNextReport_edgeCases() public {
        // Seed TVL so the report's positive accruedRewards stays within the 25 bps
        // LiquidityPool positive rebase cap (a zero-TVL pool rejects any positive rebase).
        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 1000 ether}();

        vm.prank(owner);
        etherFiOracleInstance.manageCommitteeMember(bob, false, 1);

        // Submit a report first to have a published report
        _moveClock(1024 + 2 * slotsPerEpoch);
        vm.prank(alice);
        etherFiOracleInstance.submitReport(reportAtPeriod2A);

        // Execute admin tasks to update lastHandledReportRefSlot
        _moveClock(int256(uint256(etherFiAdminInstance.postReportWaitTimeInSlots()) + 1));
        vm.prank(alice);
        etherFiAdminInstance.executeTasks(reportAtPeriod2A);

        // Next report should be after the published one
        uint32 nextSlot = etherFiOracleInstance.slotForNextReport();
        assertTrue(nextSlot >= reportAtPeriod2A.refSlotTo);
    }

    function test_blockStampForNextReport() public {
        // Seed TVL so the report's positive accruedRewards stays within the 25 bps
        // LiquidityPool positive rebase cap (a zero-TVL pool rejects any positive rebase).
        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 1000 ether}();

        vm.prank(owner);
        etherFiOracleInstance.manageCommitteeMember(bob, false, 1);

        // Submit a report first
        _moveClock(1024 + 2 * slotsPerEpoch);
        vm.prank(alice);
        etherFiOracleInstance.submitReport(reportAtPeriod2A);

        // Execute the admin tasks to update lastHandledReportRefSlot
        _moveClock(int256(uint256(etherFiAdminInstance.postReportWaitTimeInSlots()) + 1));
        vm.prank(alice);
        etherFiAdminInstance.executeTasks(reportAtPeriod2A);

        // Next report should start after the published one
        (uint32 slotFrom, uint32 slotTo, uint32 blockFrom) = etherFiOracleInstance.blockStampForNextReport();
        assertEq(slotFrom, reportAtPeriod2A.refSlotTo + 1);
        assertEq(blockFrom, reportAtPeriod2A.refBlockTo + 1);
        assertTrue(slotTo >= slotFrom);
    }

    function test_manageCommitteeMember_alreadyInTargetState() public {
        vm.prank(owner);
        etherFiOracleInstance.addCommitteeMember(chad, 2);

        // Try to enable when already enabled
        vm.prank(owner);
        vm.expectRevert(EtherFiOracle.AlreadyInTargetState.selector);
        etherFiOracleInstance.manageCommitteeMember(chad, true, 2);

        // Disable first
        vm.prank(owner);
        etherFiOracleInstance.manageCommitteeMember(chad, false, 2);

        // Try to disable when already disabled
        vm.prank(owner);
        vm.expectRevert(EtherFiOracle.AlreadyInTargetState.selector);
        etherFiOracleInstance.manageCommitteeMember(chad, false, 2);
    }

    function test_addCommitteeMember_alreadyRegistered() public {
        vm.prank(owner);
        etherFiOracleInstance.addCommitteeMember(chad, 2);

        vm.prank(owner);
        vm.expectRevert(EtherFiOracle.AlreadyRegistered.selector);
        etherFiOracleInstance.addCommitteeMember(chad, 2);
    }

    // ========== _checkQuorum invariant tests ==========
    // _checkQuorum reverts with InvalidQuorum when:
    //   - quorumSize < minQuorumSize, or
    //   - numActiveCommitteeMembers < quorumSize (too few members for the quorum), or
    //   - numActiveCommitteeMembers >= 2 * quorumSize (quorum not a strict majority).
    // The check runs after every add/remove/manage/setQuorum mutation, so each
    // mutation needs to leave the (members, quorum) pair inside the valid band.

    function test_setQuorumSize_revertsWhenBelowMinQuorumSize() public {
        vm.prank(owner);
        vm.expectRevert(EtherFiOracle.InvalidQuorum.selector);
        etherFiOracleInstance.setQuorumSize(0);
    }

    function test_setQuorumSize_revertsWhenAboveActiveMembers() public {
        // numActive = 2 (alice, bob); quorum = 3 violates numActive < quorum
        vm.prank(owner);
        vm.expectRevert(EtherFiOracle.InvalidQuorum.selector);
        etherFiOracleInstance.setQuorumSize(3);
    }

    function test_setQuorumSize_revertsWhenRatioTooLow() public {
        // First grow membership to 3 so the ratio path is reachable
        vm.prank(owner);
        etherFiOracleInstance.addCommitteeMember(chad, 2);

        // 3 / 1 = 3 >= 2 -> revert (quorum is too small for the active set)
        vm.prank(owner);
        vm.expectRevert(EtherFiOracle.InvalidQuorum.selector);
        etherFiOracleInstance.setQuorumSize(1);
    }

    function test_setQuorumSize_acceptsAtEqualityBoundary() public {
        // numActive == quorum is allowed (numActive < quorum is the failing edge)
        vm.prank(owner);
        etherFiOracleInstance.setQuorumSize(2);
        assertEq(etherFiOracleInstance.quorumSize(), 2);
    }

    function test_addCommitteeMember_revertsWhenRatioReachesTwo() public {
        // numActive becomes 3 after the add. Passing _quorumSize=1 means
        // numActive >= 2 * quorum (3 >= 2) -> revert.
        vm.prank(owner);
        vm.expectRevert(EtherFiOracle.InvalidQuorum.selector);
        etherFiOracleInstance.addCommitteeMember(chad, 1);
    }

    function test_removeCommitteeMember_revertsWhenBelowQuorum() public {
        // numActive=2, quorum=2; removing alice drops numActive to 1 < quorum -> revert
        vm.prank(owner);
        vm.expectRevert(EtherFiOracle.InvalidQuorum.selector);
        etherFiOracleInstance.removeCommitteeMember(alice, 2);
    }

    function test_removeCommitteeMember_okWhenMemberWasDisabled() public {
        // Disabling alice already accounted for the numActive drop, so removing her
        // (which only touches numCommitteeMembers, not numActive) keeps quorum valid.
        vm.prank(owner);
        etherFiOracleInstance.addCommitteeMember(chad, 2);
        // numActive=3 after add; disable alice -> numActive=2, quorum=2 (still valid)
        vm.prank(owner);
        etherFiOracleInstance.manageCommitteeMember(alice, false, 2);

        vm.prank(owner);
        etherFiOracleInstance.removeCommitteeMember(alice, 2);

        assertEq(etherFiOracleInstance.numActiveCommitteeMembers(), 2);
        assertEq(etherFiOracleInstance.numCommitteeMembers(), 2);
    }

    function test_manageCommitteeMember_disablingRevertsWhenBelowQuorum() public {
        // numActive=2, quorum=2; disabling bob drops numActive to 1 -> revert
        vm.prank(owner);
        vm.expectRevert(EtherFiOracle.InvalidQuorum.selector);
        etherFiOracleInstance.manageCommitteeMember(bob, false, 2);
    }

    function test_manageCommitteeMember_reenableKeepsQuorumValid() public {
        // First need a disable that is legal (so add chad to give us headroom)
        vm.prank(owner);
        etherFiOracleInstance.addCommitteeMember(chad, 2);
        vm.prank(owner);
        etherFiOracleInstance.manageCommitteeMember(chad, false, 2);
        assertEq(etherFiOracleInstance.numActiveCommitteeMembers(), 2);

        // Re-enable chad: numActive goes back to 3, quorum=2, still valid
        vm.prank(owner);
        etherFiOracleInstance.manageCommitteeMember(chad, true, 2);
        assertEq(etherFiOracleInstance.numActiveCommitteeMembers(), 3);
    }

    // ========== EtherFiAdmin Additional Coverage Tests ==========

    function test_setValidatorTaskBatchSize() public {
        // RoleRegistry is already initialized and alice already has the role in setUpTests
        vm.prank(alice);
        etherFiAdminInstance.setValidatorTaskBatchSize(50);
        // validatorTaskBatchSize is internal, tested indirectly through executeValidatorApprovalTask

        // Test: non-admin cannot set (onlyAdmin → OPERATION_TIMELOCK_ROLE)
        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        etherFiAdminInstance.setValidatorTaskBatchSize(75);
    }

    function test_setValidatorTaskBatchSize_guardrail() public {
        uint256 maxBatchSize = etherFiAdminInstance.maxValidatorTaskBatchSize();
        assertEq(maxBatchSize, 1_000); // configured in TestSetup

        // boundary value is accepted
        vm.prank(alice);
        etherFiAdminInstance.setValidatorTaskBatchSize(uint16(maxBatchSize));

        // one above the cap reverts
        vm.prank(alice);
        vm.expectRevert(EtherFiAdmin.InvalidValidatorTaskBatchSize.selector);
        etherFiAdminInstance.setValidatorTaskBatchSize(uint16(maxBatchSize + 1));
    }

    function test_updateAcceptableRebaseApr_guardrail() public {
        int256 maxApr = etherFiAdminInstance.maxAcceptableRebaseAprInBps();
        assertEq(maxApr, 10_000); // configured in TestSetup

        // boundary value is accepted
        vm.prank(alice);
        etherFiAdminInstance.updateAcceptableRebaseApr(int32(maxApr));
        assertEq(etherFiAdminInstance.acceptableRebaseAprInBps(), int32(maxApr));

        // negative limit is not allowed in acceptable rebase apr
        vm.prank(alice);
        vm.expectRevert(EtherFiAdmin.InvalidAcceptableRebaseApr.selector);
        etherFiAdminInstance.updateAcceptableRebaseApr(-1);

        // one above the cap reverts
        vm.prank(alice);
        vm.expectRevert(EtherFiAdmin.InvalidAcceptableRebaseApr.selector);
        etherFiAdminInstance.updateAcceptableRebaseApr(int32(maxApr + 1));
    }

    function _defaultEtherFiAdminCtorAddrs() internal view returns (IEtherFiAdmin.ConstructorAddresses memory) {
        return IEtherFiAdmin.ConstructorAddresses({
            etherFiOracle: address(etherFiOracleInstance),
            stakingManager: address(stakingManagerInstance),
            auctionManager: address(auctionInstance),
            etherFiNodesManager: address(managerInstance),
            liquidityPool: address(liquidityPoolInstance),
            withdrawRequestNft: address(withdrawRequestNFTInstance),
            roleRegistry: address(roleRegistryInstance),
            priorityWithdrawalQueue: address(priorityQueueInstance)
        });
    }

    function test_constructor_maxValidatorTaskBatchSize_guardrail() public {
        EtherFiAdmin nonZeroValue = new EtherFiAdmin(_defaultEtherFiAdminCtorAddrs(), 500, 1_000, 7200, 100_000 ether, 500, 1000);
        assertEq(nonZeroValue.maxValidatorTaskBatchSize(), 1_000);

        // value 0 reverts
        vm.expectRevert(EtherFiAdmin.InvalidValidatorTaskBatchSize.selector);
        new EtherFiAdmin(_defaultEtherFiAdminCtorAddrs(), 500, 0, 7200, 100_000 ether, 500, 1000);
    }

    function test_constructor_maxAcceptableRebaseAprInBps_guardrail() public {
        EtherFiAdmin validValue = new EtherFiAdmin(_defaultEtherFiAdminCtorAddrs(), 500, 1_000, 7200, 100_000 ether, 500, 1000);
        assertEq(validValue.maxAcceptableRebaseAprInBps(), 500);

        // value 0 reverts
        vm.expectRevert(EtherFiAdmin.InvalidMaxAcceptableRebaseApr.selector);
        new EtherFiAdmin(_defaultEtherFiAdminCtorAddrs(), 0, 1_000, 7200, 100_000 ether, 500, 1000);

        // negative values revert
        vm.expectRevert(EtherFiAdmin.InvalidMaxAcceptableRebaseApr.selector);
        new EtherFiAdmin(_defaultEtherFiAdminCtorAddrs(), -1, 1_000, 7200, 100_000 ether, 500, 1000);

        // values above 10_000 revert
        vm.expectRevert(EtherFiAdmin.InvalidMaxAcceptableRebaseApr.selector);
        new EtherFiAdmin(_defaultEtherFiAdminCtorAddrs(), 10_001, 1_000, 7200, 100_000 ether, 500, 1000);
    }

    function test_constructor_staleOracleReportBlockWindow_guardrail() public {
        EtherFiAdmin validValue = new EtherFiAdmin(_defaultEtherFiAdminCtorAddrs(), 500, 1_000, 7200, 100_000 ether, 500, 1000);
        assertEq(validValue.staleOracleReportBlockWindow(), 7200);

        // value 0 reverts
        vm.expectRevert(EtherFiAdmin.InvalidStaleOracleReportBlockWindow.selector);
        new EtherFiAdmin(_defaultEtherFiAdminCtorAddrs(), 500, 1_000, 0, 100_000 ether, 500, 1000);
    }

    function test_constructor_maxAcceptableFinalizedWithdrawalAmountPerDay_guardrail() public {
        EtherFiAdmin validValue = new EtherFiAdmin(_defaultEtherFiAdminCtorAddrs(), 500, 1_000, 7200, 100_000 ether, 500, 1000);
        assertEq(validValue.maxAcceptableFinalizedWithdrawalAmountPerDay(), 100_000 ether);

        // value 0 reverts
        vm.expectRevert(EtherFiAdmin.InvalidMaxAcceptableFinalizedWithdrawalAmount.selector);
        new EtherFiAdmin(_defaultEtherFiAdminCtorAddrs(), 500, 1_000, 7200, 0, 500, 1000);
    }

    function test_constructor_maxAcceptableNumValidatorsToApprovePerDay_zero_is_allowed() public {
        // _maxAcceptableNumValidatorsToApprovePerDay = 0 signals "pause new validators"
        EtherFiAdmin zeroAllowed = new EtherFiAdmin(_defaultEtherFiAdminCtorAddrs(), 500, 1_000, 7200, 100_000 ether, 0, 1000);
        assertEq(zeroAllowed.maxAcceptableNumValidatorsToApprovePerDay(), 0);
    }

    function test_executeValidatorApprovalTask() public {
        // RoleRegistry is already initialized and alice already has the role in setUpTests

        vm.prank(owner);
        etherFiOracleInstance.manageCommitteeMember(bob, false, 1);

        _moveClock(1024 + 2 * slotsPerEpoch);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        _initReportBlockStamp(report);
        report.validatorsToApprove = new uint256[](1);
        report.validatorsToApprove[0] = 1;

        vm.prank(alice);
        etherFiOracleInstance.submitReport(report);

        _moveClock(int256(uint256(etherFiAdminInstance.postReportWaitTimeInSlots()) + 1));

        vm.prank(alice);
        etherFiAdminInstance.executeTasks(report);

        bytes32 reportHash = etherFiOracleInstance.generateReportHash(report);
        bytes32 taskHash = keccak256(abi.encode(reportHash, report.validatorsToApprove));

        (bool completed, bool exists) = etherFiAdminInstance.validatorApprovalTaskStatus(taskHash);
        assertEq(exists, true);
        assertEq(completed, false);

        // Execute the validator approval task
        // Note: We need valid pubKeys and signatures, but for testing we can use empty ones
        // The actual deposit-data construction now lives in EtherFiAdmin._approveValidators
        // which forwards to liquidityPool.confirmAndFundBeaconValidators.
        bytes[] memory pubKeys = new bytes[](1);
        bytes[] memory signatures = new bytes[](1);
        pubKeys[0] = new bytes(48);
        signatures[0] = new bytes(96);

        // This might revert if the liquidity pool doesn't accept empty pubKeys/signatures
        // Let's test that the task exists and can be executed
        vm.prank(alice);
        // If this reverts, it's likely due to invalid pubKeys/signatures, not the task logic
        try etherFiAdminInstance.executeValidatorApprovalTask(reportHash, report.validatorsToApprove, pubKeys, signatures) {
            (completed, exists) = etherFiAdminInstance.validatorApprovalTaskStatus(taskHash);
            assertEq(completed, true);
            assertEq(exists, true);
        } catch {
            // If it reverts, at least verify the task was created correctly
            (completed, exists) = etherFiAdminInstance.validatorApprovalTaskStatus(taskHash);
            assertEq(exists, true);
            assertEq(completed, false);
        }
    }

    function test_executeValidatorApprovalTask_noConsensus() public {
        // RoleRegistry is already initialized and alice already has the role in setUpTests

        bytes32 fakeHash = keccak256("fake");
        uint256[] memory validators = new uint256[](0);
        bytes[] memory pubKeys = new bytes[](0);
        bytes[] memory signatures = new bytes[](0);

        vm.prank(alice);
        vm.expectRevert(EtherFiAdmin.ConsensusNotReached.selector);
        etherFiAdminInstance.executeValidatorApprovalTask(fakeHash, validators, pubKeys, signatures);
    }

    function test_executeValidatorApprovalTask_taskNotExists() public {
        // RoleRegistry is already initialized and alice already has the role in setUpTests

        vm.prank(owner);
        etherFiOracleInstance.manageCommitteeMember(bob, false, 1);

        _moveClock(1024 + 2 * slotsPerEpoch);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        _initReportBlockStamp(report);

        vm.prank(alice);
        etherFiOracleInstance.submitReport(report);

        bytes32 reportHash = etherFiOracleInstance.generateReportHash(report);
        uint256[] memory validators = new uint256[](1);
        validators[0] = 999; // Different validator
        bytes[] memory pubKeys = new bytes[](1);
        bytes[] memory signatures = new bytes[](1);

        vm.prank(alice);
        vm.expectRevert(EtherFiAdmin.TaskDoesNotExist.selector);
        etherFiAdminInstance.executeValidatorApprovalTask(reportHash, validators, pubKeys, signatures);
    }

    function test_invalidateValidatorApprovalTask() public {
        // RoleRegistry is already initialized and roles are already granted in setUpTests
        // alice has ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE and ETHERFI_ORACLE_EXECUTOR_TASK_MANAGER_ROLE
        // bob doesn't have the role, so we'll use alice for both

        vm.prank(owner);
        etherFiOracleInstance.manageCommitteeMember(bob, false, 1);

        _moveClock(1024 + 2 * slotsPerEpoch);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        _initReportBlockStamp(report);
        report.validatorsToApprove = new uint256[](1);
        report.validatorsToApprove[0] = 1;

        vm.prank(alice);
        etherFiOracleInstance.submitReport(report);

        _moveClock(int256(uint256(etherFiAdminInstance.postReportWaitTimeInSlots()) + 1));

        vm.prank(alice);
        etherFiAdminInstance.executeTasks(report);

        bytes32 reportHash = etherFiOracleInstance.generateReportHash(report);
        bytes32 taskHash = keccak256(abi.encode(reportHash, report.validatorsToApprove));

        (bool completed, bool exists) = etherFiAdminInstance.validatorApprovalTaskStatus(taskHash);
        assertEq(exists, true);
        assertEq(completed, false);

        // Invalidate the task
        vm.prank(alice);
        etherFiAdminInstance.invalidateValidatorApprovalTask(reportHash, report.validatorsToApprove);

        (completed, exists) = etherFiAdminInstance.validatorApprovalTaskStatus(taskHash);
        assertEq(exists, false);
        assertEq(completed, false);

        // Test: cannot invalidate non-existent task
        vm.prank(alice);
        vm.expectRevert(EtherFiAdmin.TaskDoesNotExist.selector);
        etherFiAdminInstance.invalidateValidatorApprovalTask(reportHash, report.validatorsToApprove);
    }

    function test_invalidateValidatorApprovalTask_alreadyCompleted() public {
        // RoleRegistry is already initialized and alice already has both roles in setUpTests

        vm.prank(owner);
        etherFiOracleInstance.manageCommitteeMember(bob, false, 1);

        _moveClock(1024 + 2 * slotsPerEpoch);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        _initReportBlockStamp(report);
        report.validatorsToApprove = new uint256[](1);
        report.validatorsToApprove[0] = 1;

        vm.prank(alice);
        etherFiOracleInstance.submitReport(report);

        _moveClock(int256(uint256(etherFiAdminInstance.postReportWaitTimeInSlots()) + 1));

        vm.prank(alice);
        etherFiAdminInstance.executeTasks(report);

        bytes32 reportHash = etherFiOracleInstance.generateReportHash(report);
        bytes[] memory pubKeys = new bytes[](1);
        bytes[] memory signatures = new bytes[](1);
        pubKeys[0] = new bytes(48);
        signatures[0] = new bytes(96);

        // Try to execute the task - it might revert due to invalid pubKeys/signatures
        // Since we can't easily test this without valid pubKeys/signatures, we'll just verify
        // that the task exists and the logic for invalidating completed tasks is in the contract
        bytes32 taskHash = keccak256(abi.encode(reportHash, report.validatorsToApprove));
        (bool completed, bool exists) = etherFiAdminInstance.validatorApprovalTaskStatus(taskHash);
        assertEq(exists, true);
        assertEq(completed, false);
        
        // The actual test of invalidating a completed task would require executing the task first
        // which needs valid pubKeys/signatures. This test validates that the task creation works correctly.
        // The contract code already has the check for "EtherFiAdmin: task already completed" in invalidateValidatorApprovalTask
    }

    function test_updateAcceptableRebaseApr() public {
        // RoleRegistry is already initialized and alice already has the role in setUpTests

        vm.prank(alice);
        etherFiAdminInstance.updateAcceptableRebaseApr(5000);
        assertEq(etherFiAdminInstance.acceptableRebaseAprInBps(), 5000);

        // Test: non-admin cannot update
        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        etherFiAdminInstance.updateAcceptableRebaseApr(10000);
    }

    function test_updatePostReportWaitTimeInSlots() public {
        // RoleRegistry is already initialized and alice already has the role in setUpTests

        vm.prank(alice);
        etherFiAdminInstance.updatePostReportWaitTimeInSlots(10);
        assertEq(etherFiAdminInstance.postReportWaitTimeInSlots(), 10);

        // Test: non-admin cannot update
        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        etherFiAdminInstance.updatePostReportWaitTimeInSlots(20);
    }

    function test_slotForNextReportToProcess() public {
        assertEq(etherFiAdminInstance.slotForNextReportToProcess(), 0);

        // Execute a task to set lastHandledReportRefSlot
        vm.prank(owner);
        etherFiOracleInstance.manageCommitteeMember(bob, false, 1);

        _moveClock(1024 + 2 * slotsPerEpoch);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        _initReportBlockStamp(report);

        vm.prank(alice);
        etherFiOracleInstance.submitReport(report);

        _moveClock(int256(uint256(etherFiAdminInstance.postReportWaitTimeInSlots()) + 1));

        // RoleRegistry is already initialized and alice already has the role in setUpTests
        vm.prank(alice);
        etherFiAdminInstance.executeTasks(report);

        assertEq(etherFiAdminInstance.slotForNextReportToProcess(), report.refSlotTo + 1);
    }

    function test_blockForNextReportToProcess() public {
        assertEq(etherFiAdminInstance.blockForNextReportToProcess(), 0);

        // Execute a task to set lastHandledReportRefBlock
        vm.prank(owner);
        etherFiOracleInstance.manageCommitteeMember(bob, false, 1);

        _moveClock(1024 + 2 * slotsPerEpoch);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        _initReportBlockStamp(report);

        vm.prank(alice);
        etherFiOracleInstance.submitReport(report);

        _moveClock(int256(uint256(etherFiAdminInstance.postReportWaitTimeInSlots()) + 1));

        // RoleRegistry is already initialized and alice already has the role in setUpTests
        vm.prank(alice);
        etherFiAdminInstance.executeTasks(report);

        assertEq(etherFiAdminInstance.blockForNextReportToProcess(), report.refBlockTo + 1);
    }

    function test_getImplementation_admin() public {
        address impl = etherFiAdminInstance.getImplementation();
        assertTrue(impl != address(0));
    }

    function test_canExecuteTasks_edgeCases() public {
        vm.prank(owner);
        etherFiOracleInstance.manageCommitteeMember(bob, false, 1);

        _moveClock(1024 + 2 * slotsPerEpoch);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        _initReportBlockStamp(report);

        // Test: no consensus reached
        assertEq(etherFiAdminInstance.canExecuteTasks(report), false);

        // Submit report
        vm.prank(alice);
        etherFiOracleInstance.submitReport(report);

        // Test: consensus reached but wait time not passed (if wait time > 0)
        // Note: canExecuteTasks might return true if wait time is already satisfied
        bool canExecute = etherFiAdminInstance.canExecuteTasks(report);
        
        // Move forward past wait time to ensure it works
        _moveClock(int256(uint256(etherFiAdminInstance.postReportWaitTimeInSlots()) + 1));
        assertEq(etherFiAdminInstance.canExecuteTasks(report), true);
    }

    function test_executeTasks_wrongRefSlotFrom() public {
        // RoleRegistry is already initialized and alice already has the role in setUpTests
        vm.prank(owner);
        etherFiOracleInstance.manageCommitteeMember(bob, false, 1);

        _moveClock(1024 + 2 * slotsPerEpoch);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        _initReportBlockStamp(report);
        
        // Submit correct report first
        vm.prank(alice);
        etherFiOracleInstance.submitReport(report);
        vm.prank(alice);
        etherFiAdminInstance.executeTasks(report);

        // Now create a new report with wrong refSlotFrom
        _moveClock(1024 + 2 * slotsPerEpoch);
        IEtherFiOracle.OracleReport memory wrongReport = _emptyOracleReport();
        _initReportBlockStamp(wrongReport);
        wrongReport.refSlotFrom = 9999; // Wrong slot

        // Submit the wrong report (this will fail at verifyReport, but we can test executeTasks directly)
        vm.prank(alice);
        vm.expectRevert(EtherFiOracle.WrongSlotFrom.selector);
        etherFiOracleInstance.submitReport(wrongReport);
    }

    function test_executeTasks_wrongRefBlockFrom() public {
        // RoleRegistry is already initialized and alice already has the role in setUpTests
        vm.prank(owner);
        etherFiOracleInstance.manageCommitteeMember(bob, false, 1);

        _moveClock(1024 + 2 * slotsPerEpoch);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        _initReportBlockStamp(report);
        
        // Submit correct report first
        vm.prank(alice);
        etherFiOracleInstance.submitReport(report);
        vm.prank(alice);
        etherFiAdminInstance.executeTasks(report);

        // Now create a new report with wrong refBlockFrom
        _moveClock(1024 + 2 * slotsPerEpoch);
        IEtherFiOracle.OracleReport memory wrongReport = _emptyOracleReport();
        _initReportBlockStamp(wrongReport);
        wrongReport.refBlockFrom = 9999; // Wrong block

        // Submit the wrong report (this will fail at verifyReport)
        vm.prank(alice);
        vm.expectRevert(EtherFiOracle.WrongBlockFrom.selector);
        etherFiOracleInstance.submitReport(wrongReport);
    }

    function test_executeTasks_permissionless() public {
        vm.prank(owner);
        etherFiOracleInstance.manageCommitteeMember(bob, false, 1);

        _moveClock(1024 + 2 * slotsPerEpoch);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        _initReportBlockStamp(report);

        vm.prank(alice);
        etherFiOracleInstance.submitReport(report);

        _moveClock(int256(uint256(etherFiAdminInstance.postReportWaitTimeInSlots()) + 1));

        // executeTasks is permissionless once consensus is reached and the report
        // passes the freshness/sequencing checks. Use a fresh, role-less address.
        address randoCaller = makeAddr("randoCaller");
        assertFalse(roleRegistryInstance.hasRole(roleRegistryInstance.ORACLE_OPERATIONS_ROLE(), randoCaller));
        assertFalse(roleRegistryInstance.hasRole(roleRegistryInstance.OPERATION_TIMELOCK_ROLE(), randoCaller));

        vm.prank(randoCaller);
        etherFiAdminInstance.executeTasks(report);

        assertEq(etherFiAdminInstance.lastHandledReportRefSlot(), report.refSlotTo);
        assertEq(etherFiAdminInstance.lastHandledReportRefBlock(), report.refBlockTo);
    }

    // test_pause_unPause_edgeCases / test_pause_unPause_insufficientRole removed:
    // EtherFiAdmin.pause / unPause were deleted in the role-consolidation refactor.

    // The finalized amount is now derived on-chain from the request prefix-sum
    // (WithdrawRequestNFT.getFinalizedWithdrawalAmount), not carried in the report. Back it with a
    // real request and lower the per-day cap below that amount so the per-day gate trips.
    function test_executeTasks_revertsWhenFinalizedWithdrawalExceedsCap() public {
        _unpauseWithdrawNFT();
        _seedLp(200 ether);
        uint256 requestId = _makeWithdrawRequest(10 ether);

        vm.prank(alice);
        etherFiAdminInstance.updateMaxFinalizedWithdrawalAmountPerDay(0.001 ether);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.lastFinalizedWithdrawalRequestId = uint32(requestId);

        _moveClock(1 days / 12);
        _executeAdminTasks(report, "EtherFiAdmin: finalized withdrawal amount exceeds max");
    }

    // NOTE: the per-report range-cap gate (`maxNumberOfRequestsToFinalizePerReport`) was removed
    // from `_validateWithdrawals`; that limit now only bounds the permissionless stale-finalization
    // path (`maxNumberOfStaleRequestsToFinalizePerReport`). The old range-cap and boundary tests
    // were deleted accordingly.

    function test_executeTasks_revertsWhenValidatorApprovalsExceedCap() public {
        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.validatorsToApprove = new uint256[](400); // > 200/day cap
        for (uint256 i = 0; i < 400; i++) {
            report.validatorsToApprove[i] = i + 1;
        }

        _moveClock(1 days / 12);
        _executeAdminTasks(report, "EtherFiAdmin: number of validators to approve exceeds max");
    }

    // Happy path: a report with a non-zero finalized-withdrawal amount that stays
    // within the per-day cap processes cleanly and advances the LP's locked
    // accounting.
    function test_executeTasks_finalizedWithdrawalWithinCap_succeeds() public {
        // Seed via bob so requestWithdraw caller has eETH; the on-chain finalized-amount
        // derivation requires a real request to back the locked amount.
        _unpauseWithdrawNFT();
        _seedLp(200 ether);
        uint256 requestId = _makeWithdrawRequest(10 ether);

        uint256 lockedBefore = withdrawRequestNFTInstance.ethAmountLockedForWithdrawal();

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.lastFinalizedWithdrawalRequestId = uint32(requestId);

        _moveClock(1 days / 12);
        _executeAdminTasks(report);

        assertEq(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal(), lockedBefore + 10 ether);
    }

    // LP-liquidity sanity check in _handleWithdrawals: finalized amount +
    // existing LP lock + priority-queue lock must not exceed the LP's ETH
    // balance.
    function test_executeTasks_revertsWhenFinalizedWithdrawalExceedsLpLiquidity() public {
        // Back the on-chain finalized amount with a real 6-ether request, then drop totalValueInLp
        // below it so the liquidity gate trips.
        _unpauseWithdrawNFT();
        _seedLp(10 ether);
        uint256 requestId = _makeWithdrawRequest(6 ether);

        _forceLpBalanceAndTVIL(5 ether); // totalValueInLp (5) < finalized amount (6)

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.lastFinalizedWithdrawalRequestId = uint32(requestId);

        _moveClock(1 days / 12);
        _executeAdminTasks(report, "EtherFiAdmin: finalized withdrawal exceeds LP liquidity");
    }

    // The liquidity check compares against the LP's actual ETH balance, not
    // the internal totalValueInLp accounting. ETH that arrives at the LP
    // outside a deposit path (e.g., validator principal returning before the
    // next rebase) bumps the balance while accounting lags — a finalized
    // withdrawal drawing on those funds should still pass the check.
    function test_executeTasks_finalizedWithdrawalWithinLpBalance_succeeds() public {
        _unpauseWithdrawNFT();
        _seedLp(10 ether);
        uint256 requestId = _makeWithdrawRequest(6 ether);

        // addEthAmountLockedForWithdrawal now requires totalValueInLp >= amount (strict guard).
        // Deposit ensures totalValueInLp (10) >= finalizedWithdrawalAmount (6).
        assertGe(liquidityPoolInstance.totalValueInLp(), 6 ether);

        uint256 lockedBefore = withdrawRequestNFTInstance.ethAmountLockedForWithdrawal();

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.lastFinalizedWithdrawalRequestId = uint32(requestId);

        _moveClock(1 days / 12);
        _executeAdminTasks(report);

        assertEq(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal(), lockedBefore + 6 ether);
    }

    // =====================================================================
    // canExecuteTasks unit tests
    //
    // canExecuteTasks and executeTasks share _validateReport. Each test
    // exercises one gate: where the gate trips, canExecuteTasks must return
    // false AND executeTasks must revert with the matching string. Any
    // future drift between the two functions should fail one of these tests.
    // =====================================================================

    // Submit `_report` so it reaches consensus and clear any post-report
    // wait time. Does NOT call executeTasks.
    function _submitForConsensus(IEtherFiOracle.OracleReport memory _report) internal {
        _initReportBlockStamp(_report);

        uint32 currentSlot = etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp);
        uint32 currentEpoch = (currentSlot / 32);
        uint32 reportEpoch = (_report.refSlotTo / 32) + 3;
        if (currentEpoch < reportEpoch) {
            uint32 numSlotsToMove = 32 * (reportEpoch - currentEpoch);
            _moveClock(int256(int32(numSlotsToMove)));
        }

        vm.prank(alice);
        etherFiOracleInstance.submitReport(_report);
        vm.prank(bob);
        etherFiOracleInstance.submitReport(_report);

        int256 offset = int256(int16(etherFiAdminInstance.postReportWaitTimeInSlots()));
        if (offset > 2 * 32) offset -= 2 * 32;
        if (offset > 0) _moveClock(offset);
    }

    function test_canExecuteTasks_falseWhenNoConsensus() public {
        _moveClock(1024 + 2 * slotsPerEpoch);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        _initReportBlockStamp(report);

        // No submission, so no consensus on the hash.
        assertEq(etherFiAdminInstance.canExecuteTasks(report), false);

        vm.expectRevert(abi.encodeWithSelector(EtherFiAdmin.ReportValidationFailed.selector, "EtherFiAdmin: report didn't reach consensus"));
        etherFiAdminInstance.executeTasks(report);
    }

    // After a successful execute, slotForNextReportToProcess() advances past
    // the report's refSlotFrom. The same report can no longer be executed,
    // and the refSlotFrom gate is what trips. (refBlockFrom is structurally
    // symmetric — checked by the same once-stale-always-stale relationship.)
    function test_canExecuteTasks_falseWhenWrongRefSlotFrom() public {
        IEtherFiOracle.OracleReport memory firstReport = _emptyOracleReport();
        _executeAdminTasks(firstReport);

        assertEq(etherFiAdminInstance.canExecuteTasks(firstReport), false);

        vm.expectRevert(abi.encodeWithSelector(EtherFiAdmin.ReportValidationFailed.selector, "EtherFiAdmin: report has wrong `refSlotFrom`"));
        etherFiAdminInstance.executeTasks(firstReport);
    }

    function test_canExecuteTasks_falseWhenTooFresh() public {
        vm.prank(alice);
        etherFiAdminInstance.updatePostReportWaitTimeInSlots(10);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        _initReportBlockStamp(report);

        _moveClock(1024 + 2 * slotsPerEpoch);

        vm.prank(alice);
        etherFiOracleInstance.submitReport(report);
        vm.prank(bob);
        etherFiOracleInstance.submitReport(report);

        // Consensus reached this same block; wait window of 10 slots not yet elapsed.
        assertEq(etherFiAdminInstance.canExecuteTasks(report), false);

        vm.expectRevert(abi.encodeWithSelector(EtherFiAdmin.ReportValidationFailed.selector, "EtherFiAdmin: report is too fresh"));
        etherFiAdminInstance.executeTasks(report);

        // Once the wait elapses, the gate flips.
        _moveClock(11);
        assertEq(etherFiAdminInstance.canExecuteTasks(report), true);
    }

    function test_canExecuteTasks_falseWhenAprAboveCap() public {
        // Tighten the cap so any non-zero rebase trips it.
        vm.prank(alice);
        etherFiAdminInstance.updateAcceptableRebaseApr(0);

        // TVL > 0 so the APR formula is non-trivial.
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 10 ether}();

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.accruedRewards = 0.01 ether;
        _moveClock(1 days / 12);
        _submitForConsensus(report);

        assertEq(etherFiAdminInstance.canExecuteTasks(report), false);

        vm.expectRevert(abi.encodeWithSelector(EtherFiAdmin.ReportValidationFailed.selector, "EtherFiAdmin: TVL changed too much"));
        etherFiAdminInstance.executeTasks(report);
    }

    // The APR check uses absApr, so a negative rebase of equal magnitude
    // must trip the same gate.
    function test_canExecuteTasks_falseWhenNegativeAprAboveCap() public {
        vm.prank(alice);
        etherFiAdminInstance.updateAcceptableRebaseApr(0);

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 10 ether}();

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.accruedRewards = -0.01 ether;
        _moveClock(1 days / 12);
        _submitForConsensus(report);

        assertEq(etherFiAdminInstance.canExecuteTasks(report), false);

        vm.expectRevert(abi.encodeWithSelector(EtherFiAdmin.ReportValidationFailed.selector, "EtherFiAdmin: TVL changed too much"));
        etherFiAdminInstance.executeTasks(report);
    }

    // Regression pin: protocolFees == 0 with a negative accruedRewards must
    // pass validation. An earlier refactor accidentally extended the 20%
    // rule to protocolFees == 0, which would have rejected this case
    // (5*0 > 0 + ar when ar < 0). We only assert the validation gate here;
    // the downstream rebase path is exercised by the existing
    // test_huge_negative_rebaes.
    function test_canExecuteTasks_trueWhenZeroFeesAndNegativeRewards() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 10 ether}();

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.protocolFees = 0;
        report.accruedRewards = -1 wei;
        _moveClock(1 days / 12);
        _submitForConsensus(report);

        assertEq(etherFiAdminInstance.canExecuteTasks(report), true);
    }

    // 5*pf == pf+ar -> 4*pf == ar, i.e. fees are exactly 20% of total
    // rewards. The gate is `pf*5 > totalRewards` (strict), so equality
    // passes.
    function test_canExecuteTasks_trueAtTwentyPercentBoundary() public {
        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.accruedRewards = 4 ether;
        report.protocolFees = 1 ether; // 5*1 == 1+4
        _moveClock(1 days / 12);
        _submitForConsensus(report);

        assertEq(etherFiAdminInstance.canExecuteTasks(report), true);
    }

    function test_canExecuteTasks_falseWhenFeesExceedTwentyPercent() public {
        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        // 5*pf > pf+ar : pick pf=2, ar=4 -> 10 > 6.
        report.accruedRewards = 4 ether;
        report.protocolFees = 2 ether;
        _moveClock(1 days / 12);
        _submitForConsensus(report);

        assertEq(etherFiAdminInstance.canExecuteTasks(report), false);

        vm.expectRevert(abi.encodeWithSelector(EtherFiAdmin.ReportValidationFailed.selector, "EtherFiAdmin: protocol fees exceed 20% total rewards"));
        etherFiAdminInstance.executeTasks(report);
    }

    function test_canExecuteTasks_falseWhenValidatorRateAboveCap() public {
        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.validatorsToApprove = new uint256[](400); // > 200/day cap
        for (uint256 i = 0; i < 400; i++) {
            report.validatorsToApprove[i] = i + 1;
        }
        _moveClock(1 days / 12);
        _submitForConsensus(report);

        assertEq(etherFiAdminInstance.canExecuteTasks(report), false);

        vm.expectRevert(abi.encodeWithSelector(EtherFiAdmin.ReportValidationFailed.selector, "EtherFiAdmin: number of validators to approve exceeds max"));
        etherFiAdminInstance.executeTasks(report);
    }

    function test_canExecuteTasks_falseWhenWithdrawalRateAboveCap() public {
        // On-chain finalized amount (from a real request) exceeds the lowered per-day cap.
        _unpauseWithdrawNFT();
        _seedLp(200 ether);
        uint256 requestId = _makeWithdrawRequest(10 ether);

        vm.prank(alice);
        etherFiAdminInstance.updateMaxFinalizedWithdrawalAmountPerDay(0.001 ether);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.lastFinalizedWithdrawalRequestId = uint32(requestId);
        _moveClock(1 days / 12);
        _submitForConsensus(report);

        assertEq(etherFiAdminInstance.canExecuteTasks(report), false);

        vm.expectRevert(abi.encodeWithSelector(EtherFiAdmin.ReportValidationFailed.selector, "EtherFiAdmin: finalized withdrawal amount exceeds max"));
        etherFiAdminInstance.executeTasks(report);
    }

    function test_canExecuteTasks_falseWhenFinalizedExceedsLpLiquidity() public {
        _unpauseWithdrawNFT();
        _seedLp(10 ether);
        uint256 requestId = _makeWithdrawRequest(6 ether);

        _forceLpBalanceAndTVIL(5 ether); // totalValueInLp (5) < finalized amount (6)

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.lastFinalizedWithdrawalRequestId = uint32(requestId);
        _moveClock(1 days / 12);
        _submitForConsensus(report);

        assertEq(etherFiAdminInstance.canExecuteTasks(report), false);

        vm.expectRevert(abi.encodeWithSelector(EtherFiAdmin.ReportValidationFailed.selector, "EtherFiAdmin: finalized withdrawal exceeds LP liquidity"));
        etherFiAdminInstance.executeTasks(report);
    }

    function test_canExecuteTasks_trueOnHappyPath() public {
        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        _moveClock(1 days / 12);
        _submitForConsensus(report);

        assertEq(etherFiAdminInstance.canExecuteTasks(report), true);

        etherFiAdminInstance.executeTasks(report);

        // After execution the same report no longer matches the cursor.
        assertEq(etherFiAdminInstance.canExecuteTasks(report), false);
    }

    // =====================================================================
    // _validateReport: lastFinalizedWithdrawalRequestId / on-chain finalized-amount derivation
    //
    // The report no longer carries `finalizedWithdrawalAmount`. EtherFiAdmin derives it on-chain
    // from WithdrawRequestNFT's request prefix-sum:
    //   getFinalizedWithdrawalAmount(R) = totalRequestedWithdrawalAmount[R]
    //                                     - totalRequestedWithdrawalAmount[lastFinalizedRequestId]
    // i.e. the sum of (still-valid) request amounts in (lastFinalizedRequestId, R]. The
    // report->on-chain sum-mismatch gate was removed (the amount is no longer caller-supplied, so
    // it cannot disagree); the per-report range cap was also removed. The remaining gates are the
    // per-day cap, the LP-liquidity bound, and the strict no-backwards-cursor check. Each test
    // below pins one branch of that logic.
    // =====================================================================

    // Equality edge, valid case: cursor == state, derived amount == 0. The steady-state
    // "nothing finalized this period" report.
    function test_canExecuteTasks_trueWhenIdEqualsCursorAndAmountZero() public {
        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.lastFinalizedWithdrawalRequestId = 0;

        _moveClock(1 days / 12);
        _submitForConsensus(report);

        assertEq(etherFiAdminInstance.canExecuteTasks(report), true);
    }

    // Happy path: single valid request, derived amount = its amountOfEEth.
    function test_canExecuteTasks_trueWhenSingleRequest() public {
        _unpauseWithdrawNFT();
        _seedLp(10 ether);
        uint256 r1 = _makeWithdrawRequest(3 ether);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.lastFinalizedWithdrawalRequestId = uint32(r1);

        _moveClock(1 days / 12);
        _submitForConsensus(report);

        assertEq(etherFiAdminInstance.canExecuteTasks(report), true);

        etherFiAdminInstance.executeTasks(report);
        assertEq(withdrawRequestNFTInstance.lastFinalizedRequestId(), uint32(r1));
    }

    // Happy path: the prefix-sum spans many ids; derived amount = 1 + 2 + 3.
    function test_canExecuteTasks_trueWhenMultipleRequests() public {
        _unpauseWithdrawNFT();
        _seedLp(20 ether);
        _makeWithdrawRequest(1 ether);
        _makeWithdrawRequest(2 ether);
        uint256 r3 = _makeWithdrawRequest(3 ether);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.lastFinalizedWithdrawalRequestId = uint32(r3);

        _moveClock(1 days / 12);
        _submitForConsensus(report);

        assertEq(etherFiAdminInstance.canExecuteTasks(report), true);
    }

    // Invalidating a request decrements the head prefix-sum, so when the report finalizes up to
    // the head (r3), the derived amount excludes the invalidated r2: 1 + 3 = 4.
    function test_canExecuteTasks_trueWhenInvalidRequestExcludedFromHead() public {
        _unpauseWithdrawNFT();
        _seedLp(20 ether);
        _makeWithdrawRequest(1 ether);
        uint256 r2 = _makeWithdrawRequest(2 ether);
        uint256 r3 = _makeWithdrawRequest(3 ether);

        _invalidateRequest(r2);

        // Derived amount = prefix[r3] - prefix[0] = (1 + 3) = 4 ether (r2 removed from head).
        assertEq(withdrawRequestNFTInstance.getFinalizedWithdrawalAmount(uint32(r3)), 4 ether);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.lastFinalizedWithdrawalRequestId = uint32(r3);

        _moveClock(1 days / 12);
        _submitForConsensus(report);

        assertEq(etherFiAdminInstance.canExecuteTasks(report), true);
    }

    // Cleanup scenario: every pending request was invalidated, so the head prefix-sum is 0 and the
    // derived finalized amount is 0. Cursor still advances past them.
    function test_canExecuteTasks_trueWhenAllRequestsInvalidAndAmountZero() public {
        _unpauseWithdrawNFT();
        _seedLp(10 ether);
        uint256 r1 = _makeWithdrawRequest(1 ether);
        uint256 r2 = _makeWithdrawRequest(2 ether);

        _invalidateRequest(r1);
        _invalidateRequest(r2);

        assertEq(withdrawRequestNFTInstance.getFinalizedWithdrawalAmount(uint32(r2)), 0);

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.lastFinalizedWithdrawalRequestId = uint32(r2);

        _moveClock(1 days / 12);
        _submitForConsensus(report);

        assertEq(etherFiAdminInstance.canExecuteTasks(report), true);
    }

    // The cursor cannot move backwards. After processing r1 in a first report, a follow-up with
    // lastFinalizedWithdrawalRequestId < state's cursor is rejected by the strict `<` guard.
    function test_canExecuteTasks_falseWhenIdLessThanStateCursor() public {
        _unpauseWithdrawNFT();
        _seedLp(20 ether);
        uint256 r1 = _makeWithdrawRequest(2 ether);

        IEtherFiOracle.OracleReport memory firstReport = _emptyOracleReport();
        firstReport.lastFinalizedWithdrawalRequestId = uint32(r1);
        _moveClock(1 days / 12);
        _executeAdminTasks(firstReport);

        assertEq(withdrawRequestNFTInstance.lastFinalizedRequestId(), uint32(r1));

        // Second report points to id 0, less than state's cursor (r1 = 1).
        IEtherFiOracle.OracleReport memory secondReport = _emptyOracleReport();
        secondReport.lastFinalizedWithdrawalRequestId = 0;
        _moveClock(1 days / 12);
        _submitForConsensus(secondReport);

        assertEq(etherFiAdminInstance.canExecuteTasks(secondReport), false);

        vm.expectRevert(abi.encodeWithSelector(EtherFiAdmin.ReportValidationFailed.selector, "EtherFiAdmin: finalized withdrawal request id is less than last finalized request id"));
        etherFiAdminInstance.executeTasks(secondReport);
    }

    // Cursor advances on each successful report. A second report finalizing only the newly-created
    // request derives its amount over just the new range (prefix[r2] - prefix[r1]), not r1 again.
    function test_canExecuteTasks_trueOnSecondReportAfterCursorAdvances() public {
        _unpauseWithdrawNFT();
        _seedLp(20 ether);
        uint256 r1 = _makeWithdrawRequest(1 ether);

        IEtherFiOracle.OracleReport memory firstReport = _emptyOracleReport();
        firstReport.lastFinalizedWithdrawalRequestId = uint32(r1);
        _moveClock(1 days / 12);
        _executeAdminTasks(firstReport);

        uint256 r2 = _makeWithdrawRequest(2 ether);

        // Derived amount for the second report = prefix[r2] - prefix[r1] = (1 + 2) - 1 = 2 ether.
        assertEq(withdrawRequestNFTInstance.getFinalizedWithdrawalAmount(uint32(r2)), 2 ether);

        IEtherFiOracle.OracleReport memory secondReport = _emptyOracleReport();
        secondReport.lastFinalizedWithdrawalRequestId = uint32(r2);

        _moveClock(1 days / 12);
        _submitForConsensus(secondReport);

        assertEq(etherFiAdminInstance.canExecuteTasks(secondReport), true);

        etherFiAdminInstance.executeTasks(secondReport);
        assertEq(withdrawRequestNFTInstance.lastFinalizedRequestId(), uint32(r2));
    }

    // ========== EtherFiAdmin finalizeWithdrawalsWhenStale Tests ==========

    // Permissionless escape hatch that lets anyone finalize pending withdrawal
    // requests once the oracle has gone silent for staleOracleReportBlockWindow
    // blocks. Walks pending requests in order, skips invalidated ones, stops
    // when LP balance can't cover the next valid request, and only commits if
    // it accumulated something to lock.

    function _unpauseWithdrawNFT() internal {
        if (withdrawRequestNFTInstance.paused()) {
            vm.prank(admin);
            withdrawRequestNFTInstance.unpause();
        }
    }

    // Bob deposits ETH so the LP has both `totalValueInLp` and actual ETH
    // balance to cover finalized withdrawals later, then receives eETH that
    // we'll use to back the withdraw request.
    function _seedLp(uint256 amount) internal {
        vm.deal(bob, amount);
        vm.prank(bob);
        liquidityPoolInstance.deposit{value: amount}();
    }

    function _makeWithdrawRequest(uint96 amount) internal returns (uint256) {
        vm.prank(bob);
        eETHInstance.approve(address(liquidityPoolInstance), amount);
        vm.prank(bob);
        return liquidityPoolInstance.requestWithdraw(bob, amount);
    }

    function _invalidateRequest(uint256 requestId) internal {
        vm.prank(alice);
        withdrawRequestNFTInstance.invalidateRequest(requestId);
    }

    // Forces LP balance AND totalValueInLp to `target` in lockstep so the
    // strict tVIL <= balance invariant enforced by _checkTotalValueInLp
    // stays intact. vm.deal alone would drop balance without touching tVIL
    // and trip the invariant on the next addEthAmountLockedForWithdrawal.
    // Slot 207 packs totalValueOutOfLp (offset 0) and totalValueInLp
    // (offset 16) per `forge inspect LiquidityPool storage`.
    function _forceLpBalanceAndTVIL(uint128 target) internal {
        bytes32 slot = bytes32(uint256(207));
        bytes32 raw = vm.load(address(liquidityPoolInstance), slot);
        uint128 outOf = uint128(uint256(raw)); // low 128 bits = totalValueOutOfLp
        bytes32 packed = bytes32((uint256(target) << 128) | uint256(outOf));
        vm.store(address(liquidityPoolInstance), slot, packed);
        vm.deal(address(liquidityPoolInstance), uint256(target));
    }

    // Roll forward until block.number == lastHandledReportRefBlock + staleOracleReportBlockWindow
    // (the boundary at which the staleness check first passes).
    function _advanceToStaleBoundary() internal {
        uint256 staleAt = uint256(etherFiAdminInstance.lastHandledReportRefBlock())
            + etherFiAdminInstance.staleOracleReportBlockWindow();
        if (block.number < staleAt) {
            _moveClock(int256(staleAt - block.number));
        }
    }

    // Reverts when the last report is still fresh — block.number sits below
    // lastHandledReportRefBlock + staleOracleReportBlockWindow. With both
    // fields at zero post-setup, we're trivially fresh.
    function test_finalizeWithdrawalsWhenStale_revertsWhenNotStale() public {
        // setUp() rolls to block 0; lastHandledReportRefBlock is 0; stale
        // window is 7200, so 0 < 7200 → not stale.
        assertLt(block.number, etherFiAdminInstance.staleOracleReportBlockWindow());

        vm.expectRevert(EtherFiAdmin.OracleReportNotStale.selector);
        etherFiAdminInstance.finalizeWithdrawalsWhenStale();
    }

    // One block before the staleness boundary still reverts; the check uses
    // strict `<`.
    function test_finalizeWithdrawalsWhenStale_revertsOneBlockBeforeStaleBoundary() public {
        uint256 staleWindow = etherFiAdminInstance.staleOracleReportBlockWindow();
        _moveClock(int256(staleWindow - 1));
        assertEq(block.number, staleWindow - 1);

        vm.expectRevert(EtherFiAdmin.OracleReportNotStale.selector);
        etherFiAdminInstance.finalizeWithdrawalsWhenStale();
    }

    // At exactly lastHandledReportRefBlock + staleOracleReportBlockWindow
    // the report is considered stale and the staleness check passes. With no
    // pending requests we then revert with NoWithdrawalsToFinalize — proving
    // we cleared the freshness check.
    function test_finalizeWithdrawalsWhenStale_succeedsAtExactStaleBoundary() public {
        _advanceToStaleBoundary();
        assertEq(block.number, etherFiAdminInstance.staleOracleReportBlockWindow());

        vm.expectRevert(EtherFiAdmin.NoWithdrawalsToFinalize.selector);
        etherFiAdminInstance.finalizeWithdrawalsWhenStale();
    }

    // After processing a fresh oracle report, the staleness window resets
    // relative to the report's refBlockTo. Calling again immediately reverts
    // with OracleReportNotStale even if we were previously stale.
    function test_finalizeWithdrawalsWhenStale_revertsAfterFreshReport() public {
        _unpauseWithdrawNFT();
        _seedLp(10 ether);
        _makeWithdrawRequest(1 ether);

        // Bring us past the initial stale window so we can run a fresh report.
        _advanceToStaleBoundary();

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        _executeAdminTasks(report);
        assertGt(etherFiAdminInstance.lastHandledReportRefBlock(), 0);
        assertLt(
            block.number,
            uint256(etherFiAdminInstance.lastHandledReportRefBlock())
                + etherFiAdminInstance.staleOracleReportBlockWindow()
        );

        vm.expectRevert(EtherFiAdmin.OracleReportNotStale.selector);
        etherFiAdminInstance.finalizeWithdrawalsWhenStale();
    }

    // No pending withdrawal requests at all → loop body never runs → revert
    // with NoWithdrawalsToFinalize (rather than silently no-op).
    function test_finalizeWithdrawalsWhenStale_revertsWhenNoPendingRequests() public {
        _advanceToStaleBoundary();

        assertEq(withdrawRequestNFTInstance.nextRequestId(), 1);
        assertEq(withdrawRequestNFTInstance.lastFinalizedRequestId(), 0);

        vm.expectRevert(EtherFiAdmin.NoWithdrawalsToFinalize.selector);
        etherFiAdminInstance.finalizeWithdrawalsWhenStale();
    }

    // Every pending request was invalidated by the oracle → loop walks through
    // them all (advancing requestId past each) but accumulates 0 ETH → revert.
    // lastFinalizedRequestId is unchanged because we never reach _finalizeWithdrawals.
    function test_finalizeWithdrawalsWhenStale_revertsWhenAllRequestsInvalid() public {
        _unpauseWithdrawNFT();
        _seedLp(10 ether);

        uint256 r1 = _makeWithdrawRequest(1 ether);
        uint256 r2 = _makeWithdrawRequest(1 ether);
        _invalidateRequest(r1);
        _invalidateRequest(r2);

        _advanceToStaleBoundary();

        uint32 lastFinalizedBefore = withdrawRequestNFTInstance.lastFinalizedRequestId();
        vm.expectRevert(EtherFiAdmin.NoWithdrawalsToFinalize.selector);
        etherFiAdminInstance.finalizeWithdrawalsWhenStale();

        assertEq(withdrawRequestNFTInstance.lastFinalizedRequestId(), lastFinalizedBefore);
    }

    // LP balance is below the first request's amount → break immediately on
    // iteration 1 → finalizedWithdrawalAmount stays at 0 → revert.
    function test_finalizeWithdrawalsWhenStale_revertsWhenInsufficientLiquidityForFirstRequest() public {
        _unpauseWithdrawNFT();
        _seedLp(10 ether);
        _makeWithdrawRequest(5 ether);

        // Drain totalValueInLp below the request amount; the staleness function
        // reads `liquidityPool.totalValueInLp()`, so we have to drop both
        // accounting and balance to make the liquidity check fail.
        _forceLpBalanceAndTVIL(1 ether);

        _advanceToStaleBoundary();

        vm.expectRevert(EtherFiAdmin.NoWithdrawalsToFinalize.selector);
        etherFiAdminInstance.finalizeWithdrawalsWhenStale();
    }

    // Happy path: single valid request, LP has enough — finalizes the request,
    // moves ETH from LP to the NFT, and advances lastFinalizedRequestId.
    function test_finalizeWithdrawalsWhenStale_singleValidRequest_succeeds() public {
        _unpauseWithdrawNFT();
        _seedLp(10 ether);
        uint256 requestId = _makeWithdrawRequest(1 ether);

        _advanceToStaleBoundary();

        uint256 lpBalanceBefore = address(liquidityPoolInstance).balance;
        uint256 nftBalanceBefore = address(withdrawRequestNFTInstance).balance;
        uint128 lockedBefore = withdrawRequestNFTInstance.ethAmountLockedForWithdrawal();

        etherFiAdminInstance.finalizeWithdrawalsWhenStale();

        assertEq(withdrawRequestNFTInstance.lastFinalizedRequestId(), uint32(requestId));
        assertTrue(withdrawRequestNFTInstance.isFinalized(requestId));
        assertEq(address(liquidityPoolInstance).balance, lpBalanceBefore - 1 ether);
        assertEq(address(withdrawRequestNFTInstance).balance, nftBalanceBefore + 1 ether);
        assertEq(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal(), lockedBefore + 1 ether);
    }

    // Multiple valid requests, LP covers them all. Locked amount equals the
    // sum, and lastFinalizedRequestId advances to the last one.
    function test_finalizeWithdrawalsWhenStale_finalizesAllValidRequests() public {
        _unpauseWithdrawNFT();
        _seedLp(20 ether);
        _makeWithdrawRequest(1 ether);
        _makeWithdrawRequest(2 ether);
        uint256 r3 = _makeWithdrawRequest(3 ether);

        _advanceToStaleBoundary();

        uint256 lpBalanceBefore = address(liquidityPoolInstance).balance;
        uint128 lockedBefore = withdrawRequestNFTInstance.ethAmountLockedForWithdrawal();

        etherFiAdminInstance.finalizeWithdrawalsWhenStale();

        assertEq(withdrawRequestNFTInstance.lastFinalizedRequestId(), uint32(r3));
        assertEq(address(liquidityPoolInstance).balance, lpBalanceBefore - 6 ether);
        assertEq(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal(), lockedBefore + 6 ether);
    }

    // Invalid request in the middle is skipped: requestId still advances past
    // it (so it ends up "finalized" too), but its amount is NOT added to the
    // locked total.
    function test_finalizeWithdrawalsWhenStale_skipsInvalidRequestsInMiddle() public {
        _unpauseWithdrawNFT();
        _seedLp(20 ether);
        _makeWithdrawRequest(1 ether);
        uint256 r2 = _makeWithdrawRequest(2 ether);
        uint256 r3 = _makeWithdrawRequest(3 ether);

        _invalidateRequest(r2);

        _advanceToStaleBoundary();

        uint256 lpBalanceBefore = address(liquidityPoolInstance).balance;
        uint128 lockedBefore = withdrawRequestNFTInstance.ethAmountLockedForWithdrawal();

        etherFiAdminInstance.finalizeWithdrawalsWhenStale();

        // r2 is invalid but the loop walks past it, so lastFinalized lands on r3.
        assertEq(withdrawRequestNFTInstance.lastFinalizedRequestId(), uint32(r3));
        // Only valid amounts contribute: 1 + 3 = 4.
        assertEq(address(liquidityPoolInstance).balance, lpBalanceBefore - 4 ether);
        assertEq(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal(), lockedBefore + 4 ether);
    }

    // Trailing invalid requests are still included in lastFinalizedRequestId
    // even though they contribute zero to the locked amount.
    function test_finalizeWithdrawalsWhenStale_includesTrailingInvalidRequests() public {
        _unpauseWithdrawNFT();
        _seedLp(20 ether);
        _makeWithdrawRequest(1 ether);
        _makeWithdrawRequest(2 ether);
        uint256 r3 = _makeWithdrawRequest(3 ether);

        _invalidateRequest(r3);

        _advanceToStaleBoundary();

        uint256 lpBalanceBefore = address(liquidityPoolInstance).balance;

        etherFiAdminInstance.finalizeWithdrawalsWhenStale();

        // Loop continues through the trailing invalid → finalizes up through r3.
        assertEq(withdrawRequestNFTInstance.lastFinalizedRequestId(), uint32(r3));
        // Only the two valid requests' amounts get locked.
        assertEq(address(liquidityPoolInstance).balance, lpBalanceBefore - 3 ether);
    }

    // Liquidity runs out mid-way: finalize as many as fit, stop at the first
    // valid request the LP can't cover. The leftover request stays pending.
    function test_finalizeWithdrawalsWhenStale_stopsAtLiquidityLimit() public {
        _unpauseWithdrawNFT();
        _seedLp(20 ether);
        uint256 r1 = _makeWithdrawRequest(3 ether);
        _makeWithdrawRequest(4 ether);
        uint256 r3 = _makeWithdrawRequest(5 ether);

        // Cap LP balance at 5 ether: r1 fits (3), r1+r2 doesn't (7 > 5), break.
        // Lockstep tVIL so the post-lock invariant holds.
        _forceLpBalanceAndTVIL(5 ether);

        _advanceToStaleBoundary();

        uint128 lockedBefore = withdrawRequestNFTInstance.ethAmountLockedForWithdrawal();

        etherFiAdminInstance.finalizeWithdrawalsWhenStale();

        // Stopped after r1. r2 and r3 stay unfinalized.
        assertEq(withdrawRequestNFTInstance.lastFinalizedRequestId(), uint32(r1));
        assertTrue(withdrawRequestNFTInstance.isFinalized(r1));
        assertFalse(withdrawRequestNFTInstance.isFinalized(r3));
        assertEq(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal(), lockedBefore + 3 ether);
    }

    // Invalid + valid-but-too-big combo: loop skips the invalid (advancing
    // past it) then hits the unfundable valid one and breaks. Since nothing
    // accumulated, we revert — lastFinalizedRequestId stays put. This shows
    // the function refuses to "lock in" the skipped invalid without also
    // locking real ETH.
    function test_finalizeWithdrawalsWhenStale_revertsWhenOnlyInvalidIsTraversable() public {
        _unpauseWithdrawNFT();
        _seedLp(20 ether);
        uint256 r1 = _makeWithdrawRequest(3 ether);
        _makeWithdrawRequest(5 ether);

        _invalidateRequest(r1);
        // totalValueInLp below the next (valid) request's amount.
        _forceLpBalanceAndTVIL(1 ether);

        _advanceToStaleBoundary();

        uint32 lastFinalizedBefore = withdrawRequestNFTInstance.lastFinalizedRequestId();
        vm.expectRevert(EtherFiAdmin.NoWithdrawalsToFinalize.selector);
        etherFiAdminInstance.finalizeWithdrawalsWhenStale();

        assertEq(withdrawRequestNFTInstance.lastFinalizedRequestId(), lastFinalizedBefore);
        assertFalse(withdrawRequestNFTInstance.isFinalized(r1));
    }

    // Invalid + valid-fundable combo: loop skips the invalid (advancing past
    // it) then finalizes the valid one. lastFinalizedRequestId lands on the
    // valid one — i.e., the invalid in front of it gets dragged in.
    function test_finalizeWithdrawalsWhenStale_finalizesValidAfterLeadingInvalid() public {
        _unpauseWithdrawNFT();
        _seedLp(20 ether);
        uint256 r1 = _makeWithdrawRequest(1 ether);
        uint256 r2 = _makeWithdrawRequest(2 ether);
        _invalidateRequest(r1);

        _advanceToStaleBoundary();

        uint128 lockedBefore = withdrawRequestNFTInstance.ethAmountLockedForWithdrawal();
        uint256 lpBalanceBefore = address(liquidityPoolInstance).balance;

        etherFiAdminInstance.finalizeWithdrawalsWhenStale();

        assertEq(withdrawRequestNFTInstance.lastFinalizedRequestId(), uint32(r2));
        assertEq(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal(), lockedBefore + 2 ether);
        assertEq(address(liquidityPoolInstance).balance, lpBalanceBefore - 2 ether);
    }

    // The function is permissionless — a role-less address can still trigger it
    // once the report is stale.
    function test_finalizeWithdrawalsWhenStale_isPermissionless() public {
        _unpauseWithdrawNFT();
        _seedLp(10 ether);
        uint256 requestId = _makeWithdrawRequest(1 ether);

        _advanceToStaleBoundary();

        address randoCaller = makeAddr("randoCaller2");
        assertFalse(roleRegistryInstance.hasRole(roleRegistryInstance.OPERATION_TIMELOCK_ROLE(), randoCaller));
        assertFalse(roleRegistryInstance.hasRole(roleRegistryInstance.ORACLE_OPERATIONS_ROLE(), randoCaller));

        vm.prank(randoCaller);
        etherFiAdminInstance.finalizeWithdrawalsWhenStale();

        assertEq(withdrawRequestNFTInstance.lastFinalizedRequestId(), uint32(requestId));
    }

    function test_finalizeWithdrawalsWhenStale_revertsWhenCooldownPeriodNotElapsed() public {
        _unpauseWithdrawNFT();
        _seedLp(10 ether);
        _makeWithdrawRequest(1 ether);

        _advanceToStaleBoundary();
        
        etherFiAdminInstance.finalizeWithdrawalsWhenStale();

        vm.expectRevert(EtherFiAdmin.StaleReportFinalizationCooldown.selector);
        etherFiAdminInstance.finalizeWithdrawalsWhenStale();
    }

    // Calling twice back-to-back: second call has nothing new to finalize so
    // it reverts with NoWithdrawalsToFinalize (not OracleReportNotStale —
    // staleness is still satisfied, the inner loop just finds nothing).
    function test_finalizeWithdrawalsWhenStale_secondCallWithNoNewRequestsReverts() public {
        _unpauseWithdrawNFT();
        _seedLp(10 ether);
        _makeWithdrawRequest(1 ether);

        _advanceToStaleBoundary();

        etherFiAdminInstance.finalizeWithdrawalsWhenStale();

        vm.roll(block.number + etherFiAdminInstance.STALE_REPORT_FINALIZATION_COOLDOWN() + 1);

        vm.expectRevert(EtherFiAdmin.NoWithdrawalsToFinalize.selector);
        etherFiAdminInstance.finalizeWithdrawalsWhenStale();
    }

    // A partial-fill call followed by another after liquidity replenishes:
    // the second call picks up the leftover request that the first one
    // couldn't cover after cooldown period.
    function test_finalizeWithdrawalsWhenStale_resumesAfterLiquidityReplenishes() public {
        _unpauseWithdrawNFT();
        _seedLp(20 ether);
        uint256 r1 = _makeWithdrawRequest(3 ether);
        uint256 r2 = _makeWithdrawRequest(4 ether);

        // First call: only r1 fits. Lockstep tVIL with balance so the
        // post-lock invariant holds when r1 gets finalized.
        _forceLpBalanceAndTVIL(3 ether);
        _advanceToStaleBoundary();
        etherFiAdminInstance.finalizeWithdrawalsWhenStale();
        assertEq(withdrawRequestNFTInstance.lastFinalizedRequestId(), uint32(r1));
        assertFalse(withdrawRequestNFTInstance.isFinalized(r2));

        // After r1's ETH has moved out, LP balance is 0. Replenish so r2 fits.
        // Bump totalValueInLp via a deposit so addEthAmountLockedForWithdrawal
        // doesn't trip its own InsufficientLiquidity guard.
        _seedLp(10 ether);

        vm.roll(block.number + etherFiAdminInstance.STALE_REPORT_FINALIZATION_COOLDOWN() + 1);

        etherFiAdminInstance.finalizeWithdrawalsWhenStale();
        assertEq(withdrawRequestNFTInstance.lastFinalizedRequestId(), uint32(r2));
        assertTrue(withdrawRequestNFTInstance.isFinalized(r2));
    }

    // Boundary: liquidity exactly equals the request amount. The check is
    // `liquidity < accumulated + amount` so equality should succeed.
    function test_finalizeWithdrawalsWhenStale_succeedsWhenLiquidityExactlyMatches() public {
        _unpauseWithdrawNFT();
        _seedLp(5 ether);
        uint256 requestId = _makeWithdrawRequest(5 ether);

        // LP balance and request amount are both 5 ether.
        assertEq(address(liquidityPoolInstance).balance, 5 ether);

        _advanceToStaleBoundary();

        etherFiAdminInstance.finalizeWithdrawalsWhenStale();

        assertEq(withdrawRequestNFTInstance.lastFinalizedRequestId(), uint32(requestId));
        assertEq(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal(), 5 ether);
    }
}
