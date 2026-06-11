// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../../utils/utils.sol";
import {EtherFiOracle} from "../../../src/EtherFiOracle.sol";
import {IEtherFiOracle} from "../../../src/interfaces/IEtherFiOracle.sol";

// Update the EtherFiOracle `reportPeriodSlot` from 640 -> 1280 slots
// (20 -> 40 epochs at 32 slots/epoch).
//
// The call is issued by the operating-admin Safe
// (0x2aCA71020De61bb532008049e1Bd41E451aE8AdC), which is registered in
// `EtherFiOracle.admins` and therefore satisfies the `isAdmin` modifier
// on `setOracleReportPeriod`.
//
// On a fork the script also exercises the new period end-to-end:
//   1. add a fresh committee member,
//   2. submit a valid report once (passes),
//   3. submit the same report again (reverts: nothing to submit),
//   4. fast-forward by one `reportPeriodSlot` worth of seconds,
//   5. submit the next period's report (passes again).
//
//   forge script script/operations/oracle/SetOracleReportPeriod.s.sol --fork-url $MAINNET_RPC_URL -vvvv
contract SetOracleReportPeriod is Script, Utils {
    EtherFiOracle internal constant ORACLE = EtherFiOracle(ETHERFI_ORACLE);

    uint32 internal constant EXPECTED_BEFORE = 640;
    uint32 internal constant NEW_REPORT_PERIOD_SLOT = 1280;

    // ETH beacon-chain constants used by the oracle on mainnet.
    uint32 internal constant SLOTS_PER_EPOCH = 32;
    uint32 internal constant SECONDS_PER_SLOT = 12;

    // 3 epochs past the report slot is the minimum buffer to satisfy the
    // `_isFinalized` / `verifyReport` finalization checks
    // (`reportEpoch + 2 < currEpoch`). Use 4 for headroom.
    uint32 internal constant FINALIZATION_BUFFER_SLOTS = 4 * SLOTS_PER_EPOCH;

    function run() external {
        _writeGnosisTxFile();
        _simulateOnFork();
        _testReportSubmissionFlow();
    }

    function _simulateOnFork() internal {
        uint32 before = ORACLE.reportPeriodSlot();
        console2.log("=== Before ===");
        console2.log("reportPeriodSlot:", before);
        require(before == EXPECTED_BEFORE, "Unexpected current reportPeriodSlot");

        require(
            ORACLE.admins(ETHERFI_OPERATING_ADMIN),
            "Operating admin safe is not registered as an Oracle admin"
        );

        vm.prank(ETHERFI_OPERATING_ADMIN);
        ORACLE.setOracleReportPeriod(NEW_REPORT_PERIOD_SLOT);

        uint32 afterVal = ORACLE.reportPeriodSlot();
        console2.log("=== After ===");
        console2.log("reportPeriodSlot:", afterVal);
        require(afterVal == NEW_REPORT_PERIOD_SLOT, "reportPeriodSlot not updated");

        console2.log("Simulation successful");
    }

    // Fork test: prove the new period works correctly by walking a committee
    // member through one full submit / no-op / submit cycle.
    function _testReportSubmissionFlow() internal {
        require(
            ORACLE.reportPeriodSlot() == NEW_REPORT_PERIOD_SLOT,
            "reportPeriodSlot must already be updated"
        );

        address committeeMember = makeAddr("oracle-test-committee-member");
        address oracleOwner = ORACLE.owner();

        vm.prank(oracleOwner);
        ORACLE.addCommitteeMember(committeeMember);

        // Warp so the upcoming report's epoch is comfortably finalized but
        // we haven't crossed into the next period boundary.
        _warpIntoFinalizedWindow();

        console2.log("=== Report submission flow ===");

        // ---- 1st submit: should succeed ----
        IEtherFiOracle.OracleReport memory report1 = _buildNextReport();
        console2.log("report1.refSlotFrom:", report1.refSlotFrom);
        console2.log("report1.refSlotTo:  ", report1.refSlotTo);

        vm.prank(committeeMember);
        bool consensusReached1 = ORACLE.submitReport(report1);
        console2.log("1st submit ok, consensusReached:", consensusReached1);

        (, , uint32 lastReportRefSlot1, uint32 numReports1) =
            ORACLE.committeeMemberStates(committeeMember);
        require(lastReportRefSlot1 == report1.refSlotTo, "member slot not advanced");
        require(numReports1 == 1, "member numReports != 1");

        // ---- 2nd submit (same report): must revert ----
        vm.prank(committeeMember);
        try ORACLE.submitReport(report1) {
            revert("2nd submit unexpectedly succeeded");
        } catch Error(string memory reason) {
            require(
                keccak256(bytes(reason)) == keccak256("You don't need to submit a report"),
                string.concat("unexpected revert reason: ", reason)
            );
            console2.log("2nd submit reverted as expected:", reason);
        }

        // ---- Fast-forward by one full period and submit again ----
        uint32 prevRefSlotTo = report1.refSlotTo;
        vm.warp(block.timestamp + uint256(NEW_REPORT_PERIOD_SLOT) * SECONDS_PER_SLOT);

        IEtherFiOracle.OracleReport memory report2 = _buildNextReport();
        console2.log("report2.refSlotTo:  ", report2.refSlotTo);
        require(
            report2.refSlotTo == prevRefSlotTo + NEW_REPORT_PERIOD_SLOT,
            "refSlotTo did not advance by one period"
        );

        vm.prank(committeeMember);
        bool consensusReached2 = ORACLE.submitReport(report2);
        console2.log("3rd submit ok, consensusReached:", consensusReached2);

        (, , uint32 lastReportRefSlot2, uint32 numReports2) =
            ORACLE.committeeMemberStates(committeeMember);
        require(lastReportRefSlot2 == report2.refSlotTo, "member slot not advanced after warp");
        require(numReports2 == 2, "member numReports != 2");

        console2.log("Report submission flow passed");
    }

    // Warps `block.timestamp` forward (if needed) so that the current
    // `slotForNextReport()` sits at least `FINALIZATION_BUFFER_SLOTS` behind
    // the current slot, without crossing into the next period.
    function _warpIntoFinalizedWindow() internal {
        uint32 nextSlot = ORACLE.slotForNextReport();
        uint32 currSlot = ORACLE.computeSlotAtTimestamp(block.timestamp);
        if (currSlot < nextSlot + FINALIZATION_BUFFER_SLOTS) {
            uint256 deltaSlots = uint256(nextSlot + FINALIZATION_BUFFER_SLOTS - currSlot);
            vm.warp(block.timestamp + deltaSlots * SECONDS_PER_SLOT);
        }
    }

    function _buildNextReport()
        internal
        view
        returns (IEtherFiOracle.OracleReport memory r)
    {
        (uint32 slotFrom, uint32 slotTo, uint32 blockFrom) = ORACLE.blockStampForNextReport();
        r.consensusVersion = ORACLE.consensusVersion();
        r.refSlotFrom = slotFrom;
        r.refSlotTo = slotTo;
        r.refBlockFrom = blockFrom;
        r.refBlockTo = uint32(block.number - 1);
        // Remaining fields (accruedRewards, protocolFees, arrays,
        // lastFinalizedWithdrawalRequestId, finalizedWithdrawalAmount) stay
        // at their zero defaults — they're only used for the report hash.
    }

    function _writeGnosisTxFile() internal {
        bytes memory data = abi.encodeWithSelector(
            EtherFiOracle.setOracleReportPeriod.selector,
            NEW_REPORT_PERIOD_SLOT
        );

        writeSafeJson(
            "script/operations/oracle",
            "set-oracle-report-period.json",
            ETHERFI_OPERATING_ADMIN,
            address(ORACLE),
            0,
            data,
            1
        );
    }
}
