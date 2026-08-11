// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@tests/behaviour-tests/prelude.t.sol";

/// @notice Stands in for a v1.14.0 EigenPod after disablePod(), so the sweep path can be tested
///         before EigenLayer ships. Mirrors EigenPod.withdrawDisabledPodETH: owner-only in the real
///         contract, and sends the pod's entire balance to the recipient.
contract DisabledPodStub {
    function restakingDisabled() external pure returns (bool) { return true; }

    function withdrawDisabledPodETH(address recipient) external {
        (bool ok, ) = payable(recipient).call{value: address(this).balance}("");
        require(ok, "stub: transfer failed");
    }

    receive() external payable {}
}

/// @notice Validators whose withdrawal credentials point at the EtherFiNode instead of an EigenPod.
/// @dev Inherits PreludeTest for its mainnet-fork setUp, which upgrades StakingManager,
///      LiquidityPool and EtherFiNodesManager in place and grants the roles these flows need.
contract NonEigenPodCredentialsTest is PreludeTest {

    address constant WITHDRAWAL_REQUEST_PREDEPLOY = 0x00000961Ef480Eb55e80D19ad83579A64c007002;
    address constant CONSOLIDATION_REQUEST_PREDEPLOY = 0x0000BBdDc7CE488642fb579F8B00f3a590007251;

    function _newPodLessNode() internal returns (address) {
        vm.prank(admin);
        return stakingManager.instantiateEtherFiNode(/*createEigenPod=*/ false);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  CREDENTIAL RESOLUTION  ------------------------------
    //--------------------------------------------------------------------------------------

    function test_credentialTarget_isTheNodeWhenThereIsNoPod() public {
        address node = _newPodLessNode();

        assertEq(address(IEtherFiNode(node).getEigenPod()), address(0));
        assertEq(etherFiNodesManager.withdrawalCredentialTarget(node), node);
    }

    function test_credentialTarget_isThePodWhenThereIsOne() public {
        vm.prank(admin);
        address node = stakingManager.instantiateEtherFiNode(/*createEigenPod=*/ true);

        address pod = address(IEtherFiNode(node).getEigenPod());
        assertTrue(pod != address(0));
        assertEq(etherFiNodesManager.withdrawalCredentialTarget(node), pod);
    }

    /// @dev Regression: every node on mainnet today has a pod, so the resolver must return exactly
    ///      what the previous `getEigenPod()` derivation returned.
    function test_credentialTarget_matchesPodForALiveMainnetNode() public view {
        address node = etherFiNodesManager.etherfiNodeAddress(10885);
        address pod = address(IEtherFiNode(node).getEigenPod());

        assertTrue(pod != address(0), "expected a live mainnet node to have a pod");
        assertEq(etherFiNodesManager.withdrawalCredentialTarget(node), pod);
    }

    /// @dev Credentials can never be pointed at an address the protocol did not deploy.
    function test_credentialTarget_revertsForUnknownNode() public {
        vm.expectRevert(IEtherFiNodesManager.UnknownNode.selector);
        etherFiNodesManager.withdrawalCredentialTarget(address(0xdeadbeef));
    }

    /// @dev A retired pod is never a valid credential target: a new validator against it could never
    ///      verify credentials or checkpoint, stranding its 32 ETH behind a dead pod. The validated
    ///      resolver (used by all three creation paths) must reject it.
    function test_credentialTarget_revertsForRetiredPod() public {
        vm.prank(admin);
        address node = stakingManager.instantiateEtherFiNode(true);
        address pod = address(IEtherFiNode(node).getEigenPod());

        // Simulate an EL v1.14 pod that has been retired.
        vm.mockCall(pod, abi.encodeWithSignature("restakingDisabled()"), abi.encode(true));

        vm.expectRevert(IEtherFiNodesManager.PodRetired.selector);
        etherFiNodesManager.withdrawalCredentialTarget(node);

        vm.clearMockedCalls();
    }

    /// @dev The target is derived rather than stored, which is only safe because a node's pod is
    ///      fixed at instantiation. createEigenPod is callable solely by StakingManager, whose one
    ///      call site is inside instantiateEtherFiNode.
    function test_credentialTarget_cannotBeChangedByPrivilegedCallers() public {
        address node = _newPodLessNode();

        vm.expectRevert(IEtherFiNodesManager.InvalidCaller.selector);
        vm.prank(admin);
        etherFiNodesManager.createEigenPod(node);

        vm.expectRevert(IEtherFiNodesManager.InvalidCaller.selector);
        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.createEigenPod(node);

        assertEq(etherFiNodesManager.withdrawalCredentialTarget(node), node);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  VALIDATOR CREATION  ---------------------------------
    //--------------------------------------------------------------------------------------

    /// @dev The full 1 ETH create then 31 ETH top-up flow against node credentials.
    /// @dev The expected credentials are built literally rather than read back from the resolver.
    ///      Deriving them from the resolver would make this test self-consistent and unable to
    ///      catch a resolver bug. Here, if any of the three creation paths resolves a different
    ///      target, its deposit-root check reverts IncorrectBeaconRoot.
    function test_podLess_fullCreationFlowUsesNodeCredentials() public {
        address node = _newPodLessNode();
        bytes memory creds = abi.encodePacked(bytes1(0x02), bytes11(0x0), node);

        address nodeOperator = vm.addr(0x123456);
        if (!nodeOperatorManager.registered(nodeOperator)) {
            vm.prank(nodeOperator);
            nodeOperatorManager.registerNodeOperator("test_ipfs_hash", 1000);
        }
        vm.deal(nodeOperator, 1 ether);
        vm.prank(nodeOperator);
        uint256 bidId = auctionManager.createBid{value: 0.1 ether}(1, 0.1 ether)[0];

        bytes memory pubkey = vm.randomBytes(48);
        bytes memory signature = vm.randomBytes(96);
        uint256 validatorSize = 32 ether;
        uint256 confirmAmount = validatorSize - 1 ether;

        fundContract(address(liquidityPool), 10000 ether);

        IStakingManager.DepositData memory createData = IStakingManager.DepositData({
            publicKey: pubkey,
            signature: signature,
            depositDataRoot: depositDataRootGenerator.generateDepositDataRoot(pubkey, signature, creds, 1 ether),
            ipfsHashForEncryptedValidatorKey: "test_ipfs_hash"
        });

        vm.prank(admin);
        liquidityPool.batchRegister(toArray(createData), toArray_u256(bidId), node);

        uint256 outBefore = liquidityPool.totalValueOutOfLp();
        vm.prank(admin);
        liquidityPool.batchCreateBeaconValidators(toArray(createData), toArray_u256(bidId), node);
        assertEq(liquidityPool.totalValueOutOfLp(), outBefore + 1 ether);

        IStakingManager.DepositData memory confirmData = IStakingManager.DepositData({
            publicKey: pubkey,
            signature: signature,
            depositDataRoot: depositDataRootGenerator.generateDepositDataRoot(pubkey, signature, creds, confirmAmount),
            ipfsHashForEncryptedValidatorKey: "test_ipfs_hash"
        });

        vm.prank(admin);
        liquidityPool.confirmAndFundBeaconValidators(toArray(confirmData), validatorSize);

        assertEq(liquidityPool.totalValueOutOfLp(), outBefore + validatorSize);
        bytes32 pubkeyHash = etherFiNodesManager.calculateValidatorPubkeyHash(pubkey);
        assertEq(address(etherFiNodesManager.etherFiNodeFromPubkeyHash(pubkeyHash)), node);
    }

    /// @dev The shared helper drives the same flow, confirming a pod-less node links correctly.
    function test_podLess_helperCreationFlowSucceeds() public {
        address node = _newPodLessNode();

        TestValidatorParams memory params = defaultTestValidatorParams;
        params.etherFiNode = node;
        TestValidator memory val = helper_createValidator(params);

        assertEq(val.etherFiNode, node);
        assertEq(val.eigenPod, address(0));
        assertEq(address(etherFiNodesManager.etherFiNodeFromPubkeyHash(val.pubkeyHash)), node);
    }

    /// @dev The deposited credentials are 0x02 ++ 11 zero bytes ++ node address.
    function test_podLess_depositsCompoundingCredentialsForTheNode() public {
        address node = _newPodLessNode();

        bytes memory expected = abi.encodePacked(bytes1(0x02), bytes11(0x0), node);
        assertEq(etherFiNodesManager.addressToCompoundingWithdrawalCredentials(node), expected);
        assertEq(
            etherFiNodesManager.addressToCompoundingWithdrawalCredentials(
                etherFiNodesManager.withdrawalCredentialTarget(node)
            ),
            expected
        );
    }

    /// @dev Deposit data built for any other target must be rejected, otherwise ETH would land on
    ///      credentials the protocol does not control.
    function test_podLess_rejectsDepositDataForAnotherTarget() public {
        address node = _newPodLessNode();

        address nodeOperator = vm.addr(0x123456);
        if (!nodeOperatorManager.registered(nodeOperator)) {
            vm.prank(nodeOperator);
            nodeOperatorManager.registerNodeOperator("test_ipfs_hash", 1000);
        }
        vm.deal(nodeOperator, 1 ether);
        vm.prank(nodeOperator);
        uint256 bidId = auctionManager.createBid{value: 0.1 ether}(1, 0.1 ether)[0];

        bytes memory pubkey = vm.randomBytes(48);
        bytes memory signature = vm.randomBytes(96);
        bytes memory wrongCreds = etherFiNodesManager.addressToCompoundingWithdrawalCredentials(address(0xFEE));
        IStakingManager.DepositData memory depositData = IStakingManager.DepositData({
            publicKey: pubkey,
            signature: signature,
            depositDataRoot: depositDataRootGenerator.generateDepositDataRoot(pubkey, signature, wrongCreds, 1 ether),
            ipfsHashForEncryptedValidatorKey: "test_ipfs_hash"
        });

        vm.expectRevert(IStakingManager.IncorrectBeaconRoot.selector);
        vm.prank(admin);
        liquidityPool.batchRegister(toArray(depositData), toArray_u256(bidId), node);
    }

    /// @dev registerBeaconValidators lost its pod-existence check, so confirm it still rejects
    ///      nodes the protocol never deployed.
    function test_podLess_registerRejectsUndeployedNode() public {
        bytes memory pubkey = vm.randomBytes(48);
        IStakingManager.DepositData memory depositData = IStakingManager.DepositData({
            publicKey: pubkey,
            signature: vm.randomBytes(96),
            depositDataRoot: bytes32(0),
            ipfsHashForEncryptedValidatorKey: "test_ipfs_hash"
        });

        vm.expectRevert(IStakingManager.InvalidEtherFiNode.selector);
        vm.prank(admin);
        liquidityPool.batchRegister(toArray(depositData), toArray_u256(uint256(1)), address(0xdeadbeef));
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  EXIT AND SWEEP  -------------------------------------
    //--------------------------------------------------------------------------------------

    /// @dev With no pod to read fees off, they come straight from the predeploys.
    function test_podLess_readsRequestFeesFromPredeploys() public {
        address node = _newPodLessNode();

        assertGt(IEtherFiNode(node).getWithdrawalRequestFee(), 0);
        assertGt(IEtherFiNode(node).getConsolidationRequestFee(), 0);
    }

    /// @dev A pod-less validator is still exitable by the protocol: the node is the validator's
    ///      withdrawal address, so it calls the EIP-7002 predeploy itself.
    function test_podLess_requestExitCallsThePredeployDirectly() public {
        address node = _newPodLessNode();

        TestValidatorParams memory params = defaultTestValidatorParams;
        params.etherFiNode = node;
        TestValidator memory val = helper_createValidator(params);

        _setExitRateLimit(10_000 ether, 10_000 ether);

        bytes[] memory pubkeys = new bytes[](1);
        pubkeys[0] = val.pubkey;
        uint64[] memory amounts = new uint64[](1);
        amounts[0] = 0; // full exit
        IEigenPodTypes.WithdrawalRequest[] memory requests = _requestsFromPubkeys(pubkeys, amounts);

        uint256 fee = IEtherFiNode(node).getWithdrawalRequestFee();
        uint256 predeployBalanceBefore = WITHDRAWAL_REQUEST_PREDEPLOY.balance;

        vm.deal(elExiter, fee);
        vm.prank(elExiter);
        etherFiNodesManager.requestExecutionLayerTriggeredWithdrawal{value: fee}(requests);

        assertEq(WITHDRAWAL_REQUEST_PREDEPLOY.balance, predeployBalanceBefore + fee);
    }

    function _validatorOn(address node, uint256 seed) internal returns (TestValidator memory) {
        TestValidatorParams memory params = defaultTestValidatorParams;
        params.etherFiNode = node;
        params.pubkey = abi.encodePacked(bytes32(keccak256(abi.encode(seed))), bytes16(uint128(seed)));
        return helper_createValidator(params);
    }

    function _consolidation(bytes memory src, bytes memory target)
        internal
        pure
        returns (IEigenPodTypes.ConsolidationRequest[] memory reqs)
    {
        reqs = new IEigenPodTypes.ConsolidationRequest[](1);
        reqs[0] = IEigenPodTypes.ConsolidationRequest({srcPubkey: src, targetPubkey: target});
    }

    /// @dev Partial withdrawal to the node, rather than a full exit.
    function test_podLess_partialWithdrawalReachesPredeploy() public {
        address node = _newPodLessNode();
        TestValidator memory val = _validatorOn(node, 1);
        _setExitRateLimit(10_000 ether, 10_000 ether);

        bytes[] memory pubkeys = new bytes[](1);
        pubkeys[0] = val.pubkey;
        uint64[] memory amounts = new uint64[](1);
        amounts[0] = 1_000_000_000; // 1 ETH in gwei
        IEigenPodTypes.WithdrawalRequest[] memory requests = _requestsFromPubkeys(pubkeys, amounts);

        uint256 fee = IEtherFiNode(node).getWithdrawalRequestFee();
        uint256 before = WITHDRAWAL_REQUEST_PREDEPLOY.balance;

        vm.expectEmit(true, true, false, true, address(etherFiNodesManager));
        emit IEtherFiNodesManager.ValidatorWithdrawalRequestSent(node, val.pubkeyHash, val.pubkey);

        vm.deal(elExiter, fee);
        vm.prank(elExiter);
        etherFiNodesManager.requestExecutionLayerTriggeredWithdrawal{value: fee}(requests);

        assertEq(WITHDRAWAL_REQUEST_PREDEPLOY.balance, before + fee);
    }

    /// @dev Several validators on one node exit in a single batch, one predeploy call each.
    function test_podLess_batchWithdrawalForOneNode() public {
        address node = _newPodLessNode();
        TestValidator memory a = _validatorOn(node, 2);
        TestValidator memory b = _validatorOn(node, 3);
        _setExitRateLimit(10_000 ether, 10_000 ether);

        bytes[] memory pubkeys = new bytes[](2);
        pubkeys[0] = a.pubkey;
        pubkeys[1] = b.pubkey;
        uint64[] memory amounts = new uint64[](2);
        IEigenPodTypes.WithdrawalRequest[] memory requests = _requestsFromPubkeys(pubkeys, amounts);

        uint256 fee = IEtherFiNode(node).getWithdrawalRequestFee();
        uint256 before = WITHDRAWAL_REQUEST_PREDEPLOY.balance;

        vm.deal(elExiter, fee * 2);
        vm.prank(elExiter);
        etherFiNodesManager.requestExecutionLayerTriggeredWithdrawal{value: fee * 2}(requests);

        assertEq(WITHDRAWAL_REQUEST_PREDEPLOY.balance, before + fee * 2);
    }

    function test_podLess_withdrawalRejectsInsufficientFee() public {
        address node = _newPodLessNode();
        TestValidator memory val = _validatorOn(node, 4);
        _setExitRateLimit(10_000 ether, 10_000 ether);

        bytes[] memory pubkeys = new bytes[](1);
        pubkeys[0] = val.pubkey;
        uint64[] memory amounts = new uint64[](1);
        IEigenPodTypes.WithdrawalRequest[] memory requests = _requestsFromPubkeys(pubkeys, amounts);

        uint256 fee = IEtherFiNode(node).getWithdrawalRequestFee();
        vm.deal(elExiter, fee);

        vm.expectRevert(IEtherFiNodesManager.InsufficientWithdrawalFees.selector);
        vm.prank(elExiter);
        etherFiNodesManager.requestExecutionLayerTriggeredWithdrawal{value: fee - 1}(requests);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  CONSOLIDATION  --------------------------------------
    //--------------------------------------------------------------------------------------

    /// @dev src == target switches the validator's credentials from 0x01 to 0x02.
    function test_podLess_switchToCompoundingReachesPredeploy() public {
        address node = _newPodLessNode();
        TestValidator memory val = _validatorOn(node, 5);

        IEigenPodTypes.ConsolidationRequest[] memory requests = _consolidation(val.pubkey, val.pubkey);
        uint256 fee = IEtherFiNode(node).getConsolidationRequestFee();
        uint256 before = CONSOLIDATION_REQUEST_PREDEPLOY.balance;

        vm.expectEmit(true, true, false, true, address(etherFiNodesManager));
        emit IEtherFiNodesManager.ValidatorSwitchToCompoundingRequested(node, val.pubkeyHash, val.pubkey);

        vm.deal(elExiter, fee);
        vm.prank(elExiter);
        etherFiNodesManager.requestConsolidation{value: fee}(requests);

        assertEq(CONSOLIDATION_REQUEST_PREDEPLOY.balance, before + fee);
    }

    /// @dev A true consolidation between two validators sharing the node.
    function test_podLess_consolidationWithinOneNode() public {
        address node = _newPodLessNode();
        TestValidator memory src = _validatorOn(node, 6);
        TestValidator memory target = _validatorOn(node, 7);

        IEigenPodTypes.ConsolidationRequest[] memory requests = _consolidation(src.pubkey, target.pubkey);
        uint256 fee = IEtherFiNode(node).getConsolidationRequestFee();
        uint256 before = CONSOLIDATION_REQUEST_PREDEPLOY.balance;

        vm.expectEmit(true, true, false, true, address(etherFiNodesManager));
        emit IEtherFiNodesManager.ValidatorConsolidationRequested(node, src.pubkeyHash, src.pubkey, target.pubkeyHash, target.pubkey);

        vm.deal(elExiter, fee);
        vm.prank(elExiter);
        etherFiNodesManager.requestConsolidation{value: fee}(requests);

        assertEq(CONSOLIDATION_REQUEST_PREDEPLOY.balance, before + fee);
    }

    /// @dev The target is intentionally unconstrained, which is what lets a retiring pod's
    ///      validators consolidate into a node-credentialled target.
    function test_podLess_consolidationTargetMayBeOutsideTheNode() public {
        address node = _newPodLessNode();
        TestValidator memory src = _validatorOn(node, 8);
        bytes memory foreignTarget = abi.encodePacked(bytes32(keccak256("foreign")), bytes16(uint128(9)));

        IEigenPodTypes.ConsolidationRequest[] memory requests = _consolidation(src.pubkey, foreignTarget);
        uint256 fee = IEtherFiNode(node).getConsolidationRequestFee();
        uint256 before = CONSOLIDATION_REQUEST_PREDEPLOY.balance;

        vm.deal(elExiter, fee);
        vm.prank(elExiter);
        etherFiNodesManager.requestConsolidation{value: fee}(requests);

        assertEq(CONSOLIDATION_REQUEST_PREDEPLOY.balance, before + fee);
    }

    function test_podLess_consolidationRejectsInsufficientFee() public {
        address node = _newPodLessNode();
        TestValidator memory val = _validatorOn(node, 10);

        IEigenPodTypes.ConsolidationRequest[] memory requests = _consolidation(val.pubkey, val.pubkey);
        uint256 fee = IEtherFiNode(node).getConsolidationRequestFee();
        vm.deal(elExiter, fee);

        vm.expectRevert(IEtherFiNodesManager.InsufficientConsolidationFees.selector);
        vm.prank(elExiter);
        etherFiNodesManager.requestConsolidation{value: fee - 1}(requests);
    }

    /// @dev Source validators from two nodes cannot share a batch: the node calling the predeploy
    ///      is only the withdrawal address for its own validators.
    function test_podLess_consolidationRejectsSourcesFromAnotherNode() public {
        TestValidator memory a = _validatorOn(_newPodLessNode(), 11);
        TestValidator memory b = _validatorOn(_newPodLessNode(), 12);
        assertTrue(a.etherFiNode != b.etherFiNode);

        IEigenPodTypes.ConsolidationRequest[] memory requests = new IEigenPodTypes.ConsolidationRequest[](2);
        requests[0] = IEigenPodTypes.ConsolidationRequest({srcPubkey: a.pubkey, targetPubkey: a.pubkey});
        requests[1] = IEigenPodTypes.ConsolidationRequest({srcPubkey: b.pubkey, targetPubkey: b.pubkey});

        uint256 fee = IEtherFiNode(a.etherFiNode).getConsolidationRequestFee() * 2;
        vm.deal(elExiter, fee);

        vm.expectRevert(IEtherFiNodesManager.MixedNodeRequest.selector);
        vm.prank(elExiter);
        etherFiNodesManager.requestConsolidation{value: fee}(requests);
    }

    /// @dev A batch mixing validators from two different nodes must revert. The predeploy accepts
    ///      any pubkey from any caller and the consensus layer silently drops the ones whose source
    ///      withdrawal address is not the caller, so without this check the fee would be burned and
    ///      exit events emitted for exits that never happen.
    function test_podLess_requestExitRejectsValidatorsFromAnotherNode() public {
        TestValidatorParams memory paramsA = defaultTestValidatorParams;
        paramsA.etherFiNode = _newPodLessNode();
        TestValidator memory valA = helper_createValidator(paramsA);

        TestValidatorParams memory paramsB = defaultTestValidatorParams;
        paramsB.etherFiNode = _newPodLessNode();
        TestValidator memory valB = helper_createValidator(paramsB);

        assertTrue(valA.etherFiNode != valB.etherFiNode);

        _setExitRateLimit(10_000 ether, 10_000 ether);

        bytes[] memory pubkeys = new bytes[](2);
        pubkeys[0] = valA.pubkey;
        pubkeys[1] = valB.pubkey;
        uint64[] memory amounts = new uint64[](2);
        IEigenPodTypes.WithdrawalRequest[] memory requests = _requestsFromPubkeys(pubkeys, amounts);

        uint256 fee = IEtherFiNode(valA.etherFiNode).getWithdrawalRequestFee() * 2;
        vm.deal(elExiter, fee);
        vm.expectRevert(IEtherFiNodesManager.MixedNodeRequest.selector);
        vm.prank(elExiter);
        etherFiNodesManager.requestExecutionLayerTriggeredWithdrawal{value: fee}(requests);
    }

    /// @dev Sweeping by node address needs no validator id, which suits a pod-less node whose
    ///      credential target is the node itself.
    function test_podLess_sweepsByNodeAddress() public {
        address node = _newPodLessNode();

        vm.deal(node, 3 ether);
        uint256 lpBalanceBefore = address(liquidityPool).balance;

        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.sweepFunds(node);

        assertEq(address(liquidityPool).balance, lpBalanceBefore + 3 ether);
        assertEq(node.balance, 0);
    }

    function test_sweepFundsByAddress_gatedByHousekeeping() public {
        address node = _newPodLessNode();

        vm.expectRevert(RoleRegistry.OnlyHousekeepingOperations.selector);
        vm.prank(makeAddr("rando"));
        etherFiNodesManager.sweepFunds(node);
    }

    /// @dev Beacon-chain rewards and exited principal arrive at the node, so the sweep is the only
    ///      revenue path for these validators.
    function test_podLess_sweepsNodeBalanceToLiquidityPool() public {
        address node = _newPodLessNode();

        TestValidatorParams memory params = defaultTestValidatorParams;
        params.etherFiNode = node;
        TestValidator memory val = helper_createValidator(params);

        vm.deal(node, 5 ether);
        uint256 lpBalanceBefore = address(liquidityPool).balance;

        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.sweepFunds(node);

        assertEq(address(liquidityPool).balance, lpBalanceBefore + 5 ether);
        assertEq(node.balance, 0);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  CALL FORWARDING  ------------------------------------
    //--------------------------------------------------------------------------------------

    /// @dev Both eigenpod and housekeeping operations may forward, so the withdrawal-completion
    ///      cron can batch across nodes in one transaction.
    function test_forwarding_acceptsEigenpodAndHousekeepingRoles() public {
        vm.prank(admin);
        address node = stakingManager.instantiateEtherFiNode(true);
        bytes4 selector = IEigenPod.activeValidatorCount.selector;

        address[] memory nodes = new address[](1);
        nodes[0] = node;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector);

        // whitelist the selector for each caller independently
        vm.startPrank(admin);
        etherFiNodesManager.updateAllowedForwardedEigenpodCalls(callForwarder, selector, true);
        etherFiNodesManager.updateAllowedForwardedEigenpodCalls(eigenlayerAdmin, selector, true);
        vm.stopPrank();

        vm.prank(callForwarder); // EIGENPOD_OPERATIONS_ROLE
        etherFiNodesManager.forwardEigenPodCall(nodes, data);

        vm.prank(eigenlayerAdmin); // HOUSEKEEPING_OPERATIONS_ROLE
        etherFiNodesManager.forwardEigenPodCall(nodes, data);
    }

    function test_forwarding_rejectsCallerWithNeitherRole() public {
        vm.prank(admin);
        address node = stakingManager.instantiateEtherFiNode(true);

        address[] memory nodes = new address[](1);
        nodes[0] = node;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(IEigenPod.activeValidatorCount.selector);

        vm.expectRevert(RoleRegistry.OnlyEigenpodOperations.selector);
        vm.prank(makeAddr("rando"));
        etherFiNodesManager.forwardEigenPodCall(nodes, data);

        vm.expectRevert(RoleRegistry.OnlyEigenpodOperations.selector);
        vm.prank(makeAddr("rando"));
        etherFiNodesManager.forwardExternalCall(nodes, data, address(0x1234));
    }

    /// @dev Holding a role is not enough: the selector must still be whitelisted for that caller.
    function test_forwarding_housekeepingStillNeedsTheSelectorWhitelisted() public {
        vm.prank(admin);
        address node = stakingManager.instantiateEtherFiNode(true);

        address[] memory nodes = new address[](1);
        nodes[0] = node;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(IEigenPod.activeValidatorCount.selector);

        vm.expectRevert(IEtherFiNodesManager.ForwardedCallNotAllowed.selector);
        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.forwardEigenPodCall(nodes, data);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  POD RETIREMENT  -------------------------------------
    //--------------------------------------------------------------------------------------

    /// @dev disablePod ships in EigenLayer v1.14.0, which is not on mainnet yet. The live
    ///      EigenPodManager has no such selector and no fallback, so the call reverts instead of
    ///      silently succeeding. That distinction matters: a no-op would let us believe a pod was
    ///      retired and consolidate out of a live pod, cutting the beacon slashing factor and
    ///      devaluing our claim on the ETH still in it.
    function test_disablePod_revertsUntilEigenLayerV1_14_0() public {
        vm.prank(admin);
        address node = stakingManager.instantiateEtherFiNode(/*createEigenPod=*/ true);
        IEigenPod pod = IEtherFiNode(node).getEigenPod();

        (bool supported,) = address(pod).staticcall(abi.encodeWithSignature("restakingDisabled()"));
        if (supported) {
            // EL v1.14.0 is live: a freshly created pod has no shares, checkpoints or queued
            // withdrawals, so retirement through the manager succeeds and the pod reports it. Assert
            // the real success path rather than returning green, so this test never passes vacuously.
            vm.prank(admin); // OPERATION_TIMELOCK_ROLE
            etherFiNodesManager.disablePod(node);
            assertTrue(pod.restakingDisabled(), "pod should report retirement after disablePod");
            return;
        }

        // Pre-v1.14: the EigenPodManager has no disablePod selector and no fallback, so the call
        // reverts rather than silently succeeding.
        vm.expectRevert();
        vm.prank(address(etherFiNodesManager));
        IEtherFiNode(node).disablePod();
    }

    /// @dev The end state v1.14.0 enables: a retired pod still receives skimmed rewards and full
    ///      exits at its withdrawal credential, and the owner sweeps it with no proofs, no
    ///      checkpoints and no 14-day queue. Proves ETH reaches the LiquidityPool through our
    ///      EtherFiNode, using a stub because the live EigenPod has no such selector yet.
    function test_disabledPod_sweepsPodEthToLiquidityPool() public {
        vm.prank(admin);
        address node = stakingManager.instantiateEtherFiNode(true);
        address pod = address(IEtherFiNode(node).getEigenPod());

        vm.etch(pod, address(new DisabledPodStub()).code);
        vm.deal(pod, 40 ether);

        uint256 lpBefore = address(liquidityPool).balance;

        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.withdrawDisabledPodETH(node);

        assertEq(pod.balance, 0, "pod fully drained");
        assertEq(address(liquidityPool).balance, lpBefore + 40 ether, "ETH landed in the pool");
        assertEq(node.balance, 0, "nothing stranded on the node");
    }

    /// @dev A retired pod keeps receiving beacon-chain income, so the sweep must be repeatable.
    function test_disabledPod_sweepIsRepeatable() public {
        vm.prank(admin);
        address node = stakingManager.instantiateEtherFiNode(true);
        address pod = address(IEtherFiNode(node).getEigenPod());
        vm.etch(pod, address(new DisabledPodStub()).code);

        uint256 lpBefore = address(liquidityPool).balance;

        vm.deal(pod, 1 ether);
        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.withdrawDisabledPodETH(node);

        vm.deal(pod, 32 ether); // a validator fully exits later
        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.withdrawDisabledPodETH(node);

        assertEq(address(liquidityPool).balance, lpBefore + 33 ether);
    }

    function test_disabledPod_sweepIsGatedAndValidated() public {
        vm.prank(admin);
        address node = stakingManager.instantiateEtherFiNode(true);
        vm.etch(address(IEtherFiNode(node).getEigenPod()), address(new DisabledPodStub()).code);

        vm.expectRevert(RoleRegistry.OnlyHousekeepingOperations.selector);
        vm.prank(makeAddr("rando"));
        etherFiNodesManager.withdrawDisabledPodETH(node);

        vm.expectRevert(IEtherFiNodesManager.UnknownNode.selector);
        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.withdrawDisabledPodETH(address(0xdeadbeef));
    }

    /// @dev disablePod is called by the pod owner, which is the EtherFiNode. Mocked at the
    ///      EigenPodManager so the manager -> node -> EPM path is exercised.
    function test_disabledPod_retirementRoutesThroughTheNodeAsPodOwner() public {
        vm.prank(admin);
        address node = stakingManager.instantiateEtherFiNode(true);
        address pod = address(IEtherFiNode(node).getEigenPod());

        vm.mockCall(eigenPodManager, abi.encodeWithSignature("disablePod()"), "");
        // The manager now asserts the pod actually reports retirement before emitting PodDisabled,
        // so the pod must report restakingDisabled() == true for the happy path.
        vm.mockCall(pod, abi.encodeWithSignature("restakingDisabled()"), abi.encode(true));

        vm.expectEmit(true, true, false, true, address(etherFiNodesManager));
        emit IEtherFiNodesManager.PodDisabled(node, pod);

        vm.prank(admin); // OPERATION_TIMELOCK_ROLE
        etherFiNodesManager.disablePod(node);

        vm.clearMockedCalls();
    }

    /// @dev Regression for the silent no-op: if the EtherFiNode beacon is stale, node.disablePod()
    ///      is swallowed by the empty fallback and returns success. The manager must not emit a
    ///      false PodDisabled — it reverts PodNotDisabled because the pod still reports restaking on.
    function test_disablePod_revertsWhenPodNotActuallyDisabled() public {
        vm.prank(admin);
        address node = stakingManager.instantiateEtherFiNode(true);
        address pod = address(IEtherFiNode(node).getEigenPod());

        // Simulate a node/pod that accepts disablePod() (or swallows it) yet stays enabled.
        vm.mockCall(eigenPodManager, abi.encodeWithSignature("disablePod()"), "");
        vm.mockCall(pod, abi.encodeWithSignature("restakingDisabled()"), abi.encode(false));

        vm.expectRevert(IEtherFiNodesManager.PodNotDisabled.selector);
        vm.prank(admin); // OPERATION_TIMELOCK_ROLE
        etherFiNodesManager.disablePod(node);

        vm.clearMockedCalls();
    }

    function test_disabledPod_retirementIsTimelockGated() public {
        vm.prank(admin);
        address node = stakingManager.instantiateEtherFiNode(true);
        vm.mockCall(eigenPodManager, abi.encodeWithSignature("disablePod()"), "");

        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.disablePod(node);

        vm.clearMockedCalls();
    }

    /// @dev A pod-less node has no pod to retire, so the sweep path reverts rather than
    ///      silently reporting a zero balance.
    function test_withdrawDisabledPodETH_revertsForAPodLessNode() public {
        address node = _newPodLessNode();

        vm.expectRevert();
        vm.prank(address(etherFiNodesManager));
        IEtherFiNode(node).withdrawDisabledPodETH();
    }

    /// @dev sweepFunds(address) must validate the node like every other node-taking entrypoint, so a
    ///      housekeeping caller cannot point it at an arbitrary contract and forge FundsTransferred.
    function test_sweepFunds_revertsForUnknownNode() public {
        vm.expectRevert(IEtherFiNodesManager.UnknownNode.selector);
        vm.prank(eigenlayerAdmin); // HOUSEKEEPING_OPERATIONS_ROLE
        etherFiNodesManager.sweepFunds(address(0xdeadbeef));
    }
}
