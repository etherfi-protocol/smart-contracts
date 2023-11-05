// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/EtherFiNode.sol";

import "forge-std/console2.sol";

contract EtherFiNodesManagerTest is TestSetup {
    address etherFiNode;
    uint256[] bidId;
    EtherFiNode safeInstance;

    function setUp() public {
        setUpTests();

        vm.expectRevert("Initializable: contract is already initialized");
        vm.prank(owner);
        managerImplementation.initialize(
            address(treasuryInstance),
            address(auctionInstance),
            address(stakingManagerInstance),
            address(TNFTInstance),
            address(BNFTInstance)
        );
        
        vm.prank(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 5);

        hoax(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931);
        bidId = auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);

        startHoax(0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf);

        uint256[] memory bidIdArray = new uint256[](1);
        bidIdArray[0] = bidId[0];

        stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(
            bidIdArray,
            false
        );

        etherFiNode = managerInstance.etherfiNodeAddress(bidId[0]);

        assertTrue(
            managerInstance.phase(bidId[0]) ==
                IEtherFiNode.VALIDATOR_PHASE.STAKE_DEPOSITED
        );

        IStakingManager.DepositData[]
            memory depositDataArray = new IStakingManager.DepositData[](1);

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

        stakingManagerInstance.batchRegisterValidators(zeroRoot, bidId, depositDataArray);
        vm.stopPrank();

        assertTrue(
            managerInstance.phase(bidId[0]) == IEtherFiNode.VALIDATOR_PHASE.LIVE
        );

        safeInstance = EtherFiNode(payable(etherFiNode));
    }

    function test_SetStakingRewardsSplit() public {
        vm.expectRevert("Not admin");
        vm.prank(owner);
        managerInstance.setStakingRewardsSplit(100000, 100000, 400000, 400000);

        (uint64 treasury, uint64 nodeOperator, uint64 tnft, uint64 bnft) = managerInstance.stakingRewardsSplit();
        assertEq(treasury, 50000);
        assertEq(nodeOperator, 50000);
        assertEq(tnft, 815625);
        assertEq(bnft, 84375);

        vm.prank(alice);
        managerInstance.setStakingRewardsSplit(100000, 100000, 400000, 400000);

        (treasury, nodeOperator, tnft, bnft) = managerInstance.stakingRewardsSplit();
        assertEq(treasury, 100000);
        assertEq(nodeOperator, 100000);
        assertEq(tnft, 400000);
        assertEq(bnft, 400000);
    }

    function test_SetNonExitPenaltyPrincipal() public {
        vm.expectRevert("Not admin");
        vm.prank(owner);
        managerInstance.setNonExitPenaltyPrincipal(2 ether);

        assertEq(managerInstance.nonExitPenaltyPrincipal(), 1 ether);

        vm.prank(alice);
        managerInstance.setNonExitPenaltyPrincipal(2 ether);

        assertEq(managerInstance.nonExitPenaltyPrincipal(), 2 ether);
    }

    function test_SetNonExitPenaltyDailyRate() public {
        vm.expectRevert("Not admin");
        vm.prank(owner);
        managerInstance.setNonExitPenaltyDailyRate(2 ether);

        vm.prank(alice);
        managerInstance.setNonExitPenaltyDailyRate(5);
        assertEq(managerInstance.nonExitPenaltyDailyRate(), 5);
    }

    function test_SetEtherFiNodePhaseRevertsOnIncorrectCaller() public {
        vm.expectRevert("Not staking manager");
        vm.prank(owner);
        managerInstance.setEtherFiNodePhase(bidId[0], IEtherFiNode.VALIDATOR_PHASE.CANCELLED);
    }

    function test_setEtherFiNodeIpfsHashForEncryptedValidatorKeyRevertsOnIncorrectCaller() public {
        vm.expectRevert("Not staking manager");
        vm.prank(owner);
        managerInstance.setEtherFiNodeIpfsHashForEncryptedValidatorKey(bidId[0], "_ipfsHash");
    }

    function test_RegisterEtherFiNodeRevertsOnIncorrectCaller() public {
        vm.expectRevert("Not staking manager");
        vm.prank(owner);
        managerInstance.registerEtherFiNode(bidId[0], false);
    }

    function test_RegisterEtherFiNodeRevertsIfAlreadyRegistered() public {
        // Node is registered in setup
        vm.expectRevert(EtherFiNodesManager.AlreadyInstalled.selector);
        vm.prank(address(stakingManagerInstance));
        managerInstance.registerEtherFiNode(bidId[0], false);
    }

    function test_UnregisterEtherFiNodeRevertsOnIncorrectCaller() public {
        vm.expectRevert("Not staking manager");
        vm.prank(owner);
        managerInstance.unregisterEtherFiNode(bidId[0]);
    }

    function test_UnregisterEtherFiNodeRevertsIfAlreadyUnregistered() public {
        vm.startPrank(address(stakingManagerInstance));

        // need to put the node in a terminal state before it can be unregistered
        managerInstance.setEtherFiNodePhase(bidId[0], IEtherFiNode.VALIDATOR_PHASE.EXITED);
        managerInstance.setEtherFiNodePhase(bidId[0], IEtherFiNode.VALIDATOR_PHASE.FULLY_WITHDRAWN);

        managerInstance.unregisterEtherFiNode(bidId[0]);

        vm.expectRevert(EtherFiNodesManager.NotInstalled.selector);
        managerInstance.unregisterEtherFiNode(bidId[0]);
    }

    function test_CantResetNodeWithBalance() public {
        vm.startPrank(address(stakingManagerInstance));
        uint256 validatorId = bidId[0];

        // need to put the node in a terminal state before it can be unregistered
        managerInstance.setEtherFiNodePhase(validatorId, IEtherFiNode.VALIDATOR_PHASE.EXITED);
        managerInstance.setEtherFiNodePhase(validatorId, IEtherFiNode.VALIDATOR_PHASE.FULLY_WITHDRAWN);

        // simulate not fully withdrawn funds
        vm.deal(managerInstance.etherfiNodeAddress(validatorId), 1 ether);
        vm.stopPrank();

        uint256[] memory validatorsToReset = new uint256[](1);
        validatorsToReset[0] = validatorId;
        vm.prank(alice);
        vm.expectRevert(EtherFiNodesManager.CannotResetNodeWithBalance.selector);
        managerInstance.resetWithdrawalSafes(validatorsToReset);
    }

    function test_CantResetRestakedNodeWithBalance() public {
        initializeTestingFork(TESTNET_FORK);

        uint256 validatorId = depositAndRegisterValidator(true);
        address node = managerInstance.etherfiNodeAddress(validatorId);
        vm.prank(address(managerInstance));
        IEtherFiNode(node).setIsRestakingEnabled(true);
        IEtherFiNode(node).createEigenPod();

        vm.startPrank(address(stakingManagerInstance));

        // need to put the node in a terminal state before it can be unregistered
        managerInstance.setEtherFiNodePhase(validatorId, IEtherFiNode.VALIDATOR_PHASE.EXITED);
        managerInstance.setEtherFiNodePhase(validatorId, IEtherFiNode.VALIDATOR_PHASE.FULLY_WITHDRAWN);

        // simulate funds still in eigenPod
        vm.deal(IEtherFiNode(node).eigenPod(), 1 ether);
        vm.stopPrank();

        uint256[] memory validatorsToReset = new uint256[](1);
        validatorsToReset[0] = validatorId;
        vm.prank(alice);
        vm.expectRevert(EtherFiNodesManager.CannotResetNodeWithBalance.selector);
        managerInstance.resetWithdrawalSafes(validatorsToReset);

        // move funds to the delayed withdrawal router
        IEtherFiNode(node).queueRestakedWithdrawal();

        // should still fail with the funds no longer in the pod
        vm.prank(alice);
        vm.expectRevert(EtherFiNodesManager.CannotResetNodeWithBalance.selector);
        managerInstance.resetWithdrawalSafes(validatorsToReset);
        assertEq(IEtherFiNode(node).eigenPod().balance, 0);
    }

    function test_CreateEtherFiNode() public {
        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            5
        );

        hoax(alice);
        bidId = auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);

        assertEq(managerInstance.etherfiNodeAddress(bidId[0]), address(0));

        hoax(alice);
        uint256[] memory processedBids = stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(bidId, false);

        address node = managerInstance.etherfiNodeAddress(processedBids[0]);
        assert(node != address(0));
    }

    function test_RegisterEtherFiNode() public {
        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(
            _ipfsHash,
            5
        );

        hoax(alice);
        bidId = auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);

        assertEq(managerInstance.etherfiNodeAddress(bidId[0]), address(0));

        hoax(alice);
        uint256[] memory processedBids = stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(bidId, false);

        address node = managerInstance.etherfiNodeAddress(processedBids[0]);
        assert(node != address(0));

    }

    function test_RegisterEtherFiNodeReusesAvailableSafes() public {
        vm.prank(alice);
        nodeOperatorManagerInstance.registerNodeOperator(_ipfsHash, 5);

        assertEq(managerInstance.getUnusedWithdrawalSafesLength(), 0);

        // create bid with no matching deposit yet
        hoax(alice);
        bidId = auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
        assertEq(managerInstance.etherfiNodeAddress(bidId[0]), address(0));
        assertEq(managerInstance.getUnusedWithdrawalSafesLength(), 0);

        // premake a safe
        address[] memory premadeSafe = managerInstance.createUnusedWithdrawalSafe(1, false);
        assertEq(managerInstance.getUnusedWithdrawalSafesLength(), 1);
        assertEq(managerInstance.unusedWithdrawalSafes(0), premadeSafe[0]);

        // deposit
        hoax(alice);
        uint256[] memory processedBids = stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(bidId, false);

        // assigned safe should be the premade one
        address node = managerInstance.etherfiNodeAddress(processedBids[0]);
        assert(node != address(0));
        assertEq(managerInstance.getUnusedWithdrawalSafesLength(), 0);

        // push another safe to the stack
        address[] memory safe2 = managerInstance.createUnusedWithdrawalSafe(1, false);
        assertEq(managerInstance.getUnusedWithdrawalSafesLength(), 1);

        // recycle the first safe
        vm.prank(alice);
        stakingManagerInstance.batchCancelDeposit(processedBids);
        assertEq(managerInstance.getUnusedWithdrawalSafesLength(), 2);

        // original premade safe should be on top of the stack after being recycled
        assertEq(managerInstance.unusedWithdrawalSafes(1), premadeSafe[0]);
        assertEq(managerInstance.unusedWithdrawalSafes(0), safe2[0]);
    }

    function test_createMultipleUnusedWithdrawalSafes() public {

        assertEq(managerInstance.getUnusedWithdrawalSafesLength(), 0);
        address[] memory safes = managerInstance.createUnusedWithdrawalSafe(10, false);
        assertEq(managerInstance.getUnusedWithdrawalSafesLength(), 10);
        safes = managerInstance.createUnusedWithdrawalSafe(5, false);
        assertEq(managerInstance.getUnusedWithdrawalSafesLength(), 15);
    }


    // TODO(Dave): Remaining withdrawal-safe-pool Tests
    // 1. add restaking to previously non-restaking node
    // 2. restaking with previously restaked node
    // 3. normal mode in previously restaked

    function test_UnregisterEtherFiNode() public {
        address node = managerInstance.etherfiNodeAddress(bidId[0]);
        assert(node != address(0));

        vm.startPrank(address(stakingManagerInstance));

        vm.expectRevert("withdrawal safe still in use");
        managerInstance.unregisterEtherFiNode(bidId[0]);

        // need to put the node in a terminal state before it can be unregistered
        managerInstance.setEtherFiNodePhase(bidId[0], IEtherFiNode.VALIDATOR_PHASE.EXITED);
        managerInstance.setEtherFiNodePhase(bidId[0], IEtherFiNode.VALIDATOR_PHASE.FULLY_WITHDRAWN);

        managerInstance.unregisterEtherFiNode(bidId[0]);

        node = managerInstance.etherfiNodeAddress(bidId[0]);
        assertEq(node, address(0));
    }

    function test_SendExitRequestWorksCorrectly() public {
        assertEq(managerInstance.isExitRequested(bidId[0]), false);

        hoax(alice);
        vm.expectRevert(EtherFiNodesManager.NotTnftOwner.selector);
        managerInstance.sendExitRequest(bidId[0]);

        hoax(0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf);
        managerInstance.sendExitRequest(bidId[0]);

        assertEq(managerInstance.isExitRequested(bidId[0]), true);

        uint256[] memory ids = new uint256[](1);
        ids[0] = bidId[0];
        address etherFiNode = managerInstance.etherfiNodeAddress(bidId[0]);
        uint32 exitRequestTimestamp = IEtherFiNode(etherFiNode).exitRequestTimestamp();

        assertEq(IEtherFiNode(etherFiNode).getNonExitPenalty(exitRequestTimestamp, uint32(block.timestamp)), 0);

        // 1 day passed
        vm.warp(block.timestamp + (1 + 86400));
        assertEq(IEtherFiNode(etherFiNode).getNonExitPenalty(exitRequestTimestamp, uint32(block.timestamp)), 0.03 ether);

        vm.warp(block.timestamp + (1 + (86400 + 3600)));
        assertEq(IEtherFiNode(etherFiNode).getNonExitPenalty(exitRequestTimestamp, uint32(block.timestamp)), 0.0591 ether);

        vm.warp(block.timestamp + (1 + 2 * 86400));
        assertEq(
            IEtherFiNode(etherFiNode).getNonExitPenalty(exitRequestTimestamp, uint32(block.timestamp)),
            0.114707190000000000 ether
        );

        // 10 days passed
        vm.warp(block.timestamp + (1 + 10 * 86400));
        assertEq(
            IEtherFiNode(etherFiNode).getNonExitPenalty(exitRequestTimestamp, uint32(block.timestamp)),
            0.347163722539392386 ether
        );

        // 28 days passed
        vm.warp(block.timestamp + (1 + 28 * 86400));
        assertEq(
            IEtherFiNode(etherFiNode).getNonExitPenalty(exitRequestTimestamp, uint32(block.timestamp)),
            0.721764308786155954 ether
        );

        // 365 days passed
        vm.warp(block.timestamp + (1 + 365 * 86400));
        assertEq(
            IEtherFiNode(etherFiNode).getNonExitPenalty(exitRequestTimestamp, uint32(block.timestamp)),
            1 ether
        );

        // more than 1 year passed
        vm.warp(block.timestamp + (1 + 366 * 86400));
        assertEq(IEtherFiNode(etherFiNode).getNonExitPenalty(exitRequestTimestamp, uint32(block.timestamp)), 1 ether);

        vm.warp(block.timestamp + (1 + 400 * 86400));
        assertEq(IEtherFiNode(etherFiNode).getNonExitPenalty(exitRequestTimestamp, uint32(block.timestamp)), 1 ether);

        vm.warp(block.timestamp + (1 + 1000 * 86400));
        assertEq(IEtherFiNode(etherFiNode).getNonExitPenalty(exitRequestTimestamp, uint32(block.timestamp)), 1 ether);
    }

    function test_PausableModifierWorks() public {
        hoax(alice);
        managerInstance.pauseContract();

        hoax(0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf);
        vm.expectRevert("Pausable: paused");
        managerInstance.sendExitRequest(bidId[0]);

        uint256[] memory ids = new uint256[](1);
        ids[0] = bidId[0];

        hoax(0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf);
        vm.expectRevert("Pausable: paused");
        managerInstance.batchSendExitRequest(ids);

        uint32[] memory timeStamps = new uint32[](1);
        ids[0] = block.timestamp;

        hoax(alice);
        vm.expectRevert("Pausable: paused");
        managerInstance.processNodeExit(ids, timeStamps);

        hoax(alice);
        vm.expectRevert("Pausable: paused");
        managerInstance.partialWithdraw(0);

        hoax(alice);
        vm.expectRevert("Pausable: paused");
        managerInstance.partialWithdrawBatch(ids);

        hoax(alice);
        vm.expectRevert("Pausable: paused");
        managerInstance.fullWithdraw(0);

        hoax(alice);
        vm.expectRevert("Pausable: paused");
        managerInstance.fullWithdrawBatch(ids);

    }
}
