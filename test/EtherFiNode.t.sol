// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/EtherFiNode.sol";
import "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@eigenlayer/contracts/interfaces/IEigenPodManager.sol";
import "@eigenlayer/contracts/interfaces/IDelayedWithdrawalRouter.sol";

import "forge-std/console2.sol";

contract EtherFiNodeTest is TestSetup {

    // from EtherFiNodesManager.sol
    uint256 TreasuryRewardSplit = 50_000;
    uint256 NodeOperatorRewardSplit = 50_000;
    uint256 TNFTRewardSplit = 815_625;
    uint256 BNFTRewardSplit = 84_375;
    uint256 RewardSplitDivisor = 1_000_000;

    uint256 testnetFork;
    uint256[] bidId;
    EtherFiNode safeInstance;
    EtherFiNode restakingSafe;

    // eigenLayer
    IDelayedWithdrawalRouter delayedWithdrawalRouter;

    function setUp() public {

        setUpTests();

        assertTrue(node.phase() == IEtherFiNode.VALIDATOR_PHASE.NOT_INITIALIZED);


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

        delayedWithdrawalRouter = IDelayedWithdrawalRouter(IEtherFiNodesManager(safeInstance.etherFiNodesManager()).delayedWithdrawalRouter());
        testnetFork = vm.createFork(vm.envString("GOERLI_RPC_URL"));
    }

    function createRestakedValidator() public returns (uint256) {
        vm.deal(alice, 33 ether);
        vm.startPrank(alice);

        nodeOperatorManagerInstance.registerNodeOperator("fake_ipfs_hash", 10);

        // create a new bid
        uint256[] memory createdBids = auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);

        // depsosit against that bid with restaking enabled
        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether * createdBids.length}(createdBids, true);

        // Register the validator and send deposited eth to depositContract/Beaconchain
        // signatures are not checked but roots need to match
        bytes32 root = depGen.generateDepositRoot(
            hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
            hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
            managerInstance.getWithdrawalCredentials(createdBids[0]),
            32 ether
        );
        IStakingManager.DepositData memory depositData = IStakingManager
            .DepositData({
                publicKey: hex"8f9c0aab19ee7586d3d470f132842396af606947a0589382483308fdffdaf544078c3be24210677a9c471ce70b3b4c2c",
                signature: hex"877bee8d83cac8bf46c89ce50215da0b5e370d282bb6c8599aabdbc780c33833687df5e1f5b5c2de8a6cd20b6572c8b0130b1744310a998e1079e3286ff03e18e4f94de8cdebecf3aaac3277b742adb8b0eea074e619c20d13a1dda6cba6e3df",
                depositDataRoot: root,
                ipfsHashForEncryptedValidatorKey: "restaking_unit_tests"
        });
        IStakingManager.DepositData[] memory depositDatas = new IStakingManager.DepositData[](1);
        depositDatas[0] = depositData;
        stakingManagerInstance.batchRegisterValidators(zeroRoot, createdBids, depositDatas);

        vm.stopPrank();
        return createdBids[0];
    }

    function test_createPod() public {
        // re-run setup now that we have fork selected. Probably a better way we can do this
        vm.selectFork(testnetFork);
        setUp();
        safeInstance.createEigenPod();
        console2.log("podAddr:", address(safeInstance.eigenPod()));

        vm.deal(address(safeInstance.eigenPod()), 2 ether);
        console2.log("balances:", address(safeInstance).balance, address(safeInstance.eigenPod()).balance);

        safeInstance.queueRestakedWithdrawal();
        console2.log("balances2:", address(safeInstance).balance, address(safeInstance.eigenPod()).balance);

        vm.roll(block.number + (50400) + 1);
        
        safeInstance.claimQueuedWithdrawals(1);
        console2.log("balances3:", address(safeInstance).balance, address(safeInstance.eigenPod()).balance);
    }

    function test_claimMixedSafeAndPodFunds() public {

        // re-run setup now that we have fork selected. Probably a better way we can do this
        vm.selectFork(testnetFork);
        setUp();

        uint256 bidId = createRestakedValidator();
        safeInstance = EtherFiNode(payable(managerInstance.etherfiNodeAddress(bidId)));

        // simulate 1 eth of already claimed staking rewards and 1 eth of unclaimed restaked rewards
        vm.deal(address(safeInstance.eigenPod()), 1 ether);
        vm.deal(address(safeInstance), 1 ether);

        assertEq(address(safeInstance).balance, 1 ether);
        assertEq(address(safeInstance.eigenPod()).balance, 1 ether);

        // claim the restaked rewards
        safeInstance.queueRestakedWithdrawal();
        vm.roll(block.number + (50400) + 1);
        safeInstance.claimQueuedWithdrawals(1);

        assertEq(address(safeInstance).balance, 2 ether);
        assertEq(address(safeInstance.eigenPod()).balance, 0 ether);
    }

    function test_splitBalanceInExecutionLayer() public {
        // re-run setup now that we have fork selected. Probably a better way we can do this
        vm.selectFork(testnetFork);
        setUp();

        uint256 validatorId = createRestakedValidator();
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

        // simulate 1 eth of staking rewards sent to the eigen pod
        vm.deal(address(safeInstance.eigenPod()), 1 ether);
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
        safeInstance.queueRestakedWithdrawal();
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
        vm.deal(address(safeInstance.eigenPod()), 2 ether);
        (_withdrawalSafe, _eigenPod, _delayedWithdrawalRouter) = safeInstance.splitBalanceInExecutionLayer();
        assertEq(_withdrawalSafe, 0 ether);
        assertEq(_eigenPod, 2 ether);
        assertEq(_delayedWithdrawalRouter, 1 ether);

        (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, beaconBalance);
        assertEq(toNodeOperator, 3 ether * 5 / 100);
        assertEq(toTreasury, 3 ether * 5 / 100);
        assertEq(toTnft, 30 ether + (3 ether * 90 * 29) / (100 * 32));
        assertEq(toBnft, 2 ether + (3 ether * 90 * 3) / (100 * 32));

        // wait and claim the first queued withdrawal
        vm.roll(block.number + (50400) + 1);
        safeInstance.claimQueuedWithdrawals(1);
        (_withdrawalSafe, _eigenPod, _delayedWithdrawalRouter) = safeInstance.splitBalanceInExecutionLayer();
        assertEq(_withdrawalSafe, 1 ether);
        assertEq(_eigenPod, 2 ether);
        assertEq(_delayedWithdrawalRouter, 0 ether);

        (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, beaconBalance);
        assertEq(toNodeOperator, 3 ether * 5 / 100);
        assertEq(toTreasury, 3 ether * 5 / 100);
        assertEq(toTnft, 30 ether + (3 ether * 90 * 29) / (100 * 32));
        assertEq(toBnft, 2 ether + (3 ether * 90 * 3) / (100 * 32));
    }

    function test_claimRestakedRewards() public {
        // re-run setup now that we have fork selected. Probably a better way we can do this
        vm.selectFork(testnetFork);
        setUp();

        uint256 validatorId = createRestakedValidator();
        safeInstance = EtherFiNode(payable(managerInstance.etherfiNodeAddress(validatorId)));

        // simulate 1 eth of staking rewards sent to the eigen pod
        vm.deal(address(safeInstance.eigenPod()), 1 ether);
        assertEq(address(safeInstance).balance, 0 ether);
        assertEq(address(safeInstance.eigenPod()).balance, 1 ether);

        // queue the withdrawal of the rewards. Funds have been sent to the DelayedWithdrawalRouter
        safeInstance.queueRestakedWithdrawal();
        assertEq(address(safeInstance).balance, 0 ether);
        assertEq(address(safeInstance.eigenPod()).balance, 0 ether);

        // simulate some more staking rewards but dont queue the withdrawal
        vm.deal(address(safeInstance.eigenPod()), 0.5 ether);

        // attempt to claim queued withdrawals but not enough time has passed (no funds moved to safe)
        safeInstance.claimQueuedWithdrawals(1);
        assertEq(address(safeInstance).balance, 0 ether);
        assertEq(address(safeInstance.eigenPod()).balance, 0.5 ether);

        // wait and claim
        vm.roll(block.number + (50400) + 1);
        safeInstance.claimQueuedWithdrawals(1);
        assertEq(address(safeInstance).balance, 1 ether);
        assertEq(address(safeInstance.eigenPod()).balance, 0.5 ether);

        // now queue up multiple different rewards (0.5 ether remain in pod from previous step)
        safeInstance.queueRestakedWithdrawal();
        vm.deal(address(safeInstance.eigenPod()), 0.5 ether);
        safeInstance.queueRestakedWithdrawal();
        vm.deal(address(safeInstance.eigenPod()), 0.5 ether);
        safeInstance.queueRestakedWithdrawal();

        assertEq(address(safeInstance.eigenPod()).balance, 0 ether);
        IDelayedWithdrawalRouter.DelayedWithdrawal[] memory unclaimedWithdrawals = delayedWithdrawalRouter.getUserDelayedWithdrawals(address(safeInstance));
        assertEq(unclaimedWithdrawals.length, 3);

        // wait but only claim 2 of the 3 queued withdrawals
        // The ability to claim a subset of outstanding withdrawals is to avoid a denial of service
        // attack in which the attacker creates too many withdrawals for us to process in 1 tx
        vm.roll(block.number + (50400) + 1);
        safeInstance.claimQueuedWithdrawals(2);

        unclaimedWithdrawals = delayedWithdrawalRouter.getUserDelayedWithdrawals(address(safeInstance));
        assertEq(unclaimedWithdrawals.length, 1);
        assertEq(address(safeInstance.eigenPod()).balance, 0 ether);
        assertEq(address(safeInstance).balance, 2 ether);
    }

    function test_restakedFullWithdrawal() public {
        // re-run setup now that we have fork selected. Probably a better way we can do this
        vm.selectFork(testnetFork);
        setUp();

        uint256 validatorId = createRestakedValidator();
        safeInstance = EtherFiNode(payable(managerInstance.etherfiNodeAddress(validatorId)));

        uint256[] memory validatorIds = new uint256[](1);
        uint32[] memory exitRequestTimestamps = new uint32[](1);
        validatorIds[0] = validatorId;
        exitRequestTimestamps[0] = uint32(block.timestamp);

        vm.deal(safeInstance.eigenPod(), 32 ether);

        vm.startPrank(alice); // alice is the admin
        vm.expectRevert("validator node is not exited");
        managerInstance.fullWithdraw(validatorIds[0]);

        // Marked as EXITED
        // should also have queued up the current balance to via DelayedWithdrawalRouter
        managerInstance.processNodeExit(validatorIds, exitRequestTimestamps);
        IDelayedWithdrawalRouter.DelayedWithdrawal[] memory unclaimedWithdrawals = delayedWithdrawalRouter.getUserDelayedWithdrawals(address(safeInstance));
        assertEq(unclaimedWithdrawals.length, 1);
        assertEq(unclaimedWithdrawals[0].amount, uint224(32 ether));

        // fail because we have not processed the queued withdrawal of the funds from the pod
        // because not enough time has passed to claim them
        vm.expectRevert(EtherFiNodesManager.MustClaimRestakedWithdrawals.selector);
        managerInstance.fullWithdraw(validatorIds[0]);

        // wait some time
        vm.roll(block.number + (50400) + 1);

        assertEq(managerInstance.getUnusedWithdrawalSafesLength(), 0);

        // try again. FullWithdraw will automatically attempt to claim queuedWithdrawals
        managerInstance.fullWithdraw(validatorIds[0]);
        assertEq(address(safeInstance).balance, 0);

        // safe should have been automatically recycled
        assertEq(managerInstance.getUnusedWithdrawalSafesLength(), 1);
        assertEq(uint256(safeInstance.phase()), uint256(IEtherFiNode.VALIDATOR_PHASE.READY_FOR_DEPOSIT));
        assertEq(safeInstance.isRestakingEnabled(), false);
        assertEq(safeInstance.stakingStartTimestamp(), 0);
        assertEq(safeInstance.restakingObservedExitBlock(), 0);
    }

    function test_restakedPartialWithdrawQueuesFutureWithdrawals() public {
        // re-run setup now that we have fork selected. Probably a better way we can do this
        vm.selectFork(testnetFork);
        setUp();

        uint256 validatorId = createRestakedValidator();
        IEtherFiNode node = IEtherFiNode(payable(managerInstance.etherfiNodeAddress(validatorId)));

        // simulate staking rewards
        vm.deal(node.eigenPod(), 1 ether);

        // queue up future withdrawal. Funds have moved to router
        managerInstance.queueRestakedWithdrawal(validatorId);
        (uint256 _withdrawalSafe, uint256 _eigenPod, uint256 _delayedWithdrawalRouter) = node.splitBalanceInExecutionLayer();
        assertEq(_withdrawalSafe, 0 ether);
        assertEq(_eigenPod, 0 ether);
        assertEq(_delayedWithdrawalRouter, 1 ether);

        // more staking rewards
        vm.deal(node.eigenPod(), 3 ether);

        // withdraw should claim available queued withdrawals and also automatically queue up current balance for future
        vm.roll(block.number + (50400) + 1);
        managerInstance.partialWithdraw(validatorId);

        (_withdrawalSafe, _eigenPod, _delayedWithdrawalRouter) = node.splitBalanceInExecutionLayer();
        assertEq(_withdrawalSafe, 0 ether); // funds are swept from safe after being moved into it
        assertEq(_eigenPod, 0 ether);
        assertEq(_delayedWithdrawalRouter, 3 ether);
    }

    function test_restakedAttackerCantBlockWithdraw() public {
        // re-run setup now that we have fork selected. Probably a better way we can do this
        vm.selectFork(testnetFork);
        setUp();

        uint256 validatorId = createRestakedValidator();
        safeInstance = EtherFiNode(payable(managerInstance.etherfiNodeAddress(validatorId)));

        uint256[] memory validatorIds = new uint256[](1);
        uint32[] memory exitRequestTimestamps = new uint32[](1);
        validatorIds[0] = validatorId;
        exitRequestTimestamps[0] = uint32(block.timestamp);

        vm.deal(safeInstance.eigenPod(), 32 ether);

        vm.startPrank(alice); // alice is the admin
        vm.expectRevert("validator node is not exited");
        managerInstance.fullWithdraw(validatorIds[0]);

        // Marked as EXITED
        // should also have queued up the current balance to via DelayedWithdrawalRouter
        managerInstance.processNodeExit(validatorIds, exitRequestTimestamps);
        IDelayedWithdrawalRouter.DelayedWithdrawal[] memory unclaimedWithdrawals = delayedWithdrawalRouter.getUserDelayedWithdrawals(address(safeInstance));
        assertEq(unclaimedWithdrawals.length, 1);
        assertEq(unclaimedWithdrawals[0].amount, uint224(32 ether));

        vm.roll(block.number + 1);

        // attacker now sends funds and queues claims
        vm.deal(safeInstance.eigenPod(), 1 ether);
        safeInstance.queueRestakedWithdrawal();
        vm.deal(safeInstance.eigenPod(), 1 ether);
        safeInstance.queueRestakedWithdrawal();
        vm.deal(safeInstance.eigenPod(), 1 ether);
        safeInstance.queueRestakedWithdrawal();
        vm.deal(safeInstance.eigenPod(), 1 ether);
        safeInstance.queueRestakedWithdrawal();
        vm.deal(safeInstance.eigenPod(), 1 ether);
        safeInstance.queueRestakedWithdrawal();

        unclaimedWithdrawals = delayedWithdrawalRouter.getUserDelayedWithdrawals(address(safeInstance));
        assertEq(unclaimedWithdrawals.length, 6);

        // wait some time so claims are claimable
        vm.roll(block.number + (50400) + 1);

        // TODO(Dave): 5 picked here because that's how many claims I set the manager contract to attempt. We can tune thi
        safeInstance.claimQueuedWithdrawals(5);
        unclaimedWithdrawals = delayedWithdrawalRouter.getUserDelayedWithdrawals(address(safeInstance));

        // shoud not be allowed to partial withdraw since node is exited
        // In this case it fails because of the balance check right before the state check
        vm.expectRevert("Balance > 8 ETH. Exit the node.");
        managerInstance.partialWithdraw(validatorId);

        // This should succeed even though there are still some unclaimed withdrawals
        // this is because we only enforce that all withdrawals before the observed exit of the node have completed
        managerInstance.fullWithdraw(validatorIds[0]);
        assertEq(unclaimedWithdrawals.length, 1);
        assertEq(address(safeInstance).balance, 0);
    }

    function test_SetExitRequestTimestampFailsOnIncorrectCaller() public {
        vm.expectRevert("Only EtherFiNodeManager Contract");
        vm.prank(alice);
        safeInstance.setExitRequestTimestamp();
    }

    function test_SetPhaseRevertsOnIncorrectCaller() public {
        vm.expectRevert("Only EtherFiNodeManager Contract");
        vm.prank(owner);
        safeInstance.setPhase(IEtherFiNode.VALIDATOR_PHASE.EXITED);
    }

    function test_SetIpfsHashForEncryptedValidatorKeyRevertsOnIncorrectCaller() public {
        vm.expectRevert("Only EtherFiNodeManager Contract");
        vm.prank(owner);
        safeInstance.setIpfsHashForEncryptedValidatorKey("_ipfsHash");
    }

    function test_SetExitRequestTimestampRevertsOnIncorrectCaller() public {
        vm.expectRevert("Only EtherFiNodeManager Contract");
        vm.prank(owner);
        safeInstance.setExitRequestTimestamp();

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
            IEtherFiNode(etherFiNode).phase() ==
                IEtherFiNode.VALIDATOR_PHASE.LIVE
        );
        assertTrue(IEtherFiNode(etherFiNode).exitTimestamp() == 0);

        vm.expectRevert("Only EtherFiNodeManager Contract");
        IEtherFiNode(etherFiNode).markExited(1);

        vm.expectRevert("Not admin");
        vm.prank(owner);
        managerInstance.processNodeExit(validatorIds, exitTimestamps);
        assertTrue(IEtherFiNode(etherFiNode).phase() == IEtherFiNode.VALIDATOR_PHASE.LIVE);
        assertTrue(IEtherFiNode(etherFiNode).exitTimestamp() == 0);

        hoax(alice);
        managerInstance.processNodeExit(validatorIds, exitTimestamps);
        assertTrue(IEtherFiNode(etherFiNode).phase() == IEtherFiNode.VALIDATOR_PHASE.EXITED);
        assertTrue(IEtherFiNode(etherFiNode).exitTimestamp() > 0);

        hoax(alice);
        vm.expectRevert("Invalid phase transition");
        managerInstance.processNodeExit(validatorIds, exitTimestamps);
    }

    function test_markExitedWorksCorrectlyWhenBeingSlashed() public {
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = bidId[0];
        uint32[] memory exitTimestamps = new uint32[](1);
        exitTimestamps[0] = 1;
        address etherFiNode = managerInstance.etherfiNodeAddress(validatorIds[0]);

        assertTrue(
            IEtherFiNode(etherFiNode).phase() ==
                IEtherFiNode.VALIDATOR_PHASE.LIVE
        );
        assertTrue(IEtherFiNode(etherFiNode).exitTimestamp() == 0);

        hoax(alice);
        managerInstance.markBeingSlashed(validatorIds);
        assertTrue(IEtherFiNode(etherFiNode).phase() == IEtherFiNode.VALIDATOR_PHASE.BEING_SLASHED);
        hoax(alice);
        managerInstance.processNodeExit(validatorIds, exitTimestamps);
        assertTrue(IEtherFiNode(etherFiNode).phase() == IEtherFiNode.VALIDATOR_PHASE.EXITED);
        assertTrue(IEtherFiNode(etherFiNode).exitTimestamp() > 0);
    }

    function test_evict() public {
        address nodeOperator = 0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931;
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = bidId[0];
        uint32[] memory exitTimestamps = new uint32[](1);
        exitTimestamps[0] = 1;
        address etherFiNode = managerInstance.etherfiNodeAddress(validatorIds[0]);

        assertTrue(IEtherFiNode(etherFiNode).phase() == IEtherFiNode.VALIDATOR_PHASE.LIVE);
        assertTrue(IEtherFiNode(etherFiNode).exitTimestamp() == 0);
        assertEq(address(etherFiNode).balance, 0.00 ether); // node no longer receives auction revenue

        uint256 nodeOperatorBalance = address(nodeOperator).balance;

        vm.prank(alice);
        managerInstance.processNodeEvict(validatorIds);

        assertTrue(IEtherFiNode(etherFiNode).phase() == IEtherFiNode.VALIDATOR_PHASE.EVICTED);
        assertTrue(IEtherFiNode(etherFiNode).exitTimestamp() > 0);
        assertEq(address(etherFiNode).balance, 0);
        assertEq(address(nodeOperator).balance, nodeOperatorBalance);
    }

    function test_partialWithdrawRewardsDistribution() public {
        address nodeOperator = 0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931;
        address staker = 0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf;
        address etherfiNode = managerInstance.etherfiNodeAddress(bidId[0]);

        // Transfer the T-NFT to 'dan'
        hoax(staker);
        TNFTInstance.transferFrom(staker, dan, bidId[0]);

        uint256 nodeOperatorBalance = address(nodeOperator).balance;
        uint256 treasuryBalance = address(treasuryInstance).balance;
        uint256 danBalance = address(dan).balance;
        uint256 bnftStakerBalance = address(staker).balance;

        // Simulate the rewards distribution from the beacon chain
        vm.deal(etherfiNode, address(etherfiNode).balance + 1 ether);

        // Withdraw the {staking, protocol} rewards
        // - bid amount = 0 ether (Auction revenue no longer distributed to nodes)
        //   - 50 % ether is vested for the stakers
        //   - 50 % ether is shared across all validators
        //     - 25 % to treasury, 25% to node operator, the rest to the stakers
        // - staking rewards amount = 1 ether
        hoax(owner);
        managerInstance.partialWithdraw(bidId[0]);
        assertEq(
            address(nodeOperator).balance,
            nodeOperatorBalance + (1 ether * 5) / 100
        );
        assertEq(
            address(treasuryInstance).balance,
            treasuryBalance + (1 ether * 5 ) / 100
        );
        assertEq(address(dan).balance, danBalance + 0.815625000000000000 ether);
        assertEq(address(staker).balance, bnftStakerBalance + 0.084375000000000000 ether);

        vm.deal(etherfiNode, 8.0 ether);
        vm.expectRevert(
            "Balance > 8 ETH. Exit the node."
        );
        managerInstance.partialWithdraw(bidId[0]);
    }

    function test_partialWithdrawFails() public {
        address etherfiNode = managerInstance.etherfiNodeAddress(bidId[0]);

        vm.deal(etherfiNode, 4 ether);

        vm.expectRevert(
            "Not admin"
        );
        vm.prank(owner);
        managerInstance.markBeingSlashed(bidId);

        hoax(alice);
        managerInstance.markBeingSlashed(bidId);
        vm.expectRevert(
            "Must be LIVE or FULLY_WITHDRAWN."
        );
        managerInstance.partialWithdraw(bidId[0]);
    }

    function test_markBeingSlashedFails() public {
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = bidId[0];
        uint32[] memory exitTimestamps = new uint32[](1);
        exitTimestamps[0] = 1;

        hoax(alice);
        managerInstance.processNodeExit(validatorIds, exitTimestamps);

        hoax(alice);
        vm.expectRevert("Invalid phase transition");
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
        assertTrue(IEtherFiNode(etherFiNode).phase() == IEtherFiNode.VALIDATOR_PHASE.BEING_SLASHED);
    }

    function test_partialWithdrawAfterExitRequest() public {
        address nodeOperator = 0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931;
        address staker = 0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf;
        address etherfiNode = managerInstance.etherfiNodeAddress(bidId[0]);

        // Simulate the rewards distribution from the beacon chain
        vm.deal(etherfiNode, address(etherfiNode).balance + 1 ether);

        // Transfer the T-NFT to 'dan'
        hoax(staker);
        TNFTInstance.transferFrom(staker, dan, bidId[0]);

        // Send Exit Request and wait for 14 days to pass
        hoax(dan);
        managerInstance.sendExitRequest(bidId[0]);
        vm.warp(block.timestamp + (1 + 14 * 86400));

        uint256 nodeOperatorBalance = address(nodeOperator).balance;
        uint256 treasuryBalance = address(treasuryInstance).balance;
        uint256 danBalance = address(dan).balance;
        uint256 bnftStakerBalance = address(staker).balance;

        hoax(owner);
        managerInstance.partialWithdraw(bidId[0]);
        uint256 nodeOperatorBalance2 = address(nodeOperator).balance;

        // node operator gets nothing because took longer than 14 days
        assertEq(address(nodeOperator).balance, nodeOperatorBalance);
        assertEq(
            address(treasuryInstance).balance,
            treasuryBalance + 0.05 ether + 0.05 ether // 5% rewards + 5% rewards that would have gone to node operator
        );

        // dan should recieve the T-NFT share
        uint256 danExpectedStakingRewards = 1 ether * TNFTRewardSplit / RewardSplitDivisor;
        assertEq(address(dan).balance, danBalance + danExpectedStakingRewards);

        uint256 bnftExpectedStakingRewards = 1 ether * BNFTRewardSplit / RewardSplitDivisor;
        assertEq(address(staker).balance, bnftStakerBalance + bnftExpectedStakingRewards);

        // No additional rewards if call 'partialWithdraw' again
        uint256 withdrawnOperatorBalance = address(nodeOperator).balance;
        uint256 withdrawnTreasuryBalance = address(treasuryInstance).balance;
        uint256 withdrawnDanBalance = dan.balance;
        uint256 withdrawnBNFTBalance = address(staker).balance;
        hoax(owner);
        managerInstance.partialWithdraw(bidId[0]);
        assertEq(address(nodeOperator).balance, withdrawnOperatorBalance);
        assertEq(address(treasuryInstance).balance, withdrawnTreasuryBalance);
        assertEq(address(dan).balance, withdrawnDanBalance);
        assertEq(address(staker).balance, withdrawnBNFTBalance);
    }

    function test_getFullWithdrawalPayoutsFails() public {

        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = bidId[0];
        address etherfiNode = managerInstance.etherfiNodeAddress(
            validatorIds[0]
        );

        vm.deal(etherfiNode, 16 ether);
        vm.expectRevert("validator node is not exited");
        managerInstance.fullWithdraw(validatorIds[0]);
    }

    function test_processNodeDistributeProtocolRevenueCorrectly() public {
        address nodeOperator = 0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931;
        address staker = 0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf;

        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = bidId[0];
        uint32[] memory exitTimestamps = new uint32[](1);
        exitTimestamps[0] = 1;
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorIds[0]);

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
        assertEq(toTnft, 27 ether);
        assertEq(toBnft, 1.5 ether);

        // 4. balance > 25.5 ether
        vm.deal(etherfiNode, 25.75 ether);
        assertEq(address(etherfiNode).balance, 25.75 ether);
        (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance
            .getFullWithdrawalPayouts(validatorIds[0]);
        assertEq(toNodeOperator, 0);
        assertEq(toTreasury, 0);
        assertEq(toTnft, 24.5 ether);
        assertEq(toBnft, 1.25 ether);

        // 5. balance > 16 ether
        vm.deal(etherfiNode, 18.5 ether);
        assertEq(address(etherfiNode).balance, 18.5 ether);

        (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance
            .getFullWithdrawalPayouts(validatorIds[0]);
        assertEq(toNodeOperator, 0);
        assertEq(toTreasury, 0);
        assertEq(toTnft, 17.5 ether);
        assertEq(toBnft, 1 ether);

        // 6. balance < 16 ether
        vm.deal(etherfiNode, 16 ether);

        (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance
            .getFullWithdrawalPayouts(validatorIds[0]);
        assertEq(toNodeOperator, 0);
        assertEq(toTreasury, 0);
        assertEq(toTnft, 15 ether);
        assertEq(toBnft, 1 ether);

        // 7. balance < 8 ether
        vm.deal(etherfiNode, 8 ether);

        (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance
            .getFullWithdrawalPayouts(validatorIds[0]);
        assertEq(toNodeOperator, 0);
        assertEq(toTreasury, 0);
        assertEq(toTnft, 7.5 ether);
        assertEq(toBnft, 0.5 ether);

        // 8. balance < 4 ether
        vm.deal(etherfiNode, 4 ether);

        (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance
            .getFullWithdrawalPayouts(validatorIds[0]);
        assertEq(toNodeOperator, 0);
        assertEq(toTreasury, 0);
        assertEq(toTnft, 3.75 ether);
        assertEq(toBnft, 0.25 ether);

        // 9. balance == 0 ether
        vm.deal(etherfiNode, 0 ether);

        (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance
            .getFullWithdrawalPayouts(validatorIds[0]);
        assertEq(toNodeOperator, 0);
        assertEq(toTreasury, 0);
        assertEq(toTnft, 0 ether);
        assertEq(toBnft, 0 ether);
    }

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

        uint256 nodeOperatorBalance = address(nodeOperator).balance;
        uint256 treasuryBalance = address(treasuryInstance).balance;
        uint256 danBalance = address(dan).balance;
        uint256 bnftStakerBalance = address(staker).balance;

        hoax(owner);
        vm.expectRevert("Must be LIVE or FULLY_WITHDRAWN.");
        managerInstance.partialWithdraw(validatorIds[0]);
    }

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

        hoax(TNFTInstance.ownerOf(validatorIds[0]));
        managerInstance.sendExitRequest(validatorIds[0]);

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
        managerInstance.sendExitRequest(validatorIds[0]);

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
        managerInstance.sendExitRequest(validatorIds[0]);

        // 28 days passed
        // When (appliedPenalty <= 0.2 ether)
        vm.warp(block.timestamp + 28 * 86400);
        startHoax(alice);
        managerInstance.processNodeExit(validatorIds, exitTimestamps);
        uint256 nonExitPenalty = managerInstance.getNonExitPenalty(bidId[0]);

        // see EtherFiNode.sol:calculateTVL()
        // principle calculation is decreased because balance < 16 ether. See EtherFiNode.sol:calculatePrincipals()
        // this is min(nonExitPenalty, BNFTPrinciple)
        uint256 expectedAppliedPenalty = 625 * 4 ether / 10_000;

        // the node got slashed seriously
        vm.deal(etherfiNode, 4 ether);
        (uint256 toNodeOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury) = managerInstance.getFullWithdrawalPayouts(validatorIds[0]);
        assertEq(nonExitPenalty, 0.573804794831376551 ether);

        assertEq(toNodeOperator, 0.2 ether); // incentive for nodeOperator from NonExitPenalty caps at 0.2 ether
        assertEq(toTreasury, expectedAppliedPenalty - 0.2 ether); // treasury gets excess penalty if node operator delays too long
        assertEq(toTnft, 3.750000000000000000 ether);
        assertEq(toBnft, 0); // BNFT has been fully penalized for not exiting
    }

    function test_markExitedFails() public {
        uint256[] memory validatorIds = new uint256[](1);
        uint32[] memory exitTimestamps = new uint32[](2);
        startHoax(alice);
        vm.expectRevert("Check params");
        managerInstance.processNodeExit(validatorIds, exitTimestamps);
    }

    function test_getFullWithdrawalPayoutsWorksWithNonExitPenaltyCorrectly3() public {
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = bidId[0];
        uint32[] memory exitTimestamps = new uint32[](1);
        exitTimestamps[0] = uint32(block.timestamp) + (1 + 28 * 86400);
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorIds[0]);

        hoax(TNFTInstance.ownerOf(validatorIds[0]));
        managerInstance.sendExitRequest(validatorIds[0]);

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
        uint256 expectedTreasuryPayout = baseTreasuryPayout + baseNodeOperatorPayout + (nonExitPenalty - 0.2 ether);

        uint256 stakingRewards = 1 ether;
        vm.deal(etherfiNode, 32 ether + stakingRewards);
        (
            uint256 toNodeOperator,
            uint256 toTnft,
            uint256 toBnft,
            uint256 toTreasury
        ) = managerInstance.getFullWithdrawalPayouts(validatorIds[0]);
        assertEq(toNodeOperator, 0.2 ether);
        assertEq(toTreasury, expectedTreasuryPayout);
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
        managerInstance.sendExitRequest(validatorIds[0]);

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
        uint256 expectedTreasuryPayout = baseTreasuryPayout + baseNodeOperatorPayout + (nonExitPenalty - 0.2 ether);

        (
            uint256 toNodeOperator,
            uint256 toTnft,
            uint256 toBnft,
            uint256 toTreasury
        ) = managerInstance.getFullWithdrawalPayouts(validatorIds[0]);
        assertEq(toNodeOperator, 0.2 ether);
        assertEq(toTreasury, expectedTreasuryPayout);
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
        vm.expectRevert(EtherFiNodesManager.ValidatorNotLive.selector);
        managerInstance.sendExitRequest(validatorIds[0]);
    }

    function test_ExitTimestampBeforeExitRequestLeadsToZeroNonExitPenalty() public {
        uint256[] memory validatorIds = new uint256[](1);
        uint32[] memory exitTimestamps = new uint32[](1);

        validatorIds[0] = bidId[0];

        vm.prank(TNFTInstance.ownerOf(validatorIds[0]));
        managerInstance.sendExitRequest(validatorIds[0]);

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
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorId);

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
        // - slashing penalty [0, 0.5 ether] is paid by the B-NFT holder
        {
            uint256 beaconBalance = 31.5 ether;

            (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, beaconBalance);
            assertEq(toNodeOperator, 0 ether);
            assertEq(toTreasury, 0 ether);
            assertEq(toTnft, 30 ether);
            assertEq(toBnft, 1.5 ether);
        }

        // (Validator 'active_slashed', slashing penalty in CL = 1 ether)
        // - 0.5 ether of B-NFT holder is used as the insurance claim
        // - While T-NFT receives 29.5 ether, the insurance will convert the loss 0.5 ether (manually)
        {
            uint256 beaconBalance = 31 ether;

            (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, beaconBalance);
            assertEq(toNodeOperator, 0 ether);
            assertEq(toTreasury, 0 ether);
            assertEq(toTnft, 29.5 ether);
            assertEq(toBnft, 1.5 ether);
        }

        {
            uint256 beaconBalance = 30 ether;

            (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, beaconBalance);
            assertEq(toNodeOperator, 0 ether);
            assertEq(toTreasury, 0 ether);
            assertEq(toTnft, 28.5 ether);
            assertEq(toBnft, 1.5 ether);
        }


        // The worst-case, 32 ether is all slashed!
        {
            uint256 beaconBalance = 0 ether;

            (toNodeOperator, toTnft, toBnft, toTreasury) = managerInstance.calculateTVL(validatorId, beaconBalance);
            assertEq(toNodeOperator, 0 ether);
            assertEq(toTreasury, 0 ether);
            assertEq(toTnft, 0 ether);
            assertEq(toBnft, 0 ether);
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
        managerInstance.fullWithdrawBatch(validatorIds); // Full Withdrawal!

        assertEq(address(nodeOperator).balance, nodeOperatorBalance + tvls[0]);
        assertEq(address(dan).balance, tNftStakerBalance + tvls[1]);
        assertEq(address(staker).balance, bnftStakerBalance + tvls[2]);
        assertEq(address(treasuryInstance).balance, treasuryBalance + tvls[3]);
    }

    function test_withdrawFundsFailsWhenReceiverConsumedTooMuchGas() public {
        uint256 validatorId = bidId[0];
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorId);
        vm.deal(address(etherfiNode), 3 ether); // need to give node some eth because it no longer has auction revenue

        address nodeOperator = 0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931;
        address staker = 0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf;
        
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

}
