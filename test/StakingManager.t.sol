// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";

contract StakingManagerTest is TestSetup {
    event StakeDeposit(
        address indexed staker,
        uint256 bidId,
        address withdrawSafe
    );
    event DepositCancelled(uint256 id);
    event ValidatorRegistered(
        address indexed operator,
        address indexed bNftOwner,
        address indexed tNftOwner,
        uint256 validatorId,
        bytes validatorPubKey,
        string ipfsHashForEncryptedValidatorKey
    );

    uint256[] public processedBids;
    uint256[] public validatorArray;
    uint256[] public bidIds;
    bytes[] public sig;
    address public etherFiNode;

    function setUp() public {
        setUpTests();

        vm.prank(alice);
        liquidityPoolInstance.setStakingTargetWeights(50, 50);
    }

     function test_DisableInitializer() public {
        vm.expectRevert("Initializable: contract is already initialized");
        vm.prank(owner);
        stakingManagerImplementation.initialize(address(auctionInstance));
    }

    function test_fake() public {
        console.logBytes32(_getDepositRoot());
    }

    function test_StakingManagerContractInstantiatedCorrectly() public {
        assertEq(stakingManagerInstance.stakeAmount(), 32 ether);
        assertEq(stakingManagerInstance.owner(), owner);
    }

    function test_GenerateWithdrawalCredentialsCorrectly() public {
        address exampleWithdrawalAddress = 0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931;
        bytes memory withdrawalCredential = managerInstance
            .generateWithdrawalCredentials(exampleWithdrawalAddress);
        // Generated with './deposit new-mnemonic --eth1_withdrawal_address 0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931'
        bytes
            memory trueOne = hex"010000000000000000000000cd5ebc2dd4cb3dc52ac66ceecc72c838b40a5931";
        assertEq(withdrawalCredential.length, trueOne.length);
        assertEq(keccak256(withdrawalCredential), keccak256(trueOne));
    }

    function test_ApproveRegistration() public {

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.numValidatorsToSpinUp = 4;
        _executeAdminTasks(report);

        bytes32[] memory aliceProof = merkle.getProof(whiteListedAddresses, 3);

        vm.startPrank(alice);
        liquidityPoolInstance.registerAsBnftHolder(alice);
        liquidityPoolInstance.registerAsBnftHolder(greg);

        vm.deal(alice, 100000 ether);
        vm.deal(greg, 100000 ether);

        //Set the max number of validators per holder to 4
        liquidityPoolInstance.setNumValidatorsToSpinUpPerSchedulePerBnftHolder(4);

        //Alice deposits funds into the LP to allow for validators to be spun and the calculations can work in dutyForWeek
        liquidityPoolInstance.deposit{value: 120 ether}();
        vm.stopPrank();

        //Move forward in time to make sure dutyForWeek runs with an arbitrary timestamp
        vm.warp(12431561615);

        liquidityPoolInstance.dutyForWeek();

        startHoax(alice);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 1000);
        bidIds = auctionInstance.createBid{value: 1 ether}(
            10,
            0.1 ether
        );
        vm.stopPrank();
        
        startHoax(alice);
        processedBids = liquidityPoolInstance.batchDepositAsBnftHolder{value: 8 ether}(bidIds, 4);

        IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](1);

        bytes32[] memory depositDataRootsForApproval = new bytes32[](1);

        address etherFiNode = managerInstance.etherfiNodeAddress(1);
        bytes32 root = depGen.generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            managerInstance.generateWithdrawalCredentials(etherFiNode),
            1 ether
        );
        IStakingManager.DepositData memory depositData = IStakingManager
            .DepositData({
                publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });

        bytes32 rootForApproval = depGen.generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            managerInstance.generateWithdrawalCredentials(etherFiNode),
            31 ether
        );

        depositDataRootsForApproval[0] = rootForApproval;

        depositDataArray[0] = depositData;

        validatorArray = new uint256[](1);
        validatorArray[0] = processedBids[0];

        sig = new bytes[](1);
        sig[0] = hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df";

        liquidityPoolInstance.batchRegisterAsBnftHolder(_getDepositRoot(), validatorArray, depositDataArray, depositDataRootsForApproval, sig);
        vm.stopPrank();

        bytes[] memory pubKey = new bytes[](1);
        pubKey[0] = hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c";

        vm.prank(alice);
        liquidityPoolInstance.batchApproveRegistration(validatorArray, pubKey, sig);

        uint256 selectedBidId = bidIds[0];
        etherFiNode = managerInstance.etherfiNodeAddress(selectedBidId);

        assertEq(selectedBidId, 1);
        assertEq(address(managerInstance).balance, 0 ether);

        //Revenue not about auction threshold so still 1 ether
        assertEq(address(auctionInstance).balance, 1 ether);

        address safeAddress = managerInstance.etherfiNodeAddress(bidIds[0]);
        assertEq(safeAddress, etherFiNode);
    }

    function test_DepositOneWorksCorrectly() public {
        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 5);

        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        uint256[] memory bidId = auctionInstance.createBid{value: 0.1 ether}(
            1,
            0.1 ether
        );

        uint256[] memory bidIdArray = new uint256[](1);
        bidIdArray[0] = bidId[0];
        vm.stopPrank();

        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray,
            false
        );

        IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](1);

        address etherFiNode = managerInstance.etherfiNodeAddress(1);
        bytes32 root = depGen.generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            managerInstance.generateWithdrawalCredentials(etherFiNode),
            32 ether
        );
       
        IStakingManager.DepositData memory depositData = IStakingManager
            .DepositData({
                publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });

        depositDataArray[0] = depositData;

        stakingManagerInstance.batchRegisterValidators(_getDepositRoot(), bidId, depositDataArray);

        uint256 validatorId = bidId[0];
        uint256 winningBid = bidId[0];
        address staker = stakingManagerInstance.bidIdToStaker(validatorId);
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorId);

        assertEq(staker, 0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        assertEq(stakingManagerInstance.stakeAmount(), 32 ether);
        assertEq(winningBid, bidId[0]);
        assertEq(validatorId, bidId[0]);

        vm.stopPrank();

        assertEq(
            IEtherFiNode(etherfiNode).ipfsHashForEncryptedValidatorKey(),
            depositData.ipfsHashForEncryptedValidatorKey
        );
        assertEq(
            managerInstance.ipfsHashForEncryptedValidatorKey(validatorId),
            depositData.ipfsHashForEncryptedValidatorKey
        );
    }

    function test_BatchDepositWithBidIdsFailsIFInvalidDepositAmount() public {
        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 100);

        auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
        auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
        auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
        auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);

        uint256[] memory bidIdArray = new uint256[](1);
        bidIdArray[0] = 1;

        vm.expectRevert("Insufficient staking amount");
        stakingManagerInstance.batchDepositWithBidIds{value: 0.033 ether}(
            bidIdArray,
            false
        );
    }

    function test_BatchDepositWithBidIdsFailsIfNotEnoughActiveBids() public {
        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 100);

        uint256[] memory bidIdArray = new uint256[](10);
        bidIdArray[0] = 1;
        bidIdArray[1] = 2;
        bidIdArray[2] = 6;
        bidIdArray[3] = 7;
        bidIdArray[4] = 8;
        bidIdArray[5] = 9;
        bidIdArray[6] = 11;
        bidIdArray[7] = 12;
        bidIdArray[8] = 19;
        bidIdArray[9] = 20;

        vm.expectRevert("No bids available at the moment");
        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray,
            false
        );
    }

    function test_BatchDepositWithBidIdsFailsIfNoIdsProvided() public {
        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 100);
        for (uint256 x = 0; x < 10; x++) {
            auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
        }
        for (uint256 x = 0; x < 10; x++) {
            auctionInstance.createBid{value: 0.2 ether}(1, 0.2 ether);
        }

        assertEq(auctionInstance.numberOfActiveBids(), 20);

        uint256[] memory bidIdArray = new uint256[](0);

        vm.expectRevert("No bid Ids provided");
        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray,
            false
        );
    }

    function test_BatchDepositWithBidIdsFailsIfPaused() public {
        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 100);

        for (uint256 x = 0; x < 10; x++) {
            auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
        }
        for (uint256 x = 0; x < 10; x++) {
            auctionInstance.createBid{value: 0.2 ether}(1, 0.2 ether);
        }

        assertEq(auctionInstance.numberOfActiveBids(), 20);

        uint256[] memory bidIdArray = new uint256[](10);
        bidIdArray[0] = 1;
        bidIdArray[1] = 2;
        bidIdArray[2] = 6;
        bidIdArray[3] = 7;
        bidIdArray[4] = 8;
        bidIdArray[5] = 9;
        bidIdArray[6] = 11;
        bidIdArray[7] = 12;
        bidIdArray[8] = 19;
        bidIdArray[9] = 20;

        vm.stopPrank();

        vm.prank(alice);
        stakingManagerInstance.pauseContract();

        hoax(alice);
        vm.expectRevert("Pausable: paused");
        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray,
            false
        );
    }

    function test_BatchDepositWithIdsSimpleWorksCorrectly() public {
        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 100);

        for (uint256 x = 0; x < 10; x++) {
            auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
        }
        for (uint256 x = 0; x < 10; x++) {
            auctionInstance.createBid{value: 0.2 ether}(1, 0.2 ether);
        }

        assertEq(auctionInstance.numberOfActiveBids(), 20);

        uint256[] memory bidIdArray = new uint256[](10);
        bidIdArray[0] = 1;
        bidIdArray[1] = 2;
        bidIdArray[2] = 6;
        bidIdArray[3] = 7;
        bidIdArray[4] = 8;
        bidIdArray[5] = 9;
        bidIdArray[6] = 11;
        bidIdArray[7] = 12;
        bidIdArray[8] = 19;
        bidIdArray[9] = 20;
        vm.stopPrank();

        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray,
            false
        );
        assertEq(auctionInstance.numberOfActiveBids(), 19);

        (uint256 amount, , , bool isActive) = auctionInstance.bids(1);
        assertEq(amount, 0.1 ether);
        assertEq(isActive, false);

        (amount, , , isActive) = auctionInstance.bids(7);
        assertEq(amount, 0.1 ether);
        assertEq(isActive, true);

        (amount, , , isActive) = auctionInstance.bids(20);
        assertEq(amount, 0.2 ether);
        assertEq(isActive, true);

        (amount, , , isActive) = auctionInstance.bids(3);
        assertEq(amount, 0.1 ether);
        assertEq(isActive, true);

        assertEq(address(stakingManagerInstance).balance, 32 ether);
    }

    function test_BatchDepositWithIdsComplexWorksCorrectly() public {
        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 100);

        for (uint256 x = 0; x < 10; x++) {
            auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
        }
        for (uint256 x = 0; x < 10; x++) {
            auctionInstance.createBid{value: 0.2 ether}(1, 0.2 ether);
        }

        assertEq(auctionInstance.numberOfActiveBids(), 20);
        assertEq(address(auctionInstance).balance, 3 ether);

        uint256[] memory bidIdArray = new uint256[](10);
        bidIdArray[0] = 1;
        bidIdArray[1] = 2;
        bidIdArray[2] = 6;
        bidIdArray[3] = 7;
        bidIdArray[4] = 8;
        bidIdArray[5] = 9;
        bidIdArray[6] = 11;
        bidIdArray[7] = 12;
        bidIdArray[8] = 19;
        bidIdArray[9] = 20;

        uint256 userBalanceBefore = 0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931
            .balance;

        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray,
            false
        );
        assertEq(auctionInstance.numberOfActiveBids(), 19);

        (uint256 amount, , , bool isActive) = auctionInstance.bids(1);
        assertEq(amount, 0.1 ether);
        assertEq(isActive, false);

        (amount, , , isActive) = auctionInstance.bids(7);
        assertEq(amount, 0.1 ether);
        assertEq(isActive, true);

        (amount, , , isActive) = auctionInstance.bids(20);
        assertEq(amount, 0.2 ether);
        assertEq(isActive, true);

        (amount, , , isActive) = auctionInstance.bids(3);
        assertEq(amount, 0.1 ether);
        assertEq(isActive, true);

        uint256[] memory bidIdArray2 = new uint256[](10);
        bidIdArray2[0] = 1;
        bidIdArray2[1] = 3;
        bidIdArray2[2] = 6;
        bidIdArray2[3] = 7;
        bidIdArray2[4] = 8;
        bidIdArray2[5] = 13;
        bidIdArray2[6] = 11;
        bidIdArray2[7] = 12;
        bidIdArray2[8] = 19;
        bidIdArray2[9] = 20;

        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray2,
            false
        );

        assertEq(
            0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931.balance,
            userBalanceBefore - 64 ether
        );
        assertEq(auctionInstance.numberOfActiveBids(), 18);

        (amount, , , isActive) = auctionInstance.bids(1);
        assertEq(amount, 0.1 ether);
        assertEq(isActive, false);

        (amount, , , isActive) = auctionInstance.bids(13);
        assertEq(amount, 0.2 ether);
        assertEq(isActive, true);

        (amount, , , isActive) = auctionInstance.bids(3);
        assertEq(amount, 0.1 ether);
        assertEq(isActive, false);
    }

    function test_RegisterValidatorFailsIfIncorrectCaller() public {
        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 5);

        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        uint256[] memory bidId = auctionInstance.createBid{value: 0.1 ether}(
            1,
            0.1 ether
        );
        uint256[] memory bidIdArray = new uint256[](1);
        bidIdArray[0] = bidId[0];

        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray,
            false
        );

        vm.stopPrank();

        IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](1);

        vm.prank(owner);
        vm.expectRevert("Not deposit owner");
        stakingManagerInstance.batchRegisterValidators(zeroRoot, bidId, depositDataArray);
    }

    function test_RegisterValidatorFailsIfIncorrectPhase() public {
        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        vm.deal(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931, 1000000000000 ether);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 5);

        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        uint256[] memory bidId = auctionInstance.createBid{value: 0.1 ether}(
            1,
            0.1 ether
        );
        uint256[] memory bidIdArray = new uint256[](1);
        bidIdArray[0] = bidId[0];

        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray,
            false
        );

        address etherFiNode = managerInstance.etherfiNodeAddress(1);
        bytes32 root = depGen.generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            managerInstance.generateWithdrawalCredentials(etherFiNode),
            32 ether
        );

        IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](1);

        IStakingManager.DepositData memory depositData = IStakingManager
            .DepositData({
                publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });

        depositDataArray[0] = depositData;

        stakingManagerInstance.batchRegisterValidators(zeroRoot, bidIdArray, depositDataArray);

        vm.expectRevert("Invalid phase transition");
        stakingManagerInstance.batchRegisterValidators(zeroRoot, bidIdArray, depositDataArray);

        vm.stopPrank();

    }

    function test_RegisterValidatorFailsIfContractPaused() public {
        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 5);

        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
        uint256[] memory bidIdArray = new uint256[](1);
        bidIdArray[0] = 1;

        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray,
            false
        );
        vm.stopPrank();

        IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](1);

        vm.prank(alice);
        stakingManagerInstance.pauseContract();

        hoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        vm.expectRevert("Pausable: paused");
        stakingManagerInstance.batchRegisterValidators(zeroRoot, bidIdArray, depositDataArray);
    }

    function test_RegisterValidatorWorksCorrectly() public {
        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 5);

        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        uint256[] memory bidId = auctionInstance.createBid{value: 0.1 ether}(
            1,
            0.1 ether
        );
        uint256[] memory bidIdArray = new uint256[](1);
        bidIdArray[0] = 1;

        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray,
            false
        );

        address etherFiNode = managerInstance.etherfiNodeAddress(1);
        bytes32 root = depGen.generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            managerInstance.generateWithdrawalCredentials(etherFiNode),
            32 ether
        );

        IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](1);

        IStakingManager.DepositData memory depositData = IStakingManager
            .DepositData({
                publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });

        depositDataArray[0] = depositData;

        stakingManagerInstance.batchRegisterValidators(zeroRoot, bidId, depositDataArray);

        uint256 selectedBidId = bidId[0];
        etherFiNode = managerInstance.etherfiNodeAddress(bidId[0]);

        // assertEq(address(protocolRevenueManagerInstance).balance, 0.05 ether); // protocolRevenueManager is being deprecated
        assertEq(selectedBidId, 1);
        assertEq(managerInstance.numberOfValidators(), 1);
        assertEq(address(managerInstance).balance, 0 ether, "EtherFiNode manager balance should be 0");
        assertEq(address(auctionInstance).balance, 0.1 ether, "Auction balance should be 0.1");

        address operatorAddress = auctionInstance.getBidOwner(bidId[0]);
        assertEq(operatorAddress, 0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);

        address safeAddress = managerInstance.etherfiNodeAddress(bidId[0]);
        assertEq(safeAddress, etherFiNode);

        assertEq(
            BNFTInstance.ownerOf(bidId[0]),
            0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931
        );
        assertEq(
            TNFTInstance.ownerOf(bidId[0]),
            0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931
        );
        assertEq(
            BNFTInstance.balanceOf(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931),
            1
        );
        assertEq(
            TNFTInstance.balanceOf(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931),
            1
        );
    }

    function test_BatchRegisterValidatorWorksCorrectly() public {
        bytes32[] memory proof = merkle.getProof(whiteListedAddresses, 0);

        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 100);

        for (uint256 x = 0; x < 10; x++) {
            auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
        }
        for (uint256 x = 0; x < 10; x++) {
            auctionInstance.createBid{value: 0.2 ether}(1, 0.2 ether);
        }

        uint256[] memory bidIdArray = new uint256[](10);
        bidIdArray[0] = 1;
        bidIdArray[1] = 2;
        bidIdArray[2] = 6;
        bidIdArray[3] = 7;
        bidIdArray[4] = 8;
        bidIdArray[5] = 9;
        bidIdArray[6] = 11;
        bidIdArray[7] = 12;
        bidIdArray[8] = 19;
        bidIdArray[9] = 20;

        // only the first 4 bids will be processed because of the 128 ether limit
        uint256[] memory processedBidIds = stakingManagerInstance
            .batchDepositWithBidIds{value: 128 ether}(bidIdArray, false);

        IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](4);

        for (uint256 i = 0; i < processedBidIds.length; i++) {
            address etherFiNode = managerInstance.etherfiNodeAddress(
                processedBidIds[i]
            );
            bytes32 root = depGen.generateDepositRoot(
                hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                managerInstance.generateWithdrawalCredentials(etherFiNode),
                32 ether
            );
            depositDataArray[i] = IStakingManager.DepositData({
                publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });
        }

        assertEq(address(auctionInstance).balance, 3 ether, "Auction balance should be 3");

        stakingManagerInstance.batchRegisterValidators(_getDepositRoot(), 
            processedBidIds,
            depositDataArray
        );

        assertEq(auctionInstance.accumulatedRevenue(), 0.4 ether, "Auction accumulated revenue should be 0.4");
        assertEq(address(auctionInstance).balance, 3 ether, "Auction balance should be 4");
        assertEq(address(membershipManagerInstance).balance, 0 ether, "MembershipManager balance should be 1");

        assertEq(
            BNFTInstance.ownerOf(processedBidIds[0]),
            0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931
        );
        assertEq(
            BNFTInstance.ownerOf(processedBidIds[1]),
            0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931
        );
        assertEq(
            BNFTInstance.ownerOf(processedBidIds[2]),
            0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931
        );
        assertEq(
            BNFTInstance.ownerOf(processedBidIds[3]),
            0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931
        );
        assertEq(
            TNFTInstance.ownerOf(processedBidIds[0]),
            0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931
        );
        assertEq(
            TNFTInstance.ownerOf(processedBidIds[1]),
            0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931
        );
        assertEq(
            TNFTInstance.ownerOf(processedBidIds[2]),
            0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931
        );
        assertEq(
            TNFTInstance.ownerOf(processedBidIds[3]),
            0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931
        );

        assertEq(managerInstance.numberOfValidators(), 4);
    }

    function test_BatchRegisterValidatorFailsIfArrayLengthAreNotEqual() public {
        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 100);

        for (uint256 x = 0; x < 10; x++) {
            auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
        }
        for (uint256 x = 0; x < 10; x++) {
            auctionInstance.createBid{value: 0.2 ether}(1, 0.2 ether);
        }

        uint256[] memory bidIdArray = new uint256[](10);
        bidIdArray[0] = 1;
        bidIdArray[1] = 2;
        bidIdArray[2] = 6;
        bidIdArray[3] = 7;
        bidIdArray[4] = 8;
        bidIdArray[5] = 9;
        bidIdArray[6] = 11;
        bidIdArray[7] = 12;
        bidIdArray[8] = 19;
        bidIdArray[9] = 20;

        IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](9);
        depositDataArray[0] = test_data;
        depositDataArray[1] = test_data_2;
        depositDataArray[2] = test_data;
        depositDataArray[3] = test_data_2;
        depositDataArray[4] = test_data;
        depositDataArray[5] = test_data_2;
        depositDataArray[6] = test_data;
        depositDataArray[7] = test_data_2;
        depositDataArray[8] = test_data;

        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray,
            false
        );

        assertEq(address(auctionInstance).balance, 3 ether);
        
        bytes32 root = _getDepositRoot();
        vm.expectRevert("Array lengths must match");
        stakingManagerInstance.batchRegisterValidators(root, 
            bidIdArray,
            depositDataArray
        );
    }

    function test_BatchRegisterValidatorFailsIfIncorrectPhase() public {
        bytes32[] memory proof = merkle.getProof(whiteListedAddresses, 0);

        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 100);

        for (uint256 x = 0; x < 10; x++) {
            auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
        }
        for (uint256 x = 0; x < 10; x++) {
            auctionInstance.createBid{value: 0.2 ether}(1, 0.2 ether);
        }

        uint256[] memory bidIdArray = new uint256[](4);
        bidIdArray[0] = 1;
        bidIdArray[1] = 2;
        bidIdArray[2] = 6;
        bidIdArray[3] = 7;

        uint256[] memory processedBidIds = stakingManagerInstance
            .batchDepositWithBidIds{value: 128 ether}(bidIdArray, false);

        IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](4);

        bytes32 root;
        for (uint256 i = 0; i < processedBidIds.length; i++) {
            address etherFiNode = managerInstance.etherfiNodeAddress(
                processedBidIds[i]
            );
            bytes32 generatedRoot = depGen.generateDepositRoot(
                hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                managerInstance.generateWithdrawalCredentials(etherFiNode),
                32 ether
            );        
            depositDataArray[i] = IStakingManager.DepositData({
                    publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                    signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                    depositDataRoot: generatedRoot,
                    ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });
        }

        stakingManagerInstance.batchRegisterValidators(_getDepositRoot(), 
            processedBidIds,
            depositDataArray
        );

        root = _getDepositRoot();
        vm.expectRevert("Invalid phase transition");
        stakingManagerInstance.batchRegisterValidators(root, 
            bidIdArray,
            depositDataArray
        );
    }

    function test_BatchRegisterValidatorFailsIfMoreThan16Registers() public {
        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 100);

        for (uint256 x = 0; x < 10; x++) {
            auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
        }
        for (uint256 x = 0; x < 10; x++) {
            auctionInstance.createBid{value: 0.2 ether}(1, 0.2 ether);
        }

        uint256[] memory bidIdArray = new uint256[](27);
        bidIdArray[0] = 1;
        bidIdArray[1] = 2;
        bidIdArray[2] = 3;
        bidIdArray[3] = 4;
        bidIdArray[4] = 5;
        bidIdArray[5] = 6;
        bidIdArray[6] = 7;
        bidIdArray[7] = 8;
        bidIdArray[8] = 9;
        bidIdArray[9] = 10;
        bidIdArray[10] = 11;
        bidIdArray[11] = 12;
        bidIdArray[12] = 13;
        bidIdArray[13] = 14;
        bidIdArray[14] = 15;
        bidIdArray[15] = 16;
        bidIdArray[16] = 17;
        bidIdArray[17] = 18;
        bidIdArray[18] = 19;
        bidIdArray[19] = 20;
        bidIdArray[20] = 21;
        bidIdArray[21] = 22;
        bidIdArray[22] = 23;
        bidIdArray[23] = 24;
        bidIdArray[24] = 25;
        bidIdArray[25] = 26;
        bidIdArray[26] = 27;

        IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](27);


        bytes32 root;
        for (uint256 i = 0; i < bidIdArray.length; i++) {
            address etherFiNode = managerInstance.etherfiNodeAddress(
                bidIdArray[i]
            );
            bytes32 generatedRoot = depGen.generateDepositRoot(
                hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                managerInstance.generateWithdrawalCredentials(etherFiNode),
                1 ether
            );
            depositDataArray[i] = IStakingManager.DepositData({
                    publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                    signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                    depositDataRoot: generatedRoot,
                    ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });
        }

        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray,
            false
        );

        assertEq(address(auctionInstance).balance, 3 ether);

        root = _getDepositRoot();
        vm.expectRevert("Too many validators");
        stakingManagerInstance.batchRegisterValidators(root, 
            bidIdArray,
            depositDataArray
        );
    }

    function test_cancelDepositFailsIfNotStakeOwner() public {
        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 5);

        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        uint256[] memory bidId = auctionInstance.createBid{value: 0.1 ether}(
            1,
            0.1 ether
        );

        uint256[] memory bidIdArray = new uint256[](1);
        bidIdArray[0] = bidId[0];

        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray,
            false
        );
        vm.stopPrank();

        vm.prank(owner);
        vm.expectRevert("Not deposit owner");
        stakingManagerInstance.batchCancelDeposit(bidId);

        vm.expectRevert("Not deposit owner");
        stakingManagerInstance.batchCancelDeposit(bidId);
    }

    function test_cancelDepositFailsIfDepositDoesNotExist() public {
        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 5);

        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        uint256[] memory bidId = auctionInstance.createBid{value: 0.1 ether}(
            1,
            0.1 ether
        );

        uint256[] memory bidIdArray = new uint256[](1);
        bidIdArray[0] = bidId[0];

        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray,
            false
        );
        stakingManagerInstance.batchCancelDeposit(bidId);

        vm.expectRevert("Not deposit owner");
        stakingManagerInstance.batchCancelDeposit(bidId);
    }

    function test_cancelDepositFailsIfIncorrectPhase() public {
        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 5);

        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        vm.deal(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931, 10000 ether);

        uint256[] memory bidId = auctionInstance.createBid{value: 0.1 ether}(
            1,
            0.1 ether
        );

        uint256[] memory bidIdArray = new uint256[](1);
        bidIdArray[0] = bidId[0];

        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray,
            false
        );

        address etherFiNode = managerInstance.etherfiNodeAddress(1);
        bytes32 root = depGen.generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            managerInstance.generateWithdrawalCredentials(etherFiNode),
            32 ether
        );

        IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](1);

        IStakingManager.DepositData memory depositData = IStakingManager
            .DepositData({
                publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });

        depositDataArray[0] = depositData;

        stakingManagerInstance.batchRegisterValidators(zeroRoot, bidId, depositDataArray);

        vm.expectRevert("Invalid phase transition");
        stakingManagerInstance.batchCancelDeposit(bidId);
    }

    function cancelDepositFailsIfContractPaused() public {
        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 5);

        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        uint256[] memory bidId = auctionInstance.createBid{value: 0.1 ether}(
            1,
            0.1 ether
        );

        uint256[] memory bidIdArray = new uint256[](1);
        bidIdArray[0] = bidId[0];

        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray,
            false
        );

        vm.prank(owner);
        stakingManagerInstance.pauseContract();

        hoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        vm.expectRevert("Pausable: paused");
        stakingManagerInstance.batchCancelDeposit(bidIdArray);
    }

    function test_cancelDepositWorksCorrectly() public {
        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 5);

        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
        uint256[] memory bidId2 = auctionInstance.createBid{value: 0.3 ether}(
            1,
            0.3 ether
        );
        auctionInstance.createBid{value: 0.2 ether}(1, 0.2 ether);

        assertEq(address(auctionInstance).balance, 0.6 ether);

        uint256[] memory bidIdArray = new uint256[](1);
        bidIdArray[0] = bidId2[0];

        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray,
            false
        );
        uint256 depositorBalance = 0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931
            .balance;

        uint256 selectedBidId = bidId2[0];
        address staker = stakingManagerInstance.bidIdToStaker(bidId2[0]);
        address etherFiNode = managerInstance.etherfiNodeAddress(bidId2[0]);

        assertEq(staker, 0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        assertEq(selectedBidId, bidId2[0]);
        assertTrue(
            IEtherFiNode(etherFiNode).phase() ==
                IEtherFiNode.VALIDATOR_PHASE.STAKE_DEPOSITED
        );

        (uint256 bidAmount, , address bidder, bool isActive) = auctionInstance
            .bids(selectedBidId);

        assertEq(bidAmount, 0.3 ether);
        assertEq(bidder, 0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        assertEq(isActive, false);
        assertEq(auctionInstance.numberOfActiveBids(), 2);
        assertEq(address(auctionInstance).balance, 0.6 ether);

        stakingManagerInstance.batchCancelDeposit(bidId2);
        assertEq(managerInstance.etherfiNodeAddress(bidId2[0]), address(0));
        assertEq(stakingManagerInstance.bidIdToStaker(bidId2[0]), address(0));
        assertTrue(
            IEtherFiNode(etherFiNode).phase() ==
                IEtherFiNode.VALIDATOR_PHASE.READY_FOR_DEPOSIT // node has been recycled in pool
        );

        (bidAmount, , bidder, isActive) = auctionInstance.bids(bidId2[0]);
        assertEq(bidAmount, 0.3 ether);
        assertEq(bidder, 0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        assertEq(isActive, true);
        assertEq(auctionInstance.numberOfActiveBids(), 3);
        assertEq(address(auctionInstance).balance, 0.6 ether);

        assertEq(
            0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931.balance,
            depositorBalance + 32 ether
        );
    }

    function test_CorrectValidatorAttachedToNft() public {
        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 5);

        vm.prank(0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 5);

        startHoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        uint256[] memory bidId1 = auctionInstance.createBid{value: 0.1 ether}(
            1,
            0.1 ether
        );
        uint256[] memory bidIdArray = new uint256[](1);
        bidIdArray[0] = bidId1[0];

        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray,
            false
        );

        address etherFiNode = managerInstance.etherfiNodeAddress(1);
        bytes32 root = depGen.generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            managerInstance.generateWithdrawalCredentials(etherFiNode),
            32 ether
        );

        IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](1);

        IStakingManager.DepositData memory depositData = IStakingManager
            .DepositData({
                publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });

        depositDataArray[0] = depositData;

        stakingManagerInstance.batchRegisterValidators(zeroRoot, bidId1, depositDataArray);

        vm.stopPrank();
        startHoax(0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf);
        uint256[] memory bidId2 = auctionInstance.createBid{value: 0.1 ether}(
            1,
            0.1 ether
        );
        uint256[] memory bidIdArray2 = new uint256[](1);
        bidIdArray2[0] = bidId2[0];

        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray2,
            false
        );

        etherFiNode = managerInstance.etherfiNodeAddress(2);
        root = depGen.generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            managerInstance.generateWithdrawalCredentials(etherFiNode),
            32 ether
        );

        IStakingManager.DepositData[]
            memory depositDataArray2 = new IStakingManager.DepositData[](1);

        depositData = IStakingManager.DepositData({
                publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });

        depositDataArray2[0] = depositData;

        stakingManagerInstance.batchRegisterValidators(zeroRoot, bidId2, depositDataArray2);

        assertEq(
            BNFTInstance.ownerOf(bidId1[0]),
            0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931
        );
        assertEq(
            TNFTInstance.ownerOf(bidId1[0]),
            0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931
        );
        assertEq(
            BNFTInstance.ownerOf(bidId2[0]),
            0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf
        );
        assertEq(
            TNFTInstance.ownerOf(bidId2[0]),
            0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf
        );
        assertEq(
            BNFTInstance.balanceOf(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931),
            1
        );
        assertEq(
            TNFTInstance.balanceOf(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931),
            1
        );
        assertEq(
            BNFTInstance.balanceOf(0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf),
            1
        );
        assertEq(
            TNFTInstance.balanceOf(0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf),
            1
        );
    }

    function test_SetMaxDeposit() public {
        assertEq(stakingManagerInstance.maxBatchDepositSize(), 25);
        vm.prank(alice);
        stakingManagerInstance.setMaxBatchDepositSize(12);
        assertEq(stakingManagerInstance.maxBatchDepositSize(), 12);

        vm.prank(owner);
        vm.expectRevert("Caller is not the admin");
        stakingManagerInstance.setMaxBatchDepositSize(12);
    }

    function test_EventDepositCancelled() public {
        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 5);

        hoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        uint256[] memory bidId1 = auctionInstance.createBid{value: 0.1 ether}(
            1,
            0.1 ether
        );

        hoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(bidId1, false);

        vm.expectEmit(true, false, false, true);
        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        emit DepositCancelled(bidId1[0]);
        stakingManagerInstance.batchCancelDeposit(bidId1);
    }

    function test_EventValidatorRegistered() public {
        bytes32[] memory proof = merkle.getProof(whiteListedAddresses, 0);

        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            5
        );

        hoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        uint256[] memory bidId1 = auctionInstance.createBid{value: 0.1 ether}(
            1,
            0.1 ether
        );

        startHoax(alice);
        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(bidId1, false);

        address etherFiNode = managerInstance.etherfiNodeAddress(1);
        bytes32 root = depGen.generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            managerInstance.generateWithdrawalCredentials(etherFiNode),
            32 ether
        );

        IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](1);

        IStakingManager.DepositData memory depositData = IStakingManager
            .DepositData({
                publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });

        depositDataArray[0] = depositData;

        vm.expectEmit(true, true, true, true);
        emit ValidatorRegistered(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931, alice, alice, bidId1[0], hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c", "test_ipfs");
        stakingManagerInstance.batchRegisterValidators(_getDepositRoot(), bidId1, depositDataArray);
        assertEq(BNFTInstance.ownerOf(bidId1[0]), alice);
        assertEq(TNFTInstance.ownerOf(bidId1[0]), alice);
    }

    function test_MaxBatchBidGasFee() public {
        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            5
        );

        hoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        uint256[] memory bidIds = auctionInstance.createBid{value: 0.4 ether}(
            4,
            0.1 ether
        );

        startHoax(alice);
        stakingManagerInstance.batchDepositWithBidIds{value: 128 ether}(bidIds, false);
    }

    function test_CanOnlySetAddressesOnce() public {
        vm.startPrank(owner);
        vm.expectRevert("Address already set");
        stakingManagerInstance.registerEtherFiNodeImplementationContract(
            address(0)
        );

        vm.expectRevert("Address already set");
        stakingManagerInstance.registerTNFTContract(address(0));

        vm.expectRevert("Address already set");
        stakingManagerInstance.registerBNFTContract(address(0));

        vm.expectRevert("Address already set");
        stakingManagerInstance.setLiquidityPoolAddress(address(0));

        vm.expectRevert("Address already set");
        stakingManagerInstance.setEtherFiNodesManagerAddress(address(0));
    }

    // https://dashboard.tenderly.co/public/safe/safe-apps/simulator/8f9bf820-b9a5-4df5-8c50-20c7ecfa30a6?trace=0.0.4.0.1.0.0.2.2.1
    function test_reproduceBugFromSimulator() public {
        bytes memory pubkey = hex"92c465ab9d85c53ad0dd7fe21bf102c3a3927aa3cd01458bd6593c78834f9fcc86ee6944cdf560e1f3d264581a952bc6";
        bytes memory withdrawal_credentials = hex"0100000000000000000000007c676cfb7d5e25103024ba86d38c8466aba8f190";
        bytes memory signature = hex"87b490e315affa0c6535d00eed998f295dbb2287391ec825aabb05376b19eaea8b0e39e921acb6838bce6ef17a858c620092767d67fae44e676515d8b3afc944d026fb13182dafcf7254229f13fa46af07d2445b16b9b200877b4b180e77bdfe";
        bytes32 deposit_data_root = hex"2684db66168254570a885b592a6a83003e83ee52b22c4e016ac37cc97d7572bf";

        vm.deal(owner, 100 ether);
        vm.startPrank(owner);

        vm.expectRevert("DepositContract: reconstructed DepositData does not match supplied deposit_data_root");
        mockDepositContractEth2.deposit{value: 32 ether}(pubkey, withdrawal_credentials, signature, deposit_data_root);
    }
}
