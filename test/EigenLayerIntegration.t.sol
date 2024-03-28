// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/EtherFiNode.sol";
import "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "../src/eigenlayer-interfaces/IEigenPodManager.sol";
import "../src/eigenlayer-interfaces/IDelayedWithdrawalRouter.sol";
import "../src/eigenlayer-libraries/BeaconChainProofs.sol";

import "./eigenlayer-utils/ProofParsing.sol";
import "./eigenlayer-mocks/BeaconChainOracleMock.sol";

import "forge-std/console2.sol";


contract EigenLayerIntegraitonTest is TestSetup, ProofParsing {

    address p2p;
    address dsrv;

    address eigenPodOwner;
    address eigenPod;

    // Params to _verifyWithdrawalCredentials
    uint64 oracleTimestamp;
    BeaconChainProofs.StateRootProof stateRootProof;
    uint40[] validatorIndices;
    bytes[] validatorFieldsProofs;
    bytes32[][] validatorFields;

    function setUp() public {
        initializeTestingFork(TESTNET_FORK);

        p2p = 0x37d5077434723d0ec21D894a52567cbE6Fb2C3D8;
        dsrv = 0x33503F021B5f1C00bA842cEd26B44ca2FAB157Bd;

        // // Two validators are launched for the eigenPod (0x54c..)
        // // - https://holesky.beaconcha.in/validator/874b46606ee21aa7f6c5b7ca3466895bd1a993ff20de71b983695da7f13a9c06c77ef950fbfc8fa3aad4799b54edc97e#deposits
        // // - https://holesky.beaconcha.in/validator/aef293411fed042f21f4ab1d05ff054d21ef3b7a4747ed4d06693dbba0fc33a14378c04f70366b8b038007db6d83809f#deposits
        // eigenPod = 0x54c702BABacccd92F7bd624C9c17581B5aDa81Ec;
        // eigenPodOwner = 0x16eAd66b7CBcAb3F3Cd49e04E6C74b02b05d98E8;

        eigenPodOwner = address(42000094993494);
        eigenPod = address(0x49c486E3f4303bc11C02F952Fe5b08D0AB22D443);

        // Override with Mock
        vm.startPrank(eigenLayerEigenPodManager.owner());
        beaconChainOracleMock = new BeaconChainOracleMock();
        beaconChainOracle = IBeaconChainOracle(address(beaconChainOracleMock));
        eigenLayerEigenPodManager.updateBeaconChainOracle(beaconChainOracle);
        vm.stopPrank();

        vm.startPrank(alice);
        liquidityPoolInstance.setRestakeBnftDeposits(true);
        vm.stopPrank();
    }

    function _setWithdrawalCredentialParams() public {
        validatorIndices = new uint40[](1);
        validatorFieldsProofs = new bytes[](1);
        validatorFields = new bytes32[][](1);

        // Set beacon state root, validatorIndex
        stateRootProof.beaconStateRoot = getBeaconStateRoot();
        stateRootProof.proof = getStateRootProof();
        validatorIndices[0] = uint40(getValidatorIndex());
        validatorFieldsProofs[0] = abi.encodePacked(getWithdrawalCredentialProof()); // Validator fields are proven here
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
        
        vm.startPrank(admin);
        // EigenPod contract created after EL contract upgrade is restaked by default in its 'initialize'
        // Therefore, the call to 'activateRestaking()' should fail.
        // We will need to write another test in mainnet for this
        vm.expectRevert(); 
        bytes4 selector = bytes4(keccak256("activateRestaking()"));
        managerInstance.callEigenPod(validatorId, abi.encodeWithSelector(selector));
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

    // Example in EigenLayer
    function test_verifyWithdrawalCredentials_EL() public {
        // Generate the proofs using the library
        setJSON("./test/eigenlayer-utils/test-data/withdrawal_credential_proof_302913.json");
        _setWithdrawalCredentialParams();
        _setOracleBlockRoot();

        vm.startPrank(eigenPodOwner);
        bytes4 selector = bytes4(keccak256("verifyWithdrawalCredentials(uint64,(bytes32,bytes),uint40[],bytes[],bytes32[][])"));
        bytes memory data = abi.encodeWithSelector(selector, oracleTimestamp, stateRootProof, validatorIndices, validatorFieldsProofs, validatorFields);
        address(eigenPod).call(data);
        vm.stopPrank();
    }
    function test_verifyWithdrawalCredentials() public {
        // Spin up a validator
        (uint256 validatorId, address nodeAddress, EtherFiNode node) = create_validator();

        // Generate the proofs using the library
        // setJSON("./test/eigenlayer-utils/test-data/withdrawal_credential_proof_302913.json");
        _setWithdrawalCredentialParams();
        _setOracleBlockRoot();

        vm.startPrank(admin);
        bytes4 selector = bytes4(keccak256("verifyWithdrawalCredentials(uint64,(bytes32,bytes),uint40[],bytes[],bytes32[][])"));
        managerInstance.callEigenPod(validatorId, abi.encodeWithSelector(selector, oracleTimestamp, stateRootProof, validatorIndices, validatorFieldsProofs, validatorFields));
        vm.stopPrank();
    }

    // Call DelegationMaanger.delegateTo(address operator)
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

        vm.startPrank(admin);
        bytes4 selector = bytes4(keccak256("delegateTo(address,(bytes,uint256),bytes32)"));
        IDelegationManager.SignatureWithExpiry memory signatureWithExpiry;
        managerInstance.callDelegationManager(validatorId, abi.encodeWithSelector(selector, p2p, signatureWithExpiry, bytes32(0)));
        // == delegationManager.delegateTo(p2p, signatureWithExpiry, bytes32(0));
        vm.stopPrank();
    }

}