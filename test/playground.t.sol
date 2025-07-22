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
import "../src/libraries/DepositDataRootGenerator.sol";


contract PlaygroundTest is Test, ArrayTestHelper {

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

}