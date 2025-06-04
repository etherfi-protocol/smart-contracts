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
    ITNFT tnft;
    IBNFT bnft;
    NodeOperatorManager nodeOperatorManager = NodeOperatorManager(0xd5edf7730ABAd812247F6F54D7bd31a52554e35E);

    address admin = vm.addr(0x9876543210);
    address forwarder = vm.addr(0x1234567890);
    address stakingDepositContract = address(0x00000000219ab540356cBB839Cbe05303d7705Fa);
    address eigenPodManager = address(0x91E677b07F7AF907ec9a428aafA9fc14a0d3A338);
    address delegationManager = address(0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A);
    address etherFiNodeBeacon = address(0x3c55986Cfee455E2533F4D29006634EcF9B7c03F);
    RoleRegistry roleRegistry = RoleRegistry(0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9);

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
        EtherFiNode etherFiNodeImpl = new EtherFiNode(
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
        roleRegistry.grantRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_ADMIN_ROLE(), admin);
        roleRegistry.grantRole(etherFiNodesManager.ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE(), forwarder);
        roleRegistry.grantRole(stakingManager.STAKING_MANAGER_NODE_CREATOR_ROLE(), admin);
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
        vm.expectRevert("Ownable: caller is not the owner");
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
        address etherFiNode = stakingManager.instantiateEtherFiNode(true);

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

        vm.prank(forwarder);
        etherFiNodesManager.queueETHWithdrawal(uint256(pubkeyHash), 1 ether);

        // poke some withdrawable funds into the restakedExecutionLayerGwei storage slot of the eigenpod
        address eigenpod = etherFiNodesManager.getEigenPod(uint256(pubkeyHash));
        vm.store(eigenpod, bytes32(uint256(52)) /*slot*/, bytes32(uint256(50 ether / 1 gwei)));

        vm.roll(block.number + (7200 * 15));
        vm.prank(forwarder);
        etherFiNodesManager.completeQueuedETHWithdrawals(uint256(pubkeyHash), true);
    }
}
