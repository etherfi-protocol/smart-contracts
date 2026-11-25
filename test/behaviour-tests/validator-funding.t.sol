// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@tests/behaviour-tests/prelude.t.sol";
import "@etherfi/interfaces/IDepositContract.sol";

/// @notice LiquidityPool.fundValidators called directly by an oracle-operations key: the leg after
///         the 1 ETH deposit and later top-ups, sized per call. The oracle path through
///         EtherFiAdmin is covered in oracle-podless-funding.t.sol.
contract ValidatorFundingTest is PreludeTest {

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

    /// @dev Registers a validator on a new pod-less node and sends its 1 ETH leg.
    function _newValidator() internal returns (Validator memory v) {
        vm.deal(operator, 1 ether);
        vm.prank(operator);
        uint256 bidId = auctionManager.createBid{value: 0.1 ether}(1, 0.1 ether)[0];

        vm.prank(admin);
        v.node = stakingManager.instantiateEtherFiNode(/*createEigenPod=*/ false);
        v.creds = abi.encodePacked(bytes1(0x02), bytes11(0x0), v.node);
        v.pubkey = vm.randomBytes(48);
        v.pubkeyHash = etherFiNodesManager.calculateValidatorPubkeyHash(v.pubkey);
        bytes memory signature = vm.randomBytes(96);

        IStakingManager.DepositData memory createData = IStakingManager.DepositData({
            publicKey: v.pubkey,
            signature: signature,
            depositDataRoot: depositDataRootGenerator.generateDepositDataRoot(v.pubkey, signature, v.creds, 1 ether),
            ipfsHashForEncryptedValidatorKey: "test_ipfs_hash"
        });
        vm.prank(spawner);
        liquidityPool.batchRegister(toArray(createData), toArray_u256(bidId), v.node);
        vm.prank(admin);
        liquidityPool.batchCreateBeaconValidators(toArray(createData), toArray_u256(bidId), v.node);
    }

    function _fund(bytes memory pubkey, uint256 amount) internal {
        IStakingManager.ValidatorFunding[] memory f = toFundings(pubkey, amount);
        vm.prank(admin); // ORACLE_OPERATIONS_ROLE
        liquidityPool.fundValidators(f);
    }

    function _expectFundRevert(bytes memory pubkey, uint256 amount, bytes4 selector) internal {
        IStakingManager.ValidatorFunding[] memory f = toFundings(pubkey, amount);
        vm.expectRevert(selector);
        vm.prank(admin);
        liquidityPool.fundValidators(f);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------------  FUNDING  --------------------------------------
    //--------------------------------------------------------------------------------------

    function test_fund_depositsToNodeCredentialsWithZeroSignature() public {
        _registerOperator();
        Validator memory v = _newValidator();

        bytes memory zeroSignature = new bytes(96);
        bytes32 root = depositDataRootGenerator.generateDepositDataRoot(v.pubkey, zeroSignature, v.creds, 31 ether);
        uint256 outBefore = liquidityPool.totalValueOutOfLp();
        uint256 inBefore = liquidityPool.totalValueInLp();

        vm.expectCall(
            address(stakingDepositContract),
            31 ether,
            abi.encodeCall(IDepositContract.deposit, (v.pubkey, v.creds, zeroSignature, root))
        );
        vm.expectEmit(true, true, true, true, address(stakingManager));
        emit IStakingManager.validatorConfirmed(v.pubkeyHash, address(liquidityPool), address(liquidityPool), v.pubkey);
        _fund(v.pubkey, 31 ether);

        assertEq(liquidityPool.totalValueOutOfLp(), outBefore + 31 ether);
        assertEq(liquidityPool.totalValueInLp(), inBefore - 31 ether);
    }

    function test_fund_sameValidatorCanBeToppedUpAgain() public {
        _registerOperator();
        Validator memory v = _newValidator();
        uint256 outBefore = liquidityPool.totalValueOutOfLp();

        _fund(v.pubkey, 31 ether);
        _fund(v.pubkey, 500 ether);
        _fund(v.pubkey, 1 ether);

        assertEq(liquidityPool.totalValueOutOfLp(), outBefore + 532 ether);
    }

    function test_fund_manyValidatorsWithDifferentAmountsInOneCall() public {
        _registerOperator();
        Validator memory a = _newValidator();
        Validator memory b = _newValidator();
        uint256 outBefore = liquidityPool.totalValueOutOfLp();

        IStakingManager.ValidatorFunding[] memory f = new IStakingManager.ValidatorFunding[](2);
        f[0] = IStakingManager.ValidatorFunding({publicKey: a.pubkey, amount: 31 ether});
        f[1] = IStakingManager.ValidatorFunding({publicKey: b.pubkey, amount: 1999 ether});
        vm.prank(admin);
        liquidityPool.fundValidators(f);

        assertEq(liquidityPool.totalValueOutOfLp(), outBefore + 2030 ether);
    }

    function test_fund_rejectsPubkeyNotLinkedToANode() public {
        _registerOperator();

        _expectFundRevert(vm.randomBytes(48), 31 ether, IStakingManager.UnlinkedPubkey.selector);
    }

    function test_fund_rejectsAmountsTheDepositContractRefuses() public {
        _registerOperator();
        Validator memory v = _newValidator();

        _expectFundRevert(v.pubkey, 0.5 ether, IStakingManager.InvalidFundingAmount.selector);
        _expectFundRevert(v.pubkey, 1 ether + 1, IStakingManager.InvalidFundingAmount.selector);
        _expectFundRevert(v.pubkey, 2048 ether + 1 gwei, IStakingManager.InvalidFundingAmount.selector);
    }

    //--------------------------------------------------------------------------------------
    //--------------------------------  ACCESS CONTROL  ------------------------------------
    //--------------------------------------------------------------------------------------

    function test_fund_requiresOracleOperations() public {
        IStakingManager.ValidatorFunding[] memory f = toFundings(vm.randomBytes(48), 31 ether);
        vm.expectRevert(RoleRegistry.OnlyOracleOperations.selector);
        vm.prank(makeAddr("rando"));
        liquidityPool.fundValidators(f);
    }

    function test_fund_stakingManagerOnlyAcceptsLiquidityPool() public {
        IStakingManager.ValidatorFunding[] memory f = toFundings(vm.randomBytes(48), 31 ether);
        vm.deal(admin, 31 ether);
        vm.expectRevert(IStakingManager.InvalidCaller.selector);
        vm.prank(admin);
        stakingManager.fundValidators{value: 31 ether}(f);
    }
}
