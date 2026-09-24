// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@tests/behaviour-tests/prelude.t.sol";

/// @notice End-to-end validator spin-up on non-EigenPod withdrawal credentials, from registering a
///         validator spawner through to a funded 32 ETH validator.
contract NonEigenPodValidatorLifecycleTest is PreludeTest {

    address spawner = vm.addr(0x5A0E1);
    address operator = vm.addr(0x0BEEF1);

    struct Spun {
        address node;
        bytes creds;
        bytes pubkey;
        bytes signature;
        uint256 bidId;
        bytes32 pubkeyHash;
    }

    // Steps 1-4: spawner registered, operator whitelisted and registered, bid placed, pod-less node
    // created, credentials derived from the node.
    function _prepare() internal returns (Spun memory s) {
        vm.prank(admin);
        liquidityPool.registerValidatorSpawner(spawner);

        vm.prank(admin);
        nodeOperatorManager.addToWhitelist(operator);
        vm.prank(operator);
        nodeOperatorManager.registerNodeOperator("test_ipfs_hash", 1000);

        vm.deal(operator, 1 ether);
        vm.prank(operator);
        s.bidId = auctionManager.createBid{value: 0.1 ether}(1, 0.1 ether)[0];

        vm.prank(admin);
        s.node = stakingManager.instantiateEtherFiNode(/*createEigenPod=*/ false);

        s.creds = abi.encodePacked(bytes1(0x02), bytes11(0x0), s.node);
        s.pubkey = vm.randomBytes(48);
        s.signature = vm.randomBytes(96);
        s.pubkeyHash = etherFiNodesManager.calculateValidatorPubkeyHash(s.pubkey);

        fundContract(address(liquidityPool), 10000 ether);
    }

    function _depositData(Spun memory s, uint256 amount) internal view returns (IStakingManager.DepositData memory) {
        return IStakingManager.DepositData({
            publicKey: s.pubkey,
            signature: s.signature,
            depositDataRoot: depositDataRootGenerator.generateDepositDataRoot(s.pubkey, s.signature, s.creds, amount),
            ipfsHashForEncryptedValidatorKey: "test_ipfs_hash"
        });
    }

    function _hash(Spun memory s, IStakingManager.DepositData memory d) internal pure returns (bytes32) {
        return keccak256(abi.encode(d.publicKey, d.signature, d.depositDataRoot, d.ipfsHashForEncryptedValidatorKey, s.bidId, s.node));
    }

    //--------------------------------------------------------------------------------------
    //--------------------------------  HAPPY PATH  ----------------------------------------
    //--------------------------------------------------------------------------------------

    function test_lifecycle_spawnerToFundedValidator() public {
        Spun memory s = _prepare();

        assertTrue(nodeOperatorManager.registered(operator));
        assertTrue(auctionManager.isBidActive(s.bidId));
        assertEq(address(IEtherFiNode(s.node).getEigenPod()), address(0));
        assertEq(etherFiNodesManager.withdrawalCredentialTarget(s.node), s.node);
        assertEq(etherFiNodesManager.addressToCompoundingWithdrawalCredentials(s.node), s.creds);

        // Step 5: register
        IStakingManager.DepositData memory createData = _depositData(s, 1 ether);
        vm.prank(spawner);
        liquidityPool.batchRegister(toArray(createData), toArray_u256(s.bidId), s.node);
        assertEq(
            uint8(stakingManager.validatorCreationStatus(_hash(s, createData))),
            uint8(IStakingManager.ValidatorCreationStatus.REGISTERED)
        );

        // Step 6: 1 ETH deposit
        uint256 outBefore = liquidityPool.totalValueOutOfLp();
        uint256 inBefore = liquidityPool.totalValueInLp();
        vm.prank(admin);
        liquidityPool.batchCreateBeaconValidators(toArray(createData), toArray_u256(s.bidId), s.node);

        assertEq(
            uint8(stakingManager.validatorCreationStatus(_hash(s, createData))),
            uint8(IStakingManager.ValidatorCreationStatus.CONFIRMED)
        );
        assertEq(liquidityPool.totalValueOutOfLp(), outBefore + 1 ether);
        assertEq(liquidityPool.totalValueInLp(), inBefore - 1 ether);
        assertEq(address(etherFiNodesManager.etherFiNodeFromPubkeyHash(s.pubkeyHash)), s.node);
        assertFalse(auctionManager.isBidActive(s.bidId));

        // Step 7: 31 ETH top-up
        IStakingManager.DepositData memory fundData = _depositData(s, 31 ether);
        vm.prank(admin);
        liquidityPool.confirmAndFundBeaconValidators(toArray(fundData), 32 ether);

        assertEq(liquidityPool.totalValueOutOfLp(), outBefore + 32 ether);
        assertEq(liquidityPool.totalValueInLp(), inBefore - 32 ether);

        // Step 8: rewards and principal land on the node and sweep to the pool
        vm.deal(s.node, 2 ether);
        uint256 lpBefore = address(liquidityPool).balance;
        vm.prank(eigenlayerAdmin);
        etherFiNodesManager.sweepFunds(s.node);
        assertEq(address(liquidityPool).balance, lpBefore + 2 ether);
    }

    function test_lifecycle_legacyBidIdResolvesToTheNode() public {
        Spun memory s = _prepare();
        IStakingManager.DepositData memory d = _depositData(s, 1 ether);

        vm.prank(spawner);
        liquidityPool.batchRegister(toArray(d), toArray_u256(s.bidId), s.node);
        vm.prank(admin);
        liquidityPool.batchCreateBeaconValidators(toArray(d), toArray_u256(s.bidId), s.node);

        assertEq(etherFiNodesManager.etherfiNodeAddress(s.bidId), s.node);
        assertEq(etherFiNodesManager.etherfiNodeAddress(uint256(s.pubkeyHash)), s.node);
    }

    function test_lifecycle_twoValidatorsShareOneNode() public {
        Spun memory s = _prepare();

        vm.deal(operator, 1 ether);
        vm.prank(operator);
        uint256 secondBid = auctionManager.createBid{value: 0.1 ether}(1, 0.1 ether)[0];
        bytes memory pubkey2 = vm.randomBytes(48);
        bytes memory sig2 = vm.randomBytes(96);

        IStakingManager.DepositData memory d1 = _depositData(s, 1 ether);
        IStakingManager.DepositData memory d2 = IStakingManager.DepositData({
            publicKey: pubkey2,
            signature: sig2,
            depositDataRoot: depositDataRootGenerator.generateDepositDataRoot(pubkey2, sig2, s.creds, 1 ether),
            ipfsHashForEncryptedValidatorKey: "test_ipfs_hash"
        });

        IStakingManager.DepositData[] memory batch = new IStakingManager.DepositData[](2);
        batch[0] = d1;
        batch[1] = d2;
        uint256[] memory bids = new uint256[](2);
        bids[0] = s.bidId;
        bids[1] = secondBid;

        vm.prank(spawner);
        liquidityPool.batchRegister(batch, bids, s.node);
        vm.prank(admin);
        liquidityPool.batchCreateBeaconValidators(batch, bids, s.node);

        assertEq(address(etherFiNodesManager.etherFiNodeFromPubkeyHash(s.pubkeyHash)), s.node);
        assertEq(
            address(etherFiNodesManager.etherFiNodeFromPubkeyHash(etherFiNodesManager.calculateValidatorPubkeyHash(pubkey2))),
            s.node
        );
    }

    //--------------------------------------------------------------------------------------
    //--------------------------------  GATES  ---------------------------------------------
    //--------------------------------------------------------------------------------------

    function test_lifecycle_unregisteredSpawnerCannotRegister() public {
        Spun memory s = _prepare();
        IStakingManager.DepositData memory d = _depositData(s, 1 ether);

        vm.expectRevert(LiquidityPool.IncorrectCaller.selector);
        vm.prank(makeAddr("rando"));
        liquidityPool.batchRegister(toArray(d), toArray_u256(s.bidId), s.node);
    }

    function test_lifecycle_unregisteredSpawnerLosesAccess() public {
        Spun memory s = _prepare();
        IStakingManager.DepositData memory d = _depositData(s, 1 ether);

        vm.prank(admin);
        liquidityPool.unregisterValidatorSpawner(spawner);

        vm.expectRevert(LiquidityPool.IncorrectCaller.selector);
        vm.prank(spawner);
        liquidityPool.batchRegister(toArray(d), toArray_u256(s.bidId), s.node);
    }

    function test_lifecycle_cannotRegisterTwice() public {
        Spun memory s = _prepare();
        IStakingManager.DepositData memory d = _depositData(s, 1 ether);

        vm.prank(spawner);
        liquidityPool.batchRegister(toArray(d), toArray_u256(s.bidId), s.node);

        vm.expectRevert(IStakingManager.InvalidValidatorCreationStatus.selector);
        vm.prank(spawner);
        liquidityPool.batchRegister(toArray(d), toArray_u256(s.bidId), s.node);
    }

    function test_lifecycle_cannotCreateWithoutRegistering() public {
        Spun memory s = _prepare();
        IStakingManager.DepositData memory d = _depositData(s, 1 ether);

        vm.expectRevert(IStakingManager.InvalidValidatorCreationStatus.selector);
        vm.prank(admin);
        liquidityPool.batchCreateBeaconValidators(toArray(d), toArray_u256(s.bidId), s.node);
    }

    function test_lifecycle_cannotFundUnlinkedPubkey() public {
        Spun memory s = _prepare();
        // built before expectRevert: generateDepositDataRoot is itself a call and would consume it
        IStakingManager.DepositData[] memory d = toArray(_depositData(s, 31 ether));

        vm.expectRevert(IStakingManager.UnlinkedPubkey.selector);
        vm.prank(admin);
        liquidityPool.confirmAndFundBeaconValidators(d, 32 ether);
    }

    function test_lifecycle_credentialsForAnotherTargetAreRejected() public {
        Spun memory s = _prepare();

        bytes memory otherCreds = etherFiNodesManager.addressToCompoundingWithdrawalCredentials(address(0xFEE));
        IStakingManager.DepositData memory bad = IStakingManager.DepositData({
            publicKey: s.pubkey,
            signature: s.signature,
            depositDataRoot: depositDataRootGenerator.generateDepositDataRoot(s.pubkey, s.signature, otherCreds, 1 ether),
            ipfsHashForEncryptedValidatorKey: "test_ipfs_hash"
        });

        vm.expectRevert(IStakingManager.IncorrectBeaconRoot.selector);
        vm.prank(spawner);
        liquidityPool.batchRegister(toArray(bad), toArray_u256(s.bidId), s.node);
    }

    function test_lifecycle_topUpRootMustMatchTheRemainingAmount() public {
        Spun memory s = _prepare();
        IStakingManager.DepositData memory d = _depositData(s, 1 ether);

        vm.prank(spawner);
        liquidityPool.batchRegister(toArray(d), toArray_u256(s.bidId), s.node);
        vm.prank(admin);
        liquidityPool.batchCreateBeaconValidators(toArray(d), toArray_u256(s.bidId), s.node);

        // root built for 32 ETH rather than the 31 ETH actually deposited
        IStakingManager.DepositData[] memory bad = toArray(_depositData(s, 32 ether));

        vm.expectRevert(IStakingManager.IncorrectBeaconRoot.selector);
        vm.prank(admin);
        liquidityPool.confirmAndFundBeaconValidators(bad, 32 ether);
    }

    function test_lifecycle_onlyLiquidityPoolCanReachStakingManager() public {
        Spun memory s = _prepare();
        IStakingManager.DepositData memory d = _depositData(s, 1 ether);

        vm.expectRevert(IStakingManager.InvalidCaller.selector);
        vm.prank(spawner);
        stakingManager.registerBeaconValidators(toArray(d), toArray_u256(s.bidId), s.node);

        vm.expectRevert(IStakingManager.InvalidCaller.selector);
        vm.prank(spawner);
        stakingManager.createBeaconValidators(toArray(d), toArray_u256(s.bidId), s.node);
    }

    function test_lifecycle_nodeCreationIsGated() public {
        vm.expectRevert(RoleRegistry.OnlyExecutorOperations.selector);
        vm.prank(makeAddr("rando"));
        stakingManager.instantiateEtherFiNode(false);
    }
}
