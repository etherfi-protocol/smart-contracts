// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "forge-std/StdJson.sol";
import "../../utils/utils.sol";
import "../../../src/EtherFiNodesManager.sol";
import "../../../src/LiquidityPool.sol";
import "../../../src/EtherFiOracle.sol";
import "../../../src/EtherFiAdmin.sol";
import "../../../src/RoleRegistry.sol";
import "../../../test/common/ArrayTestHelper.sol";

contract HoodiTestTopUp is Script, ArrayTestHelper {
    int256 slotsPerEpoch = 32;
    int256 secondsPerSlot = 12;

    EtherFiNodesManager constant etherFiNodesManager = EtherFiNodesManager(payable(0x7579194b8265e3Aa7df451c6BD2aff5B1FC5F945));
    RoleRegistry constant roleRegistry = RoleRegistry(0x7279853cA1804d4F705d885FeA7f1662323B5Aab);
    // EtherFiTimelock constant etherFiOperatingTimelock = EtherFiTimelock(payable(OPERATING_TIMELOCK));
    LiquidityPool constant liquidityPool = LiquidityPool(payable(0x4a8081095549e63153a61D21F92ff079fe39858E));
    EtherFiOracle constant etherFiOracleInstance = EtherFiOracle(payable(0x1888Fd1914af6980204AA0424f550d9bE35735e1));
    EtherFiAdmin constant etherFiAdminInstance = EtherFiAdmin(payable(0x0CF5ddcF6861Efd8C498466d162F231E44eB85Dd));
    address constant ORACLE_ADMIN = 0x100007b3D3DeFCa2D3ECD1b9c52872c93Ad995c5;
    address constant NODE_ADDRESS = 0xfbD914e11dF3DB8f475ae9C36ED46eE0c48f6B79;
    address constant ADMIN_EOA = 0x001000621b95AA950c1a27Bb2e1273e10d8dfF68;

    uint256 constant BID_ID = 1209339;
    bytes constant PUBKEY = hex"83dced4a00f099d91ab6c16ab94f835d681c5f2cdd16944869f224e9c9d26d74d72503e487f72915f66d150205dd3549";
    bytes constant SIGNATURE = hex"000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

    function run() external {
        console2.log("=== HOODI TEST TOPUP ===");

        vm.prank(ADMIN_EOA);
        liquidityPool.setValidatorSizeWei(2 ether);
        
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

        (report.refSlotFrom, report.refSlotTo, report.refBlockFrom) = etherFiOracleInstance.blockStampForNextReport();

        report.validatorsToApprove = new uint256[](1);
        report.validatorsToApprove[0] = BID_ID;

        // Set refBlockTo to a block number that is < block.number and > lastAdminExecutionBlock
        report.refBlockTo = uint32(block.number - 1);
        if (report.refBlockTo <= etherFiAdminInstance.lastAdminExecutionBlock()) {
            report.refBlockTo = etherFiAdminInstance.lastAdminExecutionBlock() + 1;
        }

        vm.prank(ORACLE_ADMIN);
        etherFiOracleInstance.submitReport(report);

        // Advance time for postReportWaitTimeInSlots
        uint256 slotsToWait = uint256(etherFiAdminInstance.postReportWaitTimeInSlots() + 1);
        uint32 slotAfterReport = etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp);
        vm.roll(block.number + slotsToWait);
        vm.warp(etherFiOracleInstance.beaconGenesisTimestamp() + 12 * (slotAfterReport + slotsToWait));

        vm.prank(etherFiOracleInstance.owner());
        etherFiAdminInstance.executeTasks(report);

        bytes[] memory pubkeys = new bytes[](1);
        pubkeys[0] = PUBKEY;
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = SIGNATURE;

        (bool completed, bool exists) = _executeValidatorApprovalTask(report, pubkeys, signatures);
        console.log("completed", completed);
        console.log("exists", exists);
    }

    function _executeValidatorApprovalTask(IEtherFiOracle.OracleReport memory report, bytes[] memory pubkeys, bytes[] memory signatures) internal returns (bool completed, bool exists) {
        bytes32 reportHash = etherFiOracleInstance.generateReportHash(report);
        bytes32 taskHash = keccak256(abi.encode(reportHash, report.validatorsToApprove));
        (completed, exists) = etherFiAdminInstance.validatorApprovalTaskStatus(taskHash);
        vm.prank(ADMIN_EOA);
        etherFiAdminInstance.executeValidatorApprovalTask(reportHash, report.validatorsToApprove, pubkeys, signatures);
        return (completed, exists);
    }
}