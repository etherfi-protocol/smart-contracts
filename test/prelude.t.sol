pragma solidity ^0.8.27;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import "../test/common/ArrayTestHelper.sol";
import "../src/interfaces/ILiquidityPool.sol";
import "../src/interfaces/IStakingManager.sol";
import "../src/StakingManager.sol";
import "../src/interfaces/IEtherFiNodesManager.sol";
import "../src/EtherFiNodesManager.sol";
import "../src/interfaces/IEtherFiNode.sol";
import {IEigenPod, IEigenPodTypes } from "../src/eigenlayer-interfaces/IEigenPod.sol";
import "../src/EtherFiNode.sol";
import "../src/EtherFiRateLimiter.sol";
import "../src/UUPSProxy.sol";
import "../src/NodeOperatorManager.sol";
import "../src/interfaces/ITNFT.sol";
import "../src/interfaces/IBNFT.sol";
import "../src/AuctionManager.sol";
import "../src/libraries/DepositDataRootGenerator.sol";


contract PreludeTest is Test, ArrayTestHelper {

    StakingManager stakingManager;
    ILiquidityPool liquidityPool;
    EtherFiNodesManager etherFiNodesManager;
    AuctionManager auctionManager;
    EtherFiNode etherFiNodeImpl;
    ITNFT tnft;
    IBNFT bnft;
    NodeOperatorManager nodeOperatorManager = NodeOperatorManager(0xd5edf7730ABAd812247F6F54D7bd31a52554e35E);

    address admin = vm.addr(0x9876543210);
    address stakingDepositContract = address(0x00000000219ab540356cBB839Cbe05303d7705Fa);
    address eigenPodManager = address(0x91E677b07F7AF907ec9a428aafA9fc14a0d3A338);
    address delegationManager = address(0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A);
    address etherFiNodeBeacon = address(0x3c55986Cfee455E2533F4D29006634EcF9B7c03F);
    RoleRegistry roleRegistry = RoleRegistry(0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9);
    IStrategy beaconStrategy = IStrategy(address(0xbeaC0eeEeeeeEEeEeEEEEeeEEeEeeeEeeEEBEaC0));

    // role users
    address eigenlayerAdmin = vm.addr(0xABABAB);
    address callForwarder = vm.addr(0xCDCDCD);
    address user = vm.addr(0xEFEFEF);
    address elExiter = address(0x12121212);

    // Same-pod group (EigenPod: 0x98B1377660B2ccCF88195d2360b1b1155249b940)
    bytes constant PK_16171 = hex"b964a67b7272ce6b59243d65ffd7b011363dd99322c88e583f14e34e19dfa249c80c724361ceaee7a9bfbfe1f3822871";
    bytes constant PK_16172 = hex"b22c8896452c858287426b478e76c2bf366f0c139cf54bd07fa7351290e9a9f92cc4f059ea349a441e1cfb60aacd2447";
    bytes constant PK_16173 = hex"87622c003bf0a4413bc736cc78a93b8fb5a427f5c538d71c52c9a453e9928a53c3f70acb37826b49f4ddc6d643667b78";
    bytes constant PK_UNKNOWN = hex"850587731dbd50ac4e996913bde4154ea5ca72bad7ccd853bb47398ae76a75da92b9f824114a42a12ca87dd4fa07cd41";

    // Different-pod single (EigenPod: 0x813FF37BDD2b10845470Fa7d90bc7cD0FC94e456)
    bytes constant PK_24807 = hex"b4164dc6841e4b9d4736f89961b8e59ff9397d64d75d95fa3484c78de51a18c4031ef253896ba85b38d168f7211c8c71";

    TestValidatorParams defaultTestValidatorParams;
    EtherFiRateLimiter rateLimiter;

    function setUp() public {

        vm.selectFork(vm.createFork(vm.envString("MAINNET_RPC_URL")));

        stakingManager = StakingManager(0x25e821b7197B146F7713C3b89B6A4D83516B912d);
        liquidityPool = ILiquidityPool(0x308861A430be4cce5502d0A12724771Fc6DaF216);
        etherFiNodesManager = EtherFiNodesManager(payable(0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F));
        auctionManager = AuctionManager(0x00C452aFFee3a17d9Cecc1Bcd2B8d5C7635C4CB9);

        // deploy new staking manager implementation
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
        vm.prank(LiquidityPool(payable(address(liquidityPool))).owner());
        LiquidityPool(payable(address(liquidityPool))).upgradeTo(address(liquidityPoolImpl));

        // Deploy rate limiter first with proxy pattern
        EtherFiRateLimiter rateLimiterImpl = new EtherFiRateLimiter(address(roleRegistry));
        UUPSProxy rateLimiterProxy = new UUPSProxy(address(rateLimiterImpl), "");
        rateLimiter = EtherFiRateLimiter(address(rateLimiterProxy));
        rateLimiter.initialize();
        
        // upgrade etherFiNode impl
        etherFiNodeImpl = new EtherFiNode(
            address(liquidityPool),
            address(etherFiNodesManager),
            eigenPodManager,
            delegationManager,
            address(roleRegistry)
        );
        vm.prank(stakingManager.owner());
        stakingManager.upgradeEtherFiNode(address(etherFiNodeImpl));

        // deploy new efnm implementation
        EtherFiNodesManager etherFiNodesManagerImpl = new EtherFiNodesManager(address(stakingManager), address(roleRegistry), address(rateLimiter));
        vm.prank(etherFiNodesManager.owner());
        etherFiNodesManager.upgradeTo(address(etherFiNodesManagerImpl));

        vm.prank(auctionManager.owner());
        auctionManager.disableWhitelist();

        // permissions
        vm.startPrank(roleRegistry.owner());
        roleRegistry.grantRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_ADMIN_ROLE(), admin);
        roleRegistry.grantRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE(), callForwarder);
        roleRegistry.grantRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE(), eigenlayerAdmin);
        roleRegistry.grantRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE(), elExiter);
        roleRegistry.grantRole(stakingManager.STAKING_MANAGER_NODE_CREATOR_ROLE(), admin);
        roleRegistry.grantRole(liquidityPoolImpl.LIQUIDITY_POOL_VALIDATOR_APPROVER_ROLE(), admin);
        roleRegistry.grantRole(liquidityPoolImpl.LIQUIDITY_POOL_ADMIN_ROLE(), admin);
        roleRegistry.grantRole(rateLimiter.ETHERFI_RATE_LIMITER_ADMIN_ROLE(), admin);
        vm.stopPrank();

        vm.startPrank(admin);
        rateLimiter.createNewLimiter(etherFiNodesManager.UNRESTAKING_LIMIT_ID(), 172_800_000_000_000, 2_000_000_000);
        rateLimiter.createNewLimiter(etherFiNodesManager.EXIT_REQUEST_LIMIT_ID(), 172_800_000_000_000, 2_000_000_000);
        rateLimiter.updateConsumers(etherFiNodesManager.UNRESTAKING_LIMIT_ID(), address(etherFiNodesManager), true);
        rateLimiter.updateConsumers(etherFiNodesManager.EXIT_REQUEST_LIMIT_ID(), address(etherFiNodesManager), true);
        vm.stopPrank();

        defaultTestValidatorParams = TestValidatorParams({
            nodeOperator: address(0), // attach to a random node operator
            etherFiNode: address(0),  // create a new etherfiNode
            bidId: 0,                 // create and claim a new bid
            withdrawable: true,       // simulate validator being ready to withdraw from pod
            validatorSize: 32 ether,
            pubkey: ""
        });

    }

    struct TestValidatorParams {
        address nodeOperator;  // if none specified a new operator will be created
        address etherFiNode;   // if none specified a new node will be deployed
        uint256 bidId;         // if none specified a new bid will be placed
        uint256 validatorSize; // if none specified default to 32 eth
        bool withdrawable;     // give the eigenpod "validatorSize" worth of withdrawable beacon shares
        bytes pubkey;          // if none specified a random pubkey is generated
    }

    struct TestValidator {
        address etherFiNode;
        address eigenPod;
        uint256 legacyId;
        bytes32 pubkeyHash;
        address nodeOperator;
        uint256 validatorSize;
        bytes pubkey;
    }

    function helper_createValidator(TestValidatorParams memory _params) public returns (TestValidator memory) {

        // create a copy or else successive calls of this method can mutate the input unexpectedly
        TestValidatorParams memory params = TestValidatorParams(_params.nodeOperator, _params.etherFiNode, _params.bidId, _params.validatorSize, _params.withdrawable, _params.pubkey);

        // configure a new operator if none provided
        if (params.nodeOperator == address(0)) {
            params.nodeOperator = vm.addr(0x123456);

            // register if not already
            if (!nodeOperatorManager.registered(params.nodeOperator)) {
                vm.prank(params.nodeOperator);
                nodeOperatorManager.registerNodeOperator("test_ipfs_hash", 1000);
            }
        }
        // create a new bid if none provided
        if (params.bidId == 0) {
            vm.deal(params.nodeOperator, 1 ether);
            vm.prank(params.nodeOperator);
            params.bidId = auctionManager.createBid{value: 0.1 ether}(1, 0.1 ether)[0];
        }
        // create a new node if none provided
        if (params.etherFiNode == address(0)) {
            vm.prank(admin);
            params.etherFiNode = stakingManager.instantiateEtherFiNode(/*createEigenPod=*/ true);
        }
        // default validator size if not provided
        if (params.validatorSize == 0) {
            params.validatorSize = 32 ether;
        }

        bytes memory pubkey = params.pubkey.length == 48 ? params.pubkey : vm.randomBytes(48);
        bytes memory signature = vm.randomBytes(96);

        // initial deposit
        address eigenPod = address(IEtherFiNode(params.etherFiNode).getEigenPod());
        bytes32 initialDepositRoot = depositDataRootGenerator.generateDepositDataRoot(
            pubkey,
            signature,
            etherFiNodesManager.addressToCompoundingWithdrawalCredentials(eigenPod),
            1 ether
        );
        IStakingManager.DepositData memory initialDepositData = IStakingManager.DepositData({
            publicKey: pubkey,
            signature: signature,
            depositDataRoot: initialDepositRoot,
            ipfsHashForEncryptedValidatorKey: "test_ipfs_hash"
        });
        vm.deal(address(liquidityPool), 10000 ether);
        vm.prank(address(liquidityPool));
        stakingManager.createBeaconValidators{value: 1 ether}(toArray(initialDepositData), toArray_u256(params.bidId), params.etherFiNode);

        uint256 confirmAmount = params.validatorSize - 1 ether;

        // remaining deposit
        bytes32 confirmDepositRoot = depositDataRootGenerator.generateDepositDataRoot(
            pubkey,
            signature,
            etherFiNodesManager.addressToCompoundingWithdrawalCredentials(eigenPod),
            confirmAmount
        );
        IStakingManager.DepositData memory confirmDepositData = IStakingManager.DepositData({
            publicKey: pubkey,
            signature: signature,
            depositDataRoot: confirmDepositRoot,
            ipfsHashForEncryptedValidatorKey: "test_ipfs_hash"
        });
        vm.prank(address(liquidityPool));
        stakingManager.confirmAndFundBeaconValidators{value: confirmAmount}(toArray(confirmDepositData), params.validatorSize);

        if (params.withdrawable) {
            // Poke some withdrawable funds into the restakedExecutionLayerGwei storage slot of the eigenpod.
            // This is much easier than trying to do the full proof based workflow which relies on beacon state.
            address eigenpod = etherFiNodesManager.getEigenPod(uint256(params.bidId));
            vm.store(eigenpod, bytes32(uint256(52)) /*slot*/, bytes32(uint256(params.validatorSize / 1 gwei)));

            // grant shares via delegation manager so that withdrawals work
            vm.prank(delegationManager);
            IEigenPodManager(eigenPodManager).addShares(params.etherFiNode, beaconStrategy, params.validatorSize);

            // give the pod enough eth to fulfill that withdrawal
            vm.deal(eigenpod, params.validatorSize);
        }

        TestValidator memory out = TestValidator({
            etherFiNode: params.etherFiNode,
            eigenPod: eigenPod,
            legacyId: params.bidId,
            pubkeyHash: stakingManager.calculateValidatorPubkeyHash(pubkey),
            nodeOperator: params.nodeOperator,
            validatorSize: params.validatorSize,
            pubkey: pubkey
        });
        return out;
    }

    function test_validatorHelper() public {

        // deploy 2 validators with default settings
        TestValidator memory val = helper_createValidator(defaultTestValidatorParams);
        console2.log("------------------------------------");
        console2.log("etherFiNode:", val.etherFiNode);
        console2.log("eigenPod:", val.eigenPod);
        console2.log("legacyId:", val.legacyId);
        console2.log("pubkeyHash:", uint256(val.pubkeyHash));
        console2.log("nodeOperator:", val.nodeOperator);
        console2.log("validatorSize:", val.validatorSize);
        TestValidator memory val2 = helper_createValidator(defaultTestValidatorParams);
        console2.log("------------------------------------");
        console2.log("etherFiNode:", val2.etherFiNode);
        console2.log("eigenPod:", val2.eigenPod);
        console2.log("legacyId:", val2.legacyId);
        console2.log("pubkeyHash:", uint256(val2.pubkeyHash));
        console2.log("nodeOperator:", val2.nodeOperator);
        console2.log("validatorSize:", val2.validatorSize);

        // attach to same node as the first one
        TestValidatorParams memory params = defaultTestValidatorParams;
        params.etherFiNode = val.etherFiNode;
        TestValidator memory val3 = helper_createValidator(params);
        assertEq(val.etherFiNode, val3.etherFiNode);
        assertEq(val.eigenPod, val3.eigenPod);

        // create big validator
        params = defaultTestValidatorParams;
        params.validatorSize = 2000 ether;
        params.withdrawable = true;
        TestValidator memory val4 = helper_createValidator(params);
        assertEq(2000 ether, val4.validatorSize);
        assertGe(IEigenPod(val4.eigenPod).withdrawableRestakedExecutionLayerGwei(), (2000 ether / 1 gwei));

        // create a specific operator + bid and make validator with that bid ID + operator
        params = defaultTestValidatorParams;
        params.nodeOperator = vm.addr(0x12345678);
        vm.startPrank(params.nodeOperator);
        {
            vm.deal(params.nodeOperator, 1 ether);
            nodeOperatorManager.registerNodeOperator("test_ipfs_hash", 1000);
            params.bidId = auctionManager.createBid{value: 0.1 ether}(1, 0.1 ether)[0];
        }
        vm.stopPrank();
        TestValidator memory val5 = helper_createValidator(params);
    }

    // After the v3-prelude upgrade is complete and any leftover validators in this state
    // have been approved, we can delete this test as this state can't happen anymore
    function test_approveExisting1EthBid() public {

        uint256 bidId = 114850;
        bytes memory pubkey = hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c";
        bytes memory signature = hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df";

        // need to link because this validator is already past this step from the old flow
        vm.prank(admin);
        etherFiNodesManager.linkLegacyValidatorIds(toArray_u256(bidId), toArray_bytes(pubkey));

        vm.prank(admin);
        liquidityPool.setValidatorSizeWei(33 ether);

        vm.prank(admin);
        liquidityPool.batchApproveRegistration(
            toArray_u256(bidId),
            toArray_bytes(pubkey),
            toArray_bytes(signature)
        );
    }

    function test_forwardingWhitelist() public {

        // create a node + pod
        vm.prank(admin);
        IEtherFiNode etherFiNode = IEtherFiNode(stakingManager.instantiateEtherFiNode(true /*createEigenPod*/));

        // link it to an arbitrary id
        uint256 legacyID = 10885;
        bytes memory pubkey = hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c";
        vm.prank(admin);
        etherFiNodesManager.linkLegacyValidatorIds(toArray_u256(legacyID), toArray_bytes(pubkey));

        // user with no role should not be able to forward calls
        vm.startPrank(user);
        {
            vm.expectRevert(IEtherFiNode.IncorrectRole.selector);
            etherFiNode.forwardEigenPodCall("");

            vm.expectRevert(IEtherFiNode.IncorrectRole.selector);
            etherFiNode.forwardExternalCall(address(0), "");

            vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
            etherFiNodesManager.forwardEigenPodCall(toArray_u256(legacyID), toArray_bytes(""));

            vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
            etherFiNodesManager.forwardExternalCall(toArray_u256(legacyID), toArray_bytes(""), address(0));

        }
        vm.stopPrank();

        // grant roles
        vm.startPrank(roleRegistry.owner());
        {
            roleRegistry.grantRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE(), user);
        }
        vm.stopPrank();

        bytes4 decimalsSelector = hex"313ce567"; // ERC20 decimals()
        bytes4 checkpointSelector = hex"47d28372"; // eigenpod currentCheckpoint()
        bytes memory data = hex"313ce567";
        bytes memory checkpointData = hex"47d28372" ;
        address target = 0xFe0c30065B384F05761f15d0CC899D4F9F9Cc0eB; // ethfi

        // user should fail due to calls not being whitelisted
        vm.startPrank(user);
        {
            vm.expectRevert(IEtherFiNode.ForwardedCallNotAllowed.selector);
            etherFiNode.forwardEigenPodCall(checkpointData);

            vm.expectRevert(IEtherFiNode.ForwardedCallNotAllowed.selector);
            etherFiNode.forwardExternalCall(address(0), data);

            vm.expectRevert(IEtherFiNodesManager.ForwardedCallNotAllowed.selector);
            etherFiNodesManager.forwardEigenPodCall(toArray_u256(legacyID), toArray_bytes(checkpointData));

            vm.expectRevert(IEtherFiNode.ForwardedCallNotAllowed.selector);
            etherFiNodesManager.forwardExternalCall(toArray_u256(legacyID), toArray_bytes(data), target);
        }
        vm.stopPrank();

        // whitelist calls
        vm.startPrank(admin);
        {
            etherFiNodesManager.updateAllowedForwardedExternalCalls(decimalsSelector, target, true);
            etherFiNodesManager.updateAllowedForwardedEigenpodCalls(checkpointSelector, true);
        }
        vm.stopPrank();

        // calls should succeed after being whitelisted
        vm.startPrank(user);
        {
            etherFiNode.forwardEigenPodCall(checkpointData);
            etherFiNode.forwardExternalCall(target, data);
            etherFiNodesManager.forwardEigenPodCall(toArray_u256(legacyID), toArray_bytes(checkpointData));
            etherFiNodesManager.forwardExternalCall(toArray_u256(legacyID), toArray_bytes(data), target);
        }
        vm.stopPrank();

    }

    function test_StakingManagerUpgradePermissions() public {

        // deploy new staking manager implementation
        StakingManager stakingManagerImpl = new StakingManager(
            address(liquidityPool),
            address(etherFiNodesManager),
            address(stakingDepositContract),
            address(auctionManager),
            address(etherFiNodeBeacon),
            address(roleRegistry)
        );

        // only owner should be able to upgrade
        vm.expectRevert(IRoleRegistry.OnlyProtocolUpgrader.selector);
        stakingManager.upgradeTo(address(stakingManagerImpl));

        // should succeed when called by owner
        address owner = stakingManager.owner();
        vm.prank(owner);
        stakingManager.upgradeTo(address(stakingManagerImpl));
    }

    function test_createBeaconValidators() public {

        address nodeOperator = vm.addr(0x123456);
        vm.prank(nodeOperator);
        nodeOperatorManager.registerNodeOperator("test_ipfs_hash", 1000);

        // create a bid
        vm.deal(nodeOperator, 33 ether);
        vm.prank(nodeOperator);
        uint256[] memory bidIds = auctionManager.createBid{value: 0.1 ether}(
            1,
            0.1 ether
        );

        bytes memory pubkey = hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c";
        bytes memory signature = hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df";

        vm.prank(admin);
        address etherFiNode = stakingManager.instantiateEtherFiNode(true /*createEigenPod*/);

        address eigenPod = address(IEtherFiNode(etherFiNode).getEigenPod());
        bytes32 initialDepositRoot = depositDataRootGenerator.generateDepositDataRoot(
            pubkey,
            signature,
            etherFiNodesManager.addressToCompoundingWithdrawalCredentials(eigenPod),
            1 ether
        );
        IStakingManager.DepositData memory initialDepositData = IStakingManager.DepositData({
            publicKey: pubkey,
            signature: signature,
            depositDataRoot: initialDepositRoot,
            ipfsHashForEncryptedValidatorKey: "test_ipfs_hash"
        });

        vm.deal(address(liquidityPool), 100 ether);
        vm.prank(address(liquidityPool));
        stakingManager.createBeaconValidators{value: 1 ether}(toArray(initialDepositData), bidIds, etherFiNode);

        uint256 validatorSize = 32 ether;
        uint256 confirmAmount = validatorSize - 1 ether;

        bytes32 confirmDepositRoot = depositDataRootGenerator.generateDepositDataRoot(
            pubkey,
            signature,
            etherFiNodesManager.addressToCompoundingWithdrawalCredentials(eigenPod),
            confirmAmount
        );

        IStakingManager.DepositData memory confirmDepositData = IStakingManager.DepositData({
            publicKey: pubkey,
            signature: signature,
            depositDataRoot: confirmDepositRoot,
            ipfsHashForEncryptedValidatorKey: "test_ipfs_hash"
        });

        vm.prank(address(liquidityPool));
        stakingManager.confirmAndFundBeaconValidators{value: confirmAmount}(toArray(confirmDepositData), validatorSize);
    }

    function test_withdrawRestakedValidatorETH() public {

        bytes memory validatorPubkey = hex"892c95f4e93ab042ee39397bff22cc43298ff4b2d6d6dec3f28b8b8ebcb5c65ab5e6fc29301c1faee473ec095f9e4306";
        bytes32 pubkeyHash = etherFiNodesManager.calculateValidatorPubkeyHash(validatorPubkey);
        uint256 legacyID = 10885;

        // force link this validator
        vm.prank(admin);
        etherFiNodesManager.linkLegacyValidatorIds(toArray_u256(legacyID), toArray_bytes(validatorPubkey));

        // Set up rate limiter for the linked EtherFiNode proxy
        address etherFiNodeAddress = etherFiNodesManager.etherfiNodeAddress(uint256(pubkeyHash));
        if (address(rateLimiter) != address(0)) {
            // Add EtherFiNode as a consumer for the unrestaking limit
            vm.startPrank(admin);
            rateLimiter.updateConsumers(etherFiNodesManager.UNRESTAKING_LIMIT_ID(), etherFiNodeAddress, true);
            vm.stopPrank();
        }

        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.queueETHWithdrawal(uint256(pubkeyHash), 1 ether);

        // poke some withdrawable funds into the restakedExecutionLayerGwei storage slot of the eigenpod
        address eigenpod = etherFiNodesManager.getEigenPod(uint256(pubkeyHash));
        vm.store(eigenpod, bytes32(uint256(52)) /*slot*/, bytes32(uint256(50 ether / 1 gwei)));

        uint256 startingBalance = address(liquidityPool).balance;

        vm.roll(block.number + (7200 * 15));
        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.completeQueuedETHWithdrawals(uint256(pubkeyHash), true);

        // liquidity pool should have received withdrawal
        assertEq(address(liquidityPool).balance, startingBalance + 1 ether);
    }

    function test_EtherFiNodePermissions() public {

        // create a node
        vm.prank(admin);
        IEtherFiNode etherFiNode = IEtherFiNode(stakingManager.instantiateEtherFiNode(true));

        vm.startPrank(user);

        // Normal user should fail for all eigenlayer functions
        vm.expectRevert(IEtherFiNode.IncorrectRole.selector);
        etherFiNode.createEigenPod();

        vm.expectRevert(IEtherFiNode.IncorrectRole.selector);
        etherFiNode.setProofSubmitter(address(0));

        vm.expectRevert(IEtherFiNode.IncorrectRole.selector);
        etherFiNode.startCheckpoint();

        BeaconChainProofs.BalanceProof[] memory balanceProofs = new BeaconChainProofs.BalanceProof[](1);
        BeaconChainProofs.BalanceContainerProof memory containerProof = BeaconChainProofs.BalanceContainerProof({
            balanceContainerRoot: bytes32(uint256(1)),
            proof: ""
        });
        vm.expectRevert(IEtherFiNode.IncorrectRole.selector);
        etherFiNode.verifyCheckpointProofs(containerProof, balanceProofs);

        vm.expectRevert(IEtherFiNode.IncorrectRole.selector);
        etherFiNode.queueETHWithdrawal(1 ether);

        vm.expectRevert(IEtherFiNode.IncorrectRole.selector);
        etherFiNode.completeQueuedETHWithdrawals(true);

        IDelegationManager.QueuedWithdrawalParams[] memory params = new IDelegationManager.QueuedWithdrawalParams[](1);
        vm.expectRevert(IEtherFiNode.IncorrectRole.selector);
        etherFiNode.queueWithdrawals(params);

        IDelegationManager.Withdrawal[] memory withdrawals = new IDelegationManager.Withdrawal[](1);
        IERC20[][] memory tokens = new IERC20[][](1);
        bool[] memory receiveAsTokens = new bool[](1);
        vm.expectRevert(IEtherFiNode.IncorrectRole.selector);
        etherFiNode.completeQueuedWithdrawals(withdrawals, tokens, receiveAsTokens);

        vm.expectRevert(IEtherFiNode.IncorrectRole.selector);
        etherFiNode.sweepFunds();

        // normal user should fail for all call forwarding
        vm.expectRevert(IEtherFiNode.IncorrectRole.selector);
        etherFiNode.forwardEigenPodCall("");

        vm.expectRevert(IEtherFiNode.IncorrectRole.selector);
        etherFiNode.forwardExternalCall(address(0), "");

        vm.stopPrank();
    }


    function test_EtherFiNodesManagerPermissions() public {

        uint256 nodeId = 1;

        // none of the EFNM roles should be allowed to upgrade
        vm.expectRevert(IRoleRegistry.OnlyProtocolUpgrader.selector);
        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.upgradeTo(address(0));
        vm.expectRevert(IRoleRegistry.OnlyProtocolUpgrader.selector);
        vm.prank(user);
        etherFiNodesManager.upgradeTo(address(0));
        vm.expectRevert(IRoleRegistry.OnlyProtocolUpgrader.selector);
        vm.prank(callForwarder);
        etherFiNodesManager.upgradeTo(address(0));

        vm.startPrank(user);

        // Normal user should fail for all eigenlayer functions
        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        etherFiNodesManager.setProofSubmitter(nodeId, address(0));

        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        etherFiNodesManager.startCheckpoint(nodeId);

        BeaconChainProofs.BalanceProof[] memory balanceProofs = new BeaconChainProofs.BalanceProof[](1);
        BeaconChainProofs.BalanceContainerProof memory containerProof = BeaconChainProofs.BalanceContainerProof({
            balanceContainerRoot: bytes32(uint256(1)),
            proof: ""
        });
        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        etherFiNodesManager.verifyCheckpointProofs(nodeId, containerProof, balanceProofs);

        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        etherFiNodesManager.queueETHWithdrawal(nodeId, 1 ether);

        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        etherFiNodesManager.completeQueuedETHWithdrawals(nodeId, true);

        IDelegationManager.QueuedWithdrawalParams[] memory params = new IDelegationManager.QueuedWithdrawalParams[](1);
        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        etherFiNodesManager.queueWithdrawals(nodeId, params);

        IDelegationManager.Withdrawal[] memory withdrawals = new IDelegationManager.Withdrawal[](1);
        IERC20[][] memory tokens = new IERC20[][](1);
        bool[] memory receiveAsTokens = new bool[](1);
        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        etherFiNodesManager.completeQueuedWithdrawals(nodeId, withdrawals, tokens, receiveAsTokens);

        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        etherFiNodesManager.sweepFunds(nodeId);

        // normal user should fail for all call forwarding
        uint256[] memory nodeIds = new uint256[](1);
        bytes[] memory data = new bytes[](1);

        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        etherFiNodesManager.forwardEigenPodCall(nodeIds, data);

        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        etherFiNodesManager.forwardExternalCall(nodeIds, data, address(0));

        vm.stopPrank();
    }

    function test_StakingManagerPermissions() public {

        bytes memory pubkey = hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c";
        bytes memory signature = hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df";

        // only liquidityPool can call createBeaconValidators
        bytes32 initialDepositDataRoot = depositDataRootGenerator.generateDepositDataRoot(pubkey, signature, "", 1 ether);
        IStakingManager.DepositData memory initialDepositData = IStakingManager.DepositData({
            publicKey: pubkey,
            signature: signature,
            depositDataRoot: initialDepositDataRoot,
            ipfsHashForEncryptedValidatorKey: "test_ipfs_hash"
        });
        uint256[] memory bidIds = new uint256[](1);
        vm.prank(admin);
        vm.expectRevert(IStakingManager.InvalidCaller.selector);
        stakingManager.createBeaconValidators(toArray(initialDepositData), bidIds, address(0));

        // only liquidityPool can call confirmAndFundBeaconValidators
        bytes32 confirmDepositDataRoot = depositDataRootGenerator.generateDepositDataRoot(pubkey, signature, "", 31 ether);
        IStakingManager.DepositData memory confirmDepositData = IStakingManager.DepositData({
            publicKey: pubkey,
            signature: signature,
            depositDataRoot: 0,
            ipfsHashForEncryptedValidatorKey: "test_ipfs_hash"
        });
        vm.prank(address(admin));
        vm.expectRevert(IStakingManager.InvalidCaller.selector);
        stakingManager.confirmAndFundBeaconValidators(toArray(confirmDepositData), 32 ether);


        // only protocolUpgrader can upgrade etherFiNode
        EtherFiNode nodeImpl = new EtherFiNode(address(0), address(0), address(0), address(0), address(0));
        vm.prank(admin);
        vm.expectRevert(IRoleRegistry.OnlyProtocolUpgrader.selector);
        stakingManager.upgradeEtherFiNode(address(nodeImpl));

        vm.prank(roleRegistry.owner());
        stakingManager.upgradeEtherFiNode(address(nodeImpl));
    }

    function test_getEigenPod() public {

        // node that has existing eigenpod
        IEtherFiNode node = IEtherFiNode(0xbD0BFF833DE891aDcFF6Ee5502B23f516bECBf6F);
        address eigenPod = address(node.getEigenPod());
        assertEq(eigenPod, address(0x5E77861146AFACBa593dB976AD86BaB79675BC6F));

        // new node that doesn't have existing eigenpod
        // should return zero address
        vm.prank(admin);
        IEtherFiNode newNode = IEtherFiNode(stakingManager.instantiateEtherFiNode(/*createEigenPod=*/false));
        assertEq(address(newNode.getEigenPod()), address(0));
    }

    function test_createEigenPod() public {

        // create pod without eigenpod
        vm.prank(admin);
        IEtherFiNode newNode = IEtherFiNode(stakingManager.instantiateEtherFiNode(/*createEigenPod=*/false));
        assertEq(address(newNode.getEigenPod()), address(0));

        // admin creates one and it should be connected
        vm.prank(eigenlayerAdmin);
        address newPod = newNode.createEigenPod();
        assert(newPod != address(0));
        assertEq(newPod, address(newNode.getEigenPod()));
    }

    function test_setProofSubmitter() public {

        address newSubmitter = vm.addr(0xabc123);
        IEtherFiNode node = IEtherFiNode(0xbD0BFF833DE891aDcFF6Ee5502B23f516bECBf6F);

        vm.prank(eigenlayerAdmin);
        node.setProofSubmitter(newSubmitter);

        IEigenPod pod = node.getEigenPod();
        assertEq(pod.proofSubmitter(), newSubmitter);

    }

    function test_pubkeyHashAndLegacyId() public {

        // create a new validator
        TestValidator memory val = helper_createValidator(defaultTestValidatorParams);

        // both the legacyId and the pubkeyHash should be linked to the same node
        address a1 = etherFiNodesManager.etherfiNodeAddress(val.legacyId);
        address a2 = etherFiNodesManager.etherfiNodeAddress(uint256(val.pubkeyHash));
        assertEq(a1, a2);
        assert(a1 != address(0));
    }

    function test_startCheckpoint() public {

        // create a new validator with an eigenpod
        TestValidator memory val = helper_createValidator(defaultTestValidatorParams);

        // ensure no checkpoint currently active
        assert(IEigenPod(val.eigenPod).currentCheckpointTimestamp() == 0);

        console2.log("eigenpod:", val.eigenPod);
        console2.log("balance:", val.eigenPod.balance);

        // need to deal it some additional eth not already accounted for in its
        // beacon shares or else it will revert since there is no point in checkpointing
        // need to deposit 33 eth because the amount since previous checkpoint(restakedExecutionLayerGwei) is 32
        vm.deal(val.eigenPod, 33 ether);

        //Need to store activeValidatorCount > 0 so that proofsSubmitted isn't 0
        //If it is 0 then currentCheckpointTimestamp is reset to 0 as no proofs are needed.
        vm.store(
            val.eigenPod,
            bytes32(uint256(57)) /*slot*/,
            bytes32(uint256(1))
        );
        // initiate a checkpoint
        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.startCheckpoint(uint256(val.pubkeyHash));
        assert(IEigenPod(val.eigenPod).currentCheckpointTimestamp() != 0);
    }

    function test_linkLegacyValidatorIds() public {

        // grab some legacyIds that existed before the upgrade
        uint256[] memory legacyIds = new uint256[](3);
        legacyIds[0] = 10270;
        legacyIds[1] = 10271;
        legacyIds[2] = 26606;

        // random pubkeys to attach
        bytes[] memory pubkeys = new bytes[](3);
        pubkeys[0] = vm.randomBytes(48);
        pubkeys[1] = vm.randomBytes(48);
        pubkeys[2] = vm.randomBytes(48);

        // should fail if not admin
        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        etherFiNodesManager.linkLegacyValidatorIds(legacyIds, pubkeys);

        vm.prank(admin);
        etherFiNodesManager.linkLegacyValidatorIds(legacyIds, pubkeys);

        // should fail if attempt to re-link already linked ids
        vm.expectRevert(IEtherFiNodesManager.AlreadyLinked.selector);
        vm.prank(admin);
        etherFiNodesManager.linkLegacyValidatorIds(legacyIds, pubkeys);

        // should fail if attempt to link unknown node
        uint256 badId = 9999999;
        bytes memory badPubkey = vm.randomBytes(48);
        vm.expectRevert(IEtherFiNodesManager.UnknownNode.selector);
        vm.prank(admin);
        etherFiNodesManager.linkLegacyValidatorIds(toArray_u256(badId), toArray_bytes(badPubkey));

    }

    function test_withdrawMultipleLargeValidators() public {
        // create multiple large validators of different sizes
        TestValidatorParams memory params = defaultTestValidatorParams;
        params.validatorSize = 64 ether;
        TestValidator memory val1 = helper_createValidator(params);

        // attach additional validators to the same etherfi node
        params.etherFiNode = val1.etherFiNode;
        params.validatorSize = 128 ether;
        TestValidator memory val2 = helper_createValidator(params);
        params.validatorSize = 1000 ether;
        TestValidator memory val3 = helper_createValidator(params);
        params.validatorSize = 2000 ether;
        TestValidator memory val4 = helper_createValidator(params);

        uint256 startingLPBalance = address(liquidityPool).balance;

        // should be able to withdraw arbitrary amounts not tied to any particular validator
        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.queueETHWithdrawal(uint256(val1.pubkeyHash), 1234 ether);

        // need to fast forward so that withdrawal is claimable
        vm.roll(block.number + (7200 * 15));

        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.completeQueuedETHWithdrawals(uint256(val1.pubkeyHash), /*receiveAsTokens=*/ true);

        // liquidity pool should have received the withdrawal
        assertEq(address(liquidityPool).balance, startingLPBalance + 1234 ether);

        // verify all validators are properly created and linked to the same node
        assertEq(address(etherFiNodesManager.etherFiNodeFromPubkeyHash(val1.pubkeyHash)), address(val1.etherFiNode));
        assertEq(address(etherFiNodesManager.etherFiNodeFromPubkeyHash(val2.pubkeyHash)), address(val2.etherFiNode));
        assertEq(address(etherFiNodesManager.etherFiNodeFromPubkeyHash(val3.pubkeyHash)), address(val3.etherFiNode));
        assertEq(address(etherFiNodesManager.etherFiNodeFromPubkeyHash(val4.pubkeyHash)), address(val4.etherFiNode));
        assertEq(address(val1.etherFiNode), address(val2.etherFiNode));
        assertEq(address(val1.etherFiNode), address(val3.etherFiNode));
        assertEq(address(val1.etherFiNode), address(val4.etherFiNode));
    }

    function test_withdrawMultipleSimultaneousWithdrawals() public {

        TestValidatorParams memory params = defaultTestValidatorParams;
        params.validatorSize = 64 ether;
        TestValidator memory val = helper_createValidator(params);

        // queue up multiple withdrawals
        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.queueETHWithdrawal(uint256(val.pubkeyHash), 1 ether);
        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.queueETHWithdrawal(uint256(val.pubkeyHash), 1 ether);
        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.queueETHWithdrawal(uint256(val.pubkeyHash), 1 ether);

        // need to fast forward so that withdrawal is claimable
        vm.roll(block.number + (7200 * 15));

        // all outstanding withdrawals should have been completed at once
        uint256 startingLPBalance = address(liquidityPool).balance;
        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.completeQueuedETHWithdrawals(uint256(val.pubkeyHash), /*receiveAsTokens=*/ true);

        assertEq(address(liquidityPool).balance, startingLPBalance + 3 ether);
    }

    // ---------- helpers specific to EL withdrawal tests ----------
    function _setExitRateLimit(uint256 capacity, uint256 refillPerSecond) internal {
        // admin was already granted ETHERFI_NODES_MANAGER_ADMIN_ROLE in setUp()
        vm.startPrank(admin);
        rateLimiter.setCapacity(etherFiNodesManager.EXIT_REQUEST_LIMIT_ID(), uint64(capacity * 1e9));
        rateLimiter.setRefillRate(etherFiNodesManager.EXIT_REQUEST_LIMIT_ID(), uint64(refillPerSecond * 1e9));
        vm.stopPrank();
    }

    function _requestsFromPubkeys(bytes[] memory pubkeys, uint64[] memory amountsGwei)
        internal
        pure
        returns (IEigenPod.WithdrawalRequest[] memory reqs)
    {
        require(pubkeys.length == amountsGwei.length, "test: length mismatch");
        reqs = new IEigenPod.WithdrawalRequest[](pubkeys.length);
        for (uint256 i = 0; i < pubkeys.length; ++i) {
            // NOTE: IEigenPod.WithdrawalRequest must match your interface type location
            reqs[i] = IEigenPodTypes.WithdrawalRequest({pubkey: pubkeys[i], amountGwei: amountsGwei[i]});
        }
    }

    function _resolvePod(bytes memory pubkey) internal view returns (IEtherFiNode etherFiNode, IEigenPod pod) {
        bytes32 pkHash = etherFiNodesManager.calculateValidatorPubkeyHash(pubkey);
        etherFiNode = etherFiNodesManager.etherFiNodeFromPubkeyHash(pkHash);
        pod = etherFiNode.getEigenPod();
        require(address(pod) != address(0), "test: node has no pod");
    }

    // ---------- tests for EL exits ----------
    function test_requestExecutionLayerTriggeredWithdrawal_samePod_fullExit_success() public {

        bytes[] memory pubkeys = new bytes[](3);
        uint256[] memory legacyIds = new uint256[](3);
        uint64[] memory amounts = new uint64[](3);
        pubkeys[0] = PK_16171;
        pubkeys[1] = PK_16172;
        pubkeys[2] = PK_16173;

        legacyIds[0] = 51715;
        legacyIds[1] = 51716;
        legacyIds[2] = 51717;

        vm.startPrank(admin);
        etherFiNodesManager.linkLegacyValidatorIds(legacyIds, pubkeys); 
        vm.stopPrank();
        _setExitRateLimit(172800, 2);

        ( , IEigenPod pod0) = _resolvePod(pubkeys[0]);
        ( , IEigenPod pod1) = _resolvePod(pubkeys[1]);
        ( , IEigenPod pod2) = _resolvePod(pubkeys[2]);
        assertEq(address(pod0), address(pod1));
        assertEq(address(pod0), address(pod2));

        // Build requests: full exits (amountGwei == 0)
        amounts[0] = 0; amounts[1] = 0; amounts[2] = 0;
        IEigenPod.WithdrawalRequest[] memory reqs = _requestsFromPubkeys(pubkeys, amounts);

        // Grant role to the triggering EOA
        vm.startPrank(roleRegistry.owner());
        roleRegistry.grantRole(
            etherFiNodesManager.ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE(),
            elExiter
        );
        vm.stopPrank();

        // Fetch the current per-request fee from the pod; value = fee * n + small headroom
        uint256 feePer = pod0.getWithdrawalRequestFee();
        uint256 n = reqs.length;
        uint256 valueToSend = feePer * n;
        vm.deal(elExiter, 1 ether);

        // Expect one event per request AFTER success
        for (uint256 i = 0; i < n; ++i) {
            bytes32 pkHash = etherFiNodesManager.calculateValidatorPubkeyHash(pubkeys[i]);
            vm.expectEmit(true, true, true, true, address(etherFiNodesManager));
            emit IEtherFiNodesManager.ValidatorWithdrawalRequestSent(
                address(pod0),
                pkHash,
                pubkeys[i]
            );
        }

        vm.prank(elExiter);
        etherFiNodesManager.requestExecutionLayerTriggeredWithdrawal{value: valueToSend}(reqs);
    }

    function test_requestExecutionLayerTriggeredWithdrawal_samePod_partialExit_success() public {

        bytes[] memory pubkeys = new bytes[](3);
        uint256[] memory legacyIds = new uint256[](3);
        uint64[] memory amounts = new uint64[](3);
        pubkeys[0] = PK_16171;
        pubkeys[1] = PK_16172;
        pubkeys[2] = PK_16173;

        legacyIds[0] = 51715;
        legacyIds[1] = 51716;
        legacyIds[2] = 51717;

        // Link and init
        vm.startPrank(admin);
        etherFiNodesManager.linkLegacyValidatorIds(legacyIds, pubkeys);
        vm.stopPrank();
        _setExitRateLimit(172800, 2);

        (, IEigenPod pod0) = _resolvePod(pubkeys[0]);
        (, IEigenPod pod1) = _resolvePod(pubkeys[1]);
        (, IEigenPod pod2) = _resolvePod(pubkeys[2]);
        assertEq(address(pod0), address(pod1));
        assertEq(address(pod0), address(pod2));

        // Build partial-exit requests (non-zero amounts)
        amounts[0] = 0;
        amounts[1] = 2_000 gwei;
        amounts[2] = 3_000 gwei;
        IEigenPod.WithdrawalRequest[] memory reqs = _requestsFromPubkeys(pubkeys, amounts);

        vm.startPrank(roleRegistry.owner());
        roleRegistry.grantRole(
            etherFiNodesManager.ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE(),
            elExiter
        );
        vm.stopPrank();

        // exact required ETH for fees
        uint256 feePer = pod0.getWithdrawalRequestFee();
        uint256 valueToSend = feePer * reqs.length;
        vm.deal(elExiter, 1 ether);
        vm.deal(eigenlayerAdmin, 1 ether);

        // Expect one ELExitRequestForwarded event per request
        for (uint256 i = 0; i < reqs.length; ++i) {
            bytes32 pkHash = etherFiNodesManager.calculateValidatorPubkeyHash(pubkeys[i]);
            vm.expectEmit(true, true, true, true, address(etherFiNodesManager));
            emit IEtherFiNodesManager.ValidatorWithdrawalRequestSent(
                address(pod0), pkHash, pubkeys[i]
            );
        }

        vm.prank(elExiter);
        etherFiNodesManager.requestExecutionLayerTriggeredWithdrawal{value: valueToSend}(reqs);
    }

    function test_rateLimitSetters_access_control() public {
        // Get the limit ID once to avoid interference with expectRevert
        bytes32 limitId = etherFiNodesManager.EXIT_REQUEST_LIMIT_ID();

        // Unauthorized caller -> revert
        vm.prank(user);
        vm.expectRevert();
        rateLimiter.setCapacity(limitId, 172800);

        vm.prank(user);
        vm.expectRevert();
        rateLimiter.setRefillRate(limitId, 2);

        // Authorized caller (admin in fork has the config role) -> success
        vm.startPrank(admin);
        rateLimiter.setCapacity(limitId, 172800);
        rateLimiter.setRefillRate(limitId, 2);
        vm.stopPrank();
    }

    function test_setProofSubmitter_access_control() public {
        // minimal setup to keep parity with your pattern
        bytes[] memory pubkeys = new bytes[](3);
        uint256[] memory legacyIds = new uint256[](3);
        pubkeys[0] = PK_16171;
        pubkeys[1] = PK_16172;
        pubkeys[2] = PK_16173;

        legacyIds[0] = 51715;
        legacyIds[1] = 51716;
        legacyIds[2] = 51717;

        vm.startPrank(admin);
        etherFiNodesManager.linkLegacyValidatorIds(legacyIds, pubkeys);
        vm.stopPrank();

        // Unauthorized caller -> revert
        vm.expectRevert();
        etherFiNodesManager.setProofSubmitter(legacyIds[0], address(1));
    }

    function test_requestExecutionLayerTriggeredWithdrawal_requires_role_reverts() public {

        bytes[] memory pubkeys = new bytes[](3);
        uint256[] memory legacyIds = new uint256[](3);
        uint64[] memory amounts = new uint64[](3);
        pubkeys[0] = PK_16171;
        pubkeys[1] = PK_16172;
        pubkeys[2] = PK_16173;

        legacyIds[0] = 51715;
        legacyIds[1] = 51716;
        legacyIds[2] = 51717;

        vm.startPrank(admin);
        etherFiNodesManager.linkLegacyValidatorIds(legacyIds, pubkeys); 
        vm.stopPrank();
        _setExitRateLimit(172800, 2);

        // All same pod (sanity)
        (, IEigenPod pod0) = _resolvePod(pubkeys[0]);
        (, IEigenPod pod1) = _resolvePod(pubkeys[1]);
        (, IEigenPod pod2) = _resolvePod(pubkeys[2]);
        assertEq(address(pod0), address(pod1));
        assertEq(address(pod0), address(pod2));

        // full exits
        amounts[0] = 0; amounts[1] = 0; amounts[2] = 0;
        IEigenPod.WithdrawalRequest[] memory reqs = _requestsFromPubkeys(pubkeys, amounts);

        // No EL_TRIGGER_EXIT role granted to msg.sender -> revert
        uint256 feePer = pod0.getWithdrawalRequestFee();
        uint256 valueToSend = feePer * reqs.length;
        vm.deal(address(this), 1 ether);

        vm.expectRevert();
        etherFiNodesManager.requestExecutionLayerTriggeredWithdrawal{value: valueToSend}(reqs);
    }

    // ---------- tests for unrestaking rate limiter ----------
    function test_unrestakingRateLimitSetters_access_control() public {
        // Get the limit ID once to avoid interference with expectRevert
        bytes32 limitId = etherFiNodesManager.UNRESTAKING_LIMIT_ID();

        // Unauthorized caller -> revert
        vm.prank(user);
        vm.expectRevert();
        rateLimiter.setCapacity(limitId, 172_800_000_000_000); // 172,800 ETH in gwei

        vm.prank(user);
        vm.expectRevert();
        rateLimiter.setRefillRate(limitId, 2_000_000_000); // 2 ETH/sec in gwei

        // Authorized caller (admin in fork has the config role) -> success
        vm.startPrank(admin);
        rateLimiter.setCapacity(limitId, 172_800_000_000_000); // 172,800 ETH in gwei
        rateLimiter.setRefillRate(limitId, 2_000_000_000); // 2 ETH/sec in gwei
        vm.stopPrank();
    }

    function test_queueETHWithdrawal_unrestaking_rate_limit() public {
        // Setup: create a validator and initialize unrestaking limiter
        TestValidator memory val = helper_createValidator(defaultTestValidatorParams);

        // Set a low capacity for testing (10 ETH = 10_000_000_000 gwei)
        vm.startPrank(admin);
        rateLimiter.setCapacity(etherFiNodesManager.UNRESTAKING_LIMIT_ID(), 10_000_000_000);
        vm.stopPrank();

        // First withdrawal within limit should succeed
        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.queueETHWithdrawal(uint256(val.pubkeyHash), 5 ether);

        // Second withdrawal within limit should succeed
        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.queueETHWithdrawal(uint256(val.pubkeyHash), 4 ether);

        // Third withdrawal exceeding limit should fail
        vm.expectRevert();
        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.queueETHWithdrawal(uint256(val.pubkeyHash), 2 ether);
    }

    function test_queueWithdrawals_unrestaking_rate_limit() public {
        // Setup: create a validator and initialize unrestaking limiter
        TestValidator memory val = helper_createValidator(defaultTestValidatorParams);

        // Set a low capacity for testing (20 ETH = 20_000_000_000 gwei)
        vm.startPrank(admin);
        rateLimiter.setCapacity(etherFiNodesManager.UNRESTAKING_LIMIT_ID(), 20_000_000_000);
        vm.stopPrank();

        // Create withdrawal params with shares (shares = wei, so 15 ether = 15 ETH)
        IDelegationManager.QueuedWithdrawalParams[] memory params = 
            new IDelegationManager.QueuedWithdrawalParams[](1);

        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = IStrategy(address(0xbeaC0eeEeeeeEEeEeEEEEeeEEeEeeeEeeEEBEaC0));

        uint256[] memory shares = new uint256[](1);
        shares[0] = 15 ether; // 15 ETH worth of shares

        params[0].strategies = strategies;
        params[0].depositShares = shares;
        params[0].__deprecated_withdrawer = address(0);

        // First withdrawal within limit should succeed
        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.queueWithdrawals(uint256(val.pubkeyHash), params);

        // Second withdrawal exceeding limit should fail (15 + 10 > 20)
        shares[0] = 10 ether;
        vm.expectRevert();
        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.queueWithdrawals(uint256(val.pubkeyHash), params);
    }

    function test_directNodeAccess_queueETHWithdrawal_rate_limit() public {
        // Test that direct access to EtherFiNode also respects rate limits
        TestValidator memory val = helper_createValidator(defaultTestValidatorParams);

        // Set a very low capacity for testing (1 ETH = 1_000_000_000 gwei)
        vm.startPrank(admin);
        rateLimiter.setCapacity(etherFiNodesManager.UNRESTAKING_LIMIT_ID(), 1_000_000_000);
        vm.stopPrank();

        // Direct call to EtherFiNode should also be rate limited
        IEtherFiNode etherFiNode = IEtherFiNode(val.etherFiNode);

        // First call should succeed
        vm.prank(eigenlayerAdmin);
        etherFiNode.queueETHWithdrawal(0.5 ether);

        // Second call exceeding limit should fail
        vm.expectRevert();
        vm.prank(eigenlayerAdmin);
        etherFiNode.queueETHWithdrawal(0.6 ether);
    }

    function test_exitRequestsRateLimiting_partial_exit_success() public {
        bytes32 limitId = etherFiNodesManager.EXIT_REQUEST_LIMIT_ID();

        // Initialize exit rate limiter with large capacity
        vm.prank(admin);
        rateLimiter.setCapacity(limitId, 5000_000_000_000); // 5000 ETH

        // Setup validator for partial exit
        bytes[] memory pubkeys = new bytes[](1);
        uint256[] memory legacyIds = new uint256[](1);
        uint64[] memory amounts = new uint64[](1);
        pubkeys[0] = PK_16171;
        legacyIds[0] = 51715;
        amounts[0] = 1_000_000_000; // 1 ETH partial exit

        vm.prank(admin);
        etherFiNodesManager.linkLegacyValidatorIds(legacyIds, pubkeys);

        // Grant role to the triggering EOA
        vm.startPrank(roleRegistry.owner());
        roleRegistry.grantRole(
            etherFiNodesManager.ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE(),
            elExiter
        );
        vm.stopPrank();

        IEigenPod.WithdrawalRequest[] memory reqs = _requestsFromPubkeys(pubkeys, amounts);
        (, IEigenPod pod0) = _resolvePod(pubkeys[0]);
        uint256 feePer = pod0.getWithdrawalRequestFee();
        uint256 valueToSend = feePer * reqs.length;

        // This should succeed (1 ETH << 5000 ETH capacity)
        vm.deal(elExiter, 1 ether);
        vm.prank(elExiter);
        etherFiNodesManager.requestExecutionLayerTriggeredWithdrawal{value: valueToSend}(reqs);
    }

    function test_exitRequestsRateLimiting_capacity_admin_functions() public {
        bytes32 limitId = etherFiNodesManager.EXIT_REQUEST_LIMIT_ID();

        // Test setting capacity
        vm.prank(admin);
        rateLimiter.setCapacity(limitId, 200_000_000_000); // 200 ETH

        // Test setting refill rate
        vm.prank(admin);
        rateLimiter.setRefillRate(limitId, 5_000_000_000); // 5 ETH/sec

        // Test non-admin cannot change settings
        vm.prank(user);
        vm.expectRevert();
        rateLimiter.setCapacity(limitId, 300_000_000_000);

        vm.prank(user);
        vm.expectRevert();
        rateLimiter.setRefillRate(limitId, 10_000_000_000);
    }

    // ---------- Unrestaking rate limiting tests ----------

    // TODO: re-implement
    /*
    function test_unrestakingRateLimiting_capacity_consumption() public {
        bytes32 limitId = etherFiNodesManager.UNRESTAKING_LIMIT_ID();

        // Set capacity to 50 ETH
        vm.prank(admin);
        rateLimiter.setCapacity(limitId, 50_000_000_000);

        // Test that unauthorized access is blocked by the access control we added
        // This verifies our security fix is working - preventing DoS attacks
        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        etherFiNodesManager.consumeUnrestakingCapacity(30 ether);
    }
    */

    function test_unrestakingRateLimiting_role_based_admin() public {
        bytes32 limitId = etherFiNodesManager.UNRESTAKING_LIMIT_ID();

        // Debug: check if admin has the role
        bool hasRole = roleRegistry.hasRole(rateLimiter.ETHERFI_RATE_LIMITER_ADMIN_ROLE(), admin);
        assertTrue(hasRole, "Admin should have the rate limiter role");

        // Admin should be able to set capacity and refill rate
        vm.prank(admin);
        rateLimiter.setCapacity(limitId, 100_000_000_000); // 100 ETH
        vm.prank(admin);
        rateLimiter.setRefillRate(limitId, 3_000_000_000); // 3 ETH/sec

        // Verify the values were set correctly
        (uint64 capacity, , uint64 refillRate, ) = rateLimiter.getLimit(limitId);
        assertEq(capacity, 100_000_000_000);
        assertEq(refillRate, 3_000_000_000);

        // Test setting capacity without admin role should fail
        vm.prank(user);
        vm.expectRevert();
        rateLimiter.setCapacity(limitId, 200_000_000_000);

        vm.prank(user);
        vm.expectRevert();
        rateLimiter.setRefillRate(limitId, 5_000_000_000);

        // Verify values remain unchanged after failed attempts
        (capacity, , refillRate, ) = rateLimiter.getLimit(limitId);
        assertEq(capacity, 100_000_000_000);
        assertEq(refillRate, 3_000_000_000);
    }

    // TODO: re-implement
    /*
    function test_unrestakingRateLimiting_multiple_consumption() public {
        bytes32 limitId = etherFiNodesManager.UNRESTAKING_LIMIT_ID();

        // Set capacity to 100 ETH
        vm.prank(admin);
        rateLimiter.setCapacity(limitId, 100_000_000_000);

        // Test that unauthorized access is blocked by the access control we added
        // This verifies our security fix prevents multiple unauthorized consumption attempts
        vm.expectRevert(IEtherFiNodesManager.IncorrectRole.selector);
        etherFiNodesManager.consumeUnrestakingCapacity(20 ether);
    }
    */

    // ---------- EIP-7251 Consolidation tests ----------
    function test_requestConsolidation_samePod_success() public {
        // Setup validators in same pod
        bytes[] memory pubkeys = new bytes[](3);
        uint256[] memory legacyIds = new uint256[](3);
        pubkeys[0] = PK_16171;
        pubkeys[1] = PK_16172; 
        pubkeys[2] = PK_16173;
        legacyIds[0] = 51715;
        legacyIds[1] = 51716;
        legacyIds[2] = 51717;

        vm.prank(admin);
        etherFiNodesManager.linkLegacyValidatorIds(legacyIds, pubkeys);

        (, IEigenPod pod0) = _resolvePod(pubkeys[0]);
        (, IEigenPod pod1) = _resolvePod(pubkeys[1]);
        (, IEigenPod pod2) = _resolvePod(pubkeys[2]);

        // Sanity check: all same pod
        assertEq(address(pod0), address(pod1));
        assertEq(address(pod1), address(pod2));

        // Create consolidation requests
        IEigenPodTypes.ConsolidationRequest[] memory reqs = new IEigenPodTypes.ConsolidationRequest[](2);
        reqs[0] = IEigenPodTypes.ConsolidationRequest({
            srcPubkey: pubkeys[0],
            targetPubkey: pubkeys[1]
        });
        reqs[1] = IEigenPodTypes.ConsolidationRequest({
            srcPubkey: pubkeys[1], 
            targetPubkey: pubkeys[2]
        });

        uint256 feePer = pod0.getConsolidationRequestFee();
        uint256 valueToSend = feePer * reqs.length;

        // Expect consolidation events
        vm.expectEmit(true, true, true, true, address(etherFiNodesManager));
        emit IEtherFiNodesManager.ValidatorConsolidationRequested(
            address(pod0), 
            etherFiNodesManager.calculateValidatorPubkeyHash(pubkeys[0]), 
            pubkeys[0], 
            etherFiNodesManager.calculateValidatorPubkeyHash(pubkeys[1]), 
            pubkeys[1]
        );
        vm.expectEmit(true, true, true, true, address(etherFiNodesManager));
        emit IEtherFiNodesManager.ValidatorConsolidationRequested(
            address(pod0), 
            etherFiNodesManager.calculateValidatorPubkeyHash(pubkeys[1]), 
            pubkeys[1], 
            etherFiNodesManager.calculateValidatorPubkeyHash(pubkeys[2]), 
            pubkeys[2]
        );
        vm.deal(admin, 1 ether);
        vm.prank(admin);
        etherFiNodesManager.requestConsolidation{value: valueToSend}(reqs);
    }

    function test_getConsolidationRequestFee() public {
        // Setup validator
        bytes[] memory pubkeys = new bytes[](1);
        uint256[] memory legacyIds = new uint256[](1);
        pubkeys[0] = PK_16171;
        legacyIds[0] = 51715;

        vm.prank(admin);
        etherFiNodesManager.linkLegacyValidatorIds(legacyIds, pubkeys);

        (, IEigenPod pod0) = _resolvePod(pubkeys[0]);

        uint256 directFee = pod0.getConsolidationRequestFee();
        uint256 managerFee = etherFiNodesManager.getConsolidationRequestFee(address(pod0));

        assertEq(directFee, managerFee);
    }

    function test_requestConsolidation_samePod_switchToCompounding_success() public {
        bytes[] memory pubkeys = new bytes[](2);
        uint256[] memory legacyIds = new uint256[](2);
        pubkeys[0] = PK_16171;
        pubkeys[1] = PK_16172;
        legacyIds[0] = 51715;
        legacyIds[1] = 51716;

        vm.startPrank(admin);
        etherFiNodesManager.linkLegacyValidatorIds(legacyIds, pubkeys);
        vm.stopPrank();

        (, IEigenPod pod0) = _resolvePod(pubkeys[0]);
        (, IEigenPod pod1) = _resolvePod(pubkeys[1]);

        // Sanity check: all same pod
        assertEq(address(pod0), address(pod1));

        // Create switch to compounding requests (srcPubkey == targetPubkey)
        IEigenPodTypes.ConsolidationRequest[] memory reqs = new IEigenPodTypes.ConsolidationRequest[](2);
        reqs[0] = IEigenPodTypes.ConsolidationRequest({
            srcPubkey: pubkeys[0],
            targetPubkey: pubkeys[0]  // Same pubkey = switch to compounding
        });
        reqs[1] = IEigenPodTypes.ConsolidationRequest({
            srcPubkey: pubkeys[1],
            targetPubkey: pubkeys[1]  // Same pubkey = switch to compounding
        });

        uint256 feePer = pod0.getConsolidationRequestFee();
        uint256 valueToSend = feePer * reqs.length;

        // Expect switch to compounding events
        vm.expectEmit(true, true, true, true, address(etherFiNodesManager));
        emit IEtherFiNodesManager.ValidatorSwitchToCompoundingRequested(
            address(pod0),
            etherFiNodesManager.calculateValidatorPubkeyHash(pubkeys[0]),
            pubkeys[0]
        );
        vm.expectEmit(true, true, true, true, address(etherFiNodesManager));
        emit IEtherFiNodesManager.ValidatorSwitchToCompoundingRequested(
            address(pod0),
            etherFiNodesManager.calculateValidatorPubkeyHash(pubkeys[1]),
            pubkeys[1]
        );

        vm.deal(admin, 1 ether);
        vm.prank(admin);
        etherFiNodesManager.requestConsolidation{value: valueToSend}(reqs);
    }

    function test_requestConsolidation_mixedOperations_success() public {
        bytes[] memory pubkeys = new bytes[](3);
        uint256[] memory legacyIds = new uint256[](3);
        pubkeys[0] = PK_16171;
        pubkeys[1] = PK_16172;
        pubkeys[2] = PK_16173;
        legacyIds[0] = 51715;
        legacyIds[1] = 51716;
        legacyIds[2] = 51717;

        vm.startPrank(admin);
        etherFiNodesManager.linkLegacyValidatorIds(legacyIds, pubkeys);
        vm.stopPrank();

        (, IEigenPod pod0) = _resolvePod(pubkeys[0]);

        // Mixed operations: consolidation + switch to compounding
        IEigenPodTypes.ConsolidationRequest[] memory reqs = new IEigenPodTypes.ConsolidationRequest[](2);
        reqs[0] = IEigenPodTypes.ConsolidationRequest({
            srcPubkey: pubkeys[0],
            targetPubkey: pubkeys[1]  // Consolidation
        });
        reqs[1] = IEigenPodTypes.ConsolidationRequest({
            srcPubkey: pubkeys[2],
            targetPubkey: pubkeys[2]  // Switch to compounding
        });

        uint256 feePer = pod0.getConsolidationRequestFee();
        uint256 valueToSend = feePer * reqs.length;

        // Expect mixed events
        vm.expectEmit(true, true, true, true, address(etherFiNodesManager));
        emit IEtherFiNodesManager.ValidatorConsolidationRequested(
            address(pod0),
            etherFiNodesManager.calculateValidatorPubkeyHash(pubkeys[0]),
            pubkeys[0],
            etherFiNodesManager.calculateValidatorPubkeyHash(pubkeys[1]),
            pubkeys[1]
        );
        vm.expectEmit(true, true, true, true, address(etherFiNodesManager));
        emit IEtherFiNodesManager.ValidatorSwitchToCompoundingRequested(
            address(pod0),
            etherFiNodesManager.calculateValidatorPubkeyHash(pubkeys[2]),
            pubkeys[2]
        );

        vm.deal(admin, 1 ether);
        vm.prank(admin);
        etherFiNodesManager.requestConsolidation{value: valueToSend}(reqs);
    }

    function test_requestConsolidation_accessControl_onlyAdmin() public {
        bytes[] memory pubkeys = new bytes[](1);
        uint256[] memory legacyIds = new uint256[](1);
        pubkeys[0] = PK_16171;
        legacyIds[0] = 51715;

        vm.startPrank(admin);
        etherFiNodesManager.linkLegacyValidatorIds(legacyIds, pubkeys);
        vm.stopPrank();

        (, IEigenPod pod0) = _resolvePod(pubkeys[0]);

        // Create consolidation request
        IEigenPodTypes.ConsolidationRequest[] memory reqs = new IEigenPodTypes.ConsolidationRequest[](1);
        reqs[0] = IEigenPodTypes.ConsolidationRequest({
            srcPubkey: pubkeys[0],
            targetPubkey: pubkeys[0]
        });

        uint256 feePer = pod0.getConsolidationRequestFee();
        uint256 valueToSend = feePer * reqs.length;

        // Non-admin should revert
        address nonAdmin = vm.addr(123);
        vm.deal(nonAdmin, 1 ether);
        vm.expectRevert();
        vm.prank(nonAdmin);
        etherFiNodesManager.requestConsolidation{value: valueToSend}(reqs);

        // Admin should succeed
        vm.deal(admin, 1 ether);
        vm.prank(admin);
        etherFiNodesManager.requestConsolidation{value: valueToSend}(reqs);
    }

    function test_requestConsolidation_insufficientFee_reverts() public {
        bytes[] memory pubkeys = new bytes[](2);
        uint256[] memory legacyIds = new uint256[](2);
        pubkeys[0] = PK_16171;
        pubkeys[1] = PK_16172;
        legacyIds[0] = 51715;
        legacyIds[1] = 51716;

        vm.startPrank(admin);
        etherFiNodesManager.linkLegacyValidatorIds(legacyIds, pubkeys);
        vm.stopPrank();

        (, IEigenPod pod0) = _resolvePod(pubkeys[0]);

        // Create consolidation requests
        IEigenPodTypes.ConsolidationRequest[] memory reqs = new IEigenPodTypes.ConsolidationRequest[](2);
        reqs[0] = IEigenPodTypes.ConsolidationRequest({
            srcPubkey: pubkeys[0],
            targetPubkey: pubkeys[1]
        });
        reqs[1] = IEigenPodTypes.ConsolidationRequest({
            srcPubkey: pubkeys[1],
            targetPubkey: pubkeys[0]
        });

        uint256 feePer = pod0.getConsolidationRequestFee();
        uint256 correctFee = feePer * reqs.length;

        // Test insufficient fee (if fee > 0)
        if (feePer > 0) {
            vm.deal(admin, 1 ether);
            vm.expectRevert(IEtherFiNodesManager.InsufficientConsolidationFees.selector);
            vm.prank(admin);
            etherFiNodesManager.requestConsolidation{value: correctFee - 1}(reqs);
        }

        // Test correct fee should work
        vm.deal(admin, 1 ether);
        vm.prank(admin);
        etherFiNodesManager.requestConsolidation{value: correctFee}(reqs);
    }

    function test_requestConsolidation_emptyRequests_reverts() public {
        // Empty request array should revert
        IEigenPodTypes.ConsolidationRequest[] memory reqs = new IEigenPodTypes.ConsolidationRequest[](0);

        vm.deal(admin, 1 ether);
        vm.expectRevert(IEtherFiNodesManager.EmptyConsolidationRequest.selector);
        vm.prank(admin);
        etherFiNodesManager.requestConsolidation{value: 0}(reqs);
    }

    function test_requestConsolidation_feeCalculation_accuracy() public {
        bytes[] memory pubkeys = new bytes[](3);
        uint256[] memory legacyIds = new uint256[](3);
        pubkeys[0] = PK_16171;
        pubkeys[1] = PK_16172;
        pubkeys[2] = PK_16173;
        legacyIds[0] = 51715;
        legacyIds[1] = 51716;
        legacyIds[2] = 51717;

        vm.startPrank(admin);
        etherFiNodesManager.linkLegacyValidatorIds(legacyIds, pubkeys);
        vm.stopPrank();

        (, IEigenPod pod0) = _resolvePod(pubkeys[0]);

        // Test different batch sizes for fee calculation accuracy using only known working pubkeys
        uint256 feePer = pod0.getConsolidationRequestFee();

        for (uint256 batchSize = 1; batchSize <= 3; batchSize++) {
            IEigenPodTypes.ConsolidationRequest[] memory reqs = new IEigenPodTypes.ConsolidationRequest[](batchSize);
            for (uint256 i = 0; i < batchSize; i++) {
                reqs[i] = IEigenPodTypes.ConsolidationRequest({
                    srcPubkey: pubkeys[i],
                    targetPubkey: pubkeys[(i + 1) % pubkeys.length]
                });
            }

            uint256 expectedFee = feePer * batchSize;

            vm.deal(admin, 2 ether);
            vm.prank(admin);
            etherFiNodesManager.requestConsolidation{value: expectedFee}(reqs);
        }
    }

}

