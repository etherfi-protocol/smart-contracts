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
import "../lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import "forge-std/console2.sol";

contract V3PreludeTransactions is Script {

    uint256 constant BLOCK_BEFORE_UPGRADE = 22977373;

    EtherFiTimelock etherFiTimelock = EtherFiTimelock(payable(0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761));

    //--------------------------------------------------------------------------------------
    //---------------------------- New Deployments -----------------------------------------
    //--------------------------------------------------------------------------------------
    // TODO: update after prod deploy
    // currenttly is deployments on https://virtual.mainnet.eu.rpc.tenderly.co/0d158367-3563-4395-a24f-96c478e76f49

    address constant stakingManagerImpl = 0xb991a11310227b7B0D56a08FF1e17fbf55Aa85f4;
    address constant etherFiNodeImpl = 0xcAd2475effd731244dE2692c204b1eC08F8bD77C;
    address constant etherFiNodesManagerImpl = 0x0f607dF2a145a37A2622e7539fC89821ad28c593;
    address constant liquidityPoolImpl = 0x2777Fea1e8E1EfcAa27E63a828Da02b573b71867;
    address constant weETHImpl = 0xdf59da0C9509591FDF23869Ca8c0A561FB942ae3;
    address constant eETHImpl = 0xAb948dD6bb77728f75724651999067Cde6626825;
    address constant etherFiOracleImpl = 0xbEb3c9af86dB8D2425d69933F5eECB93Dcf486BC;
    address constant etherFiAdminImpl = 0x4849C3DfEfC4709365165E9098703eE08c299678;

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

    //bytes32 ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE = EtherFiNode(payable(etherFiNodeImpl)).ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE();
    //bytes32 ETHERFI_NODE_CALL_FORWARDER_ROLE = EtherFiNode(payable(etherFiNodeImpl)).ETHERFI_NODE_CALL_FORWARDER_ROLE();
    //bytes32 STAKING_MANAGER_NODE_CREATOR_ROLE = StakingManager(payable(stakingManagerImpl)).STAKING_MANAGER_NODE_CREATOR_ROLE();
    //bytes32 ETHERFI_NODES_MANAGER_ADMIN_ROLE = EtherFiNodesManager(payable(etherFiNodesManagerImpl)).ETHERFI_NODES_MANAGER_ADMIN_ROLE();
    //bytes32 ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE = EtherFiNodesManager(payable(etherFiNodesManagerImpl)).ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE();
    //bytes32 ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE = EtherFiNodesManager(payable(etherFiNodesManagerImpl)).ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE();
    //bytes32 LIQUIDITY_POOL_VALIDATOR_APPROVER_ROLE = LiquidityPool(payable(liquidityPoolImpl)).LIQUIDITY_POOL_VALIDATOR_APPROVER_ROLE();

    //--------------------------------------------------------------------------------------
    //-------------------------------- Previous Implementations  ---------------------------
    //--------------------------------------------------------------------------------------

    address constant etherFiNodeBeacon = 0x3c55986Cfee455E2533F4D29006634EcF9B7c03F;
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
//        initializeRealisticForkWithBlock(MAINNET_FORK, BLOCK_BEFORE_UPGRADE);
/*
        LiquidityPoolImplBefore = addressProviderInstance.getImplementationAddress("LiquidityPool");
        StakingManagerImplBefore = addressProviderInstance.getImplementationAddress("StakingManager");
        EtherFiNodesManagerImplBefore = addressProviderInstance.getImplementationAddress("EtherFiNodesManager");
        EtherFiOracleImplBefore = addressProviderInstance.getImplementationAddress("EtherFiOracle");
        EtherFiAdminImplBefore = addressProviderInstance.getImplementationAddress("EtherFiAdmin");
        EETHImplBefore = addressProviderInstance.getImplementationAddress("EETH");
        WeETHImplBefore = addressProviderInstance.getImplementationAddress("WeETH");
        EtherFiNodeImplBefore = UpgradeableBeacon(etherFiNodeBeacon).implementation();
        */
        address testnetOwner = 0xD0d7F8a5a86d8271ff87ff24145Cf40CEa9F7A39;
        bytes32 proposerRole = 0xb09aa5aeb3702cfd50b6b62bc4532604938f21248a27a1d5ca736082b6819cc1;
        bytes32 executorRole = 0xd8aa0f3194971a2a116679f7c2090f6939c8d4e01a2a8d7e41d55e5351469e63;

        bytes memory testData1 = abi.encodeWithSelector(IAccessControl(address(etherFiTimelock)).grantRole.selector, proposerRole, testnetOwner);
        bytes memory testData2 = abi.encodeWithSelector(IAccessControl(address(etherFiTimelock)).grantRole.selector, executorRole, testnetOwner);
        console2.logBytes(testData1);
        console2.logBytes(testData2);
        return;

        /*
        _executeUpgrade();
        
        console2.log("Upgrade complete - proceeding with rollback test");
        
        //_executeRollback();
        
        console2.log("Rollback complete - test finished successfully");
        */
    }

    function _executeUpgrade() internal {
        address[] memory targets = new address[](24);
        bytes[] memory data = new bytes[](24);
        uint256[] memory values = new uint256[](24); // Default to 0

        //--------------------------------------------------------------------------------------
        //---------------------------------- Grant Roles ---------------------------------------
        //--------------------------------------------------------------------------------------

        /*
        // etherFiNode
        data[0] = _encodeRoleGrant(ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE, address(etherFiNodesManager));
        data[1] = _encodeRoleGrant(ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE, address(stakingManager));
        data[2] = _encodeRoleGrant(ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE, proofSubmitter);
        data[3] = _encodeRoleGrant(ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE, operatingTimelock);
        data[4] = _encodeRoleGrant(ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE, etherFiAdminExecuter);
        data[5] = _encodeRoleGrant(ETHERFI_NODE_CALL_FORWARDER_ROLE, address(etherFiNodesManager));
        data[6] = _encodeRoleGrant(ETHERFI_NODE_CALL_FORWARDER_ROLE, proofSubmitter);
        data[7] = _encodeRoleGrant(ETHERFI_NODE_CALL_FORWARDER_ROLE, operatingTimelock);

        // staking manager
        data[8] = _encodeRoleGrant(STAKING_MANAGER_NODE_CREATOR_ROLE, operatingTimelock);
        data[9] = _encodeRoleGrant(STAKING_MANAGER_NODE_CREATOR_ROLE, etherFiAdminExecuter);

        // etherFiNodesManager
        data[10] = _encodeRoleGrant(ETHERFI_NODES_MANAGER_ADMIN_ROLE, operatingTimelock);
        data[11] = _encodeRoleGrant(ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE, operatingTimelock);
        data[12] = _encodeRoleGrant(ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE, proofSubmitter);
        data[13] = _encodeRoleGrant(ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE, operatingTimelock);
        data[14] = _encodeRoleGrant(ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE, proofSubmitter);

        // liquidityPool
        data[15] = _encodeRoleGrant(LIQUIDITY_POOL_VALIDATOR_APPROVER_ROLE, etherFiAdmin);

        // all role grants have same target
        for (uint256 i = 0; i <= 15; i++) {
            targets[i] = address(roleRegistry);
        }
        */

        //--------------------------------------------------------------------------------------
        //------------------------------- CONTRACT UPGRADES  -----------------------------------
        //--------------------------------------------------------------------------------------

        targets[16] = address(eETH);
        data[16] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, eETHImpl);

        targets[17] = address(etherFiAdmin);
        data[17] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, etherFiAdminImpl);

        targets[18] = address(stakingManager);
        data[18] = abi.encodeWithSelector(StakingManager.upgradeEtherFiNode.selector, etherFiNodeImpl);

        targets[19] = address(etherFiNodesManager);
        data[19] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, etherFiNodesManagerImpl);

        targets[20] = address(etherFiOracle);
        data[20] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, etherFiOracleImpl);

        targets[21] = address(liquidityPool);
        data[21] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, liquidityPoolImpl);

        targets[22] = address(stakingManager);
        data[22] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, stakingManagerImpl);

        targets[23] = address(weETH);
        data[23] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, weETHImpl);

        bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));
        etherFiTimelock.scheduleBatch(targets, values, data, bytes32(0)/*=predecessor*/, timelockSalt, 259200/*=minDelay*/);

        //_batch_execute_timelock(targets, data, values, true, true, true, true);
    }


    function _executeRollback() internal {
        
        address[] memory targets = new address[](8);
        bytes[] memory data = new bytes[](8);
        uint256[] memory values = new uint256[](8); // Default to 0

        targets[0] = address(etherFiAdmin);
        data[0] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, EtherFiAdminImplBefore);

        targets[1] = address(eETH);
        data[1] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector,EETHImplBefore);

        targets[2] = address(stakingManager);
        data[2] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector,StakingManagerImplBefore);

        targets[3] = address(etherFiNodesManager);
        data[3] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector,EtherFiNodesManagerImplBefore);

        targets[4] = address(etherFiOracle);
        data[4] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector,EtherFiOracleImplBefore);

        targets[5] = address(liquidityPool);
        data[5] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector,LiquidityPoolImplBefore);

        targets[6] = address(stakingManager);
        data[6] = abi.encodeWithSelector(StakingManager.upgradeEtherFiNode.selector, EtherFiNodeImplBefore);

        targets[7] = address(weETH);
        data[7] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector,WeETHImplBefore);
    
        //_batch_execute_timelock(targets, data, values, true, true, true, true);
    }

    function _encodeRoleGrant(bytes32 role, address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(RoleRegistry.grantRole.selector, role, account);
    }
}
