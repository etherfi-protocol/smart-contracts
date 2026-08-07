// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@tests/behaviour-tests/prelude.t.sol";

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
        etherFiNodesManager.sweepFunds(uint256(val.pubkeyHash));

        assertEq(address(liquidityPool).balance, lpBalanceBefore + 5 ether);
        assertEq(node.balance, 0);
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

        (bool supported,) =
            address(IEtherFiNode(node).getEigenPod()).staticcall(abi.encodeWithSignature("restakingDisabled()"));
        if (supported) {
            emit log("EigenLayer v1.14.0 is live: extend this test to cover the disablePod success path");
            return;
        }

        vm.expectRevert();
        vm.prank(address(etherFiNodesManager));
        IEtherFiNode(node).disablePod();
    }

    /// @dev A pod-less node has no pod to retire, so the sweep path reverts rather than
    ///      silently reporting a zero balance.
    function test_withdrawDisabledPodETH_revertsForAPodLessNode() public {
        address node = _newPodLessNode();

        vm.expectRevert();
        vm.prank(address(etherFiNodesManager));
        IEtherFiNode(node).withdrawDisabledPodETH();
    }
}
