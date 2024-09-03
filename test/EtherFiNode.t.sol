// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/EtherFiNode.sol";
import "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "../src/eigenlayer-interfaces/IEigenPodManager.sol";
import "../src/eigenlayer-interfaces/IDelayedWithdrawalRouter.sol";

import "forge-std/console2.sol";


contract EtherFiNodeTest is TestSetup {

    // from EtherFiNodesManager.sol
    uint256 TreasuryRewardSplit = 50_000;
    uint256 NodeOperatorRewardSplit = 50_000;
    uint256 TNFTRewardSplit = 815_625;
    uint256 BNFTRewardSplit = 84_375;
    uint256 RewardSplitDivisor = 1_000_000;

    uint256[] bidId;
    EtherFiNode safeInstance;
    EtherFiNode restakingSafe;

    function setUp() public {
        setUpTests();

        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            5
        );

        hoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        bidId = auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);

        startHoax(0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf);

        uint256[] memory bidIdArray = new uint256[](1);
        bidIdArray[0] = bidId[0];

        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray,
            false
        );

        address etherFiNode = managerInstance.etherfiNodeAddress(bidId[0]);

        assertTrue(
            managerInstance.phase(bidId[0]) ==
                IEtherFiNode.VALIDATOR_PHASE.STAKE_DEPOSITED
        );

        IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](1);

        bytes32 root = depGen.generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            //managerInstance.generateWithdrawalCredentials(etherFiNode),
            managerInstance.getWithdrawalCredentials(bidId[0]),
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

        stakingManagerInstance.batchRegisterValidators(zeroRoot, bidId, depositDataArray);
        vm.stopPrank();

        assertTrue(
            managerInstance.phase(bidId[0]) ==
                IEtherFiNode.VALIDATOR_PHASE.LIVE
        );

        safeInstance = EtherFiNode(payable(etherFiNode));

        assertEq(address(etherFiNode).balance, 0 ether);
        assertEq(
            auctionInstance.accumulatedRevenue(),
            0.1 ether
        );
    }


    function test_batchClaimRestakedWithdrawal() public {
        initializeTestingFork(MAINNET_FORK);

        uint256 validator1 = depositAndRegisterValidator(true);
        uint256 validator2 = depositAndRegisterValidator(true);
        EtherFiNode safe1 = EtherFiNode(payable(managerInstance.etherfiNodeAddress(validator1)));
        EtherFiNode safe2 = EtherFiNode(payable(managerInstance.etherfiNodeAddress(validator2)));

        _transferTo(address(safe1.eigenPod()), 1 ether);
        _transferTo(address(safe2.eigenPod()), 2 ether);

        (uint256 _withdrawalSafe, uint256 _eigenPod, uint256 _delayedWithdrawalRouter) = safe1.splitBalanceInExecutionLayer();
        assertEq(_withdrawalSafe, 0 ether);
        assertEq(_eigenPod, 1 ether);
        assertEq(_delayedWithdrawalRouter, 0 ether);
        (_withdrawalSafe, _eigenPod, _delayedWithdrawalRouter) = safe2.splitBalanceInExecutionLayer();
        assertEq(_withdrawalSafe, 0 ether);
        assertEq(_eigenPod, 2 ether);
        assertEq(_delayedWithdrawalRouter, 0 ether);

        uint256[] memory validatorIds = new uint256[](2);
        validatorIds[0] = validator1;
        validatorIds[1] = validator2;
        vm.prank(alice); // alice is admin
        managerInstance.batchQueueRestakedWithdrawal(validatorIds);

        // as of PEPE queing withdrawal does not automatically process partial withdrawals
        (_withdrawalSafe, _eigenPod, _delayedWithdrawalRouter) = safe1.splitBalanceInExecutionLayer();
        assertEq(_withdrawalSafe, 0 ether);
        assertEq(_eigenPod, 1 ether);
        assertEq(_delayedWithdrawalRouter, 0 ether);
        (_withdrawalSafe, _eigenPod, _delayedWithdrawalRouter) = safe2.splitBalanceInExecutionLayer();
        assertEq(_withdrawalSafe, 0 ether);
        assertEq(_eigenPod, 2 ether);
        assertEq(_delayedWithdrawalRouter, 0 ether);

    }

    function test_claimMixedSafeAndPodFunds() public {
        initializeTestingFork(MAINNET_FORK);

        uint256 bidId = depositAndRegisterValidator(true);
        safeInstance = EtherFiNode(payable(managerInstance.etherfiNodeAddress(bidId)));

        // simulate 1 eth of already claimed staking rewards and 1 eth of unclaimed restaked rewards
        _transferTo(address(safeInstance.eigenPod()), 1 ether);
        _transferTo(address(safeInstance), 1 ether);

        assertEq(address(safeInstance).balance, 1 ether);
        assertEq(address(safeInstance.eigenPod()).balance, 1 ether);

        // claim the restaked rewards
        // safeInstance.queueRestakedWithdrawal();
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = bidId;
        vm.prank(alice); // alice is admin
        managerInstance.batchQueueRestakedWithdrawal(validatorIds);

        vm.roll(block.number + (50400) + 1);

        safeInstance.DEPRECATED_claimDelayedWithdrawalRouterWithdrawals();

        assertEq(address(safeInstance).balance, 2 ether);
        assertEq(address(safeInstance.eigenPod()).balance, 0 ether);
    }

    function test_splitBalanceInExecutionLayer() public {

        initializeTestingFork(MAINNET_FORK);

        uint256 validatorId = depositAndRegisterValidator(true);
        safeInstance = EtherFiNode(payable(managerInstance.etherfiNodeAddress(validatorId)));

        uint256 beaconBalance = 32 ether;
        (uint256 toNodeOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury) = (0, 0, 0, 0);

        (uint256 _withdrawalSafe, uint256 _eigenPod, uint256 _delayedWithdrawalRouter) = safeInstance.splitBalanceInExecutionLayer();
        assertEq(_withdrawalSafe, 0 ether);
        assertEq(_eigenPod, 0 ether);
        assertEq(_delayedWithdrawalRouter, 0 ether);

        (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, beaconBalance);
        assertEq(toNodeOperator, 0 ether);
        assertEq(toTreasury, 0 ether);
        assertEq(toTnft, 30 ether);
        assertEq(toBnft, 2 ether);

        // simulate 1 eth of EL staking rewards (such as MEV fee) sent to the eigen pod
        _transferTo(address(safeInstance.eigenPod()), 1 ether);
        assertEq(address(safeInstance.eigenPod()).balance, 1 ether);
        (_withdrawalSafe, _eigenPod, _delayedWithdrawalRouter) = safeInstance.splitBalanceInExecutionLayer();
        assertEq(_withdrawalSafe, 0 ether);
        assertEq(_eigenPod, 1 ether);
        assertEq(_delayedWithdrawalRouter, 0 ether);

        (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, beaconBalance);
        assertEq(toNodeOperator, 1 ether * 5 / 100);
        assertEq(toTreasury, 1 ether * 5 / 100);
        assertEq(toTnft, 30 ether + (1 ether * 90 * 29) / (100 * 32));
        assertEq(toBnft, 2 ether + (1 ether * 90 * 3) / (100 * 32));

        // queue the withdrawal of the rewards. Funds have been sent to the DelayedWithdrawalRouter
        _withdrawNonBeaconChainETHBalanceWei(validatorId);
        (_withdrawalSafe, _eigenPod, _delayedWithdrawalRouter) = safeInstance.splitBalanceInExecutionLayer();
        assertEq(_withdrawalSafe, 0 ether);
        assertEq(_eigenPod, 0 ether);
        assertEq(_delayedWithdrawalRouter, 1 ether);

        (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, beaconBalance);
        assertEq(toNodeOperator, 1 ether * 5 / 100);
        assertEq(toTreasury, 1 ether * 5 / 100);
        assertEq(toTnft, 30 ether + (1 ether * 90 * 29) / (100 * 32));
        assertEq(toBnft, 2 ether + (1 ether * 90 * 3) / (100 * 32));

        // more staking rewards
        _transferTo(address(safeInstance.eigenPod()), 2 ether);
        (_withdrawalSafe, _eigenPod, _delayedWithdrawalRouter) = safeInstance.splitBalanceInExecutionLayer();
        assertEq(_withdrawalSafe, 0 ether);
        assertEq(_eigenPod, 2 ether);
        assertEq(_delayedWithdrawalRouter, 1 ether);

        (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, beaconBalance);
        assertEq(toNodeOperator, 3 ether * 5 / 100);
        assertEq(toTreasury, 3 ether * 5 / 100);
        assertEq(toTnft, 30 ether + (3 ether * 90 * 29) / (100 * 32));
        assertEq(toBnft, 2 ether + (3 ether * 90 * 3) / (100 * 32));
    }

    function test_FullWithdrawWhenBalanceBelow16EthFails() public {
        initializeTestingFork(MAINNET_FORK);

        // create a restaked validator
        uint256 validatorId = depositAndRegisterValidator(false);
        EtherFiNode node = EtherFiNode(payable(managerInstance.etherfiNodeAddress(validatorId)));

        // Marked as EXITED
        uint256[] memory validatorIds = new uint256[](1);
        uint32[] memory exitRequestTimestamps = new uint32[](1);
        validatorIds[0] = validatorId;
        exitRequestTimestamps[0] = uint32(block.timestamp);
        
        vm.deal(address(node), 16 ether - 1);

        vm.prank(alice); // alice is admin
        managerInstance.processNodeExit(validatorIds, exitRequestTimestamps);

        vm.expectRevert("INSUFFICIENT_BALANCE");
        managerInstance.fullWithdraw(validatorId);
    }

    function test_restakedFullWithdrawal() public {
        initializeTestingFork(MAINNET_FORK);

        uint256 validatorId = depositAndRegisterValidator(true);
        safeInstance = EtherFiNode(payable(managerInstance.etherfiNodeAddress(validatorId)));

        uint256[] memory validatorIds = new uint256[](1);
        uint32[] memory exitRequestTimestamps = new uint32[](1);
        validatorIds[0] = validatorId;
        exitRequestTimestamps[0] = uint32(block.timestamp);

        vm.deal(safeInstance.eigenPod(), 32 ether);

        vm.startPrank(alice); // alice is the admin
        vm.expectRevert("NOT_EXITED");
        managerInstance.fullWithdraw(validatorIds[0]);

        // Marked as EXITED
        // should also have queued up the current balance to via DelayedWithdrawalRouter
        vm.expectRevert("NO_FULLWITHDRAWAL_QUEUED");
        managerInstance.processNodeExit(validatorIds, exitRequestTimestamps);


        // TODO
        // IDelayedWithdrawalRouter.DelayedWithdrawal[] memory unclaimedWithdrawals = managerInstance.delayedWithdrawalRouter().getUserDelayedWithdrawals(address(safeInstance));
        // assertEq(unclaimedWithdrawals.length, 1);
        // assertEq(unclaimedWithdrawals[0].amount, uint224(32 ether));

        // // fail because we have not processed the queued withdrawal of the funds from the pod
        // // because not enough time has passed to claim them
        // vm.expectRevert("PENDING_WITHDRAWALS");
        // managerInstance.fullWithdraw(validatorIds[0]);

        // // wait some time
        // vm.roll(block.number + (50400) + 1);

        // assertEq(managerInstance.getUnusedWithdrawalSafesLength(), 0);

        // // try again. FullWithdraw will automatically attempt to claim queuedWithdrawals
        // managerInstance.fullWithdraw(validatorIds[0]);
        // assertEq(address(safeInstance).balance, 0);

        // // safe should have been automatically recycled
        // assertEq(managerInstance.getUnusedWithdrawalSafesLength(), 1);
        // assertEq(uint256(managerInstance.phase(validatorIds[0])), uint256(IEtherFiNode.VALIDATOR_PHASE.FULLY_WITHDRAWN));
        // assertEq(safeInstance.isRestakingEnabled(), false);
        // assertEq(safeInstance.restakingObservedExitBlock(), 0);
    }

    function test_withdrawableBalanceInExecutionLayer() public {
        initializeTestingFork(MAINNET_FORK);

        uint256 validatorId = depositAndRegisterValidator(true);
        safeInstance = EtherFiNode(payable(managerInstance.etherfiNodeAddress(validatorId)));

        assertEq(safeInstance.totalBalanceInExecutionLayer(), 0 ether);
        assertEq(safeInstance.withdrawableBalanceInExecutionLayer(), 0 ether);

        // send some funds to the pod
        _transferTo(safeInstance.eigenPod(), 1 ether);
        assertEq(safeInstance.totalBalanceInExecutionLayer(), 1 ether);
        assertEq(safeInstance.withdrawableBalanceInExecutionLayer(), 0 ether);

        // queue withdrawal
        _withdrawNonBeaconChainETHBalanceWei(validatorId);
        assertEq(safeInstance.totalBalanceInExecutionLayer(), 1 ether);
        assertEq(safeInstance.withdrawableBalanceInExecutionLayer(), 0 ether);

        // more eth to pod
        _transferTo(safeInstance.eigenPod(), 1 ether);
        assertEq(safeInstance.totalBalanceInExecutionLayer(), 2 ether);
        assertEq(safeInstance.withdrawableBalanceInExecutionLayer(), 0 ether);

        // wait so queued withdrawal is claimable
        vm.roll(block.number + (50400) + 1);
        assertEq(safeInstance.totalBalanceInExecutionLayer(), 2 ether);
        assertEq(safeInstance.withdrawableBalanceInExecutionLayer(), 1 ether);

        // claim that withdrawal
        safeInstance.DEPRECATED_claimDelayedWithdrawalRouterWithdrawals();
        assertEq(safeInstance.totalBalanceInExecutionLayer(), 2 ether);
        assertEq(address(safeInstance).balance, 1 ether);
        assertEq(safeInstance.withdrawableBalanceInExecutionLayer(), 1 ether);

        // queue multiple but only some that are claimable
        _withdrawNonBeaconChainETHBalanceWei(validatorId);
        _transferTo(safeInstance.eigenPod(), 1 ether);
        _withdrawNonBeaconChainETHBalanceWei(validatorId);
        vm.roll(block.number + (50400) + 1);
        _transferTo(safeInstance.eigenPod(), 1 ether);
        _withdrawNonBeaconChainETHBalanceWei(validatorId);
        assertEq(safeInstance.withdrawableBalanceInExecutionLayer(), 3 ether);
        assertEq(safeInstance.totalBalanceInExecutionLayer(), 4 ether);
    }

    function _withdrawNonBeaconChainETHBalanceWei(uint256 validatorId) public {
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = validatorId;

        address safe = managerInstance.etherfiNodeAddress(validatorId);
        address eigenPod = managerInstance.getEigenPod(validatorId);

        bytes4 selector = bytes4(keccak256("withdrawNonBeaconChainETHBalanceWei(address,uint256)"));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, safe, address(eigenPod).balance);

        vm.prank(owner);
        managerInstance.forwardEigenpodCall(validatorIds, data);
    }

    function testFullWithdrawBurnsTNFT() public {
        initializeTestingFork(MAINNET_FORK);

        uint256 validatorId = depositAndRegisterValidator(false);
        safeInstance = EtherFiNode(payable(managerInstance.etherfiNodeAddress(validatorId)));

        uint256[] memory validatorIds = new uint256[](1);
        uint32[] memory exitRequestTimestamps = new uint32[](1);
        validatorIds[0] = validatorId;
        exitRequestTimestamps[0] = uint32(block.timestamp);

        vm.deal(address(safeInstance), 32 ether);

        vm.startPrank(alice); // alice is the admin
        vm.expectRevert("NOT_EXITED");
        managerInstance.fullWithdraw(validatorId);

        // Marked as EXITED
        // should also have queued up the current balance to via DelayedWithdrawalRouter
        managerInstance.processNodeExit(validatorIds, exitRequestTimestamps);

        // alice should own the tNFT since she created the validator
        assertEq(TNFTInstance.ownerOf(validatorId), alice);

        // withdraw the node
        managerInstance.fullWithdraw(validatorIds[0]);

        // tNFT should be burned
        vm.expectRevert("ERC721: invalid token ID");
        TNFTInstance.ownerOf(validatorId);
        // bNFT should be burned
        vm.expectRevert("ERC721: invalid token ID");
        BNFTInstance.ownerOf(validatorId);
    }

    function test_EtherFiNodeMultipleSafesWorkCorrectly() public {

        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(
            aliceIPFSHash,
            5
        );

        vm.prank(chad);
        nodeOperatorManagerInstance.registerNodeOperator(
            aliceIPFSHash,
            5
        );

        hoax(alice);
        uint256[] memory bidId1 = auctionInstance.createBid{value: 0.4 ether}(
            1,
            0.4 ether
        );

        hoax(chad);
        uint256[] memory bidId2 = auctionInstance.createBid{value: 0.3 ether}(
            1,
            0.3 ether
        );

        hoax(bob);
        uint256[] memory bidIdArray = new uint256[](1);
        bidIdArray[0] = bidId1[0];

        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray,
            false
        );

        hoax(dan);
        bidIdArray = new uint256[](1);
        bidIdArray[0] = bidId2[0];

        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray,
            false
        );

        {
            address staker_2 = stakingManagerInstance.bidIdToStaker(bidId1[0]);
            address staker_3 = stakingManagerInstance.bidIdToStaker(bidId2[0]);
            assertEq(staker_2, bob);
            assertEq(staker_3, dan);
        }

        address etherFiNode = managerInstance.etherfiNodeAddress(bidId1[0]);

        IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](1);

        root = depGen.generateDepositRoot(
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

        startHoax(bob);
        stakingManagerInstance.batchRegisterValidators(zeroRoot, bidId1, depositDataArray);
        vm.stopPrank();

        assertEq(address(managerInstance.etherfiNodeAddress(bidId1[0])).balance, 0);

        etherFiNode = managerInstance.etherfiNodeAddress(bidId2[0]);

        IStakingManager.DepositData[]
            memory depositDataArray2 = new IStakingManager.DepositData[](1);

        root = depGen.generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            managerInstance.generateWithdrawalCredentials(etherFiNode),
            32 ether
        );

        depositData = IStakingManager
            .DepositData({
                publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "test_ipfs"
            });
        
        depositDataArray2[0] = depositData;

        startHoax(dan);
        stakingManagerInstance.batchRegisterValidators(zeroRoot, bidId2, depositDataArray2);
        vm.stopPrank();

        assertEq(address(managerInstance.etherfiNodeAddress(bidId2[0])).balance, 0);
    }

    function test_markExitedWorksCorrectly() public {
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = bidId[0];
        uint32[] memory exitTimestamps = new uint32[](1);
        exitTimestamps[0] = 1;
        address etherFiNode = managerInstance.etherfiNodeAddress(validatorIds[0]);

        assertTrue(
            managerInstance.phase(validatorIds[0]) ==
                IEtherFiNode.VALIDATOR_PHASE.LIVE
        );
        assertTrue(IEtherFiNode(etherFiNode).DEPRECATED_exitTimestamp() == 0);

        vm.expectRevert("INCORRECT_CALLER");
        IEtherFiNode(etherFiNode).processNodeExit(1);

        vm.expectRevert(EtherFiNodesManager.NotAdmin.selector);
        vm.prank(bob);
        managerInstance.processNodeExit(validatorIds, exitTimestamps);
        IEtherFiNodesManager.ValidatorInfo memory info = managerInstance.getValidatorInfo(validatorIds[0]);
        assertTrue(info.phase == IEtherFiNode.VALIDATOR_PHASE.LIVE);
        assertTrue(info.exitTimestamp == 0);

        hoax(alice);
        managerInstance.processNodeExit(validatorIds, exitTimestamps);
        info = managerInstance.getValidatorInfo(validatorIds[0]);
        assertTrue(info.phase == IEtherFiNode.VALIDATOR_PHASE.EXITED);
        assertTrue(info.exitTimestamp > 0);

        hoax(alice);
        vm.expectRevert("INVALID_PHASE_TRANSITION");
        managerInstance.processNodeExit(validatorIds, exitTimestamps);
    }

    function test_markExitedWorksCorrectlyWhenBeingSlashed() public {
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = bidId[0];
        uint32[] memory exitTimestamps = new uint32[](1);
        exitTimestamps[0] = 1;
        address etherFiNode = managerInstance.etherfiNodeAddress(validatorIds[0]);

        IEtherFiNodesManager.ValidatorInfo memory info = managerInstance.getValidatorInfo(validatorIds[0]);
        assertTrue(info.phase == IEtherFiNode.VALIDATOR_PHASE.LIVE);
        assertTrue(info.exitTimestamp == 0);

        hoax(alice);
        managerInstance.markBeingSlashed(validatorIds);
        info = managerInstance.getValidatorInfo(validatorIds[0]);
        assertTrue(info.phase == IEtherFiNode.VALIDATOR_PHASE.BEING_SLASHED);

        hoax(alice);
        managerInstance.processNodeExit(validatorIds, exitTimestamps);
        info = managerInstance.getValidatorInfo(validatorIds[0]);
        assertTrue(info.phase == IEtherFiNode.VALIDATOR_PHASE.EXITED);
        assertTrue(info.exitTimestamp > 0);
    }


    function test_markBeingSlashedFails() public {
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = bidId[0];
        uint32[] memory exitTimestamps = new uint32[](1);
        exitTimestamps[0] = 1;

        hoax(alice);
        managerInstance.processNodeExit(validatorIds, exitTimestamps);

        hoax(alice);
        vm.expectRevert("INVALID_PHASE_TRANSITION");
        managerInstance.markBeingSlashed(bidId);
    }

    function test_markBeingSlashedWorks() public {
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = bidId[0];
        uint32[] memory exitTimestamps = new uint32[](1);
        exitTimestamps[0] = 1;
        address etherFiNode = managerInstance.etherfiNodeAddress(validatorIds[0]);

        hoax(alice);
        managerInstance.markBeingSlashed(bidId);
        assertTrue(managerInstance.phase(bidId[0]) == IEtherFiNode.VALIDATOR_PHASE.BEING_SLASHED);
    }

    /*
    function test_partialWithdrawAfterExitRequest() public {
        address nodeOperator = 0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931;
        address staker = 0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf;
        address etherfiNode = managerInstance.etherfiNodeAddress(bidId[0]);

        // Simulate the rewards distribution from the beacon chain
        vm.deal(etherfiNode, address(etherfiNode).balance + 1 ether);

        // Send Exit Request
        hoax(TNFTInstance.ownerOf(bidId[0]));
        managerInstance.batchSendExitRequest(_to_uint256_array(bidId[0]));

        vm.prank(managerInstance.owner());
        vm.expectRevert("PENDING_EXIT_REQUEST");
        managerInstance.partialWithdraw(bidId[0]);
    }
    */

    function test_getFullWithdrawalPayoutsFails() public {

        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = bidId[0];
        address etherfiNode = managerInstance.etherfiNodeAddress(
            validatorIds[0]
        );

        vm.deal(etherfiNode, 16 ether);
        vm.expectRevert("NOT_EXITED");
        managerInstance.fullWithdraw(validatorIds[0]);
    }

    function test_processNodeDistributeProtocolRevenueCorrectly() public {
        address nodeOperator = 0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931;
        address staker = 0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf;

        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = bidId[0];
        uint32[] memory exitTimestamps = new uint32[](1);
        exitTimestamps[0] = 1;

        uint256 nodeOperatorBalance = address(nodeOperator).balance;
        uint256 treasuryBalance = address(treasuryInstance).balance;
        uint256 stakerBalance = address(staker).balance;

        startHoax(alice);
        managerInstance.processNodeExit(validatorIds, exitTimestamps);
        vm.stopPrank();

        // no auction rewards anymore
        assertEq(address(nodeOperator).balance, nodeOperatorBalance);
        assertEq(address(treasuryInstance).balance, treasuryBalance);
        assertEq(address(staker).balance, stakerBalance);
    }


    function test_getFullWithdrawalPayoutsWorksCorrectly1() public {
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = bidId[0];
        uint32[] memory exitTimestamps = new uint32[](1);
        exitTimestamps[0] = 1;
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorIds[0]);

        startHoax(alice);
        assertEq(managerInstance.numberOfValidators(), 1);
        managerInstance.processNodeExit(validatorIds, exitTimestamps);
        assertEq(managerInstance.numberOfValidators(), 0);
        vm.stopPrank();

        // 1. balance > 32 ether
        vm.deal(etherfiNode, 33 ether);
        assertEq(address(etherfiNode).balance, 33 ether);

        uint256 stakingRewards = 1 ether;
        (
            uint256 toNodeOperator,
            uint256 toTnft,
            uint256 toBnft,
            uint256 toTreasury
        ) = managerInstance.getFullWithdrawalPayouts(validatorIds[0]);
        assertEq(toNodeOperator, stakingRewards * NodeOperatorRewardSplit / RewardSplitDivisor);
        assertEq(toTreasury, stakingRewards * TreasuryRewardSplit / RewardSplitDivisor);
        assertEq(toTnft, 30 ether + (stakingRewards * TNFTRewardSplit / RewardSplitDivisor));
        assertEq(toBnft, 2 ether + (stakingRewards * BNFTRewardSplit / RewardSplitDivisor));

        // 2. balance > 31.5 ether
        vm.deal(etherfiNode, 31.75 ether);
        assertEq(address(etherfiNode).balance, 31.75 ether);

        (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance
            .getFullWithdrawalPayouts(validatorIds[0]);
        assertEq(toNodeOperator, 0);
        assertEq(toTreasury, 0);
        assertEq(toTnft, 30 ether);
        assertEq(toBnft, 1.75 ether);

        // 3. balance > 26 ether
        vm.deal(etherfiNode, 28.5 ether);
        assertEq(address(etherfiNode).balance, 28.5 ether);

        (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance
            .getFullWithdrawalPayouts(validatorIds[0]);
        assertEq(toNodeOperator, 0);
        assertEq(toTreasury, 0);
        assertEq(toTnft, 27.5 ether);
        assertEq(toBnft, 1 ether);

        // 4. balance > 25.5 ether
        vm.deal(etherfiNode, 25.75 ether);
        assertEq(address(etherfiNode).balance, 25.75 ether);
        (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance
            .getFullWithdrawalPayouts(validatorIds[0]);
        assertEq(toNodeOperator, 0);
        assertEq(toTreasury, 0);
        assertEq(toTnft, 24.75 ether);
        assertEq(toBnft, 1 ether);

        // 5. balance > 16 ether
        vm.deal(etherfiNode, 18.5 ether);
        assertEq(address(etherfiNode).balance, 18.5 ether);

        (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance
            .getFullWithdrawalPayouts(validatorIds[0]);
        assertEq(toNodeOperator, 0);
        assertEq(toTreasury, 0);
        assertEq(toTnft, 17.5 ether);
        assertEq(toBnft, 1 ether);

        // 6. balance = 16 ether
        vm.deal(etherfiNode, 16 ether);

        (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance
            .getFullWithdrawalPayouts(validatorIds[0]);
        assertEq(toNodeOperator, 0);
        assertEq(toTreasury, 0);
        assertEq(toTnft, 15 ether);
        assertEq(toBnft, 1 ether);

        // 7. balance < 16 ether
        vm.deal(etherfiNode, 16 ether - 1);

        vm.expectRevert();
        (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance
            .getFullWithdrawalPayouts(validatorIds[0]);
    }

    /*
    function test_partialWithdrawAfterExitFails() public {
        address nodeOperator = 0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931;
        address staker = 0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf;

        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = bidId[0];
        uint32[] memory exitTimestamps = new uint32[](1);
        exitTimestamps[0] = 1;
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorIds[0]);

        // 8. balance < 4 ether
        vm.deal(etherfiNode, 4 ether);

        startHoax(alice);
        assertEq(managerInstance.numberOfValidators(), 1);
        managerInstance.processNodeExit(validatorIds, exitTimestamps);
        assertEq(managerInstance.numberOfValidators(), 0);
        vm.stopPrank();

        // Transfer the T-NFT to 'dan'
        hoax(staker);
        TNFTInstance.transferFrom(staker, dan, validatorIds[0]);

        hoax(owner);
        vm.expectRevert("NOT_LIVE");
        managerInstance.partialWithdraw(validatorIds[0]);
    }
    */

    function test_getFullWithdrawalPayoutsAuditFix3() public {
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = bidId[0];
        uint32[] memory exitTimestamps = new uint32[](1);
        exitTimestamps[0] = 1;
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorIds[0]);

        startHoax(alice);
        assertEq(managerInstance.numberOfValidators(), 1);
        managerInstance.processNodeExit(validatorIds, exitTimestamps);
        assertEq(managerInstance.numberOfValidators(), 0);
        vm.stopPrank();

        uint256 stakingRewards = 0.04 ether;
        vm.deal(etherfiNode, 32 ether + stakingRewards);

        assertEq(address(etherfiNode).balance, 32 ether + stakingRewards);

        {
            (uint256 toNodeOperator,
            uint256 toTnft,
            uint256 toBnft,
            uint256 toTreasury
            ) = managerInstance.getFullWithdrawalPayouts(validatorIds[0]);

            assertEq(toNodeOperator, stakingRewards * NodeOperatorRewardSplit / RewardSplitDivisor);
            assertEq(toTnft, 30 ether + stakingRewards * TNFTRewardSplit / RewardSplitDivisor);
            assertEq(toBnft, 2 ether + stakingRewards * BNFTRewardSplit / RewardSplitDivisor);
            assertEq(toTreasury, stakingRewards * TreasuryRewardSplit / RewardSplitDivisor);
        }

        skip(6 * 7 * 4 days);

        // auction rewards no longer vest so should be the same as above
        {
            (uint256 toNodeOperator,
            uint256 toTnft,
            uint256 toBnft,
            uint256 toTreasury
            ) = managerInstance.getFullWithdrawalPayouts(validatorIds[0]);

            assertEq(toNodeOperator, stakingRewards * NodeOperatorRewardSplit / RewardSplitDivisor);
            assertEq(toTnft, 30 ether + stakingRewards * TNFTRewardSplit / RewardSplitDivisor);
            assertEq(toBnft, 2 ether + stakingRewards * BNFTRewardSplit / RewardSplitDivisor);
            assertEq(toTreasury, stakingRewards * TreasuryRewardSplit / RewardSplitDivisor);
        }
    }

    function test_getFullWithdrawalPayoutsAuditFix2() public {
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = bidId[0];
        uint32[] memory exitTimestamps = new uint32[](1);
        exitTimestamps[0] = 1;
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorIds[0]);

        startHoax(alice);
        assertEq(managerInstance.numberOfValidators(), 1);
        managerInstance.processNodeExit(validatorIds, exitTimestamps);
        assertEq(managerInstance.numberOfValidators(), 0);
        vm.stopPrank();

        //uint256 stakingRewards = 0.949 ether;
        vm.deal(etherfiNode, 31.949 ether);
        assertEq(
            address(etherfiNode).balance,
            31.949000000000000000 ether
        ); 


        skip(6 * 7 * 4 days);

        // auction rewards no longer vest so should be the same as above
        {
            (uint256 toNodeOperator,
            uint256 toTnft,
            uint256 toBnft,
            uint256 toTreasury
            ) = managerInstance.getFullWithdrawalPayouts(validatorIds[0]);

            assertEq(toNodeOperator, 0);
            assertEq(toTnft, 30 ether);
            assertEq(toBnft, 1.949000000000000000 ether);
            assertEq(toTreasury, 0);
        }
    }


    function test_getFullWithdrawalPayoutsWorksWithNonExitPenaltyCorrectly1()
        public
    {
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = bidId[0];
        uint32[] memory exitTimestamps = new uint32[](1);
        exitTimestamps[0] = uint32(block.timestamp) + 86400;
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorIds[0]);

        assertEq(IEtherFiNode(etherfiNode).numExitRequestsByTnft(), 0);

        hoax(TNFTInstance.ownerOf(validatorIds[0]));
        managerInstance.batchSendExitRequest(_to_uint256_array(validatorIds[0]));

        assertEq(IEtherFiNode(etherfiNode).numExitRequestsByTnft(), 1);

        // 1 day passed
        vm.warp(block.timestamp + 86400);
        startHoax(alice);
        managerInstance.processNodeExit(validatorIds, exitTimestamps);
        uint256 nonExitPenalty = managerInstance.getNonExitPenalty(bidId[0]);

        // simulate staking rewards
        uint256 stakingRewards = 1 ether;
        vm.deal(etherfiNode, 32 ether + stakingRewards);

        (uint256 toNodeOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury) = managerInstance.getFullWithdrawalPayouts(validatorIds[0]);
        assertEq(nonExitPenalty, 0.03 ether);
        assertEq(toNodeOperator, nonExitPenalty + (stakingRewards * NodeOperatorRewardSplit / RewardSplitDivisor));
        assertEq(toTreasury, stakingRewards * TreasuryRewardSplit / RewardSplitDivisor);
        assertEq(toTnft, 30 ether + (stakingRewards * TNFTRewardSplit / RewardSplitDivisor));
        assertEq(toBnft, 2 ether - nonExitPenalty + (stakingRewards * BNFTRewardSplit / RewardSplitDivisor));
    }

    function test_getFullWithdrawalPayoutsWorksWithNonExitPenaltyCorrectly2()
        public
    {
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = bidId[0];
        uint32[] memory exitTimestamps = new uint32[](1);
        exitTimestamps[0] = uint32(block.timestamp) + (1 + 7 * 86400);
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorIds[0]);

        hoax(TNFTInstance.ownerOf(validatorIds[0]));
        managerInstance.batchSendExitRequest(_to_uint256_array(validatorIds[0]));

        // 7 days passed
        vm.warp(block.timestamp + (1 + 7 * 86400));
        startHoax(alice);
        managerInstance.processNodeExit(validatorIds, exitTimestamps);
        uint256 nonExitPenalty = managerInstance.getNonExitPenalty(bidId[0]);

        // simulate staking rewards
        uint256 stakingRewards = 1 ether;
        vm.deal(etherfiNode, 32 ether + stakingRewards);

        (uint256 toNodeOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury) = managerInstance.getFullWithdrawalPayouts(validatorIds[0]);
        assertEq(toNodeOperator, nonExitPenalty + (stakingRewards * NodeOperatorRewardSplit / RewardSplitDivisor));
        assertEq(toTreasury, stakingRewards * TreasuryRewardSplit / RewardSplitDivisor);
        assertEq(toTnft, 30 ether + (stakingRewards * TNFTRewardSplit / RewardSplitDivisor));
        assertEq(toBnft, 2 ether - nonExitPenalty + (stakingRewards * BNFTRewardSplit / RewardSplitDivisor));
    }

    function test_getFullWithdrawalPayoutsWorksWithNonExitPenaltyCorrectly4()
        public
    {
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = bidId[0];
        uint32[] memory exitTimestamps = new uint32[](1);
        exitTimestamps[0] = uint32(block.timestamp) + 28 * 86400;
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorIds[0]);

        hoax(TNFTInstance.ownerOf(validatorIds[0]));
        managerInstance.batchSendExitRequest(_to_uint256_array(validatorIds[0]));

        // 28 days passed
        // When (appliedPenalty <= 0.2 ether)
        vm.warp(block.timestamp + 28 * 86400);
        startHoax(alice);
        managerInstance.processNodeExit(validatorIds, exitTimestamps);
        uint256 nonExitPenalty = managerInstance.getNonExitPenalty(bidId[0]);

        // see EtherFiNode.sol:calculateTVL()
        // the node got slashed seriously
        vm.deal(etherfiNode, 16 ether);
        (uint256 toNodeOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury) = managerInstance.getFullWithdrawalPayouts(validatorIds[0]);
        assertEq(nonExitPenalty, 0.573804794831376551 ether);

        assertEq(toNodeOperator, 0.2 ether); // incentive for nodeOperator from NonExitPenalty caps at 0.2 ether
        assertEq(toTreasury, nonExitPenalty - 0.2 ether); // treasury gets excess penalty if node operator delays too long
        assertEq(toTnft, 15 ether);
        assertEq(toBnft, 1 ether - 0.573804794831376551 ether); // BNFT has been fully penalized for not exiting
    }

    function test_markExitedFails() public {
        uint256[] memory validatorIds = new uint256[](1);
        uint32[] memory exitTimestamps = new uint32[](2);
        startHoax(alice);
        vm.expectRevert(EtherFiNodesManager.InvalidParams.selector);
        managerInstance.processNodeExit(validatorIds, exitTimestamps);
    }

    function test_getFullWithdrawalPayoutsWorksWithNonExitPenaltyCorrectly3() public {
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = bidId[0];
        uint32[] memory exitTimestamps = new uint32[](1);
        exitTimestamps[0] = uint32(block.timestamp) + (1 + 28 * 86400);
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorIds[0]);

        hoax(TNFTInstance.ownerOf(validatorIds[0]));
        managerInstance.batchSendExitRequest(_to_uint256_array(validatorIds[0]));

        // 28 days passed
        // When (appliedPenalty > 0.2 ether)
        vm.warp(block.timestamp + (1 + 28 * 86400));
        startHoax(alice);
        managerInstance.processNodeExit(validatorIds, exitTimestamps);
        uint256 nonExitPenalty = managerInstance.getNonExitPenalty(bidId[0]);
        assertGe(nonExitPenalty, 0.5 ether);

        // Treasury gets the excess penalty reward after the node operator hits the 0.2 eth cap
        // Treasury also gets the base reward of the node operator since its over 14 days
        uint256 baseTreasuryPayout = (1 ether * TreasuryRewardSplit / RewardSplitDivisor);
        uint256 baseNodeOperatorPayout = (1 ether * NodeOperatorRewardSplit / RewardSplitDivisor);

        uint256 stakingRewards = 1 ether;
        vm.deal(etherfiNode, 32 ether + stakingRewards);
        (
            uint256 toNodeOperator,
            uint256 toTnft,
            uint256 toBnft,
            uint256 toTreasury
        ) = managerInstance.getFullWithdrawalPayouts(validatorIds[0]);
        assertEq(toNodeOperator, 0.2 ether + baseNodeOperatorPayout);
        assertEq(toTreasury, baseTreasuryPayout + (nonExitPenalty - 0.2 ether));
        assertEq(toTnft, 30 ether + (stakingRewards * TNFTRewardSplit / RewardSplitDivisor));
        assertEq(toBnft, 2 ether - nonExitPenalty + (stakingRewards * BNFTRewardSplit / RewardSplitDivisor));
    }

    function test_getFullWithdrawalPayoutsWorksWithNonExitPenaltyCorrectly5() public {

        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = bidId[0];
        uint32[] memory exitTimestamps = new uint32[](1);
        exitTimestamps[0] = uint32(block.timestamp) + (1 + 28 * 86400);
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorIds[0]);

        hoax(TNFTInstance.ownerOf(validatorIds[0]));
        managerInstance.batchSendExitRequest(_to_uint256_array(validatorIds[0]));

        // 2 * 28 days passed
        // When (appliedPenalty > 0.2 ether)
        vm.warp(block.timestamp + (1 + 2 * 28 * 86400));
        hoax(alice);
        managerInstance.processNodeExit(validatorIds, exitTimestamps);
        uint256 nonExitPenalty = managerInstance.getNonExitPenalty(bidId[0]);


        uint256 stakingRewards = 1 ether;
        vm.deal(etherfiNode, 32 ether + stakingRewards);

        // Treasury gets the excess penalty reward after the node operator hits the 0.2 eth cap
        // Treasury also gets the base reward of the node operator since its over 14 days
        uint256 baseTreasuryPayout = (1 ether * TreasuryRewardSplit / RewardSplitDivisor);
        uint256 baseNodeOperatorPayout = (1 ether * NodeOperatorRewardSplit / RewardSplitDivisor);

        (
            uint256 toNodeOperator,
            uint256 toTnft,
            uint256 toBnft,
            uint256 toTreasury
        ) = managerInstance.getFullWithdrawalPayouts(validatorIds[0]);
        assertEq(toNodeOperator, 0.2 ether + baseNodeOperatorPayout);
        assertEq(toTreasury, baseTreasuryPayout + (nonExitPenalty - 0.2 ether));
        assertEq(toTnft, 30 ether + (stakingRewards *TNFTRewardSplit / RewardSplitDivisor));
        assertEq(toBnft, 2 ether - nonExitPenalty + (stakingRewards * BNFTRewardSplit / RewardSplitDivisor));
    }

    function test_sendEthToEtherFiNodeContractSucceeds() public {
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = bidId[0];
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorIds[0]);

        vm.deal(owner, 10 ether);
        vm.prank(owner);
        uint256 nodeBalance = address(etherfiNode).balance;
        (bool sent, ) = address(etherfiNode).call{value: 5 ether}("");
        require(sent, "Failed to send eth");
        assertEq(address(etherfiNode).balance, nodeBalance + 5 ether);
    }

    function test_ExitRequestAfterExitFails() public {
        uint256[] memory validatorIds = new uint256[](1);
        uint32[] memory exitTimestamps = new uint32[](1);

        validatorIds[0] = bidId[0];

        vm.prank(alice);
        managerInstance.processNodeExit(validatorIds, exitTimestamps);

        vm.prank(TNFTInstance.ownerOf(validatorIds[0]));
        exitTimestamps[0] = uint32(block.timestamp);

        // T-NFT holder sends the exit request after the node is marked EXITED
        vm.expectRevert("INVALID");
        managerInstance.batchSendExitRequest(_to_uint256_array(validatorIds[0]));
    }

    function test_ExitTimestampBeforeExitRequestLeadsToZeroNonExitPenalty() public {
        uint256[] memory validatorIds = new uint256[](1);
        uint32[] memory exitTimestamps = new uint32[](1);

        validatorIds[0] = bidId[0];

        vm.prank(TNFTInstance.ownerOf(validatorIds[0]));
        managerInstance.batchSendExitRequest(_to_uint256_array(validatorIds[0]));

        // the node actually exited a second before the exit request from the T-NFT holder
        vm.prank(alice);
        exitTimestamps[0] = uint32(block.timestamp) - 1;
        managerInstance.processNodeExit(validatorIds, exitTimestamps);

        uint256 nonExitPenalty = managerInstance.getNonExitPenalty(bidId[0]);
        assertEq(nonExitPenalty, 0 ether);
    }

    function test_ImplementationContract() public {
        assertEq(safeInstance.implementation(), address(node));
    }

    function test_trackingTVL() public {
        uint256 validatorId = bidId[0];

        (uint256 toNodeOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury) = (0, 0, 0, 0);

        // (Validator 'active_not_slashed', Accrued rewards in CL = 1 ether)
        {
            uint256 beaconBalance = 32 ether + 1 ether;

            (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, beaconBalance);
            assertEq(toNodeOperator, 0.05 ether);
            assertEq(toTreasury, 0.05 ether);
            assertEq(toTnft, 30.815625000000000000 ether);
            assertEq(toBnft, 2.084375000000000000 ether);
        }

        // (Validator 'active_not_slashed', Accrued rewards in CL = 0)
        {
            uint256 beaconBalance = 32 ether;

            (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, beaconBalance);
            assertEq(toNodeOperator, 0 ether);
            assertEq(toTreasury, 0 ether);
            assertEq(toTnft, 30 ether);
            assertEq(toBnft, 2 ether);
        }

        // (Validator 'active_slashed', slashing penalty in CL = 0.5 ether)
        // - slashing penalty [0, 1 ether] is paid by the B-NFT holder
        {
            uint256 beaconBalance = 31.5 ether;

            (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, beaconBalance);
            assertEq(toNodeOperator, 0 ether);
            assertEq(toTreasury, 0 ether);
            assertEq(toTnft, 30 ether);
            assertEq(toBnft, 1.5 ether);
        }

        // (Validator 'active_slashed', slashing penalty in CL = 1 ether)
        {
            uint256 beaconBalance = 31 ether;

            (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, beaconBalance);
            assertEq(toNodeOperator, 0 ether);
            assertEq(toTreasury, 0 ether);
            assertEq(toTnft, 30 ether);
            assertEq(toBnft, 1 ether);
        }

        {
            uint256 beaconBalance = 30 ether;

            (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, beaconBalance);
            assertEq(toNodeOperator, 0 ether);
            assertEq(toTreasury, 0 ether);
            assertEq(toTnft, 29 ether);
            assertEq(toBnft, 1 ether);
        }

        // The worst-case, 16 ether is all slashed!
        {
            uint256 beaconBalance = 16 ether;

            (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, beaconBalance);
            assertEq(toNodeOperator, 0 ether);
            assertEq(toTreasury, 0 ether);
            assertEq(toTnft, 15 ether);
            assertEq(toBnft, 1 ether);
        }
    }

    function test_trackingTVL2() public {
        uint256 validatorId = bidId[0];       
        uint256[] memory tvls = new uint256[](4);  // (operator, tnft, bnft, treasury)
        (uint256 toNodeOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury) = (0, 0, 0, 0);

        // Check the staking rewards when we have 1 ether accrued
        {
            uint256 beaconBalance = 32 ether + 1 ether;

            (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, beaconBalance);
            assertEq(toNodeOperator, 0.05 ether);
            assertEq(toTreasury, 0.05 ether);
            assertEq(toTnft, 30.815625000000000000 ether);
            assertEq(toBnft, 2.084375000000000000 ether);
            tvls[0] += toNodeOperator;
            tvls[1] += toTnft;
            tvls[2] += toBnft;
            tvls[3] += toTreasury;

            assertEq(beaconBalance, toNodeOperator + toTnft + toBnft + toTreasury);
        }

        // Confirm the total TVL
        {
            uint256 beaconBalance = 32 ether + 1 ether;

            (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, beaconBalance);
            assertEq(toNodeOperator, tvls[0]);
            assertEq(toTreasury, tvls[3]);
            assertEq(toTnft, tvls[1]);
            assertEq(toBnft, tvls[2]);
        }

        // Confirm that after exiting the validator node from the beacon network,
        // if we trigger the full withdrawal, the same amount is transferred to {stakers, operator, treasury}
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorId);

        uint256[] memory validatorIds = new uint256[](1);
        uint32[] memory exitRequestTimestamps = new uint32[](1);
        validatorIds[0] = validatorId;
        exitRequestTimestamps[0] = uint32(block.timestamp);

        address nodeOperator = 0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931;
        address staker = 0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf;

        // Transfer the T-NFT to 'dan' (Just for testing scenario)
        vm.prank(staker);
        TNFTInstance.transferFrom(staker, dan, bidId[0]);

        uint256 nodeOperatorBalance = address(nodeOperator).balance;
        uint256 treasuryBalance = address(treasuryInstance).balance;
        uint256 bnftStakerBalance = address(staker).balance;
        uint256 tNftStakerBalance = address(dan).balance;

        // Simulate the withdrawal from Beacon Network to Execution Layer
        _transferTo(etherfiNode, 32 ether + 1 ether);

        // After a long period of time (after the auction fee vesting period completes)
        skip(6 * 7 * 4 days);

        vm.prank(alice);
        managerInstance.processNodeExit(validatorIds, exitRequestTimestamps); // Marked as EXITED
        managerInstance.batchFullWithdraw(validatorIds); // Full Withdrawal!

        assertEq(address(nodeOperator).balance, nodeOperatorBalance + tvls[0]);
        assertEq(address(dan).balance, tNftStakerBalance + tvls[1]);
        assertEq(address(staker).balance, bnftStakerBalance + tvls[2]);
        assertEq(address(treasuryInstance).balance, treasuryBalance + tvls[3]);
    }

    function test_withdrawFundsFailsWhenReceiverConsumedTooMuchGas() public {
        uint256 validatorId = bidId[0];
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorId);
        vm.deal(address(etherfiNode), 3 ether); // need to give node some eth because it no longer has auction revenue

        uint256 treasuryBalance = address(treasuryInstance).balance;
        uint256 noAttackerBalance = address(noAttacker).balance;
        uint256 revertAttackerBalance = address(revertAttacker).balance;
        uint256 gasDrainAttackerBalance = address(gasDrainAttacker).balance;

        vm.startPrank(address(managerInstance));
        IEtherFiNode(etherfiNode).withdrawFunds(
            address(treasuryInstance), 0,
            address(revertAttacker), 1,
            address(noAttacker), 1,
            address(gasDrainAttacker), 1
        );
        vm.stopPrank();

        assertEq(address(revertAttacker).balance, revertAttackerBalance);
        assertEq(address(noAttacker).balance, noAttackerBalance + 1);
        assertEq(address(gasDrainAttacker).balance, gasDrainAttackerBalance);
        assertEq(address(treasuryInstance).balance, treasuryBalance + 2);
    }

    function test_trackingTVL3() public {
        uint256 tvl = 0;
        uint256 numBnftsHeldByLP = 0; // of validators in [LIVE, EXITED, BEING_SLASHED]
        uint256 numTnftsHeldByLP = 0; // of validators in [LIVE, EXITED, BEING_SLASHED]
        uint256 numValidators_STAKE_DEPOSITED = 0;
        uint256 numValidators_WATING_FOR_APPROVAL = 0;
        assertEq(address(liquidityPoolInstance).balance, 0);
        assertEq(address(stakingManagerInstance).balance, 0);

        uint256[] memory validatorIds = launch_validator(1, 0, true);
        uint256 validatorId = validatorIds[0];
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorId);

        // tvl = (BNFT) + (TNFT) + (LP Balance) - ....
        numBnftsHeldByLP = 1;
        numTnftsHeldByLP = 1;
        numValidators_STAKE_DEPOSITED = 0;
        numValidators_WATING_FOR_APPROVAL = 0;
        tvl = numBnftsHeldByLP * 2 ether + numTnftsHeldByLP * 30 ether + address(liquidityPoolInstance).balance - numValidators_STAKE_DEPOSITED * 2 ether - numValidators_WATING_FOR_APPROVAL * 1 ether;
        assertEq(liquidityPoolInstance.getTotalPooledEther(), tvl);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 32 ether);
        assertEq(address(liquidityPoolInstance).balance, 0);
        assertEq(address(stakingManagerInstance).balance, 0);

        vm.startPrank(alice);

        // ---------------------------------------------------------- //
        // -------------- BNFT to BNFT-Staker, TNFT to LP ----------- //
        // ---------------------------------------------------------- //
        liquidityPoolInstance.updateBnftMode(false);

        liquidityPoolInstance.deposit{value: 30 ether}();
        numBnftsHeldByLP = 1;
        numTnftsHeldByLP = 1;
        numValidators_STAKE_DEPOSITED = 0;
        numValidators_WATING_FOR_APPROVAL = 0;
        tvl = numBnftsHeldByLP * 2 ether + numTnftsHeldByLP * 30 ether + address(liquidityPoolInstance).balance - numValidators_STAKE_DEPOSITED * 2 ether - numValidators_WATING_FOR_APPROVAL * 1 ether;
        assertEq(liquidityPoolInstance.getTotalPooledEther(), tvl);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 32 ether + 30 ether);
        assertEq(address(liquidityPoolInstance).balance, 30 ether);
        assertEq(address(stakingManagerInstance).balance, 0);

        // 
        // New Validator Deposit
        // 
        uint256[] memory newValidatorIds = auctionInstance.createBid{value: 0.4 ether}(1, 0.4 ether);
        liquidityPoolInstance.batchDepositAsBnftHolder{value: 2 ether}(newValidatorIds, 1, 0);

        numBnftsHeldByLP = 1;
        numTnftsHeldByLP = 1;
        numValidators_STAKE_DEPOSITED = 1;
        numValidators_WATING_FOR_APPROVAL = 0;
        tvl = numBnftsHeldByLP * 2 ether + numTnftsHeldByLP * 30 ether + address(liquidityPoolInstance).balance - numValidators_STAKE_DEPOSITED * 2 ether - numValidators_WATING_FOR_APPROVAL * 1 ether;
        assertEq(liquidityPoolInstance.getTotalPooledEther(), tvl);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 32 ether + 30 ether);
        assertEq(address(liquidityPoolInstance).balance, 32 ether);
        assertEq(address(stakingManagerInstance).balance, 0);

        // 
        // New Validator Register
        // 
        (IStakingManager.DepositData[] memory depositDataArray, bytes32[] memory depositDataRootsForApproval, bytes[] memory sig, bytes[] memory pubKey) = _prepareForValidatorRegistration(newValidatorIds);
        liquidityPoolInstance.batchRegisterAsBnftHolder(zeroRoot, newValidatorIds, depositDataArray, depositDataRootsForApproval, sig);

        numBnftsHeldByLP = 1;
        numTnftsHeldByLP = 1;
        numValidators_STAKE_DEPOSITED = 0;
        numValidators_WATING_FOR_APPROVAL = 1;
        tvl = numBnftsHeldByLP * 2 ether + numTnftsHeldByLP * 30 ether + address(liquidityPoolInstance).balance - numValidators_STAKE_DEPOSITED * 2 ether - numValidators_WATING_FOR_APPROVAL * 1 ether;
        assertEq(liquidityPoolInstance.getTotalPooledEther(), tvl);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 32 ether + 30 ether);
        assertEq(address(liquidityPoolInstance).balance, 31 ether);
        assertEq(address(stakingManagerInstance).balance, 0);

        // 
        // APPROVE
        // 
        liquidityPoolInstance.batchApproveRegistration(newValidatorIds, pubKey, sig);

        numBnftsHeldByLP = 1;
        numTnftsHeldByLP = 2;
        numValidators_STAKE_DEPOSITED = 0;
        numValidators_WATING_FOR_APPROVAL = 0;
        tvl = numBnftsHeldByLP * 2 ether + numTnftsHeldByLP * 30 ether + address(liquidityPoolInstance).balance - numValidators_STAKE_DEPOSITED * 2 ether - numValidators_WATING_FOR_APPROVAL * 1 ether;
        assertEq(liquidityPoolInstance.getTotalPooledEther(), tvl);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 32 ether + 30 ether);
        assertEq(address(liquidityPoolInstance).balance, 0);
        assertEq(address(stakingManagerInstance).balance, 0);


        // ---------------------------------------------------------- //
        // ---------------- BNFT to LP, TNFT to LP ------------------ //
        // ---------------------------------------------------------- //
        liquidityPoolInstance.updateBnftMode(true);

        liquidityPoolInstance.deposit{value: 32 ether}();
        numBnftsHeldByLP = 1;
        numTnftsHeldByLP = 2;
        numValidators_STAKE_DEPOSITED = 0;
        numValidators_WATING_FOR_APPROVAL = 0;
        tvl = numBnftsHeldByLP * 2 ether + numTnftsHeldByLP * 30 ether + address(liquidityPoolInstance).balance + numValidators_WATING_FOR_APPROVAL * 1 ether;
        assertEq(liquidityPoolInstance.getTotalPooledEther(), tvl);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 32 ether + 30 ether + 32 ether);
        assertEq(address(liquidityPoolInstance).balance, 32 ether);
        assertEq(address(stakingManagerInstance).balance, 0);

        // 
        // New Validator Deposit
        // 
        newValidatorIds = auctionInstance.createBid{value: 0.4 ether}(1, 0.4 ether);
        liquidityPoolInstance.batchDepositWithLiquidityPoolAsBnftHolder(newValidatorIds, 1, 0);

        numBnftsHeldByLP = 1;
        numTnftsHeldByLP = 2;
        numValidators_STAKE_DEPOSITED = 1;
        numValidators_WATING_FOR_APPROVAL = 0;
        tvl = numBnftsHeldByLP * 2 ether + numTnftsHeldByLP * 30 ether + address(liquidityPoolInstance).balance + numValidators_WATING_FOR_APPROVAL * 1 ether;
        assertEq(liquidityPoolInstance.getTotalPooledEther(), tvl);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 32 ether + 30 ether + 32 ether);
        assertEq(address(liquidityPoolInstance).balance, 32 ether);
        assertEq(address(stakingManagerInstance).balance, 0);

        // 
        // New Validator Register
        // 
        (depositDataArray, depositDataRootsForApproval, sig, pubKey) = _prepareForValidatorRegistration(newValidatorIds);
        liquidityPoolInstance.batchRegisterWithLiquidityPoolAsBnftHolder(zeroRoot, newValidatorIds, depositDataArray, depositDataRootsForApproval, sig);

        numBnftsHeldByLP = 1;
        numTnftsHeldByLP = 2;
        numValidators_STAKE_DEPOSITED = 0;
        numValidators_WATING_FOR_APPROVAL = 1;
        tvl = numBnftsHeldByLP * 2 ether + numTnftsHeldByLP * 30 ether + address(liquidityPoolInstance).balance + numValidators_WATING_FOR_APPROVAL * 1 ether;
        assertEq(liquidityPoolInstance.getTotalPooledEther(), tvl);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 32 ether + 30 ether + 32 ether);
        assertEq(address(liquidityPoolInstance).balance, 31 ether);
        assertEq(address(stakingManagerInstance).balance, 0);

        // 
        // APPROVE
        // 
        liquidityPoolInstance.batchApproveRegistration(newValidatorIds, pubKey, sig);

        numBnftsHeldByLP = 2;
        numTnftsHeldByLP = 3;
        numValidators_STAKE_DEPOSITED = 0;
        numValidators_WATING_FOR_APPROVAL = 0;
        tvl = numBnftsHeldByLP * 2 ether + numTnftsHeldByLP * 30 ether + address(liquidityPoolInstance).balance + numValidators_WATING_FOR_APPROVAL * 1 ether;
        assertEq(liquidityPoolInstance.getTotalPooledEther(), tvl);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 32 ether + 30 ether + 32 ether);
        assertEq(address(liquidityPoolInstance).balance, 0);
        assertEq(address(stakingManagerInstance).balance, 0);

        vm.stopPrank();
    }

    // Zelic audit - reward can be go wrong because it's using wrong numAssociatedValidators.
    function test_partialWithdrawWithMultipleValidators_WithIntermdiateValidators() public {
        uint256[] memory validatorIds = launch_validator(1, 0, false);
        uint256 validatorId = validatorIds[0];
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorId);

        assertTrue(managerInstance.phase(validatorIds[0]) == IEtherFiNode.VALIDATOR_PHASE.LIVE);
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 1);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 30 ether);

        // One validator of id `validatorId` with accrued rewards amount in the safe = 1 ether
        vm.deal(etherfiNode, 1 ether);

        // the accrued rewards (1 ether) are split as follows:
        (uint256 toOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury) = managerInstance.getRewardsPayouts(validatorId);
        assertEq(toOperator, 1 ether * 5 / (100));
        assertEq(toTnft, 1 ether * (90 * 29) / (100 * 32));
        assertEq(toBnft, 1 ether * (90 * 3) / (100 * 32));
        assertEq(toTreasury, 1 ether * 5 / (100));

        // TVL = accrued rewards amounts + beacon balance as principal
        // assuming the beacon balance is 32 ether
        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, 32 ether);
        assertEq(toOperator, 1 ether * 5 / 100);
        assertEq(toTnft, 30 ether + 1 ether * (90 * 29) / (100 * 32));
        assertEq(toBnft, 2 ether + 1 ether * (90 * 3) / (100 * 32));
        assertEq(toTreasury, 1 ether * 5 / 100);

        liquidityPoolInstance.deposit{value: 30 ether * 1}();
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 30 ether + 30 ether);

        vm.startPrank(alice);
        registerAsBnftHolder(alice);

        // 
        // New Validator Deposit into the same safe
        // 
        uint256[] memory newValidatorIds = auctionInstance.createBid{value: 0.4 ether}(1, 0.4 ether);
        liquidityPoolInstance.batchDepositAsBnftHolder{value: 2 ether}(newValidatorIds, 1, validatorId);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 30 ether + 30 ether);

        // Confirm that the num of associated validators still 1
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 1);

        // Confirm that the {getRewardsPayouts, calculateTVL} remain the smae
        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.getRewardsPayouts(validatorId);
        assertEq(toOperator, 1 ether * 5 / (100));
        assertEq(toTnft, 1 ether * (90 * 29) / (100 * 32));
        assertEq(toBnft, 1 ether * (90 * 3) / (100 * 32));
        assertEq(toTreasury, 1 ether * 5 / (100));

        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, 32 ether);
        assertEq(toOperator, 1 ether * 5 / 100);
        assertEq(toTnft, 30 ether + 1 ether * (90 * 29) / (100 * 32));
        assertEq(toBnft, 2 ether + 1 ether * (90 * 3) / (100 * 32));
        assertEq(toTreasury, 1 ether * 5 / 100);

        vm.expectRevert("NOT_LIVE");
        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.getRewardsPayouts(newValidatorIds[0]);

        vm.expectRevert("INVALID_PHASE");
        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(newValidatorIds[0], 32 ether);

        // 
        // New Validator Register into the same safe
        // 
        (IStakingManager.DepositData[] memory depositDataArray, bytes32[] memory depositDataRootsForApproval, bytes[] memory sig, bytes[] memory pubKey) = _prepareForValidatorRegistration(newValidatorIds);
        liquidityPoolInstance.batchRegisterAsBnftHolder(zeroRoot, newValidatorIds, depositDataArray, depositDataRootsForApproval, sig);

        // Confirm that the num of associated validators still 1
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 1);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 30 ether + 30 ether);

        // Confirm that the {getRewardsPayouts, calculateTVL} remain the smae
        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.getRewardsPayouts(validatorId);
        assertEq(toOperator, 1 ether * 5 / (100));
        assertEq(toTnft, 1 ether * (90 * 29) / (100 * 32));
        assertEq(toBnft, 1 ether * (90 * 3) / (100 * 32));
        assertEq(toTreasury, 1 ether * 5 / (100));

        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, 32 ether);
        assertEq(toOperator, 1 ether * 5 / 100);
        assertEq(toTnft, 30 ether + 1 ether * (90 * 29) / (100 * 32));
        assertEq(toBnft, 2 ether + 1 ether * (90 * 3) / (100 * 32));
        assertEq(toTreasury, 1 ether * 5 / 100);

        vm.expectRevert("NOT_LIVE");
        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.getRewardsPayouts(newValidatorIds[0]);

        vm.expectRevert("INVALID_PHASE");
        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(newValidatorIds[0], 32 ether);

        // 
        // APPROVE
        // 
        liquidityPoolInstance.batchApproveRegistration(newValidatorIds, pubKey, sig);

        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 2);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), 30 ether + 30 ether);

        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.getRewardsPayouts(validatorId);
        assertEq(toOperator, 1 ether * 5 / (2 * 100));
        assertEq(toTnft, 1 ether * (90 * 29) / (2 * 100 * 32));
        assertEq(toBnft, 1 ether * (90 * 3) / (2 * 100 * 32));
        assertEq(toTreasury, 1 ether * 5 / (2 * 100));

        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, 32 ether);
        assertEq(toOperator, 1 ether * 5 / (2 * 100));
        assertEq(toTnft, 30 ether + 1 ether * (90 * 29) / (2 * 100 * 32));
        assertEq(toBnft, 2 ether + 1 ether * (90 * 3) / (2 * 100 * 32));
        assertEq(toTreasury, 1 ether * 5 / (2 * 100));

        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.getRewardsPayouts(newValidatorIds[0]);
        assertEq(toOperator, 1 ether * 5 / (2 * 100));
        assertEq(toTnft, 1 ether * (90 * 29) / (2 * 100 * 32));
        assertEq(toBnft, 1 ether * (90 * 3) / (2 * 100 * 32));
        assertEq(toTreasury, 1 ether * 5 / (2 * 100));

        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(newValidatorIds[0], 32 ether);
        assertEq(toOperator, 1 ether * 5 / (2 * 100));
        assertEq(toTnft, 30 ether + 1 ether * (90 * 29) / (2 * 100 * 32));
        assertEq(toBnft, 2 ether + 1 ether * (90 * 3) / (2 * 100 * 32));
        assertEq(toTreasury, 1 ether * 5 / (2 * 100));

        vm.stopPrank();
    }

    function test_partialWithdrawWithMultipleValidators() public {
        uint256[] memory validatorIds = launch_validator(1, 0, false);
        uint256 validatorId = validatorIds[0];
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorId);

        assertTrue(managerInstance.phase(validatorIds[0]) == IEtherFiNode.VALIDATOR_PHASE.LIVE);
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 1);

        // Case 1: one validator of id `validatorId` with accrued rewards amount in the safe = 1 ether
        vm.deal(etherfiNode, 1 ether);

        // the accrued rewards (1 ether) are split as follows:
        (uint256 toOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury) = managerInstance.getRewardsPayouts(validatorId);
        assertEq(toOperator, 1 ether * 5 / (100));
        assertEq(toTnft, 1 ether * (90 * 29) / (100 * 32));
        assertEq(toBnft, 1 ether * (90 * 3) / (100 * 32));
        assertEq(toTreasury, 1 ether * 5 / (100));

        // TVL = accrued rewards amounts + beacon balance as principal
        // assuming the beacon balance is 32 ether
        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, 32 ether);
        assertEq(toOperator, 1 ether * 5 / 100);
        assertEq(toTnft, 30 ether + 1 ether * (90 * 29) / (100 * 32));
        assertEq(toBnft, 2 ether + 1 ether * (90 * 3) / (100 * 32));
        assertEq(toTreasury, 1 ether * 5 / 100);

        // Case 2: launch a new validator sharing the same safe, EtherFiNode, contract
        // so the safe is shared by the two validators
        // Note that the safe has the same total accrued rewards amount (= 1 ether)
        uint256[] memory newValidatorIds = launch_validator(1, validatorId, false);
        assertTrue(managerInstance.phase(validatorIds[0]) == IEtherFiNode.VALIDATOR_PHASE.LIVE);
        assertTrue(managerInstance.phase(newValidatorIds[0]) == IEtherFiNode.VALIDATOR_PHASE.LIVE);
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 2);
        assertEq(IEtherFiNode(etherfiNode).numExitedValidators(), 0);

        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.getRewardsPayouts(validatorId);
        assertEq(toOperator, 1 ether * 5 / (2 * 100));
        assertEq(toTnft, 1 ether * (90 * 29) / (2 * 100 * 32));
        assertEq(toBnft, 1 ether * (90 * 3) / (2 * 100 * 32));
        assertEq(toTreasury, 1 ether * 5 / (2 * 100));

        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.getRewardsPayouts(newValidatorIds[0]);
        assertEq(toOperator, 1 ether * 5 / (2 * 100));
        assertEq(toTnft, 1 ether * (90 * 29) / (2 * 100 * 32));
        assertEq(toBnft, 1 ether * (90 * 3) / (2 * 100 * 32));
        assertEq(toTreasury, 1 ether * 5 / (2 * 100));

        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, 32 ether);
        assertEq(toOperator, 1 ether * 5 / (2 * 100));
        assertEq(toTnft, 30 ether + 1 ether * (90 * 29) / (2 * 100 * 32));
        assertEq(toBnft, 2 ether + 1 ether * (90 * 3) / (2 * 100 * 32));
        assertEq(toTreasury, 1 ether * 5 / (2 * 100));

        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(newValidatorIds[0], 32 ether);
        assertEq(toOperator, 1 ether * 5 / (2 * 100));
        assertEq(toTnft, 30 ether + 1 ether * (90 * 29) / (2 * 100 * 32));
        assertEq(toBnft, 2 ether + 1 ether * (90 * 3) / (2 * 100 * 32));
        assertEq(toTreasury, 1 ether * 5 / (2 * 100));

        // What if one of the validators exits after getting slashed till 16 ether?
        // It exited & its principle is withdrawn
        _transferTo(etherfiNode, 16 ether);

        vm.expectRevert("MUST_EXIT");
        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.getRewardsPayouts(validatorIds[0]);
        vm.expectRevert("MUST_EXIT");
        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.getRewardsPayouts(newValidatorIds[0]);

        // Mark validatorIds[0] as EXITED
        vm.prank(alice);
        uint32[] memory exitTimestamps = new uint32[](1);
        exitTimestamps[0] = uint32(block.timestamp);
        managerInstance.processNodeExit(validatorIds, exitTimestamps);

        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 2);
        assertEq(IEtherFiNode(etherfiNode).numExitedValidators(), 1);

        // 16 ether was withdrawn from Beacon after the full slashing
        // 1 ether which were accrued rewards for both validators are used to cover the loss in `validatorId`
        // -> in total, the safe has 17 ether
        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, 0);
        assertEq(toOperator, 0 ether);
        assertEq(toTnft, 16 ether);
        assertEq(toBnft, 1 ether);
        assertEq(toTreasury, 0 ether);

        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(newValidatorIds[0], 32 ether);
        assertEq(toOperator, 0 ether);
        assertEq(toTnft, 30 ether);
        assertEq(toBnft, 2 ether);
        assertEq(toTreasury, 0 ether);

        vm.expectRevert("NOT_LIVE");
        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.getRewardsPayouts(validatorIds[0]);
        vm.expectRevert("NEED_FULL_WITHDRAWAL");
        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.getRewardsPayouts(newValidatorIds[0]);

        vm.expectRevert("NOT_EXITED");
        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.getFullWithdrawalPayouts(newValidatorIds[0]);
        vm.expectRevert("NOT_EXITED");
        managerInstance.batchFullWithdraw(newValidatorIds);

        managerInstance.batchFullWithdraw(validatorIds);

        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 1);

        // validatorIds[0] is gone, thus, calling its {calculateTVL, getRewardsPayouts} should fail
        vm.expectRevert();
        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorIds[0], 32 ether);
        vm.expectRevert();
        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.getRewardsPayouts(validatorIds[0]);

        // newValidatorIds[0] is still live
        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(newValidatorIds[0], 32 ether);
        assertEq(toOperator, 0);
        assertEq(toTnft, 30 ether);
        assertEq(toBnft, 2 ether);
        assertEq(toTreasury, 0);

        (toOperator, toTnft, toBnft, toTreasury) = managerInstance.getRewardsPayouts(newValidatorIds[0]);
        assertEq(toOperator, 0);
        assertEq(toTnft, 0);
        assertEq(toBnft, 0);
        assertEq(toTreasury, 0);
    }

    function _mainnet_369_verifyAndProcessWithdrawals(bool partialWithdrawal, bool fullWithdrawal) internal {
        uint256 validatorId = 369;
        address nodeAddress = managerInstance.etherfiNodeAddress(validatorId);
        IEigenPod eigenPod = IEigenPod(managerInstance.getEigenPod(validatorId));

        assertEq(eigenPod.withdrawableRestakedExecutionLayerGwei(), 0);
    
        // verifyAndProcessWithdrawals
        if (partialWithdrawal) {
            address(eigenPod).call{value: 0, gas:1_000_000}(hex"e251ef5200000000000000000000000000000000000000000000000000000000663a4e1f00000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000001800000000000000000000000000000000000000000000000000000000000000c8000000000000000000000000000000000000000000000000000000000000012a000000000000000000000000000000000000000000000000000000000000014008e405ed18605dbf438a1c0115d1a93b580ee4c942e2fc858ad34d3ba388d8b8600000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000060a2ad91774bccf4423b727a10983a04378d48f280e4217c7070b9523993fe7dca9ba15af405ee306ca32a4c14a1273df163e949a2a1f08a84d7c1566299987a9bbc5cf9c59bbd157bd7a24bc50c0d768b03c13135ac1a66536f959049155272ce00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000002e00000000000000000000000000000000000000000000000000000000000000360000000000000000000000000000000000000000000000000000000000000046000000000000000000000000000000000000000000000000000000000000005200000000000000000000000000000000000000000000000000000000000001ee8000000000000000000000000000000000000000000000000000000000000014a0000000000000000000000000000000000000000000000000000000000000003cc003aa3e58648d449af984b12c4b6de38bb4ee81226e8723838568d5c836e54e81e88000000000000000000000000000000000000000000000000000000000037a32766000000000000000000000000000000000000000000000000000000005b56176575dc15667e194cf6f1599bbad88920cc3d3b1705a332097fee2d6a7300000000000000000000000000000000000000000000000000000000000001406b1636db8408b53792ffcbec6a939d676a251c4460b40e7207abaaaafce49d109f9988088a5c04fb2f7246028a279031931b6d146eb83f3bf10258a4ede814ef269ef811551ebda0bafc785f05ff348c6659c2a3ada2be14195d4a11bf1f65d8bed0e770de8946c2182316aeaea88e5beb5f37fb8dcb73c2d6edbd014aa78ae410000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000fca1884a0e636a68b90cb425cc0ae5493378d8440714a375b238c9b6829c8034f5c265b1a8d6ddbfdf8194cb5016221f58d1508745501a87b38a7f26f18c2425302be53468d391fe41647064e0c42feaa9da337644b4f453b5181d88ec2e524e2a36e25ced18cdb69e1560a10f42aec4acd87e7661ff35501380e212b10e0e62000000000000000000000000000000000000000000000000000000000000006057740f000000000000000000000000000000000000000000000000000000000098247f9611876beb1c50172fe04b929f630929a3a2505c300b5308270bd2633eb088fed94ced6811e0b3005510e5716a3cb5f47ead00c6e1e7188b9f215c5ae100000000000000000000000000000000000000000000000000000000000000e07c672abcd627326ab27469aeeedf7f3e8555d2a441d26f4b47e5073bdf942ee7b46f0c01805fe212e15907981b757e6c496b0cb06664224655613dcec82505bbdb56114e00fdd4c1f85c892bf35ac9a89289aaecb1ebd0a96cde606a748b5d7180d856275a577499986e02fe5c5ec408467b8cfe8c516c16690d09442438d1110000000000000000000000000000000000000000000000000000000000000000f5a5fd42d16a20302798ef6ed309979b43003d2320d9f0e8ea9831a92759fb4b66e21951ffc563a13110d81c15d8de35c902069dc3f4c88c5dee9bc7a9344f5600000000000000000000000000000000000000000000000000000000000000a091da120100000000000000000000000000000000000000000000000000000000f765ee409227596ed00401db4253dd1d5743bab6897179f8674fc122166e87cb654e9b10b7bc1d94bfd5798b93c474342b9db20c6ac89f6ff2fcf61a97551fbf302be53468d391fe41647064e0c42feaa9da337644b4f453b5181d88ec2e524e2a36e25ced18cdb69e1560a10f42aec4acd87e7661ff35501380e212b10e0e620000000000000000000000000000000000000000000000000000000000000580cb2407d209fa474c16c43f1d270ddc493940f16a38c4e22d6aff4acf7fe1f5a6da3e83874cc698b20de0f69dbf968f7d311428c1f1aed27dd4da540f85a887ffbb2e6716d2b74c04a235e44404a65a7b874410c3c96c48f76331163e8c8a958be3f0f6d8c5f4d2fada206aa31ec732a528a973b084e27237ecc2a295572d3165db099c65a569940fcd85fa84263bd420161465c46eda435f7664c277799841f36e0810c823ef48aa94644831460140ebfcd3ca0808f2c84ae3dda7081b8e4d28be82c11bf888cdc1802d63f57600a2de146f01f27c06330981f68e62484274ca0a399fdbaf61f44c9930a63fc4860101de6c5d3b8d33720ad99b8b6661d47461e8d20440589af169db3ea8a7db8d8be6424bc5542c3b294fa7b1ad5cec25db48f510773bdba10f9625f9ed698cd947206934de80aa7a7347c342ecd8ffe566bd77a7dc6e3f299f679e082e95358c3446c156524aaeda5e5678b1b094cdc36205d4c23d65c99dec0d5a1b3fb632fa2b18f679912566087d79797a6095f666692d641021afc4676d3660ad3dc3e968de1b560beb4b1459f98caaf22f5347bc82c05045a5680a3a32a0b011780e4141e1b79f419c06785f9072b7e4294cd41603c4c4a3317ce1f96ef8d94fc8117137fc2e60bdf390d0e20706fff9a2528f444521e3f4993b7515e9948c579d2dc07fe18d46360ed484aa3fa132a892308d73c1108157f009fac8eb7825d1a7015beaf310feccc1a9bb5aa51615f2e5f70c815021ba90c1709dc89a3b4965a8e02bdb16cef4573bd2cdd5a7180ce5c5485083bea329f2d67a3c7ff0bdb031d7659e39167d723edd43aebb36e77116242dc0a341d89efde052aa15429fae05bad4d0b1d7c64da64d03d7a1854a588c2cb8430c0d30d5fb5effea691d833f3c53c00b390c08aaffa8294e48c7790f4d4ab18c4d943087eb0ddba57e35f6d286673802a4af5975e22506c7cf4c64bb6be5ee11527f2c460485af574848585860d57ea2bd50835e0b5a2a296e0dcb014483c82debb54f506d86582d252405b840018792cad2bf1259f1ef5aa5f887e13cb2f0094f51e1ffff0ad7e659772f9534c195c815efc4014ef1e1daed4404c06385d11192e92b6cf04127db05441cd833107a52be852868890e4317e6a02ab47683aa75964220b7d05f875f140027ef5118a2247bbb84ce8f2f0f1123623085daf7960c329f5fdf6af5f5bbdb6be9ef8aa618e4bf8073960867171e29676f8b284dea6a08a85eb58d900f5e182e3c50ef74969ea16c7726c549757cc23523c369587da7293784d49a7502ffcfb0340b1d7885688500ca308161a7f96b62df9d083b71fcc8f2bb8fe6b1689256c0d385f42f5bbe2027a22c1996e110ba97c171d3e5948de92beb8d0d63c39ebade8509e0ae3c9c3876fb5fa112be18f905ecacfecb92057603ab95eec8b2e541cad4e91de38385f2e046619f54496c2382cb6cacd5b98c26f5a4f893e908917775b62bff23294dbbe3a1cd8e6cc1c35b4801887b646a6f81f17fcddba7b592e3133393c16194fac7431abf2f5485ed711db282183c819e08ebaa8a8d7fe3af8caa085a7639a832001457dfb9128a8061142ad0335629ff23ff9cfeb3c337d7a51a6fbf00b9e34c52e1c9195c969bd4e7a0bfd51d5c5bed9c1167e71f0aa83cc32edfbefa9f4d3e0174ca85182eec9f3a09f6a6c0df6377a510d75701000000000000000000000000000000000000000000000000000000000000acd708000000000000000000000000000000000000000000000000000000000084ceaa4dde66e23c4e4c32636f7c2b0298bb449c4db731b90e5a39b4b264936bdb56114e00fdd4c1f85c892bf35ac9a89289aaecb1ebd0a96cde606a748b5d719c5ebbb28e654845862cc16e46b200feecac45488e12f0d39cbac3b14b6608d2db82f769a33f407aa641459e217f4e1ec7ad7412d75092e1ca9243e1f0d976e10000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000005c045f8cf05beedeb84fcae091fcb2ee47004764d17f457990ae3896426107c7a3732b1992669e48276043927cf519ff38fc16607f58ad93459c4495f32899fea09472a67b3cad7814ea1c0c18d43bb75140be02840bfd89cd46aa112fecd74dd904eff388ad7b3fa8679413441b329d86682937c3769b9af03307d150912dd4cf967ebb5be4d7d11360483dbea5eb821ef42d625ef387fcf8eeef520a4941520bcd88969552805e6b880a95b8e51ebd43b5a0326a59d6234f884d6301e48007c23ab68ce7484c4eaa534b4a7e4ca941981911623be2e822bd4263b78f57fb13e8256fc4b4f33ce0b8a1d67d911d3b288a3f7bd83dba6a94732bbe91743e996ebe845609139d009d32bfacee0d976cb7764418115a056b1d6c960559e3ae81fb2ca124adeceb195bb9ddcace33bf9389857a49434ad906678722485a99b9e0d32a5d878c5edcf3de0d11c8801ec3922b84dd12f67ae0593a38c8301d033a5607ed890abff4d542f85ef28766754556da1ee16ee0a62975669ab998be62bda776ab8db898c4521a6b44b9a64b496324ae7891f4c093abea717debc156234668ae447aeac7009b41efa940362cbbecc5e5f96b7b54a1b5ad4f7c05474c193ba71d29439a821fb189ff9073fab3fadf25340b4e0d0b2ecca2119872ab94390f9697c84d73e0f8e59f5a87b9938ba93ab27ad6b054fb2fd353065ccc6322033f08a267a085ed31c844b806f4fcf2e2e5525ca19d95f9fe06fba90b08f20ce7cca8875268e15d87243d2608a90d2f409097f373ddfe878c15a593a9f2391162c38c39f99fce4a47409cf806957e75da4a22a6b45bacafa85dfab4af7b43c758ca12509c2f893e908917775b62bff23294dbbe3a1cd8e6cc1c35b4801887b646a6f81f17fd3019e322e1007c697bc17c90409600efa985e2cb7746180afbcb40e100505718a8d7fe3af8caa085a7639a832001457dfb9128a8061142ad0335629ff23ff9cfeb3c337d7a51a6fbf00b9e34c52e1c9195c969bd4e7a0bfd51d5c5bed9c1167e71f0aa83cc32edfbefa9f4d3e0174ca85182eec9f3a09f6a6c0df6377a510d731206fa80a50bb6abe29085058f16212212a60eec8f049fecb92d8c8e0a84bc021352bfecbeddde993839f614c3dac0a3ee37543f9b412b16199dc158e23b544619e312724bb6d7c3153ed9de791d764a366b389af13c58bf8a8d90481a467657cdd2986268250628d0c10e385c58c6191e6fbe05191bcc04f133f2cea72c1c4848930bd7ba8cac54661072113fb278869e07bb8587f91392933374d017bcbe18869ff2c22b28cc10510d9853292803328be4fb0e80495e8bb8d271f5b889636b5fe28e79f1b850f8658246ce9b6a1e7b49fc06db7143e8fe0b4f2b0c5523a5c985e929f70af28d0bdd1a90a808f977f597c7c778c489e98d3bd8910d31ac0f7c6f67e02e6e4e1bdefb994c6098953f34636ba2b6ca20a4721d2b26a886722ff1c9a7e5ff1cf48b4ad1582d3f4e4a1004f3b20d8c5a2b71387a4254ad933ebc52f075ae229646b6f6aed19a5e372cf295081401eb893ff599b3f9acc0c0d3e7d328921deb59612076801e8cd61592107b5c67c79b846595cc6320c395b46362cbfb909fdb236ad2411b4e4883810a074b840464689986c3f8a8091827e17c32755d8fb3687ba3ba49f342c77f5a1f89bec83d811446e1a467139213d640b6a74f7210d4f8e7e1039790e7bf4efa207555a10a6db1dd4b95da313aaa88b88fe76ad21b516cbc645ffe34ab5de1c8aef8cd4e7f8d2b51e8e1456adc7563cda206f4029150000000000000000000000000000000000000000000000000000000000d45b16000000000000000000000000000000000000000000000000000000000022510254e4f4544672d0eb19657a0be79a48c7cf5c472e13e3e277cfd44045137deb13b2d15e74fda4e56936c38b7cbf6eb1c20603e4ae799e763e41417095723eacadb74fb7a6f608f74e3650bcc308a325e6618e2ee58ec8463f404764d23a9feb2b5083e4002918f7db0955d1aa1f506f75f5fd24430fe4984a56f2b8d1e40000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000089c37f28ca0901d81d9af4258607e2c0959e5c0e908470dac8c5027cd967f0ad2010000000000000000000000afd81a1f8062a383f9d5e067af3a6eb5f517102400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e2c3030000000000000000000000000000000000000000000000000000000000f3c30300000000000000000000000000000000000000000000000000000000007e460400000000000000000000000000000000000000000000000000000000007e47040000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000004ae078f0200000000000000000000000000000000000000000000000000000000930f100000000000000000000000000000000000000000000000000000000000afd81a1f8062a383f9d5e067af3a6eb5f51710240000000000000000000000001543180100000000000000000000000000000000000000000000000000000000");
        }
        if (fullWithdrawal) {
            address(eigenPod).call{value: 0, gas:1_000_000}(hex"e251ef52000000000000000000000000000000000000000000000000000000006638fa3b00000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000001800000000000000000000000000000000000000000000000000000000000000c8000000000000000000000000000000000000000000000000000000000000012a00000000000000000000000000000000000000000000000000000000000001400198834354f1ac0ae8a3ec4011b706e7a92e948d256a856a9a3e5e2e93b402a6700000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000060ebbfe960bd141e77f95b0dd1951955996425cf85ce29076159ad3f47f92ca916c96893dc0d8b73a12310ced273450fbedc2e6c6cf2d620bd46685e3869143042a78115593b93f98909f98c3068e1cf7639232052413970cf1c8017bafc00e30e00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000002e000000000000000000000000000000000000000000000000000000000000003600000000000000000000000000000000000000000000000000000000000000460000000000000000000000000000000000000000000000000000000000000052000000000000000000000000000000000000000000000000000000000000010d500000000000000000000000000000000000000000000000000000000000001520000000000000000000000000000000000000000000000000000000000000008172978eb77844db83a9ef01dcbfbe0b7c7ad11056759193e8d3958d70f7785e4d51089000000000000000000000000000000000000000000000000000000000053fa3266000000000000000000000000000000000000000000000000000000000d9c14261ee928c31797186c89a831477580f0d3bc6098e4f9350bfecf7faa150000000000000000000000000000000000000000000000000000000000000140cf0b5956fe1d61b770a8de6fffd31b9c3f8fc775bc3901beb3039480f3786e57cfb96e0f7cde640f7ba9d33824f3be1975608519d2d2c90334ec06a0ff94c78420613ded12606d94c0db03794b3faea365c887903fbd0bb00aeba3e61799d83b5a4dea179c54ee96af9fccf0eafe1dc916a784e5c99c79c82f6e0ace928e694510000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d06a859dcd26f8e77721786d904cac9467441b60014adebfd1c53a36475e08d486ef1de76000fd36f915a0349cd8a763eab2e30b118355f7d29f9a9153cfb3ac599e350eee2a8c703de1e86b09d872c48d797662ce7d7985cb027c14775b9cde536d98837f2dd165a55d5eeae91485954472d56f246df256bf3cae19352a123c00000000000000000000000000000000000000000000000000000000000000607974100000000000000000000000000000000000000000000000000000000000c1351b147c463120ebcb0ad88eeb7a419e4bc3d7c028470bd5100cfff242761feacdf609c77f95b539ac5460b188d1c6d95149ea9b6ea74453f672e0dca1f8ca00000000000000000000000000000000000000000000000000000000000000e04770848f71241cb0132ae23a72dcea11cb58a2ab6506d12dc697701beb5ad53ab46f0c01805fe212e15907981b757e6c496b0cb06664224655613dcec82505bbdb56114e00fdd4c1f85c892bf35ac9a89289aaecb1ebd0a96cde606a748b5d717e466931f54f3a09f6ccc9560d49542e6d4ed92c252fb90e9198abed364857830000000000000000000000000000000000000000000000000000000000000000f5a5fd42d16a20302798ef6ed309979b43003d2320d9f0e8ea9831a92759fb4b1c163e09fade42b03be003c55e37415cb3d10d5c1da601b3c62ccf149cb610a400000000000000000000000000000000000000000000000000000000000000a0f1c4da000000000000000000000000000000000000000000000000000000000015ba0de266825f5463fab0eca873bf9973a8eec557faa7a1bff9d4a7c68ca5baaf85706b6aae3e00b9737d6cf05fd942f1a1e3ac4469c8bede52be92b4259a41599e350eee2a8c703de1e86b09d872c48d797662ce7d7985cb027c14775b9cde536d98837f2dd165a55d5eeae91485954472d56f246df256bf3cae19352a123c0000000000000000000000000000000000000000000000000000000000000580ccc56b18a55d998d7ab9b382ae063c915cd760d4e15b3adf43a6c409b70f2fd00abdb98c72a995f612149a87870c3ecf36750de9cd77d6c64b56e646846beb992fadd6eeaa6da03aeb4d9e51d293dcf4e18c4c964ae8d94ae66bcd7de70d33440ec142a21e471ccdec4880d59364999c157d803051863f9d4f66383898aa5a98c6f7c620b5ca9119a62f386d033fefa5b71e133146305c84bc1598a473d5da45e4f0286f5eaae92452191fd475ce6436bff1a8be5e48080d2fe01bc732929694f2d7d99760ac1b4c7b66c78bdcf8694e67f2473809057b02db03f6843c4c3eb9381fdc6d61d8039ee2a58c54da54d7194a5945fe8b4784d83a3d911deebf8d43b348e74b019611b93602acfc7950a47e73eded3e7917d5aebfd4a500fbe93b3aa2c093aa38d591b490461426b9e38c840957fb285149b789e0b8cbcc34bd9fe9217b0db835e8767d87b41c99fc4453d7f927b3a77193ba6c5b908ac7a38c7d6fb023133925aec522a3b82385be2e96b57a2bd82a7d4a02f94b420e5b0160ce1f122950d23a65b16be7db5e79cca1788918979d724db7b1cd9c4098a52d532db3a35e638be25190d875880a5738069b223c8bc6820cf3a380bd35c9a6371ca0de52038cdd03b6f3252a5765baefe6a1420824d0e4e3e386706fb029a7bf1308711c9760f6e42caabff33a492674530611e489b57791ffc687e5cda81d239226feed47d70c7cae3b1358a0ebfd75f87172e9e6167b2ce9ed2ae6d050d9bd9e0169c78009fdf07fc56a11f122370658a353aaa542ed63e44c4bc15ff4cd105ab33c4798d0e92891c6bff8e0828a487fb7668a6ad8649993fa1e6f9f09d496f6d2329efde052aa15429fae05bad4d0b1d7c64da64d03d7a1854a588c2cb8430c0d30d5fb5effea691d833f3c53c00b390c08aaffa8294e48c7790f4d4ab18c4d943087eb0ddba57e35f6d286673802a4af5975e22506c7cf4c64bb6be5ee11527f2c460485af574848585860d57ea2bd50835e0b5a2a296e0dcb014483c82debb54f506d86582d252405b840018792cad2bf1259f1ef5aa5f887e13cb2f0094f51e1ffff0ad7e659772f9534c195c815efc4014ef1e1daed4404c06385d11192e92b6cf04127db05441cd833107a52be852868890e4317e6a02ab47683aa75964220b7d05f875f140027ef5118a2247bbb84ce8f2f0f1123623085daf7960c329f5fdf6af5f5bbdb6be9ef8aa618e4bf8073960867171e29676f8b284dea6a08a85eb58d900f5e182e3c50ef74969ea16c7726c549757cc23523c369587da7293784d49a7502ffcfb0340b1d7885688500ca308161a7f96b62df9d083b71fcc8f2bb8fe6b1689256c0d385f42f5bbe2027a22c1996e110ba97c171d3e5948de92beb8d0d63c39ebade8509e0ae3c9c3876fb5fa112be18f905ecacfecb92057603ab95eec8b2e541cad4e91de38385f2e046619f54496c2382cb6cacd5b98c26f5a4f893e908917775b62bff23294dbbe3a1cd8e6cc1c35b4801887b646a6f81f17fcddba7b592e3133393c16194fac7431abf2f5485ed711db282183c819e08ebaa8a8d7fe3af8caa085a7639a832001457dfb9128a8061142ad0335629ff23ff9cfeb3c337d7a51a6fbf00b9e34c52e1c9195c969bd4e7a0bfd51d5c5bed9c1167e71f0aa83cc32edfbefa9f4d3e0174ca85182eec9f3a09f6a6c0df6377a510d756010000000000000000000000000000000000000000000000000000000000003c3a060000000000000000000000000000000000000000000000000000000000e97c869919e7a3846613f4bf3f72a86df0af9f9faabddb35008a266c54f74022db56114e00fdd4c1f85c892bf35ac9a89289aaecb1ebd0a96cde606a748b5d71436c8971f0963e274db592074eef4608740fc2360665e961c7839a847d24ddd9771133e804d0a5ceaf4ced110260eb4941823d137d7d90d2ecc5e0bc48828f020000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000005c045f8cf05beedeb84fcae091fcb2ee47004764d17f457990ae3896426107c7a3732b1992669e48276043927cf519ff38fc16607f58ad93459c4495f32899fea09472a67b3cad7814ea1c0c18d43bb75140be02840bfd89cd46aa112fecd74dd904eff388ad7b3fa8679413441b329d86682937c3769b9af03307d150912dd4cf967ebb5be4d7d11360483dbea5eb821ef42d625ef387fcf8eeef520a4941520bcd88969552805e6b880a95b8e51ebd43b5a0326a59d6234f884d6301e48007c23ab68ce7484c4eaa534b4a7e4ca941981911623be2e822bd4263b78f57fb13e8256fc4b4f33ce0b8a1d67d911d3b288a3f7bd83dba6a94732bbe91743e996ebe845609139d009d32bfacee0d976cb7764418115a056b1d6c960559e3ae81fb2ca124adeceb195bb9ddcace33bf9389857a49434ad906678722485a99b9e0d32a5d878c5edcf3de0d11c8801ec3922b84dd12f67ae0593a38c8301d033a5607ed890abff4d542f85ef28766754556da1ee16ee0a62975669ab998be62bda776ab8a537662433c44d2740e3c87e02304cd4a0554ad89ed03267b8b0106f04474dc13e22deead7ee01a015cf87c3a1c64e03d4d30e8e3ea2f0e41440402e3f12b0e539a821fb189ff9073fab3fadf25340b4e0d0b2ecca2119872ab94390f9697c846c02f5bcbc84ea5361fa90162f418ba33b1de0e010bfc33e1cf68eb3ab493399dae9312d93b698d08a504776d3e30937419f14d7fc50b0cf25b6076c6f29d838783e078f41855d97fa5f8ddafd16c71291a654d79b03d5b87e20cc6f17f522377a8b66f7436c8e7d8644a2bc37cd0445239bd4996de321d4b81b335286380fdef893e908917775b62bff23294dbbe3a1cd8e6cc1c35b4801887b646a6f81f17f4704e8367b63754276b4d91c5bcc943f1388380f743c7554c1ed3083d73c7bd68a8d7fe3af8caa085a7639a832001457dfb9128a8061142ad0335629ff23ff9cfeb3c337d7a51a6fbf00b9e34c52e1c9195c969bd4e7a0bfd51d5c5bed9c1167e71f0aa83cc32edfbefa9f4d3e0174ca85182eec9f3a09f6a6c0df6377a510d731206fa80a50bb6abe29085058f16212212a60eec8f049fecb92d8c8e0a84bc021352bfecbeddde993839f614c3dac0a3ee37543f9b412b16199dc158e23b544619e312724bb6d7c3153ed9de791d764a366b389af13c58bf8a8d90481a467657cdd2986268250628d0c10e385c58c6191e6fbe05191bcc04f133f2cea72c1c4848930bd7ba8cac54661072113fb278869e07bb8587f91392933374d017bcbe18869ff2c22b28cc10510d9853292803328be4fb0e80495e8bb8d271f5b889636b5fe28e79f1b850f8658246ce9b6a1e7b49fc06db7143e8fe0b4f2b0c5523a5c985e929f70af28d0bdd1a90a808f977f597c7c778c489e98d3bd8910d31ac0f7c6f67e02e6e4e1bdefb994c6098953f34636ba2b6ca20a4721d2b26a886722ff1c9a7e5ff1cf48b4ad1582d3f4e4a1004f3b20d8c5a2b71387a4254ad933ebc52f075ae229646b6f6aed19a5e372cf295081401eb893ff599b3f9acc0c0d3e7d328921deb59612076801e8cd61592107b5c67c79b846595cc6320c395b46362cbfb909fdb236ad2411b4e4883810a074b840464689986c3f8a8091827e17c32755d8fb3687ba3ba49f342c77f5a1f89bec83d811446e1a467139213d640b6a74f7210d4f8e7e1039790e7bf4efa207555a10a6db1dd4b95da313aaa88b88fe76ad21b516cbc645ffe34ab5de1c8aef8cd4e7f8d2b51e8e1456adc7563cda206fab261500000000000000000000000000000000000000000000000000000000003459160000000000000000000000000000000000000000000000000000000000cf134aae33d75aa66ba5a51906b0adfbaeeae302d3c82a20ce1dee250616d9b6e3b20a20d924029ce9cc5677310c9965596487bda5f842ab4625a0fff41aefa0e8381811d500984752da2fc221daa869d370eda79e41f5b15e1bf5a9d58e0a8aef897b9fbedb7d8d522483a67ee115d67cba2363f207742491dfbbebdbad36740000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000089c37f28ca0901d81d9af4258607e2c0959e5c0e908470dac8c5027cd967f0ad2010000000000000000000000afd81a1f8062a383f9d5e067af3a6eb5f517102400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e2c3030000000000000000000000000000000000000000000000000000000000f3c30300000000000000000000000000000000000000000000000000000000007e460400000000000000000000000000000000000000000000000000000000007e47040000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000004230b9e0200000000000000000000000000000000000000000000000000000000930f100000000000000000000000000000000000000000000000000000000000afd81a1f8062a383f9d5e067af3a6eb5f51710240000000000000000000000004091267407000000000000000000000000000000000000000000000000000000");
            assertEq(eigenPod.withdrawableRestakedExecutionLayerGwei(), 32 ether / 1 gwei);
        }
    }

    function test_mainnet_369_verifyAndProcessWithdrawals() public {
        initializeRealisticFork(MAINNET_FORK);
        _upgrade_etherfi_node_contract();   
        _upgrade_etherfi_nodes_manager_contract(); 

        _mainnet_369_add_validator();

        _mainnet_369_verifyAndProcessWithdrawals(false, true);
    }

    function test_mainnet_369_processNodeExit_without_withdrawal_proved() public {
        initializeRealisticFork(MAINNET_FORK);
        _upgrade_etherfi_node_contract();    
        _upgrade_etherfi_nodes_manager_contract(); 

        uint256 validatorId = 369;
        address nodeAddress = managerInstance.etherfiNodeAddress(validatorId);
        IEigenPod eigenPod = IEigenPod(managerInstance.getEigenPod(validatorId));
        IDelegationManager mgr = managerInstance.delegationManager();
        IEigenPodManager eigenPodManager = managerInstance.eigenPodManager();

        //  call `ProcessNodeExit` to initiate the queued withdrawal
        uint256[] memory validatorIds = new uint256[](1);
        uint32[] memory exitTimestamps = new uint32[](1);
        validatorIds[0] = validatorId;
        exitTimestamps[0] = uint32(block.timestamp);
        
        hoax(managerInstance.owner());
        vm.expectRevert("NO_FULLWITHDRAWAL_QUEUED");
        managerInstance.processNodeExit(validatorIds, exitTimestamps);
    }

    function test_mainnet_369_queueWithdrawals_by_rando_fails() public {
        initializeRealisticFork(MAINNET_FORK);
        _upgrade_etherfi_node_contract();   
        _upgrade_etherfi_nodes_manager_contract(); 

        _mainnet_369_verifyAndProcessWithdrawals(true, true);

        uint256 validatorId = 369;
        address nodeAddress = managerInstance.etherfiNodeAddress(validatorId);
        IEigenPod eigenPod = IEigenPod(managerInstance.getEigenPod(validatorId));
        IDelegationManager mgr = managerInstance.delegationManager();
        IEigenPodManager eigenPodManager = managerInstance.eigenPodManager();

        IDelegationManager.QueuedWithdrawalParams[] memory params = new IDelegationManager.QueuedWithdrawalParams[](1);
        IStrategy[] memory strategies = new IStrategy[](1);
        uint256[] memory shares = new uint256[](1);

        strategies[0] = mgr.beaconChainETHStrategy();
        shares[0] = uint256(eigenPod.withdrawableRestakedExecutionLayerGwei()) * uint256(1 gwei);
        params[0] = IDelegationManager.QueuedWithdrawalParams({
            strategies: strategies,
            shares: shares,
            withdrawer: nodeAddress
        });

        // Caller != withdrawer
        vm.expectRevert("DelegationManager.queueWithdrawal: withdrawer must be staker");
        vm.prank(alice);
        mgr.queueWithdrawals(params);
    }

    function test_mainnet_369_processNodeExit_success() public returns (IDelegationManager.Withdrawal memory) {
        // test_mainnet_369_verifyAndProcessWithdrawals();  
        initializeRealisticFork(MAINNET_FORK);

        vm.warp(block.timestamp + 7 * 24 * 3600);

        uint256 validatorId = 338;
        address nodeAddress = managerInstance.etherfiNodeAddress(validatorId);
        IEigenPod eigenPod = IEigenPod(managerInstance.getEigenPod(validatorId));
        IDelegationManager mgr = managerInstance.delegationManager();
        IEigenPodManager eigenPodManager = managerInstance.eigenPodManager();

        // Calculate TVL does not work once the eigenPod's balance goes above 16 ether since we cannot tell if it is the reward or exited fund
        // ether.fi will perform `verifyAndProcessWithdrawals` and `processNodeExit` to mark the validator as exited
        // Then, it will call `calculateTVL` to get the correct TVL
        vm.expectRevert();
        managerInstance.calculateTVL(validatorId, 0 ether);

        IDelegationManager.Withdrawal memory withdrawal;
        IERC20[] memory tokens = new IERC20[](1);
        {
            IStrategy[] memory strategies = new IStrategy[](1);
            strategies[0] = mgr.beaconChainETHStrategy();
            uint256[] memory shares = new uint256[](1);
            shares[0] = uint256(eigenPod.withdrawableRestakedExecutionLayerGwei()) * 1 gwei;
            withdrawal = IDelegationManager.Withdrawal({
                staker: nodeAddress,
                delegatedTo: mgr.delegatedTo(nodeAddress),
                withdrawer: nodeAddress,
                nonce: mgr.cumulativeWithdrawalsQueued(nodeAddress),
                startBlock: uint32(block.number),
                strategies: strategies,
                shares: shares
            });      

            bytes32 withdrawalRoot = mgr.calculateWithdrawalRoot(withdrawal);
        }

        // 2. call `ProcessNodeExit` to initiate the queued withdrawal
        uint256[] memory validatorIds = new uint256[](1);
        {
            uint32[] memory exitTimestamps = new uint32[](1);
            validatorIds[0] = validatorId;
            exitTimestamps[0] = uint32(block.timestamp);
            
            hoax(managerInstance.owner());
            managerInstance.processNodeExit(validatorIds, exitTimestamps);
            // It calls `DelegationManager::undelegate` which emits the event `WithdrawalQueued`
        }

        // 'calculateTVL' now works
        managerInstance.calculateTVL(validatorId, 0 ether);

        // it reamins the same even after queueing the withdrawal until it is claimed
        assertEq(eigenPod.withdrawableRestakedExecutionLayerGwei(), 32 ether / 1 gwei);

        return withdrawal;
    }

    function test_mainnet_369_completeQueuedWithdrawal() public {
        IDelegationManager.Withdrawal memory withdrawal = test_mainnet_369_processNodeExit_success();

        uint256 validatorId = 369;
        address nodeAddress = managerInstance.etherfiNodeAddress(validatorId);
        IEigenPod eigenPod = IEigenPod(managerInstance.getEigenPod(validatorId));
        IDelegationManager mgr = managerInstance.delegationManager();
        IEigenPodManager eigenPodManager = managerInstance.eigenPodManager();
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = validatorId;

        // mgr.completeQueuedWithdrawal(withdrawal, tokens, 0, true);
        IDelegationManager.Withdrawal[] memory withdrawals = new IDelegationManager.Withdrawal[](1);
        uint256[] memory middlewareTimesIndexes = new uint256[](1);
        withdrawals[0] = withdrawal;
        middlewareTimesIndexes[0] = 0;
        
        IERC20[] memory tokens = new IERC20[](1);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(IDelegationManager.completeQueuedWithdrawal.selector, withdrawal, tokens, 0, true);

        // FAIL, the forward call is not allowed for `completeQueuedWithdrawal`
        vm.expectRevert("NOT_ALLOWED");
        vm.prank(owner);
        managerInstance.forwardExternalCall(validatorIds, data, address(managerInstance.delegationManager()));

        // FAIL, if the `minWithdrawalDelayBlocks` is not passed
        vm.prank(owner);
        vm.expectRevert("DelegationManager._completeQueuedWithdrawal: minWithdrawalDelayBlocks period has not yet passed");
        managerInstance.completeQueuedWithdrawals(validatorIds, withdrawals, middlewareTimesIndexes, true);

        // 1. Wait
        // Wait 'minDelayBlock' after the `verifyAndProcessWithdrawals`
        {
            uint256 minDelayBlock = Math.max(mgr.minWithdrawalDelayBlocks(), mgr.strategyWithdrawalDelayBlocks(mgr.beaconChainETHStrategy()));
            vm.roll(block.number + minDelayBlock);
        }

        // 2. DelegationManager.completeQueuedWithdrawal
        uint256 prevEtherFiNodeAddress = address(nodeAddress).balance;
        managerInstance.completeQueuedWithdrawals(validatorIds, withdrawals, middlewareTimesIndexes, true);

        assertEq(address(nodeAddress).balance, prevEtherFiNodeAddress + 32 ether);
        assertEq(eigenPodManager.podOwnerShares(nodeAddress), 0);
        assertEq(eigenPod.withdrawableRestakedExecutionLayerGwei(), 0);
    }

    function test_mainnet_369_fullWithdraw_success() public {
        test_mainnet_369_completeQueuedWithdrawal();

        uint256 validatorId = 369;
        address nodeAddress = managerInstance.etherfiNodeAddress(validatorId);

        assertEq(IEtherFiNode(nodeAddress).associatedValidatorIds(IEtherFiNode(nodeAddress).associatedValidatorIndices(validatorId)), validatorId);

        managerInstance.fullWithdraw(validatorId);

        assertNotEq(IEtherFiNode(nodeAddress).associatedValidatorIds(IEtherFiNode(nodeAddress).associatedValidatorIndices(validatorId)), validatorId);
    }

    function test_mainnet_369_fullWithdraw_without_completeQueuedWithdrawal() public {
        IDelegationManager.Withdrawal memory withdrawal = test_mainnet_369_processNodeExit_success();

        uint256 validatorId = 369;
        address nodeAddress = managerInstance.etherfiNodeAddress(validatorId);

        vm.deal(nodeAddress, 32 ether);

        // Say the withdrawal safe (etherfi node contract) got >32 ether
        // but that is not from the withdrawal, then it is not counted as the withdrawan principal
        vm.expectRevert("INSUFFICIENT_BALANCE");
        managerInstance.fullWithdraw(validatorId);
    }

    function _mainnet_369_add_validator() public {
        uint256 validatorId = 369;
        address nodeAddress = managerInstance.etherfiNodeAddress(validatorId);
        IEigenPod eigenPod = IEigenPod(managerInstance.getEigenPod(validatorId));
        IDelegationManager mgr = managerInstance.delegationManager();
        IEigenPodManager eigenPodManager = managerInstance.eigenPodManager();

        assertEq(IEtherFiNode(nodeAddress).numAssociatedValidators(), 1);

        // validator 369 is with isLpBnftHolder = false
        vm.prank(owner);
        liquidityPoolInstance.updateBnftMode(false);

        uint256 newValidatorId = _add_validator_to_safe(validatorId);

        vm.prank(owner);
        liquidityPoolInstance.updateBnftMode(true);

        assertEq(IEtherFiNode(nodeAddress).numAssociatedValidators(), 1); // the new validator is registered but not approved yet
    }

    function _add_validator_to_safe(uint256 validatorIdToShareSafeWith) internal returns (uint256) {
        address operator = auctionInstance.getBidOwner(validatorIdToShareSafeWith);
        vm.deal(operator, 100 ether);
        vm.startPrank(operator);
        uint256[] memory bidIds = auctionInstance.createBid{value: 0.1 ether * 1}(1, 0.1 ether);
        vm.stopPrank();
        
        address bnftStaker = BNFTInstance.ownerOf(validatorIdToShareSafeWith);
        uint256 lp_balance = address(liquidityPoolInstance).balance;
        vm.startPrank(bnftStaker);
        vm.deal(bnftStaker, 2 ether);
        uint256[] memory newValidatorIds = liquidityPoolInstance.batchDepositAsBnftHolder{value: 2 ether}(bidIds, 1, validatorIdToShareSafeWith);
        (IStakingManager.DepositData[] memory depositDataArray, bytes32[] memory depositDataRootsForApproval, bytes[] memory sig, bytes[] memory pubKey) = _prepareForValidatorRegistration(newValidatorIds);
        liquidityPoolInstance.batchRegisterAsBnftHolder(zeroRoot, newValidatorIds, depositDataArray, depositDataRootsForApproval, sig);
        vm.stopPrank();

        assertEq(uint8(managerInstance.phase(newValidatorIds[0])), uint8(IEtherFiNode.VALIDATOR_PHASE.WAITING_FOR_APPROVAL));
    }

    function test_mainnet_launch_validator_with_reserved_version1_safe() public {
        initializeRealisticFork(MAINNET_FORK);
        _upgrade_etherfi_node_contract();   
        _upgrade_etherfi_nodes_manager_contract(); 

        address etherFiNode = managerInstance.unusedWithdrawalSafes(managerInstance.getUnusedWithdrawalSafesLength() - 1);

        assertEq(IEtherFiNode(etherFiNode).version(), 1);
        assertEq(IEtherFiNode(etherFiNode).numAssociatedValidators(), 0);

        uint256[] memory newValidatorIds = launch_validator(1, 0, false);
        address newEtherFiNode = managerInstance.etherfiNodeAddress(newValidatorIds[0]);

        assertEq(etherFiNode, newEtherFiNode);
        assertEq(IEtherFiNode(newEtherFiNode).version(), 1);
        assertEq(IEtherFiNode(newEtherFiNode).numAssociatedValidators(), 1);        
    }

    function test_mainnet_launch_validator_sharing_version0_safe() public {
        initializeRealisticFork(MAINNET_FORK);
        _upgrade_etherfi_node_contract();   
        _upgrade_etherfi_nodes_manager_contract(); 

        uint256 validatorId = 2285;
        address etherFiNode = managerInstance.etherfiNodeAddress(validatorId);

        assertEq(IEtherFiNode(etherFiNode).version(), 1);
        assertEq(IEtherFiNode(etherFiNode).numAssociatedValidators(), 1);

        uint256[] memory newValidatorIds = launch_validator(1, validatorId, false, BNFTInstance.ownerOf(validatorId), auctionInstance.getBidOwner(validatorId));
        address newEtherFiNode = managerInstance.etherfiNodeAddress(newValidatorIds[0]);

        assertEq(etherFiNode, newEtherFiNode);
        assertEq(IEtherFiNode(etherFiNode).version(), 1);
        assertEq(IEtherFiNode(etherFiNode).numAssociatedValidators(), 2);
    }

    function test_mainnet_launch_validator_cancel_afeter_deposit_while_sharing_version0_safe() public {
        initializeRealisticFork(MAINNET_FORK);
        
        _upgrade_etherfi_node_contract();   
        _upgrade_etherfi_nodes_manager_contract(); 
        
        uint256 validatorId = 23835;
        address etherFiNode = managerInstance.etherfiNodeAddress(validatorId);

        assertEq(IEtherFiNode(etherFiNode).version(), 1);
        assertEq(IEtherFiNode(etherFiNode).numAssociatedValidators(), 1);

        address operator = auctionInstance.getBidOwner(validatorId);
        vm.deal(operator, 100 ether);
        vm.startPrank(operator);
        uint256[] memory bidIds = auctionInstance.createBid{value: 0.1 ether * 1}(1, 0.1 ether);
        vm.stopPrank();
        
        address bnftStaker = 0x5836152812568244760ba356B5f3838Aa5B672e0;
        uint256 lp_balance = address(liquidityPoolInstance).balance;
        vm.startPrank(bnftStaker);
        uint256[] memory newValidatorIds = liquidityPoolInstance.batchDepositWithLiquidityPoolAsBnftHolder(bidIds, 1, validatorId);
        vm.stopPrank();
        address newEtherFiNode = managerInstance.etherfiNodeAddress(newValidatorIds[0]);

        assertEq(etherFiNode, newEtherFiNode);
        assertEq(IEtherFiNode(etherFiNode).version(), 1);
        assertEq(IEtherFiNode(etherFiNode).numAssociatedValidators(), 1);

        vm.startPrank(bnftStaker);
        liquidityPoolInstance.batchCancelDeposit(newValidatorIds);
        vm.stopPrank();

        assertEq(lp_balance, address(liquidityPoolInstance).balance);
        assertEq(managerInstance.etherfiNodeAddress(newValidatorIds[0]), address(0));
        assertEq(IEtherFiNode(etherFiNode).numAssociatedValidators(), 1);
    }


    // Zellic audit - Cancel validator deposit with version 0 safe fails
    function test_mainnet_cancel_intermediate_validator() public {
        initializeRealisticFork(MAINNET_FORK);
        _upgrade_etherfi_node_contract();   
        _upgrade_etherfi_nodes_manager_contract(); 

        address operator = 0x1876ECcb4eDd3ed95051c64824430fc7f1C8763c;
        vm.deal(operator, 100 ether);
        vm.startPrank(operator);
        uint256[] memory bidIds = auctionInstance.createBid{value: 0.1 ether * 1}(1, 0.1 ether);
        vm.stopPrank();
        
        address bnftStaker = 0x5836152812568244760ba356B5f3838Aa5B672e0;
        vm.startPrank(bnftStaker);
        uint256[] memory validatorIds = liquidityPoolInstance.batchDepositWithLiquidityPoolAsBnftHolder(bidIds, 1);
        vm.stopPrank();

        _upgrade_etherfi_nodes_manager_contract();
        _upgrade_etherfi_node_contract();
        _upgrade_staking_manager_contract();
        _upgrade_liquidity_pool_contract();

        vm.startPrank(bnftStaker);
        liquidityPoolInstance.batchCancelDeposit(validatorIds);
        vm.stopPrank();
    }

    function test_ExitOneAmongMultipleValidators() public {
        uint256[] memory validatorIds = launch_validator(1, 0, false);
        uint256 validatorId = validatorIds[0];
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorId);

        assertTrue(managerInstance.phase(validatorIds[0]) == IEtherFiNode.VALIDATOR_PHASE.LIVE);
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 1);
        assertEq(IEtherFiNode(etherfiNode).numExitRequestsByTnft(), 0);
        assertEq(IEtherFiNode(etherfiNode).numExitedValidators(), 0);

        // launch 3 more validators
        uint256[] memory newValidatorIds = launch_validator(3, validatorId, false);
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 4);
        assertEq(IEtherFiNode(etherfiNode).numExitRequestsByTnft(), 0);
        assertEq(IEtherFiNode(etherfiNode).numExitedValidators(), 0);

        // Send exit request to the 2nd one
        hoax(TNFTInstance.ownerOf(newValidatorIds[0]));
        managerInstance.batchSendExitRequest(_to_uint256_array(newValidatorIds[0]));
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 4);
        assertEq(IEtherFiNode(etherfiNode).numExitRequestsByTnft(), 1);
        assertEq(IEtherFiNode(etherfiNode).numExitedValidators(), 0);

        // Exit the 2nd one
        uint256 validatorToExit = IEtherFiNode(etherfiNode).associatedValidatorIds(1);
        _transferTo(managerInstance.etherfiNodeAddress(validatorToExit), 16 ether);

        uint256[] memory validatorIdsToExit = new uint256[](1);
        uint32[] memory exitTimestamps = new uint32[](1);
        validatorIdsToExit[0] = validatorToExit;
        exitTimestamps[0] = uint32(block.timestamp);
        hoax(managerInstance.owner());
        managerInstance.processNodeExit(validatorIdsToExit, exitTimestamps);
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 4);
        assertEq(IEtherFiNode(etherfiNode).numExitRequestsByTnft(), 1);
        assertEq(IEtherFiNode(etherfiNode).numExitedValidators(), 1);

        managerInstance.fullWithdraw(validatorToExit);
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 3);
        assertEq(IEtherFiNode(etherfiNode).numExitRequestsByTnft(), 0);
        assertEq(IEtherFiNode(etherfiNode).numExitedValidators(), 0);

        assertEq(managerInstance.etherfiNodeAddress(validatorToExit), address(0)); 
        for (uint256 i = 0; i < IEtherFiNode(etherfiNode).numAssociatedValidators(); i++) {
            uint256 valId = IEtherFiNode(etherfiNode).associatedValidatorIds(i);
            address safe = managerInstance.etherfiNodeAddress(valId);

            assertEq(safe, etherfiNode);
        }
    }

    function test_lp_as_bnft_holders_cant_mix_up_1() public {
        uint256[] memory validatorIds = launch_validator(1, 0, false);
        uint256 validatorId = validatorIds[0];
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorId);

        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 1);

        vm.deal(alice, 10000 ether);
        vm.startPrank(alice);
        liquidityPoolInstance.updateBnftMode(true);
        uint256[] memory bidIds = auctionInstance.createBid{value: 0.1 ether * 1}(1, 0.1 ether);
        liquidityPoolInstance.deposit{value: 32 ether * 1}();

        // launch 1 more validators
        vm.expectRevert("WRONG_BNFT_OWNER");
        uint256[] memory newValidatorIds = liquidityPoolInstance.batchDepositWithLiquidityPoolAsBnftHolder(bidIds, 1, validatorId);
    }

    function test_lp_as_bnft_holders_cant_mix_up_2() public {
        uint256[] memory validatorIds = launch_validator(1, 0, true);
        uint256 validatorId = validatorIds[0];
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorId);

        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 1);

        vm.deal(alice, 10000 ether);
        vm.startPrank(alice);
        liquidityPoolInstance.updateBnftMode(false);
        uint256[] memory bidIds = auctionInstance.createBid{value: 0.1 ether * 1}(1, 0.1 ether);
        liquidityPoolInstance.deposit{value: 30 ether * 1}();

        // launch 1 more validators
        vm.expectRevert("WRONG_BNFT_OWNER");
        uint256[] memory newValidatorIds = liquidityPoolInstance.batchDepositAsBnftHolder{value: 2 ether}(bidIds, 1, validatorId);
    }

    /*
    function test_PartialWithdrawalOfPrincipalFails() public {
        uint256[] memory validatorIds = launch_validator(1, 0, false);
        uint256 validatorId = validatorIds[0];
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorId);

        assertTrue(managerInstance.phase(validatorIds[0]) == IEtherFiNode.VALIDATOR_PHASE.LIVE);
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 1);

        // launch 3 more validators
        uint256[] memory newValidatorIds = launch_validator(3, validatorId, false);
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 4);

        uint256[] memory validatorIdsToExit = new uint256[](1);
        uint32[] memory exitTimestamps = new uint32[](1);
        exitTimestamps[0] = uint32(block.timestamp);

        // Exit 1 among 4
        validatorIdsToExit[0] = newValidatorIds[0];
        _transferTo(etherfiNode, 16 ether);

        // Someone triggers paritalWithrdaw
        // Before the Oracle marks it as EXITED
        vm.prank(managerInstance.owner());
        vm.expectRevert("MUST_EXIT");
        managerInstance.partialWithdraw(validatorId);

        hoax(managerInstance.owner());
        managerInstance.processNodeExit(validatorIdsToExit, exitTimestamps);

        managerInstance.fullWithdraw(validatorIdsToExit[0]);
    }
    */

    function test_TnftTransferFailsWithMultipleValidators_Fails() public {
        uint256[] memory validatorIds = launch_validator(1, 0, false);
        uint256 validatorId = validatorIds[0];
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorId);

        assertTrue(managerInstance.phase(validatorIds[0]) == IEtherFiNode.VALIDATOR_PHASE.LIVE);
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 1);

        // launch 3 more validators
        uint256[] memory newValidatorIds = launch_validator(3, validatorId, false);
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 4);

        address tnftOwner = TNFTInstance.ownerOf(validatorId);
        vm.prank(tnftOwner);
        vm.expectRevert("numAssociatedValidators != 1");
        TNFTInstance.transferFrom(tnftOwner, bob, validatorId);

        uint256[] memory validatorIdsToExit = new uint256[](1);
        uint32[] memory exitTimestamps = new uint32[](1);
        exitTimestamps[0] = uint32(block.timestamp);

        // Exit 1 among 4
        validatorIdsToExit[0] = newValidatorIds[0];
        _transferTo(etherfiNode, 16 ether);
        hoax(managerInstance.owner());
        managerInstance.processNodeExit(validatorIdsToExit, exitTimestamps);
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 4);

        managerInstance.fullWithdraw(validatorIdsToExit[0]);
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 3);

        // Still fails
        vm.prank(tnftOwner);
        vm.expectRevert("numAssociatedValidators != 1");
        TNFTInstance.transferFrom(tnftOwner, bob, validatorId);

        // Exit 1 among 3
        validatorIdsToExit[0] = newValidatorIds[1];
        _transferTo(etherfiNode, 16 ether);
        hoax(managerInstance.owner());
        managerInstance.processNodeExit(validatorIdsToExit, exitTimestamps);
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 3);

        managerInstance.fullWithdraw(validatorIdsToExit[0]);
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 2);

        // Still fails
        vm.prank(tnftOwner);
        vm.expectRevert("numAssociatedValidators != 1");
        TNFTInstance.transferFrom(tnftOwner, bob, validatorId);

        // Exit 1 among 2
        validatorIdsToExit[0] = newValidatorIds[2];
        _transferTo(etherfiNode, 16 ether);
        hoax(managerInstance.owner());
        managerInstance.processNodeExit(validatorIdsToExit, exitTimestamps);
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 2);

        // Still fails
        vm.prank(tnftOwner);
        vm.expectRevert("numAssociatedValidators != 1");
        TNFTInstance.transferFrom(tnftOwner, bob, validatorId);


        managerInstance.fullWithdraw(validatorIdsToExit[0]);
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 1);

        // Now succeeds
        vm.prank(tnftOwner);
        TNFTInstance.transferFrom(tnftOwner, bob, validatorId);
    }

    // Zellic-Audit-Issue 1
    function test_CacnelAfterBeingMarkedExited_fails() public {
        vm.deal(alice, 10000 ether);

        uint256[] memory validatorIds = launch_validator(1, 0, false);
        uint32[] memory exitTimestamps = new uint32[](1);
        exitTimestamps[0] = 1;
        address etherFiNode = managerInstance.etherfiNodeAddress(validatorIds[0]);

        assertTrue(managerInstance.phase(validatorIds[0]) == IEtherFiNode.VALIDATOR_PHASE.LIVE);

        vm.startPrank(alice);
        managerInstance.processNodeExit(validatorIds, exitTimestamps);
        IEtherFiNodesManager.ValidatorInfo memory info = managerInstance.getValidatorInfo(validatorIds[0]);
        assertTrue(info.phase == IEtherFiNode.VALIDATOR_PHASE.EXITED);

        uint256[] memory bidIds = auctionInstance.createBid{value: 0.2 ether}(2, 0.1 ether);
        liquidityPoolInstance.deposit{value: 60 ether}();
        uint256[] memory newValidators = liquidityPoolInstance.batchDepositAsBnftHolder{value: 4 ether}(bidIds, 2);

        vm.expectRevert("INVALID_PHASE_TRANSITION");
        liquidityPoolInstance.batchCancelDeposit(validatorIds);
    }

    // Zellic-Audit-Issue 2
    function test_SendingMultipleExitRequests_fails() public {
        vm.startPrank(TNFTInstance.ownerOf(bidId[0]));

        managerInstance.batchSendExitRequest(_to_uint256_array(bidId[0]));

        vm.expectRevert("INVALID");
        managerInstance.batchSendExitRequest(_to_uint256_array(bidId[0]));
    }

    // Zellic-Audit-Issue 4
    function test_wrong_staker_on_fails_1() public {
        vm.deal(alice, 100000 ether);

        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: 32 ether * 1}();

        registerAsBnftHolder(alice);
        nodeOperatorManagerInstance.registerNodeOperator(aliceIPFSHash, 5);

        {
            uint256[] memory bidId1 = auctionInstance.createBid{value: 0.4 ether}(1, 0.4 ether);
            uint256[] memory newValidators = liquidityPoolInstance.batchDepositAsBnftHolder{value: 2 ether}(bidId1, 1);
        }

        uint256[] memory bidId1 = auctionInstance.createBid{value: 0.4 ether}(1, 0.4 ether);
        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(bidId1, false);

        (IStakingManager.DepositData[] memory depositDataArray, bytes32[] memory depositDataRootsForApproval, bytes[] memory sig, bytes[] memory pubKey) = _prepareForValidatorRegistration(bidId1);

        vm.expectRevert("Wrong flow");
        liquidityPoolInstance.batchRegisterAsBnftHolder(zeroRoot, bidId1, depositDataArray, depositDataRootsForApproval, sig);
        vm.stopPrank();
    }

    // Zellic-Audit-Issue 4
    function test_wrong_staker_on_fails_2() public {
        vm.deal(alice, 100000 ether);

        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: 32 ether * 1}();

        registerAsBnftHolder(alice);
        nodeOperatorManagerInstance.registerNodeOperator(aliceIPFSHash, 5);

        uint256[] memory bidId1 = auctionInstance.createBid{value: 0.4 ether}(1, 0.4 ether);
        liquidityPoolInstance.batchDepositAsBnftHolder{value: 2 ether}(bidId1, 1);

        uint256[] memory bidId2 = auctionInstance.createBid{value: 0.4 ether}(1, 0.4 ether);
        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(bidId2, false);

        // Confirm that the LP flow can't affect the 32 ETH staker flow
        {
            (IStakingManager.DepositData[] memory depositDataArray, bytes32[] memory depositDataRootsForApproval, bytes[] memory sig, bytes[] memory pubKey) = _prepareForValidatorRegistration(bidId2);
            vm.expectRevert("Wrong flow");
            liquidityPoolInstance.batchRegisterAsBnftHolder(zeroRoot, bidId2, depositDataArray, depositDataRootsForApproval, sig);
        }

        // Confirm that the 32ETH flow can't affect the LP flow
        {
            IStakingManager.DepositData[] memory depositDataArray = _prepareForDepositData(bidId1, 32 ether);
            vm.expectRevert("Wrong flow");
            stakingManagerInstance.batchRegisterValidators(zeroRoot, bidId1, depositDataArray);
        }

        vm.stopPrank();
    }


}
