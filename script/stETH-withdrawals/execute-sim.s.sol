// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {Utils} from "../utils/utils.sol";
import {TimelockSimulator} from "../helpers/TimelockSimulator.s.sol";

contract ExecuteSim is TimelockSimulator {
    function run() external {
        // 1.a Upgrade EFRM to Temp
        _executeBatch_timelock(
            UPGRADE_TIMELOCK,
            address(0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0),
            hex"3659cfe6000000000000000000000000590015fdf9334594b0ae14f29b0ded9f1f8504bc",
            bytes32(0),
            hex"e74ed6d6f7a02c6b3942516b4839e665a41e83dd9db3cb94bcca886f7f01ba5b"
        );
        
        // 1.b Clear Out Slot For Upgrade
        _executeBatch_timelock(
            UPGRADE_TIMELOCK,
            address(0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0),
            hex"57905a65",
            hex"6ff351fe4bf00936cb8a277735e14cdea8a0f4d7d64ebf51d1a972c34e9b9b14",
            hex"a9bceb3281bf94c5e8c3416688bc519091eb028e223c014d29556c934ab46d72"
        );

        // 2. Upgrade to new implementations
        address[] memory upgradeTargets = new address[](3);
        upgradeTargets[0] = address(0x308861A430be4cce5502d0A12724771Fc6DaF216); // liquidityPool
        upgradeTargets[1] = address(0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0); // etherFiRedemptionManager
        upgradeTargets[2] = address(0x1B7a4C3797236A1C37f8741c0Be35c2c72736fFf); // etherFiRestaker
        
        bytes[] memory upgradeData = new bytes[](3);
        upgradeData[0] = hex"3659cfe6000000000000000000000000a5c1ddd9185901e3c05e0660126627e039d0a626";
        upgradeData[1] = hex"3659cfe6000000000000000000000000e3f384dc7002547dd240ac1ad69a430cce1e292d";
        upgradeData[2] = hex"3659cfe600000000000000000000000071bef55739f0b148e2c3e645fde947f380c48615";
        
        _executeBatch_timelock(
            UPGRADE_TIMELOCK,
            upgradeTargets,
            upgradeData,
            bytes32(0),
            hex"30742daa20a1d517f1c1580c5702c72652a5cab11c8d6361112f1fba2d421aab"
        );

        // 3. Rollback upgrade to old implementations
        address[] memory rollbackTargets = new address[](3);
        rollbackTargets[0] = address(0x308861A430be4cce5502d0A12724771Fc6DaF216); // liquidityPool
        rollbackTargets[1] = address(0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0); // etherFiRedemptionManager
        rollbackTargets[2] = address(0x1B7a4C3797236A1C37f8741c0Be35c2c72736fFf); // etherFiRestaker
        
        bytes[] memory rollbackData = new bytes[](3);
        rollbackData[0] = hex"3659cfe6000000000000000000000000025911766aef6ff0c294fd831a2b5c17dc299b3f";
        rollbackData[1] = hex"3659cfe6000000000000000000000000e6f40295a7500509fad08e924c91b0f050a7b84b";
        rollbackData[2] = hex"3659cfe60000000000000000000000000052f731a6bea541843385ffba408f52b74cb624";
        
        _executeBatch_timelock(
            UPGRADE_TIMELOCK,
            rollbackTargets,
            rollbackData,
            bytes32(0),
            hex"03f23e4f38e9bec1b00961f8247e9cd63cae2d84269535de66f731d14812c84b"
        );
    }
}