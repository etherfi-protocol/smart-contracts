// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../src/EtherFiNode.sol";

import "../src/eigenlayer-interfaces/IDelayedWithdrawalRouter.sol";
import "../src/eigenlayer-interfaces/IEigenPod.sol";
import "../src/eigenlayer-interfaces/IEigenPodManager.sol";

import "../src/eigenlayer-libraries/BeaconChainProofs.sol";
import "./TestSetup.sol";
import "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import "./eigenlayer-mocks/BeaconChainOracleMock.sol";
import "./eigenlayer-utils/ProofParsing.sol";

import "forge-std/console.sol";
import "forge-std/console2.sol";

contract EigenLayerIntegraitonTest is TestSetup, ProofParsing {
    address p2p;
    address dsrv;
    address etherfi_avs_operator_1;

    uint256[] validatorIds;
    uint256 validatorId;
    IEigenPod eigenPod;
    address podOwner;
    bytes pubkey;
    EtherFiNode ws;

    // Params to _verifyWithdrawalCredentials
    uint64 oracleTimestamp;
    BeaconChainProofs.StateRootProof stateRootProof;
    uint40[] validatorIndices;
    bytes[] withdrawalCredentialProofs;
    bytes[] validatorFieldsProofs;
    bytes32[][] validatorFields;

    function setUp() public {
        /*
        initializeRealisticFork(MAINNET_FORK);

        // yes bob!
        p2p = address(1000);
        dsrv = address(1001);

        // - Mainnet
        // bid Id = validator Id = 21397
        validatorId = 21397;
        pubkey = hex"a9c09c47ad6c0c5c397521249be41c8b81b139c3208923ec3c95d7f99c57686ab66fe75ea20103a1291578592d11c2c2";

        // {EigenPod, EigenPodOwner} used in EigenLayer's unit test
        eigenPod = IEigenPod(managerInstance.getEigenPod(validatorId));
        podOwner = managerInstance.etherfiNodeAddress(validatorId);
        validatorIds = new uint256[](1);
        validatorIds[0] = validatorId;
        ws = EtherFiNode(payable(podOwner));

        // Override with Mock
        vm.startPrank(eigenLayerEigenPodManager.owner());
        beaconChainOracleMock = new BeaconChainOracleMock();
        beaconChainOracle = IBeaconChainOracle(address(beaconChainOracleMock));
        eigenLayerEigenPodManager.updateBeaconChainOracle(beaconChainOracle);
        vm.stopPrank();

        vm.startPrank(owner);
        liquidityPoolInstance.setRestakeBnftDeposits(true);
        vm.stopPrank();

        EtherFiNodesManager newManagerImpl = new EtherFiNodesManager(address(0x0), address(0x0));
        EtherFiNode newNodeImpl = new EtherFiNode(address(0x0), address(0x0), address(0x0), address(0x0));

        vm.startPrank(managerInstance.owner());
        managerInstance.upgradeTo(address(newManagerImpl));
        vm.stopPrank();
        vm.startPrank(stakingManagerInstance.owner());
        stakingManagerInstance.upgradeEtherFiNode(address(newNodeImpl));
        vm.stopPrank();

        */
    }

    /*
    function _setWithdrawalCredentialParams() public {
        validatorIndices = new uint40[](1);
        withdrawalCredentialProofs = new bytes[](1);
        validatorFieldsProofs = new bytes[](1);
        validatorFields = new bytes32[][](1);

        // Set beacon state root, validatorIndex
        stateRootProof.beaconStateRoot = getBeaconStateRoot();
        stateRootProof.proof = getStateRootProof();
        validatorIndices[0] = uint40(getValidatorIndex());
        withdrawalCredentialProofs[0] = abi.encodePacked(getWithdrawalCredentialProof()); // Validator fields are proven here
        // validatorFieldsProofs[0] = abi.encodePacked(getValidatorFieldsProof());
        validatorFields[0] = getValidatorFields();
    }

    function _beacon_process_1ETH_deposit() internal {
        setJSON("./test/eigenlayer-utils/test-data/ValidatorFieldsProof_1293592_8654000.json");

        _setWithdrawalCredentialParams();
    }

    function _beacon_process_32ETH_deposit() internal {

        setJSON("./test/eigenlayer-utils/test-data/mainnet_withdrawal_credential_proof_1293592_1712964563.json");
        oracleTimestamp = 1712964563;
        // timestamp doesn't seem to get set by custom RPC for even though block does
        vm.warp(1712974563);

        _setWithdrawalCredentialParams();
    }

    function _beacon_process_partial_withdrawals() internal {
        // TODO
    }

    function create_validator() public returns (uint256, address, EtherFiNode) {
        uint256[] memory validatorIds = launch_validator(1, 0, true);
        address nodeAddress = managerInstance.etherfiNodeAddress(validatorIds[0]);
        EtherFiNode node = EtherFiNode(payable(nodeAddress));

        return (validatorIds[0], nodeAddress, node);
    }

    function test_verifyAndProcessWithdrawals_OnlyOnce() public {
        test_verifyWithdrawalCredentials_32ETH();

        bytes4 selector = bytes4(keccak256("verifyWithdrawalCredentials(uint64,(bytes32,bytes),uint40[],bytes[],bytes32[][])"));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, oracleTimestamp, stateRootProof, validatorIndices, withdrawalCredentialProofs, validatorFields);

        // Can perform 'verifyWithdrawalCredentials' only once
        vm.prank(owner);
        vm.expectRevert("EigenPod.verifyCorrectWithdrawalCredentials: Validator must be inactive to prove withdrawal credentials");
        managerInstance.forwardEigenpodCall(validatorIds, data);
        vm.stopPrank();
    }


    function test_verifyBalanceUpdates_FAIL_1() public {

        vm.selectFork(vm.createFork(vm.envString("HISTORICAL_PROOF_RPC_URL")));
        _beacon_process_32ETH_deposit();

        bytes4 selector = bytes4(keccak256("verifyBalanceUpdates(uint64,uint40[],(bytes32,bytes),bytes[],bytes32[][])"));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, oracleTimestamp, validatorIndices, stateRootProof, withdrawalCredentialProofs, validatorFields);

        IEigenPod.ValidatorInfo memory validatorInfo = eigenPod.validatorPubkeyToInfo(pubkey);

        // Calling 'verifyBalanceUpdates' before 'verifyWithdrawalCredentials' should fail
        vm.prank(owner);
        vm.expectRevert("EigenPod.verifyBalanceUpdate: Validator not active");
        managerInstance.forwardEigenpodCall(validatorIds, data);
        vm.stopPrank();

        vm.warp(oracleTimestamp + 5 hours);

        // If the proof is too old, it should fail
        vm.prank(owner);
        vm.expectRevert("EigenPod.verifyBalanceUpdates: specified timestamp is too far in past");
        managerInstance.forwardEigenpodCall(validatorIds, data);
        vm.stopPrank();
    }

    function test_createDelayedWithdrawal() public {
        test_verifyWithdrawalCredentials_32ETH();
        address delayedWithdrawalRouter = address(managerInstance.delayedWithdrawalRouter());

        bytes4 selector = bytes4(keccak256("createDelayedWithdrawal(address,address)"));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, podOwner, alice);

        // whitelist this external call
        vm.prank(managerInstance.owner());
        managerInstance.updateAllowedForwardedExternalCalls(selector, delayedWithdrawalRouter, true);

        vm.prank(owner);
        vm.expectRevert("DelayedWithdrawalRouter.onlyEigenPod: not podOwner's EigenPod");
        managerInstance.forwardExternalCall(validatorIds, data, delayedWithdrawalRouter);
    }

    function test_recoverTokens() public {

        bytes4 selector = bytes4(keccak256("recoverTokens(address[],uint256[],address)"));
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        address[] memory recipients = new address[](1);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, tokens, amounts, recipients);

        vm.prank(owner);
        vm.expectRevert("NOT_ALLOWED");
        managerInstance.forwardEigenpodCall(validatorIds, data);
    }

    function _registerAsOperator(address avs_operator) internal {
        assertEq(eigenLayerDelegationManager.isOperator(avs_operator), false);

        vm.startPrank(avs_operator);
        address delegationApprover = address(0);
        uint32 allocationDelay = 0;
        eigenLayerDelegationManager.registerAsOperator(delegationApprover, allocationDelay, "");
        vm.stopPrank();

        assertEq(eigenLayerDelegationManager.isOperator(avs_operator), true);
    }

    function test_registerAsOperator() public {
        _registerAsOperator(p2p);
        _registerAsOperator(dsrv);
    }

    // activateStaking & verifyWithdrawalCredentials & delegate to p2p
    function test_delegateTo() public {

        test_verifyWithdrawalCredentials_32ETH();

        etherfi_avs_operator_1 = 0xfB487f216CA24162119C0C6Ae015d680D7569C2f;

        address operator = etherfi_avs_operator_1;
        address mainnet_earningsReceiver = 0x88C3c0AeAC97287E71D78bb97138727A60b2623b;
        address delegationManager = address(managerInstance.delegationManager());
        address delayedWithdrawalRouter = address(managerInstance.delayedWithdrawalRouter());


        test_registerAsOperator();

        bytes4 selector = bytes4(keccak256("delegateTo(address,(bytes,uint256),bytes32)"));
        IDelegationManager.SignatureWithExpiry memory signatureWithExpiry;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, operator, signatureWithExpiry, bytes32(0));

        // whitelist this external call
        vm.prank(managerInstance.owner());
        managerInstance.updateAllowedForwardedExternalCalls(selector, delegationManager, true);

        assertEq(eigenLayerDelegationManager.isDelegated(podOwner), false);

        vm.startPrank(owner);
        managerInstance.forwardExternalCall(validatorIds, data, delegationManager);
        vm.stopPrank();

        assertEq(eigenLayerDelegationManager.isDelegated(podOwner), true);
    }

    function test_undelegate() public {
        // createOrSelectFork(vm.envString("HISTORICAL_PROOF_RPC_URL"));
        address delegationManager = address(managerInstance.delegationManager());

        // 1. activateStaking & verifyWithdrawalCredentials & delegate to p2p & undelegate from p2p
        {
            bytes4 selector = bytes4(keccak256("undelegate(address)"));
            bytes[] memory data = new bytes[](1);
            data[0] = abi.encodeWithSelector(selector, podOwner);

            // whitelist this external call
            vm.prank(managerInstance.owner());
            managerInstance.updateAllowedForwardedExternalCalls(selector, delegationManager, true);

            vm.prank(owner);
            vm.expectRevert("DelegationManager.undelegate: staker must be delegated to undelegate");
            managerInstance.forwardExternalCall(validatorIds, data, delegationManager);

            test_delegateTo();

            vm.prank(owner);
            managerInstance.forwardExternalCall(validatorIds, data, delegationManager);
        }

        // 2. delegate to dsrv
        {
            bytes4 selector = bytes4(keccak256("delegateTo(address,(bytes,uint256),bytes32)"));
            IDelegationManager.SignatureWithExpiry memory signatureWithExpiry;
            bytes[] memory data = new bytes[](1);
            data[0] = abi.encodeWithSelector(selector, dsrv, signatureWithExpiry, bytes32(0));

            // whitelist this external call
            vm.prank(managerInstance.owner());
            managerInstance.updateAllowedForwardedExternalCalls(selector, delegationManager, true);

            vm.startPrank(owner);
            managerInstance.forwardExternalCall(validatorIds, data, delegationManager);
            vm.stopPrank();
        }
    }

    function test_completeQueuedWithdrawals_338_e2e() public {
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = 338;
        uint32[] memory timeStamps = new uint32[](1);
        timeStamps[0] = 0;
        address nodeAddress = managerInstance.etherfiNodeAddress(validatorIds[0]);

        IDelegationManager mgr = managerInstance.delegationManager();

        // 1. completeQueuedWithdrawal for withdrawal from undelegate
        test_completeQueuedWithdrawals_338_for_withdrawal_from_undelegate();

        // 2. call `ProcessNodeExit` to initiate the queued withdrawal
        IDelegationManagerTypes.Withdrawal memory withdrawal;
        {
            IStrategy[] memory strategies = new IStrategy[](1);
            strategies[0] = mgr.beaconChainETHStrategy();
            uint256[] memory shares = new uint256[](1);
            shares[0] = 32 ether;
            withdrawal = IDelegationManagerTypes.Withdrawal({
                staker: nodeAddress,
                delegatedTo: mgr.delegatedTo(nodeAddress),
                withdrawer: nodeAddress,
                nonce: mgr.cumulativeWithdrawalsQueued(nodeAddress),
                startBlock: uint32(block.number),
                strategies: strategies,
                scaledShares: shares
            });
        }

        vm.prank(owner);
        managerInstance.processNodeExit(validatorIds, timeStamps);

        // 3. Wait
        // Wait 'minDelayBlock' after the `verifyAndProcessWithdrawals`
        {
            uint256 minDelayBlock = mgr.minWithdrawalDelayBlocks();
            vm.roll(block.number + minDelayBlock);
        }


        // 4. DelegationManager.completeQueuedWithdrawal
        bytes32 withdrawalRoot = mgr.calculateWithdrawalRoot(withdrawal);

        IDelegationManager.Withdrawal[] memory withdrawals = new IDelegationManager.Withdrawal[](1);
        withdrawals[0] = withdrawal;

        vm.prank(owner);
        vm.expectRevert();
        EtherFiNode(payable(nodeAddress)).completeQueuedWithdrawals(withdrawals, false);

        vm.prank(owner);
        vm.expectRevert();
        managerInstance.completeQueuedWithdrawals(validatorIds, withdrawals, false);

        vm.prank(owner);
        managerInstance.completeQueuedWithdrawals(validatorIds, withdrawals, true);
    }

    // Only {operatingAdmin / Admin / Owner} can perform EigenLayer-related actions
    function test_access_control() public {
        address el_operating_admin = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;
        vm.startPrank(el_operating_admin);

        bytes4 selector = bytes4(keccak256(""));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector);

        address eigenPodManager = address(managerInstance.eigenPodManager());
        address delegationManager = address(managerInstance.delegationManager());
        address delayedWithdrawalRouter = address(managerInstance.delayedWithdrawalRouter());

        // FAIL
        bytes4 selector1 = bytes4(keccak256("nonBeaconChainETHBalanceWei()"));
        data[0] = abi.encodeWithSelector(selector1);
        vm.expectRevert();
        managerInstance.forwardEigenpodCall(validatorIds, data);

        bytes4 selector2 = bytes4(keccak256("ethPOS()"));
        data[0] = abi.encodeWithSelector(selector2);
        vm.expectRevert();
        managerInstance.forwardExternalCall(validatorIds, data, eigenPodManager);

        bytes4 selector3 = bytes4(keccak256("domainSeparator()"));
        data[0] = abi.encodeWithSelector(selector3);
        vm.expectRevert();
        managerInstance.forwardExternalCall(validatorIds, data, delegationManager);

        bytes4 selector4 = bytes4(keccak256("withdrawalDelayBlocks()"));
        data[0] = abi.encodeWithSelector(selector4);
        vm.expectRevert();
        managerInstance.forwardExternalCall(validatorIds, data, delayedWithdrawalRouter);

        vm.stopPrank();

        vm.startPrank(managerInstance.owner());
        managerInstance.updateAllowedForwardedEigenpodCalls(selector1, true);
        managerInstance.updateAllowedForwardedExternalCalls(selector2, eigenPodManager, true);
        managerInstance.updateAllowedForwardedExternalCalls(selector3, delegationManager, true);
        managerInstance.updateAllowedForwardedExternalCalls(selector4, delayedWithdrawalRouter, true);
        vm.stopPrank();

        // SUCCEEDS

        data[0] = abi.encodeWithSelector(selector1);
        managerInstance.forwardEigenpodCall(validatorIds, data);

        data[0] = abi.encodeWithSelector(selector2);
        managerInstance.forwardExternalCall(validatorIds, data, eigenPodManager);

        data[0] = abi.encodeWithSelector(selector3);
        managerInstance.forwardExternalCall(validatorIds, data, delegationManager);

        data[0] = abi.encodeWithSelector(selector4);
        managerInstance.forwardExternalCall(validatorIds, data, delayedWithdrawalRouter);
    }

    function test_deployment_bytecode() public {
        initializeRealisticFork(MAINNET_FORK);
        EtherFiNodesManager etherFiNodesManagerImplementation = new EtherFiNodesManager();
        address etherFiNodesManagerImplAddress = address(0xE9EE6923D41Cf5F964F11065436BD90D4577B5e4);

        EtherFiNode etherFiNodeImplementation = new EtherFiNode();
        address etherFiNodeImplAddress = address(0xc5F2764383f93259Fba1D820b894B1DE0d47937e);

        EtherFiRestaker etherFiRestakerImplementation = new EtherFiRestaker(address(0x7750d328b314EfFa365A0402CcfD489B80B0adda));
        address etherFiRestakerImplAddress = address(0x0052F731a6BEA541843385ffBA408F52B74Cb624);

        verifyContractByteCodeMatch(etherFiNodesManagerImplAddress, address(etherFiNodesManagerImplementation));
        verifyContractByteCodeMatch(etherFiNodeImplAddress, address(etherFiNodeImplementation));
        verifyContractByteCodeMatch(etherFiRestakerImplAddress, address(etherFiRestakerImplementation));
    }
    */
}
