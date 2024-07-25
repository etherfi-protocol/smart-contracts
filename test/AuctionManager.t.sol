// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";

contract AuctionManagerTest is TestSetup {
    event BidCreated(
        address indexed bidder,
        uint256 amountPerBid,
        uint256[] bidId,
        uint64[] ipfsIndexArray
    );
    event BidCancelled(uint256 indexed bidId);
    event BidReEnteredAuction(uint256 indexed bidId);
    event Received(address indexed sender, uint256 value);
    
    function setUp() public {
        setUpTests();
    }

    function test_DisableInitializer() public {
        vm.expectRevert("Initializable: contract is already initialized");
        vm.prank(owner);
        auctionImplementation.initialize(address(nodeOperatorManagerInstance));
    }
    

    function test_AuctionManagerContractInstantiatedCorrectly() public {
        assertEq(auctionInstance.numberOfBids(), 1);
        assertEq(
            auctionInstance.stakingManagerContractAddress(),
            address(stakingManagerInstance)
        );
        assertEq(auctionInstance.whitelistBidAmount(), 0.001 ether);
        assertEq(auctionInstance.minBidAmount(), 0.01 ether);
        assertEq(auctionInstance.whitelistBidAmount(), 0.001 ether);
        assertEq(auctionInstance.maxBidAmount(), 5 ether);
        assertEq(auctionInstance.numberOfActiveBids(), 0);
        assertTrue(auctionInstance.whitelistEnabled());
    }

    function test_ReEnterAuctionManagerFailsIfBidAlreadyActive() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 5);

        vm.prank(alice);
        uint256[] memory bidId1 = auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);

        vm.prank(address(stakingManagerInstance));
        vm.expectRevert("Bid already active");
        auctionInstance.reEnterAuction(bidId1[0]);

        vm.prank(owner);
        vm.expectRevert("Only staking manager contract function");
        auctionInstance.reEnterAuction(bidId1[0]);
    }

    function test_DisableWhitelist() public {
        assertTrue(auctionInstance.whitelistEnabled());

        vm.expectRevert(AuctionManager.IncorrectRole.selector);
        vm.prank(owner);
        auctionInstance.disableWhitelist();

        vm.prank(alice);
        auctionInstance.disableWhitelist();

        assertFalse(auctionInstance.whitelistEnabled());
    }

    function test_EnableWhitelist() public {
        assertTrue(auctionInstance.whitelistEnabled());

        vm.prank(alice);
        auctionInstance.disableWhitelist();

        assertFalse(auctionInstance.whitelistEnabled());

        vm.expectRevert(AuctionManager.IncorrectRole.selector);
        vm.prank(owner);
        auctionInstance.enableWhitelist();

        vm.prank(alice);
        auctionInstance.enableWhitelist();

        assertTrue(auctionInstance.whitelistEnabled());
    }

    function test_createBidWorks() public {
        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            5
        );

        vm.prank(bob);
        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            5
        );

        vm.prank(henry);
        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            5
        );

        assertFalse(nodeOperatorManagerInstance.isWhitelisted(jess));
        assertTrue(nodeOperatorManagerInstance.isWhitelisted(alice));

        hoax(alice);
        uint256[] memory bid1Id = auctionInstance.createBid{value: 0.001 ether}(
            1,
            0.001 ether
        );

        assertEq(auctionInstance.numberOfActiveBids(), 1);

        (
            uint256 amount,
            uint64 ipfsIndex,
            address bidderAddress,
            bool isActive
        ) = auctionInstance.bids(bid1Id[0]);

        assertEq(amount, 0.001 ether);
        assertEq(ipfsIndex, 0);
        assertEq(bidderAddress, alice);
        assertTrue(isActive);

        startHoax(alice);
        auctionInstance.createBid{value: 0.004 ether}(4, 0.001 ether);

        vm.expectRevert("Bid size is too small");
        auctionInstance.createBid{value: 0.004 ether}(0, 0.001 ether);
        vm.stopPrank();

        vm.expectRevert("Insufficient public keys");
        startHoax(alice);
        auctionInstance.createBid{value: 1 ether}(1, 1 ether);
        vm.stopPrank();

        assertTrue(auctionInstance.whitelistEnabled());

        vm.expectRevert("Only whitelisted addresses");
        hoax(jess);
        auctionInstance.createBid{value: 0.01 ether}(1, 0.01 ether);

        assertEq(auctionInstance.numberOfActiveBids(), 5);

        // Owner disables whitelist
        vm.prank(alice);
        auctionInstance.disableWhitelist();

        // Bob can still bid below min bid amount because he was whitelisted
        hoax(bob);
        uint256[] memory bobBidIds = auctionInstance.createBid{
            value: 0.001 ether
        }(1, 0.001 ether);

        (amount, ipfsIndex, bidderAddress, isActive) = auctionInstance.bids(
            bobBidIds[0]
        );
        assertEq(amount, 0.001 ether);
        assertEq(ipfsIndex, 0);
        assertEq(bidderAddress, bob);
        assertTrue(isActive);

        assertEq(auctionInstance.numberOfActiveBids(), 6);

        // jess cannot bid below the min bid amount because he was not whitelisted
        vm.expectRevert("Incorrect bid value");
        hoax(jess);
        uint256[] memory henryBidIds = auctionInstance.createBid{
            value: 0.001 ether
        }(1, 0.001 ether);

        hoax(henry);
        henryBidIds = auctionInstance.createBid{value: 0.01 ether}(
            1,
            0.01 ether
        );
        (amount, ipfsIndex, bidderAddress, isActive) = auctionInstance.bids(
            henryBidIds[0]
        );
        assertEq(amount, 0.01 ether);
        assertEq(ipfsIndex, 0);
        assertEq(bidderAddress, henry);
        assertTrue(isActive);

        // Owner enables whitelist
        vm.prank(alice);
        auctionInstance.enableWhitelist();

        vm.expectRevert("Only whitelisted addresses");
        hoax(jess);
        auctionInstance.createBid{value: 0.01 ether}(1, 0.01 ether);

        hoax(bob);
        bobBidIds = auctionInstance.createBid{value: 0.001 ether}(
            1,
            0.001 ether
        );

        (amount, ipfsIndex, bidderAddress, isActive) = auctionInstance.bids(
            bobBidIds[0]
        );
        assertEq(amount, 0.001 ether);
        assertEq(ipfsIndex, 1);
        assertEq(bidderAddress, bob);
        assertTrue(isActive);
    }

    function test_CreateBidMinMaxAmounts() public {
        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            5
        );

        vm.prank(henry);
        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            5
        );

        vm.expectRevert("Incorrect bid value");
        hoax(alice);
        auctionInstance.createBid{value: 0.00001 ether}(1, 0.00001 ether);

        vm.expectRevert("Incorrect bid value");
        hoax(alice);
        auctionInstance.createBid{value: 5.1 ether}(1, 5.1 ether);

        vm.prank(alice);
        auctionInstance.disableWhitelist();

        vm.expectRevert("Incorrect bid value");
        hoax(alice);
        auctionInstance.createBid{value: 5.1 ether}(1, 5.1 ether);

        vm.expectRevert("Incorrect bid value");
        hoax(alice);
        auctionInstance.createBid{value: 0.00001 ether}(1, 0.00001 ether);

        vm.expectRevert("Incorrect bid value");
        hoax(jess);
        auctionInstance.createBid{value: 0.001 ether}(1, 0.001 ether);

        vm.expectRevert("Incorrect bid value");
        hoax(henry);
        auctionInstance.createBid{value: 5.1 ether}(1, 5.1 ether);
    }

    function test_createBidFailsIfBidSizeIsLargerThanKeysRemaining() public {
        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(
            aliceIPFSHash,
            3
        );

        hoax(alice);
        uint256[] memory bidIds = auctionInstance.createBid{value: 0.2 ether}(
            2,
            0.1 ether
        );

        (uint256 amount, uint64 ipfsIndex, address bidderAddress, bool isActive) = auctionInstance.bids(bidIds[0]);
        assertEq(amount, 0.1 ether);
        assertEq(ipfsIndex, 0);
        assertEq(bidderAddress, alice);
        assertTrue(isActive);

        vm.expectRevert("Insufficient public keys");
        hoax(alice);
        auctionInstance.createBid{value: 0.2 ether}(2, 0.1 ether);

        hoax(alice);
        auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
    }

    function test_createBidFailsIfIPFSIndexMoreThanTotalKeys() public {
        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(
            aliceIPFSHash,
            1
        );

        hoax(alice);
        auctionInstance.createBid{value: 0.1 ether}(
            1,
            0.1 ether
        );

        vm.expectRevert("Insufficient public keys");
        hoax(alice);
        auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);

        vm.expectRevert("Insufficient public keys");
        hoax(alice);
        auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
    }

    function test_createBidBatch() public {
        startHoax(alice);
        nodeOperatorManagerInstance.registerNodeOperator(
            aliceIPFSHash,
            10
        );

        uint256[] memory bidIds = auctionInstance.createBid{value: 0.5 ether}(
            5,
            0.1 ether
        );

        vm.stopPrank();

        (
            uint256 amount,
            uint64 ipfsIndex,
            address bidderAddress,
            bool isActive
        ) = auctionInstance.bids(bidIds[0]);

        assertEq(amount, 0.1 ether);
        assertEq(ipfsIndex, 0);
        assertEq(bidderAddress, alice);
        assertTrue(isActive);

        (amount, ipfsIndex, bidderAddress, isActive) = auctionInstance.bids(
            bidIds[1]
        );

        assertEq(amount, 0.1 ether);
        assertEq(ipfsIndex, 1);
        assertEq(bidderAddress, alice);
        assertTrue(isActive);

        (amount, ipfsIndex, bidderAddress, isActive) = auctionInstance.bids(
            bidIds[2]
        );

        assertEq(amount, 0.1 ether);
        assertEq(ipfsIndex, 2);
        assertEq(bidderAddress, alice);
        assertTrue(isActive);

        (amount, ipfsIndex, bidderAddress, isActive) = auctionInstance.bids(
            bidIds[3]
        );

        assertEq(amount, 0.1 ether);
        assertEq(ipfsIndex, 3);
        assertEq(bidderAddress, alice);
        assertTrue(isActive);

        (amount, ipfsIndex, bidderAddress, isActive) = auctionInstance.bids(
            bidIds[4]
        );

        assertEq(amount, 0.1 ether);
        assertEq(ipfsIndex, 4);
        assertEq(bidderAddress, alice);
        assertTrue(isActive);

        assertEq(bidIds.length, 5);

        startHoax(bob);
        nodeOperatorManagerInstance.registerNodeOperator(
            aliceIPFSHash,
            10
        );

        uint256[] memory bobBidIds = auctionInstance.createBid{value: 1 ether}(
            10,
            0.1 ether
        );

        vm.stopPrank();

        assertEq(bobBidIds.length, 10);

        (amount, ipfsIndex, bidderAddress, isActive) = auctionInstance.bids(
            bobBidIds[0]
        );

        assertEq(amount, 0.1 ether);
        assertEq(ipfsIndex, 0);
        assertEq(bidderAddress, bob);
        assertTrue(isActive);

        (amount, ipfsIndex, bidderAddress, isActive) = auctionInstance.bids(
            bobBidIds[9]
        );

        assertEq(amount, 0.1 ether);
        assertEq(ipfsIndex, 9);
        assertEq(bidderAddress, bob);
        assertTrue(isActive);
    }

    function test_createBidBatchFailsWithIncorrectValue() public {
        hoax(alice);
        nodeOperatorManagerInstance.registerNodeOperator(
            aliceIPFSHash,
            10
        );

        vm.expectRevert("Incorrect bid value");
        hoax(alice);
        auctionInstance.createBid{value: 0.4 ether}(
            5,
            0.1 ether
        );
    }

    function test_CreateBidPauseable() public {
        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(
            aliceIPFSHash,
            5
        );

        assertFalse(auctionInstance.paused());
        vm.prank(alice);
        auctionInstance.pauseContract();
        assertTrue(auctionInstance.paused());

        vm.expectRevert("Pausable: paused");
        hoax(alice);
        auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);

        assertEq(auctionInstance.numberOfActiveBids(), 0);

        vm.prank(alice);
        auctionInstance.unPauseContract();

        hoax(alice);
        auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);

        assertEq(auctionInstance.numberOfActiveBids(), 1);
    }

    function test_CancelBidFailsWhenBidAlreadyInactive() public {
        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(
            aliceIPFSHash,
            5
        );

        hoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        uint256[] memory bid1Id = auctionInstance.createBid{value: 0.1 ether}(
            1,
            0.1 ether
        );

        hoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        auctionInstance.cancelBidBatch(bid1Id);

        hoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        vm.expectRevert("Bid already cancelled");
        auctionInstance.cancelBid(bid1Id[0]);
    }

    function test_CancelBidFailsWhenNotBidOwnerCalling() public {
        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(
            aliceIPFSHash,
            5
        );

        hoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);

        vm.prank(alice);
        vm.expectRevert("Invalid bid");
        auctionInstance.cancelBid(1);
    }

    function test_CancelBidFailsWhenNotExistingBid() public {
        vm.prank(alice);
        vm.expectRevert("Invalid bid");
        auctionInstance.cancelBid(1);
    }

    function test_CancelBidWorksIfBidIsNotCurrentHighest() public {
        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(
            aliceIPFSHash,
            5
        );

        vm.prank(0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf);
        nodeOperatorManagerInstance.registerNodeOperator(
            aliceIPFSHash,
            5
        );

        vm.prank(0xCDca97f61d8EE53878cf602FF6BC2f260f10240B);
        nodeOperatorManagerInstance.registerNodeOperator(
            aliceIPFSHash,
            5
        );

        hoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        auctionInstance.createBid{value: 0.1 ether}(
            1,
            0.1 ether
        );
        assertEq(auctionInstance.numberOfActiveBids(), 1);

        hoax(0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf);
        auctionInstance.createBid{value: 0.3 ether}(
            1,
            0.3 ether
        );
        assertEq(auctionInstance.numberOfActiveBids(), 2);

        startHoax(0xCDca97f61d8EE53878cf602FF6BC2f260f10240B);
        uint256[] memory bid3Id = auctionInstance.createBid{value: 0.2 ether}(
            1,
            0.2 ether
        );
        assertEq(address(auctionInstance).balance, 0.6 ether);
        assertEq(auctionInstance.numberOfActiveBids(), 3);

        uint256 balanceBeforeCancellation = 0xCDca97f61d8EE53878cf602FF6BC2f260f10240B
                .balance;
        auctionInstance.cancelBid(bid3Id[0]);
        assertEq(auctionInstance.numberOfActiveBids(), 2);

        (, , , bool isActive) = auctionInstance.bids(bid3Id[0]);

        assertEq(isActive, false);
        assertEq(address(auctionInstance).balance, 0.4 ether);
        assertEq(
            0xCDca97f61d8EE53878cf602FF6BC2f260f10240B.balance,
            balanceBeforeCancellation += 0.2 ether
        );
    }

    function test_PausableCancelBid() public {
        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            5
        );

        vm.prank(0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf);
        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            5
        );

        vm.prank(0xCDca97f61d8EE53878cf602FF6BC2f260f10240B);
        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            5
        );

        hoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        auctionInstance.createBid{value: 0.1 ether}(
            1,
            0.1 ether
        );
        assertEq(auctionInstance.numberOfActiveBids(), 1);

        hoax(0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf);
        uint256[] memory bid2Id = auctionInstance.createBid{value: 0.3 ether}(
            1,
            0.3 ether
        );
        assertEq(auctionInstance.numberOfActiveBids(), 2);

        vm.prank(alice);
        auctionInstance.pauseContract();

        vm.expectRevert("Pausable: paused");
        hoax(0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf);
        auctionInstance.cancelBid(bid2Id[0]);

        vm.prank(alice);
        auctionInstance.unPauseContract();

        assertEq(auctionInstance.numberOfActiveBids(), 2);

        hoax(0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf);
        auctionInstance.cancelBid(bid2Id[0]);

        assertEq(auctionInstance.numberOfActiveBids(), 1);
    }

    function test_ProcessAuctionFeeTransfer() public {
        assertEq(auctionInstance.accumulatedRevenue(), 0);

        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            5
        );

        hoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        uint256[] memory bid1Ids = auctionInstance.createBid{value: 0.1 ether}(
            1,
            0.1 ether
        );

        vm.prank(owner);
        vm.expectRevert("Only staking manager contract function");
        auctionInstance.processAuctionFeeTransfer(bid1Ids[0]);

        vm.prank(address(stakingManagerInstance));
        auctionInstance.processAuctionFeeTransfer(bid1Ids[0]);

        assertEq(auctionInstance.accumulatedRevenue(), 0.1 ether);
    }

    function test_SetMaxBidAmount() public {
        vm.prank(alice);
        vm.expectRevert("Min bid exceeds max bid");
        auctionInstance.setMaxBidPrice(0.001 ether);

        vm.prank(owner);
        vm.expectRevert(AuctionManager.IncorrectRole.selector);
        auctionInstance.setMaxBidPrice(10 ether);

        assertEq(auctionInstance.maxBidAmount(), 5 ether);
        vm.prank(alice);
        auctionInstance.setMaxBidPrice(10 ether);
        assertEq(auctionInstance.maxBidAmount(), 10 ether);
    }

    function test_SetMinBidAmount() public {
        vm.prank(alice);
        vm.expectRevert("Min bid exceeds max bid");
        auctionInstance.setMinBidPrice(5 ether);

        vm.prank(owner);
        vm.expectRevert(AuctionManager.IncorrectRole.selector);
        auctionInstance.setMinBidPrice(0.005 ether);

        assertEq(auctionInstance.minBidAmount(), 0.01 ether);
        vm.prank(alice);
        auctionInstance.setMinBidPrice(1 ether);
        assertEq(auctionInstance.minBidAmount(), 1 ether);
    }

    function test_SetWhitelistBidAmount() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        auctionInstance.updateWhitelistMinBidAmount(0.005 ether);

        vm.prank(owner);
        vm.expectRevert("Invalid Amount");
        auctionInstance.updateWhitelistMinBidAmount(0);

        vm.prank(owner);
        vm.expectRevert("Invalid Amount");
        auctionInstance.updateWhitelistMinBidAmount(0.2 ether);

        assertEq(auctionInstance.whitelistBidAmount(), 0.001 ether);
        vm.prank(owner);
        auctionInstance.updateWhitelistMinBidAmount(0.002 ether);
        assertEq(auctionInstance.whitelistBidAmount(), 0.002 ether);
    }

    function test_EventBidPlaced() public {

        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(
            aliceIPFSHash,
            5
        );

        uint256[] memory bidIdArray = new uint256[](1);
        uint64[] memory ipfsIndexArray = new uint64[](1);

        bidIdArray[0] = 1;
        ipfsIndexArray[0] = 0;

        vm.expectEmit(true, true, true, true);
        emit BidCreated(alice, 0.2 ether, bidIdArray, ipfsIndexArray);
        hoax(alice);
        auctionInstance.createBid{value: 0.2 ether}(1, 0.2 ether);
    }

    function test_EventBidCancelled() public {

        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(
            aliceIPFSHash,
            5
        );

        startHoax(alice);
        uint256[] memory bidIds = auctionInstance.createBid{value: 0.2 ether}(1, 0.2 ether);

        vm.expectEmit(true, false, false, true);
        emit BidCancelled(bidIds[0]);
        auctionInstance.cancelBid(bidIds[0]);      
    }

    function test_CanOnlySetAddressesOnce() public {
        vm.startPrank(owner);

        vm.expectRevert("Address already set");
        auctionInstance.setStakingManagerContractAddress(address(0));
    }

    function test_SetAccumulatedRevenueThreshold() public {
        vm.prank(bob);
        vm.expectRevert(AuctionManager.IncorrectRole.selector);
        auctionInstance.setAccumulatedRevenueThreshold(0.005 ether);

        // TODO: consider if 0 is an invalid threshold amount
        // vm.prank(alice);
        // vm.expectRevert("Invalid Amount");
        // auctionInstance.updateAccumulatedRevenueThreshold(0);

        vm.prank(alice);
        auctionInstance.setAccumulatedRevenueThreshold(2 ether);
        assertEq(auctionInstance.accumulatedRevenueThreshold(), 2 ether);
    }

    function test_AccumulateAuctionRevenue() public {
        vm.deal(alice, 100 ether);
        
        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 5); 

        vm.prank(alice);
        uint256[] memory bidId = auctionInstance.createBid{value: 0.5 ether}(1, 0.5 ether);

        _depositAndRegisterValidator(bidId[0], false);

        assertEq(auctionInstance.accumulatedRevenue(), 0.5 ether);

        vm.prank(alice);
        uint256[] memory bidIds2 = auctionInstance.createBid{value: 0.7 ether}(1, 0.7 ether);

        _depositAndRegisterValidator(bidIds2[0], false);

        assertEq(auctionInstance.accumulatedRevenue(), 0 ether);
        assertEq(address(membershipManagerInstance).balance, 1.2 ether);
    }
    
    function test_transferAccumulatedRevenue() public {
        vm.startPrank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 5);
        vm.stopPrank();

        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            5
        ); 

        startHoax(alice);

        uint256[] memory bidId = auctionInstance.createBid{value: 0.5 ether}(
            1,
            0.5 ether
        );
        vm.stopPrank();

        _depositAndRegisterValidator(bidId[0], false);

        assertEq(auctionInstance.accumulatedRevenue(), 0.5 ether);
        assertEq(address(auctionInstance).balance, 0.5 ether);
        assertEq(address(membershipManagerInstance).balance, 0 ether);

        vm.prank(alice);
        auctionInstance.transferAccumulatedRevenue();

        assertEq(auctionInstance.accumulatedRevenue(), 0 ether);
        assertEq(address(auctionInstance).balance, 0 ether);
        assertEq(address(membershipManagerInstance).balance, 0.5 ether);
    }
}
