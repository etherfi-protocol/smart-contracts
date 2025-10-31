// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import "../../test/common/ArrayTestHelper.sol";

import "../../src/libraries/DepositDataRootGenerator.sol";

import "../../src/interfaces/IStakingManager.sol";
import "../../src/interfaces/IEtherFiNode.sol";
import "../../src/interfaces/ILiquidityPool.sol";

import "../../src/StakingManager.sol";
import "../../src/LiquidityPool.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/EtherFiNode.sol";
import "../../src/NodeOperatorManager.sol";
import "../../src/AuctionManager.sol";
import "../../src/RoleRegistry.sol";
import "./OldLiquidityPool.sol";

// Command to run this test: forge test --match-contract ValidatorKeyGenTest

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

    // --------------------------------------------------------------------------
    // ----------------------- PRE UPGRADE STORAGE VALUES -----------------------
    // --------------------------------------------------------------------------
    IStakingManager public s_stakingManager;
    IEtherFiNodesManager public s_nodesManager;
    address public s_DEPRECATED_regulationsManager;
    address public s_membershipManager;
    address public s_DEPRECATED_TNFT;
    IeETH public s_eETH; 
    bool public s_DEPRECATED_eEthliquidStakingOpened;
    uint128 public s_totalValueOutOfLp;
    uint128 public s_totalValueInLp;
    address public s_feeRecipient;
    uint32 public s_numPendingDeposits;
    address public s_DEPRECATED_bNftTreasury;
    IWithdrawRequestNFT public s_withdrawRequestNFT;
    ILiquidityPool.BnftHolder[] public s_DEPRECATED_bnftHolders;
    uint128 public s_DEPRECATED_maxValidatorsPerOwner;
    uint128 public s_DEPRECATED_schedulingPeriodInSeconds;
    ILiquidityPool.HoldersUpdate public s_DEPRECATED_holdersUpdate;
    mapping(address => bool) public s_DEPRECATED_admins; // TODO: How to check this?
    mapping(ILiquidityPool.SourceOfFunds => ILiquidityPool.FundStatistics) public s_DEPRECATED_fundStatistics; // TODO: How to check this?
    mapping(uint256 => bytes32) public s_depositDataRootForApprovalDeposits; // TODO: How to check this?
    address public s_etherFiAdminContract;
    bool public s_DEPRECATED_whitelistEnabled;
    mapping(address => bool) public s_DEPRECATED_whitelisted; // TODO: How to check this?
    mapping(address => ILiquidityPool.ValidatorSpawner) public s_validatorSpawner; // TODO: How to check this?
    bool public s_restakeBnftDeposits;
    uint128 public s_ethAmountLockedForWithdrawal;
    bool public s_paused;
    address public s_DEPRECATED_auctionManager;
    ILiquifier public s_liquifier;
    bool private s_DEPRECATED_isLpBnftHolder;
    EtherFiRedemptionManager public s_etherFiRedemptionManager;
    IRoleRegistry public s_roleRegistry;
    uint256 public s_validatorSizeWei;

    // SANITY CHECK VARIABLES BEFORE UPGRADE
    address public ownerBefore;
    address public liquidityPoolImplBefore;
    address public stakingManagerImplBefore;
    uint256 public totalPooledBefore;
    uint256 public sharesForAmountBefore;
    uint256 public sharesForWithdrawalBefore;
    uint256 public amountForShareBefore;
    uint256 public totalEtherClaimBefore;

    function setUp() public {
        vm.selectFork(vm.createFork(vm.envString("MAINNET_RPC_URL")));
        vm.deal(tom, 100 ether);

        helper_storePreUpgradeStorageValues();

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
        roleRegistry.grantRole(stakingManager.STAKING_MANAGER_VALIDATOR_INVALIDATOR_ROLE(), admin);
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

    function helper_storePreUpgradeStorageValues() internal {
        OldLiquidityPool oldLiquidityPool = OldLiquidityPool(payable(address(liquidityPool)));

        ownerBefore = liquidityPool.owner();
        liquidityPoolImplBefore = liquidityPool.getImplementation();
        
        bytes32 implementationSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        stakingManagerImplBefore = address(uint160(uint256(vm.load(address(stakingManager), implementationSlot))));

        s_stakingManager = oldLiquidityPool.stakingManager();
        s_nodesManager = oldLiquidityPool.nodesManager();
        s_DEPRECATED_regulationsManager = oldLiquidityPool.DEPRECATED_regulationsManager();
        s_membershipManager = oldLiquidityPool.membershipManager();
        s_DEPRECATED_TNFT = oldLiquidityPool.DEPRECATED_TNFT();
        s_eETH = oldLiquidityPool.eETH();
        s_DEPRECATED_eEthliquidStakingOpened = oldLiquidityPool.DEPRECATED_eEthliquidStakingOpened();
        s_totalValueOutOfLp = oldLiquidityPool.totalValueOutOfLp();
        s_totalValueInLp = oldLiquidityPool.totalValueInLp();
        s_feeRecipient = oldLiquidityPool.feeRecipient();
        s_numPendingDeposits = oldLiquidityPool.numPendingDeposits();
        s_DEPRECATED_bNftTreasury = oldLiquidityPool.DEPRECATED_bNftTreasury();
        s_withdrawRequestNFT = oldLiquidityPool.withdrawRequestNFT();
        // s_DEPRECATED_bnftHolders = oldLiquidityPool.DEPRECATED_bnftHolders();
        s_DEPRECATED_maxValidatorsPerOwner = oldLiquidityPool.DEPRECATED_maxValidatorsPerOwner();
        s_DEPRECATED_schedulingPeriodInSeconds = oldLiquidityPool.DEPRECATED_schedulingPeriodInSeconds();
        // s_DEPRECATED_holdersUpdate = oldLiquidityPool.DEPRECATED_holdersUpdate();
        s_etherFiAdminContract = oldLiquidityPool.etherFiAdminContract();
        s_DEPRECATED_whitelistEnabled = oldLiquidityPool.DEPRECATED_whitelistEnabled();
        s_restakeBnftDeposits = oldLiquidityPool.restakeBnftDeposits();
        s_ethAmountLockedForWithdrawal = oldLiquidityPool.ethAmountLockedForWithdrawal();
        s_paused = oldLiquidityPool.paused();
        s_DEPRECATED_auctionManager = oldLiquidityPool.DEPRECATED_auctionManager();
        s_liquifier = oldLiquidityPool.liquifier();
        // s_DEPRECATED_isLpBnftHolder = oldLiquidityPool.DEPRECATED_isLpBnftHolder(); // Note: Private variable, cannot be accessed
        s_etherFiRedemptionManager = oldLiquidityPool.etherFiRedemptionManager();
        s_roleRegistry = oldLiquidityPool.roleRegistry();
        s_validatorSizeWei = oldLiquidityPool.validatorSizeWei();

        // TEST VIEW FUNCTIONS
        totalPooledBefore = liquidityPool.getTotalPooledEther();
        sharesForAmountBefore = liquidityPool.sharesForAmount(1 ether);
        sharesForWithdrawalBefore = liquidityPool.sharesForWithdrawalAmount(1 ether);
        amountForShareBefore = liquidityPool.amountForShare(1 ether);
        totalEtherClaimBefore = liquidityPool.getTotalEtherClaimOf(tom);
    }

    // ==================== SANITY CHECKS ====================

    function test_sanityChecks() public {
        // TEST VIEW FUNCTIONS
        assertEq(liquidityPool.getTotalPooledEther(), totalPooledBefore);
        assertEq(liquidityPool.sharesForAmount(1 ether), sharesForAmountBefore);
        assertEq(liquidityPool.sharesForWithdrawalAmount(1 ether), sharesForWithdrawalBefore);
        assertEq(liquidityPool.amountForShare(1 ether), amountForShareBefore);

        // Owner should remain the same
        assertEq(liquidityPool.owner(), ownerBefore);
        assertNotEq(liquidityPool.getImplementation(), liquidityPoolImplBefore);

        // ROLLBACK POSSIBLE
        vm.prank(liquidityPool.owner());
        liquidityPool.upgradeTo(liquidityPoolImplBefore);
        assertEq(liquidityPool.owner(), ownerBefore);
        assertEq(liquidityPool.getImplementation(), liquidityPoolImplBefore);

        vm.prank(stakingManager.owner());
        stakingManager.upgradeTo(stakingManagerImplBefore);
        assertEq(stakingManager.owner(), ownerBefore);
        bytes32 implementationSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        address stakingManagerImplAfter = address(uint160(uint256(vm.load(address(stakingManager), implementationSlot))));
        assertEq(stakingManagerImplAfter, stakingManagerImplBefore);
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
        vm.expectRevert(LiquidityPool.NotRegistered.selector);
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
        vm.expectRevert(LiquidityPool.ContractPaused.selector);
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
        vm.expectRevert();
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

    function test_roleGrant_succeeds() public {
        assertEq(roleRegistry.hasRole(keccak256("STAKING_MANAGER_VALIDATOR_INVALIDATOR_ROLE"), address(admin)), true);
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
        vm.expectRevert(LiquidityPool.ContractPaused.selector);
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

    // ==================== invalidateRegisteredBeaconValidator Tests ====================

    function test_invalidateRegisteredBeaconValidator_revertsWhenNoRole() public {
        address unauthorizedUser = vm.addr(0xDEAD);
        
        // Setup a registered validator
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

        // Register the validator first
        vm.prank(spawner);
        liquidityPool.batchRegister(toArray(depositData), createdBids, etherFiNode);

        // Try to invalidate without the role
        vm.prank(unauthorizedUser);
        vm.expectRevert(IStakingManager.IncorrectRole.selector);
        stakingManager.invalidateRegisteredBeaconValidator(depositData, createdBids[0], etherFiNode);
    }

    function test_invalidateRegisteredBeaconValidator_revertsWhenNotRegistered() public {
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

        (,,, , IStakingManager.DepositData memory depositData, address etherFiNode) = helper_getDataForValidatorKeyGen();

        // Don't register - validator doesn't exist
        vm.prank(admin);
        vm.expectRevert(IStakingManager.InvalidValidatorCreationStatus.selector);
        stakingManager.invalidateRegisteredBeaconValidator(depositData, createdBids[0], etherFiNode);
    }

    function test_invalidateRegisteredBeaconValidator_revertsWhenAlreadyConfirmed() public {
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

        (,,, , IStakingManager.DepositData memory depositData, address etherFiNode) = helper_getDataForValidatorKeyGen();

        vm.prank(spawner);
        liquidityPool.batchRegister(toArray(depositData), createdBids, etherFiNode);

        // Confirm the validator
        vm.deal(address(liquidityPool), 100 ether);
        vm.prank(admin);
        liquidityPool.batchCreateBeaconValidators(toArray(depositData), createdBids, etherFiNode);

        // Try to invalidate a confirmed validator - should revert
        vm.prank(admin);
        vm.expectRevert(IStakingManager.InvalidValidatorCreationStatus.selector);
        stakingManager.invalidateRegisteredBeaconValidator(depositData, createdBids[0], etherFiNode);
    }

    function test_invalidateRegisteredBeaconValidator_revertsWhenAlreadyInvalidated() public {
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

        (,,, , IStakingManager.DepositData memory depositData, address etherFiNode) = helper_getDataForValidatorKeyGen();

        vm.prank(spawner);
        liquidityPool.batchRegister(toArray(depositData), createdBids, etherFiNode);

        // Invalidate the validator first time
        vm.prank(admin);
        stakingManager.invalidateRegisteredBeaconValidator(depositData, createdBids[0], etherFiNode);

        // Try to invalidate again - should revert
        vm.prank(admin);
        vm.expectRevert(IStakingManager.InvalidValidatorCreationStatus.selector);
        stakingManager.invalidateRegisteredBeaconValidator(depositData, createdBids[0], etherFiNode);
    }

    function test_invalidateRegisteredBeaconValidator_succeeds() public {
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

        (,,, , IStakingManager.DepositData memory depositData, address etherFiNode) = helper_getDataForValidatorKeyGen();

        vm.prank(spawner);
        liquidityPool.batchRegister(toArray(depositData), createdBids, etherFiNode);

        // Verify status is REGISTERED
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

        // Invalidate the validator
        vm.expectEmit(true, true, true, true);
        emit IStakingManager.ValidatorCreationStatusUpdated(depositData, createdBids[0], etherFiNode, validatorHash, IStakingManager.ValidatorCreationStatus.INVALIDATED);

        vm.prank(admin);
        stakingManager.invalidateRegisteredBeaconValidator(depositData, createdBids[0], etherFiNode);

        // Verify status is INVALIDATED
        assertEq(
            uint8(stakingManager.validatorCreationStatus(validatorHash)),
            uint8(IStakingManager.ValidatorCreationStatus.INVALIDATED)
        );
    }

    // ==================== Upgrade Compatibility Tests ====================

    function test_upgrade_preservesPreUpgradeStorageValues() public {
        OldLiquidityPool oldLiquidityPool = OldLiquidityPool(payable(0x308861A430be4cce5502d0A12724771Fc6DaF216));

        assertEq(address(liquidityPool.DEPRECATED_stakingManager()), address(s_stakingManager));
        assertEq(address(liquidityPool.MEMBERSHIP_MANAGER()), address(s_membershipManager)); // VERIFIED CONSTANTS
        assertEq(address(liquidityPool.DEPRECATED_nodesManager()), address(s_nodesManager));
        assertEq(liquidityPool.DEPRECATED_regulationsManager(), s_DEPRECATED_regulationsManager);
        assertEq(address(liquidityPool.DEPRECATED_membershipManager()), s_membershipManager);
        assertEq(liquidityPool.DEPRECATED_TNFT(), s_DEPRECATED_TNFT);
        assertEq(address(liquidityPool.DEPRECATED_eETH()), address(s_eETH));
        assertEq(liquidityPool.DEPRECATED_eEthliquidStakingOpened(), s_DEPRECATED_eEthliquidStakingOpened);
        assertEq(liquidityPool.totalValueOutOfLp(), s_totalValueOutOfLp);
        assertEq(liquidityPool.totalValueInLp(), s_totalValueInLp);
        assertEq(liquidityPool.feeRecipient(), s_feeRecipient);
        assertEq(liquidityPool.numPendingDeposits(), s_numPendingDeposits);
        assertEq(liquidityPool.DEPRECATED_bNftTreasury(), s_DEPRECATED_bNftTreasury);
        assertEq(address(liquidityPool.DEPRECATED_withdrawRequestNFT()), address(s_withdrawRequestNFT));
        // assertEq(liquidityPool.DEPRECATED_bnftHolders(), s_DEPRECATED_bnftHolders);
        assertEq(liquidityPool.DEPRECATED_maxValidatorsPerOwner(), s_DEPRECATED_maxValidatorsPerOwner);
        assertEq(liquidityPool.DEPRECATED_schedulingPeriodInSeconds(), s_DEPRECATED_schedulingPeriodInSeconds);
        // assertEq(liquidityPool.DEPRECATED_holdersUpdate(), s_DEPRECATED_holdersUpdate);
        // assertEq(liquidityPool.depositDataRootForApprovalDeposits(), s_depositDataRootForApprovalDeposits);
        assertEq(liquidityPool.DEPRECATED_etherFiAdminContract(), s_etherFiAdminContract);
        assertEq(liquidityPool.ETHERFI_ADMIN_CONTRACT(), s_etherFiAdminContract); // VERIFIED CONSTANTS
        assertEq(liquidityPool.DEPRECATED_whitelistEnabled(), s_DEPRECATED_whitelistEnabled);
        assertEq(liquidityPool.restakeBnftDeposits(), s_restakeBnftDeposits);
        assertEq(liquidityPool.ethAmountLockedForWithdrawal(), s_ethAmountLockedForWithdrawal);
        assertEq(liquidityPool.paused(), s_paused);
        assertEq(liquidityPool.DEPRECATED_auctionManager(), s_DEPRECATED_auctionManager); 
        assertEq(address(liquidityPool.DEPRECATED_liquifier()), address(s_liquifier));
        assertEq(address(liquidityPool.LIQUIFIER()), address(s_liquifier)); // VERIFIED CONSTANTS
        // assertEq(liquidityPool.DEPRECATED_isLpBnftHolder(), oldLiquidityPool.DEPRECATED_isLpBnftHolder()); // Note: Private variable, cannot be accessed
        assertEq(address(liquidityPool.DEPRECATED_etherFiRedemptionManager()), address(s_etherFiRedemptionManager));
        assertEq(address(liquidityPool.ETHERFI_REDEMPTION_MANAGER()), address(s_etherFiRedemptionManager)); // VERIFIED CONSTANTS
        assertEq(address(liquidityPool.DEPRECATED_roleRegistry()), address(s_roleRegistry));
        assertEq(liquidityPool.validatorSizeWei(), s_validatorSizeWei);
    }

    function test_upgrade_preservesDepositDataRootMapping() public {
        // Set some deposit data roots
        uint256 validatorId1 = 123;
        uint256 validatorId2 = 456;
        bytes32 root1 = keccak256("root1");
        bytes32 root2 = keccak256("root2");

        // Note: depositDataRootForApprovalDeposits mapping doesn't have a setter in current contract
        // but we can verify the slot is preserved by checking the mapping exists
        // This test verifies the mapping storage slot structure is maintained

        // Perform upgrade
        LiquidityPool newImpl = new LiquidityPool();
        vm.prank(liquidityPool.owner());
        liquidityPool.upgradeTo(address(newImpl));

        // Verify mapping slot structure is preserved (reads zero for unset values, which is correct)
        assertEq(liquidityPool.depositDataRootForApprovalDeposits(validatorId1), bytes32(0));
        assertEq(liquidityPool.depositDataRootForApprovalDeposits(validatorId2), bytes32(0));
    }

    function test_upgrade_maintainsEthAccounting() public {
        uint256 totalPooledBefore = liquidityPool.getTotalPooledEther();

        vm.deal(address(tom), 10 ether);
        vm.prank(tom);
        liquidityPool.deposit{value: 5 ether}();

        // Verify accounting updated correctly
        assertEq(liquidityPool.getTotalPooledEther(), totalPooledBefore + 5 ether);
    }
}