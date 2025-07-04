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
import "../src/EtherFiNode.sol";
import "../src/NodeOperatorManager.sol";
import "../src/interfaces/ITNFT.sol";
import "../src/interfaces/IBNFT.sol";
import "../src/AuctionManager.sol";
import "../src/libraries/DepositRootGenerator.sol";


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

    TestValidatorParams defaultTestValidatorParams;

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
        EtherFiNodesManager etherFiNodesManagerImpl = new EtherFiNodesManager(address(stakingManager), address(roleRegistry));
        vm.prank(etherFiNodesManager.owner());
        etherFiNodesManager.upgradeTo(address(etherFiNodesManagerImpl));

        vm.prank(auctionManager.owner());
        auctionManager.disableWhitelist();

        // permissions
        vm.startPrank(roleRegistry.owner());
        roleRegistry.grantRole(etherFiNodeImpl.ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE(), address(etherFiNodesManager));
        roleRegistry.grantRole(etherFiNodeImpl.ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE(), address(stakingManager));
        roleRegistry.grantRole(etherFiNodeImpl.ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE(), eigenlayerAdmin);
        roleRegistry.grantRole(etherFiNodeImpl.ETHERFI_NODE_CALL_FORWARDER_ROLE(), address(etherFiNodesManager));
        roleRegistry.grantRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_ADMIN_ROLE(), admin);
        roleRegistry.grantRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE(), callForwarder);
        roleRegistry.grantRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE(), eigenlayerAdmin);
        roleRegistry.grantRole(stakingManager.STAKING_MANAGER_NODE_CREATOR_ROLE(), admin);
        vm.stopPrank();

        defaultTestValidatorParams = TestValidatorParams({
            nodeOperator: address(0), // attach to a random node operator
            etherFiNode: address(0),  // create a new etherfiNode
            bidId: 0,                 // create and claim a new bid
            withdrawable: true,       // simulate validator being ready to withdraw from pod
            validatorSize: 32 ether
        });

    }

    struct TestValidatorParams {
        address nodeOperator;  // if none specified a new operator will be created
        address etherFiNode;   // if none specified a new node will be deployed
        uint256 bidId;         // if none specified a new bid will be placed
        uint256 validatorSize; // if none specified default to 32 eth
        bool withdrawable;     // give the eigenpod "validatorSize" worth of withdrawable beacon shares
    }

    struct TestValidator {
        address etherFiNode;
        address eigenPod;
        uint256 legacyId;
        bytes32 pubkeyHash;
        address nodeOperator;
        uint256 validatorSize;
    }

    function helper_createValidator(TestValidatorParams memory _params) public returns (TestValidator memory) {

        // create a copy or else successive calls of this method can mutate the input unexpectedly
        TestValidatorParams memory params = TestValidatorParams(_params.nodeOperator, _params.etherFiNode, _params.bidId, _params.validatorSize, _params.withdrawable);

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

        bytes memory pubkey = vm.randomBytes(48);
        bytes memory signature = vm.randomBytes(96);

        // initial deposit
        address eigenPod = address(IEtherFiNode(params.etherFiNode).getEigenPod());
        bytes32 initialDepositRoot = depositRootGenerator.generateDepositRoot(
            pubkey,
            signature,
            etherFiNodesManager.addressToWithdrawalCredentials(eigenPod),
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
        bytes32 confirmDepositRoot = depositRootGenerator.generateDepositRoot(
            pubkey,
            signature,
            etherFiNodesManager.addressToWithdrawalCredentials(eigenPod),
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
            validatorSize: params.validatorSize
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
            roleRegistry.grantRole(EtherFiNode(payable(address(etherFiNode))).ETHERFI_NODE_CALL_FORWARDER_ROLE(), user);
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
        bytes32 initialDepositRoot = depositRootGenerator.generateDepositRoot(
            pubkey,
            signature,
            etherFiNodesManager.addressToWithdrawalCredentials(eigenPod),
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

        bytes32 confirmDepositRoot = depositRootGenerator.generateDepositRoot(
            pubkey,
            signature,
            etherFiNodesManager.addressToWithdrawalCredentials(eigenPod),
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
        bytes32 initialDepositRoot = depositRootGenerator.generateDepositRoot(pubkey, signature, "", 1 ether);
        IStakingManager.DepositData memory initialDepositData = IStakingManager.DepositData({
            publicKey: pubkey,
            signature: signature,
            depositDataRoot: initialDepositRoot,
            ipfsHashForEncryptedValidatorKey: "test_ipfs_hash"
        });
        uint256[] memory bidIds = new uint256[](1);
        vm.prank(admin);
        vm.expectRevert(IStakingManager.InvalidCaller.selector);
        stakingManager.createBeaconValidators(toArray(initialDepositData), bidIds, address(0));

        // only liquidityPool can call confirmAndFundBeaconValidators
        bytes32 confirmDepositRoot = depositRootGenerator.generateDepositRoot(pubkey, signature, "", 31 ether);
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
        vm.deal(val.eigenPod, 1 ether);

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

        // create a few large validators of different sizes
        TestValidatorParams memory params = defaultTestValidatorParams;
        params.validatorSize = 64 ether;
        TestValidator memory val1 = helper_createValidator(params);

        // attach all of them to the same etherfi node
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

}

