// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import "../../test/common/ArrayTestHelper.sol";

import "../../src/libraries/DepositDataRootGenerator.sol";

import "../../src/interfaces/IStakingManager.sol";
import "../../src/interfaces/IEtherFiNode.sol";

import "../../src/StakingManager.sol";
import "../../src/LiquidityPool.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/EtherFiNode.sol";
import "../../src/NodeOperatorManager.sol";
import "../../src/AuctionManager.sol";
import "../../src/RoleRegistry.sol";

contract ValidatorKeyGenTest is Test, ArrayTestHelper {
    StakingManager public constant stakingManager = StakingManager(0x25e821b7197B146F7713C3b89B6A4D83516B912d);
    EtherFiNodesManager public constant etherFiNodesManager = EtherFiNodesManager(0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F);
    EtherFiNode public constant etherFiNodeBeacon = EtherFiNode(payable(0x3c55986Cfee455E2533F4D29006634EcF9B7c03F));
    LiquidityPool public constant liquidityPool = LiquidityPool(payable(0x308861A430be4cce5502d0A12724771Fc6DaF216));
    NodeOperatorManager public constant nodeOperatorManager = NodeOperatorManager(0xd5edf7730ABAd812247F6F54D7bd31a52554e35E);
    AuctionManager public constant auctionManager = AuctionManager(0x00C452aFFee3a17d9Cecc1Bcd2B8d5C7635C4CB9);
    RoleRegistry public constant roleRegistry = RoleRegistry(0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9);

    address public constant stakingDepositContract = address(0x00000000219ab540356cBB839Cbe05303d7705Fa);

    address public constant admin = 0x2aCA71020De61bb532008049e1Bd41E451aE8AdC;
    address public constant stakingManagerNodeCreatorRoleHolder = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;
    address public constant operatingTimelock = 0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a;
    address public constant timelock = 0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761;

    address public tom = vm.addr(0x9999999);

    function setUp() public {
        vm.selectFork(vm.createFork(vm.envString("MAINNET_RPC_URL")));
        vm.deal(tom, 100 ether);

        StakingManager stakingManagerImpl = new StakingManager(
            address(liquidityPool),
            address(etherFiNodesManager),
            address(stakingDepositContract),
            address(auctionManager),
            address(etherFiNodeBeacon),
            address(roleRegistry)
        );
        vm.prank(stakingManager.owner());
        stakingManager.upgradeTo(address(stakingManagerImpl));

        LiquidityPool liquidityPoolImpl = new LiquidityPool();
        vm.prank(liquidityPool.owner());
        liquidityPool.upgradeTo(address(liquidityPoolImpl));

        vm.startPrank(roleRegistry.owner());
        roleRegistry.grantRole(liquidityPool.LIQUIDITY_POOL_VALIDATOR_CREATOR_ROLE(), admin);
        roleRegistry.grantRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE(), address(stakingManager));
        auctionManager.updateAdmin(admin, true);
        vm.stopPrank();
    }

    function helper_getDataForValidatorKeyGen() internal returns (bytes memory pubkey, bytes memory signature, bytes memory withdrawalCredentials, bytes32 depositDataRoot, IStakingManager.DepositData memory depositData, address etherFiNode) {
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

    function test_liquidityPool_newFlow() public {
        // STEP 1: Whitelist the user
        vm.prank(admin);
        nodeOperatorManager.addToWhitelist(tom);

        // STEP 2: Get the data for the validator key gen
        (bytes memory pubkey, bytes memory signature, bytes memory withdrawalCredentials, bytes32 depositDataRoot, StakingManager.DepositData memory depositData, address etherFiNode) = helper_getDataForValidatorKeyGen();

        // STEP 3: Register the node operator and create the bid
        vm.deal(tom, 100 ether);

        vm.startPrank(tom);
        nodeOperatorManager.registerNodeOperator("test_ipfs_hash", 1000);
        uint256[] memory bidId1 = auctionManager.createBid{value: 0.1 ether}(1, 0.1 ether);
        vm.stopPrank();

        // STEP 4: Register the validator spawner and batch register the validator
        vm.prank(operatingTimelock);
        liquidityPool.registerValidatorSpawner(tom);

        vm.prank(tom);
        liquidityPool.batchRegister(toArray(depositData), toArray_u256(bidId1[0]), etherFiNode);
        assertEq(uint8(stakingManager.validatorCreationStatus(keccak256(abi.encodePacked(depositData.publicKey, depositData.signature, depositData.depositDataRoot, depositData.ipfsHashForEncryptedValidatorKey, bidId1[0], etherFiNode)))), uint8(IStakingManager.ValidatorCreationStatus.REGISTERED));

        // STEP 5: Confirm the validator
        vm.prank(admin);
        liquidityPool.batchCreateBeaconValidators(toArray(depositData), toArray_u256(bidId1[0]), etherFiNode);
        assertEq(uint8(stakingManager.validatorCreationStatus(keccak256(abi.encodePacked(depositData.publicKey, depositData.signature, depositData.depositDataRoot, depositData.ipfsHashForEncryptedValidatorKey, bidId1[0], etherFiNode)))), uint8(IStakingManager.ValidatorCreationStatus.CONFIRMED));
    }

    function test_batchRegister_revertsWhenNotRegisteredSpawner() public {
        address unregisteredUser = vm.addr(0xDEAD);
        
        // Get the data for the validator key gen
        (bytes memory pubkey, bytes memory signature, bytes memory withdrawalCredentials, bytes32 depositDataRoot, IStakingManager.DepositData memory depositData, address etherFiNode) = helper_getDataForValidatorKeyGen();

        IStakingManager.DepositData[] memory depositDataArray = new IStakingManager.DepositData[](1);
        depositDataArray[0] = depositData;

        uint256[] memory bidIds = new uint256[](1);
        bidIds[0] = 1; 

        vm.prank(unregisteredUser);
        vm.expectRevert("Incorrect Caller");
        liquidityPool.batchRegister(depositDataArray, bidIds, etherFiNode);
    }

    function test_batchRegister_revertsWhenPaused() public {
        address spawner = vm.addr(0x1234);
        
        // Setup spawner
        vm.prank(operatingTimelock);
        liquidityPool.registerValidatorSpawner(spawner);

        // Get the data for the validator key gen
        (bytes memory pubkey, bytes memory signature, bytes memory withdrawalCredentials, bytes32 depositDataRoot, IStakingManager.DepositData memory depositData, address etherFiNode) = helper_getDataForValidatorKeyGen();

        IStakingManager.DepositData[] memory depositDataArray = new IStakingManager.DepositData[](1);
        depositDataArray[0] = depositData;

        uint256[] memory bidIds = new uint256[](1);
        bidIds[0] = 1; 

        // Pause contract
        vm.prank(admin);
        liquidityPool.pauseContract();

        vm.prank(spawner);
        vm.expectRevert("Pausable: paused");
        liquidityPool.batchRegister(depositDataArray, bidIds, etherFiNode);
    }

    function test_batchRegister_revertsWhenInvalidEtherFiNode() public {
        address spawner = vm.addr(0x1234);
        bytes memory pubkey = vm.randomBytes(48);
        bytes memory signature = vm.randomBytes(96);

        vm.prank(admin);
        nodeOperatorManager.addToWhitelist(spawner);

        vm.prank(operatingTimelock);
        liquidityPool.registerValidatorSpawner(spawner);

        address invalidNode = address(0xDEAD); // wrong contract address
        
        bytes32 depositRoot = depositDataRootGenerator.generateDepositDataRoot(
            pubkey,
            signature,
            bytes(""),
            1 ether
        );

        IStakingManager.DepositData[] memory depositData = new IStakingManager.DepositData[](1);
        depositData[0] = IStakingManager.DepositData({
            publicKey: pubkey,
            signature: signature,
            depositDataRoot: depositRoot,
            ipfsHashForEncryptedValidatorKey: "test_ipfs"
        });

        uint256[] memory bidIds = new uint256[](1);
        bidIds[0] = 1; 

        vm.prank(spawner);
        vm.expectRevert("call to non-contract address 0x000000000000000000000000000000000000dEaD");
        liquidityPool.batchRegister(depositData, bidIds, invalidNode);
    }

    function test_batchRegister_revertsWhenArrayLengthMismatch() public {
        address spawner = vm.addr(0x1234);
        
        vm.prank(operatingTimelock);
        liquidityPool.registerValidatorSpawner(spawner);

        // Get the data for the validator key gen
        (bytes memory pubkey, bytes memory signature, bytes memory withdrawalCredentials, bytes32 depositDataRoot, IStakingManager.DepositData memory depositData, address etherFiNode) = helper_getDataForValidatorKeyGen();

        // Array length mismatch: 1 depositData but 2 bidIds
        IStakingManager.DepositData[] memory depositDataArray = new IStakingManager.DepositData[](1);
        depositDataArray[0] = depositData;

        uint256[] memory bidIds = new uint256[](2);
        bidIds[0] = 1;
        bidIds[1] = 2;

        vm.prank(spawner);
        vm.expectRevert(IStakingManager.InvalidDepositData.selector);
        liquidityPool.batchRegister(depositDataArray, bidIds, etherFiNode);
    }

    function test_batchRegister_revertsWhenBidNotActive() public {
        address spawner = vm.addr(0x1234);
        
        vm.prank(admin);
        nodeOperatorManager.addToWhitelist(spawner);

        vm.prank(operatingTimelock);
        liquidityPool.registerValidatorSpawner(spawner);

        // Register node operator and create bid
        vm.deal(spawner, 100 ether);
        vm.prank(spawner);
        nodeOperatorManager.registerNodeOperator("ipfs_hash", 1000);

        vm.prank(spawner);
        uint256[] memory createdBids = auctionManager.createBid{value: 0.1 ether}(1, 0.1 ether);

        // Cancel the bid to make it inactive
        vm.prank(spawner);
        auctionManager.cancelBid(createdBids[0]);

        // Get the data for the validator key gen
        (bytes memory pubkey, bytes memory signature, bytes memory withdrawalCredentials, bytes32 depositDataRoot, IStakingManager.DepositData memory depositData, address etherFiNode) = helper_getDataForValidatorKeyGen();

        IStakingManager.DepositData[] memory depositDataArray = new IStakingManager.DepositData[](1);
        depositDataArray[0] = depositData;

        vm.prank(spawner);
        vm.expectRevert(IStakingManager.InactiveBid.selector);
        liquidityPool.batchRegister(depositDataArray, createdBids, etherFiNode);
    }

    function test_batchRegister_revertsWhenIncorrectDepositDataRoot() public {
        address spawner = vm.addr(0x1234);
        
        vm.prank(admin);
        nodeOperatorManager.addToWhitelist(spawner);

        vm.prank(operatingTimelock);
        liquidityPool.registerValidatorSpawner(spawner);

        vm.deal(spawner, 100 ether);
        vm.prank(spawner);
        nodeOperatorManager.registerNodeOperator("ipfs_hash", 1000);

        vm.prank(spawner);
        uint256[] memory createdBids = auctionManager.createBid{value: 0.1 ether}(1, 0.1 ether);

        // Get the data for the validator key gen
        (bytes memory pubkey, bytes memory signature, bytes memory withdrawalCredentials, bytes32 depositDataRoot, IStakingManager.DepositData memory depositData, address etherFiNode) = helper_getDataForValidatorKeyGen();

        // Use incorrect deposit data root
        bytes32 incorrectRoot = keccak256("incorrect");

        IStakingManager.DepositData[] memory depositDataArray = new IStakingManager.DepositData[](1);
        depositDataArray[0] = IStakingManager.DepositData({
            publicKey: pubkey,
            signature: signature,
            depositDataRoot: incorrectRoot,
            ipfsHashForEncryptedValidatorKey: depositData.ipfsHashForEncryptedValidatorKey
        });

        vm.prank(spawner);
        // Will revert due to incorrect deposit data root
        vm.expectRevert(IStakingManager.IncorrectBeaconRoot.selector);
        liquidityPool.batchRegister(depositDataArray, createdBids, etherFiNode);
    }

    function test_batchRegister_succeeds() public {
        address spawner = vm.addr(0x1234);
        
        vm.prank(admin);
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
        bytes32 validatorHash = keccak256(abi.encodePacked(
            depositData.publicKey,
            depositData.signature,
            depositData.depositDataRoot,
            depositData.ipfsHashForEncryptedValidatorKey,
            createdBids[0],
            etherFiNode
        ));
        
        assertEq(
            uint8(stakingManager.validatorCreationStatus(validatorHash)),
            uint8(IStakingManager.ValidatorCreationStatus.REGISTERED)
        );
    }

    // ==================== batchCreateBeaconValidators Tests ====================

    function test_batchCreateBeaconValidators_revertsWhenNoRole() public {
        address unauthorizedUser = vm.addr(0xDEAD);
        
        (bytes memory pubkey, bytes memory signature, bytes memory withdrawalCredentials, bytes32 depositDataRoot, IStakingManager.DepositData memory depositData, address etherFiNode) = helper_getDataForValidatorKeyGen();

        IStakingManager.DepositData[] memory depositDataArray = new IStakingManager.DepositData[](1);
        depositDataArray[0] = depositData;

        uint256[] memory bidIds = new uint256[](1);
        bidIds[0] = 1; 

        vm.prank(unauthorizedUser);
        vm.expectRevert(LiquidityPool.IncorrectRole.selector);
        liquidityPool.batchCreateBeaconValidators(depositDataArray, bidIds, etherFiNode);
    }

    function test_batchCreateBeaconValidators_revertsWhenPaused() public {
        (bytes memory pubkey, bytes memory signature, bytes memory withdrawalCredentials, bytes32 depositDataRoot, IStakingManager.DepositData memory depositData, address etherFiNode) = helper_getDataForValidatorKeyGen();

        IStakingManager.DepositData[] memory depositDataArray = new IStakingManager.DepositData[](1);
        depositDataArray[0] = depositData;

        uint256[] memory bidIds = new uint256[](1);
        bidIds[0] = 1; 

        // Pause contract
        vm.prank(admin);
        liquidityPool.pauseContract();

        vm.prank(admin);
        vm.expectRevert("Pausable: paused");
        liquidityPool.batchCreateBeaconValidators(depositDataArray, bidIds, etherFiNode);
    }

    function test_batchCreateBeaconValidators_revertsWhenNotRegisteredValidator() public {
        // Get the data for the validator key gen
        (bytes memory pubkey, bytes memory signature, bytes memory withdrawalCredentials, bytes32 depositDataRoot, IStakingManager.DepositData memory depositData, address etherFiNode) = helper_getDataForValidatorKeyGen();

        IStakingManager.DepositData[] memory depositDataArray = new IStakingManager.DepositData[](1);
        depositDataArray[0] = depositData;

        // Use non-existent bid ID (validator not registered)
        uint256[] memory bidIds = new uint256[](1);
        bidIds[0] = 999999;

        vm.deal(address(liquidityPool), 100 ether);

        vm.prank(admin);
        // Will revert because validator is not in REGISTERED status
        vm.expectRevert(IStakingManager.InvalidValidatorCreationStatus.selector);
        liquidityPool.batchCreateBeaconValidators(depositDataArray, bidIds, etherFiNode);
    }

    function test_batchCreateBeaconValidators_revertsWhenEmptyArrays() public {
        // Get the data for the validator key gen (just need etherFiNode)
        (,,, , , address etherFiNode) = helper_getDataForValidatorKeyGen();

        IStakingManager.DepositData[] memory depositData = new IStakingManager.DepositData[](0);
        uint256[] memory bidIds = new uint256[](0);

        vm.prank(admin);
        // Empty arrays are valid - function completes successfully (no revert)
        // The loop in createBeaconValidators doesn't execute when length is 0
        liquidityPool.batchCreateBeaconValidators(depositData, bidIds, etherFiNode);
    }

    function test_batchCreateBeaconValidators_succeeds() public {
        address spawner = vm.addr(0x1234);
        
        vm.prank(admin);
        nodeOperatorManager.addToWhitelist(spawner);

        // Setup spawner and register validator first
        vm.prank(operatingTimelock);
        liquidityPool.registerValidatorSpawner(spawner);

        vm.deal(spawner, 100 ether);
        vm.prank(spawner);  
        nodeOperatorManager.registerNodeOperator("ipfs_hash", 1000);

        vm.prank(spawner);
        uint256[] memory createdBids = auctionManager.createBid{value: 0.1 ether}(1, 0.1 ether);

        // Get the data for the validator key gen
        (bytes memory pubkey, bytes memory signature, bytes memory withdrawalCredentials, bytes32 depositDataRoot, IStakingManager.DepositData memory depositData, address etherFiNode) = helper_getDataForValidatorKeyGen();

        IStakingManager.DepositData[] memory depositDataArray = new IStakingManager.DepositData[](1);
        depositDataArray[0] = depositData;

        // Register first
        vm.prank(spawner);
        liquidityPool.batchRegister(depositDataArray, createdBids, etherFiNode);

        // Fund LP with sufficient ETH (1 ether per validator)
        vm.deal(address(liquidityPool), 100 ether);

        // Now create validators
        vm.prank(admin);
        liquidityPool.batchCreateBeaconValidators(depositDataArray, createdBids, etherFiNode);

        // Verify validator status is CONFIRMED
        bytes32 validatorHash = keccak256(abi.encodePacked(
            depositData.publicKey,
            depositData.signature,
            depositData.depositDataRoot,
            depositData.ipfsHashForEncryptedValidatorKey,
            createdBids[0],
            etherFiNode
        ));
        
        assertEq(
            uint8(stakingManager.validatorCreationStatus(validatorHash)),
            uint8(IStakingManager.ValidatorCreationStatus.CONFIRMED)
        );
    }

    function test_batchCreateBeaconValidators_accountsForEthCorrectly() public {
        address spawner = vm.addr(0x1234);
        
        vm.prank(admin);
        nodeOperatorManager.addToWhitelist(spawner);

        vm.prank(operatingTimelock);
        liquidityPool.registerValidatorSpawner(spawner);

        vm.deal(spawner, 100 ether);
        vm.prank(spawner);
        nodeOperatorManager.registerNodeOperator("ipfs_hash", 1000);

        vm.prank(spawner);
        uint256[] memory createdBids = auctionManager.createBid{value: 0.1 ether}(1, 0.1 ether);

        // Get the data for the validator key gen
        (bytes memory pubkey, bytes memory signature, bytes memory withdrawalCredentials, bytes32 depositDataRoot, IStakingManager.DepositData memory depositData, address etherFiNode) = helper_getDataForValidatorKeyGen();

        IStakingManager.DepositData[] memory depositDataArray = new IStakingManager.DepositData[](1);
        depositDataArray[0] = depositData;

        vm.prank(spawner);
        liquidityPool.batchRegister(depositDataArray, createdBids, etherFiNode);

        // Record initial balances
        uint128 initialTotalOut = liquidityPool.totalValueOutOfLp();
        uint128 initialTotalIn = liquidityPool.totalValueInLp();

        vm.deal(address(liquidityPool), 100 ether);

        uint256 expectedEthOut = 1 ether; // 1 ether per validator

        vm.prank(admin);
        liquidityPool.batchCreateBeaconValidators(depositDataArray, createdBids, etherFiNode);

        // Verify accounting
        assertEq(
            liquidityPool.totalValueOutOfLp(),
            initialTotalOut + uint128(expectedEthOut)
        );
        assertEq(
            liquidityPool.totalValueInLp(),
            initialTotalIn - uint128(expectedEthOut)
        );
    }

    function test_batchCreateBeaconValidators_withMultipleValidators() public {
        address spawner = vm.addr(0x1234);
        
        vm.prank(admin);
        nodeOperatorManager.addToWhitelist(spawner);

        vm.prank(operatingTimelock);
        liquidityPool.registerValidatorSpawner(spawner);

        vm.deal(spawner, 100 ether);
        vm.prank(spawner);
        nodeOperatorManager.registerNodeOperator("ipfs_hash", 1000);

        // Create 3 bids
        vm.prank(spawner);
        uint256[] memory createdBids = auctionManager.createBid{value: 0.3 ether}(3, 0.1 ether);

        vm.prank(operatingTimelock);
        address etherFiNode = stakingManager.instantiateEtherFiNode(true);

        address eigenPod = address(IEtherFiNode(etherFiNode).getEigenPod());
        bytes memory withdrawalCreds = etherFiNodesManager.addressToCompoundingWithdrawalCredentials(eigenPod);

        // Create deposit data for 3 validators
        IStakingManager.DepositData[] memory depositData = new IStakingManager.DepositData[](3);
        for (uint256 i = 0; i < 3; i++) {
            bytes memory pubkey = vm.randomBytes(48);
            bytes memory signature = vm.randomBytes(96);
            bytes32 depositRoot = depositDataRootGenerator.generateDepositDataRoot(
                pubkey,
                signature,
                withdrawalCreds,
                stakingManager.initialDepositAmount()
            );

            depositData[i] = IStakingManager.DepositData({
                publicKey: pubkey,
                signature: signature,
                depositDataRoot: depositRoot,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });
        }

        // Register all
        vm.prank(spawner);
        liquidityPool.batchRegister(depositData, createdBids, etherFiNode);

        vm.deal(address(liquidityPool), 100 ether);

        // Create all validators - should require 3 ether
        vm.prank(admin);
        liquidityPool.batchCreateBeaconValidators(depositData, createdBids, etherFiNode);

        // Verify all are confirmed
        for (uint256 i = 0; i < 3; i++) {
            bytes32 validatorHash = keccak256(abi.encodePacked(
                depositData[i].publicKey,
                depositData[i].signature,
                depositData[i].depositDataRoot,
                depositData[i].ipfsHashForEncryptedValidatorKey,
                createdBids[i],
                etherFiNode
            ));
            
            assertEq(
                uint8(stakingManager.validatorCreationStatus(validatorHash)),
                uint8(IStakingManager.ValidatorCreationStatus.CONFIRMED)
            );
        }
    }
}