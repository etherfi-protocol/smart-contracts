// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import "../src/EETH.sol";
import "../src/EtherFiAdmin.sol";
import "../src/EtherFiNode.sol";
import "../src/EtherFiNodesManager.sol";
import "../src/EtherFiOracle.sol";
import "../src/EtherFiTimelock.sol";
import "../src/LiquidityPool.sol";

import "../src/RoleRegistry.sol";
import "../src/StakingManager.sol";
import "../src/WeETH.sol";
import "../test/TestSetup.sol";
import "forge-std/Script.sol";

import "forge-std/console2.sol";

contract V3PreludeTransactions is Script {
    /*

            EtherFiTimelock etherFiTimelock = EtherFiTimelock(payable(0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761));

            //--------------------------------------------------------------------------------------
            //--------------------- Previous Implementations ---------------------------------------
            //--------------------------------------------------------------------------------------
            address constant oldLiquidityPoolImpl = 0xA6099d83A67a2c653feB5e4e48ec24C5aeE1C515;
            address constant oldStakingManagerImpl = 0xB27d4e7b8fF1EF21751b50F3821D99719Ad5868f;
            address constant oldEtherFiNodeImpl = 0xc5F2764383f93259Fba1D820b894B1DE0d47937e;
            address constant oldEtherFiNodesManagerImpl = 0xE9EE6923D41Cf5F964F11065436BD90D4577B5e4;
            address constant oldEtherFiOracleImpl = 0x99BE559FAdf311D2CEdeA6265F4d36dfa4377B70;
            address constant oldEtherFiAdminImpl = 0x683583979C8be7Bcfa41E788Ab38857dfF792f49;
            address constant oldEETHImpl = 0x46c51d2E6d5FEF0400d26320bC96995176c369DD;
            address constant oldWeETHImpl = 0x353E98F34b6E5a8D9d1876Bf6dF01284d05837cB;

            //--------------------------------------------------------------------------------------
            //---------------------------- New Deployments -----------------------------------------
            //--------------------------------------------------------------------------------------
            address constant liquidityPoolImpl = 0x025911766aEF6fF0C294FD831a2b5c17dC299B3f;
            address constant stakingManagerImpl = 0x433d06fFc5EfE0e93daa22fcEF7eD60e65Bf70b4;
            address constant etherFiNodeImpl = 0x5Dae50e686f7CB980E4d0c5E4492c56bC73eD9a2;
            address constant etherFiNodesManagerImpl = 0x158B21148E86470E2075926EbD5528Af2D510cAF;
            address constant etherFiOracleImpl = 0x5eefE6f65a280A6f1Eb1FdFf36Ab9e2af6f38462;
            address constant etherFiAdminImpl = 0xd50f28485A75A1FdE432BA7d012d0E2543D2f20d;
            address constant weETHImpl = 0x2d10683E941275D502173053927AD6066e6aFd6B;
            address constant eETHImpl = 0xCB3D917A965A70214f430a135154Cd5ADdA2ad84;

            //--------------------------------------------------------------------------------------
            //------------------------- Existing Users/Proxies -------------------------------------
            //--------------------------------------------------------------------------------------
            address constant etherFiNodesManager = 0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F;
            address constant stakingManager = 0x25e821b7197B146F7713C3b89B6A4D83516B912d;
            address constant eETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
            address constant weETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
            address constant etherFiOracle = 0x57AaF0004C716388B21795431CD7D5f9D3Bb6a41;
            address constant liquidityPool = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
            address constant proofSubmitter = 0x7835fB36A8143a014A2c381363cD1A4DeE586d2A;
            address constant operatingTimelock = 0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a;
            address constant etherFiAdminExecuter = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;
            address constant etherFiAdmin = 0x0EF8fa4760Db8f5Cd4d993f3e3416f30f942D705;
            address constant roleRegistry = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;

            //--------------------------------------------------------------------------------------
            //-------------------------------------  ROLES  ----------------------------------------
            //--------------------------------------------------------------------------------------
            bytes32 ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE = EtherFiNode(payable(etherFiNodeImpl)).ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE();
            bytes32 ETHERFI_NODE_CALL_FORWARDER_ROLE = EtherFiNode(payable(etherFiNodeImpl)).ETHERFI_NODE_CALL_FORWARDER_ROLE();
            bytes32 STAKING_MANAGER_NODE_CREATOR_ROLE = StakingManager(payable(stakingManagerImpl)).STAKING_MANAGER_NODE_CREATOR_ROLE();
            bytes32 ETHERFI_NODES_MANAGER_ADMIN_ROLE = EtherFiNodesManager(payable(etherFiNodesManagerImpl)).ETHERFI_NODES_MANAGER_ADMIN_ROLE();
            bytes32 ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE = EtherFiNodesManager(payable(etherFiNodesManagerImpl)).ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE();
            bytes32 ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE = EtherFiNodesManager(payable(etherFiNodesManagerImpl)).ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE();
            bytes32 LIQUIDITY_POOL_VALIDATOR_APPROVER_ROLE = LiquidityPool(payable(liquidityPoolImpl)).LIQUIDITY_POOL_VALIDATOR_APPROVER_ROLE();

            function run() public {

                vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

                executeUpgrade();
                executeRollback();

                vm.stopBroadcast();
            }

            function executeUpgrade() internal {
                address[] memory targets = new address[](23);
                bytes[] memory data = new bytes[](23);
                uint256[] memory values = new uint256[](23); // Default to 0

                //--------------------------------------------------------------------------------------
                //---------------------------------- Grant Roles ---------------------------------------
                //--------------------------------------------------------------------------------------

                // etherFiNode
                data[0] = _encodeRoleGrant(ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE, address(etherFiNodesManager));
                data[1] = _encodeRoleGrant(ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE, address(stakingManager));
                data[2] = _encodeRoleGrant(ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE, operatingTimelock);
                data[3] = _encodeRoleGrant(ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE, etherFiAdminExecuter);
                data[4] = _encodeRoleGrant(ETHERFI_NODE_CALL_FORWARDER_ROLE, address(etherFiNodesManager));
                data[5] = _encodeRoleGrant(ETHERFI_NODE_CALL_FORWARDER_ROLE, proofSubmitter);
                data[6] = _encodeRoleGrant(ETHERFI_NODE_CALL_FORWARDER_ROLE, operatingTimelock);

                // staking manager
                data[7] = _encodeRoleGrant(STAKING_MANAGER_NODE_CREATOR_ROLE, operatingTimelock);
                data[8] = _encodeRoleGrant(STAKING_MANAGER_NODE_CREATOR_ROLE, etherFiAdminExecuter);

                // etherFiNodesManager
                data[9] = _encodeRoleGrant(ETHERFI_NODES_MANAGER_ADMIN_ROLE, operatingTimelock);
                data[10] = _encodeRoleGrant(ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE, operatingTimelock);
                data[11] = _encodeRoleGrant(ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE, proofSubmitter);
                data[12] = _encodeRoleGrant(ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE, operatingTimelock);
                data[13] = _encodeRoleGrant(ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE, etherFiAdminExecuter);

                // liquidityPool
                data[14] = _encodeRoleGrant(LIQUIDITY_POOL_VALIDATOR_APPROVER_ROLE, etherFiAdmin);

                // all role grants have same target
                for (uint256 i = 0; i <= 14; i++) {
                    targets[i] = address(roleRegistry);
                }

                //--------------------------------------------------------------------------------------
                //------------------------------- CONTRACT UPGRADES  -----------------------------------
                //--------------------------------------------------------------------------------------

                targets[15] = address(eETH);
                data[15] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, eETHImpl);

                targets[16] = address(etherFiAdmin);
                data[16] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, etherFiAdminImpl);

                targets[17] = address(stakingManager);
                data[17] = abi.encodeWithSelector(StakingManager.upgradeEtherFiNode.selector, etherFiNodeImpl);

                targets[18] = address(etherFiNodesManager);
                data[18] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, etherFiNodesManagerImpl);

                targets[19] = address(etherFiOracle);
                data[19] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, etherFiOracleImpl);

                targets[20] = address(liquidityPool);
                data[20] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, liquidityPoolImpl);

                targets[21] = address(stakingManager);
                data[21] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, stakingManagerImpl);

                targets[22] = address(weETH);
                data[22] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, weETHImpl);

                // schedule
                bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));
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
                //etherFiTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, 259200);

                //bytes32 timelockSalt = TODO set as salt from schedule;
                //etherFiTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
            }


            function executeRollback() internal {

                address[] memory targets = new address[](8);
                bytes[] memory data = new bytes[](8);
                uint256[] memory values = new uint256[](8); // Default to 0

                targets[0] = address(etherFiAdmin);
                data[0] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, oldEtherFiAdminImpl);

                targets[1] = address(eETH);
                data[1] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, oldEETHImpl);

                targets[2] = address(stakingManager);
                data[2] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, oldStakingManagerImpl);

                targets[3] = address(etherFiNodesManager);
                data[3] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, oldEtherFiNodesManagerImpl);

                targets[4] = address(etherFiOracle);
                data[4] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, oldEtherFiOracleImpl);

                targets[5] = address(liquidityPool);
                data[5] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, oldLiquidityPoolImpl);

                targets[6] = address(stakingManager);
                data[6] = abi.encodeWithSelector(StakingManager.upgradeEtherFiNode.selector, oldEtherFiNodeImpl);

                targets[7] = address(weETH);
                data[7] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, oldWeETHImpl);

                // schedule
                bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));
                //bytes32 timelockSalt = 0xdf0ec353ec9a0cec6fd24a849783aea0fd395b5b0f4efb968986485ba6d4f6ff;
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

                // uncomment to run against fork
                //etherFiTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, 259200);

                //etherFiTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);

            }

            function _encodeRoleGrant(bytes32 role, address account) internal pure returns (bytes memory) {
                return abi.encodeWithSelector(RoleRegistry.grantRole.selector, role, account);
            }
            */

    }
