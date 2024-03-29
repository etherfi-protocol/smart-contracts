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

    // Params to _verifyWithdrawalCredentials
    uint64 oracleTimestamp;
    BeaconChainProofs.StateRootProof stateRootProof;
    uint40[] validatorIndices;
    bytes[] withdrawalCredentialProofs;
    bytes[] validatorFieldsProofs;
    bytes32[][] validatorFields;

    function setUp() public {
        initializeRealisticFork(TESTNET_FORK);

        p2p = 0x37d5077434723d0ec21D894a52567cbE6Fb2C3D8;
        dsrv = 0x33503F021B5f1C00bA842cEd26B44ca2FAB157Bd;

        // A validator is launched
        // - https://holesky.beaconcha.in/validator/1644305#deposits
        // bid Id = validator Id = 1

        // {EigenPod, EigenPodOwner} used in EigenLayer's unit test
        validatorId = 1;
        eigenPod = IEigenPod(managerInstance.getEigenPod(validatorId));
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
        validatorFieldsProofs[0] = abi.encodePacked(getValidatorFieldsProof());
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
        (uint256 validatorId, address nodeAddress, EtherFiNode node) = create_validator();

        assertTrue(node.eigenPod() != address(0));

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

    // Call EigenPod.verifyWithdrawalCredentials()
    // function verifyWithdrawalCredentials(
    //     uint64 oracleTimestamp,
    //     BeaconChainProofs.StateRootProof calldata stateRootProof,
    //     uint40[] calldata validatorIndices,
    //     bytes[] calldata withdrawalCredentialProofs,
    //     bytes32[][] calldata validatorFields
    // )
    //     external;
    // where
    // @ src/eigenlayer-libraries/BeaconChainProofs.sol
    // struct StateRootProof {
    //     bytes32 beaconStateRoot;
    //     bytes proof;
    // }

    // Example from the EigenLayer repo
    function test_verifyWithdrawalCredentials_EL() public {
        // Generate the proofs using the library
        setJSON("./test/eigenlayer-utils/test-data/withdrawal_credential_proof_302913.json");
        _setWithdrawalCredentialParams();
        _setOracleBlockRoot();

        address podOwner = managerInstance.etherfiNodeAddress(validatorId);
        int256 initialShares = eigenLayerEigenPodManager.podOwnerShares(podOwner);

        vm.startPrank(podOwner);
        // bytes4 selector = bytes4(keccak256("verifyWithdrawalCredentials(uint64,(bytes32,bytes),uint40[],bytes[],bytes32[][])"));
        // bytes memory data = abi.encodeWithSelector(selector, oracleTimestamp, stateRootProof, validatorIndices, validatorFieldsProofs, validatorFields);
        // address(eigenPod).call(data);
        eigenPod.verifyWithdrawalCredentials(
            oracleTimestamp,
            stateRootProof,
            validatorIndices,
            withdrawalCredentialProofs,
            validatorFields
        );
        vm.stopPrank();

        // Assert: Check that the shares are updated correctly
        int256 updatedShares = eigenLayerEigenPodManager.podOwnerShares(podOwner);
        assertTrue(updatedShares != initialShares, "Shares should be updated after verifying withdrawal credentials");
        assertEq(updatedShares, 32e18, "Shares should be 32ETH in wei after verifying withdrawal credentials");
    }

    function test_verifyWithdrawalCredentials() public {
        // 1. Spin up a validator
        (uint256 validatorId, address nodeAddress, EtherFiNode node) = create_validator();

        // 2. Generate the proofs using the library
        setJSON("./test/eigenlayer-utils/test-data/withdrawal_credential_proof_302913.json"); // TODO: Use Ether.Fi's one
        
        _setWithdrawalCredentialParams();
        _setOracleBlockRoot();

        // 3. Trigger a function
        vm.startPrank(owner);
        bytes4 selector = bytes4(keccak256("verifyWithdrawalCredentials(uint64,(bytes32,bytes),uint40[],bytes[],bytes32[][])"));
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, oracleTimestamp, stateRootProof, validatorIndices, validatorFieldsProofs, validatorFields);
        managerInstance.callEigenPod(validatorIds, data);
        vm.stopPrank();

        // 4. Check the result
        // assertEq(...)
    }

    // Call DelegationManager.delegateTo(address operator)
    // function delegateTo(
    //     address operator,
    //     SignatureWithExpiry memory approverSignatureAndExpiry,
    //     bytes32 approverSalt
    // ) external;
    // where
    // @ src/eigenlayer-interfaces/ISignatureUtils.sol
    // struct SignatureWithExpiry {
    //     // the signature itself, formatted as a single bytes object
    //     bytes signature;
    //     // the expiration timestamp (UTC) of the signature
    //     uint256 expiry;
    // }
    function test_delegateTo() public {
        (uint256 validatorId, address nodeAddress, EtherFiNode node) = create_validator();

        vm.startPrank(owner);
        bytes4 selector = bytes4(keccak256("delegateTo(address,(bytes,uint256),bytes32)"));
        IDelegationManager.SignatureWithExpiry memory signatureWithExpiry;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(selector, p2p, signatureWithExpiry, bytes32(0));

        managerInstance.callDelegationManager(validatorIds, data);
        // == delegationManager.delegateTo(p2p, signatureWithExpiry, bytes32(0));
        vm.stopPrank();
    }

}