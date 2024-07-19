// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";

contract StakingManagerTest is TestSetup {
    event StakeDeposit(
        address indexed staker,
        uint256 indexed bidId,
        address indexed withdrawSafe,
        bool restaked
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

    function setUp() public {
        setUpTests();

        vm.prank(alice);
        liquidityPoolInstance.setStakingTargetWeights(50, 50);
    }

     function test_DisableInitializer() public {
        vm.expectRevert("Initializable: contract is already initialized");
        vm.prank(owner);
        stakingManagerImplementation.initialize(address(auctionInstance), address(depositContractEth2));
    }

    function test_fake() public view {
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

        vm.startPrank(alice);
        liquidityPoolInstance.registerAsBnftHolder(alice);
        liquidityPoolInstance.registerAsBnftHolder(greg);

        vm.deal(alice, 100000 ether);
        vm.deal(greg, 100000 ether);

        //Alice deposits funds into the LP to allow for validators to be spun and the calculations can work in dutyForWeek
        liquidityPoolInstance.deposit{value: 120 ether}();
        vm.stopPrank();

        //Move forward in time to make sure dutyForWeek runs with an arbitrary timestamp
        vm.warp(12431561615);

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

    function test_CreateOneBid() public returns (uint256[] memory) {
        vm.deal(alice, 100 ether);

        vm.startPrank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 5);

        uint256[] memory bidId = auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
        vm.stopPrank();

        return bidId;
    }

    function test_CreateMultipleBids() public returns (uint256[] memory) {
        vm.deal(alice, 100 ether);

        vm.startPrank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 50);

        uint256[] memory bidId = new uint256[](20);

        for (uint256 x = 0; x < 10; x++) {
            uint256[] memory tmp = auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
            bidId[x] = tmp[0];
        }
        for (uint256 x = 0; x < 10; x++) {
            uint256[] memory tmp = auctionInstance.createBid{value: 0.2 ether}(1, 0.2 ether);
            bidId[x + 10] = tmp[0];
        }
        vm.stopPrank();

        assertEq(auctionInstance.numberOfActiveBids(), 20);

        return bidId;
    }

    function test_DepositOneWorksCorrectly() public returns (uint256[] memory) {
        uint256[] memory bidId = test_CreateOneBid();

        vm.prank(address(liquidityPoolInstance));
        stakingManagerInstance.batchDepositWithBidIds(bidId, 1, alice, bob, henry, ILiquidityPool.SourceOfFunds.EETH, false, 0);
    
        return bidId;
    }

    function test_RegisterOne() public {
        uint256[] memory validatorId = test_DepositOneWorksCorrectly();

        (IStakingManager.DepositData[] memory depositDataArray,,,) = _prepareForValidatorRegistration(validatorId);

        vm.expectRevert("DEPOSIT_AMOUNT_MISMATCH");
        vm.prank(address(liquidityPoolInstance));
        stakingManagerInstance.batchRegisterValidators(zeroRoot, validatorId, alice, bob, depositDataArray, henry);

        vm.deal(address(liquidityPoolInstance), 100 ether);

        vm.expectRevert("INCORRECT_CALLER");
        vm.prank(alice);
        stakingManagerInstance.batchRegisterValidators{value: 1 ether}(zeroRoot, validatorId, henry, bob, depositDataArray, alice);

        address randomAddress = vm.addr(121232);
        vm.expectRevert("INCORRECT_HASH");
        vm.prank(address(liquidityPoolInstance));
        stakingManagerInstance.batchRegisterValidators{value: 1 ether}(zeroRoot, validatorId, randomAddress, bob, depositDataArray, alice);

        vm.expectRevert("INCORRECT_HASH");
        vm.prank(address(liquidityPoolInstance));
        stakingManagerInstance.batchRegisterValidators{value: 1 ether}(zeroRoot, validatorId, henry, randomAddress, depositDataArray, alice);

        vm.expectRevert("INCORRECT_CALLER");
        vm.prank(address(liquidityPoolInstance));
        stakingManagerInstance.batchRegisterValidators{value: 1 ether}(zeroRoot, validatorId, henry, bob, depositDataArray, randomAddress);

        vm.expectEmit(true, true, true, true);
        emit ValidatorRegistered(alice, henry, bob, validatorId[0], hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c", "test_ipfs");
        vm.prank(address(liquidityPoolInstance));
        stakingManagerInstance.batchRegisterValidators{value: 1 ether}(zeroRoot, validatorId, henry, bob, depositDataArray, alice);
    
        vm.expectRevert("INVALID_PHASE_TRANSITION");
        vm.prank(address(liquidityPoolInstance));
        stakingManagerInstance.batchRegisterValidators{value: 1 ether}(zeroRoot, validatorId, henry, bob, depositDataArray, alice);
    }

    function test_BatchDepositWithBidIdsFailsIfNotEnoughActiveBids() public {
        test_CreateOneBid();

        uint256[] memory bidIdArray = new uint256[](2);
        bidIdArray[0] = 1;
        bidIdArray[1] = 2;
 
        vm.expectRevert("NOT_ENOUGH_BIDS");
        vm.prank(address(liquidityPoolInstance));
        stakingManagerInstance.batchDepositWithBidIds(bidIdArray, 2, alice, bob, henry, ILiquidityPool.SourceOfFunds.EETH, false, 0);
    }

    function test_BatchDepositWithBidIdsFailsIfNoIdsProvided() public {
        uint256[] memory bidId = test_CreateOneBid();


        uint256[] memory bidIdArray = new uint256[](0);
        vm.expectRevert("WRONG_PARAMS");
        vm.prank(address(liquidityPoolInstance));
        stakingManagerInstance.batchDepositWithBidIds(bidIdArray, 1, alice, bob, henry, ILiquidityPool.SourceOfFunds.EETH, false, 0);
    }

    function test_BatchDepositWithBidIdsFailsIfPaused() public {
        uint256[] memory bidId = test_CreateOneBid();

        vm.prank(alice);
        stakingManagerInstance.pauseContract();

        vm.expectRevert("Pausable: paused");
        vm.prank(address(liquidityPoolInstance));
        stakingManagerInstance.batchDepositWithBidIds(bidId, 1, alice, bob, henry, ILiquidityPool.SourceOfFunds.EETH, false, 0);
    }

    function test_BatchDepositWithIdsSimpleWorksCorrectly() public {
        test_CreateMultipleBids();

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

        vm.prank(address(liquidityPoolInstance));
        stakingManagerInstance.batchDepositWithBidIds(bidIdArray, 1, alice, bob, henry, ILiquidityPool.SourceOfFunds.EETH, false, 0);

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
    }

    function test_RegisterValidatorFailsIfContractPaused() public {
        uint256[] memory validatorId = test_DepositOneWorksCorrectly();

        (IStakingManager.DepositData[] memory depositDataArray,,,) = _prepareForValidatorRegistration(validatorId);

        vm.prank(alice);
        stakingManagerInstance.pauseContract();

        vm.deal(address(liquidityPoolInstance), 100 ether);

        vm.expectRevert("Pausable: paused");
        vm.prank(address(liquidityPoolInstance));
        stakingManagerInstance.batchRegisterValidators{value: 1 ether}(zeroRoot, validatorId, henry, bob, depositDataArray, alice);
    }

    function test_BatchRegisterValidatorWorksCorrectly() public {
        test_CreateMultipleBids();

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

        vm.prank(address(liquidityPoolInstance));
        uint256[] memory validatorIds = stakingManagerInstance.batchDepositWithBidIds(bidIdArray, 4, alice, bob, henry, ILiquidityPool.SourceOfFunds.EETH, false, 0);

        assertEq(address(auctionInstance).balance, 3 ether, "Auction balance should be 3");

        (IStakingManager.DepositData[] memory depositDataArray,,,) = _prepareForValidatorRegistration(validatorIds);
        vm.deal(address(liquidityPoolInstance), 100 ether);
        vm.prank(address(liquidityPoolInstance));
        stakingManagerInstance.batchRegisterValidators{value: 4 ether}(zeroRoot, validatorIds, henry, bob, depositDataArray, alice);

        assertEq(managerInstance.numberOfValidators(), 4);
        assertEq(auctionInstance.accumulatedRevenue(), 0.4 ether, "Auction accumulated revenue should be 0.4");
        assertEq(address(auctionInstance).balance, 3 ether, "Auction balance should be 4");
        assertEq(address(membershipManagerInstance).balance, 0 ether, "MembershipManager balance should be 1");

        for (uint256 i = 0; i < validatorIds.length; i++) {
            assertEq(BNFTInstance.ownerOf(validatorIds[i]), henry);
            assertEq(TNFTInstance.ownerOf(validatorIds[i]), bob);
        }
    }

    function test_BatchRegisterValidatorFailsIfArrayLengthAreNotEqual() public {
        test_CreateMultipleBids();

        uint256[] memory bidIdArray = new uint256[](3);
        bidIdArray[0] = 1;
        bidIdArray[1] = 2;
        bidIdArray[2] = 6;

        vm.prank(address(liquidityPoolInstance));
        uint256[] memory validatorIds = stakingManagerInstance.batchDepositWithBidIds(bidIdArray, 3, alice, bob, henry, ILiquidityPool.SourceOfFunds.EETH, false, 0);

        (IStakingManager.DepositData[] memory depositDataArray,,,) = _prepareForValidatorRegistration(validatorIds);
        vm.deal(address(liquidityPoolInstance), 100 ether);

        uint256[] memory newWrongValidatorIds = new uint256[](2);

        vm.expectRevert("WRONG_PARAMS");
        vm.prank(address(liquidityPoolInstance));
        stakingManagerInstance.batchRegisterValidators{value: 4 ether}(zeroRoot, newWrongValidatorIds, henry, bob, depositDataArray, alice);
    }

    function test_BatchFailsIfMoreThanMax() public {
        uint256[] memory bidIds = test_CreateMultipleBids();

        vm.prank(alice);
        stakingManagerInstance.setMaxBatchDepositSize(1);

        vm.expectRevert("WRONG_PARAMS");
        vm.prank(address(liquidityPoolInstance));
        stakingManagerInstance.batchDepositWithBidIds(bidIds, 2, alice, bob, henry, ILiquidityPool.SourceOfFunds.EETH, false, 0);

        uint256[] memory validatorIds = new uint256[](2);

        // '1' works though
        vm.prank(address(liquidityPoolInstance));
        uint256[] memory tmp = stakingManagerInstance.batchDepositWithBidIds(bidIds, 1, alice, bob, henry, ILiquidityPool.SourceOfFunds.EETH, false, 0);
        validatorIds[0] = tmp[0];

        vm.prank(address(liquidityPoolInstance));
        tmp = stakingManagerInstance.batchDepositWithBidIds(bidIds, 1, alice, bob, henry, ILiquidityPool.SourceOfFunds.EETH, false, 0);
        validatorIds[1] = tmp[0];

        (IStakingManager.DepositData[] memory depositDataArray,,,) = _prepareForValidatorRegistration(validatorIds);
        vm.deal(address(liquidityPoolInstance), 100 ether);

        vm.expectRevert("WRONG_PARAMS");
        vm.prank(address(liquidityPoolInstance));
        stakingManagerInstance.batchRegisterValidators{value: 1 ether * validatorIds.length}(zeroRoot, validatorIds, henry, bob, depositDataArray, alice);


        (depositDataArray,,,) = _prepareForValidatorRegistration(tmp);
        vm.prank(address(liquidityPoolInstance));
        stakingManagerInstance.batchRegisterValidators{value: 1 ether * tmp.length}(zeroRoot, tmp, henry, bob, depositDataArray, alice);
    }

    function test_cancelDeposit() public {
        //  stakingManagerInstance.batchDepositWithBidIds(bidId, 1, alice, bob, henry, ILiquidityPool.SourceOfFunds.EETH, false, 0);
        uint256[] memory validatorId = test_DepositOneWorksCorrectly();

        vm.prank(address(liquidityPoolInstance));
        vm.expectRevert("INCORRECT_CALLER");
        stakingManagerInstance.batchCancelDepositAsBnftHolder(validatorId, bob);

        vm.prank(address(liquidityPoolInstance));
        vm.expectRevert("INCORRECT_CALLER");
        stakingManagerInstance.batchCancelDepositAsBnftHolder(validatorId, henry);

        vm.prank(address(liquidityPoolInstance));
        stakingManagerInstance.batchCancelDepositAsBnftHolder(validatorId, alice);

        vm.prank(address(liquidityPoolInstance));
        vm.expectRevert("NO_DEPOSIT_EXIST");
        stakingManagerInstance.batchCancelDepositAsBnftHolder(validatorId, alice);
    }

    function test_cancelDepositFailsIfIncorrectPhase() public {
        uint256[] memory validatorId = test_DepositOneWorksCorrectly();

        (IStakingManager.DepositData[] memory depositDataArray,,,) = _prepareForValidatorRegistration(validatorId);
        vm.deal(address(liquidityPoolInstance), 100 ether);
        vm.prank(address(liquidityPoolInstance));
        stakingManagerInstance.batchRegisterValidators{value: 1 ether}(zeroRoot, validatorId, henry, bob, depositDataArray, alice);

        vm.prank(address(liquidityPoolInstance));
        vm.expectRevert("INVALID_PHASE_TRANSITION");
        stakingManagerInstance.batchCancelDepositAsBnftHolder(validatorId, alice);
    }

    function test_cancelDepositFailsIfContractPaused() public {
        uint256[] memory validatorId = test_DepositOneWorksCorrectly();

        vm.prank(alice);
        stakingManagerInstance.pauseContract();

        vm.prank(address(liquidityPoolInstance));
        vm.expectRevert("Pausable: paused");
        stakingManagerInstance.batchCancelDepositAsBnftHolder(validatorId, alice);
    }

    function test_cancelDepositWorksCorrectly() public {
        uint256[] memory validatorId = test_DepositOneWorksCorrectly();

        uint256 selectedBidId = validatorId[0];
        address staker = stakingManagerInstance.bidIdToStaker(validatorId[0]);
        address etherFiNode = managerInstance.etherfiNodeAddress(validatorId[0]);

        assertEq(staker, alice);
        assertEq(selectedBidId, validatorId[0]);
        assertTrue(managerInstance.phase(validatorId[0]) == IEtherFiNode.VALIDATOR_PHASE.STAKE_DEPOSITED);

        (uint256 bidAmount, , address bidder, bool isActive) = auctionInstance.bids(selectedBidId);

        assertEq(bidAmount, 0.1 ether);
        assertEq(bidder, alice);
        assertEq(isActive, false);
        assertEq(auctionInstance.numberOfActiveBids(), 0);
        assertEq(address(auctionInstance).balance, 0.1 ether);
        assertEq(managerInstance.getUnusedWithdrawalSafesLength(), 0);

        vm.expectEmit(true, false, false, true);
        emit DepositCancelled(validatorId[0]);
        vm.prank(address(liquidityPoolInstance));
        stakingManagerInstance.batchCancelDepositAsBnftHolder(validatorId, alice);

        assertEq(managerInstance.etherfiNodeAddress(validatorId[0]), address(0));
        assertEq(stakingManagerInstance.bidIdToStaker(validatorId[0]), address(0));
        assertTrue(managerInstance.phase(validatorId[0]) == IEtherFiNode.VALIDATOR_PHASE.NOT_INITIALIZED);
        assertEq(managerInstance.getUnusedWithdrawalSafesLength(), 1);

        (bidAmount, , bidder, isActive) = auctionInstance.bids(validatorId[0]);
        assertEq(bidAmount, 0.1 ether);
        assertEq(bidder, alice);
        assertEq(isActive, true);
        assertEq(auctionInstance.numberOfActiveBids(), 1);
        assertEq(address(auctionInstance).balance, 0.1 ether);
    }

    function test_SetMaxDeposit() public {
        assertEq(stakingManagerInstance.maxBatchDepositSize(), 25);
        vm.prank(alice);
        stakingManagerInstance.setMaxBatchDepositSize(12);
        assertEq(stakingManagerInstance.maxBatchDepositSize(), 12);

        vm.prank(owner);
        vm.expectRevert("NOT_ADMIN");
        stakingManagerInstance.setMaxBatchDepositSize(12);
    }

    function test_CanOnlySetAddressesOnce() public {
        vm.startPrank(owner);
        vm.expectRevert(StakingManager.ALREADY_SET.selector);
        stakingManagerInstance.registerEtherFiNodeImplementationContract(
            address(0)
        );

        vm.expectRevert(StakingManager.ALREADY_SET.selector);
        stakingManagerInstance.registerTNFTContract(address(0));

        vm.expectRevert(StakingManager.ALREADY_SET.selector);
        stakingManagerInstance.registerBNFTContract(address(0));

        vm.expectRevert(StakingManager.ALREADY_SET.selector);
        stakingManagerInstance.setLiquidityPoolAddress(address(0));

        vm.expectRevert(StakingManager.ALREADY_SET.selector);
        stakingManagerInstance.setEtherFiNodesManagerAddress(address(0));
    }
}
