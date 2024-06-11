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
        vm.expectRevert("NOT_ADMIN");
        vm.prank(bob);
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

    function test_setEnableNodeRecycling() public {
        vm.expectRevert("NOT_ADMIN");
        vm.prank(bob);
        managerInstance.setEnableNodeRecycling(true);

        vm.prank(alice);
        managerInstance.setEnableNodeRecycling(true);
        assertEq(managerInstance.enableNodeRecycling(), true);

        vm.prank(alice);
        managerInstance.setEnableNodeRecycling(false);
        assertEq(managerInstance.enableNodeRecycling(), false);
    }

    function test_SetNonExitPenaltyPrincipal() public {
        vm.expectRevert("NOT_ADMIN");
        vm.prank(bob);
        managerInstance.setNonExitPenalty(300, 2 ether);

        assertEq(managerInstance.nonExitPenaltyPrincipal(), 1 ether);

        vm.prank(alice);
        managerInstance.setNonExitPenalty(300, 2 ether);

        assertEq(managerInstance.nonExitPenaltyPrincipal(), 2 ether);
    }

    function test_SetNonExitPenaltyDailyRate() public {
        vm.expectRevert("NOT_ADMIN");
        vm.prank(bob);
        managerInstance.setNonExitPenalty(300, 2 ether);

        vm.prank(alice);
        managerInstance.setNonExitPenalty(5, 2 ether);
        assertEq(managerInstance.nonExitPenaltyDailyRate(), 5);
    }

    function test_SetEtherFiNodePhaseRevertsOnIncorrectCaller() public {
        vm.expectRevert(EtherFiNodesManager.NotStakingManager.selector);
        vm.prank(owner);
        managerInstance.setValidatorPhase(bidId[0], IEtherFiNode.VALIDATOR_PHASE.LIVE);
    }

    function test_RegisterEtherFiNodeRevertsOnIncorrectCaller() public {
        vm.prank(address(stakingManagerInstance));
        address ws = managerInstance.allocateEtherFiNode(false);

        vm.expectRevert(EtherFiNodesManager.NotStakingManager.selector);
        vm.prank(owner);
        managerInstance.registerValidator(bidId[0], false, ws);
    }

    function test_RegisterEtherFiNodeRevertsIfAlreadyRegistered() public {
        vm.prank(address(stakingManagerInstance));
        address ws = managerInstance.allocateEtherFiNode(false);

        // Node is registered in setup
        vm.expectRevert(EtherFiNodesManager.AlreadyInstalled.selector);
        vm.prank(address(stakingManagerInstance));
        managerInstance.registerValidator(bidId[0], false, ws);
    }

    function test_UnregisterValidatorRevertsOnIncorrectCaller() public {
        vm.expectRevert(EtherFiNodesManager.NotStakingManager.selector);
        vm.prank(owner);
        managerInstance.unregisterValidator(bidId[0]);
    }

    function test_getEigenPod() public {
        initializeTestingFork(TESTNET_FORK);

        uint256 nonRestakedValidatorId = depositAndRegisterValidator(false);
        assertEq(managerInstance.getEigenPod(nonRestakedValidatorId), address(0x0));
        assertEq(managerInstance.isRestakingEnabled(nonRestakedValidatorId), false);

        uint256 restakedValidatorId = depositAndRegisterValidator(true);
        assert(managerInstance.getEigenPod(restakedValidatorId) != address(0x0));
        assertEq(managerInstance.isRestakingEnabled(restakedValidatorId), true);
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


        // disable use of recycled validators
        vm.prank(alice);
        managerInstance.setEnableNodeRecycling(false);

        // create a new bid
        vm.deal(alice, 33 ether);
        vm.prank(alice);
        bidId = auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether);
        processedBids = stakingManagerInstance.batchDepositWithBidIds{value: 32 ether}(bidId, false);

        // recycled validator should not have been used because of toggle
        assertEq(managerInstance.getUnusedWithdrawalSafesLength(), 2);
        assert(managerInstance.etherfiNodeAddress(processedBids[0]) != managerInstance.unusedWithdrawalSafes(1));
        assert(managerInstance.etherfiNodeAddress(processedBids[0]) != address(0));

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

    function test_UnregisterValidatorAfterFullWithdraw_fails() public {
        address node = managerInstance.etherfiNodeAddress(bidId[0]);
        assert(node != address(0));

        uint256[] memory validatorsToReset = new uint256[](1);
        uint32[] memory timeStamps = new uint32[](1);
        validatorsToReset[0] = bidId[0];
        timeStamps[0] = uint32(block.timestamp);
        uint256 validatorId = validatorsToReset[0];

        // need to put the node in a terminal state before it can be unregistered
        _transferTo(managerInstance.etherfiNodeAddress(validatorsToReset[0]), 32 ether);
        vm.prank(alice);
        managerInstance.processNodeExit(validatorsToReset, timeStamps);

        assertTrue(managerInstance.phase(validatorId) == IEtherFiNode.VALIDATOR_PHASE.EXITED);
        assertEq(IEtherFiNode(node).version(), 1);
        assertEq(IEtherFiNode(node).numAssociatedValidators(), 1);
        assertEq(managerInstance.numAssociatedValidators(validatorId), 1);
        assertEq(managerInstance.getNonExitPenalty(validatorId), 0);
        assertEq(IEtherFiNode(node).numExitRequestsByTnft(), 0);
        assertEq(IEtherFiNode(node).numExitedValidators(), 1);
        assertEq(IEtherFiNode(node).isRestakingEnabled(), false);

        _moveClock(100000);
        managerInstance.batchFullWithdraw(validatorsToReset);

        vm.startPrank(address(stakingManagerInstance));
        vm.expectRevert();
        managerInstance.unregisterValidator(bidId[0]);
    }

    function test_SendExitRequestWorksCorrectly() public {
        assertEq(managerInstance.isExitRequested(bidId[0]), false);

        hoax(alice);
        vm.expectRevert("NOT_TNFT_OWNER");
        managerInstance.batchSendExitRequest(_to_uint256_array(bidId[0]));

        hoax(0x9154a74AAfF2F586FB0a884AeAb7A64521c64bCf);
        managerInstance.batchSendExitRequest(_to_uint256_array(bidId[0]));

        assertEq(managerInstance.isExitRequested(bidId[0]), true);

        uint256[] memory ids = new uint256[](1);
        ids[0] = bidId[0];
        address etherFiNode = managerInstance.etherfiNodeAddress(bidId[0]);
        IEtherFiNodesManager.ValidatorInfo memory info = managerInstance.getValidatorInfo(bidId[0]);
        uint32 exitRequestTimestamp = info.exitRequestTimestamp;

        uint64 nonExitPenaltyPrincipal = managerInstance.nonExitPenaltyPrincipal();
        uint64 nonExitPenaltyDailyRate = managerInstance.nonExitPenaltyDailyRate();

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
        managerInstance.batchSendExitRequest(_to_uint256_array(bidId[0]));

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
        managerInstance.batchPartialWithdraw(ids);

        hoax(alice);
        vm.expectRevert("Pausable: paused");
        managerInstance.fullWithdraw(0);

        hoax(alice);
        vm.expectRevert("Pausable: paused");
        managerInstance.batchFullWithdraw(ids);

    }
}
