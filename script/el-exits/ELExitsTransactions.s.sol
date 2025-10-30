// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../../lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import "../../src/EETH.sol";
import "../../src/EtherFiAdmin.sol";
import "../../src/EtherFiNode.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/EtherFiOracle.sol";

import "../../src/EtherFiRateLimiter.sol";
import "../../src/EtherFiTimelock.sol";
import "../../src/LiquidityPool.sol";
import "../../src/RoleRegistry.sol";
import "../../src/StakingManager.sol";
import "../../src/WeETH.sol";
import "../../test/TestSetup.sol";

import "forge-std/Script.sol";
import "forge-std/console2.sol";

contract ElExitsTransactions is Script {
    EtherFiTimelock etherFiTimelock = EtherFiTimelock(payable(0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761));
    EtherFiTimelock etherFiOperatingTimelock = EtherFiTimelock(payable(ETHERFI_NODES_MANAGER_ADMIN_ROLE));

    //--------------------------------------------------------------------------------------
    //--------------------- Previous Implementations ---------------------------------------
    //--------------------------------------------------------------------------------------
    address constant oldStakingManagerImpl = 0x433d06fFc5EfE0e93daa22fcEF7eD60e65Bf70b4;
    address constant oldEtherFiNodeImpl = 0x5Dae50e686f7CB980E4d0c5E4492c56bC73eD9a2;
    address constant oldEtherFiNodesManagerImpl = 0x158B21148E86470E2075926EbD5528Af2D510cAF;

    //--------------------------------------------------------------------------------------
    //---------------------------- New Deployments -----------------------------------------
    //--------------------------------------------------------------------------------------
    address constant etherFiRateLimiterImpl = 0x1dd43C32f03f8A74b8160926D559d34358880A89;
    address constant etherFiRateLimiterProxy = 0x6C7c54cfC2225fA985cD25F04d923B93c60a02F8;
    address constant stakingManagerImpl = 0xa38d03ea42F8bc31892336E1F42523e94FB91a7A;
    address constant etherFiNodeImpl = 0x6268728c52aAa4EC670F5fcdf152B50c4B463472;
    address constant etherFiNodesManagerImpl = 0x0f366dF7af5003fC7C6524665ca58bDeAdDC3745;

    //--------------------------------------------------------------------------------------
    //------------------------- Existing Users/Proxies -------------------------------------
    //--------------------------------------------------------------------------------------
    address constant etherFiNodesManager = 0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F;
    address constant stakingManager = 0x25e821b7197B146F7713C3b89B6A4D83516B912d;
    address constant roleRegistry = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;

    address constant ETHERFI_OPERATING_ADMIN = 0x2aCA71020De61bb532008049e1Bd41E451aE8AdC;
    address constant POD_PROVER = 0x7835fB36A8143a014A2c381363cD1A4DeE586d2A;
    address constant EL_TRIGGER_EXITER = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;

    address constant ETHERFI_NODES_MANAGER_ADMIN_ROLE = 0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a; // Operating Timelock

    address constant TIMELOCK_CONTROLLER = 0xcdd57D11476c22d265722F68390b036f3DA48c21;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ROLES  ----------------------------------------
    //--------------------------------------------------------------------------------------

    bytes32 ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE = EtherFiNodesManager(payable(etherFiNodesManagerImpl)).ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE();

    bytes32 ETHERFI_NODES_MANAGER_POD_PROVER_ROLE = EtherFiNodesManager(payable(etherFiNodesManagerImpl)).ETHERFI_NODES_MANAGER_POD_PROVER_ROLE();

    bytes32 STAKING_MANAGER_ADMIN_ROLE = StakingManager(payable(stakingManagerImpl)).STAKING_MANAGER_ADMIN_ROLE();

    bytes32 ETHERFI_RATE_LIMITER_ADMIN_ROLE = EtherFiRateLimiter(payable(etherFiRateLimiterImpl)).ETHERFI_RATE_LIMITER_ADMIN_ROLE();

    //--------------------------------------------------------------------------------------
    //------------------------------- SELECTORS ---------------------------------------
    //--------------------------------------------------------------------------------------

    // cast sig "updateAllowedForwardedExternalCalls(bytes4,address,bool)"
    bytes4 UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR = 0xc7f61eec;
    // cast sig "updateAllowedForwardedEigenpodCalls(bytes4,bool)"
    bytes4 UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR = 0x4cba6c74;

    uint256 MIN_DELAY_OPERATING_TIMELOCK = 28_800; // 8 hours
    uint256 MIN_DELAY_TIMELOCK = 259_200; // 72 hours

    // External calls selectors
    bytes4 UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_ONE = 0x9a15bf92;
    bytes4 UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_TWO = 0xa9059cbb;
    bytes4 UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_THREE = 0x3ccc861d;
    bytes4 UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_FOUR = 0xeea9064b;
    bytes4 UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_FIVE = 0x7f548071;
    bytes4 UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_SIX = 0xda8be864;
    bytes4 UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_SEVEN = 0x0dd8dd02;
    bytes4 UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_EIGHT = 0x33404396;
    bytes4 UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_NINE = 0x9435bb43;

    // Eigenpod calls selectors
    bytes4 UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_ONE = 0x88676cad;
    bytes4 UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_TWO = 0xf074ba62;
    bytes4 UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_THREE = 0x039157d2;
    bytes4 UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_FOUR = 0x3f65cf19;
    bytes4 UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_FIVE = 0xc4907442;
    bytes4 UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_SIX = 0x0dd8dd02;
    bytes4 UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_SEVEN = 0x9435bb43;

    //--------------------------------------------------------------------------------------
    //---------------------------------  POST UPGRADE RELATED STUFF  -----------------------
    //--------------------------------------------------------------------------------------

    //--------------------------------------------------------------------------------------
    //---------------------------------  LIMIT IDS  ----------------------------------------
    //--------------------------------------------------------------------------------------
    bytes32 UNRESTAKING_LIMIT_ID = EtherFiNodesManager(payable(etherFiNodesManagerImpl)).UNRESTAKING_LIMIT_ID();

    bytes32 EXIT_REQUEST_LIMIT_ID = EtherFiNodesManager(payable(etherFiNodesManagerImpl)).EXIT_REQUEST_LIMIT_ID();

    uint64 CAPACITY_RATE_LIMITER = 100_000_000_000_000;
    uint64 REFILL_RATE_LIMITER = 2_000_000_000;

    //--------------------------------------------------------------------------------------
    //---------------------------------  SELECTORS  ----------------------------------------
    //--------------------------------------------------------------------------------------

    /*
        External forwarded calls
        // ------------------------------------------------------------------------------------------------
        King rewards claiming from eigen
        caller: `0x7835fB36A8143a014A2c381363cD1A4DeE586d2A` 
        target = eigenlayerRewardsCoordinator: 0x7750d328b314EfFa365A0402CcfD489B80B0adda 
        method: `processClaim((uint32,uint32,bytes,(address,bytes32),uint32[],bytes[],(address,uint256)[]) claim, address recipient)`

        cast sig "processClaim((uint32,uint32,bytes,(address,bytes32),uint32[],bytes[],(address,uint256)[]),address)"
        0x3ccc861d

        Eigenpod forwarded calls
        // ------------------------------------------------------------------------------------------------
        Proof server start checkpoint
        caller: `0x7835fB36A8143a014A2c381363cD1A4DeE586d2A`
        method: eigenpod.StartCheckpoint(bool)

            function startCheckpoint(
                bool revertIfNoBalance
            ) external;

        cast sig "startCheckpoint(bool)"
        0x88676cad

        // ------------------------------------------------------------------------------------------------
        Proof server complete checkpoint
        caller: `0x7835fB36A8143a014A2c381363cD1A4DeE586d2A`
        method: eigenpod.VerifyCheckpointProofs(...)

            function verifyCheckpointProofs(
                BeaconChainProofs.BalanceContainerProof calldata balanceContainerProof,
                BeaconChainProofs.BalanceProof[] calldata proofs
            ) external;

        cast sig "verifyCheckpointProofs((bytes32,bytes),[(bytes32,bytes32,bytes)])"
        0xbd97dd29

        // ------------------------------------------------------------------------------------------------
        Proof server verify withdrawal credentials
        caller: `0x7835fB36A8143a014A2c381363cD1A4DeE586d2A`
        method: EigenPod.VerifyWithdrawalCredentials(...)

            function verifyWithdrawalCredentials(
                uint64 beaconTimestamp,
                BeaconChainProofs.StateRootProof calldata stateRootProof,
                uint40[] calldata validatorIndices,
                bytes[] calldata validatorFieldsProofs,
                bytes32[][] calldata validatorFields
            ) external;

        cast sig "verifyWithdrawalCredentials(uint64,(bytes32,bytes),uint40[],bytes[],bytes32[][])"
        0x3f65cf19
        */

    // External calls selectors
    bytes4 UPDATE_USER_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_ONE = 0x3ccc861d; // processClaim

    // Eigenpod calls selectors
    bytes4 UPDATE_USER_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_TWO = 0x88676cad; // startCheckpoint
    bytes4 UPDATE_USER_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_THREE = 0xf074ba62; // verifyCheckpointProofs
    bytes4 UPDATE_USER_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_FOUR = 0x3f65cf19; // verifyWithdrawalCredentials

    function run() public {
        console2.log("================================================");
        console2.log("======================== Running El Exits Transactions ========================");
        console2.log("================================================");
        console2.log("");
        vm.startBroadcast(ETHERFI_OPERATING_ADMIN);
        cleanUpOldMappingsInEtherFiNodesManager();
        vm.stopBroadcast();

        vm.startBroadcast(TIMELOCK_CONTROLLER);
        executeElExitTransactions();
        vm.stopBroadcast();

        console2.log("================================================");
        console2.log("======================== Running Post Upgrade Transactions ========================");
        console2.log("================================================");
        console2.log("");
        vm.startBroadcast(ETHERFI_OPERATING_ADMIN);
        backfillEtherFiNodes();
        setUpEtherFiRateLimiter();
        addNewMappingsInEtherFiNodesManager();
        vm.stopBroadcast();

        // ---------------------------------------------------------------------------------------------------------
        // -------------------------------------- UNCOMMENT ONLY FOR ROLLBACK --------------------------------------
        // ---------------------------------------------------------------------------------------------------------

        console2.log("================================================");
        console2.log("======================== Running Rollback Transactions ========================");
        console2.log("================================================");
        console2.log("");
        // @dev NOTE: check the comment => uncomment to run against fork
        // ROLLBACK
        // 1. Rollback the new mappings in EtherFiNodesManager
        vm.startBroadcast(ETHERFI_OPERATING_ADMIN);
        rollback_newMappingsFromEtherFiNodesManager();
        vm.stopBroadcast();

        // 2. First execute the upgrade tx back to the old implementations
        vm.startBroadcast(TIMELOCK_CONTROLLER);
        rollback_executeElExitTransactions();
        vm.stopBroadcast();

        // 3. Then rollback the old mappings
        vm.startBroadcast(ETHERFI_OPERATING_ADMIN);
        rollback_oldMappingsInEtherFiNodesManager();
        vm.stopBroadcast();
    }

    function executeElExitTransactions() public {
        console2.log("Executing El Exit");
        console2.log("================================================");

        address[] memory targets = new address[](7);
        bytes[] memory data = new bytes[](7);
        uint256[] memory values = new uint256[](7); // Default to 0

        //--------------------------------------------------------------------------------------
        //---------------------------------- Grant Roles ---------------------------------------
        //--------------------------------------------------------------------------------------

        // etherFiNode
        data[0] = _encodeRoleGrant(ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE, EL_TRIGGER_EXITER);
        data[1] = _encodeRoleGrant(ETHERFI_NODES_MANAGER_POD_PROVER_ROLE, POD_PROVER);
        data[2] = _encodeRoleGrant(STAKING_MANAGER_ADMIN_ROLE, ETHERFI_OPERATING_ADMIN);
        data[3] = _encodeRoleGrant(ETHERFI_RATE_LIMITER_ADMIN_ROLE, ETHERFI_OPERATING_ADMIN);

        for (uint256 i = 0; i < 4; i++) {
            targets[i] = address(roleRegistry);
        }

        //--------------------------------------------------------------------------------------
        //------------------------------- CONTRACT UPGRADES  -----------------------------------
        //--------------------------------------------------------------------------------------

        targets[4] = address(stakingManager);
        data[4] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, stakingManagerImpl);

        targets[5] = address(etherFiNodesManager);
        data[5] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, etherFiNodesManagerImpl);

        //--------------------------------------------------------------------------------------
        //------------------------------- ETHERFI NODE UPGRADE  -----------------------------------
        //--------------------------------------------------------------------------------------

        targets[6] = address(stakingManager);
        data[6] = abi.encodeWithSelector(StakingManager.upgradeEtherFiNode.selector, etherFiNodeImpl);

        //--------------------------------------------------------------------------------------
        //------------------------------- SCHEDULE TX  -----------------------------------
        //--------------------------------------------------------------------------------------
        bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherFiTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt,
            MIN_DELAY_TIMELOCK // minDelay
        );
        console2.log("====== Schedule Execute El Exit Transactions Tx:");
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
        console2.log("====== Execute El Exit Transactions Tx:");
        console2.logBytes(executeCalldata);
        console2.log("================================================");
        console2.log("");

        // uncomment to run against fork
        // console2.log("=== SCHEDULING BATCH ===");
        // console2.log("Current timestamp:", block.timestamp);
        // etherFiTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_TIMELOCK);

        // console2.log("=== FAST FORWARDING TIME ===");
        // vm.warp(block.timestamp + MIN_DELAY_TIMELOCK + 1); // +1 to ensure it's past the delay
        // console2.log("New timestamp:", block.timestamp);
        // etherFiTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
    }

    function cleanUpOldMappingsInEtherFiNodesManager() public {
        console2.log("Removing Whitelisted External Calls in EtherFiNodesManager");

        address[] memory targets = new address[](16);
        bytes[] memory data = new bytes[](16);
        uint256[] memory values = new uint256[](16); // Default to 0

        // -------------------------- Whitelisted External Calls --------------------------

        targets[0] = address(etherFiNodesManager);
        data[0] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_ONE, 0x035bdAeaB85E47710C27EdA7FD754bA80aD4ad02, false);

        targets[1] = address(etherFiNodesManager);
        data[1] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_TWO, 0xec53bF9167f50cDEB3Ae105f56099aaaB9061F83, false);

        targets[2] = address(etherFiNodesManager);
        data[2] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_THREE, 0x7750d328b314EfFa365A0402CcfD489B80B0adda, false);

        targets[3] = address(etherFiNodesManager);
        data[3] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_FOUR, 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A, false);

        targets[4] = address(etherFiNodesManager);
        data[4] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_FIVE, 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A, false);

        targets[5] = address(etherFiNodesManager);
        data[5] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_SIX, 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A, false);

        targets[6] = address(etherFiNodesManager);
        data[6] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_SEVEN, 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A, false);

        targets[7] = address(etherFiNodesManager);
        data[7] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_EIGHT, 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A, false);

        targets[8] = address(etherFiNodesManager);
        data[8] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_NINE, 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A, false);

        // -------------------------- Whitelisted Eigenpod Calls --------------------------
        targets[9] = address(etherFiNodesManager);
        data[9] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_ONE, false);

        targets[10] = address(etherFiNodesManager);
        data[10] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_TWO, false);

        targets[11] = address(etherFiNodesManager);
        data[11] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_THREE, false);

        targets[12] = address(etherFiNodesManager);
        data[12] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_FOUR, false);

        targets[13] = address(etherFiNodesManager);
        data[13] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_FIVE, false);

        targets[14] = address(etherFiNodesManager);
        data[14] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_SIX, false);

        targets[15] = address(etherFiNodesManager);
        data[15] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_SEVEN, false);

        // schedule
        bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherFiOperatingTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt,
            MIN_DELAY_OPERATING_TIMELOCK // minDelay
        );
        console2.log("====== Schedule Clean Up Old Whitelist Mappings In EtherFiNodesManager Tx:");
        console2.logBytes(scheduleCalldata);
        console2.log("================================================");
        console2.log("");
        // execute
        bytes memory executeCalldata = abi.encodeWithSelector(
            etherFiOperatingTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0), //predecessor
            timelockSalt
        );
        console2.log("====== Execute Clean Up Old Whitelist Mappings In EtherFiNodesManager Tx:");
        console2.logBytes(executeCalldata);
        console2.log("================================================");
        console2.log("");
        // uncomment to run against fork
        // console2.log("=== SCHEDULING BATCH ===");
        // console2.log("Current timestamp:", block.timestamp);
        // etherFiOperatingTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_OPERATING_TIMELOCK);

        // console2.log("=== FAST FORWARDING TIME ===");
        // vm.warp(block.timestamp + MIN_DELAY_OPERATING_TIMELOCK + 1); // +1 to ensure it's past the delay
        // console2.log("New timestamp:", block.timestamp);
        // etherFiOperatingTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
    }

    function addNewMappingsInEtherFiNodesManager() public {
        console2.log("Adding New Mappings");
        console2.log("================================================");
        address ALLOWED_CALLER = 0x7835fB36A8143a014A2c381363cD1A4DeE586d2A;
        address EIGENLAYER_REWARDS_COORDINATOR = 0x7750d328b314EfFa365A0402CcfD489B80B0adda;

        address[] memory targets = new address[](4);
        bytes[] memory data = new bytes[](4);
        uint256[] memory values = new uint256[](4); // Default to 0

        // Forwarded External Calls
        data[0] = abi.encodeWithSelector(
            EtherFiNodesManager.updateAllowedForwardedExternalCalls.selector,
            ALLOWED_CALLER,
            UPDATE_USER_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_ONE, // processClaim
            EIGENLAYER_REWARDS_COORDINATOR,
            true
        );
        // Forwarded Eigenpod Calls
        data[1] = abi.encodeWithSelector(
            EtherFiNodesManager.updateAllowedForwardedEigenpodCalls.selector,
            ALLOWED_CALLER,
            UPDATE_USER_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_TWO, // startCheckpoint
            true
        );
        data[2] = abi.encodeWithSelector(
            EtherFiNodesManager.updateAllowedForwardedEigenpodCalls.selector,
            ALLOWED_CALLER,
            UPDATE_USER_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_THREE, // verifyCheckpointProofs
            true
        );
        data[3] = abi.encodeWithSelector(
            EtherFiNodesManager.updateAllowedForwardedEigenpodCalls.selector,
            ALLOWED_CALLER,
            UPDATE_USER_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_FOUR, // verifyWithdrawalCredentials
            true
        );

        for (uint256 i = 0; i < 4; i++) {
            targets[i] = address(etherFiNodesManager);
        }

        // schedule
        bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherFiOperatingTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt,
            MIN_DELAY_OPERATING_TIMELOCK // minDelay
        );
        console2.log("====== Schedule New Mappings In EtherFiNodesManager Tx:");
        console2.logBytes(scheduleCalldata);
        console2.log("================================================");
        console2.log("");
        // execute
        bytes memory executeCalldata = abi.encodeWithSelector(
            etherFiOperatingTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0), //predecessor
            timelockSalt
        );
        console2.log("====== Execute New Mappings In EtherFiNodesManager Tx:");
        console2.logBytes(executeCalldata);
        console2.log("================================================");
        console2.log("");

        // uncomment to run against fork
        // console2.log("=== SCHEDULING BATCH ===");
        // console2.log("Current timestamp:", block.timestamp);
        // etherFiOperatingTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_OPERATING_TIMELOCK);

        // // console2.log("=== FAST FORWARDING TIME ===");
        // vm.warp(block.timestamp + MIN_DELAY_OPERATING_TIMELOCK + 1); // +1 to ensure it's past the delay
        // console2.log("New timestamp:", block.timestamp);
        // etherFiOperatingTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
    }

    function backfillEtherFiNodes() public {
        console2.log("Backfilling EtherFiNodes - All 504 addresses");
        console2.log("================================================");

        // All 504 addresses
        address[] memory etherFiNodes = _getEtherFiNodes();

        // uncomment to run against fork
        // StakingManager(payable(stakingManager)).backfillExistingEtherFiNodes(etherFiNodes);

        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = address(stakingManager);
        data[0] = abi.encodeWithSelector(StakingManager.backfillExistingEtherFiNodes.selector, etherFiNodes);

        console2.log("target: ", targets[0]);
        console2.log("data: ");
        console2.logBytes(data[0]);
        console2.log("================================================");
        console2.log("");
    }

    function setUpEtherFiRateLimiter() public {
        console2.log("Setting Up EtherFiRateLimiter");
        console2.log("================================================");

        // uncomment to run against fork
        // EtherFiRateLimiter(payable(etherFiRateLimiterProxy)).createNewLimiter(UNRESTAKING_LIMIT_ID, CAPACITY_RATE_LIMITER, REFILL_RATE_LIMITER);
        // EtherFiRateLimiter(payable(etherFiRateLimiterProxy)).createNewLimiter(EXIT_REQUEST_LIMIT_ID, CAPACITY_RATE_LIMITER, REFILL_RATE_LIMITER);
        // EtherFiRateLimiter(payable(etherFiRateLimiterProxy)).updateConsumers(UNRESTAKING_LIMIT_ID, address(etherFiNodesManager), true);
        // EtherFiRateLimiter(payable(etherFiRateLimiterProxy)).updateConsumers(EXIT_REQUEST_LIMIT_ID, address(etherFiNodesManager), true);

        address[] memory targets = new address[](4);
        bytes[] memory data = new bytes[](4);
        uint256[] memory values = new uint256[](4); // Default to 0

        data[0] = abi.encodeWithSelector(EtherFiRateLimiter.createNewLimiter.selector, UNRESTAKING_LIMIT_ID, CAPACITY_RATE_LIMITER, REFILL_RATE_LIMITER);
        data[1] = abi.encodeWithSelector(EtherFiRateLimiter.createNewLimiter.selector, EXIT_REQUEST_LIMIT_ID, CAPACITY_RATE_LIMITER, REFILL_RATE_LIMITER);
        data[2] = abi.encodeWithSelector(EtherFiRateLimiter.updateConsumers.selector, UNRESTAKING_LIMIT_ID, address(etherFiNodesManager), true);
        data[3] = abi.encodeWithSelector(EtherFiRateLimiter.updateConsumers.selector, EXIT_REQUEST_LIMIT_ID, address(etherFiNodesManager), true);

        for (uint256 i = 0; i < 4; i++) {
            console2.log("====== Execute Set Up EtherFiRateLimiter Tx:", i);
            targets[i] = address(etherFiRateLimiterProxy);
            console2.log("target: ", targets[i]);
            console2.log("data: ");
            console2.logBytes(data[i]);
            console2.log("--------------------------------");
        }
        console2.log("================================================");
        console2.log("");
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- EMERGENCY NODE ROLLBACK  -----------------------------
    //--------------------------------------------------------------------------------------
    function rollback_newMappingsFromEtherFiNodesManager() public {
        console2.log("Rolling back New Mappings in EtherFiNodesManager");
        address ALLOWED_CALLER = 0x7835fB36A8143a014A2c381363cD1A4DeE586d2A;
        address EIGENLAYER_REWARDS_COORDINATOR = 0x7750d328b314EfFa365A0402CcfD489B80B0adda;

        address[] memory targets = new address[](4);
        bytes[] memory data = new bytes[](4);
        uint256[] memory values = new uint256[](4); // Default to 0

        // Forwarded External Calls
        data[0] = abi.encodeWithSelector(
            EtherFiNodesManager.updateAllowedForwardedExternalCalls.selector,
            ALLOWED_CALLER,
            UPDATE_USER_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_ONE, // processClaim
            EIGENLAYER_REWARDS_COORDINATOR,
            false
        );
        // Forwarded Eigenpod Calls
        data[1] = abi.encodeWithSelector(
            EtherFiNodesManager.updateAllowedForwardedEigenpodCalls.selector,
            ALLOWED_CALLER,
            UPDATE_USER_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_TWO, // startCheckpoint
            false
        );
        data[2] = abi.encodeWithSelector(
            EtherFiNodesManager.updateAllowedForwardedEigenpodCalls.selector,
            ALLOWED_CALLER,
            UPDATE_USER_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_THREE, // verifyCheckpointProofs
            false
        );
        data[3] = abi.encodeWithSelector(
            EtherFiNodesManager.updateAllowedForwardedEigenpodCalls.selector,
            ALLOWED_CALLER,
            UPDATE_USER_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_FOUR, // verifyWithdrawalCredentials
            false
        );

        for (uint256 i = 0; i < 4; i++) {
            targets[i] = address(etherFiNodesManager);
        }

        // schedule
        bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherFiOperatingTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt,
            MIN_DELAY_OPERATING_TIMELOCK // minDelay
        );
        console2.log("====== Schedule Rollback New Mappings In EtherFiNodesManager Tx:");
        console2.logBytes(scheduleCalldata);
        console2.log("================================================");

        // execute
        bytes memory executeCalldata = abi.encodeWithSelector(
            etherFiOperatingTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0), //predecessor
            timelockSalt
        );
        console2.log("====== Execute Rollback New Mappings In EtherFiNodesManager Tx:");
        console2.logBytes(executeCalldata);
        console2.log("================================================");
        console2.log("");

        // uncomment to run against fork
        // console2.log("=== SCHEDULING BATCH ===");
        // console2.log("Current timestamp:", block.timestamp);
        // etherFiOperatingTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_OPERATING_TIMELOCK);

        // console2.log("=== FAST FORWARDING TIME ===");
        // vm.warp(block.timestamp + MIN_DELAY_OPERATING_TIMELOCK + 1); // +1 to ensure it's past the delay
        // console2.log("New timestamp:", block.timestamp);
        // etherFiOperatingTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
    }

    // NOTE: Make sure to clear out the etherFiNodes mapping in the StakingManager contract in case of a rollback
    function rollback_backfillEtherFiNodes() public {
        // console2.log("Rolling back Backfill EtherFiNodes");
    }

    function rollback_executeElExitTransactions() public {
        console2.log("Executing El Exit Rollback");
        console2.log("================================================");

        address[] memory targets = new address[](3);
        bytes[] memory data = new bytes[](3);
        uint256[] memory values = new uint256[](3); // Default to 0

        //--------------------------------------------------------------------------------------
        //------------------------------- CONTRACT UPGRADES  -----------------------------------
        //--------------------------------------------------------------------------------------

        targets[0] = address(stakingManager);
        data[0] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, oldStakingManagerImpl);

        targets[1] = address(etherFiNodesManager);
        data[1] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, oldEtherFiNodesManagerImpl);

        targets[2] = address(stakingManager);
        data[2] = abi.encodeWithSelector(StakingManager.upgradeEtherFiNode.selector, oldEtherFiNodeImpl);

        // schedule
        bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherFiTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt,
            MIN_DELAY_TIMELOCK // minDelay
        );
        console2.log("====== Rollback Schedule Tx:");
        console2.logBytes(scheduleCalldata);
        console2.log("================================================");

        // execute
        bytes memory executeCalldata = abi.encodeWithSelector(
            etherFiTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0), //predecessor
            timelockSalt
        );
        console2.log("====== Rollback Execute Tx:");
        console2.logBytes(executeCalldata);

        console2.log("");
        console2.log("================================================");

        // uncomment to run against fork
        // console2.log("=== SCHEDULING BATCH ===");
        // console2.log("Current timestamp:", block.timestamp);
        // etherFiTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_TIMELOCK);

        // console2.log("=== FAST FORWARDING TIME ===");
        // vm.warp(block.timestamp + MIN_DELAY_TIMELOCK + 1); // +1 to ensure it's past the delay
        // console2.log("New timestamp:", block.timestamp);
        // etherFiTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
    }

    function rollback_oldMappingsInEtherFiNodesManager() public {
        console2.log("Rolling back Old Whitelist Mappings in EtherFiNodesManager");

        address[] memory targets = new address[](16);
        bytes[] memory data = new bytes[](16);
        uint256[] memory values = new uint256[](16); // Default to 0

        // -------------------------- Whitelisted External Calls --------------------------

        targets[0] = address(etherFiNodesManager);
        data[0] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_ONE, 0x035bdAeaB85E47710C27EdA7FD754bA80aD4ad02, true);

        targets[1] = address(etherFiNodesManager);
        data[1] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_TWO, 0xec53bF9167f50cDEB3Ae105f56099aaaB9061F83, true);

        targets[2] = address(etherFiNodesManager);
        data[2] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_THREE, 0x7750d328b314EfFa365A0402CcfD489B80B0adda, true);

        targets[3] = address(etherFiNodesManager);
        data[3] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_FOUR, 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A, true);

        targets[4] = address(etherFiNodesManager);
        data[4] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_FIVE, 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A, true);

        targets[5] = address(etherFiNodesManager);
        data[5] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_SIX, 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A, true);

        targets[6] = address(etherFiNodesManager);
        data[6] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_SEVEN, 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A, true);

        targets[7] = address(etherFiNodesManager);
        data[7] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_EIGHT, 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A, true);

        targets[8] = address(etherFiNodesManager);
        data[8] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EXTERNAL_CALLS_SELECTOR_NINE, 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A, true);

        // -------------------------- Whitelisted Eigenpod Calls --------------------------
        targets[9] = address(etherFiNodesManager);
        data[9] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_ONE, true);

        targets[10] = address(etherFiNodesManager);
        data[10] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_TWO, true);

        targets[11] = address(etherFiNodesManager);
        data[11] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_THREE, true);

        targets[12] = address(etherFiNodesManager);
        data[12] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_FOUR, true);

        targets[13] = address(etherFiNodesManager);
        data[13] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_FIVE, true);

        targets[14] = address(etherFiNodesManager);
        data[14] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_SIX, true);

        targets[15] = address(etherFiNodesManager);
        data[15] = abi.encodeWithSelector(UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR, UPDATE_ALLOWED_FORWARDED_EIGENPOD_CALLS_SELECTOR_SEVEN, true);

        // schedule
        bytes32 timelockSalt = keccak256(abi.encode(targets, data, block.number));
        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherFiOperatingTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0), // predecessor
            timelockSalt,
            MIN_DELAY_OPERATING_TIMELOCK // minDelay
        );
        console2.log("====== Schedule Rollback Cleaned Up Old Whitelist Mappings In EtherFiNodesManager Tx:");
        console2.logBytes(scheduleCalldata);
        console2.log("================================================");
        console2.log("");

        // execute
        bytes memory executeCalldata = abi.encodeWithSelector(
            etherFiOperatingTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0), //predecessor
            timelockSalt
        );
        console2.log("====== Execute Rollback Cleaned Up Old Whitelist Mappings In EtherFiNodesManager Tx:");
        console2.logBytes(executeCalldata);
        console2.log("================================================");
        console2.log("");

        // uncomment to run against fork
        // console2.log("=== SCHEDULING BATCH ===");
        // console2.log("Current timestamp:", block.timestamp);
        // etherFiOperatingTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_OPERATING_TIMELOCK);

        // console2.log("=== FAST FORWARDING TIME ===");
        // vm.warp(block.timestamp + MIN_DELAY_OPERATING_TIMELOCK + 1); // +1 to ensure it's past the delay
        // console2.log("New timestamp:", block.timestamp);
        // etherFiOperatingTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- HELPER FUNCTIONS  -----------------------------------
    //--------------------------------------------------------------------------------------

    function _encodeRoleGrant(bytes32 role, address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(RoleRegistry.grantRole.selector, role, account);
    }

    function _getEtherFiNodes() internal pure returns (address[] memory etherFiNodes) {
        etherFiNodes = new address[](504);
        {
            etherFiNodes[0] = 0x3e7230E6184e89525fa89CADBBBCfBd056157d5E;
            etherFiNodes[1] = 0x89c5e2206315Ff914f59CDc3dC93117c2D2274EE;
            etherFiNodes[2] = 0x7AFaeeF339c6767D921420514f11B4D8AA3363F4;
            etherFiNodes[3] = 0xbb31f6dAc34b3646D6339f3696047fFeaC246d4F;
            etherFiNodes[4] = 0x7898333991035242A1115D978c0619F8736dD323;
            etherFiNodes[5] = 0x9bD9d7183c63493B47D394533355dAbbc0f29dC5;
            etherFiNodes[6] = 0x379eBDb23B602970D8c96A08f9F9430fB225d01A;
            etherFiNodes[7] = 0xe08D2106ed8b1A97c160404a14756834280e5ebb;
            etherFiNodes[8] = 0x6893552Bc8a2061fEe4bC7CbdFDc10b5Bb077DaD;
            etherFiNodes[9] = 0xAb38C425b9fF37D28bA6fF77A132133a3a9ef276;
            etherFiNodes[10] = 0x25428435E23683CAD096B55dbD582f1F01Bac1be;
            etherFiNodes[11] = 0xFf1e889CfB8b04BcD99d641a2c25774EdDc507dc;
            etherFiNodes[12] = 0x5d5B49E9AD0D92B02d99e3771C09C947019637c9;
            etherFiNodes[13] = 0xBF4859a818ecbe578C9C98F7F36086e1F45D3d16;
            etherFiNodes[14] = 0x3b8206bFe447260F69ca0618667b0f6180096cA2;
            etherFiNodes[15] = 0x26F4Da4aE82933096F281665e0cecEAfD00E2B37;
            etherFiNodes[16] = 0x622AE42994eCD2B499BE8B4d3473AD397BCd739d;
            etherFiNodes[17] = 0xe5fcDEd228fa644627C1dfEc053CE3E22cb48112;
            etherFiNodes[18] = 0x25833D3De051493455f6ac61e71b731D108a8cE8;
            etherFiNodes[19] = 0xC12eAAc114e8D5315E97c8b047c895fD83444Ea5;
            etherFiNodes[20] = 0x17f8623EDEc433f17e6838244737d21790bC1DAC;
            etherFiNodes[21] = 0x0e7e0A71B3749fD1dA367B72Fd247127713fC8a1;
            etherFiNodes[22] = 0x975eCc3879C0cCf4433d15D6941d0238357aC325;
            etherFiNodes[23] = 0xEAA1E6Fa654788aDBdeAAc009217Cc4F6b92aD9D;
            etherFiNodes[24] = 0xf75818B3501FF843F6784f6DE1D3F6080cEB96e5;
            etherFiNodes[25] = 0xBe21d6A41Efe662826Ac4953C210C5F5c9748355;
            etherFiNodes[26] = 0x1a495289A93e7e1Caa75436FE90A4aeb5eC33A5f;
            etherFiNodes[27] = 0x0F4227aF3B662238efFDD93b18BE7EC04cf84291;
            etherFiNodes[28] = 0x65737AD48b64Be2a766bac2230837a1745d8d11a;
            etherFiNodes[29] = 0x94eD8a5dCa27a963953561b02635B3d465dE4d0d;
            etherFiNodes[30] = 0xbb7ca966A6F3A0B7216BD55F040A85324eD9Cd87;
            etherFiNodes[31] = 0xa66d6730c2516B277bd65844cEFCc3e6814cf190;
            etherFiNodes[32] = 0xb0A72A7E4Af952C4f9d379E3EeF77b7C9c2c2F1e;
            etherFiNodes[33] = 0x38454E5702637E3D2A59C5d1c92c1904996bA227;
            etherFiNodes[34] = 0xdCDb6dF94Addd94aE8D1564d54D608b9D65814bd;
            etherFiNodes[35] = 0x8139F843DdF4eF2aCfB7225F9137f9E865B7b237;
            etherFiNodes[36] = 0x1dF4fd06bB3866D7d66e0Db8428B24fd829B2e9b;
            etherFiNodes[37] = 0x76F6ec9ad10A8576f378C85688C9F113eF8eE40d;
            etherFiNodes[38] = 0x1B65AE9Ba310F033E5c15FdaAb4a485aB0b798c8;
            etherFiNodes[39] = 0x4bBCC558f0f27Bb1aDdE07A99AebBA67968b783f;
            etherFiNodes[40] = 0x6AC6B8F3328ADd3F4329dE67BF45fE271c9f83fD;
            etherFiNodes[41] = 0x555C1a885F98968874e7b69e96937A59182ab8dA;
            etherFiNodes[42] = 0x5F1245A3ed7e93D87493EF1b152767F26F452956;
            etherFiNodes[43] = 0xC94EBB12830571FCEaEe464BB330723cBBf11308;
            etherFiNodes[44] = 0x92316Ab4BEe3662709DD6a96ea19B06692409B2E;
            etherFiNodes[45] = 0xb71F34483f886CFc6C220C72e7C77B9ce29F49bd;
            etherFiNodes[46] = 0x91B69545B6537d396a9467ed03bc418F8d2472D7;
            etherFiNodes[47] = 0x0F3e5FA1720E0b99d4DF5ed38783d6f7d71AaF12;
            etherFiNodes[48] = 0x877d2a7a6de6E05901954bC8CC0F37f2e9A6f75e;
            etherFiNodes[49] = 0x605B07407E8da3e102330B1B895D1057FD66Add1;
            etherFiNodes[50] = 0x18Ec33F50FbA074e1A8AF006633179cdE8c97957;
            etherFiNodes[51] = 0x1F6368d91B4D0235C4C4aB8D2D357721e0Eb26ae;
            etherFiNodes[52] = 0x5062b28d34a6518D0CA037a50372849a85b446b3;
            etherFiNodes[53] = 0x721636F6bBf037Bcf63d3AD697f529512C712626;
            etherFiNodes[54] = 0xBEb93802817F4B5A63a04c7CC1B288F58C2abf79;
            etherFiNodes[55] = 0x5F522B216A990961584BC857cEe8f5ba3983197c;
            etherFiNodes[56] = 0x880bA04DB0b91B1C46cDa2081EF5C0cC6378Fd32;
            etherFiNodes[57] = 0x0A780528eA8ECe64Fb2e46Fd2600eAE21747291b;
            etherFiNodes[58] = 0x566Faca7Db752D2E9A35f21FF9D1e498541Fb8aB;
            etherFiNodes[59] = 0x6a402D1E19752ccD640d85E1854A2925b36FA439;
            etherFiNodes[60] = 0x75d2672CB618F47bC1CAa417e681100090fDBB99;
            etherFiNodes[61] = 0xCa6824cBcb57C3310Ad2ac8392D825A37C0118B2;
            etherFiNodes[62] = 0xaA311B226F4367aacc68DB326016b970F96e07bB;
            etherFiNodes[63] = 0x7f91F0a50A874ADD09027F5C21684209e1338434;
            etherFiNodes[64] = 0x3D8dA83643370df84098AB9bdBd3Ec9aB38d810e;
            etherFiNodes[65] = 0xf60B68889Df46cdc608121417c38232a302cCf2B;
            etherFiNodes[66] = 0x5731CDd8B8A91b1DF8D66e822baF535cF8a3569a;
            etherFiNodes[67] = 0xFDB00d95606d33a4E3DEA5872463482DcF8AD51a;
            etherFiNodes[68] = 0x8f8d073FA239A74de9249c1bf8a4c077547066f2;
            etherFiNodes[69] = 0x5c4d4A148c4b504Fab5782Da4DA93D69D098B207;
            etherFiNodes[70] = 0xd5438E6bDd74035Dc5931597C23F4c8479E4D0AF;
            etherFiNodes[71] = 0xb8934644879dc160030fb483851Fd7d268aFD437;
            etherFiNodes[72] = 0x1120B0d85824a76625f3e595fcc8F2fff42675fC;
            etherFiNodes[73] = 0xfB082Dc369e7a9DdD4f0dd6D75DbC07daBC5a441;
            etherFiNodes[74] = 0x2B5B6b2C0617077328ABa5E19493C35fbE261B80;
            etherFiNodes[75] = 0x886Ac426bC13877E89828914589E0980306447eB;
            etherFiNodes[76] = 0xbfCbcEC4973ec02F4e8066a32Bc83C2dDdaE5D1e;
            etherFiNodes[77] = 0x9F7479fb112B6a51325Cf9A4B407a0D3bC48B938;
            etherFiNodes[78] = 0x36A9E14026754265bC9CA70F41905c1325489E87;
            etherFiNodes[79] = 0x51B60b00E33BDa11412b518a7223F79f59Bb7E2F;
            etherFiNodes[80] = 0x4e7A000995358e75010e1cD361Dbd73a365feC74;
            etherFiNodes[81] = 0xD57672Fe005D4877100c4E456629eB986d3D974a;
            etherFiNodes[82] = 0x05778C88D86A7E7E3546F2e6dD38a3655E157440;
            etherFiNodes[83] = 0x2556Ac27c67A6f7faA71DEcb863cA6BC2f287A24;
            etherFiNodes[84] = 0x829400C84E2dF1fBD6012e2Fb3EA8Bb0866D2651;
            etherFiNodes[85] = 0x1Af1465D9674caa5Dc53Cf2aF240202462b6C279;
            etherFiNodes[86] = 0x6497Dbc476b07e89572253B73AFa3Fd3AdaA4365;
            etherFiNodes[87] = 0xFc6A02Dcc0807E067d8BEfa544a8496F420Aad27;
            etherFiNodes[88] = 0x09bdd58de99a103292B095FbeA99C75d3970A57c;
            etherFiNodes[89] = 0xDa9f386d040cedDbEb5eC9017c2d2542aC58a47C;
            etherFiNodes[90] = 0xb9d000815899360ECfaD44Cd3C150103B37fCE28;
            etherFiNodes[91] = 0x30Ab5A829d516A6167512624625E884655d16fa5;
            etherFiNodes[92] = 0xA59c6081a1ffD1b1EA71B0913E313E780291520f;
            etherFiNodes[93] = 0x4B559d35C759074F065315948da2445De1a3314e;
            etherFiNodes[94] = 0xA5216Ea96166629dB0F5157e810C17b022008a9d;
            etherFiNodes[95] = 0x017Fb4bD8AD751bE840392A5d45476817F83D796;
            etherFiNodes[96] = 0xD8A966d1BD65EeCF3aD6b48636C09cD58BbeEEA2;
            etherFiNodes[97] = 0x2d8823E1E502734AE19EAE42027d931353D6a8EE;
            etherFiNodes[98] = 0x787044f7f0B0e5E4d60B84cCE2D79E027611B49f;
            etherFiNodes[99] = 0xA369A6466A9670Ed973B5B06EBaD778ca661a073;
            etherFiNodes[100] = 0x28A38AEE3443cEC4136235fC0043b48cF2639F8a;
            etherFiNodes[101] = 0x89B8ee5b9441Ed47188dcc42949408D93130C35d;
            etherFiNodes[102] = 0x24E7315B50b90b894B905af1DC5645C138BA7fFD;
            etherFiNodes[103] = 0x8F36f66FA058234103988710b8C01f542D3eD926;
            etherFiNodes[104] = 0x29aC32400d735834Be7907dCb281C7dCC6346EE2;
            etherFiNodes[105] = 0xF2cF3Cc1de93D4ddd6c65971c4eb1573614D02Da;
            etherFiNodes[106] = 0x85Dd94DE89AD5Da0966CDbD9Bb5F9efD24782FA5;
            etherFiNodes[107] = 0xA2e670C1163C8E200817af3a138e1287E2Cb4204;
            etherFiNodes[108] = 0xF3F385FD165935CE51451DD26BEB17588f04dfb0;
            etherFiNodes[109] = 0xd3d2413985389A8F45dbF2378b313C2A789065B7;
            etherFiNodes[110] = 0x0Da178663e7ed6B7DbA300bD8A053e7975fd5b67;
            etherFiNodes[111] = 0x8A7460C302b3AA0D21c250Baa6d641391EFABa45;
            etherFiNodes[112] = 0x7b78D0FcE0dF2F8BBdF7018E317fd92C00817750;
            etherFiNodes[113] = 0x44b5101b3b54ebDeB0e54f0e2d5b09DBd6DbD07F;
            etherFiNodes[114] = 0x92d7f071290AD0F6C9df8cA099134a3C587faf93;
            etherFiNodes[115] = 0xF256f6453324E575E5eAf87d6Fc1dA9b8ed3ddD8;
            etherFiNodes[116] = 0x341C0cA17721452f9855fA35d87827ea7Cc41089;
            etherFiNodes[117] = 0x2A3aDDfDFbb49DF010f4e6De4e9b8654250EA056;
            etherFiNodes[118] = 0xe01AA1F2DAaafDFF569fE3923A2266A7EC198e9B;
            etherFiNodes[119] = 0xb22Cc4518CAE7F110Db80DfdA8cEcd2B2e9D8bCB;
            etherFiNodes[120] = 0x65b28416ECE2b225Ae993b596445A410818F7699;
            etherFiNodes[121] = 0xDdc78265b278b94B19D135Bf5a761c878e6b21cF;
            etherFiNodes[122] = 0x9CA5F522f276E0b2e22cC8c1e7aFC89E20ded95c;
            etherFiNodes[123] = 0xa925b70B1ED79440152817f95A1960f74b40B550;
            etherFiNodes[124] = 0x789e8C2C3A8817Bd91314F9b9964C7D2336c1e22;
            etherFiNodes[125] = 0x6c99f059372Afcb8A972BD5f30A92e6CdcFdE1A1;
            etherFiNodes[126] = 0x451F0c6fC102C72690936A2b1F36fA184DaDcC04;
            etherFiNodes[127] = 0xD8a8dDDa3C7995C1a7Cd702b840c645B90E4c853;
            etherFiNodes[128] = 0x0aC24232336129222fe793241CA927E1a23AdaaA;
            etherFiNodes[129] = 0xc240cF53e8A3a5b4cb1a4A0BA3154DE5f1b0979e;
            etherFiNodes[130] = 0xd2707CFb58531DBAE76ef9Dd48780c8AA9A7e03F;
            etherFiNodes[131] = 0x24f1CE4758D02138a50faD53A6D21fF0ce029134;
            etherFiNodes[132] = 0xFa4e457Eb376634619c6853950E8edC2d5367c20;
            etherFiNodes[133] = 0xfa589B1b8f726d7aD3b87feEaC02491874Dd1fD5;
            etherFiNodes[134] = 0xaB299cdBD252Ac660A4eA7fcBA60a7bC64A95a05;
            etherFiNodes[135] = 0x7A2Ed858220463906E91ca2134e009B39A4b9eD9;
            etherFiNodes[136] = 0x8CB375DF683C34352696a5C894bd9bcB2a102529;
            etherFiNodes[137] = 0xCF504173490c312FA298BBDa7c538BD85945A12f;
            etherFiNodes[138] = 0x1EfA8c0315785a6678483Af6BA5CDB220E119e2E;
            etherFiNodes[139] = 0x5ff1bdc8e6A9E22C2d173574Cb0Ed22FbD2ddBA6;
            etherFiNodes[140] = 0x7D716075A3B7527597D5BA73CF5Fb19B9fcA5963;
            etherFiNodes[141] = 0x5d471718231615c5d6f4D4F46Fed4CbCFB43D3dA;
            etherFiNodes[142] = 0xF1CB37D9F632aE7814BC667Bd4B8f6cA65e72310;
            etherFiNodes[143] = 0x4a0a562CAfA04ab85B80557164811FD370f8E02e;
            etherFiNodes[144] = 0x18403332cB1793261AE769E895300c96ab3eCc84;
            etherFiNodes[145] = 0xB9266f94f418f5c229E4749a2d9aB8cAD8f2c039;
            etherFiNodes[146] = 0xC8B51968bc350626E66F56219782a6D45f2873ec;
            etherFiNodes[147] = 0x4c0456404760794A5b69550E5B76Fc0265710DDB;
            etherFiNodes[148] = 0x3A8F06b92c0b26551E73b3288e993e4414438298;
            etherFiNodes[149] = 0xA2aD87E730719C1994D8043F9962daee79E28760;
            etherFiNodes[150] = 0x384e83c2D42245A36faeD06f0555FF9c158eBbCF;
            etherFiNodes[151] = 0x3eC480Cd3E635b9033f99981262eB811669AE793;
            etherFiNodes[152] = 0x1cf177fb21f2cb8004a4B0616487499214fE3677;
            etherFiNodes[153] = 0x1adF94c9cABeEdb88149Ad8Dc54785507d243AAe;
            etherFiNodes[154] = 0xC7608Ad927312FB3f3486b4c70B133af603ed8a8;
            etherFiNodes[155] = 0x44bAacc2364fa423BFCBfA05C52eed1Df89cAAC9;
            etherFiNodes[156] = 0x6aeE24AaA432ab826f9eDD7F33dFC4Fd15a50b37;
            etherFiNodes[157] = 0x70FAFAA07d8937D45A8FEC1BAEa19E6B3fbb3b34;
            etherFiNodes[158] = 0xf7620082954317FF38d97863C7BE563498679f16;
            etherFiNodes[159] = 0x34b63bBe645A55a7593A95061E385096Fef4d00f;
            etherFiNodes[160] = 0xf2f4aAB39C4da684AC2EC971E3F924C0d47248c0;
            etherFiNodes[161] = 0x4342cb2Ea3e33A81891722EE4733cd8E3aeE5304;
            etherFiNodes[162] = 0xa01C6BAA89aFAE74bEfa932a45fD116401294f8d;
            etherFiNodes[163] = 0xFe74C7Dd86dD2896e1A361A9B6EfdD758aD25200;
            etherFiNodes[164] = 0xB74C26Cc203bB6516718b0Dc08C77A94A449e666;
            etherFiNodes[165] = 0x5c2ECC61fd049c4A4B06dACA0A20A522d0469D0D;
            etherFiNodes[166] = 0x426311D83B04b4f939E47a5f13983EB810b332D6;
            etherFiNodes[167] = 0x9fb692C7Ccf5fF89fEC67847bc9a6FB1d1008a2E;
            etherFiNodes[168] = 0x96CE7522AD24eFFBc45aDeb3df7631898F441161;
            etherFiNodes[169] = 0xc2e0E0D80E4231dF031F62d88A28E0f3A558707F;
            etherFiNodes[170] = 0x8EF13bE111C1A520cafb79fEf7F33d12d31C0401;
            etherFiNodes[171] = 0xB9e6d511497FAe0946d0AC0F4D8EB616Ef2DD0b4;
            etherFiNodes[172] = 0x8A7B3DCfF329B716C2eCca3Fe3FE40B0597F5EE1;
            etherFiNodes[173] = 0x2c5cCc15397678ACdb51A7F88f95278A00ea3766;
            etherFiNodes[174] = 0xC17eA5c4304902F5B6C49d930775f59478369Dc5;
            etherFiNodes[175] = 0x4Cb9384E3cc72f9302288f64edadE772d7F2DD06;
            etherFiNodes[176] = 0xcF2FF6Db11f786baf8D6F91A6e8057FCD69C801a;
            etherFiNodes[177] = 0x88d90C63642d04eda97F19B4BBe7b86883EfA3c1;
            etherFiNodes[178] = 0x77820E1593Ae1aF815c142aeD2EF0C0F1152EB88;
            etherFiNodes[179] = 0xcdDAbd28c0407F23C9eF68C1942197218F38AdB5;
            etherFiNodes[180] = 0xC5fed0B686EA5f691e97F3Ff345CD2175ebB3E88;
            etherFiNodes[181] = 0x31b255a927Ddfdc6C965449a86DE5E8f36E5E9e3;
            etherFiNodes[182] = 0x29800021504aa3e678103EB3BEd8AA11406CEa5d;
            etherFiNodes[183] = 0x805aA2570C7BE016B82846F2580789a2e72Ee5ea;
            etherFiNodes[184] = 0x17Ba15473fbA00590aE02699a3CCEBC97EE33fbB;
            etherFiNodes[185] = 0x98d4b1361EA345503A9BC19CC178eE90209a4B15;
            etherFiNodes[186] = 0xCdF5eAEab476C93D391a0Bf388c1E8612Ad574B1;
            etherFiNodes[187] = 0x39460bfA4b5513880bE7bdA00A9E7feF19f04Ff3;
            etherFiNodes[188] = 0x4e0eec3957850A7D63FdDA152f682041D37FA76c;
            etherFiNodes[189] = 0x34e32E3A9feD4502b78754e11ddD77866f1c69b9;
            etherFiNodes[190] = 0xfebC0a4a1f2331684AE05179FAC7F7661D0DB44A;
            etherFiNodes[191] = 0xD9e08AeFA3ADd33435c3a151585a68256055B8d9;
            etherFiNodes[192] = 0xA7f0e245D5FFa2F1E8d9D7345ce0d95d92054b44;
            etherFiNodes[193] = 0x05b1E40339823e1aF30A8ED70c3fBf7F1d0CE9ae;
            etherFiNodes[194] = 0xB11c0a61537EB0728f318b46110961CA1BF358Eb;
            etherFiNodes[195] = 0x475ea9D806E65259416f39dDbe495f8C48B322E1;
            etherFiNodes[196] = 0xDD654528ba46b1693B5a64984AFDbD37d62b2048;
            etherFiNodes[197] = 0xDF684C50866d7BA03d34594D95DE998513283E22;
            etherFiNodes[198] = 0xB842d9775B9dFBfaCCA052a4fA9d31FE9AC15F20;
            etherFiNodes[199] = 0xc0AB5F4e823fC4730980FFC2900614A1aFE5c10F;
            etherFiNodes[200] = 0x1944A786b0f0ed1Df3AB63A580a2d98f87c0321B;
            etherFiNodes[201] = 0x002a6B9AF140CfB18c64D2f9FA4AA464DC3d223E;
            etherFiNodes[202] = 0xC3D3662A44c0d80080D3AF0eea752369c504724e;
            etherFiNodes[203] = 0xc3e25FF9fF6075C06EbB8336aF9324B0Aa58b7e6;
            etherFiNodes[204] = 0xbC582999ec3806F5406005972eba996A72E3c92B;
            etherFiNodes[205] = 0x672633330F42ccdBf4C26d37f253F620f1fa1E9f;
            etherFiNodes[206] = 0xD0e144f5b49C0A0336A460346eBfA6A50F524609;
            etherFiNodes[207] = 0xb9B8D166f2316BC3030A4B509cCE3b71B10A1cB4;
            etherFiNodes[208] = 0x8e512D30E715eea9B1CC71abB679Ab4A1CD87424;
            etherFiNodes[209] = 0x6847c6c2e10d1315A172869C49Eb5c7BbCD9b55A;
            etherFiNodes[210] = 0x72467Bb72D209a92F3606F7881f613Bf1750dD2c;
            etherFiNodes[211] = 0xc5e6CA36b2125Cd77833a54f3B7f3f08B8687677;
            etherFiNodes[212] = 0x542123a1bc8773531c45E03bbD2e29bFa0120b48;
            etherFiNodes[213] = 0x2177938e3a7C45d34C4Af318CA702D18F4a2Ad97;
            etherFiNodes[214] = 0x68B143606a83c746d9f4A409F819366563907b8A;
            etherFiNodes[215] = 0xd7f329A059f157F078c12f2D786c84B82d335a05;
            etherFiNodes[216] = 0x2071AF87c84beCfcC3C5f7449300A1b5c94fc400;
            etherFiNodes[217] = 0xd07b84674318087d74e1A23A38E6da0a16e2a786;
            etherFiNodes[218] = 0x68CF80550DC54624Eac782d192B3389Aea6Bf9DB;
            etherFiNodes[219] = 0xacc67E4eeE02Ef664f0A7795d79e39B9C82CaB5C;
            etherFiNodes[220] = 0x8520926e154F3F28b84466e824f4a04EDB855D68;
            etherFiNodes[221] = 0x350A35A13b2621635bB0E4c991bd4ed6A5822275;
            etherFiNodes[222] = 0xF1D6f5BfD68cD91868ed7288FF458F81D271ecad;
            etherFiNodes[223] = 0x5B5C87ba8e8adD7608fA267b942f88349029CA0a;
            etherFiNodes[224] = 0x3e37F3D19Cd845862064040de7230E6C36C88f62;
            etherFiNodes[225] = 0xbc7cf32D14Aa9485577EA5dbEF775B2a2F8dF450;
            etherFiNodes[226] = 0xfd7B0f4308B43761911A42F2Ca5cb3f45cB01407;
            etherFiNodes[227] = 0xbC379FE95A5BB3a00534d87B63C4DF1621cD6116;
            etherFiNodes[228] = 0xeA68CfFBEaBb690A3a750dF349f244d46a59A7F8;
            etherFiNodes[229] = 0x87BDC90129911f0B85F931E66Db0edCB07D07857;
            etherFiNodes[230] = 0xC34F3Bc719B1148EB782F460540563a21d4EDA89;
            etherFiNodes[231] = 0x8395c2E7C9648C66B9ce434A00890547B8235567;
            etherFiNodes[232] = 0x4cB8996Ca2cD63D075883eB9D2Dc67e1661A5E8d;
            etherFiNodes[233] = 0x5c0b43ED752d7Bcbe9Cf8fBaaB37897d03700859;
            etherFiNodes[234] = 0x33d7989FB8B738BCEC5633666c65CF505ED14E5D;
            etherFiNodes[235] = 0x28f9d3c96b9E3d67F374fB0ce9e654D46BCaD63B;
            etherFiNodes[236] = 0x792d9085e0E28e6d50f87f62c4A37B8322703579;
            etherFiNodes[237] = 0xf1708e88a1C4F71927A8FfCb5D05b1f6A8d1Ec38;
            etherFiNodes[238] = 0x879dD1920cc92934A4e589ab232D5Ab8aE9d4dC9;
            etherFiNodes[239] = 0xE01560fa1CDaAe2aEBb0740980c38b52cc7943e9;
            etherFiNodes[240] = 0x6879a1C36B84DC06684243Ee07eeACB90a16a1D5;
            etherFiNodes[241] = 0x8D0202b60F0Ea5a1BCABA06523B4a35C964Df5E4;
            etherFiNodes[242] = 0x210519Def80BA3D08b792B645001ca60EF33af18;
            etherFiNodes[243] = 0xD6c0ABD82067ceDD41Cd6a949805678d57903993;
            etherFiNodes[244] = 0x8951C5beC5Bd4b6bc83Fe24C4dDB999983ed1D07;
            etherFiNodes[245] = 0xcd6f7A00CF75411b57bB82EC452f1323Da447c81;
            etherFiNodes[246] = 0xA6AD5A5Bf1CDE56CCA1414E4623249f84C460fb6;
            etherFiNodes[247] = 0x4220C994236fdaB61F2Bf344a7F87Dd2853C946a;
            etherFiNodes[248] = 0x4ff137c6627C235ca81Cc0D0441C884e615420e8;
            etherFiNodes[249] = 0x39C1F506E66908AFFA4Df53311e41e7a7FE6aDf1;
            etherFiNodes[250] = 0x8387467591e29C9920DdE5a2b25433deFFfB40FA;
            etherFiNodes[251] = 0x1035B78AC7E1Ba55bBbd41c97574665708a6ef8f;
            etherFiNodes[252] = 0xABABa3B9eC4074A1572968f0e5ade2D783166DF3;
            etherFiNodes[253] = 0xF538AC27909BEed9652B8f008f2246851FdeD09b;
            etherFiNodes[254] = 0x402b223Cea501372ba9a6f257CfA02787be00dC5;
            etherFiNodes[255] = 0xC68fd4290b92EA932cAe7C4bda2f299797cf2e58;
            etherFiNodes[256] = 0xE876fa16d430e55F13C4dd7A6606Fe80d76455fa;
            etherFiNodes[257] = 0xA43A07F802538709F2A4a2692d684dc9Cb2bD209;
            etherFiNodes[258] = 0x94d1f84d0cE6890Ff4670bbD31292B8618B72f88;
            etherFiNodes[259] = 0xcce27C4e3a1D52AfE9e08875cA376003be921892;
            etherFiNodes[260] = 0xAbcF49D29a924C25776a761eE954A423dc466ac6;
            etherFiNodes[261] = 0x60D55f0334Fcf98889030ceDAdf2dA8957545E56;
            etherFiNodes[262] = 0xE913e701c2d1e900F4b0E63A7d80cc971DB28417;
            etherFiNodes[263] = 0xdf271a6F5ED7E28E64851d3C9D5A19acC217803E;
            etherFiNodes[264] = 0x3008dC4BB2c7DCb69c28Dc27b95Bc1E256c12BBE;
            etherFiNodes[265] = 0x779808C61F0B99C95dd2029edC60D9DcF0C8fb7B;
            etherFiNodes[266] = 0x2E2EA2E703C7b338c5c82E00d29A82d0882ccf81;
            etherFiNodes[267] = 0xE9275c8388Af4Bf31494364c52B6c53380120d7A;
            etherFiNodes[268] = 0x61306c865EBbf6543A6EEe68cE3CcB2ef56eE586;
            etherFiNodes[269] = 0x887A188EDFF988e6409DF5c0163A966cda7797Bf;
            etherFiNodes[270] = 0xc62ac4c5aD7d5fd2FF3aD96aCdD630c367BaBE84;
            etherFiNodes[271] = 0x31db9021ec8E1065e1f55553c69e1B1ea9d20533;
            etherFiNodes[272] = 0xfb03AC905e5B739A5f657Fe34b56f61C78fA141d;
            etherFiNodes[273] = 0x0488959c023f8ca753e703a3Ff84d455291Bf340;
            etherFiNodes[274] = 0xfECC3C23865Bf9BE4266CDfd6039CB7F96c88619;
            etherFiNodes[275] = 0x0Fad6411abbb918f98a8783deB0261650fb486E6;
            etherFiNodes[276] = 0xf23A10F3A91Ca1ECbf2AA1aA8A3F46131Dfeee79;
            etherFiNodes[277] = 0x26d5f4B39F4802685fBd617cD2A8CD7c88Df27bD;
            etherFiNodes[278] = 0x0eb949AD35e651A7EEE97f0B56a9B61D373Ad9FF;
            etherFiNodes[279] = 0x5B0a41eE37025F0129b27A8e7a31165ACF562aCC;
            etherFiNodes[280] = 0xf72977De8Eb362b03E4A15aAF28030DB84Fa124c;
            etherFiNodes[281] = 0x64Da61B03f3822F4C177dbA081410a541e9F051D;
            etherFiNodes[282] = 0xC53Bd1F74dd2BA50f8965C49B300d034237A8888;
            etherFiNodes[283] = 0x1f77682673eC85571EfC40D055F40635f7E5e182;
            etherFiNodes[284] = 0x07D27b2bC11e9fc0EC8Ce14570a570B9c60838fD;
            etherFiNodes[285] = 0x9751d9b590b889454193704CD234761acbe0B531;
            etherFiNodes[286] = 0xe2A28b0A9992615AE607c6e0Dc5620D4158AC5CB;
            etherFiNodes[287] = 0x7577099D62442dC0B8521bDC9686C08acc9f804e;
            etherFiNodes[288] = 0xaFfa244FA321457A2919F44bEEf059A5EF86CF08;
            etherFiNodes[289] = 0x859ee23A15039b52230F90306c5529845d5E4806;
            etherFiNodes[290] = 0x32d7eB10Ef44F94035880bf0AB8C10D36840e799;
            etherFiNodes[291] = 0xA449F6062583996ca518BE49F12B5457A2418AE8;
            etherFiNodes[292] = 0x68FCF900D0DAE14c3613875B4F1f43A20aa5ADCD;
            etherFiNodes[293] = 0xEa930A99EFC098B2e92f817712E4deB9ECcF5F15;
            etherFiNodes[294] = 0xF15f97a204B6FaA3259988d5CE9535bFF0197C36;
            etherFiNodes[295] = 0xc217bEadd5fbD27056Da99b6FBf381c139C6F539;
            etherFiNodes[296] = 0x5bBEA8A90cFb577722f093bb59e7807742A16546;
            etherFiNodes[297] = 0xA9F12EFC80B95ad3486b2B0bDeeca8c29c57bD2e;
            etherFiNodes[298] = 0xF832D2C7050E8561f625317db58AdaAd5FEbb972;
            etherFiNodes[299] = 0x8273dFc7565Ba52Ec779D8C6d02eE86E5c708f4B;
            etherFiNodes[300] = 0x828d2f327b985CE817B18DDB6dfCC299ca93A692;
            etherFiNodes[301] = 0xf0c250C8762E7EfCaD5547D83d92694391a05304;
            etherFiNodes[302] = 0xA74969cc2571C93b48E1b3f3330eef187d34c399;
            etherFiNodes[303] = 0xe0e8067A3f0c9D6ec0937c82f1cf7ef9fD3E4ED1;
            etherFiNodes[304] = 0xda963Fc23501BfA83c67D78E445b145debed6A05;
            etherFiNodes[305] = 0xe67d839eE1236bB3a82bB54d8056B736bB695B84;
            etherFiNodes[306] = 0x407E9B6aC58fa4527863985A4C7d71C2B7A3aa64;
            etherFiNodes[307] = 0x4e9910f224089212062b3EC467ad29a74F7C40c6;
            etherFiNodes[308] = 0xCe12a9925e1969E76A01eF4b879095ff42c6d9a9;
            etherFiNodes[309] = 0x869dE7Ab862E6f9b72113deaDD9010C58650Ccc6;
            etherFiNodes[310] = 0xe7F1B968560B33A079a9E5b9805369fBB5D74354;
            etherFiNodes[311] = 0xA0760F9780859a87c9F3968799dEc064Acf57a96;
            etherFiNodes[312] = 0x4Ce8ebe9039c688C4E036B61ee9FDFfF5A79e587;
            etherFiNodes[313] = 0xebAb62bC85B7479802CcF7255beeA2ED34dbA3fa;
            etherFiNodes[314] = 0x82107e0d9F52011B863476eF2a8d19341Cea13d0;
            etherFiNodes[315] = 0xF3c4F6dabbB700282ebD32A682c90d408862c6D3;
            etherFiNodes[316] = 0x16c77161e677731400f9C051CEd5E509eDF8119E;
            etherFiNodes[317] = 0x29Ae07a837A10d781dCD919E0e597F9D67821EB7;
            etherFiNodes[318] = 0x3Af5eD3BD05738407599bb9B17693091061A5C5b;
            etherFiNodes[319] = 0xA62362BeD7365e86Bd5006c2cc5C301D8AD0a795;
            etherFiNodes[320] = 0x1c0039333695f02a89FA1C8437AD97723b76492B;
            etherFiNodes[321] = 0x61d4fAA50061d4256333068B4E710A65EbAE021E;
            etherFiNodes[322] = 0xC916990c7056f1F22d13c06878CF74C96C818B2e;
            etherFiNodes[323] = 0xf3650ee00D54D298C6391642132d26c7E3349bf9;
            etherFiNodes[324] = 0x7d10374Dd4B94018b474A0BacB0322b71B69b6dD;
            etherFiNodes[325] = 0xA7bD07fEfB0951fCde19316305e43d8C52f7f581;
            etherFiNodes[326] = 0x6EC002c55988bD845a7A75E42b7E1341ffd8B848;
            etherFiNodes[327] = 0xE568837534F76D43dF094D324cd34efe95C2FF8E;
            etherFiNodes[328] = 0x899D38eaaA6258207897d16391f78e789337c5E5;
            etherFiNodes[329] = 0x50D79De3F3745B10a60FC49c8026719b86F58C41;
            etherFiNodes[330] = 0x7A6a45794bC109A2fD014c5E8233A0A1fc04FeAa;
            etherFiNodes[331] = 0x13A1D1D89587B6A2027cDE1d941B21DCc8B11071;
            etherFiNodes[332] = 0x9bC0E2bFa9CC3d845c7f9f1cEbA316979E1d90A6;
            etherFiNodes[333] = 0xf163C1592EbC8D3C01c146d95c3ea492b5A88652;
            etherFiNodes[334] = 0xC1F66793397fEB0ED3350e4Cf64D5f9bb94D3F87;
            etherFiNodes[335] = 0x65449AF92B373cCde157a5100e445fC704856D22;
            etherFiNodes[336] = 0x7779Ebb3CE29261FA60d738C3BAB35A05D8d6f65;
            etherFiNodes[337] = 0x92D0F935eCd948E6a8F9af2859425Fdd4977016e;
            etherFiNodes[338] = 0x9026D32C484B95Bf07836B8AF3E3bBF1979b0040;
            etherFiNodes[339] = 0x0B721a934c2336067F387ad067d3b6011C1E086a;
            etherFiNodes[340] = 0x2AfB3d19E893Ef7f8032405a3FB7f77Cb805e620;
            etherFiNodes[341] = 0x83021e9027a8998cfdf9aA5EC4552a74723F62FD;
            etherFiNodes[342] = 0x214D73826833492291Baf91d76383752F43b93a6;
            etherFiNodes[343] = 0x5Fa54461239D8bc28831c0b83bDB8ac196724216;
            etherFiNodes[344] = 0x498Fe6625628053E4F97246161Fab24aEa3DEC36;
            etherFiNodes[345] = 0x5FbE28547E96C7C3CE166F7FD807F2a0A1785D1C;
            etherFiNodes[346] = 0x08498343F166610336A5295f4184aFE341CA87d4;
            etherFiNodes[347] = 0xDBA1e4E75B68400dCEA91F08AC71416E8992D235;
            etherFiNodes[348] = 0xdf467218063Fc712310F3C40e118cB465af8a499;
            etherFiNodes[349] = 0x53E1Eb2fa5EC3C5097E67265E33ea4E53aB61b79;
            etherFiNodes[350] = 0x03ABd0ab82763346Af2F5Cbf0dCFe2944D262BBD;
            etherFiNodes[351] = 0x4bDbB7443d9873C386665Dc009CE575d3cc49875;
            etherFiNodes[352] = 0x324e7B4C997b4bCfC461150C368cBE516aC52155;
            etherFiNodes[353] = 0x4f36C70BBC9AC08Dbf64ec0814483806981C1B11;
            etherFiNodes[354] = 0x128eCd43f6D7bB7dFEF009A4597A508eA33F6a2E;
            etherFiNodes[355] = 0xB94AD22998B357fC52e6ff6bE1024a1846BE6f73;
            etherFiNodes[356] = 0xC30Ee2F14c912b5d2C410f33178024FfD5801Fa8;
            etherFiNodes[357] = 0x4E1bE83EF43043Efc7E1AAd3903C3E10778cB11d;
            etherFiNodes[358] = 0x4E480009b62E229c77dbB23A5310F51c3643863B;
            etherFiNodes[359] = 0x9B2FBc50937d6ED6e4B13B6635A0921685ecf081;
            etherFiNodes[360] = 0x57eD4e7452e5465c5463E7ac12DbC2e8d1a8F5Eb;
            etherFiNodes[361] = 0x58a02D02454b290367DeC5385E8992b4B78f230e;
            etherFiNodes[362] = 0x127adcd683cBc218e0D21f76e10E8dD774d5a322;
            etherFiNodes[363] = 0xeb1f74F0A5F636a28B046a554B9caD8A93729882;
            etherFiNodes[364] = 0xFCa6641dc8348d279386687409fBbd648C633363;
            etherFiNodes[365] = 0xfD4Ff2942e183161a5920749CD5A8B0cFD4164AC;
            etherFiNodes[366] = 0x19c8198eaE8eDDBBeC609eBa8b9cd27d78535b65;
            etherFiNodes[367] = 0x24A2672DEb8A1e237a864b7Ab3Db8fd2E24b786f;
            etherFiNodes[368] = 0xca7437B8a27a5430EC737055A635572f79636A3c;
            etherFiNodes[369] = 0x71dD5dA598A607c771f8Ae6749809B15E9291356;
            etherFiNodes[370] = 0x3E18a98b8B8E58AF9e01C8b0044df598FEc001e9;
            etherFiNodes[371] = 0xf43406A5c68bE9B470cA82BC4801DF82883b812b;
            etherFiNodes[372] = 0x461D7239a28f42e24f31b076c2f4845d880EF5b4;
            etherFiNodes[373] = 0xc28a3888850acEAb69E958fF080d34BC875BD916;
            etherFiNodes[374] = 0xbD0BFF833DE891aDcFF6Ee5502B23f516bECBf6F;
            etherFiNodes[375] = 0xf28F9e613be607F6b04Afc62246C59314644390F;
            etherFiNodes[376] = 0xC5678cdCa4a99e12C942669AdeDea93F9Ee02164;
            etherFiNodes[377] = 0x73DD16E5AAfDB2ac4BC0Ace8bf4685bC9b552390;
            etherFiNodes[378] = 0x5F60C27B0238F0f2a45EDADfAD916047A92DeB4B;
            etherFiNodes[379] = 0x28729b8d61cFc6761bf124c53952beA3Efa91164;
            etherFiNodes[380] = 0xfa57cd342Ba611d29F1E64ac7f8E6f154209eD1B;
            etherFiNodes[381] = 0x502140A6D0FdfFA79d8B5C4248c56C5A839eFe19;
            etherFiNodes[382] = 0x3CBA751AB00b0D51F05173Ff867beBDcc0a2D748;
            etherFiNodes[383] = 0x9Ad4D1CC437fE06341E8d53fAC7B31cbc3990f44;
            etherFiNodes[384] = 0x164B635771D670769743782407c118678875B41D;
            etherFiNodes[385] = 0xF850B602D1D849808aC657E283DFee465CDa2c44;
            etherFiNodes[386] = 0x9335F3c4d0eFDFf9eb5593D94EAd40D3bBd64461;
            etherFiNodes[387] = 0x107B8Ec20163Acd5F4A1024d23B98E17Ee693489;
            etherFiNodes[388] = 0x8c3ED442297996533d47528fe1309e97934d4FD4;
            etherFiNodes[389] = 0xD09047286dE4c45c6aFD8B82e3eEc0328d56cb13;
            etherFiNodes[390] = 0x07f2c0E45ee4A380bF46df2Bf0270243De0498E1;
            etherFiNodes[391] = 0x2aA9fa4fa6243560239C5d1341ed1F0803850a34;
            etherFiNodes[392] = 0x069B5947F9e3b649fc81c6B39C277bC76e565c66;
            etherFiNodes[393] = 0x60aA7075640116412d440f2120DE44Af14a287E0;
            etherFiNodes[394] = 0x2d0E152d228ab28DB832A66f582D2DFb1bc74D21;
            etherFiNodes[395] = 0xde47E4A91c9A89A3dd92Eaf11eE54b721D6C84a9;
            etherFiNodes[396] = 0x1Cd7c7061DE2c6546D61Cf46e26C548d6e2BD7E5;
            etherFiNodes[397] = 0x5C1945a5168D964ae9f0fD21B8F8e8Fe6d7F190e;
            etherFiNodes[398] = 0x3a25000bC93Cc870b8e3b926f0f0C3C6f7e189D3;
            etherFiNodes[399] = 0x9617c80dCd8dBfAAE5Ff31688A04Ba503F50E9b3;
            etherFiNodes[400] = 0xB2E7de426cA4727053398a2C0fA33a1ebFeF01ab;
            etherFiNodes[401] = 0xaA4B27c9fe0E9a45C798BB4da9CA59567A2FFCA0;
            etherFiNodes[402] = 0xBe868540584C3c48d60f818F2686F8a842450cB9;
            etherFiNodes[403] = 0xA90B5E5bd778dfa981d2137E730F9b1054E8B98E;
            etherFiNodes[404] = 0xD6eF53Cb81e3E3C65BfA01b825934aD3a83f0CF0;
            etherFiNodes[405] = 0xCCc267f76c986ba1e0e001Bb12B22afd7C7B064c;
            etherFiNodes[406] = 0xf137C86BFFA768A4710B9131Ac1d624a7D2A439b;
            etherFiNodes[407] = 0x93E3cbF53A118864d886bEEc47851D9d20AfFb1c;
            etherFiNodes[408] = 0x734dd8DE56a74A75335528207eDc8FCD3bB76976;
            etherFiNodes[409] = 0x3cB20C4F4c0B0Df25A10E56E0Ff5f8619D15dd39;
            etherFiNodes[410] = 0xB39C947373D35797a1BB86E14024Cb121E59A12f;
            etherFiNodes[411] = 0x275a898f7E548f706D0c8383007Ba3996FD4AC3E;
            etherFiNodes[412] = 0x6Ee5aF2e75CCCFe283E73d54431d7454400Ccb81;
            etherFiNodes[413] = 0x0A72F682e70F3dc64a3701b684d3Be09FC7A9D3a;
            etherFiNodes[414] = 0xf53437bF4fcC050D0D99e3029eddc14FEe75F38B;
            etherFiNodes[415] = 0x418d22F3a65909668993Ab340e8915d6e8606505;
            etherFiNodes[416] = 0xfef809eE528989e6C9400Fa73f515529F8745175;
            etherFiNodes[417] = 0xb9EA74303041b7de3BD00FCdCD09DA9B53A15D09;
            etherFiNodes[418] = 0x398D41A9Cc2A1aAbEA6AEAA5f6c774028EfC1C9b;
            etherFiNodes[419] = 0xCF6b0aD627319d0bB23B614d5a51506f67C9790A;
            etherFiNodes[420] = 0xBF62CE0EA2B68ed6c6Ca2B7c985120Bcaa215Aa2;
            etherFiNodes[421] = 0xF95D0A565EB865B80Ba8f635a1179cD59e2F62ab;
            etherFiNodes[422] = 0x1f56Cf8ce0161D8bA64F6d1d81c786aa0D2f170D;
            etherFiNodes[423] = 0x00A6c74d55aB9b334d013295579F2B04241555eE;
            etherFiNodes[424] = 0xADe7c2AD832c45e83Fd284DbF189CEDcCb01300C;
            etherFiNodes[425] = 0x53D11983548AC5edEC5Ff0E23ff44C5FcAE829Fe;
            etherFiNodes[426] = 0x438ADF3559bEc3B32D26932dE14B393C11D85E77;
            etherFiNodes[427] = 0x12eE6B0ae0504BCccD431BD2bf5Bf73Bfb6cF1eA;
            etherFiNodes[428] = 0xd620Dc0F53174dC6Fb7199F62c19B7b5bB829d2B;
            etherFiNodes[429] = 0x74B87A389f7fcC468A472370Dc151264D8b32796;
            etherFiNodes[430] = 0x9aA6Ab98105004f841a63369D879584177B728B7;
            etherFiNodes[431] = 0x777e4A759e656153F3e1fd851D56476cD41EebEe;
            etherFiNodes[432] = 0x368478531DC9d603d1F983059A75C5D17d5B1F15;
            etherFiNodes[433] = 0x2EB7190aBA154Ca3607ADe476a5987D8ee27536C;
            etherFiNodes[434] = 0xf18885775216c5F7fdE5178af79D039B16582435;
            etherFiNodes[435] = 0x91C5ea411a41C622801be342B0894ceC34FA17c6;
            etherFiNodes[436] = 0x479D701719347F2Ece907A1D29D9A247b979CA47;
            etherFiNodes[437] = 0xe14d155c24BCbf8edC787e3cB2e3231e14c83165;
            etherFiNodes[438] = 0x792956CF36720AB179F9A4B68Aa43B123d2B6aFB;
            etherFiNodes[439] = 0x0DFaA65c1587355fb92E1Ecb548aeDD4f342913A;
            etherFiNodes[440] = 0x3cB28c01B669a33f413aC83d2ac51eae9502aEc8;
            etherFiNodes[441] = 0x2986DBBdC83138AfeB601c3C9896E5B56adFDC0B;
            etherFiNodes[442] = 0x8aDB2936904C827aDD4856d4B87f55b51ecE9430;
            etherFiNodes[443] = 0xD5C1Ee69f397CafF00C498B5D0c3D1a620fDBe7c;
            etherFiNodes[444] = 0x09FFa5983EBB11e78e8343785A8F0CC32FB89d43;
            etherFiNodes[445] = 0x9739dC2AF4c931E9E52420149c128D891745BD11;
            etherFiNodes[446] = 0x7B9122fe3e7Fb146A45bA141584ED3572261Cb64;
            etherFiNodes[447] = 0xc8F03022851B8f3885D93a05C3e42ad7a6230B2b;
            etherFiNodes[448] = 0xdD110818cA88e5F06dA54a23508751162Dd11EF7;
            etherFiNodes[449] = 0xD3cB3B79315a681e9D53172DFc14540CCb4739f5;
            etherFiNodes[450] = 0xeE973C44bEd87c63bcec8a3642DEA1de9b1660bD;
            etherFiNodes[451] = 0x7309B1ED0187C102eA48Acbb56ED80B90F9890f4;
            etherFiNodes[452] = 0xceb23DA1577bb0c67a1c178AF3E482c3819A9af6;
            etherFiNodes[453] = 0x95D1EFC9c37bDE75cCb805D394ff984609215a80;
            etherFiNodes[454] = 0x8422c6C767DDe85de9FE9100E4076349D09424Bd;
            etherFiNodes[455] = 0x60F97379FC6CF74FE3EaB9c2378c1e4570572Ec1;
            etherFiNodes[456] = 0x985EedfE3E9F5174eE2B9F48BcC6f05Ff1Fc97BD;
            etherFiNodes[457] = 0xff7bbea32130c68EfB3E6eBE4b2cbb8C196F2790;
            etherFiNodes[458] = 0xdd2b96f0e708F2DE5aF69CBad82824330AC182eE;
            etherFiNodes[459] = 0x85d5c42F0719011D7FD1697b040A009cd97dC9Ba;
            etherFiNodes[460] = 0x7092fd2bc738637CBddCDD49423eb91d9d9C70f1;
            etherFiNodes[461] = 0xD3C45138081904B2395433c42cF6834daE8A6A9b;
            etherFiNodes[462] = 0xbF86DC00A97BD980DffE3acF86C99A532f0034c9;
            etherFiNodes[463] = 0xF512794ABEe9c7c22Cd337360a410B4B24Ff57E8;
            etherFiNodes[464] = 0xC51c02d08F47415AA6a89D2Feb4247A3eA56705a;
            etherFiNodes[465] = 0x492f1ABda3efF51eEeBa1a4baC3801Da773AaA0E;
            etherFiNodes[466] = 0x78CD6E25b5D6e77744a11Ab44cF6E3c3867731aD;
            etherFiNodes[467] = 0x7F0Ea3A346a851d72464bd93F864857993e0A1FA;
            etherFiNodes[468] = 0x126f710106f6BeC455F0fBb99cf7D5806eC1468E;
            etherFiNodes[469] = 0x86bB4DfD8093dbbc1dC6952dc5606edd344558BE;
            etherFiNodes[470] = 0xCb28ccD41FD2eCc4c1b51539C4d713eFA913fC4B;
            etherFiNodes[471] = 0x522c853111B2BDcd82b33bD091029C124C218c43;
            etherFiNodes[472] = 0x8354138758db5BD1CB79a237060b9604CdF2c892;
            etherFiNodes[473] = 0x1122441eb62db1232826B6435467d9C0FdE20c45;
            etherFiNodes[474] = 0x6aA7d9D30d38cE75Eb04b0e0e55124F86Fef9130;
            etherFiNodes[475] = 0x98FDf41D1C2ACeB97a6ff8342DC2A95Fe6E0317c;
            etherFiNodes[476] = 0x0Bb9cab8f16753a1DCf16E3520146ab4E324D45E;
            etherFiNodes[477] = 0xF1CFa25d083Aa043924b0d709cb4Ec3C349DDAf0;
            etherFiNodes[478] = 0x405eFa9E551BCb100c098e3104f7A19186C7659f;
            etherFiNodes[479] = 0xC74d4951Fb066DcA8028103407344412D36F1D2d;
            etherFiNodes[480] = 0x4038C16A3a35dF3502199Bd02F86d88573234758;
            etherFiNodes[481] = 0x3b945ED22FCEAd5FfeAfF9D7fA336118221cD0b3;
            etherFiNodes[482] = 0x28adB17D422f603a68F06BaD99B4186eBf40976e;
            etherFiNodes[483] = 0x25d6f80abe41805eE75d3f4444c4c65FF29DB27d;
            etherFiNodes[484] = 0x2d6139fBf41583B7Bf004E648fF3D3534E5B8200;
            etherFiNodes[485] = 0xAfd94E152E5ad6B41A207C736aE90CD639bDC958;
            etherFiNodes[486] = 0x4Dce61dd63de6215A50ba4BDa9B763c0930E793C;
            etherFiNodes[487] = 0x19D8bE2CC9167677bE007E63c71613aF2D0AF752;
            etherFiNodes[488] = 0x568D56CaE9e3C3a0A9D9436E0a117e39cb390368;
            etherFiNodes[489] = 0x3d3124cA9740bBdd46ed2AC943a9a4a3dEAFba4a;
            etherFiNodes[490] = 0xC0f5f83A2edE6092d6BCfee6ff5dE962AeDd2e2E;
            etherFiNodes[491] = 0x0DB8711A0D91CEEaD095F9FF24D603880938d370;
            etherFiNodes[492] = 0x1Ef1B520D6e195F062bC834f8eD2F013004e251c;
            etherFiNodes[493] = 0x9B2400031505bcCaBE3B833f685089Dc82aD7ADa;
            etherFiNodes[494] = 0xD4aD4f4B0B46e24E6fB2418a6912D10ef62080b7;
            etherFiNodes[495] = 0xc5eD912cA6DB7b41De4ef3632Fa0A5641E42BF09;
            etherFiNodes[496] = 0xBA84F3Bcc2d545ce99632bc2854d1616a16d7706;
            etherFiNodes[497] = 0x09be862D29f3CfeB5aF5B2518f000723a219aa11;
            etherFiNodes[498] = 0x0df236685A8bf4bAdf4517859a4bF013E5C0D36D;
            etherFiNodes[499] = 0x8AbB76A605B2537037C68FE9d80FA16912a078f6;
            etherFiNodes[500] = 0x9a60341a33A8946c9D94df66699c0Fba9FcDB3ee;
            etherFiNodes[501] = 0xCdfb5be691F53a8Fb33cf9895F7d20Eda9824C31;
            etherFiNodes[502] = 0xf67a3AbE28f5b80c2a8078a30ed01C27cD9A8FE4;
            etherFiNodes[503] = 0xE6cE3c7A8223Bae86354831e48439c006bd64872;
        }
    }
}
