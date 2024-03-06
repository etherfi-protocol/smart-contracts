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

        vm.deal(address(safe1.eigenPod()), 1 ether);
        vm.deal(address(safe2.eigenPod()), 2 ether);

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
        managerInstance.batchQueueRestakedWithdrawal(validatorIds);

        // both safes should have funds queued for withdrawal
        (_withdrawalSafe, _eigenPod, _delayedWithdrawalRouter) = safe1.splitBalanceInExecutionLayer();
        assertEq(_withdrawalSafe, 0 ether);
        assertEq(_eigenPod, 0 ether);
        assertEq(_delayedWithdrawalRouter, 1 ether);
        (_withdrawalSafe, _eigenPod, _delayedWithdrawalRouter) = safe2.splitBalanceInExecutionLayer();
        assertEq(_withdrawalSafe, 0 ether);
        assertEq(_eigenPod, 0 ether);
        assertEq(_delayedWithdrawalRouter, 2 ether);

    }

    function test_claimMixedSafeAndPodFunds() public {

        initializeTestingFork(MAINNET_FORK);

        uint256 bidId = depositAndRegisterValidator(true);
        safeInstance = EtherFiNode(payable(managerInstance.etherfiNodeAddress(bidId)));

        // simulate 1 eth of already claimed staking rewards and 1 eth of unclaimed restaked rewards
        vm.deal(address(safeInstance.eigenPod()), 1 ether);
        vm.deal(address(safeInstance), 1 ether);

        assertEq(address(safeInstance).balance, 1 ether);
        assertEq(address(safeInstance.eigenPod()).balance, 1 ether);

        // claim the restaked rewards
        // safeInstance.queueRestakedWithdrawal();
        vm.prank(admin);
        managerInstance.callEigenPod(bidId, abi.encodeWithSignature("withdrawBeforeRestaking()"));
        vm.roll(block.number + (50400) + 1);
        safeInstance.claimQueuedWithdrawals(1, false);

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
        safeInstance.claimQueuedWithdrawals(1, false);
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
        initializeTestingFork(MAINNET_FORK);

        uint256 validatorId = depositAndRegisterValidator(true);
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
        safeInstance.claimQueuedWithdrawals(1, false);
        assertEq(address(safeInstance).balance, 0 ether);
        assertEq(address(safeInstance.eigenPod()).balance, 0.5 ether);

        // wait and claim
        vm.roll(block.number + (50400) + 1);
        safeInstance.claimQueuedWithdrawals(1, false);
        assertEq(address(safeInstance).balance, 1 ether);
        assertEq(address(safeInstance.eigenPod()).balance, 0.5 ether);

        // now queue up multiple different rewards (0.5 ether remain in pod from previous step)
        safeInstance.queueRestakedWithdrawal();
        vm.deal(address(safeInstance.eigenPod()), 0.5 ether);
        safeInstance.queueRestakedWithdrawal();
        vm.deal(address(safeInstance.eigenPod()), 0.5 ether);
        safeInstance.queueRestakedWithdrawal();

        assertEq(address(safeInstance.eigenPod()).balance, 0 ether);

        IDelayedWithdrawalRouter.DelayedWithdrawal[] memory unclaimedWithdrawals = managerInstance.delayedWithdrawalRouter().getUserDelayedWithdrawals(address(safeInstance));
        assertEq(unclaimedWithdrawals.length, 3);

        // wait but only claim 2 of the 3 queued withdrawals
        // The ability to claim a subset of outstanding withdrawals is to avoid a denial of service
        // attack in which the attacker creates too many withdrawals for us to process in 1 tx
        vm.roll(block.number + (50400) + 1);
        safeInstance.claimQueuedWithdrawals(2, false);


        unclaimedWithdrawals = managerInstance.delayedWithdrawalRouter().getUserDelayedWithdrawals(address(safeInstance));
        assertEq(unclaimedWithdrawals.length, 1);
        assertEq(address(safeInstance.eigenPod()).balance, 0 ether);
        assertEq(address(safeInstance).balance, 2 ether);
    }

    function test_FullWithdrawWhenBalanceBelow16EthFails() public {
        initializeTestingFork(MAINNET_FORK);

        // create a restaked validator
        uint256 validatorId = depositAndRegisterValidator(true);
        EtherFiNode node = EtherFiNode(payable(managerInstance.etherfiNodeAddress(validatorId)));

        // Marked as EXITED
        uint256[] memory validatorIds = new uint256[](1);
        uint32[] memory exitRequestTimestamps = new uint32[](1);
        validatorIds[0] = validatorId;
        exitRequestTimestamps[0] = uint32(block.timestamp);
        
        vm.deal(node.eigenPod(), 16 ether - 1);

        vm.prank(alice); // alice is admin
        managerInstance.processNodeExit(validatorIds, exitRequestTimestamps);

        IDelayedWithdrawalRouter delayedWithdrawalRouter = IDelayedWithdrawalRouter(IEtherFiNodesManager(managerInstance).delayedWithdrawalRouter());
        uint256 delayBlocks = delayedWithdrawalRouter.withdrawalDelayBlocks();
        vm.roll(block.number + (delayBlocks) + 1);

        vm.expectRevert("INSUFFICIENT_BALANCE");
        managerInstance.fullWithdraw(validatorId);
    }

    function test_canClaimRestakedFullWithdrawal() public {
        initializeTestingFork(MAINNET_FORK);

        // create a restaked validator
        uint256 validatorId = depositAndRegisterValidator(true);
        EtherFiNode node = EtherFiNode(payable(managerInstance.etherfiNodeAddress(validatorId)));

        // Marked as EXITED
        uint256[] memory validatorIds = new uint256[](1);
        uint32[] memory exitRequestTimestamps = new uint32[](1);
        validatorIds[0] = validatorId;
        exitRequestTimestamps[0] = uint32(block.timestamp);
        vm.deal(node.eigenPod(), 32 ether);
        vm.prank(alice); // alice is admin
        managerInstance.processNodeExit(validatorIds, exitRequestTimestamps);
        IDelayedWithdrawalRouter.DelayedWithdrawal[] memory unclaimedWithdrawals = managerInstance.delayedWithdrawalRouter().getUserDelayedWithdrawals(address(node));
        assertEq(unclaimedWithdrawals.length, 1);
        assertEq(unclaimedWithdrawals[0].amount, uint224(32 ether));

        // not enough time has passed
        assertEq(node.canClaimRestakedFullWithdrawal(), false);

        // attempting withdraw should fail
        vm.expectRevert("PENDING_WITHDRAWALS");
        managerInstance.fullWithdraw(validatorId);

        // wait the queueing period
        IDelayedWithdrawalRouter delayedWithdrawalRouter = IDelayedWithdrawalRouter(IEtherFiNodesManager(managerInstance).delayedWithdrawalRouter());
        uint256 delayBlocks = delayedWithdrawalRouter.withdrawalDelayBlocks();
        vm.roll(block.number + (delayBlocks) + 1);

        // should be claimable now
        assertEq(node.canClaimRestakedFullWithdrawal(), true);

        // attempting withdraw should now succeed
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
        managerInstance.processNodeExit(validatorIds, exitRequestTimestamps);
        IDelayedWithdrawalRouter.DelayedWithdrawal[] memory unclaimedWithdrawals = managerInstance.delayedWithdrawalRouter().getUserDelayedWithdrawals(address(safeInstance));
        assertEq(unclaimedWithdrawals.length, 1);
        assertEq(unclaimedWithdrawals[0].amount, uint224(32 ether));

        // fail because we have not processed the queued withdrawal of the funds from the pod
        // because not enough time has passed to claim them
        vm.expectRevert("PENDING_WITHDRAWALS");
        managerInstance.fullWithdraw(validatorIds[0]);

        // wait some time
        vm.roll(block.number + (50400) + 1);

        assertEq(managerInstance.getUnusedWithdrawalSafesLength(), 0);

        // try again. FullWithdraw will automatically attempt to claim queuedWithdrawals
        managerInstance.fullWithdraw(validatorIds[0]);
        assertEq(address(safeInstance).balance, 0);

        // safe should have been automatically recycled
        assertEq(managerInstance.getUnusedWithdrawalSafesLength(), 1);
        assertEq(uint256(managerInstance.phase(validatorIds[0])), uint256(IEtherFiNode.VALIDATOR_PHASE.FULLY_WITHDRAWN));
        assertEq(safeInstance.isRestakingEnabled(), false);
        assertEq(safeInstance.restakingObservedExitBlock(), 0);
    }

    function test_withdrawableBalanceInExecutionLayer() public {
        initializeTestingFork(MAINNET_FORK);

        uint256 validatorId = depositAndRegisterValidator(true);
        safeInstance = EtherFiNode(payable(managerInstance.etherfiNodeAddress(validatorId)));

        assertEq(safeInstance.totalBalanceInExecutionLayer(), 0 ether);
        assertEq(safeInstance.withdrawableBalanceInExecutionLayer(), 0 ether);

        // send some funds to the pod
        vm.deal(safeInstance.eigenPod(), 1 ether);
        assertEq(safeInstance.totalBalanceInExecutionLayer(), 1 ether);
        assertEq(safeInstance.withdrawableBalanceInExecutionLayer(), 0 ether);

        // queue withdrawal
        safeInstance.queueRestakedWithdrawal();
        assertEq(safeInstance.totalBalanceInExecutionLayer(), 1 ether);
        assertEq(safeInstance.withdrawableBalanceInExecutionLayer(), 0 ether);

        // more eth to pod
        vm.deal(safeInstance.eigenPod(), 1 ether);
        assertEq(safeInstance.totalBalanceInExecutionLayer(), 2 ether);
        assertEq(safeInstance.withdrawableBalanceInExecutionLayer(), 0 ether);

        // wait so queued withdrawal is claimable
        vm.roll(block.number + (50400) + 1);
        assertEq(safeInstance.totalBalanceInExecutionLayer(), 2 ether);
        assertEq(safeInstance.withdrawableBalanceInExecutionLayer(), 1 ether);

        // claim that withdrawal
        safeInstance.claimQueuedWithdrawals(1, false);
        assertEq(safeInstance.totalBalanceInExecutionLayer(), 2 ether);
        assertEq(address(safeInstance).balance, 1 ether);
        assertEq(safeInstance.withdrawableBalanceInExecutionLayer(), 1 ether);

        // queue multiple but only some that are claimable
        safeInstance.queueRestakedWithdrawal();
        vm.deal(safeInstance.eigenPod(), 1 ether);
        safeInstance.queueRestakedWithdrawal();
        vm.roll(block.number + (50400) + 1);
        vm.deal(safeInstance.eigenPod(), 1 ether);
        safeInstance.queueRestakedWithdrawal();
        assertEq(safeInstance.withdrawableBalanceInExecutionLayer(), 3 ether);
        assertEq(safeInstance.totalBalanceInExecutionLayer(), 4 ether);
    }

    function test_restakedAttackerCantBlockWithdraw() public {
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
        managerInstance.processNodeExit(validatorIds, exitRequestTimestamps);
        IDelayedWithdrawalRouter.DelayedWithdrawal[] memory unclaimedWithdrawals = managerInstance.delayedWithdrawalRouter().getUserDelayedWithdrawals(address(safeInstance));
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

        unclaimedWithdrawals = managerInstance.delayedWithdrawalRouter().getUserDelayedWithdrawals(address(safeInstance));
        assertEq(unclaimedWithdrawals.length, 6);

        // wait some time so claims are claimable
        vm.roll(block.number + (50400) + 1);

        // TODO(Dave): 5 picked here because that's how many claims I set the manager contract to attempt. We can tune thi
        safeInstance.claimQueuedWithdrawals(5, false);
        unclaimedWithdrawals = managerInstance.delayedWithdrawalRouter().getUserDelayedWithdrawals(address(safeInstance));
        assertEq(unclaimedWithdrawals.length, 1);

        // shoud not be allowed to partial withdraw since node is exited
        // In this case it fails because of the balance check right before the state check
        vm.expectRevert("NOT_LIVE");
        managerInstance.partialWithdraw(validatorId);

        // attacker sends more eth to pod that will not be able to be able to be withdrawn immediately
        vm.deal(safeInstance.eigenPod(), 1 ether);

        // This should succeed even though there are still some unclaimed withdrawals
        // this is because we only enforce that all withdrawals before the observed exit of the node have completed
        managerInstance.fullWithdraw(validatorIds[0]);
        assertEq(address(safeInstance).balance, 0);
        assertEq(uint256(managerInstance.phase(validatorIds[0])), uint256(IEtherFiNode.VALIDATOR_PHASE.FULLY_WITHDRAWN));
    }

    function testFullWithdrawBurnsTNFT() public {
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
        managerInstance.fullWithdraw(validatorId);

        // Marked as EXITED
        // should also have queued up the current balance to via DelayedWithdrawalRouter
        managerInstance.processNodeExit(validatorIds, exitRequestTimestamps);
        IDelayedWithdrawalRouter.DelayedWithdrawal[] memory unclaimedWithdrawals = managerInstance.delayedWithdrawalRouter().getUserDelayedWithdrawals(address(safeInstance));
        assertEq(unclaimedWithdrawals.length, 1);
        assertEq(unclaimedWithdrawals[0].amount, uint224(32 ether));

        // wait some time so claims are claimable
        vm.roll(block.number + (50400) + 1);

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
        IEtherFiNode(etherFiNode).processNodeExit();

        vm.expectRevert("NOT_ADMIN");
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

        vm.deal(etherfiNode, 16.0 ether);
        vm.expectRevert(
            "MUST_EXIT"
        );
        managerInstance.partialWithdraw(bidId[0]);
    }

    function test_partialWithdrawFails() public {
        address etherfiNode = managerInstance.etherfiNodeAddress(bidId[0]);

        vm.deal(etherfiNode, 4 ether);

        vm.expectRevert(
            "NOT_ADMIN"
        );
        vm.prank(bob);
        managerInstance.markBeingSlashed(bidId);

        hoax(alice);
        managerInstance.markBeingSlashed(bidId);
        vm.expectRevert(
            "NOT_LIVE"
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

    function test_partialWithdrawAfterExitRequest() public {
        address nodeOperator = 0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931;
        address staker = 0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf;
        address etherfiNode = managerInstance.etherfiNodeAddress(bidId[0]);

        // Simulate the rewards distribution from the beacon chain
        vm.deal(etherfiNode, address(etherfiNode).balance + 1 ether);

        // Send Exit Request
        hoax(TNFTInstance.ownerOf(bidId[0]));
        managerInstance.batchSendExitRequest(_to_uint256_array(bidId[0]));

        vm.expectRevert("PENDING_EXIT_REQUEST");
        managerInstance.partialWithdraw(bidId[0]);
    }

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
        managerInstance.batchSendExitRequest(_to_uint256_array(validatorIds[0]));

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
        vm.expectRevert("NOT_LIVE");
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
        vm.expectRevert("MUST_EXIT");
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

    function test_mainnet_partialWithdraw_after_upgrade() public {
        initializeRealisticFork(MAINNET_FORK);

        _upgrade_etherfi_nodes_manager_contract();
        _upgrade_etherfi_node_contract();

        uint256 validatorId = 2285;
        managerInstance.batchQueueRestakedWithdrawal(_to_uint256_array(validatorId));

        _moveClock(7 * 7200);

        managerInstance.partialWithdraw(validatorId);

        hoax(TNFTInstance.ownerOf(validatorId));
        managerInstance.batchSendExitRequest(_to_uint256_array(validatorId));

        vm.expectRevert("PENDING_EXIT_REQUEST");
        managerInstance.partialWithdraw(validatorId);

        _transferTo(managerInstance.etherfiNodeAddress(validatorId), 16 ether);

        uint256[] memory validatorIds = new uint256[](1);
        uint32[] memory exitTimestamps = new uint32[](1);
        validatorIds[0] = validatorId;
        exitTimestamps[0] = uint32(block.timestamp);
        hoax(managerInstance.owner());
        managerInstance.processNodeExit(validatorIds, exitTimestamps);

        managerInstance.fullWithdraw(validatorId);
    }

    function test_mainnet_launch_validator_with_reserved_version0_safe() public {
        initializeRealisticFork(MAINNET_FORK);

        managerInstance.createUnusedWithdrawalSafe(1, true);

        _upgrade_etherfi_nodes_manager_contract();
        _upgrade_etherfi_node_contract();
        _upgrade_staking_manager_contract();

        address etherFiNode = managerInstance.unusedWithdrawalSafes(managerInstance.getUnusedWithdrawalSafesLength() - 1);

        assertEq(IEtherFiNode(etherFiNode).version(), 0);
        assertEq(IEtherFiNode(etherFiNode).numAssociatedValidators(), 0);

        uint256[] memory newValidatorIds = launch_validator(1, 0, false);
        address newEtherFiNode = managerInstance.etherfiNodeAddress(newValidatorIds[0]);

        assertEq(etherFiNode, newEtherFiNode);
        assertEq(IEtherFiNode(newEtherFiNode).version(), 1);
        assertEq(IEtherFiNode(newEtherFiNode).numAssociatedValidators(), 1);        
    }

    function test_mainnet_launch_validator_with_reserved_version1_safe() public {
        initializeRealisticFork(MAINNET_FORK);

        _upgrade_etherfi_nodes_manager_contract();
        _upgrade_etherfi_node_contract();
        _upgrade_staking_manager_contract();

        managerInstance.createUnusedWithdrawalSafe(1, true);
        address etherFiNode = managerInstance.unusedWithdrawalSafes(managerInstance.getUnusedWithdrawalSafesLength() - 1);

        assertEq(IEtherFiNode(etherFiNode).version(), 1);
        assertEq(IEtherFiNode(etherFiNode).numAssociatedValidators(), 0);

        uint256[] memory newValidatorIds = launch_validator(1, 0, false);
        address newEtherFiNode = managerInstance.etherfiNodeAddress(newValidatorIds[0]);

        assertEq(etherFiNode, newEtherFiNode);
        assertEq(IEtherFiNode(newEtherFiNode).version(), 1);
        assertEq(IEtherFiNode(newEtherFiNode).numAssociatedValidators(), 1);        
    }

    function test_mainnet_launch_validator_with_version0_safe() public {
        initializeRealisticFork(MAINNET_FORK);

        managerInstance.createUnusedWithdrawalSafe(1, true);

        _upgrade_etherfi_nodes_manager_contract();
        _upgrade_etherfi_node_contract();
        _upgrade_staking_manager_contract();

        uint256 validatorId = 2285;
        address etherFiNode = managerInstance.etherfiNodeAddress(validatorId);

        assertEq(IEtherFiNode(etherFiNode).version(), 0);
        assertEq(IEtherFiNode(etherFiNode).numAssociatedValidators(), 1);

        uint256[] memory newValidatorIds = launch_validator(1, validatorId, false, BNFTInstance.ownerOf(validatorId), auctionInstance.getBidOwner(validatorId));
        address newEtherFiNode = managerInstance.etherfiNodeAddress(newValidatorIds[0]);

        assertEq(etherFiNode, newEtherFiNode);
        assertEq(IEtherFiNode(etherFiNode).version(), 1);
        assertEq(IEtherFiNode(etherFiNode).numAssociatedValidators(), 2);
    }

    function test_ExitOneAmongMultipleValidators() public {
        uint256[] memory validatorIds = launch_validator(1, 0, false);
        uint256 validatorId = validatorIds[0];
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorId);

        assertTrue(managerInstance.phase(validatorIds[0]) == IEtherFiNode.VALIDATOR_PHASE.LIVE);
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 1);

        // launch 3 more validators
        uint256[] memory newValidatorIds = launch_validator(3, validatorId, false);
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 4);

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

        managerInstance.fullWithdraw(validatorToExit);
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 3);

        assertEq(managerInstance.etherfiNodeAddress(validatorToExit), address(0)); 
        for (uint256 i = 0; i < IEtherFiNode(etherfiNode).numAssociatedValidators(); i++) {
            uint256 valId = IEtherFiNode(etherfiNode).associatedValidatorIds(i);
            address safe = managerInstance.etherfiNodeAddress(valId);

            assertEq(safe, etherfiNode);
        }
    }

    function test_ForcedPartialWithdrawal_succeeds() public {
        uint256[] memory validatorIds = launch_validator(1, 0, false);
        uint256 validatorId = validatorIds[0];
        address etherfiNode = managerInstance.etherfiNodeAddress(validatorId);

        assertTrue(managerInstance.phase(validatorIds[0]) == IEtherFiNode.VALIDATOR_PHASE.LIVE);
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 1);

        // launch 3 more validators
        uint256[] memory newValidatorIds = launch_validator(3, validatorId, false);
        assertEq(IEtherFiNode(etherfiNode).numAssociatedValidators(), 4);

        // 1 ether as staking rewards
        _transferTo(etherfiNode, 1 ether);

        uint256[] memory validatorIdsToExit = new uint256[](1);
        uint32[] memory exitTimestamps = new uint32[](1);
        exitTimestamps[0] = uint32(block.timestamp);

        // Exit 1 among 4
        validatorIdsToExit[0] = newValidatorIds[0];
        _transferTo(etherfiNode, 16 ether);

        vm.expectRevert("NOT_ADMIN");
        managerInstance.forcePartialWithdraw(validatorId);

        vm.prank(alice);
        managerInstance.forcePartialWithdraw(validatorId);
    }

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
        vm.expectRevert("MUST_EXIT");
        managerInstance.partialWithdraw(validatorId);

        hoax(managerInstance.owner());
        managerInstance.processNodeExit(validatorIdsToExit, exitTimestamps);

        managerInstance.fullWithdraw(validatorIdsToExit[0]);
    }

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

        vm.expectRevert("ALREADY_ASKED");
        managerInstance.batchSendExitRequest(_to_uint256_array(bidId[0]));
    }

    // Zellic-Audit-Issue 2
    function test_RevertingExitRequest_WhenThereIsNoExitRequest_fails() public {
        vm.startPrank(TNFTInstance.ownerOf(bidId[0]));

        vm.expectRevert("NOT_ASKED");
        managerInstance.batchRevertExitRequest(_to_uint256_array(bidId[0]));

        managerInstance.batchSendExitRequest(_to_uint256_array(bidId[0]));

        managerInstance.batchRevertExitRequest(_to_uint256_array(bidId[0]));
    }

}
