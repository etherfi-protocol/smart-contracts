// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@tests/TestSetup.sol";
import "@scripts/deploys/Deployed.s.sol";

import "@etherfi/staking/interfaces/IStakingManager.sol";
import "@etherfi/staking/interfaces/IEtherFiNode.sol";

import "@etherfi/staking/libraries/DepositDataRootGenerator.sol";

/// @notice End-to-end validator spin-up for a node with no EigenPod, driven through the real
///         production components at every step: node-operator whitelisting, bid submission,
///         validator creation against 0x02 credentials that point at the EtherFiNode, oracle
///         report submission to consensus, EtherFiAdmin.executeTasks, and finally
///         EtherFiAdmin.executeValidatorApprovalTask funding the validator to full size.
/// @dev Nothing here hand-builds the top-up DepositData. EtherFiAdmin._approveValidators is the
///      only component that does so in production, and it derives the credential target
///      independently of StakingManager.confirmAndFundBeaconValidators. If the two derivations
///      ever disagree the top-up reverts IncorrectBeaconRoot, which is exactly what a pod-less
///      node used to trigger: _approveValidators hardcoded getEigenPod() (address(0) with no
///      pod) while StakingManager resolved the node. These tests pin the two together.
contract PodLessValidatorFlowsIntegrationTest is TestSetup, Deployed {
    /// @dev EtherFiAdmin slot 209 packs lastHandledReportRefSlot (4B @ offset 0) and
    ///      lastHandledReportRefBlock (4B @ offset 4).
    uint256 constant ADMIN_LAST_HANDLED_SLOT = 209;

    /// @dev Committee members minted for this test, in submission order.
    address[] internal committee;

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);

        // Mainnet NodeOperatorManager predates the role-based ACL, so its
        // NODE_OPERATOR_MANAGER_ADMIN_ROLE() getter does not exist on-chain yet.
        NodeOperatorManager nodeOperatorManagerImpl =
            new NodeOperatorManager(address(roleRegistryInstance), address(auctionInstance));
        vm.prank(roleRegistryInstance.owner());
        nodeOperatorManagerInstance.upgradeTo(address(nodeOperatorManagerImpl));

        // The on-chain LiquidityPool impl still gates registerValidatorSpawner on
        // LIQUIDITY_POOL_ADMIN_ROLE; upgrade to the consolidated role model.
        LiquidityPool newLpImpl = new LiquidityPool(ILiquidityPool.ConstructorAddresses({
            stakingManager: address(stakingManagerInstance),
            nodesManager: address(managerInstance),
            eETH: address(eETHInstance),
            withdrawRequestNFT: address(withdrawRequestNFTInstance),
            liquifier: address(liquifierInstance),
            etherFiRedemptionManager: address(etherFiRedemptionManagerInstance),
            roleRegistry: address(roleRegistryInstance),
            priorityWithdrawalQueue: address(priorityQueueInstance),
            blacklister: address(blacklisterInstance),
            etherFiAdminContract: address(etherFiAdminInstance),
            membershipManager: address(membershipManagerInstance)
        }));
        address lpOwner = roleRegistryInstance.owner();
        vm.prank(lpOwner);
        liquidityPoolInstance.upgradeTo(address(newLpImpl));

        // WithdrawRequestNFT needs a receive() to accept the ETH-escrow transfer that
        // initializeOnUpgradeV2 makes. Deploy before pranking: the inlined `new` is a CREATE
        // that would otherwise consume the single-shot prank.
        address newWrnImpl = address(new WithdrawRequestNFT(
            address(liquidityPoolInstance),
            address(roleRegistryInstance),
            address(blacklisterInstance),
            address(etherFiAdminInstance)
        ));
        vm.prank(roleRegistryInstance.owner());
        withdrawRequestNFTInstance.upgradeTo(newWrnImpl);

        // The queue proxy still runs the master impl, which has no receive(). Upgrade it before
        // initializeOnUpgradeV2 sweeps queue-locked ETH into it, or that sweep reverts SendFail.
        address newPQ = address(new PriorityWithdrawalQueue(
            address(liquidityPoolInstance), address(eETHInstance), address(weEthInstance),
            address(blacklisterInstance), address(roleRegistryInstance), 1 hours
        ));
        vm.prank(UPGRADE_TIMELOCK);
        PriorityWithdrawalQueue(payable(PRIORITY_WITHDRAWAL_QUEUE)).upgradeTo(newPQ);

        if (!liquidityPoolInstance.escrowMigrationCompleted()) {
            vm.prank(lpOwner);
            liquidityPoolInstance.initializeOnUpgradeV2();
        }

        // Brings up local Oracle and Admin impls, so the OracleReport ABI matches and the
        // EtherFiAdmin under test is built from this branch's source.
        _upgradeOracleAndAdminForFork();

        address rrOwner = roleRegistryInstance.owner();
        vm.startPrank(rrOwner);
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_TIMELOCK_ROLE(), rrOwner);
        roleRegistryInstance.grantRole(roleRegistryInstance.ORACLE_OPERATIONS_ROLE(), ADMIN_EOA);
        // Otherwise executeTasks rejects the approval against the per-day cap.
        etherFiAdminInstance.updateMaxNumValidatorsToApprovePerDay(
            etherFiAdminInstance.maxAcceptableNumValidatorsToApprovePerDay()
        );
        vm.stopPrank();

        _syncAdminToOracle();
        _seedFreshCommittee();
    }

    //--------------------------------------------------------------------------------------
    //----------------------------------  ORACLE SETUP  ------------------------------------
    //--------------------------------------------------------------------------------------

    /// @dev submitReport rejects a new report while the last published one is unhandled, and the
    ///      fork lands on whatever mainnet state exists at the latest block.
    function _syncAdminToOracle() internal {
        uint32 lastPublished = etherFiOracleInstance.lastPublishedReportRefSlot();
        if (lastPublished == etherFiAdminInstance.lastHandledReportRefSlot()) return;

        uint32 lastPublishedBlock = etherFiOracleInstance.lastPublishedReportRefBlock();
        uint256 packed = uint256(vm.load(address(etherFiAdminInstance), bytes32(ADMIN_LAST_HANDLED_SLOT)));
        packed &= ~uint256(0xFFFFFFFFFFFFFFFF); // clear both uint32 fields
        packed |= uint256(lastPublished);
        packed |= uint256(lastPublishedBlock) << 32;
        vm.store(address(etherFiAdminInstance), bytes32(ADMIN_LAST_HANDLED_SLOT), bytes32(packed));
    }

    /// @dev Adds enough brand-new committee members that they alone reach quorum, so the test
    ///      never depends on which mainnet members are currently registered or whether they have
    ///      already submitted for this refSlot.
    ///
    ///      _checkQuorum requires quorum <= numActive < 2 * quorum, so quorum is a strict
    ///      majority. Starting from N active members, adding k=N+2 gives numActive=2N+2 and
    ///      quorum=N+2=k: the fresh members are exactly a majority. Each add re-runs
    ///      _checkQuorum, so every intermediate step passes its own valid quorum.
    function _seedFreshCommittee() internal {
        uint32 active = etherFiOracleInstance.numActiveCommitteeMembers();
        uint32 toAdd = active + 2;

        vm.startPrank(roleRegistryInstance.owner());
        for (uint32 i = 1; i <= toAdd; i++) {
            address member = vm.addr(uint256(keccak256(abi.encodePacked("podless-committee", i))));
            uint32 quorum = (active + i) / 2 + 1;
            etherFiOracleInstance.addCommitteeMember(member, quorum);
            committee.push(member);
        }
        vm.stopPrank();

        assertGe(committee.length, etherFiOracleInstance.quorumSize(), "fresh members reach quorum alone");
    }

    /// @dev Advances to a slot where the oracle treats the next report epoch as finalized.
    ///      Oracle requires slotEpoch + 2 < currEpoch, i.e. currEpoch >= slotEpoch + 3.
    function _warpToReportableSlot() internal {
        while (true) {
            uint32 slot = etherFiOracleInstance.slotForNextReport();
            uint32 curr = etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp);
            uint32 min = ((slot / 32) + 3) * 32;
            if (curr >= min) break;
            uint256 delta = min - curr;
            vm.roll(block.number + delta);
            vm.warp(etherFiOracleInstance.beaconGenesisTimestamp() + 12 * (curr + uint32(delta)));
        }
    }

    function _buildReport(uint256[] memory validatorsToApprove)
        internal
        view
        returns (IEtherFiOracle.OracleReport memory report)
    {
        report = IEtherFiOracle.OracleReport(
            etherFiOracleInstance.consensusVersion(), 0, 0, 0, 0, 0, 0, new uint256[](0), 0, 0
        );
        (report.refSlotFrom, report.refSlotTo, report.refBlockFrom) = etherFiOracleInstance.blockStampForNextReport();
        report.validatorsToApprove = validatorsToApprove;
        report.lastFinalizedWithdrawalRequestId = withdrawRequestNFTInstance.lastFinalizedRequestId();

        // refBlockTo must be below the current block and above the last admin execution.
        report.refBlockTo = uint32(block.number - 1);
        if (report.refBlockTo <= etherFiAdminInstance.lastAdminExecutionBlock()) {
            report.refBlockTo = etherFiAdminInstance.lastAdminExecutionBlock() + 1;
        }
    }

    /// @dev Submits the report from fresh committee members until consensus is reached.
    function _reachConsensus(IEtherFiOracle.OracleReport memory report) internal returns (bytes32 reportHash) {
        reportHash = etherFiOracleInstance.generateReportHash(report);
        for (uint256 i = 0; i < committee.length; i++) {
            vm.prank(committee[i]);
            etherFiOracleInstance.submitReport(report);
            if (etherFiOracleInstance.isConsensusReached(reportHash)) break;
        }
        assertTrue(etherFiOracleInstance.isConsensusReached(reportHash), "committee reached consensus");
    }

    /// @dev executeTasks is gated on postReportWaitTimeInSlots elapsing after consensus.
    function _warpPastReportWait() internal {
        uint256 slotsToWait = uint256(etherFiAdminInstance.postReportWaitTimeInSlots() + 1);
        uint32 slotNow = etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp);
        vm.roll(block.number + slotsToWait);
        vm.warp(etherFiOracleInstance.beaconGenesisTimestamp() + 12 * (slotNow + slotsToWait));
    }

    //--------------------------------------------------------------------------------------
    //--------------------------------  VALIDATOR SETUP  -----------------------------------
    //--------------------------------------------------------------------------------------

    function _toArray(IStakingManager.DepositData memory d)
        internal
        pure
        returns (IStakingManager.DepositData[] memory arr)
    {
        arr = new IStakingManager.DepositData[](1);
        arr[0] = d;
    }

    function _toArrayU256(uint256 x) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = x;
    }

    function _toArrayBytes(bytes memory b) internal pure returns (bytes[] memory arr) {
        arr = new bytes[](1);
        arr[0] = b;
    }

    function _grantValidatorCreationRoles() internal {
        address roleOwner = roleRegistryInstance.owner();
        vm.startPrank(roleOwner);
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_TIMELOCK_ROLE(), ETHERFI_OPERATING_ADMIN);
        roleRegistryInstance.grantRole(roleRegistryInstance.ORACLE_OPERATIONS_ROLE(), ETHERFI_OPERATING_ADMIN);
        roleRegistryInstance.grantRole(roleRegistryInstance.EXECUTOR_OPERATIONS_ROLE(), OPERATING_TIMELOCK);
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_MULTISIG_ROLE(), ETHERFI_OPERATING_ADMIN);
        vm.stopPrank();
    }

    /// @dev Whitelist the spawner, register it as a node operator, and place a bid.
    function _whitelistSpawnerAndBid(address spawner) internal returns (uint256 bidId) {
        _grantValidatorCreationRoles();

        vm.prank(ETHERFI_OPERATING_ADMIN);
        nodeOperatorManagerInstance.addToWhitelist(spawner);
        assertTrue(nodeOperatorManagerInstance.isWhitelisted(spawner), "spawner whitelisted");

        vm.deal(spawner, 10 ether);
        vm.startPrank(spawner);
        if (!nodeOperatorManagerInstance.registered(spawner)) {
            nodeOperatorManagerInstance.registerNodeOperator("test_ipfs_hash", 1000);
        }
        bidId = auctionInstance.createBid{value: 0.1 ether}(1, 0.1 ether)[0];
        vm.stopPrank();
        assertTrue(auctionInstance.isBidActive(bidId), "bid active");

        vm.prank(ETHERFI_OPERATING_ADMIN);
        liquidityPoolInstance.registerValidatorSpawner(spawner);
    }

    /// @dev Builds 1-ETH deposit data against whatever the node's credential target is.
    function _buildCreationDepositData(address etherFiNode)
        internal
        returns (IStakingManager.DepositData memory depositData, bytes memory withdrawalCredentials)
    {
        bytes memory pubkey = vm.randomBytes(48);
        bytes memory signature = vm.randomBytes(96);
        withdrawalCredentials = managerInstance.addressToCompoundingWithdrawalCredentials(
            managerInstance.withdrawalCredentialTarget(etherFiNode)
        );
        depositData = IStakingManager.DepositData({
            publicKey: pubkey,
            signature: signature,
            depositDataRoot: depositDataRootGenerator.generateDepositDataRoot(
                pubkey, signature, withdrawalCredentials, stakingManagerInstance.INITIAL_DEPOSIT_AMOUNT()
            ),
            ipfsHashForEncryptedValidatorKey: "test_ipfs_hash"
        });
    }

    /// @dev Runs the whole spin-up and returns the ETH that left the LP across both deposits.
    function _spinUpValidator(address spawner, bool createEigenPod)
        internal
        returns (address etherFiNode, uint256 outDelta)
    {
        uint256 bidId = _whitelistSpawnerAndBid(spawner);

        vm.prank(OPERATING_TIMELOCK);
        etherFiNode = stakingManagerInstance.instantiateEtherFiNode(createEigenPod);

        (IStakingManager.DepositData memory depositData, bytes memory creds) = _buildCreationDepositData(etherFiNode);

        uint256 outStart = liquidityPoolInstance.totalValueOutOfLp();
        _runCreationLeg(spawner, etherFiNode, bidId, depositData);
        _runOracleFundingLeg(etherFiNode, bidId, depositData);

        // Credentials never moved off the target the deposits were built against.
        assertEq(
            managerInstance.addressToCompoundingWithdrawalCredentials(
                managerInstance.withdrawalCredentialTarget(etherFiNode)
            ),
            creds,
            "credential target unchanged across the flow"
        );

        outDelta = liquidityPoolInstance.totalValueOutOfLp() - outStart;
    }

    /// @dev The 1 ETH leg: spawner registers, operating admin creates.
    function _runCreationLeg(
        address spawner,
        address etherFiNode,
        uint256 bidId,
        IStakingManager.DepositData memory depositData
    ) internal {
        uint256 outStart = liquidityPoolInstance.totalValueOutOfLp();

        vm.prank(spawner);
        liquidityPoolInstance.batchRegister(_toArray(depositData), _toArrayU256(bidId), etherFiNode);

        bytes32 validatorHash = keccak256(abi.encode(
            depositData.publicKey,
            depositData.signature,
            depositData.depositDataRoot,
            depositData.ipfsHashForEncryptedValidatorKey,
            bidId,
            etherFiNode
        ));
        assertEq(
            uint8(stakingManagerInstance.validatorCreationStatus(validatorHash)),
            uint8(IStakingManager.ValidatorCreationStatus.REGISTERED),
            "registered"
        );

        vm.prank(ETHERFI_OPERATING_ADMIN);
        liquidityPoolInstance.batchCreateBeaconValidators(_toArray(depositData), _toArrayU256(bidId), etherFiNode);

        assertEq(
            uint8(stakingManagerInstance.validatorCreationStatus(validatorHash)),
            uint8(IStakingManager.ValidatorCreationStatus.CONFIRMED),
            "confirmed"
        );
        assertEq(
            liquidityPoolInstance.totalValueOutOfLp(),
            outStart + stakingManagerInstance.INITIAL_DEPOSIT_AMOUNT(),
            "1 ETH leg left the LP"
        );
        assertEq(managerInstance.etherfiNodeAddress(bidId), etherFiNode, "oracle resolves the node by bid id");
    }

    /// @dev The remaining-ETH leg: real oracle report, then EtherFiAdmin builds the top-up itself.
    function _runOracleFundingLeg(
        address etherFiNode,
        uint256 bidId,
        IStakingManager.DepositData memory depositData
    ) internal {
        _warpToReportableSlot();
        IEtherFiOracle.OracleReport memory report = _buildReport(_toArrayU256(bidId));
        bytes32 reportHash = _reachConsensus(report);
        _warpPastReportWait();

        vm.prank(ADMIN_EOA);
        etherFiAdminInstance.executeTasks(report);

        bytes32 taskHash = keccak256(abi.encode(reportHash, report.validatorsToApprove));
        (bool completedBefore, bool exists) = etherFiAdminInstance.validatorApprovalTaskStatus(taskHash);
        assertTrue(exists, "executeTasks created the approval task");
        assertFalse(completedBefore, "approval task not yet executed");

        vm.prank(ADMIN_EOA);
        etherFiAdminInstance.executeValidatorApprovalTask(
            reportHash,
            report.validatorsToApprove,
            _toArrayBytes(depositData.publicKey),
            _toArrayBytes(depositData.signature)
        );

        (bool completedAfter,) = etherFiAdminInstance.validatorApprovalTaskStatus(taskHash);
        assertTrue(completedAfter, "approval task completed");

        // The pubkey stays bound to the node the credentials named.
        bytes32 pubkeyHash = managerInstance.calculateValidatorPubkeyHash(depositData.publicKey);
        assertEq(address(managerInstance.etherFiNodeFromPubkeyHash(pubkeyHash)), etherFiNode, "pubkey linked to node");
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------------  TESTS  ----------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice The whole point: a validator whose 0x02 credentials name the EtherFiNode itself
    ///         funds to full size through the oracle, with no EigenPod anywhere in the flow.
    function test_podLessValidator_spinsUpAndFundsThroughOracle() public {
        address spawner = vm.addr(0xB0D1E55);

        (address etherFiNode, uint256 outDelta) = _spinUpValidator(spawner, /*createEigenPod=*/ false);

        assertEq(address(IEtherFiNode(etherFiNode).getEigenPod()), address(0), "node never got a pod");
        assertEq(managerInstance.withdrawalCredentialTarget(etherFiNode), etherFiNode, "node is its own target");
        assertEq(outDelta, liquidityPoolInstance.validatorSizeWei(), "funded to full validator size");
    }

    /// @notice The pod-backed flow through the identical path, so the pod-less result is read as
    ///         a difference in credential target and nothing else.
    function test_podBackedValidator_spinsUpAndFundsThroughOracle() public {
        address spawner = vm.addr(0xB0D1E56);

        (address etherFiNode, uint256 outDelta) = _spinUpValidator(spawner, /*createEigenPod=*/ true);

        address pod = address(IEtherFiNode(etherFiNode).getEigenPod());
        assertTrue(pod != address(0), "node has a pod");
        assertEq(managerInstance.withdrawalCredentialTarget(etherFiNode), pod, "pod is the target");
        assertEq(outDelta, liquidityPoolInstance.validatorSizeWei(), "funded to full validator size");
    }

    /// @notice Pins EtherFiAdmin's credential derivation to StakingManager's. These are separate
    ///         implementations of the same rule, and a disagreement is invisible until a top-up
    ///         reverts IncorrectBeaconRoot, so assert it directly for both regimes.
    function test_credentialTarget_isNodeWithoutPod_andPodWithOne() public {
        _grantValidatorCreationRoles();

        vm.prank(OPERATING_TIMELOCK);
        address podLess = stakingManagerInstance.instantiateEtherFiNode(false);
        vm.prank(OPERATING_TIMELOCK);
        address podBacked = stakingManagerInstance.instantiateEtherFiNode(true);

        assertEq(managerInstance.withdrawalCredentialTarget(podLess), podLess, "pod-less resolves to the node");
        assertEq(
            managerInstance.withdrawalCredentialTarget(podBacked),
            address(IEtherFiNode(podBacked).getEigenPod()),
            "pod-backed resolves to the pod"
        );

        // The 0x02 prefix and the 11 zero bytes are what the beacon chain reads; pin the layout.
        assertEq(
            managerInstance.addressToCompoundingWithdrawalCredentials(podLess),
            abi.encodePacked(bytes1(0x02), bytes11(0x0), podLess),
            "0x02 credentials point at the node"
        );
    }
}
