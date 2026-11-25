// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@tests/behaviour-tests/prelude.t.sol";
import "@etherfi/interfaces/IDepositContract.sol";

/// @notice Top-ups of validators already funded to 32 ETH, sized per call by an oracle-operations
///         key and bounded on-chain by a per-validator principal cap, a rate limit and a
///         liquidity floor.
contract ValidatorTopUpsTest is PreludeTest {

    address spawner = vm.addr(0x70B0F1);
    address operator = vm.addr(0x70B0F2);

    struct Validator {
        address node;
        bytes creds;
        bytes pubkey;
        bytes32 pubkeyHash;
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------------  HELPERS  --------------------------------------
    //--------------------------------------------------------------------------------------

    function _registerOperator() internal {
        vm.prank(admin);
        liquidityPool.registerValidatorSpawner(spawner);
        vm.prank(admin);
        nodeOperatorManager.addToWhitelist(operator);
        vm.prank(operator);
        nodeOperatorManager.registerNodeOperator("test_ipfs_hash", 1000);
        fundContract(address(liquidityPool), 10000 ether);
    }

    /// @dev Runs register, the 1 ETH leg and, when `confirm` is set, the 31 ETH leg on a pod-less node.
    function _newValidator(bool confirm) internal returns (Validator memory v) {
        vm.deal(operator, 1 ether);
        vm.prank(operator);
        uint256 bidId = auctionManager.createBid{value: 0.1 ether}(1, 0.1 ether)[0];

        vm.prank(admin);
        v.node = stakingManager.instantiateEtherFiNode(/*createEigenPod=*/ false);
        v.creds = abi.encodePacked(bytes1(0x02), bytes11(0x0), v.node);
        v.pubkey = vm.randomBytes(48);
        v.pubkeyHash = etherFiNodesManager.calculateValidatorPubkeyHash(v.pubkey);
        bytes memory signature = vm.randomBytes(96);

        IStakingManager.DepositData memory createData = _depositData(v, signature, 1 ether);
        vm.prank(spawner);
        liquidityPool.batchRegister(toArray(createData), toArray_u256(bidId), v.node);
        vm.prank(admin);
        liquidityPool.batchCreateBeaconValidators(toArray(createData), toArray_u256(bidId), v.node);

        if (confirm) {
            // built before the prank: generateDepositDataRoot is itself a call and would consume it
            IStakingManager.DepositData[] memory fundData = toArray(_depositData(v, signature, 31 ether));
            vm.prank(admin);
            liquidityPool.confirmAndFundBeaconValidators(fundData);
        }
    }

    function _depositData(Validator memory v, bytes memory signature, uint256 amount) internal view returns (IStakingManager.DepositData memory) {
        return IStakingManager.DepositData({
            publicKey: v.pubkey,
            signature: signature,
            depositDataRoot: depositDataRootGenerator.generateDepositDataRoot(v.pubkey, signature, v.creds, amount),
            ipfsHashForEncryptedValidatorKey: "test_ipfs_hash"
        });
    }

    /// @dev The bucket starts empty and fills at the refill rate, so this warps `fillSeconds` after setting it.
    function _configure(uint256 maxPrincipal, uint256 floor, uint64 capacityGwei, uint64 refillGwei, uint256 fillSeconds) internal {
        vm.startPrank(admin); // OPERATION_TIMELOCK_ROLE
        stakingManager.setMaxValidatorPrincipalWei(maxPrincipal);
        stakingManager.setMinLiquidityPoolBalanceWei(floor);
        stakingManager.setTopUpLimit(capacityGwei, refillGwei);
        vm.stopPrank();
        vm.warp(block.timestamp + fillSeconds);
    }

    function _configureOpen() internal {
        _configure(2048 ether, 0, type(uint64).max, type(uint64).max, 1);
    }

    function _topUps(bytes memory pubkey, uint256 amount) internal pure returns (IStakingManager.TopUp[] memory t) {
        t = new IStakingManager.TopUp[](1);
        t[0] = IStakingManager.TopUp({publicKey: pubkey, amount: amount});
    }

    function _topUp(bytes memory pubkey, uint256 amount) internal {
        vm.prank(admin); // ORACLE_OPERATIONS_ROLE
        liquidityPool.topUpValidators(_topUps(pubkey, amount));
    }

    function _expectTopUpRevert(bytes memory pubkey, uint256 amount, bytes4 selector) internal {
        IStakingManager.TopUp[] memory t = _topUps(pubkey, amount);
        vm.expectRevert(selector);
        vm.prank(admin);
        liquidityPool.topUpValidators(t);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  ACTIVATION LEG  -------------------------------------
    //--------------------------------------------------------------------------------------

    function test_confirm_fundsTo32AndRecordsPrincipal() public {
        _registerOperator();
        uint256 outBefore = liquidityPool.totalValueOutOfLp();

        Validator memory v = _newValidator(true);

        assertEq(stakingManager.validatorPrincipalWei(v.pubkeyHash), 32 ether);
        assertEq(liquidityPool.totalValueOutOfLp(), outBefore + 32 ether);
    }

    function test_confirm_secondCallForSamePubkeyReverts() public {
        _registerOperator();
        Validator memory v = _newValidator(true);

        IStakingManager.DepositData[] memory again = toArray(_depositData(v, vm.randomBytes(96), 31 ether));
        vm.expectRevert(IStakingManager.ValidatorAlreadyFunded.selector);
        vm.prank(admin);
        liquidityPool.confirmAndFundBeaconValidators(again);
    }

    //--------------------------------------------------------------------------------------
    //---------------------------------  TOP-UPS  ------------------------------------------
    //--------------------------------------------------------------------------------------

    function test_topUp_depositsToNodeCredentialsWithZeroSignature() public {
        _registerOperator();
        _configureOpen();
        Validator memory v = _newValidator(true);

        bytes memory zeroSignature = new bytes(96);
        bytes32 root = depositDataRootGenerator.generateDepositDataRoot(v.pubkey, zeroSignature, v.creds, 100 ether);
        uint256 outBefore = liquidityPool.totalValueOutOfLp();
        uint256 inBefore = liquidityPool.totalValueInLp();

        vm.expectCall(
            address(stakingDepositContract),
            100 ether,
            abi.encodeCall(IDepositContract.deposit, (v.pubkey, v.creds, zeroSignature, root))
        );
        vm.expectEmit(true, false, false, true, address(stakingManager));
        emit IStakingManager.ValidatorToppedUp(v.pubkeyHash, 100 ether, 132 ether);
        _topUp(v.pubkey, 100 ether);

        assertEq(stakingManager.validatorPrincipalWei(v.pubkeyHash), 132 ether);
        assertEq(liquidityPool.totalValueOutOfLp(), outBefore + 100 ether);
        assertEq(liquidityPool.totalValueInLp(), inBefore - 100 ether);
    }

    function test_topUp_disabledUntilConfigured() public {
        _registerOperator();
        Validator memory v = _newValidator(true);

        _expectTopUpRevert(v.pubkey, 1 ether, IStakingManager.ExceedsMaxValidatorPrincipal.selector);
    }

    function test_topUp_rejectsValidatorStillAtOneEth() public {
        _registerOperator();
        _configureOpen();
        Validator memory v = _newValidator(false);

        _expectTopUpRevert(v.pubkey, 1 ether, IStakingManager.ValidatorNotFunded.selector);
    }

    function test_topUp_rejectsUnknownPubkey() public {
        _registerOperator();
        _configureOpen();

        _expectTopUpRevert(vm.randomBytes(48), 1 ether, IStakingManager.ValidatorNotFunded.selector);
    }

    function test_topUp_principalCapIsInclusive() public {
        _registerOperator();
        _configure(2000 ether, 0, type(uint64).max, type(uint64).max, 1);
        Validator memory v = _newValidator(true);

        _topUp(v.pubkey, 1968 ether);
        assertEq(stakingManager.validatorPrincipalWei(v.pubkeyHash), 2000 ether);

        _expectTopUpRevert(v.pubkey, 1 ether, IStakingManager.ExceedsMaxValidatorPrincipal.selector);
    }

    function test_topUp_capAppliesAcrossRepeatsInOneBatch() public {
        _registerOperator();
        _configure(100 ether, 0, type(uint64).max, type(uint64).max, 1);
        Validator memory v = _newValidator(true);

        IStakingManager.TopUp[] memory t = new IStakingManager.TopUp[](2);
        t[0] = IStakingManager.TopUp({publicKey: v.pubkey, amount: 40 ether});
        t[1] = IStakingManager.TopUp({publicKey: v.pubkey, amount: 40 ether});
        vm.expectRevert(IStakingManager.ExceedsMaxValidatorPrincipal.selector);
        vm.prank(admin);
        liquidityPool.topUpValidators(t);

        t[1].amount = 28 ether;
        vm.prank(admin);
        liquidityPool.topUpValidators(t);
        assertEq(stakingManager.validatorPrincipalWei(v.pubkeyHash), 100 ether);
    }

    function test_topUp_rateLimitBlocksThenRefills() public {
        _registerOperator();
        Validator memory v = _newValidator(true);
        _configure(2048 ether, 0, uint64(100 ether / 1 gwei), uint64(1 ether / 1 gwei), 0);

        // configured buckets start empty
        _expectTopUpRevert(v.pubkey, 1 ether, IStakingManager.TopUpRateLimitExceeded.selector);
        vm.warp(block.timestamp + 100);

        _topUp(v.pubkey, 100 ether);
        _expectTopUpRevert(v.pubkey, 1 ether, IStakingManager.TopUpRateLimitExceeded.selector);

        vm.warp(block.timestamp + 10);
        _topUp(v.pubkey, 10 ether);
        _expectTopUpRevert(v.pubkey, 1 ether, IStakingManager.TopUpRateLimitExceeded.selector);
    }

    function test_topUp_liquidityFloorIsInclusive() public {
        _registerOperator();
        Validator memory v = _newValidator(true);
        _configure(2048 ether, liquidityPool.totalValueInLp() - 50 ether, type(uint64).max, type(uint64).max, 1);

        _expectTopUpRevert(v.pubkey, 51 ether, IStakingManager.InsufficientLiquidityPoolBalance.selector);
        _topUp(v.pubkey, 50 ether);
        assertEq(liquidityPool.totalValueInLp(), stakingManager.minLiquidityPoolBalanceWei());
    }

    function test_topUp_rejectsAmountsTheDepositContractRefuses() public {
        _registerOperator();
        _configureOpen();
        Validator memory v = _newValidator(true);

        _expectTopUpRevert(v.pubkey, 0.5 ether, IStakingManager.InvalidTopUpAmount.selector);
        _expectTopUpRevert(v.pubkey, 1 ether + 1, IStakingManager.InvalidTopUpAmount.selector);
    }

    //--------------------------------------------------------------------------------------
    //--------------------------------  ACCESS CONTROL  ------------------------------------
    //--------------------------------------------------------------------------------------

    function test_topUp_requiresOracleOperations() public {
        IStakingManager.TopUp[] memory t = _topUps(vm.randomBytes(48), 1 ether);
        vm.expectRevert(RoleRegistry.OnlyOracleOperations.selector);
        vm.prank(makeAddr("rando"));
        liquidityPool.topUpValidators(t);
    }

    function test_topUp_stakingManagerOnlyAcceptsLiquidityPool() public {
        IStakingManager.TopUp[] memory t = _topUps(vm.randomBytes(48), 1 ether);
        vm.deal(admin, 1 ether);
        vm.expectRevert(IStakingManager.InvalidCaller.selector);
        vm.prank(admin);
        stakingManager.topUpValidators{value: 1 ether}(t);
    }

    function test_setters_requireOperatingTimelock() public {
        address rando = makeAddr("rando");
        vm.startPrank(rando);
        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        stakingManager.setMaxValidatorPrincipalWei(2048 ether);
        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        stakingManager.setMinLiquidityPoolBalanceWei(0);
        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        stakingManager.setTopUpLimit(1, 1);
        vm.stopPrank();
    }

    function test_setMaxValidatorPrincipal_boundedBy32And2048() public {
        vm.startPrank(admin);
        vm.expectRevert(IStakingManager.InvalidValidatorSize.selector);
        stakingManager.setMaxValidatorPrincipalWei(32 ether - 1);
        vm.expectRevert(IStakingManager.InvalidValidatorSize.selector);
        stakingManager.setMaxValidatorPrincipalWei(2048 ether + 1);
        stakingManager.setMaxValidatorPrincipalWei(32 ether);
        stakingManager.setMaxValidatorPrincipalWei(2048 ether);
        vm.stopPrank();
        assertEq(stakingManager.maxValidatorPrincipalWei(), 2048 ether);
    }
}
