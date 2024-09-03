// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/EtherFiNode.sol";
import "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "../src/eigenlayer-interfaces/IEigenPodManager.sol";
import "../src/eigenlayer-interfaces/IEigenPod.sol";
import "../src/eigenlayer-interfaces/IDelayedWithdrawalRouter.sol";
import "../src/eigenlayer-libraries/BeaconChainProofs.sol";

import "./eigenlayer-utils/ProofParsing.sol";
import "./eigenlayer-mocks/BeaconChainOracleMock.sol";

import "forge-std/console2.sol";
import "forge-std/console.sol";


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
        /*
        vm.startPrank(eigenLayerEigenPodManager.owner());
        beaconChainOracleMock = new BeaconChainOracleMock();
        beaconChainOracle = IBeaconChainOracle(address(beaconChainOracleMock));
        eigenLayerEigenPodManager.updateBeaconChainOracle(beaconChainOracle);
        vm.stopPrank();
        */

        vm.startPrank(owner);
        liquidityPoolInstance.setRestakeBnftDeposits(true);
        vm.stopPrank();

        EtherFiNodesManager newManagerImpl = new EtherFiNodesManager();
        EtherFiNode newNodeImpl = new EtherFiNode(address(liquidityPool));

        vm.startPrank(managerInstance.owner());
        managerInstance.upgradeTo(address(newManagerImpl));
        vm.stopPrank();
        vm.startPrank(stakingManagerInstance.owner());
        stakingManagerInstance.upgradeEtherFiNode(address(newNodeImpl));
        vm.stopPrank();


    }

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


    function test_PartialWithdrawalPEPE() public {
        initializeRealisticFork(TESTNET_FORK);
        address owner = stakingManagerInstance.owner();

        // upgrade contract
        address newImpl = address(new EtherFiNode(address(liquidityPool)));
        vm.prank(owner);
        stakingManagerInstance.upgradeEtherFiNode(newImpl);

        vm.prank(owner);
        managerInstance.updateAdmin(owner, true);

        IEtherFiNode etherfiNode = IEtherFiNode(managerInstance.etherfiNodeAddress(1));
        IEigenPod pod = IEigenPod(etherfiNode.eigenPod());

        // expect to fail because not admin calling function
        vm.expectRevert("not admin");
        etherfiNode.queueEigenlayerPartialWithdrawal(2 gwei);

        uint256 queueBlock = block.number;
        vm.prank(owner);
        etherfiNode.queueEigenlayerPartialWithdrawal(2 gwei);

        // should fail if we simulate an in progress full withdrawal
        // (eigenpod has different number of active validators than etherfiNode)
        vm.prank(address(managerInstance));
        etherfiNode.updateNumberOfAssociatedValidators(0, 1);

        vm.prank(owner);
        vm.expectRevert(EtherFiNode.PendingFullWithdrawal.selector);
        etherfiNode.queueEigenlayerPartialWithdrawal(2 gwei);

        // undo
        vm.prank(address(managerInstance));
        etherfiNode.updateNumberOfAssociatedValidators(1, 0);

        // prepare to claim
        IStrategy[] memory strategies = new IStrategy[](1);
        uint256[] memory shares = new uint256[](1);
        strategies[0] = eigenLayerDelegationManager.beaconChainETHStrategy();
        shares[0] = 2 gwei;
        IDelegationManager.Withdrawal memory withdrawal = IDelegationManager.Withdrawal({
            staker: address(etherfiNode),
            delegatedTo: address(0x0),
            withdrawer: address(etherfiNode),
            nonce: 0,
            startBlock: uint32(queueBlock),
            strategies: strategies,
            shares: shares
        });

        // fail because not enough time has passed
        vm.prank(owner);
        vm.expectRevert("DelegationManager._completeQueuedWithdrawal: minWithdrawalDelayBlocks period has not yet passed");
        etherfiNode.completeEigenlayerPartialWithdrawal(withdrawal, 0);

        // wait for withdrawal period
        vm.warp(block.timestamp + (60 * 60 * 24 * 8));
        vm.roll(block.number + (7200*8));

        vm.prank(owner);
        etherfiNode.completeEigenlayerPartialWithdrawal(withdrawal, 0);
    }

    function test_PEPE() public {
        initializeRealisticFork(TESTNET_FORK);

        address newImpl = address(new EtherFiNode(address(liquidityPool)));
        vm.prank(stakingManagerInstance.owner());
        stakingManagerInstance.upgradeEtherFiNode(newImpl);

        address etherfiNode = address(managerInstance.etherfiNodeAddress(1));

        IEigenPod pod = IEigenPod(0xb2DE3E0380D7229Dc9e717342ed042E54EAaA620);
        console2.log(pod.withdrawableRestakedExecutionLayerGwei());

        uint256[] memory validatorIds = new uint256[](1);
        uint32[] memory timestamps = new uint32[](1);
        validatorIds[0] = 1;
        timestamps[0] = uint32(block.timestamp);

        address admin = address(0xD0d7F8a5a86d8271ff87ff24145Cf40CEa9F7A39);
        uint256 queueBlock = block.number;
        vm.prank(admin);
        managerInstance.processNodeExit(validatorIds, timestamps);

        // wait for the queue to be complete
        vm.roll(block.number + (7200 * 8));

        // recreate the withdrawal params used in processNodeExit()
        IStrategy[] memory strategies = new IStrategy[](1);
        uint256[] memory shares = new uint256[](1);
        uint256[] memory middlewareTimesIndexes = new uint256[](1);
        strategies[0] = eigenLayerDelegationManager.beaconChainETHStrategy();
        shares[0] = 32 ether;
        middlewareTimesIndexes[0] = 0;
        IDelegationManager.Withdrawal[] memory queuedWithdrawals = new IDelegationManager.Withdrawal[](1);
        queuedWithdrawals[0] = IDelegationManager.Withdrawal({
            staker: etherfiNode,
            delegatedTo: address(0),
            withdrawer: etherfiNode,
            nonce: uint96(eigenLayerDelegationManager.cumulativeWithdrawalsQueued(address(pod))),
            startBlock: uint32(queueBlock),
            strategies: strategies,
            shares: shares
        });

        vm.prank(admin);
        managerInstance.completeQueuedWithdrawals(validatorIds, queuedWithdrawals, middlewareTimesIndexes, true);

        // TODO(Dave): I have traced this execution and it fails at the end because
        // holesky liquidity pool as an incorrect valueOutOfLP value (the withdrawal works as expected)
        // We should correct that and fix this final clause.
        vm.prank(admin);
        vm.expectRevert();
        managerInstance.fullWithdraw(1);
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

    // https://holesky.beaconcha.in/validator/1644305#deposits
    function test_verifyWithdrawalCredentials_32ETH() public {

        vm.selectFork(vm.createFork(vm.envString("HISTORICAL_PROOF_RPC_URL")));

        int256 initialShares = eigenLayerEigenPodManager.podOwnerShares(podOwner);
        IEigenPod.ValidatorInfo memory validatorInfo = eigenPod.validatorPubkeyToInfo(pubkey);
        assertTrue(validatorInfo.status == IEigenPod.VALIDATOR_STATUS.INACTIVE, "Validator status should be INACTIVE");
        assertEq(validatorInfo.validatorIndex, 0);
        assertEq(validatorInfo.restakedBalanceGwei, 0);
        assertEq(validatorInfo.mostRecentBalanceUpdateTimestamp, 0);

        _beacon_process_32ETH_deposit();
        console2.log("initialShares:", initialShares);

        bytes4 selector = bytes4(keccak256("verifyWithdrawalCredentials(uint64,(bytes32,bytes),uint40[],bytes[],bytes32[][])"));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, oracleTimestamp, stateRootProof, validatorIndices, withdrawalCredentialProofs, validatorFields);
        vm.prank(owner);
        managerInstance.forwardEigenpodCall(validatorIds, data);

        int256 updatedShares = eigenLayerEigenPodManager.podOwnerShares(podOwner);
        console2.log("updatedShares:", updatedShares);

        validatorInfo = eigenPod.validatorPubkeyToInfo(pubkey);
        assertEq(updatedShares, initialShares+32e18, "Shares should be 32 ETH in wei after verifying withdrawal credentials");
        assertTrue(validatorInfo.status == IEigenPod.VALIDATOR_STATUS.ACTIVE, "Validator status should be ACTIVE");
        assertEq(validatorInfo.validatorIndex, validatorIndices[0], "Validator index should be set");
        assertEq(validatorInfo.restakedBalanceGwei, 32 ether / 1e9, "Restaked balance should be 32 eth");
        assertEq(validatorInfo.mostRecentBalanceUpdateTimestamp, oracleTimestamp, "Most recent balance update timestamp should be set");
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
        IDelegationManager.OperatorDetails memory detail = IDelegationManager.OperatorDetails({
            earningsReceiver: address(treasuryInstance),
            delegationApprover: address(0),
            stakerOptOutWindowBlocks: 0
        });
        eigenLayerDelegationManager.registerAsOperator(detail, "");
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

        // Confirm, the earningsReceiver is set to treasuryInstance
        assertEq(eigenLayerDelegationManager.earningsReceiver(operator), address(mainnet_earningsReceiver));
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

    function test_completeQueuedWithdrawals_338_for_withdrawal_from_undelegate() public {
        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = 338;
        uint32[] memory timeStamps = new uint32[](1);
        timeStamps[0] = 0;
        address nodeAddress = managerInstance.etherfiNodeAddress(validatorIds[0]);

        IDelegationManager mgr = managerInstance.delegationManager();

        // 1. completeQueuedWithdrawal
        // the withdrawal was queued by `undelegate` in https://etherscan.io/tx/0xd0e400ecd6711cf2f8e5ea97585c864db6d3ffb4d248d3e6d97a66b3683ec98b
        {
            // 
            // {
            // 'staker': '0x7aC9b51aB907715194F407C15191fce0F3771254',
            // 'delegatedTo': '0x5b9B3Cf0202a1a3Dc8f527257b7E6002D23D8c85', 
            // 'withdrawer': '0x7aC9b51aB907715194F407C15191fce0F3771254', 
            // 'nonce': 0, 
            // 'startBlock': 19692808, 
            // 'strategies': ['0xbeaC0eeEeeeeEEeEeEEEEeeEEeEeeeEeeEEBEaC0'], 
            // 'shares': [32000000000000000000]
            // }
            IDelegationManager.Withdrawal memory withdrawal;
            IERC20[] memory tokens = new IERC20[](1);
            IStrategy[] memory strategies = new IStrategy[](1);
            strategies[0] = IStrategy(0xbeaC0eeEeeeeEEeEeEEEEeeEEeEeeeEeeEEBEaC0);
            uint256[] memory shares = new uint256[](1);
            shares[0] = 32000000000000000000;
            withdrawal = IDelegationManager.Withdrawal({
                staker: 0x7aC9b51aB907715194F407C15191fce0F3771254,
                delegatedTo: 0x5b9B3Cf0202a1a3Dc8f527257b7E6002D23D8c85,
                withdrawer: 0x7aC9b51aB907715194F407C15191fce0F3771254,
                nonce: 0,
                startBlock: 19692808,
                strategies: strategies,
                shares: shares
            });      
            
            bytes32 withdrawalRoot = mgr.calculateWithdrawalRoot(withdrawal);
            assertTrue(mgr.pendingWithdrawals(withdrawalRoot));

            IDelegationManager.Withdrawal[] memory withdrawals = new IDelegationManager.Withdrawal[](1);
            uint256[] memory middlewareTimesIndexes = new uint256[](1);
            withdrawals[0] = withdrawal;
            middlewareTimesIndexes[0] = 0;

            vm.prank(owner);
            vm.expectRevert();
            EtherFiNode(payable(nodeAddress)).completeQueuedWithdrawals(withdrawals, middlewareTimesIndexes, false);

            vm.prank(owner);
            vm.expectRevert();
            managerInstance.completeQueuedWithdrawals(validatorIds, withdrawals, middlewareTimesIndexes, true);

            vm.prank(owner);
            managerInstance.completeQueuedWithdrawals(validatorIds, withdrawals, middlewareTimesIndexes, false);
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
        IDelegationManager.Withdrawal memory withdrawal;
        {
            IStrategy[] memory strategies = new IStrategy[](1);
            strategies[0] = mgr.beaconChainETHStrategy();
            uint256[] memory shares = new uint256[](1);
            shares[0] = 32 ether;
            withdrawal = IDelegationManager.Withdrawal({
                staker: nodeAddress,
                delegatedTo: mgr.delegatedTo(nodeAddress),
                withdrawer: nodeAddress,
                nonce: mgr.cumulativeWithdrawalsQueued(nodeAddress),
                startBlock: uint32(block.number),
                strategies: strategies,
                shares: shares
            });      
        }
        
        vm.prank(owner);
        managerInstance.processNodeExit(validatorIds, timeStamps);
    
        // 3. Wait
        // Wait 'minDelayBlock' after the `verifyAndProcessWithdrawals`
        {
            uint256 minDelayBlock = Math.max(mgr.minWithdrawalDelayBlocks(), mgr.strategyWithdrawalDelayBlocks(mgr.beaconChainETHStrategy()));
            vm.roll(block.number + minDelayBlock);
        }


        // 4. DelegationManager.completeQueuedWithdrawal            
        bytes32 withdrawalRoot = mgr.calculateWithdrawalRoot(withdrawal);

        IDelegationManager.Withdrawal[] memory withdrawals = new IDelegationManager.Withdrawal[](1);
        uint256[] memory middlewareTimesIndexes = new uint256[](1);
        withdrawals[0] = withdrawal;
        middlewareTimesIndexes[0] = 0;

        vm.prank(owner);
        vm.expectRevert();
        EtherFiNode(payable(nodeAddress)).completeQueuedWithdrawals(withdrawals, middlewareTimesIndexes, false);

        vm.prank(owner);
        vm.expectRevert();
        managerInstance.completeQueuedWithdrawals(validatorIds, withdrawals, middlewareTimesIndexes, false);

        vm.prank(owner);
        managerInstance.completeQueuedWithdrawals(validatorIds, withdrawals, middlewareTimesIndexes, true);
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

}
