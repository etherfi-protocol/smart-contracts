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

    uint256[] validatorIds;
    uint256 validatorId;
    IEigenPod eigenPod;
    address podOwner;

    // Params to _verifyWithdrawalCredentials
    uint64 oracleTimestamp;
    BeaconChainProofs.StateRootProof stateRootProof;
    uint40[] validatorIndices;
    bytes[] withdrawalCredentialProofs;
    bytes[] validatorFieldsProofs;
    bytes32[][] validatorFields;

    function setUp() public {
        initializeRealisticFork(TESTNET_FORK);

        // Upgrade before running tests if you changed the contracts
        _upgrade_etherfi_nodes_manager_contract();
        // _upgrade_etherfi_node_contract();

        p2p = 0x37d5077434723d0ec21D894a52567cbE6Fb2C3D8;
        dsrv = 0x33503F021B5f1C00bA842cEd26B44ca2FAB157Bd;

        // A validator is launched
        // - https://holesky.beaconcha.in/validator/1644305#deposits
        // bid Id = validator Id = 1

        // {EigenPod, EigenPodOwner} used in EigenLayer's unit test
        validatorId = 1;
        eigenPod = IEigenPod(managerInstance.getEigenPod(validatorId));
        podOwner = managerInstance.etherfiNodeAddress(validatorId);
        validatorIds = new uint256[](1);
        validatorIds[0] = validatorId;

        // Override with Mock
        vm.startPrank(eigenLayerEigenPodManager.owner());
        beaconChainOracleMock = new BeaconChainOracleMock();
        beaconChainOracle = IBeaconChainOracle(address(beaconChainOracleMock));
        eigenLayerEigenPodManager.updateBeaconChainOracle(beaconChainOracle);
        vm.stopPrank();

        vm.startPrank(owner);
        liquidityPoolInstance.setRestakeBnftDeposits(true);
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

        // Get an oracle timestamp
        vm.warp(genesisSlotTimestamp + 1 days);
        oracleTimestamp = uint64(block.timestamp);
    }

    function _setOracleBlockRoot() internal {
        bytes32 latestBlockRoot = getLatestBlockRoot();
        //set beaconStateRoot
        beaconChainOracleMock.setOracleBlockRootAtTimestamp(latestBlockRoot);
    }

    function _beacon_process_1ETH_deposit() internal {
        // - The validator 1644305 has only 1 ETH deposit at slot = 1317759
        setJSON("./test/eigenlayer-utils/test-data/withdrawal_credential_proof_1644305_1317759.json");
        
        _setWithdrawalCredentialParams();
        _setOracleBlockRoot();
    }

    function _beacon_process_32ETH_deposit() internal {
        // TODO
    }

    function _beacon_process_partial_withdrawals() internal {
        // TODO
    }

    // References
    // - https://github.com/Layr-Labs/eigenlayer-contracts/tree/dev?tab=readme-ov-file#current-testnet-deployment
    // - https://github.com/Layr-Labs/eigenlayer-contracts/blob/dev/src/test/unit/EigenPodUnit.t.sol
    // - https://github.com/Layr-Labs/eigenlayer-contracts/blob/dev/src/test/unit/
    // - https://github.com/Layr-Labs/eigenlayer-contracts/tree/dev/src/test/utils

    function create_validator() public returns (uint256, address, EtherFiNode) {        
        uint256[] memory validatorIds = launch_validator(1, 0, true);
        address nodeAddress = managerInstance.etherfiNodeAddress(validatorIds[0]);
        EtherFiNode node = EtherFiNode(payable(nodeAddress));

        return (validatorIds[0], nodeAddress, node);
    }

    // What need to happen after EL mainnet launch
    // per EigenPod
    // - call `activateRestaking()` to empty the EigenPod contract and disable `withdrawBeforeRestaking()`
    // - call `verifyWithdrawalCredentials()` to register the validator by proving that it is active
    // - call `delegateTo` for delegation

    // Call EigenPod.activateRestaking()
    function test_activateRestaking() public {
        vm.startPrank(owner);
        // EigenPod contract created after EL contract upgrade is restaked by default in its 'initialize'
        // Therefore, the call to 'activateRestaking()' should fail.
        // We will need to write another test in mainnet for this
        vm.expectRevert(); 
        bytes4 selector = bytes4(keccak256("activateRestaking()"));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector);
        managerInstance.callEigenPod(validatorIds, data);
        vm.stopPrank();
    }

    // https://holesky.beaconcha.in/validator/1644305#deposits
    function test_verifyWithdrawalCredentials_1ETH() public {
        _beacon_process_1ETH_deposit();

        int256 initialShares = eigenLayerEigenPodManager.podOwnerShares(podOwner);

        // 2. Trigger a function
        vm.startPrank(owner);
        bytes4 selector = bytes4(keccak256("verifyWithdrawalCredentials(uint64,(bytes32,bytes),uint40[],bytes[],bytes32[][])"));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, oracleTimestamp, stateRootProof, validatorIndices, withdrawalCredentialProofs, validatorFields);
        managerInstance.callEigenPod(validatorIds, data);
        vm.stopPrank();

        // 3. Check the result
        int256 updatedShares = eigenLayerEigenPodManager.podOwnerShares(podOwner);
        assertTrue(updatedShares != initialShares, "Shares should be updated after verifying withdrawal credentials");
        assertEq(updatedShares, 1e18, "Shares should be 1 ETH in wei after verifying withdrawal credentials");
    }

    function test_verifyWithdrawalCredentials_32ETH() public {
        _beacon_process_partial_withdrawals();
        
        // TODO
    }

    function test_verifyBalanceUpdates_1ETH() public {
        _beacon_process_1ETH_deposit();

        int256 initialShares = eigenLayerEigenPodManager.podOwnerShares(podOwner);

        // 2. Trigger a function
        vm.startPrank(owner);
        bytes4 selector = bytes4(keccak256("verifyBalanceUpdates(uint64,uint40[],(bytes32,bytes),bytes[],bytes32[][])"));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, oracleTimestamp, validatorIndices, stateRootProof, withdrawalCredentialProofs, validatorFields);
        vm.expectRevert("EigenPod.verifyBalanceUpdate: Validator not active");
        managerInstance.callEigenPod(validatorIds, data);
        vm.stopPrank();
    }

    function test_verifyAndProcessWithdrawals_32ETH() public {
        // TODO
    }

    function test_delegateTo() public {
        bytes4 selector = bytes4(keccak256("delegateTo(address,(bytes,uint256),bytes32)"));
        IDelegationManager.SignatureWithExpiry memory signatureWithExpiry;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, p2p, signatureWithExpiry, bytes32(0));

        vm.startPrank(owner);
        managerInstance.callDelegationManager(validatorIds, data);
        // == delegationManager.delegateTo(p2p, signatureWithExpiry, bytes32(0));
        vm.stopPrank();
    }


    function test_undelegate() public {
        bytes4 selector = bytes4(keccak256("undelegate(address)"));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, podOwner);
        
        vm.prank(owner);
        vm.expectRevert("DelegationManager.undelegate: staker must be delegated to undelegate");
        managerInstance.callDelegationManager(validatorIds, data);

        test_delegateTo();

        vm.prank(owner);
        managerInstance.callDelegationManager(validatorIds, data);
    }

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
        vm.startPrank(owner);

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

}