// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/interfaces/IWETH.sol";
import "../src/interfaces/ILiquidityPool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "../lib/murky/src/Merkle.sol";

contract StakingManagerV1Syko is StakingManager {
    mapping (uint256 => address) test;

    function add(uint256 id, address addr) public {
        test[id] = addr;
    }

    function getTest(uint256 id) public view returns (address) {
        return test[id];
    }
}

contract StakingManagerV2Syko is StakingManager {
    struct TestData {
        address add;
        bool isV2;
    }

    mapping (uint256 => TestData) testData;

    function getTest(uint256 id) public view returns (TestData memory) {
        return testData[id];
    }
}

contract AuctionManagerV2Test is AuctionManager {
    function isUpgraded() public pure returns(bool){
        return true;
    }
}

contract BNFTV2 is BNFT {
    function isUpgraded() public pure returns(bool){
        return true;
    }
}

contract TNFTV2 is TNFT {
    function isUpgraded() public pure returns(bool){
        return true;
    }
}

contract EtherFiNodesManagerV2 is EtherFiNodesManager {
    function isUpgraded() public pure returns(bool){
        return true;
    }
}

contract ProtocolRevenueManagerV2 is ProtocolRevenueManager {
    function isUpgraded() public pure returns(bool){
        return true;
    }
}

contract EtherFiNodeV2 is EtherFiNode {
    function isUpgraded() public pure returns(bool){
        return true;
    }
}

contract NodeOperatorManagerV2 is NodeOperatorManager {
    function isUpgraded() public pure returns(bool){
        return true;
    }
}

contract UpgradeTest is TestSetup {
    using stdStorage for StdStorage;

    AuctionManagerV2Test public auctionManagerV2Instance;
    BNFTV2 public BNFTV2Instance;
    TNFTV2 public TNFTV2Instance;
    EtherFiNodesManagerV2 public etherFiNodesManagerV2Instance;
    ProtocolRevenueManagerV2 public protocolRevenueManagerV2Instance;
    StakingManager public stakingManagerV2Instance;
    NodeOperatorManagerV2 public nodeOperatorManagerV2Instance;

    uint256[] public slippageArray;

    function setUp() public {
        setUpTests();
    }

    function test_CanUpgradeAuctionManager() public {
        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            5
        );

        assertEq(auctionInstance.numberOfActiveBids(), 0);
        hoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);

        assertEq(auctionInstance.numberOfActiveBids(), 1);
        assertEq(auctionInstance.getImplementation(), address(auctionImplementation));

        AuctionManagerV2Test auctionManagerV2Implementation = new AuctionManagerV2Test();

        vm.prank(owner);
        auctionInstance.upgradeTo(address(auctionManagerV2Implementation));

        auctionManagerV2Instance = AuctionManagerV2Test(address(auctionManagerProxy));

        vm.expectRevert("Initializable: contract is already initialized");
        vm.prank(owner);
        auctionManagerV2Instance.initialize(address(nodeOperatorManagerInstance));

        assertEq(auctionManagerV2Instance.getImplementation(), address(auctionManagerV2Implementation));

        // Check that state is maintained
        assertEq(auctionManagerV2Instance.numberOfActiveBids(), 1);
        assertEq(auctionManagerV2Instance.isUpgraded(), true);
    }

    function test_CanUpgradeBNFT() public {
        assertEq(BNFTInstance.getImplementation(), address(BNFTImplementation));

        BNFTV2 BNFTV2Implementation = new BNFTV2();

        vm.prank(owner);
        BNFTInstance.upgradeTo(address(BNFTV2Implementation));

        BNFTV2Instance = BNFTV2(address(BNFTProxy));
        
        vm.expectRevert("Initializable: contract is already initialized");
        vm.prank(owner);
        BNFTV2Instance.initialize(address(stakingManagerInstance));

        assertEq(BNFTV2Instance.getImplementation(), address(BNFTV2Implementation));
        assertEq(BNFTV2Instance.isUpgraded(), true);
    }

    function test_CanUpgradeTNFT() public {
        assertEq(TNFTInstance.getImplementation(), address(TNFTImplementation));

        TNFTV2 TNFTV2Implementation = new TNFTV2();

        vm.prank(owner);
        TNFTInstance.upgradeTo(address(TNFTV2Implementation));

        TNFTV2Instance = TNFTV2(address(TNFTProxy));
        
        vm.expectRevert("Initializable: contract is already initialized");
        vm.prank(owner);
        TNFTV2Instance.initialize(address(stakingManagerInstance));

        assertEq(TNFTV2Instance.getImplementation(), address(TNFTV2Implementation));
        assertEq(TNFTV2Instance.isUpgraded(), true);
    }

    function test_CanUpgradeEtherFiNodesManager() public {
        assertEq(managerInstance.getImplementation(), address(managerImplementation));

        vm.prank(alice);
        managerInstance.setStakingRewardsSplit(uint64(100000), uint64(100000), uint64(400000), uint64(400000));

        EtherFiNodesManagerV2 managerV2Implementation = new EtherFiNodesManagerV2();

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(alice);
        managerInstance.upgradeTo(address(managerV2Implementation));

        vm.prank(owner);
        managerInstance.upgradeTo(address(managerV2Implementation));

        etherFiNodesManagerV2Instance = EtherFiNodesManagerV2(payable(address(etherFiNodeManagerProxy)));

        vm.expectRevert("Initializable: contract is already initialized");
        vm.prank(owner);
        etherFiNodesManagerV2Instance.initialize(
            address(treasuryInstance),
            address(auctionInstance),
            address(stakingManagerInstance),
            address(TNFTInstance),
            address(BNFTInstance)
        );

        assertEq(etherFiNodesManagerV2Instance.getImplementation(), address(managerV2Implementation));
        assertEq(etherFiNodesManagerV2Instance.isUpgraded(), true);

        // State is maintained
        (uint64 treasury, uint64 nodeOperator, uint64 tnft, uint64 bnft) = etherFiNodesManagerV2Instance.stakingRewardsSplit();
        assertEq(treasury, 100000);
        assertEq(nodeOperator, 100000);
        assertEq(tnft, 400000);
        assertEq(bnft, 400000);
    }

    function test_CanUpgradeProtocolRevenueManager() public {
        assertEq(protocolRevenueManagerInstance.getImplementation(), address(protocolRevenueManagerImplementation));

        vm.prank(alice);

        ProtocolRevenueManagerV2 protocolRevenueManagerV2Implementation = new ProtocolRevenueManagerV2();

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(alice);
        protocolRevenueManagerInstance.upgradeTo(address(protocolRevenueManagerV2Implementation));

        vm.prank(owner);
        protocolRevenueManagerInstance.upgradeTo(address(protocolRevenueManagerV2Implementation));

        protocolRevenueManagerV2Instance = ProtocolRevenueManagerV2(payable(address(protocolRevenueManagerProxy)));

        vm.expectRevert("Initializable: contract is already initialized");
        vm.prank(owner);
        protocolRevenueManagerV2Instance.initialize();

        assertEq(protocolRevenueManagerV2Instance.getImplementation(), address(protocolRevenueManagerV2Implementation));
        assertEq(protocolRevenueManagerV2Instance.isUpgraded(), true);
    }

    function test_CanUpgradeStakingManager() public {
        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 5);

        startHoax(alice);
        auctionInstance.createBid{value: 0.1 ether}(
            1,
            0.1 ether
        );

        vm.stopPrank();

        assertEq(stakingManagerInstance.getImplementation(), address(stakingManagerImplementation));

        vm.prank(alice);
        stakingManagerInstance.setMaxBatchDepositSize(uint128(25));

        StakingManager stakingManagerV2Implementation = new StakingManager();

        vm.expectRevert("Initializable: contract is already initialized");
        vm.prank(owner);
        stakingManagerV2Implementation.initialize(address(auctionInstance), address(depositContractEth2));


        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(alice);
        stakingManagerInstance.upgradeTo(address(stakingManagerV2Implementation));

        vm.prank(owner);
        stakingManagerInstance.upgradeTo(address(stakingManagerV2Implementation));

        stakingManagerV2Instance = StakingManager(address(stakingManagerProxy));

        vm.expectRevert("Initializable: contract is already initialized");
        vm.prank(owner);
        stakingManagerV2Instance.initialize(address(auctionInstance), address(depositContractEth2));

        assertEq(stakingManagerV2Instance.getImplementation(), address(stakingManagerV2Implementation));
        // assertEq(stakingManagerV2Instance.isUpgraded(), true);
        
        // State is maintained
        assertEq(stakingManagerV2Instance.maxBatchDepositSize(), 25);

        assertEq(address(stakingManagerV2Instance.depositContractEth2()), address(depositContractEth2));
    }

    function test_canUpgradeEtherFiNode() public {        
        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            5
        );

        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        uint256[] memory bidIds = auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);

        uint256[] memory processedBids = stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(bidIds, false);

        address safe1 = managerInstance.etherfiNodeAddress(processedBids[0]);
        console.log(safe1);

        vm.stopPrank();
        
        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            5
        );

        startHoax(alice);
        uint256[] memory aliceBidIds = auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
        uint256[] memory aliceProcessedBids = stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(aliceBidIds, false);

        address safe2 = managerInstance.etherfiNodeAddress(aliceProcessedBids[0]);
        console.log(safe2);

        vm.stopPrank();

        EtherFiNodeV2 etherFiNodeV2 = new EtherFiNodeV2();

        vm.prank(owner);
        stakingManagerInstance.upgradeEtherFiNode(address(etherFiNodeV2));


        safe1 = managerInstance.etherfiNodeAddress(processedBids[0]);
        safe2 = managerInstance.etherfiNodeAddress(aliceProcessedBids[0]);

        EtherFiNodeV2 safe1V2 = EtherFiNodeV2(payable(safe1));
        EtherFiNodeV2 safe2V2 = EtherFiNodeV2(payable(safe2));

        assertEq(safe1V2.isUpgraded(), true);
        assertEq(safe2V2.isUpgraded(), true);
    }

    function test_CanUpgradeNodeOperatorManager() public {

        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 5);
        
        assertEq(nodeOperatorManagerInstance.getImplementation(), address(nodeOperatorManagerImplementation));

        NodeOperatorManagerV2 nodeOperatorManagerV2Implementation = new NodeOperatorManagerV2();

        vm.expectRevert("Initializable: contract is already initialized");
        vm.prank(owner);
        nodeOperatorManagerV2Implementation.initialize();


        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(alice);
        nodeOperatorManagerInstance.upgradeTo(address(nodeOperatorManagerV2Implementation));

        vm.prank(owner);
        nodeOperatorManagerInstance.upgradeTo(address(nodeOperatorManagerV2Implementation));

        nodeOperatorManagerV2Instance = NodeOperatorManagerV2(address(nodeOperatorManagerProxy));

        vm.expectRevert("Initializable: contract is already initialized");
        vm.prank(owner);
        nodeOperatorManagerV2Instance.initialize();

        assertEq(nodeOperatorManagerV2Instance.getImplementation(), address(nodeOperatorManagerV2Implementation));
        assertEq(nodeOperatorManagerV2Instance.isUpgraded(), true);
    }

    function test_Storage() public {
        StakingManager stakingManagerV1Implementation = new StakingManagerV1Syko();
        StakingManager stakingManagerV2Implementation = new StakingManagerV2Syko();
        
        vm.prank(owner);
        stakingManagerInstance.upgradeTo(address(stakingManagerV1Implementation));
        StakingManagerV1Syko stakingManagerV1Instance = StakingManagerV1Syko(address(stakingManagerProxy));
        assertEq(stakingManagerV1Instance.getImplementation(), address(stakingManagerV1Implementation));

        stakingManagerV1Instance.add(1, address(owner));
        assertEq(stakingManagerV1Instance.getTest(1), address(owner));       

        vm.prank(owner);
        stakingManagerInstance.upgradeTo(address(stakingManagerV2Implementation));
        StakingManagerV2Syko stakingManagerV2Instance = StakingManagerV2Syko(address(stakingManagerProxy));
        assertEq(stakingManagerV2Instance.getImplementation(), address(stakingManagerV2Implementation));

        assertEq(stakingManagerV2Instance.getTest(1).add, address(owner));       
        assertEq(stakingManagerV2Instance.getTest(1).isV2, false);       

    }
}
