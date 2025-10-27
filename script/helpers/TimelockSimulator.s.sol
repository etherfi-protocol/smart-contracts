// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
// import "forge-std/Script.sol";
import {Utils} from "../utils/utils.sol";

import {EtherFiTimelock} from "../../src/EtherFiTimelock.sol";
import {Deployed} from "../deploys/Deployed.s.sol";

contract TimelockSimulator is Script, Utils, Deployed {

    function _execute_timelock(address timelock, address target, bytes memory data, bytes32 predecessor, bytes32 salt) internal {
        vm.startPrank(timelockToAdmin[timelock]);
        EtherFiTimelock timelockInstance = EtherFiTimelock(payable(timelock));
        timelockInstance.execute(target, 0, data, predecessor, salt);
        vm.stopPrank();
    }

    function _executeBatch_timelock(address timelock, address[] memory targets, bytes[] memory data, bytes32 predecessor, bytes32 salt) internal {
        uint256[] memory values = new uint256[](targets.length);
        for (uint256 i = 0; i < targets.length; i++) {
            values[i] = 0;
        }

        vm.startPrank(timelockToAdmin[timelock]);
        EtherFiTimelock timelockInstance = EtherFiTimelock(payable(timelock));
        timelockInstance.executeBatch(targets, values, data, predecessor, salt);
        vm.stopPrank();
    }

    function _executeBatch_timelock(address timelock, address target, bytes memory data, bytes32 predecessor, bytes32 salt) internal {
        address[] memory targetsArray = new address[](1);
        targetsArray[0] = target;
        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = data;
        uint256[] memory valuesArray = new uint256[](1);
        valuesArray[0] = 0;
        
        _executeBatch_timelock(timelock, targetsArray, dataArray, predecessor, salt);
    }
}