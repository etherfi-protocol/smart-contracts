// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "forge-std/console2.sol";

contract EtherFiAdminUpgradeTest is TestSetup {
    function setUp() public {
        setUpTests();
    }

    //0xc30a309d02917ae5edf27e441ca029c54b069336919439d342c2f4b7889c623d
    function generateReport() internal returns (IEtherFiOracle.OracleReport memory) {
        //create report structure exactly the same to what submitted for that block
        IEtherFiOracle.OracleReport memory report = IEtherFiOracle.OracleReport({
            consensusVersion: 1,
            refSlotFrom: 9362464,
            refSlotTo: 9362943,
            refBlockFrom: 20156700,
            refBlockTo: 20157172,
            accruedRewards: 8729224130452426342,
            validatorsToApprove: new uint256[](100),
            liquidityPoolValidatorsToExit: new uint256[](0),
            exitedValidators: new uint256[](0),
            exitedValidatorsExitTimestamps: new uint32[](0),
            slashedValidators: new uint256[](0),
            withdrawalRequestsToInvalidate: new uint256[](0),
            lastFinalizedWithdrawalRequestId: 21696,
            eEthTargetAllocationWeight: 0,
            etherFanTargetAllocationWeight: 0,
            finalizedWithdrawalAmount: 1137171105616126724,
            numValidatorsToSpinUp: 100
        });
        uint256 startId = 52835;
        for (uint i = 0; i < 100; i++) {
            report.validatorsToApprove[i] = startId + i;
        }
    return report;
    }

    function test_sanity() public { 
        initializeRealisticForkWithBlock(MAINNET_FORK, 20157483);
        //upgrade the contact
        EtherFiAdmin v2Implementation = new EtherFiAdmin();
        address adminOwner = 0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761;
        vm.startPrank(adminOwner);
        etherFiAdminInstance.upgradeTo(address(v2Implementation));
        vm.stopPrank();

        vm.startPrank(0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F); 
        IEtherFiOracle.OracleReport memory report = generateReport();
        etherFiOracleInstance.submitReport(report);
        //skip forward so I can execute the tasks
        skip(3600);
        etherFiAdminInstance.executeTasks2(report);
        vm.stopPrank();
    }
}

//   [52835,52836,52837,52838,52839,52840,52841,52842,52843,52844,52845,52846,52847,52848,
//   52849,52850,52851,52852,52853,52854,52855,52856,52857,52858,52859,52860,52861,52862,
//   52863,52864,52865,52866,52867,52868,52869,52870,52871,52872,52873,52874,58175,58176,
//   58177,58178,58179,58180,58181,58182,58183,58184,58185,58186,58187,58188,58189,58190,
//   58191,58192,58193,58194,58195,58196,58197,58198,58199,58200,58201,58202,58203,58204,
//   58205,58206,58207,58208,58209,58210,58211,58212,58213,58214,58215,58216,58217,58218,
//   58219,58220,58221,58222,58223,58224,58225,58226,58227,58228,58229,58230,58231,58232,
//   58233,58234]