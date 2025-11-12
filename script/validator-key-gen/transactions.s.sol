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
import "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "forge-std/Script.sol";
import "forge-std/console2.sol";

contract ValidatorKeyGenTransactions is Script {
    EtherFiTimelock etherFiTimelock = EtherFiTimelock(payable(0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761));

    address constant STAKING_MANAGER_PROXY = 0x25e821b7197B146F7713C3b89B6A4D83516B912d;
    address constant LIQUIDITY_POOL_PROXY = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address constant ETHERFI_NODES_MANAGER_PROXY = 0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F;
    address constant ROLE_REGISTRY = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;

    address constant nodesManagerImpl = 0x0f366dF7af5003fC7C6524665ca58bDeAdDC3745;
    
    //--------------------------------------------------------------------------------------
    //---------------------------- New Deployments -----------------------------------------
    //--------------------------------------------------------------------------------------
    address constant stakingManagerImpl = 0xF73996bceDE56AD090024F2Fd4ca545A3D06c8E3;
    address constant liquidityPoolImpl = 0x4C6767A0afDf06c55DAcb03cB26aaB34Eed281fc;

    bytes32 LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE = LiquidityPool(payable(liquidityPoolImpl)).LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE();
    bytes32 ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE = EtherFiNodesManager(payable(nodesManagerImpl)).ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE();
    bytes32 STAKING_MANAGER_VALIDATOR_INVALIDATOR_ROLE = StakingManager(payable(stakingManagerImpl)).STAKING_MANAGER_VALIDATOR_INVALIDATOR_ROLE();

    //--------------------------------------------------------------------------------------
    address constant ETHERFI_OPERATING_ADMIN = 0x2aCA71020De61bb532008049e1Bd41E451aE8AdC;
    address constant UPGRADE_ADMIN = 0xcdd57D11476c22d265722F68390b036f3DA48c21;
    uint256 constant TIMELOCK_MIN_DELAY = 259200; // 72 hours

    LiquidityPool constant liquidityPool = LiquidityPool(payable(LIQUIDITY_POOL_PROXY));
    StakingManager constant stakingManager = StakingManager(STAKING_MANAGER_PROXY);

    function run() public {
        console2.log("================================================");
        console2.log("Running Validator Key Gen Transactions");
        console2.log("================================================");
        console2.log("");

        // vm.startBroadcast();
        executeUpgrade();
        // vm.stopBroadcast();
    }

    function executeUpgrade() public {
        console2.log("Executing Upgrade");
        console2.log("================================================");

        address[] memory targets = new address[](5);
        bytes[] memory data = new bytes[](5);
        uint256[] memory values = new uint256[](5); // Default to 0
        
        //--------------------------------------------------------------------------------------
        //------------------------------- CONTRACT UPGRADES  -----------------------------------
        //--------------------------------------------------------------------------------------
        targets[0] = STAKING_MANAGER_PROXY;
        data[0] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, stakingManagerImpl);

        targets[1] = LIQUIDITY_POOL_PROXY;
        data[1] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, liquidityPoolImpl);

        //--------------------------------------------------------------------------------------
        //---------------------------------- Grant Roles ---------------------------------------
        //--------------------------------------------------------------------------------------

        targets[2] = ROLE_REGISTRY;
        data[2] = _encodeRoleGrant(
            LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE,
            ETHERFI_OPERATING_ADMIN
        );
        targets[3] = ROLE_REGISTRY;
        data[3] = _encodeRoleGrant(
            ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE,
            address(stakingManager)
        );
        targets[4] = ROLE_REGISTRY;
        data[4] = _encodeRoleGrant(
            STAKING_MANAGER_VALIDATOR_INVALIDATOR_ROLE,
            ETHERFI_OPERATING_ADMIN
        );

        bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));

        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherFiTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt,
            TIMELOCK_MIN_DELAY // minDelay
        );

        console2.log("Schedule Tx:");
        console2.logBytes(scheduleCalldata);
        console2.log("================================================");
        console2.log("");

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
        console2.log("================================================");
        console2.log("");

        // uncomment to run against fork
        console2.log("=== SCHEDULING BATCH ===");
        vm.startPrank(UPGRADE_ADMIN);
        etherFiTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, TIMELOCK_MIN_DELAY);

        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1); // +1 to ensure it's past the delay
        etherFiTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
        vm.stopPrank();

        console2.log("Upgrade executed successfully");
        console2.log("================================================");
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