// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "forge-std/console2.sol";

contract EtherFiOracleTest is TestSetup {
    function setUp() public {
        setUpTests();

        // Timestamp = 1, BlockNumber = 0
        vm.roll(0);
    }

    function test_addCommitteeMember() public {
        _moveClock(1024 + 2 * slotsPerEpoch);

        // chad is not a commitee member
        vm.prank(chad);
        vm.expectRevert("You are not registered as the Oracle committee member");
        etherFiOracleInstance.submitReport(reportAtPeriod2A);

        // chad is added to the committee
        vm.prank(owner);
        etherFiOracleInstance.addCommitteeMember(chad);
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
        etherFiOracleInstance.manageCommitteeMember(chad, false);
        (registered, enabled, lastReportRefSlot, numReports) = etherFiOracleInstance.committeeMemberStates(chad);
        assertEq(registered, true);
        assertEq(enabled, false);
        assertEq(lastReportRefSlot, 1023);
        assertEq(numReports, 1);

        // chad fails to submit a report
        vm.prank(chad);
        vm.expectRevert("You are disabled");
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
        vm.expectRevert("Report Epoch is not finalized yet");
        etherFiOracleInstance.submitReport(reportAtPeriod2A);

        // At timpestamp = 12673, blocknumber = 1056, epoch = 33
        _moveClock(1 * slotsPerEpoch);
        vm.expectRevert("Report Epoch is not finalized yet");
        etherFiOracleInstance.submitReport(reportAtPeriod2A);

        // At timpestamp = 13045, blocknumber = 1087, epoch = 33
        _moveClock(31);
        vm.expectRevert("Report Epoch is not finalized yet");
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
        vm.expectRevert("Report is for wrong consensusVersion");
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
        vm.expectRevert("You don't need to submit a report");
        vm.prank(alice);
        etherFiOracleInstance.submitReport(reportAtPeriod2A);

        // alice submits a different report
        vm.expectRevert("You don't need to submit a report");
        vm.prank(alice);
        etherFiOracleInstance.submitReport(reportAtPeriod2B);
        
        _moveClock(1024 );
        // [timestamp = 25345, period 3]
        // 66 epoch

        // alice submits reports with wrong {slotFrom, slotTo, blockFrom}
        vm.expectRevert("Report is for wrong slotFrom");
        vm.prank(alice);
        etherFiOracleInstance.submitReport(reportAtPeriod4);

        // alice submits period 2 report
        vm.expectRevert("Report is for wrong slotTo");
        vm.prank(alice);
        etherFiOracleInstance.submitReport(reportAtPeriod2A);

        // alice submits period 3A report
        vm.expectRevert("Report is for wrong blockTo");
        vm.prank(alice);
        etherFiOracleInstance.submitReport(reportAtPeriod3A);

        // alice submits period 3B report
        vm.expectRevert("Report is for wrong blockFrom");
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
        (uint32 support, bool consensusReached) = etherFiOracleInstance.consensusStates(reportHash);
        assertEq(support, 1);

        // bob submits the period 2 report
        vm.prank(bob);
        etherFiOracleInstance.submitReport(reportAtPeriod2A);
        (support, consensusReached) = etherFiOracleInstance.consensusStates(reportHash);
        assertEq(support, 2);

        assertEq(etherFiOracleInstance.lastPublishedReportRefSlot(), reportAtPeriod2A.refSlotTo);
        assertEq(etherFiOracleInstance.lastPublishedReportRefBlock(), reportAtPeriod2A.refBlockTo);
    }

    function test_consensus() public {
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

        // alice submits the period 3 report
        vm.prank(alice);
        consensusReached = etherFiOracleInstance.submitReport(reportAtPeriod3);
        assertEq(consensusReached, false);
        // bob submits the same period 3 report
        vm.prank(bob);
        consensusReached = etherFiOracleInstance.submitReport(reportAtPeriod3);
        assertEq(consensusReached, true);

        // Now it's period 4
        _moveClock(1024);

        vm.prank(alice);
        consensusReached = etherFiOracleInstance.submitReport(reportAtPeriod4);
        assertEq(consensusReached, false);
        vm.prank(bob);
        consensusReached = etherFiOracleInstance.submitReport(reportAtPeriod4);
        assertEq(consensusReached, true);
    }

    function test_change_report_start_slot() public { 
        vm.prank(owner);
        etherFiOracleInstance.setQuorumSize(1);
        
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

        vm.prank(alice);
        etherFiOracleInstance.submitReport(report);

        (slotFrom, slotTo, blockFrom) = etherFiOracleInstance.blockStampForNextReport();
        assertEq(slotFrom, 1024);
        assertEq(slotTo, 2 * 1024 - 1);
        assertEq(blockFrom, 1024);

        console.log(etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp));
        vm.prank(owner);
        etherFiOracleInstance.setReportStartSlot(1 * 1024 + 512);

        (slotFrom, slotTo, blockFrom) = etherFiOracleInstance.blockStampForNextReport();
        assertEq(slotFrom, 1024);
        assertEq(slotTo, 2 * 1024 + 512 - 1);
        assertEq(blockFrom, 1024);

        _moveClock(1 * 1024 + 512);

        report.refSlotFrom = 1024;
        report.refSlotTo = 2 * 1024 + 512 -1;
        report.refBlockFrom = 1024;
        report.refBlockTo = 2 * 1024 + 512 -1;

        vm.prank(alice);
        etherFiOracleInstance.submitReport(report);

        (slotFrom, slotTo, blockFrom) = etherFiOracleInstance.blockStampForNextReport();
        assertEq(slotFrom, 2 * 1024 + 512);
        assertEq(slotTo, 3 * 1024 + 512 - 1);
        assertEq(blockFrom, 2 * 1024 + 512);
    }

    function test_report_start_slot() public {
        vm.prank(owner);
        etherFiOracleInstance.setReportStartSlot(2048);

        // note that the block timestamp starts from 1 (= slot 0) and the block number starts from 0

        // now after moveClock(1500)
        // timestamp = 1 + 1500 * 12 = slot 1500
        // block_number = 0 + 1500 = 1500
        _moveClock(1500);

        // this should fail because not start yet
        vm.prank(alice);
        vm.expectRevert("Report Epoch is not finalized yet");
        etherFiOracleInstance.submitReport(reportAtSlot3071);

        // current slot = 1500
        // after moveClock(500)
        // timestamp = (1 + 1500 * 12) + 548 * 12 = 1 + 2048 * 12 = slot 2048 = epoch 64
        // block_number = 0 + 2048 = 2048
        _moveClock(548);

        // this should fail because start but in period 1
        vm.prank(alice);
        vm.expectRevert("Report Epoch is not finalized yet");
        etherFiOracleInstance.submitReport(reportAtSlot3071);

        // 2048 + 1024 + 64 = 3136
        _moveClock(1024 + 2 * slotsPerEpoch);
        
        vm.prank(alice);
        etherFiOracleInstance.submitReport(reportAtSlot3071);

        // change startSlot to 3264
        vm.prank(owner);
        etherFiOracleInstance.setReportStartSlot(3264);

        // slot 3236
        _moveClock(100);
        
        vm.prank(alice);
        vm.expectRevert("Report Epoch is not finalized yet");
        etherFiOracleInstance.submitReport(reportAtSlot4287);

        _moveClock(28 + 1024 + 2 * slotsPerEpoch);

        vm.prank(alice);
        etherFiOracleInstance.submitReport(reportAtSlot4287);
    }

    function test_pause() public {
        _moveClock(1024 + 2 * slotsPerEpoch);
        
        vm.prank(owner);
        etherFiOracleInstance.pauseContract();

        vm.prank(alice);
        vm.expectRevert("Pausable: paused");
        etherFiOracleInstance.submitReport(reportAtPeriod2A);

        vm.prank(owner);
        etherFiOracleInstance.unPauseContract();

        vm.prank(alice);
        etherFiOracleInstance.submitReport(reportAtPeriod2A);
    }

    function test_set_quorum_size() public {
        vm.startPrank(owner);

        // TODO enable this test for mainnet
        // vm.expectRevert("Quorum size must be greater than 1");
        // etherFiOracleInstance.setQuorumSize(1);

        etherFiOracleInstance.setQuorumSize(2);

        vm.stopPrank();
    }

    function test_set_oracle_report_period() public {
        vm.startPrank(owner);

        vm.expectRevert("Report period cannot be zero");
        etherFiOracleInstance.setOracleReportPeriod(0);

        vm.expectRevert("Report period must be a multiple of the epoch");
        etherFiOracleInstance.setOracleReportPeriod(127);

        etherFiOracleInstance.setOracleReportPeriod(128);

        vm.stopPrank();
    }

    function test_admin_task() public {
        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();

        // When we want Oracle to allow to spin up one validator
        report.numValidatorsToSpinUp = 1;
        _executeAdminTasks(report);
        assertEq(etherFiAdminInstance.numValidatorsToSpinUp(), 1);

        report.eEthTargetAllocationWeight = 80;
        report.etherFanTargetAllocationWeight = 20;
        _executeAdminTasks(report);
        (, uint32 eEthTargetWeight) = liquidityPoolInstance.fundStatistics(ILiquidityPool.SourceOfFunds.EETH);
        (, uint32 etherFanTargetWeight) = liquidityPoolInstance.fundStatistics(ILiquidityPool.SourceOfFunds.ETHER_FAN);
        assertEq(eEthTargetWeight, 80);
        assertEq(etherFanTargetWeight, 20);
    }

    function test_huge_positive_rebaes() public {
        // TVL after `launch_validator` is 60 ETH
        // EtherFIAdmin limits the APR per rebase as 100 % == 10000 bps
        uint256[] memory validatorIds = launch_validator();

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();

        _moveClock(1 days / 12);

        // Change in APR is below 100%
        report.accruedRewards = int128(60 ether) / int128(365);
        _executeAdminTasks(report);

        _moveClock(1 days / 12);

        // Change in APR is above 100%, which reverts
        report.accruedRewards = int128(61 ether) / int128(365);
        _executeAdminTasks(report, "EtherFiAdmin: TVL changed too much");
    }

    function test_huge_negative_rebaes() public {
        // TVL after `launch_validator` is 60 ETH
        // EtherFIAdmin limits the APR per rebase as 100 % == 10000 bps
        uint256[] memory validatorIds = launch_validator();

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();

        _moveClock(1 days / 12);

        // Change in APR is below 100%
        report.accruedRewards = int128(-59 ether) / int128(365);
        _executeAdminTasks(report);

        _moveClock(1 days / 12);

        // Change in APR is above 100%, which reverts
        report.accruedRewards = int128(-61 ether) / int128(365);
        _executeAdminTasks(report, "EtherFiAdmin: TVL changed too much");
    }

}
