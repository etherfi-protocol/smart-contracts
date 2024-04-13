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

import "../src/UUPSProxy.sol";
import "../src/EtherFiAvsOperator.sol";
import "../src/EtherFiAvsOperatorsManager.sol";

import "./eigenlayer-utils/ProofParsing.sol";
import "./eigenlayer-mocks/BeaconChainOracleMock.sol";
import {BitmapUtils} from "../src/eigenlayer-libraries/BitmapUtils.sol";
import {BN254} from "../src/eigenlayer-libraries/BN254.sol";
import {IBLSApkRegistry} from "../src/eigenlayer-interfaces/IBLSApkRegistry.sol";
// import {MockAVSDeployer} from "./eigenlayer-middleware/test/utils/MockAVSDeployer.sol";

import "forge-std/console2.sol";
import "forge-std/console.sol";


contract EtherFiAvsOperatorsManagerTest is TestSetup {

    uint256 id;
    address avsNodeRunner;
    address ecdsaSigner;

    address eigenDA_registryCoordinator;

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);

        _upgrade_etherfi_avs_operators_manager();
        
        avsNodeRunner = address(100000);
        ecdsaSigner = address(100001);

        eigenDA_registryCoordinator = 0x0BAAc79acD45A023E19345c352d8a7a83C4e5656;
    }

    function test_instantiateEtherFiAvsOperator() public {
        vm.startPrank(avsOperatorsManager.owner());
        uint256[] memory ids = avsOperatorsManager.instantiateEtherFiAvsOperator(1);
        id = ids[0];

        assertEq(avsOperatorsManager.avsNodeRunner(id), address(0));
        assertEq(avsOperatorsManager.ecdsaSigner(id), address(0));
        avsOperatorsManager.updateAvsNodeRunner(id, avsNodeRunner);
        avsOperatorsManager.updateEcdsaSigner(id, ecdsaSigner);
        assertEq(avsOperatorsManager.avsNodeRunner(id), avsNodeRunner);
        assertEq(avsOperatorsManager.ecdsaSigner(id), ecdsaSigner);
        vm.stopPrank();
    }

    function test_registerAsOperator() public {
        test_instantiateEtherFiAvsOperator();

        IDelegationManager.OperatorDetails memory details = IDelegationManager.OperatorDetails({
            earningsReceiver: address(treasuryInstance),
            delegationApprover: address(0),
            stakerOptOutWindowBlocks: 1
        });
        string memory metadata_uri = "metadata_uri";

        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        avsOperatorsManager.registerAsOperator(id, details, metadata_uri);

        vm.prank(avsNodeRunner);
        vm.expectRevert("Ownable: caller is not the owner");
        avsOperatorsManager.registerAsOperator(id, details, metadata_uri);

        vm.prank(avsOperatorsManager.owner());
        avsOperatorsManager.registerAsOperator(id, details, metadata_uri);

        IDelegationManager.OperatorDetails memory stored_details = avsOperatorsManager.operatorDetails(id);

        assertEq(stored_details.earningsReceiver, details.earningsReceiver);
        assertEq(stored_details.delegationApprover, details.delegationApprover);
        assertEq(stored_details.stakerOptOutWindowBlocks, details.stakerOptOutWindowBlocks);
    }

    function test_registerBlsKeyAsDelegatedNodeOperator() public {
        test_registerAsOperator();

        bytes memory quorumNumbers = abi.encodePacked(uint256(1), uint256(2), uint256(3));
        string memory socket = "socket";
        IBLSApkRegistry.PubkeyRegistrationParams memory params = IBLSApkRegistry.PubkeyRegistrationParams({
            pubkeyRegistrationSignature: BN254.G1Point(1, 1),
            pubkeyG1: BN254.G1Point(1, 1),
            pubkeyG2: BN254.G2Point([uint256(1), uint256(1)], [uint256(1), uint256(1)])
        });

        vm.prank(alice);
        vm.expectRevert("INCORRECT_CALLER");
        avsOperatorsManager.registerBlsKeyAsDelegatedNodeOperator(id, eigenDA_registryCoordinator, quorumNumbers, socket, params);

        vm.prank(avsNodeRunner);
        vm.expectRevert("AVS_NOT_WHITELISTED");
        avsOperatorsManager.registerBlsKeyAsDelegatedNodeOperator(id, eigenDA_registryCoordinator, quorumNumbers, socket, params);

        vm.prank(avsOperatorsManager.owner());
        avsOperatorsManager.updateAvsWhitelist(id, eigenDA_registryCoordinator, true);

        vm.prank(avsNodeRunner);
        avsOperatorsManager.registerBlsKeyAsDelegatedNodeOperator(id, eigenDA_registryCoordinator, quorumNumbers, socket, params);
    }

    function test_update_operator_info() public {
        test_registerAsOperator();
    
        string memory new_socket = "new_socket";
        IBLSApkRegistry.PubkeyRegistrationParams memory new_params = IBLSApkRegistry.PubkeyRegistrationParams({
            pubkeyRegistrationSignature: BN254.G1Point(2, 2),
            pubkeyG1: BN254.G1Point(2, 2),
            pubkeyG2: BN254.G2Point([uint256(2), uint256(2)], [uint256(2), uint256(2)])
        });
        IDelegationManager.OperatorDetails memory new_details = IDelegationManager.OperatorDetails({
            earningsReceiver: address(treasuryInstance),
            delegationApprover: address(0),
            stakerOptOutWindowBlocks: 2
        });
        string memory new_metadata_uri = "new_metadata_uri";


        vm.prank(alice);
        vm.expectRevert("INCORRECT_CALLER");
        avsOperatorsManager.updateSocket(id, eigenDA_registryCoordinator, new_socket);

        vm.prank(avsNodeRunner);
        vm.expectRevert("Ownable: caller is not the owner");
        avsOperatorsManager.modifyOperatorDetails(id, new_details);

        vm.prank(avsNodeRunner);
        vm.expectRevert("Ownable: caller is not the owner");
        avsOperatorsManager.updateOperatorMetadataURI(id, new_metadata_uri);
    
        vm.prank(avsOperatorsManager.owner());
        avsOperatorsManager.updateOperatorMetadataURI(id, new_metadata_uri);
    }

    function test_avs_directory() public {
        test_registerAsOperator();

        IAVSDirectory avsDirectory = IAVSDirectory(avsOperatorsManager.avsDirectory());
        address eigenDA_servicemanager = 0x870679E138bCdf293b7Ff14dD44b70FC97e12fc0;
        address eigenYields = 0x5ACCC90436492F24E6aF278569691e2c942A676d;

        assertTrue(avsDirectory.avsOperatorStatus(eigenDA_servicemanager, eigenYields) == IAVSDirectory.OperatorAVSRegistrationStatus.REGISTERED);
        assertTrue(avsOperatorsManager.avsOperatorStatus(1, eigenDA_servicemanager) == IAVSDirectory.OperatorAVSRegistrationStatus.UNREGISTERED);
        assertTrue(
            avsOperatorsManager.calculateOperatorAVSRegistrationDigestHash(id, eigenDA_servicemanager, bytes32(abi.encode(1)), 1) ==
            avsDirectory.calculateOperatorAVSRegistrationDigestHash(address(avsOperatorsManager.avsOperators(id)), eigenDA_servicemanager, bytes32(abi.encode(1)), 1)
        );
    }
}