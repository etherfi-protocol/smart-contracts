// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/AuctionManagerGasOptimized.sol";
import "../src/StakingManager.sol";
import "../src/interfaces/IStakingManager.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

contract AuctionManagerGasOptimizedTest is TestSetup {
    AuctionManagerGasOptimized auctionGasOptimizedInstance;
    
    function setUp() public {
        setUpTests();

        uint256 numBidsBefore = auctionInstance.numberOfBids();

        AuctionManagerGasOptimized auctionManager = new AuctionManagerGasOptimized();
        StakingManager stakingManager = new StakingManager();

        vm.prank(owner);
        UUPSUpgradeable(address(auctionInstance)).upgradeToAndCall(
            address(auctionManager),
            abi.encodeWithSelector(
                AuctionManagerGasOptimized.initializeOnUpgradeVersion2.selector
            )
        );

        vm.prank(owner);
        UUPSUpgradeable(address(stakingManagerInstance)).upgradeTo(address(stakingManager));

        uint256 numBidsAfter = auctionInstance.numberOfBids();
        assertEq(numBidsAfter, 256 * ((numBidsBefore - 1 + 256) / 256)); 

        auctionGasOptimizedInstance = AuctionManagerGasOptimized(address(auctionInstance));
    }   

    function test_createBidWorksAfterGasOptimization() public {
        startHoax(alice);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 250);
        uint256[] memory batchBidId = auctionInstance.createBid{value: 20 ether}(200, 0.1 ether);
        
        uint256 batchId = batchBidId[0];
        (
            uint16 numBids,
            uint32 amountPerBidInGwei,
            uint216 availableBidsBitset
        ) = auctionGasOptimizedInstance.batchedBids(batchId);

        uint256 bidId = batchId * 256;
        address bidderAddress = auctionGasOptimizedInstance.getBidOwner(bidId);
        
        assertEq(numBids, 200);
        assertEq(availableBidsBitset, 1606938044258990275541962092341162602522202993782792835301375); // 111..(200 times) in binary for 3 active bids
        assertEq(amountPerBidInGwei, 0.1 gwei); 
        assertEq(bidderAddress, alice);
        
        assertTrue(auctionInstance.isBidActive(bidId));
        assertEq(auctionInstance.getBidOwner(bidId), alice);
    }

    function test_CancelBidWorksAfterGasOptimization() public {
        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 15);

        uint256 amountPerBidInGwei = 0.1 ether;
        
        startHoax(alice);
        uint256[] memory bidIds = auctionInstance.createBid{value: 0.2 ether}(2, amountPerBidInGwei);
        uint256 batchId = bidIds[0];

        uint256 firstBidId = batchId * 256;
        uint256 secondBidId = batchId * 256 + 1;
        
        uint256 balanceBefore = alice.balance;
        auctionGasOptimizedInstance.cancelBid(firstBidId);
        
        address bidderAddress = auctionGasOptimizedInstance.getBidOwner(firstBidId);

        ( , , uint216 availableBidsBitset) = auctionGasOptimizedInstance.batchedBids(batchId);
        
        assertEq(availableBidsBitset, 2); // 10 in binary - first bid cancelled
        assertFalse(auctionGasOptimizedInstance.isBidActive(firstBidId));
        assertTrue(auctionGasOptimizedInstance.isBidActive(secondBidId));
        assertEq(bidderAddress, alice);
        assertEq(alice.balance, balanceBefore + 0.1 ether);
    }

    function test_BidActivationAfterGasOptimization() public {
        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 15);
                
        startHoax(alice);
        uint256[] memory batchId = auctionGasOptimizedInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
        
        uint256[] memory selectedBids = new uint256[](1);
        selectedBids[0] = batchId[0] * 256;
        
        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(selectedBids, false);
        assertFalse(auctionGasOptimizedInstance.isBidActive(selectedBids[0]));
        
        stakingManagerInstance.batchCancelDeposit(selectedBids);
        assertTrue(auctionGasOptimizedInstance.isBidActive(selectedBids[0]));
    }

    function test_BatchBoundaries() public {
        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 250);

        startHoax(alice);
        uint256[] memory bidIds = auctionInstance.createBid{value: 21.6 ether}(216, 0.1 ether);

        uint256 batchId = bidIds[0];
        (
            uint16 numBids,
            uint32 amountPerBidInGwei,
            uint216 availableBidsBitset
        ) = auctionGasOptimizedInstance.batchedBids(batchId);

        assertEq(numBids, 216);
        assertEq(availableBidsBitset, 105312291668557186697918027683670432318895095400549111254310977535); // 1111111111..(216 times) in binary
        
        uint256[] memory moreBids = auctionGasOptimizedInstance.createBid{value: 0.5 ether}(5, 0.1 ether);
        
        uint256 nextBatchId = moreBids[0];
        (numBids, amountPerBidInGwei, availableBidsBitset) = auctionGasOptimizedInstance.batchedBids(nextBatchId);
        
        assertEq(numBids, 5);
        assertEq(availableBidsBitset, 31); // 11111 in binary
    }

    function test_BatchAcceptBidsAfterOptimization() public {
        startHoax(alice);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 250);
        uint256[] memory batchBidId = auctionInstance.createBid{value: 20 ether}(200, 0.1 ether);
        
        uint256 batchId = batchBidId[0];
        (
            uint16 numBids,
            uint32 amountPerBidInGwei,
            uint216 availableBidsBitset
        ) = auctionGasOptimizedInstance.batchedBids(batchId);

        uint256 bidId = batchId * 256;
        address bidderAddress = auctionGasOptimizedInstance.getBidOwner(bidId);
        
        assertEq(numBids, 200);
        assertEq(availableBidsBitset, 1606938044258990275541962092341162602522202993782792835301375); // 111..(200 times) in binary for 3 active bids
        assertEq(amountPerBidInGwei, 0.1 gwei); 
        assertEq(bidderAddress, alice);
        
        assertTrue(auctionInstance.isBidActive(bidId));
        assertEq(auctionInstance.getBidOwner(bidId), alice);

        uint256 numActiveBids = auctionGasOptimizedInstance.numberOfActiveBids();

        IStakingManager.BatchBidRequest[] memory batchedBidRequests = new IStakingManager.BatchBidRequest[](1);
        batchedBidRequests[0] = IStakingManager.BatchBidRequest({
            batchId: batchId,
            bidAcceptBitmap: 1267650600228229401496702157823 // 111..(80 times)000..(10 times)111...(10 times) total 90 bids accepting
        });

        stakingManagerInstance.setMaxBatchDepositSize(100);

        deal(alice, 10000 ether);
        stakingManagerInstance.batchDepositWithBatchedBids{value: 90 * 32 ether}(batchedBidRequests, false);

        // since we accepted 90 bids
        assertEq(numActiveBids - 90, auctionGasOptimizedInstance.numberOfActiveBids());
    }
}