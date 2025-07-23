// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../test/TestSetup.sol";
import "../src/EtherFiTimelock.sol";
import "../src/EtherFiNode.sol";
import "../src/EtherFiNodesManager.sol";
import "../src/LiquidityPool.sol";
import "../src/StakingManager.sol";
import "../src/EtherFiOracle.sol";
import "../src/EtherFiAdmin.sol";
import "../src/EETH.sol";
import "../src/WeETH.sol";
import "../src/RoleRegistry.sol";
import "forge-std/console2.sol";

contract V3PreludeTransactions is Script, TestSetup {
    
    uint256 constant BLOCK_BEFORE_UPGRADE = 22977373;
    address constant STAKER1 = 0x2aCA71020De61bb532008049e1Bd41E451aE8AdC;
    address constant ETHERFI_NODE_BEACON = 0x3c55986Cfee455E2533F4D29006634EcF9B7c03F;

    address LiquidityPoolImplBefore;
    address StakingManagerImplBefore;
    address EtherFiNodesManagerImplBefore;
    address EtherFiOracleImplBefore;
    address EtherFiAdminImplBefore;
    address EETHImplBefore;
    address WeETHImplBefore;
    address EtherFiNodeImplBefore;

    function run() public {
        // Get the state of the contracts before the upgrade
        initializeRealisticForkWithBlock(MAINNET_FORK, BLOCK_BEFORE_UPGRADE);
        LiquidityPoolImplBefore = addressProviderInstance.getImplementationAddress("LiquidityPool");
        StakingManagerImplBefore = addressProviderInstance.getImplementationAddress("StakingManager");
        EtherFiNodesManagerImplBefore = addressProviderInstance.getImplementationAddress("EtherFiNodesManager");
        EtherFiOracleImplBefore = addressProviderInstance.getImplementationAddress("EtherFiOracle");
        EtherFiAdminImplBefore = addressProviderInstance.getImplementationAddress("EtherFiAdmin");
        EETHImplBefore = addressProviderInstance.getImplementationAddress("EETH");
        WeETHImplBefore = addressProviderInstance.getImplementationAddress("WeETH");
        EtherFiNodeImplBefore = UpgradeableBeacon(ETHERFI_NODE_BEACON).implementation();

        //create transactions to upgrade
        initializeRealisticFork(MAINNET_FORK);
        console2.log("Role Registry Address:", address(roleRegistryInstance));

        _executeUpgrade();
        
        console2.log("Upgrade complete - proceeding with rollback test");
        
        _executeRollback();
        
        console2.log("Rollback complete - test finished successfully");
    }

    function _executeUpgrade() internal {
        address[] memory targets = new address[](17);
        bytes[] memory data = new bytes[](17);
        uint256[] memory values = new uint256[](17); // Default to 0

        _configureUpgradeTransactions(targets, data);
        
        _batch_execute_timelock(targets, data, values, true, true, true, true);
    }

    /////////////////////// FIX: Update with Deployed Contracts not newly constructed contracts ///////////////////////
    /////////////////////// FIX: Update Role Granting to use the correct roles ///////////////////////
    function _configureUpgradeTransactions(
        address[] memory targets, 
        bytes[] memory data
    ) internal {

        address stakingManagerImpl = address(new StakingManager(
            address(liquidityPoolInstance),
            address(managerInstance),
            address(depositContractEth2),
            address(auctionInstance),
            ETHERFI_NODE_BEACON,
            address(roleRegistryInstance)
        ));

        address etherFiNodeImpl = address(new EtherFiNode(
            address(liquidityPoolInstance),
            address(managerInstance),
            address(eigenLayerEigenPodManager),
            address(eigenLayerDelegationManager),
            address(roleRegistryInstance)
        ));

        address etherFiNodesManagerImpl = address(new EtherFiNodesManager(
            address(stakingManagerInstance),
            address(roleRegistryInstance)
        ));

        address liquidityPoolImpl = address(new LiquidityPool());
        address weETHImpl = address(new WeETH(address(roleRegistryInstance)));
        address eETHImpl = address(new EETH(address(roleRegistryInstance)));
        address etherFiOracleImpl = address(new EtherFiOracle());
        address etherFiAdminImpl = address(new EtherFiAdmin());

        // Configure role registry targets (0-8)
        for (uint256 i = 0; i < 9; i++) {
            targets[i] = address(roleRegistryInstance);
        }

        data[0] = _encodeRoleGrant(
            EtherFiNode(payable(etherFiNodeImpl)).ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE(),
            address(managerInstance)
        );
        data[1] = _encodeRoleGrant(
            EtherFiNode(payable(etherFiNodeImpl)).ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE(),
            address(stakingManagerInstance)
        );
        data[2] = _encodeRoleGrant(
            EtherFiNode(payable(etherFiNodeImpl)).ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE(),
            STAKER1
        );
        data[3] = _encodeRoleGrant(
            EtherFiNodesManager(etherFiNodesManagerImpl).ETHERFI_NODES_MANAGER_ADMIN_ROLE(),
            STAKER1
        );
        data[4] = _encodeRoleGrant(
            EtherFiNodesManager(etherFiNodesManagerImpl).ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE(),
            STAKER1
        );
        data[5] = _encodeRoleGrant(
            EtherFiNodesManager(etherFiNodesManagerImpl).ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE(),
            STAKER1
        );
        data[6] = _encodeRoleGrant(
            StakingManager(stakingManagerImpl).STAKING_MANAGER_NODE_CREATOR_ROLE(),
            STAKER1
        );
        data[7] = _encodeRoleGrant(
            LiquidityPool(payable(liquidityPoolImpl)).LIQUIDITY_POOL_ADMIN_ROLE(),
            STAKER1
        );
        data[8] = _encodeRoleGrant(
            LiquidityPool(payable(liquidityPoolImpl)).LIQUIDITY_POOL_VALIDATOR_APPROVER_ROLE(),
            STAKER1
        );

        targets[9] = address(eETHInstance);
        data[9] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, eETHImpl);

        targets[10] = address(etherFiAdminInstance);
        data[10] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, etherFiAdminImpl);

        targets[11] = address(stakingManagerInstance);
        data[11] = abi.encodeWithSelector(StakingManager.upgradeEtherFiNode.selector, etherFiNodeImpl);

        targets[12] = address(managerInstance);
        data[12] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, etherFiNodesManagerImpl);

        targets[13] = address(etherFiOracleInstance);
        data[13] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, etherFiOracleImpl);

        targets[14] = address(liquidityPoolInstance);
        data[14] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, liquidityPoolImpl);

        targets[15] = address(stakingManagerInstance);
        data[15] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, stakingManagerImpl);

        targets[16] = address(weEthInstance);
        data[16] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, weETHImpl);
    }

    function _executeRollback() internal {
        
        address[] memory targets = new address[](8);
        bytes[] memory data = new bytes[](8);
        uint256[] memory values = new uint256[](8); // Default to 0

        targets[0] = address(etherFiAdminInstance);
        data[0] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, EtherFiAdminImplBefore);

        targets[1] = address(eETHInstance);
        data[1] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector,EETHImplBefore);

        targets[2] = address(stakingManagerInstance);
        data[2] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector,StakingManagerImplBefore);

        targets[3] = address(managerInstance);
        data[3] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector,EtherFiNodesManagerImplBefore);

        targets[4] = address(etherFiOracleInstance);
        data[4] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector,EtherFiOracleImplBefore);

        targets[5] = address(liquidityPoolInstance);
        data[5] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector,LiquidityPoolImplBefore);

        targets[6] = address(stakingManagerInstance);
        data[6] = abi.encodeWithSelector(StakingManager.upgradeEtherFiNode.selector, EtherFiNodeImplBefore);

        targets[7] = address(weEthInstance);
        data[7] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector,WeETHImplBefore);
    
        _batch_execute_timelock(targets, data, values, true, true, true, true);
    }

    function _encodeRoleGrant(bytes32 role, address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(RoleRegistry.grantRole.selector, role, account);
    }
}
