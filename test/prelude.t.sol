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
import "../src/interfaces/ITNFT.sol";
import "../src/interfaces/IBNFT.sol";
import "../src/libraries/DepositRootGenerator.sol";


contract PreludeTest is Test, ArrayTestHelper {

    StakingManager stakingManager;
    ILiquidityPool liquidityPool;
    EtherFiNodesManager etherFiNodesManager;
    IAuctionManager auctionManager;
    ITNFT tnft;
    IBNFT bnft;

    address stakingDepositContract = address(0x00000000219ab540356cBB839Cbe05303d7705Fa);
    address eigenPodManager = address(0x91E677b07F7AF907ec9a428aafA9fc14a0d3A338);
    address delegationManager = address(0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A);

    // i don't think i need this anymore
    address oracle;


    function setUp() public {

        console2.log("setup start");
        vm.selectFork(vm.createFork(vm.envString("MAINNET_RPC_URL")));
        console2.log("post fork");

        stakingManager = StakingManager(0x25e821b7197B146F7713C3b89B6A4D83516B912d);
        liquidityPool = ILiquidityPool(0x308861A430be4cce5502d0A12724771Fc6DaF216);
        etherFiNodesManager = EtherFiNodesManager(payable(0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F));
        auctionManager = IAuctionManager(0x00C452aFFee3a17d9Cecc1Bcd2B8d5C7635C4CB9);
        tnft = ITNFT(0x7B5ae07E2AF1C861BcC4736D23f5f66A61E0cA5e);
        bnft = IBNFT(0x6599861e55abd28b91dd9d86A826eC0cC8D72c2c);

        // deploy new staking manager implementation
        StakingManager stakingManagerImpl = new StakingManager(
            address(liquidityPool),
            address(etherFiNodesManager),
            address(stakingDepositContract),
            address(auctionManager),
            address(tnft),
            address(bnft),
            oracle
        );
        vm.prank(stakingManager.owner());
        stakingManager.upgradeTo(address(stakingManagerImpl));
        console2.log("sm upgrade");

        // upgrade etherFiNode impl
        EtherFiNode etherFiNodeImpl = new EtherFiNode(
            eigenPodManager,
            delegationManager,
            address(liquidityPool),
            address(etherFiNodesManager)
        );
        vm.prank(stakingManager.owner());
        stakingManager.upgradeEtherFiNode(address(etherFiNodeImpl));
        console2.log("efn upgrade");

        // deploy new efnm implementation
        EtherFiNodesManager etherFiNodesManagerImpl = new EtherFiNodesManager(address(stakingManager));
        vm.prank(etherFiNodesManager.owner());
        etherFiNodesManager.upgradeTo(address(etherFiNodesManagerImpl));

        console2.log("efnm upgrade");
    }

    /*
                address etherFiNode = managerInstance.etherFiNodeFromId(11);
        root = generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            managerInstance.addressToWithdrawalCredentials(etherFiNode),
            1 ether
        );

        depositDataRootsForApproval[0] = generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            managerInstance.addressToWithdrawalCredentials(etherFiNode),
            31 ether
        );

        IStakingManager.DepositData memory depositData = IStakingManager
            .DepositData({
                publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });
            */


    function test_createBeaconValidators() public {

        // create a bid
        address nodeOperator = address(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        vm.prank(nodeOperator);
        uint256[] memory bidIds = auctionManager.createBid{value: 0.1 ether}(
            1,
            0.1 ether
        );

        bytes memory pubkey = hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c";
        bytes memory signature = hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df";
        //uint256 validatorID = 5;

        // TODO: fix
        address etherFiNode = address(0x1234);
        bytes32 depositRoot = depositRootGenerator.generateDepositRoot(
            pubkey,
            signature,
            etherFiNodesManager.addressToWithdrawalCredentials(etherFiNode),
            1 ether
        );
        //uint256[] memory validatorIDs = toArray_u256(validatorID);
        IStakingManager.DepositData memory depositData = IStakingManager
            .DepositData({
                publicKey: pubkey,
                signature: signature,
                depositDataRoot: depositRoot,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });
        //ISta[] memory depositDatas = toArray(depositData);

        stakingManager.createBeaconValidators(toArray(depositData), bidIds, etherFiNode);

    }
}
