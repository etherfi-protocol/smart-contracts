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

    event QueuedRestakingWithdrawal(uint256 indexed _validatorId, address indexed etherFiNode, bytes32[] withdrawalRoots);
    event WithdrawalQueued(bytes32 withdrawalRoot, IDelegationManager.Withdrawal withdrawal);
    event FullWithdrawal(uint256 indexed _validatorId, address indexed etherFiNode, uint256 toOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury);


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
        EtherFiNode newNodeImpl = new EtherFiNode();

        vm.startPrank(managerInstance.owner());
        managerInstance.upgradeTo(address(newManagerImpl));
        vm.stopPrank();
        vm.startPrank(stakingManagerInstance.owner());
        stakingManagerInstance.upgradeEtherFiNode(address(newNodeImpl));
        vm.stopPrank();
    }

    // better forking experience for cases when you have nested tests because of solidity stack limits
    mapping(string => uint256) createdForks;

    function createOrSelectFork(string memory forkURL) public {
        if (createdForks[forkURL] == 0) {
            createdForks[forkURL] = vm.createFork(forkURL);
        }
        vm.selectFork(createdForks[forkURL]);



        // upgrade fork to latest version of code
        address newManagerImpl = address(new EtherFiNodesManager());
        address newNodeImpl = address(new EtherFiNode());
        vm.prank(managerInstance.owner());
        managerInstance.upgradeTo(newManagerImpl);
        vm.prank(stakingManagerInstance.owner());
        stakingManagerInstance.upgradeEtherFiNode(newNodeImpl);

    }

    function test_fullWithdraw_812() public {

        createOrSelectFork(vm.envString("HISTORICAL_PROOF_812_WITHDRAWAL_RPC_URL"));


        uint256 validatorId = 812;
        address admin = managerInstance.owner();
        EtherFiNode node = EtherFiNode(payable(managerInstance.etherfiNodeAddress(validatorId)));
        IEigenPod pod = IEigenPod(node.eigenPod());

        uint256 nodeBalanceBeforeWithdrawal = address(node).balance;

        // at stack limit so need to subdivide tests
        test_completeQueuedWithdrawal_812();

        assertEq(address(node).balance, nodeBalanceBeforeWithdrawal + 32 ether, "Balance did not increase as expected");

        // my arbitrarily picked timestamp causes node operator to be fully punished
        // important property is just that funds flow successfully to appropriate parties
        vm.expectEmit(true, true, false, true);
        emit FullWithdrawal(validatorId, address(node), 0, 30026957263471875000, 2002788682428125000, 3305105100000000);
        managerInstance.fullWithdraw(validatorId);

        assertEq(address(node).balance, 0, "funds did not get withdrawn as expected");
    }

    // This test hits the local variable stack limit. You can call this test as a starting point for additional
    // tests of the the withdrawal flow
    function test_completeQueuedWithdrawal_812() public {
        createOrSelectFork(vm.envString("HISTORICAL_PROOF_812_WITHDRAWAL_RPC_URL"));

        // tenderly fork was made before role updates so update here
        setupRoleRegistry();

        IDelegationManager delegationManager = managerInstance.delegationManager();

        uint256 validatorId = 812;

        uint256[] memory validatorIds = new uint256[](1);
        uint32[] memory exitTimestamps = new uint32[](1);
        validatorIds[0] = validatorId;
        exitTimestamps[0] = 20206627;

        address admin = managerInstance.owner();
        EtherFiNode node = EtherFiNode(payable(managerInstance.etherfiNodeAddress(validatorId)));
        IEigenPod pod = IEigenPod(node.eigenPod());

        // Gather all fields required for recreating the Withdrawal struct. Quite a complicated object.
        // Our proof infra will be able to grab these fields by enumerating the DelegationManager.WithdrawalQueued event

        // only withdrawing eth not LSTs
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = delegationManager.beaconChainETHStrategy();

        // All shares proven by full withdrawal proof that wasn't immediately queued into delayedWithdrawalRouter
        // I believe this should always be exactly 32 eth per validator unless the validator had been slashed.
        // All the partial withdrawals including the partial portion of the full withdrawal were immediately queued into delayedWithdrawalRouter
        uint256[] memory shares = new uint256[](1);
        shares[0] = uint256(pod.withdrawableRestakedExecutionLayerGwei()) * 1 gwei;

        // how many withdrawals initiated by this eigenpod
        uint256 nonce = delegationManager.cumulativeWithdrawalsQueued(address(node));

        // block the original withdrawal was queued
        uint32 startBlock = 20216438;

        IDelegationManager.Withdrawal memory withdrawal = IDelegationManager.Withdrawal({
            staker: address(node),
            delegatedTo: address(0x5b9B3Cf0202a1a3Dc8f527257b7E6002D23D8c85),
            withdrawer: address(node),
            nonce: nonce,
            startBlock: startBlock,
            strategies: strategies,
            shares: shares
        });

        // withdrawal root is hash of the withdrawal object, "keccak256(abi.encode(withdrawal));"
        bytes32 withdrawalRoot = delegationManager.calculateWithdrawalRoot(withdrawal);
        assertEq(withdrawalRoot, 0x8a9e9fe2cb3ce091210d7b101553268a94c23f0d1f93b52ea3c04467731a9390);

        // ensure emitted event matches our simulation
        vm.expectEmit(false, false, false, true);
        emit WithdrawalQueued(withdrawalRoot, withdrawal);

        // check the event emitted by our contracts
        bytes32[] memory withdrawalRoots = new bytes32[](1);
        withdrawalRoots[0] = withdrawalRoot;
        vm.expectEmit(true, true, false, true);
        emit QueuedRestakingWithdrawal(validatorId, address(node), withdrawalRoots);

        // actual exit call that will result in the both of the above events and the queuing of the withdrawal
        vm.prank(admin);
        managerInstance.processNodeExit(validatorIds, exitTimestamps);

        // prepare to trigger claim from EtherfiNodesManager
        uint256[] memory middlewareTimeIndexes = new uint256[](1); // currently unused by eigenlayer
        IDelegationManager.Withdrawal[] memory withdrawals = new IDelegationManager.Withdrawal[](1);
        withdrawals[0] = withdrawal;

        // claim should fail because not enough time has passed
        vm.expectRevert("DelegationManager._completeQueuedWithdrawal: minWithdrawalDelayBlocks period has not yet passed");
        vm.prank(admin);
        managerInstance.completeQueuedWithdrawals(validatorIds, withdrawals, middlewareTimeIndexes);

        // wait 7 days
        vm.roll(block.number + 7200 * 7);

        // complete the withdrawal to the pod
        vm.prank(admin);
        managerInstance.completeQueuedWithdrawals(validatorIds, withdrawals, middlewareTimeIndexes);
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

    function test_verifyAndProcessWithdrawals_OnlyOnce() public {
        test_verifyWithdrawalCredentials_32ETH();
        
        bytes4 selector = bytes4(keccak256("verifyWithdrawalCredentials(uint64,(bytes32,bytes),uint40[],bytes[],bytes32[][])"));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, oracleTimestamp, stateRootProof, validatorIndices, withdrawalCredentialProofs, validatorFields);

        // Can perform 'verifyWithdrawalCredentials' only once
        vm.prank(owner);
        vm.expectRevert("EigenPod.verifyCorrectWithdrawalCredentials: Validator must be inactive to prove withdrawal credentials");
        managerInstance.callEigenPod(validatorIds, data);
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
        managerInstance.callEigenPod(validatorIds, data);

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
        managerInstance.callEigenPod(validatorIds, data);
        vm.stopPrank();

        vm.warp(oracleTimestamp + 5 hours);

        // If the proof is too old, it should fail
        vm.prank(owner);
        vm.expectRevert("EigenPod.verifyBalanceUpdates: specified timestamp is too far in past");
        managerInstance.callEigenPod(validatorIds, data);
        vm.stopPrank();
    }

    function test_createDelayedWithdrawal() public {
        test_verifyWithdrawalCredentials_32ETH();

        bytes4 selector = bytes4(keccak256("createDelayedWithdrawal(address,address)"));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, podOwner, alice);

        vm.prank(owner);
        vm.expectRevert("DelayedWithdrawalRouter.onlyEigenPod: not podOwner's EigenPod");
        managerInstance.callDelayedWithdrawalRouter(validatorIds, data);
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
        managerInstance.callEigenPod(validatorIds, data);
    }

    function test_withdrawNonBeaconChainETHBalanceWei() public {

        // 1.
        (uint256 _withdrawalSafe, uint256 _eigenPod, uint256 _delayedWithdrawalRouter) = ws.splitBalanceInExecutionLayer();

        _transferTo(address(eigenPod), 1 ether);

        // 2.
        (uint256 new_withdrawalSafe, uint256 new_eigenPod, uint256 new_delayedWithdrawalRouter) = ws.splitBalanceInExecutionLayer();
        assertEq(_withdrawalSafe, new_withdrawalSafe);
        assertEq(_eigenPod + 1 ether, new_eigenPod);
        assertEq(_delayedWithdrawalRouter, new_delayedWithdrawalRouter);

        bytes4 selector = bytes4(keccak256("withdrawNonBeaconChainETHBalanceWei(address,uint256)"));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, alice, 1 ether);

        vm.prank(owner);
        vm.expectRevert("INCORRECT_RECIPIENT");
        managerInstance.callEigenPod(validatorIds, data);

        data[0] = abi.encodeWithSelector(selector, podOwner, 1 ether);
        vm.prank(owner);
        managerInstance.callEigenPod(validatorIds, data);

        // 3.
        (new_withdrawalSafe, new_eigenPod, new_delayedWithdrawalRouter) = ws.splitBalanceInExecutionLayer();
        assertEq(_withdrawalSafe, new_withdrawalSafe);
        assertEq(_eigenPod, new_eigenPod);
        assertEq(_delayedWithdrawalRouter + 1 ether, new_delayedWithdrawalRouter);

        vm.roll(block.number + (50400) + 1);

        ws.claimDelayedWithdrawalRouterWithdrawals(5, false, validatorId);

        // 4.
        (uint256 new_new_withdrawalSafe, uint256 new_new_eigenPod, uint256 new_new_delayedWithdrawalRouter) = ws.splitBalanceInExecutionLayer();
        assertEq(_withdrawalSafe + 1 ether + _delayedWithdrawalRouter, new_new_withdrawalSafe);
        assertEq(_eigenPod, new_new_eigenPod);
        assertEq(0, new_new_delayedWithdrawalRouter);
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


        test_registerAsOperator();

        bytes4 selector = bytes4(keccak256("delegateTo(address,(bytes,uint256),bytes32)"));
        IDelegationManager.SignatureWithExpiry memory signatureWithExpiry;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, operator, signatureWithExpiry, bytes32(0));

        // Confirm, the earningsReceiver is set to treasuryInstance
        assertEq(eigenLayerDelegationManager.earningsReceiver(operator), address(mainnet_earningsReceiver));
        assertEq(eigenLayerDelegationManager.isDelegated(podOwner), false);

        vm.startPrank(owner);
        managerInstance.callDelegationManager(validatorIds, data);
        vm.stopPrank();

        assertEq(eigenLayerDelegationManager.isDelegated(podOwner), true);
    }

    function test_undelegate() public {
        // 1. activateStaking & verifyWithdrawalCredentials & delegate to p2p & undelegate from p2p
        {
            bytes4 selector = bytes4(keccak256("undelegate(address)"));
            bytes[] memory data = new bytes[](1);
            data[0] = abi.encodeWithSelector(selector, podOwner);

            vm.prank(owner);
            managerInstance.callDelegationManager(validatorIds, data);

            vm.prank(owner);
            vm.expectRevert("DelegationManager.undelegate: staker must be delegated to undelegate");
            managerInstance.callDelegationManager(validatorIds, data);

            test_delegateTo();

            vm.prank(owner);
            managerInstance.callDelegationManager(validatorIds, data);
        }

        // 2. delegate to dsrv
        {
            bytes4 selector = bytes4(keccak256("delegateTo(address,(bytes,uint256),bytes32)"));
            IDelegationManager.SignatureWithExpiry memory signatureWithExpiry;
            bytes[] memory data = new bytes[](1);
            data[0] = abi.encodeWithSelector(selector, dsrv, signatureWithExpiry, bytes32(0));

            vm.startPrank(owner);
            managerInstance.callDelegationManager(validatorIds, data);
            vm.stopPrank();
        }
    }

    // Only {eigenLayerOperatingAdmin / Admin / Owner} can perform EigenLayer-related actions
    function test_access_control() public {
        bytes4 selector = bytes4(keccak256(""));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector);

        // FAIL
        vm.startPrank(chad);

        selector = bytes4(keccak256("nonBeaconChainETHBalanceWei()"));
        data[0] = abi.encodeWithSelector(selector);
        vm.expectRevert();
        managerInstance.callEigenPod(validatorIds, data);

        selector = bytes4(keccak256("ethPOS()"));
        data[0] = abi.encodeWithSelector(selector);
        vm.expectRevert();
        managerInstance.callDelegationManager(validatorIds, data);

        selector = bytes4(keccak256("domainSeparator()"));
        data[0] = abi.encodeWithSelector(selector);
        vm.expectRevert();
        managerInstance.callEigenPodManager(validatorIds, data);

        selector = bytes4(keccak256("withdrawalDelayBlocks()"));
        data[0] = abi.encodeWithSelector(selector);
        vm.expectRevert();
        managerInstance.callDelayedWithdrawalRouter(validatorIds, data);

        vm.stopPrank();

        // SUCCEEDS
        address el_operating_admin = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;
        vm.startPrank(el_operating_admin);

        selector = bytes4(keccak256("nonBeaconChainETHBalanceWei()"));
        data[0] = abi.encodeWithSelector(selector);
        managerInstance.callEigenPod(validatorIds, data);

        selector = bytes4(keccak256("ethPOS()"));
        data[0] = abi.encodeWithSelector(selector);
        managerInstance.callEigenPodManager(validatorIds, data);

        selector = bytes4(keccak256("domainSeparator()"));
        data[0] = abi.encodeWithSelector(selector);
        managerInstance.callDelegationManager(validatorIds, data);

        selector = bytes4(keccak256("withdrawalDelayBlocks()"));
        data[0] = abi.encodeWithSelector(selector);
        managerInstance.callDelayedWithdrawalRouter(validatorIds, data);

        vm.stopPrank();

    }

    /*
    function test_29027_verifyWithdrawalCredentials() public {
        setJSON("./test/eigenlayer-utils/test-data/mainnet_withdrawal_credential_proof_1285801.json");
        
        _setWithdrawalCredentialParams();
        _setOracleBlockRoot();

        uint256[] memory validatorIds = new uint256[](1);
        validatorIds[0] = 29027;

        oracleTimestamp = 1712703383;
        validatorIndices[0] = 1285801;

        bytes4 selector = bytes4(keccak256("verifyWithdrawalCredentials(uint64,(bytes32,bytes),uint40[],bytes[],bytes32[][])"));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, oracleTimestamp, stateRootProof, validatorIndices, withdrawalCredentialProofs, validatorFields);
        vm.prank(owner);
        managerInstance.callEigenPod(validatorIds, data);
    }
    */

}
