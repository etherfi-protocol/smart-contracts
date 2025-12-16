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
import "../../deploys/Deployed.s.sol";
import "../../../src/WithdrawRequestNFT.sol";

// Commands:
// forge script script/el-exits/val-consolidations/topUpFork.s.sol --fork-url $MAINNET_RPC_URL -vvvv

/**
Transactions:
1. Set validator size to 2000 ether
2. AVS Operators submit the report
3. Admin executes the tasks using that report
4. Admin executes the validator approval task

OR ANOTHER WAY:

1. Set validator size to 2000 ether
2. Give the LIQUIDITY_POOL_VALIDATOR_APPROVER_ROLE to the ETHERFI_OPERATING_ADMIN
3. Call batchApproveRegistration() to approve the validator by the ETHERFI_OPERATING_ADMIN
4. Remove the LIQUIDITY_POOL_VALIDATOR_APPROVER_ROLE from the ETHERFI_OPERATING_ADMIN
 */

contract TopUpFork is Script, Deployed, Utils, ArrayTestHelper {
    int256 slotsPerEpoch = 32;
    int256 secondsPerSlot = 12;

    EtherFiNodesManager constant etherFiNodesManager = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER));
    RoleRegistry constant roleRegistry = RoleRegistry(ROLE_REGISTRY);
    LiquidityPool constant liquidityPool = LiquidityPool(payable(LIQUIDITY_POOL));
    EtherFiOracle constant etherFiOracleInstance = EtherFiOracle(payable(ETHERFI_ORACLE));
    EtherFiAdmin constant etherFiAdminInstance = EtherFiAdmin(payable(ETHERFI_ADMIN));
    WithdrawRequestNFT constant withdrawRequestNFTInstance = WithdrawRequestNFT(payable(WITHDRAW_REQUEST_NFT));
    address constant NODE_ADDRESS = 0xfbD914e11dF3DB8f475ae9C36ED46eE0c48f6B79;
    address constant AVS_OPERATOR_1 = 0xDd777e5158Cb11DB71B4AF93C75A96eA11A2A615;
    address constant AVS_OPERATOR_2 = 0x2c7cB7d5dC4aF9caEE654553a144C76F10D4b320;

    uint256 constant BID_ID = 110766;
    bytes constant PUBKEY = hex"a538a38970260348b6258eec086b932a76d369c96b5c87de5645807657c6128312e0c76bcd9987469ffe16d425bc971e";
    // provide 96 bytes of zeros for signature
    bytes constant SIGNATURE = hex"000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

    function run() external {
        console2.log("=== TOP UP FORK ===");

        vm.prank(OPERATING_TIMELOCK);
        liquidityPool.setValidatorSizeWei(2000 ether);

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

        (bytes[] memory pubkeys, uint256[] memory ids, bytes[] memory signatures) = _parseValidatorsFromForkJson();
        report.validatorsToApprove = ids;
        report.lastFinalizedWithdrawalRequestId = withdrawRequestNFTInstance.lastFinalizedRequestId();
        
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

    function _parseValidatorsFromForkJson() internal view returns (bytes[] memory pubkeys, uint256[] memory ids, bytes[] memory signatures) {
        string memory root = vm.projectRoot();
        string memory jsonFilePath = string.concat(
            root,
            "/script/el-exits/val-consolidations/LugaNodes.json"
        );
        string memory jsonData = vm.readFile(jsonFilePath);
        uint256 validatorCount = 10; // First 10 validators from LugaNodes.json

        pubkeys = new bytes[](validatorCount);
        ids = new uint256[](validatorCount);
        signatures = new bytes[](validatorCount);
        for (uint256 i = 0; i < validatorCount; i++) {
            string memory basePath = string.concat("$[", vm.toString(i), "]");
            ids[i] = stdJson.readUint(jsonData, string.concat(basePath, ".id"));
            pubkeys[i] = stdJson.readBytes(jsonData, string.concat(basePath, ".pubkey"));
            signatures[i] = SIGNATURE;
        }
    }
}