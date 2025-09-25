// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../../test/TestSetup.sol";
import "../../src/EtherFiTimelock.sol";
import "../../src/EtherFiNode.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/LiquidityPool.sol";
import "../../src/StakingManager.sol";
import "../../src/EtherFiOracle.sol";
import "../../src/EtherFiAdmin.sol";
import "../../src/EETH.sol";
import "../../src/WeETH.sol";
import "../../src/RoleRegistry.sol";
import "../../src/EtherFiRateLimiter.sol";
import "../../lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import "forge-std/Script.sol";
import "forge-std/console2.sol";

contract ElExitsTransactions is Script {
    EtherFiTimelock etherFiTimelock =
        EtherFiTimelock(payable(0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761));

    //--------------------------------------------------------------------------------------
    //--------------------- Previous Implementations ---------------------------------------
    //--------------------------------------------------------------------------------------
    address constant oldStakingManagerImpl =
        0x433d06fFc5EfE0e93daa22fcEF7eD60e65Bf70b4;
    address constant oldEtherFiNodeImpl =
        0xc5F2764383f93259Fba1D820b894B1DE0d47937e;
    address constant oldEtherFiNodesManagerImpl =
        0x158B21148E86470E2075926EbD5528Af2D510cAF;

    //--------------------------------------------------------------------------------------
    //---------------------------- New Deployments -----------------------------------------
    //--------------------------------------------------------------------------------------
    address constant etherFiRateLimiterImpl =
        0x1dd43C32f03f8A74b8160926D559d34358880A89;
    address constant etherFiRateLimiterProxy =
        0x6C7c54cfC2225fA985cD25F04d923B93c60a02F8;
    address constant stakingManagerImpl =
        0xa38d03ea42F8bc31892336E1F42523e94FB91a7A;
    address constant etherFiNodeImpl =
        0x6268728c52aAa4EC670F5fcdf152B50c4B463472;
    address constant etherFiNodesManagerImpl =
        0x0f366dF7af5003fC7C6524665ca58bDeAdDC3745;

    //--------------------------------------------------------------------------------------
    //------------------------- Existing Users/Proxies -------------------------------------
    //--------------------------------------------------------------------------------------
    address constant etherFiNodesManager =
        0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F;
    address constant stakingManager =
        0x25e821b7197B146F7713C3b89B6A4D83516B912d;
    address constant roleRegistry = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;

    address constant ETHERFI_OPERATING_ADMIN =
        0x2aCA71020De61bb532008049e1Bd41E451aE8AdC;
    address constant POD_PROVER = 0x7835fB36A8143a014A2c381363cD1A4DeE586d2A;
    address constant EL_TRIGGER_EXITER =
        0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;

    address constant ETHERFI_NODES_MANAGER_ADMIN_ROLE =
        0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a; // Operating Timelock

    address constant TIMELOCK_CONTROLLER = 0xcdd57D11476c22d265722F68390b036f3DA48c21;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ROLES  ----------------------------------------
    //--------------------------------------------------------------------------------------

    bytes32 ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE =
        EtherFiNodesManager(payable(etherFiNodesManagerImpl))
            .ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE();

    bytes32 ETHERFI_NODES_MANAGER_POD_PROVER_ROLE =
        EtherFiNodesManager(payable(etherFiNodesManagerImpl))
            .ETHERFI_NODES_MANAGER_POD_PROVER_ROLE();

    bytes32 STAKING_MANAGER_ADMIN_ROLE =
        StakingManager(payable(stakingManagerImpl))
            .STAKING_MANAGER_ADMIN_ROLE();

    bytes32 ETHERFI_RATE_LIMITER_ADMIN_ROLE =
        EtherFiRateLimiter(payable(etherFiRateLimiterImpl))
            .ETHERFI_RATE_LIMITER_ADMIN_ROLE();

    function run() public {
        console2.log("Running El Exits Transactions");
        vm.startBroadcast(TIMELOCK_CONTROLLER);

        executeElExitTransactions();
        // executeElExitRollback();

        vm.stopBroadcast();
    }

    function executeElExitTransactions() public {
        console2.log("Executing El Exit");
        address[] memory targets = new address[](7);
        bytes[] memory data = new bytes[](7);
        uint256[] memory values = new uint256[](7); // Default to 0

        //--------------------------------------------------------------------------------------
        //---------------------------------- Grant Roles ---------------------------------------
        //--------------------------------------------------------------------------------------

        // etherFiNode
        data[0] = _encodeRoleGrant(
            ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE,
            EL_TRIGGER_EXITER
        );
        data[1] = _encodeRoleGrant(
            ETHERFI_NODES_MANAGER_POD_PROVER_ROLE,
            POD_PROVER
        );
        data[2] = _encodeRoleGrant(
            STAKING_MANAGER_ADMIN_ROLE,
            ETHERFI_OPERATING_ADMIN
        );
        data[3] = _encodeRoleGrant(
            ETHERFI_RATE_LIMITER_ADMIN_ROLE,
            ETHERFI_OPERATING_ADMIN
        );

        for (uint256 i = 0; i < 4; i++) {
            targets[i] = address(roleRegistry);
        }

        //--------------------------------------------------------------------------------------
        //------------------------------- CONTRACT UPGRADES  -----------------------------------
        //--------------------------------------------------------------------------------------

        targets[4] = address(stakingManager);
        data[4] = abi.encodeWithSelector(
            UUPSUpgradeable.upgradeTo.selector,
            stakingManagerImpl
        );

        targets[5] = address(etherFiNodesManager);
        data[5] = abi.encodeWithSelector(
            UUPSUpgradeable.upgradeTo.selector,
            etherFiNodesManagerImpl
        );

        //--------------------------------------------------------------------------------------
        //------------------------------- ETHERFI NODE UPGRADE  -----------------------------------
        //--------------------------------------------------------------------------------------

        targets[6] = address(stakingManager);
        data[6] = abi.encodeWithSelector(
            StakingManager.upgradeEtherFiNode.selector,
            etherFiNodeImpl
        );

        //--------------------------------------------------------------------------------------
        //------------------------------- SCHEDULE TX  -----------------------------------
        //--------------------------------------------------------------------------------------
        bytes32 timelockSalt = keccak256(
            abi.encode(targets, data, block.number)
        );
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherFiTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt,
            259200 // minDelay
        );
        console2.log("Schedule Tx:");
        console2.logBytes(scheduleCalldata);

        // execute
        bytes memory executeCalldata = abi.encodeWithSelector(
            etherFiTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0), //predecessor
            timelockSalt
        );
        console2.log("Execute Tx:");
        console2.logBytes(executeCalldata);

        // uncomment to run against fork
        etherFiTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, 259200);

        // bytes32 timelockSalt = TODO set as salt from schedule;
        etherFiTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- EMERGENCY NODE ROLLBACK  -----------------------------------
    //--------------------------------------------------------------------------------------
    function executeElExitRollback() public view {
        console2.log("Executing El Exit Rollback");

        address[] memory targets = new address[](3);
        bytes[] memory data = new bytes[](3);
        uint256[] memory values = new uint256[](3); // Default to 0

        //--------------------------------------------------------------------------------------
        //------------------------------- CONTRACT UPGRADES  -----------------------------------
        //--------------------------------------------------------------------------------------

        targets[0] = address(stakingManager);
        data[0] = abi.encodeWithSelector(
            UUPSUpgradeable.upgradeTo.selector,
            oldStakingManagerImpl
        );

        targets[1] = address(etherFiNodesManager);
        data[1] = abi.encodeWithSelector(
            UUPSUpgradeable.upgradeTo.selector,
            oldEtherFiNodesManagerImpl
        );

        targets[2] = address(stakingManager);
        data[2] = abi.encodeWithSelector(
            StakingManager.upgradeEtherFiNode.selector,
            oldEtherFiNodeImpl
        );

        // schedule
        bytes32 timelockSalt = keccak256(
            abi.encode(targets, data, block.number)
        );
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherFiTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt,
            259200 // minDelay
        );
        console2.log("Rollback Schedule Tx:");
        console2.logBytes(scheduleCalldata);

        // execute
        bytes memory executeCalldata = abi.encodeWithSelector(
            etherFiTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0), //predecessor
            timelockSalt
        );
        console2.log("Rollback Execute Tx:");
        console2.logBytes(executeCalldata);

        // etherFiTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
        // etherFiTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, 259200);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- HELPER FUNCTIONS  -----------------------------------
    //--------------------------------------------------------------------------------------

    function _encodeRoleGrant(
        bytes32 role,
        address account
    ) internal pure returns (bytes memory) {
        return
            abi.encodeWithSelector(
                RoleRegistry.grantRole.selector,
                role,
                account
            );
    }
}
