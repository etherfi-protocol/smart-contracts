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
import "../../src/libraries/DepositDataRootGenerator.sol";
import "../../src/NodeOperatorManager.sol";
import "../../src/AuctionManager.sol";
import "../../src/interfaces/IEtherFiNode.sol";
import "../../src/interfaces/IEtherFiNodesManager.sol";
import "../../src/interfaces/IStakingManager.sol";
import {IEigenPod, IEigenPodTypes} from "../../src/eigenlayer-interfaces/IEigenPod.sol";
import "../../lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "forge-std/Script.sol";
import "forge-std/console2.sol";

// forge script script/validator-key-gen/transactions.s.sol --fork-url $MAINNET_RPC_URL

contract ValidatorKeyGenTransactions is Script {
    EtherFiTimelock etherFiTimelock = EtherFiTimelock(payable(0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761));
    address constant operatingTimelock = 0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a;
    address constant realElExiter = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;

    address constant STAKING_MANAGER_PROXY = 0x25e821b7197B146F7713C3b89B6A4D83516B912d;
    address constant LIQUIDITY_POOL_PROXY = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address constant ETHERFI_NODES_MANAGER_PROXY = 0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F;
    address constant ROLE_REGISTRY = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;
    address constant ETHERFI_RESTAKER_PROXY = 0x1B7a4C3797236A1C37f8741c0Be35c2c72736fFf;
    NodeOperatorManager public constant nodeOperatorManager = NodeOperatorManager(0xd5edf7730ABAd812247F6F54D7bd31a52554e35E);
    AuctionManager public constant auctionManager = AuctionManager(0x00C452aFFee3a17d9Cecc1Bcd2B8d5C7635C4CB9);
    RoleRegistry public constant roleRegistry = RoleRegistry(ROLE_REGISTRY);
    
    //--------------------------------------------------------------------------------------
    //---------------------------- New Deployments -----------------------------------------
    //--------------------------------------------------------------------------------------
    address constant stakingManagerImpl = 0xF73996bceDE56AD090024F2Fd4ca545A3D06c8E3;
    address constant liquidityPoolImpl = 0x4C6767A0afDf06c55DAcb03cB26aaB34Eed281fc;
    address constant etherFiNodesManagerImpl = 0x69B35625A66424cBA28bEd328E1CbFD239714cD7;
    address constant etherFiRestakerImpl = 0x6fDF76c039654f46b9d7e851Fb8135569080C033;

    bytes32 public LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE;
    bytes32 public ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE;
    bytes32 public STAKING_MANAGER_VALIDATOR_INVALIDATOR_ROLE;
    bytes32 public ETHERFI_NODES_MANAGER_EL_CONSOLIDATION_ROLE;
    //--------------------------------------------------------------------------------------
    address constant ETHERFI_OPERATING_ADMIN = 0x2aCA71020De61bb532008049e1Bd41E451aE8AdC;
    address constant UPGRADE_ADMIN = 0xcdd57D11476c22d265722F68390b036f3DA48c21;
    uint256 constant TIMELOCK_MIN_DELAY = 259200; // 72 hours

    LiquidityPool constant liquidityPool = LiquidityPool(payable(LIQUIDITY_POOL_PROXY));
    StakingManager constant stakingManager = StakingManager(STAKING_MANAGER_PROXY);
    EtherFiNodesManager constant etherFiNodesManager = EtherFiNodesManager(ETHERFI_NODES_MANAGER_PROXY);

    function run() public {
        console2.log("================================================");
        console2.log("Running Validator Key Gen Transactions");
        console2.log("================================================");
        console2.log("");

        string memory forkUrl = vm.envString("TENDERLY_TEST_RPC"); // TODO: change to mainnet fork
        vm.selectFork(vm.createFork(forkUrl));

        LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE = LiquidityPool(payable(liquidityPoolImpl)).LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE();
        ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE = EtherFiNodesManager(payable(etherFiNodesManagerImpl)).ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE();
        STAKING_MANAGER_VALIDATOR_INVALIDATOR_ROLE = StakingManager(payable(stakingManagerImpl)).STAKING_MANAGER_VALIDATOR_INVALIDATOR_ROLE();
        ETHERFI_NODES_MANAGER_EL_CONSOLIDATION_ROLE = EtherFiNodesManager(payable(etherFiNodesManagerImpl)).ETHERFI_NODES_MANAGER_EL_CONSOLIDATION_ROLE();

        executeUpgrade();
        forkTestOne();
        forkTestTwo();
    }

    function executeUpgrade() public {
        console2.log("Executing Upgrade");
        console2.log("================================================");

        address[] memory targets = new address[](8);
        bytes[] memory data = new bytes[](8);
        uint256[] memory values = new uint256[](8); // Default to 0
        
        //--------------------------------------------------------------------------------------
        //------------------------------- CONTRACT UPGRADES  -----------------------------------
        //--------------------------------------------------------------------------------------
        targets[0] = STAKING_MANAGER_PROXY;
        data[0] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, stakingManagerImpl);

        targets[1] = LIQUIDITY_POOL_PROXY;
        data[1] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, liquidityPoolImpl);

        targets[2] = ETHERFI_NODES_MANAGER_PROXY;
        data[2] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, etherFiNodesManagerImpl);

        targets[3] = ETHERFI_RESTAKER_PROXY;
        data[3] = abi.encodeWithSelector(UUPSUpgradeable.upgradeTo.selector, etherFiRestakerImpl);
        //--------------------------------------------------------------------------------------
        //---------------------------------- Grant Roles ---------------------------------------
        //--------------------------------------------------------------------------------------

        targets[4] = ROLE_REGISTRY;
        data[4] = _encodeRoleGrant(
            LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE,
            ETHERFI_OPERATING_ADMIN
        );
        targets[5] = ROLE_REGISTRY;
        data[5] = _encodeRoleGrant(
            ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE,
            address(stakingManager)
        );
        targets[6] = ROLE_REGISTRY;
        data[6] = _encodeRoleGrant(
            STAKING_MANAGER_VALIDATOR_INVALIDATOR_ROLE,
            realElExiter
        );
        targets[7] = ROLE_REGISTRY;
        data[7] = _encodeRoleGrant(
            ETHERFI_NODES_MANAGER_EL_CONSOLIDATION_ROLE,
            realElExiter
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

    function forkTestOne() public {
        vm.prank(auctionManager.owner());
        auctionManager.updateAdmin(ETHERFI_OPERATING_ADMIN, true);

        address spawner = vm.addr(0x1234);
        
        vm.prank(ETHERFI_OPERATING_ADMIN);
        nodeOperatorManager.addToWhitelist(spawner);

        vm.prank(operatingTimelock);
        liquidityPool.registerValidatorSpawner(spawner);

        vm.deal(spawner, 100 ether);
        vm.prank(spawner);
        nodeOperatorManager.registerNodeOperator("ipfs_hash", 1000);

        vm.prank(spawner);
        uint256[] memory createdBids = auctionManager.createBid{value: 0.1 ether}(1, 0.1 ether);

        (bytes memory pubkey, bytes memory signature, bytes memory withdrawalCredentials, bytes32 depositDataRoot, IStakingManager.DepositData memory depositData, address etherFiNode) = helper_getDataForValidatorKeyGen();

        IStakingManager.DepositData[] memory depositDataArray = new IStakingManager.DepositData[](1);
        depositDataArray[0] = depositData;

        vm.prank(spawner);
        liquidityPool.batchRegister(depositDataArray, createdBids, etherFiNode);

        // Verify validator status is REGISTERED
        bytes32 validatorHash = keccak256(abi.encode(
            depositData.publicKey,
            depositData.signature,
            depositData.depositDataRoot,
            depositData.ipfsHashForEncryptedValidatorKey,
            createdBids[0],
            etherFiNode
        ));
        
        require(uint8(stakingManager.validatorCreationStatus(validatorHash)) == uint8(IStakingManager.ValidatorCreationStatus.REGISTERED), "Validator status is not REGISTERED");
    
        console2.log("Forking Test completed successfully");
        console2.log("================================================");
        console2.log("");
    }

    function forkTestTwo() public {
        bytes memory PK_80143 = hex"811cd0bb7dd301afbbddd1d5db15ff0ca9d5f8ada78c0b1223f75b524aca1ca9ff1ba205d9efd7c37c2174576cc123e2";
        bytes memory PK_80194 = hex"b86cb11d564b29a38cdc8a3f1f9c35e6dcd2d0f85f40da60f745e479ba42b4548c83a2b049cf02277fceaa9b421d0039";
        bytes memory PK_89936 = hex"b8786ec7945d737698e374193f05a5498e932e2941263a7842837e9e3fac033af285e53a90afecf994585d178b5eedaa";
        require(roleRegistry.hasRole(ETHERFI_NODES_MANAGER_EL_CONSOLIDATION_ROLE, realElExiter), "realElExiter does not have ETHERFI_NODES_MANAGER_EL_CONSOLIDATION_ROLE");

        bytes[] memory pubkeys = new bytes[](3);
        pubkeys[0] = PK_80143;
        pubkeys[1] = PK_80194;
        pubkeys[2] = PK_89936;

        bytes[] memory pubkeysonlyOneValidator = new bytes[](1);
        uint256[] memory legacyIdsonlyOneValidator = new uint256[](1);
        pubkeysonlyOneValidator[0] = PK_80143;
        legacyIdsonlyOneValidator[0] = 80143;

        // Link legacy validator id (requires admin role, so use timelock)
        vm.prank(operatingTimelock);
        etherFiNodesManager.linkLegacyValidatorIds(legacyIdsonlyOneValidator, pubkeysonlyOneValidator);
        vm.stopPrank();
        console2.log("Linking legacy validator ids complete");

        bytes32 pkHash = etherFiNodesManager.calculateValidatorPubkeyHash(pubkeys[0]);
        IEtherFiNode etherFiNode = etherFiNodesManager.etherFiNodeFromPubkeyHash(pkHash);
        IEigenPod pod = etherFiNode.getEigenPod();
        require(address(pod) != address(0), "test: node has no pod");

        IEigenPodTypes.ConsolidationRequest[] memory reqs = new IEigenPodTypes.ConsolidationRequest[](3);
        reqs[0] = IEigenPodTypes.ConsolidationRequest({
            srcPubkey: pubkeys[0],
            targetPubkey: pubkeys[0]
        });
        reqs[1] = IEigenPodTypes.ConsolidationRequest({
            srcPubkey: pubkeys[1],
            targetPubkey: pubkeys[0]
        });
        reqs[2] = IEigenPodTypes.ConsolidationRequest({
            srcPubkey: pubkeys[2],
            targetPubkey: pubkeys[0]
        });

        uint256 feePer = pod.getConsolidationRequestFee();
        uint256 n = reqs.length;
        uint256 valueToSend = feePer * n;

        // Fund the EOA with enough ETH to pay consolidation fees
        vm.deal(realElExiter, valueToSend + 1 ether);

        // Test that EOA can successfully call requestConsolidation
        vm.expectEmit(true, true, true, true, address(etherFiNodesManager));
        emit IEtherFiNodesManager.ValidatorSwitchToCompoundingRequested(
            address(pod),
            etherFiNodesManager.calculateValidatorPubkeyHash(pubkeys[0]),
            pubkeys[0]
        );
        vm.prank(realElExiter);
        etherFiNodesManager.requestConsolidation{value: valueToSend}(reqs);
        
        console2.log("EOA successfully requested consolidation");
        console2.log("================================================");
        console2.log("");
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

    function helper_getDataForValidatorKeyGen() public returns (bytes memory pubkey, bytes memory signature, bytes memory withdrawalCredentials, bytes32 depositDataRoot, IStakingManager.DepositData memory depositData, address etherFiNode) {
        pubkey = vm.randomBytes(48);
        signature = vm.randomBytes(96);

        vm.prank(operatingTimelock);
        etherFiNode = stakingManager.instantiateEtherFiNode(true /*createEigenPod*/);
        address eigenPod = address(IEtherFiNode(etherFiNode).getEigenPod());

        withdrawalCredentials = etherFiNodesManager.addressToCompoundingWithdrawalCredentials(eigenPod);
        depositDataRoot = depositDataRootGenerator.generateDepositDataRoot(pubkey, signature, withdrawalCredentials, 1 ether);
        depositData = IStakingManager.DepositData({
            publicKey: pubkey, signature: signature, depositDataRoot: depositDataRoot, ipfsHashForEncryptedValidatorKey: "test_ipfs_hash"
        });

        return (pubkey, signature, withdrawalCredentials, depositDataRoot, depositData, etherFiNode);
    }
}