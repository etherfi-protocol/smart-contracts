// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/AuctionManagerGasOptimized.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

contract AuctionManagerGasOptimizedTest is TestSetup {
    AuctionManagerGasOptimized auctionGasOptimizedInstance;
    
    function setUp() public {
        setUpTests();

        uint256 numBidsBefore = auctionInstance.numberOfBids();

        AuctionManagerGasOptimized auctionManager = new AuctionManagerGasOptimized();

        vm.prank(owner);
        UUPSUpgradeable(address(auctionInstance)).upgradeToAndCall(
            address(auctionManager),
            abi.encodeWithSelector(
                AuctionManagerGasOptimized.initializeOnUpgradeVersion2.selector
            )
        );

        uint256 numBidsAfter = auctionInstance.numberOfBids();
        assertEq(numBidsAfter, 10 * ((numBidsBefore - 1 + 10) / 10)); 

        auctionGasOptimizedInstance = AuctionManagerGasOptimized(address(auctionInstance));
    }   

    function test_createBidWorksAfterGasOptimization() public {
        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 25);
        
        // Create new bids under batched system
        startHoax(alice);
        uint256[] memory bidIds = auctionInstance.createBid{value: 0.3 ether}(3, 0.1 ether);
        
        // Verify batch storage
        uint256 batchId = bidIds[0] / 10;
        (
            uint16 numBids,
            uint16 isActiveBits,
            uint32 amountPerBidInGwei,
            ,
            address bidderAddress
        ) = auctionGasOptimizedInstance.batchedBids(batchId);
        
        assertEq(numBids, 3);
        assertEq(isActiveBits, 7); // 111 in binary for 3 active bids
        assertEq(amountPerBidInGwei, 0.1 gwei); 
        assertEq(bidderAddress, alice);
        
        assertTrue(auctionInstance.isBidActive(bidIds[0]));
        assertEq(auctionInstance.getBidOwner(bidIds[0]), alice);
    }

    function test_CancelBidWorksAfterGasOptimization() public {
        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 15);
        
        startHoax(alice);
        uint256[] memory bidIds = auctionInstance.createBid{value: 0.2 ether}(2, 0.1 ether);
        
        uint256 balanceBefore = alice.balance;
        auctionGasOptimizedInstance.cancelBid(bidIds[0]);
        
        uint256 batchId = bidIds[0] / 10;
        (, uint16 isActiveBits,,, address bidderAddress) = auctionGasOptimizedInstance.batchedBids(batchId);
        
        assertEq(isActiveBits, 2); // 10 in binary - first bid cancelled
        assertFalse(auctionGasOptimizedInstance.isBidActive(bidIds[0]));
        assertTrue(auctionGasOptimizedInstance.isBidActive(bidIds[1]));
        assertEq(bidderAddress, alice);
        assertEq(alice.balance, balanceBefore + 0.1 ether);
    }

    function test_BidActivationAfterGasOptimization() public {
        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 15);
                
        startHoax(alice);
        uint256[] memory bidIds = auctionGasOptimizedInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
        
        uint256[] memory selectedBids = new uint256[](1);
        selectedBids[0] = bidIds[0];
        
        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(selectedBids, false);
        assertFalse(auctionGasOptimizedInstance.isBidActive(bidIds[0]));
        
        stakingManagerInstance.batchCancelDeposit(selectedBids);
        assertTrue(auctionGasOptimizedInstance.isBidActive(bidIds[0]));
    }

    function test_BatchBoundaries() public {
        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 25);
        
        
        startHoax(alice);
        uint256[] memory bidIds = auctionInstance.createBid{value: 1 ether}(10, 0.1 ether);
        
        uint256 batchId = bidIds[0] / 10;
        (uint16 numBids, uint16 isActiveBits,,,) = auctionGasOptimizedInstance.batchedBids(batchId);
        
        assertEq(numBids, 10);
        assertEq(isActiveBits, 1023); // 1111111111 in binary
        
        uint256[] memory moreBids = auctionGasOptimizedInstance.createBid{value: 0.5 ether}(5, 0.1 ether);
        
        uint256 nextBatchId = moreBids[0] / 10;
        (numBids, isActiveBits,,,) = auctionGasOptimizedInstance.batchedBids(nextBatchId);
        
        assertEq(numBids, 5);
        assertEq(isActiveBits, 31); // 11111 in binary
    }
}