// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";

contract LargeScenariosTest is TestSetup {
    bytes IPFS_Hash = "QmYsfDjQZfnSQkNyA4eVwswhakCusAx4Z6bzF89FZ91om3";

    function setUp() public {
        setUpTests();
    }

    // TODO(Dave,Brett): Re-enable after new rewards routing is finalized
    /*
    function test_LargeScenarioOne() public {
         // Alice, Bob, Chad - Operators
         // Dan, Elvis, Greg, - Stakers

        /// Register Node Operators
        bytes32[] memory danProof = merkle.getProof(whiteListedAddresses, 6);
        bytes32[] memory elvisProof = merkle.getProof(whiteListedAddresses, 7);
        bytes32[] memory gregProof = merkle.getProof(whiteListedAddresses, 8);

        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(
            IPFS_Hash,
            1000
        );

        vm.prank(bob);
        nodeOperatorManagerInstance.registerNodeOperator(
            IPFS_Hash,
            4000
        );

        vm.prank(chad);
        nodeOperatorManagerInstance.registerNodeOperator(
            IPFS_Hash,
            6000
        );

        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(
            IPFS_Hash,
            100
        );

        /// Actors Bid
        hoax(alice);
        uint256[] memory aliceBidIds = auctionInstance.createBid{
            value: 0.05 ether
        }(10, 0.005 ether);
        assertEq(aliceBidIds.length, 10);

        hoax(bob);
        uint256[] memory bobBidIds = auctionInstance.createBid{
            value: 0.1 ether
        }(50, 0.002 ether);
        assertEq(bobBidIds.length, 50);

        hoax(chad);
        uint256[] memory chadBidIds = auctionInstance.createBid{
            value: 0.5 ether
        }(100, 0.005 ether);
        assertEq(chadBidIds.length, 100);

        vm.expectRevert("Only whitelisted addresses");
        hoax(jess);
        auctionInstance.createBid{value: 0.5 ether}(100, 0.005 ether);

        assertEq(address(auctionInstance).balance, 0.65 ether);

        /// Actors Stake
        hoax(dan);
        uint256[] memory danProcessedBidIds = stakingManagerInstance
            .batchDepositWithBidIds{value: 32 ether}(aliceBidIds, danProof, dan);
        assertEq(danProcessedBidIds.length, 1);
        assertEq(danProcessedBidIds[0], aliceBidIds[0]);
        address staker = stakingManagerInstance.bidIdToStaker(
            danProcessedBidIds[0]
        );
        assertEq(staker, dan);
        bool isActive = auctionInstance.isBidActive(aliceBidIds[0]);
        assertFalse(isActive);
        address danNode = managerInstance.etherfiNodeAddress(
            danProcessedBidIds[0]
        );
        assert(danNode != address(0));
        assertTrue(
            IEtherFiNode(danNode).phase() ==
                IEtherFiNode.VALIDATOR_PHASE.STAKE_DEPOSITED
        );

        assertEq(address(stakingManagerInstance).balance, 32 ether);

        hoax(elvis);
        // 10 Deposits but only 9 bids
        uint256 balanceBefore = elvis.balance;
        uint256[] memory elvisProcessedBidIds = stakingManagerInstance
            .batchDepositWithBidIds{value: 320 ether}(aliceBidIds, elvisProof, elvis);
        assertEq(elvisProcessedBidIds.length, 9);
        // staking manager balance should be 320 ether. 320 ether - 32 ether (1 deposit) + 32 ether from previous deposit
        assertEq(address(stakingManagerInstance).balance, 320 ether);
        assertEq(elvis.balance, balanceBefore - 288 ether);
        isActive = auctionInstance.isBidActive(aliceBidIds[9]);
        assertFalse(isActive);

        // Elvis cancels a deposit
        vm.prank(elvis);
        balanceBefore = elvis.balance;
        {
            uint256[] memory bidToCancel = new uint256[](1);
            bidToCancel[0] = elvisProcessedBidIds[0];
            stakingManagerInstance.batchCancelDeposit(bidToCancel);
        }
        assertTrue(auctionInstance.isBidActive(elvisProcessedBidIds[0]));
        assertEq(address(stakingManagerInstance).balance, 320 ether - 32 ether);
        assertEq(elvis.balance, balanceBefore + 32 ether);

        // Elvis needs a new array because he cancelled a bid
        uint256[] memory newElvisProcessedBidIds = new uint256[](
            elvisProcessedBidIds.length - 1
        );
        newElvisProcessedBidIds[0] = elvisProcessedBidIds[1];
        newElvisProcessedBidIds[1] = elvisProcessedBidIds[2];
        newElvisProcessedBidIds[2] = elvisProcessedBidIds[3];
        newElvisProcessedBidIds[3] = elvisProcessedBidIds[4];
        newElvisProcessedBidIds[4] = elvisProcessedBidIds[5];
        newElvisProcessedBidIds[5] = elvisProcessedBidIds[6];
        newElvisProcessedBidIds[6] = elvisProcessedBidIds[7];
        newElvisProcessedBidIds[7] = elvisProcessedBidIds[8];

        hoax(greg);
        uint256[] memory gregProcessedBidIds = stakingManagerInstance
            .batchDepositWithBidIds{value: 32 ether}(bobBidIds, gregProof, greg);
        assertEq(gregProcessedBidIds.length, 1);

        IStakingManager.DepositData[]
            memory depositDataArray1 = new IStakingManager.DepositData[](1);

        /// Register Validators
        // generate deposit data
        bytes32 root = depGen.generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            managerInstance.generateWithdrawalCredentials(danNode),
            32 ether
        );
        IStakingManager.DepositData memory depositData = IStakingManager
            .DepositData({
                publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });

        depositDataArray1[0] = depositData;

        staker = stakingManagerInstance.bidIdToStaker(danProcessedBidIds[0]);
        assertEq(staker, dan);

        startHoax(dan);
        stakingManagerInstance.batchRegisterValidators(
            zeroRoot,
            danProcessedBidIds,
            depositDataArray1
        );
        vm.stopPrank();

        // Check that 32 ETH has been deposited into the Beacon Chain
        assertEq(address(stakingManagerInstance).balance, 288 ether);

        // Check node state and NFT Owners
        assertTrue(
            IEtherFiNode(danNode).phase() == IEtherFiNode.VALIDATOR_PHASE.LIVE
        );
        assertEq(TNFTInstance.ownerOf(danProcessedBidIds[0]), dan);
        assertEq(BNFTInstance.ownerOf(danProcessedBidIds[0]), dan);

        assertEq(managerInstance.numberOfValidators(), 1);

        /// Elvis batch registers validators
        // Generate Elvis's deposit data
        IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](
                newElvisProcessedBidIds.length
            );

        for (uint256 i = 0; i < newElvisProcessedBidIds.length; i++) {
            address node = managerInstance.etherfiNodeAddress(
                newElvisProcessedBidIds[i]
            );

            root = depGen.generateDepositRoot(
                hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                managerInstance.generateWithdrawalCredentials(node),
                32 ether
            );
            depositDataArray[i] = IStakingManager.DepositData({
                publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });
        }

        for (uint256 i = 0; i < newElvisProcessedBidIds.length; i++) {
            staker = stakingManagerInstance.bidIdToStaker(
                newElvisProcessedBidIds[i]
            );
            assertEq(staker, elvis);
        }

        startHoax(elvis);
        stakingManagerInstance.batchRegisterValidators(
            zeroRoot,
            newElvisProcessedBidIds,
            depositDataArray
        );
        vm.stopPrank();

        assertEq(address(stakingManagerInstance).balance, 32 ether);

        // Check nodes state and NFT Owners
        for (uint256 i = 0; i < newElvisProcessedBidIds.length; i++) {
            address elvisNode = managerInstance.etherfiNodeAddress(
                newElvisProcessedBidIds[i]
            );
            assertTrue(
                IEtherFiNode(elvisNode).phase() ==
                    IEtherFiNode.VALIDATOR_PHASE.LIVE
            );
            assertEq(TNFTInstance.ownerOf(newElvisProcessedBidIds[i]), elvis);
            assertEq(BNFTInstance.ownerOf(newElvisProcessedBidIds[i]), elvis);
        }

        assertEq(managerInstance.numberOfValidators(), 9);

        // Auction Revenue gets transferred
        // 0.005 ether * 8 bids = 0.04 ether
        assertEq(address(auctionInstance).balance, 0.645 ether - 0.04 ether);

        for (uint256 i = 0; i < newElvisProcessedBidIds.length; i++) {
            address elvisNode = managerInstance.etherfiNodeAddress(
                newElvisProcessedBidIds[i]
            );
            assertEq(elvisNode.balance, 0.0025 ether);
        }

        // Greg registers his validator
        address gregNode = managerInstance.etherfiNodeAddress(
            gregProcessedBidIds[0]
        );

        root = depGen.generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            managerInstance.generateWithdrawalCredentials(gregNode),
            32 ether
        );
        depositData = IStakingManager.DepositData({
            publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            depositDataRoot: root,
            ipfsHashForEncryptedValidatorKey: "test_ipfs"
        });

        depositDataArray1[0] = depositData;

        startHoax(greg);
        stakingManagerInstance.batchRegisterValidators(
            zeroRoot,
            gregProcessedBidIds,
            depositDataArray1
        );
        vm.stopPrank();

        // Auction Revenue gets transferred
        // Because he used bobs bid of 0.002 ether
        assertEq(gregNode.balance, 0.001 ether);
        assertEq(address(auctionInstance).balance, 0.605 ether - 0.002 ether);

        // Check nodes state and NFT Owners
        assertTrue(
            IEtherFiNode(gregNode).phase() == IEtherFiNode.VALIDATOR_PHASE.LIVE
        );
        assertEq(TNFTInstance.ownerOf(gregProcessedBidIds[0]), greg);
        assertEq(BNFTInstance.ownerOf(gregProcessedBidIds[0]), greg);

        //---- Staking Rewards come in ----

        // Owner acting as deposit contract
        skip(2 weeks);
        hoax(owner);
        (bool sent, ) = address(protocolRevenueManagerInstance).call{
            value: 1 ether
        }("");
        require(sent, "Failed to send Ether");

        // Bob is N.O.
        // Greg is TNFT and BNFT owner
        uint256 bobBalanceBeforeSkim = bob.balance;
        uint256 gregBalanceBeforeSkim = greg.balance;
        uint256 treasuryBalanceBeforeSkim = address(treasuryInstance).balance;

        (
            uint256 toOperator,
            uint256 toTnft,
            uint256 toBnft,
            uint256 toTreasury
        ) = managerInstance.getRewardsPayouts(
                gregProcessedBidIds[0],
                32 ether,
                true,
                true,
                true
            );

        // Greg skims rewards
        vm.prank(greg);
        managerInstance.partialWithdraw(
            gregProcessedBidIds[0],
            true,
            true,
            true
        );

        // Correct rewards go to NFT holders, Node Operator and Treasury
        assertEq(greg.balance, gregBalanceBeforeSkim + toTnft + toBnft);
        assertEq(bob.balance, bobBalanceBeforeSkim + toOperator);
        assertEq(
            address(treasuryInstance).balance,
            treasuryBalanceBeforeSkim + toTreasury
        );    
    }
    */
}
