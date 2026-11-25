// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@tests/behaviour-tests/prelude.t.sol";
import "@etherfi/oracle/EtherFiAdmin.sol";
import {IEtherFiAdmin} from "@etherfi/oracle/interfaces/IEtherFiAdmin.sol";
import {IEtherFiOracle} from "@etherfi/oracle/interfaces/IEtherFiOracle.sol";

/// @notice Funds a pod-less validator through the production oracle path:
///         EtherFiAdmin.executeValidatorApprovalTask -> _fundValidators -> LiquidityPool.fundValidators,
///         with the amount per validator taken from the approval task the report created.
contract OraclePodlessFundingTest is PreludeTest {
    // EIP-1967 implementation slot.
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    // validatorApprovalTaskStatus mapping base slot (forge inspect EtherFiAdmin storageLayout).
    uint256 constant TASK_STATUS_SLOT = 211;

    address podLessNode;
    bytes valPubkey;
    bytes valSignature;

    function _newPodLessNode() internal returns (address) {
        vm.prank(admin);
        return stakingManager.instantiateEtherFiNode(/*createEigenPod=*/ false);
    }

    /// @dev Redeploy EtherFiAdmin with the proxy's own immutables and point the proxy at it, so the
    ///      fork runs this branch's _fundValidators (PreludeTest does not upgrade EtherFiAdmin).
    function _upgradeEtherFiAdminInPlace(address proxy) internal {
        EtherFiAdmin cur = EtherFiAdmin(proxy);
        IEtherFiAdmin.ConstructorAddresses memory addrs = IEtherFiAdmin.ConstructorAddresses({
            etherFiOracle: address(cur.etherFiOracle()),
            stakingManager: address(cur.stakingManager()),
            auctionManager: address(cur.auctionManager()),
            etherFiNodesManager: address(cur.etherFiNodesManager()),
            liquidityPool: address(cur.liquidityPool()),
            withdrawRequestNft: address(cur.withdrawRequestNft()),
            roleRegistry: 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9,
            priorityWithdrawalQueue: address(cur.priorityWithdrawalQueue())
        });
        EtherFiAdmin newImpl = new EtherFiAdmin(
            addrs,
            cur.maxAcceptableRebaseAprInBps(),
            cur.maxValidatorTaskBatchSize(),
            cur.staleOracleReportBlockWindow(),
            cur.maxAcceptableFinalizedWithdrawalAmountPerDay(),
            1_000_000 ether, // maxAcceptableValidatorFundingAmountPerDay: the live impl predates this getter
            cur.maxNumberOfRequestsToFinalizePerReport()
        );
        vm.store(proxy, IMPL_SLOT, bytes32(uint256(uint160(address(newImpl)))));
    }

    /// @dev Phase 1: create a pod-less validator (1 ETH) with node-based 0x02 credentials.
    ///      Returns the out-of-LP value captured before the 1 ETH deposit.
    function _createPodLessValidatorPhase1() internal returns (uint256 outStart) {
        podLessNode = _newPodLessNode();
        bytes memory creds = abi.encodePacked(bytes1(0x02), bytes11(0x0), podLessNode);

        address nodeOperator = vm.addr(0x123456);
        if (!nodeOperatorManager.registered(nodeOperator)) {
            vm.prank(nodeOperator);
            nodeOperatorManager.registerNodeOperator("test_ipfs_hash", 1000);
        }
        vm.deal(nodeOperator, 1 ether);
        vm.prank(nodeOperator);
        uint256 bidId = auctionManager.createBid{value: 0.1 ether}(1, 0.1 ether)[0];

        valPubkey = vm.randomBytes(48);
        valSignature = vm.randomBytes(96);
        fundContract(address(liquidityPool), 10000 ether);

        IStakingManager.DepositData memory createData = IStakingManager.DepositData({
            publicKey: valPubkey,
            signature: valSignature,
            depositDataRoot: depositDataRootGenerator.generateDepositDataRoot(valPubkey, valSignature, creds, 1 ether),
            ipfsHashForEncryptedValidatorKey: "test_ipfs_hash"
        });

        outStart = liquidityPool.totalValueOutOfLp();
        vm.prank(admin);
        liquidityPool.batchRegister(toArray(createData), toArray_u256(bidId), podLessNode);
        vm.prank(admin);
        liquidityPool.batchCreateBeaconValidators(toArray(createData), toArray_u256(bidId), podLessNode);
        assertEq(liquidityPool.totalValueOutOfLp(), outStart + 1 ether, "phase 1 deposited 1 ETH");
    }

    /// @dev Seed the two executeValidatorApprovalTask gates (orthogonal to the builder under test).
    function _seedApprovalTask(address proxy, bytes32 reportHash, uint256[] memory validatorIds, uint256[] memory amounts) internal {
        vm.mockCall(
            address(EtherFiAdmin(proxy).etherFiOracle()),
            abi.encodeWithSelector(IEtherFiOracle.isConsensusReached.selector, reportHash),
            abi.encode(true)
        );
        bytes32 taskHash = keccak256(abi.encode(reportHash, validatorIds, amounts));
        // TaskStatus { bool completed; bool exists; } packed in one slot: exists at byte offset 1.
        bytes32 taskSlot = keccak256(abi.encode(taskHash, TASK_STATUS_SLOT));
        vm.store(proxy, taskSlot, bytes32(uint256(1) << 8));
        (bool completed, bool exists) = EtherFiAdmin(proxy).validatorApprovalTaskStatus(taskHash);
        assertTrue(exists && !completed, "seeded approval task exists, not completed");
    }

    function _singleTask(uint256 amount) internal returns (address proxy, uint256 outStart, uint256[] memory ids, uint256[] memory amounts, bytes32 reportHash) {
        proxy = LiquidityPool(payable(address(liquidityPool))).etherFiAdminContract();
        _upgradeEtherFiAdminInPlace(proxy);
        outStart = _createPodLessValidatorPhase1();

        ids = new uint256[](1);
        ids[0] = uint256(etherFiNodesManager.calculateValidatorPubkeyHash(valPubkey));
        amounts = new uint256[](1);
        amounts[0] = amount;
        reportHash = keccak256("podless-funding-report");
        _seedApprovalTask(proxy, reportHash, ids, amounts);
    }

    function test_oracleApprovalPath_fundsPodLessValidator() public {
        (address proxy, uint256 outStart, uint256[] memory ids, uint256[] memory amounts, bytes32 reportHash) = _singleTask(31 ether);
        bytes32 pubkeyHash = bytes32(ids[0]);
        assertEq(etherFiNodesManager.etherfiNodeAddress(ids[0]), podLessNode, "oracle resolves node by pubkeyHash id");

        vm.prank(admin); // ORACLE_OPERATIONS_ROLE
        EtherFiAdmin(proxy).executeValidatorApprovalTask(reportHash, ids, amounts, toArray_bytes(valPubkey));

        assertEq(liquidityPool.totalValueOutOfLp(), outStart + 32 ether, "funded to 32 ETH via oracle path");
        assertEq(address(etherFiNodesManager.etherFiNodeFromPubkeyHash(pubkeyHash)), podLessNode, "still linked to the pod-less node");
        assertEq(address(IEtherFiNode(podLessNode).getEigenPod()), address(0), "node remained pod-less");

        vm.clearMockedCalls();
    }

    function test_oracleApprovalPath_depositsTheReportedAmount() public {
        (address proxy, uint256 outStart, uint256[] memory ids, uint256[] memory amounts, bytes32 reportHash) = _singleTask(1999 ether);

        vm.prank(admin);
        EtherFiAdmin(proxy).executeValidatorApprovalTask(reportHash, ids, amounts, toArray_bytes(valPubkey));

        assertEq(liquidityPool.totalValueOutOfLp(), outStart + 2000 ether, "1 ETH leg plus the reported 1999 ETH");
        vm.clearMockedCalls();
    }

    function test_oracleApprovalPath_rejectsAmountsTheReportDidNotCommitTo() public {
        (address proxy,, uint256[] memory ids, uint256[] memory amounts, bytes32 reportHash) = _singleTask(31 ether);
        amounts[0] = 2000 ether;
        bytes[] memory pubkeys = toArray_bytes(valPubkey);

        vm.expectRevert(EtherFiAdmin.TaskDoesNotExist.selector);
        vm.prank(admin);
        EtherFiAdmin(proxy).executeValidatorApprovalTask(reportHash, ids, amounts, pubkeys);
        vm.clearMockedCalls();
    }

    function test_oracleApprovalPath_rejectsAPubkeyFromAnotherNode() public {
        (address proxy,, uint256[] memory ids, uint256[] memory amounts, bytes32 reportHash) = _singleTask(31 ether);
        // a second ether.fi validator on its own node: linked, but not the one the report approved
        _createPodLessValidatorPhase1();
        bytes[] memory otherNodesPubkey = toArray_bytes(valPubkey);

        vm.expectRevert(EtherFiAdmin.PubkeyNotLinkedToValidatorNode.selector);
        vm.prank(admin);
        EtherFiAdmin(proxy).executeValidatorApprovalTask(reportHash, ids, amounts, otherNodesPubkey);
        vm.clearMockedCalls();
    }
}
