// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/EtherFiNode.sol";
import "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin-upgradeable/contracts/utils/cryptography/ECDSAUpgradeable.sol";
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
import {IRegistryCoordinator} from "../src/eigenlayer-interfaces/IRegistryCoordinator.sol";
// import {MockAVSDeployer} from "./eigenlayer-middleware/test/utils/MockAVSDeployer.sol";

import "forge-std/console2.sol";
import "forge-std/console.sol";


contract EtherFiAvsOperatorsManagerTest is TestSetup {

    uint256 id;
    address avsNodeRunner;
    address ecdsaSigner;

    address eigenDA_registryCoordinator;
    address eigenDA_servicemanager;
    address brevis_registryCoordinator;
    address brevis_servicemanager;

    function setUp() public {
        initializeRealisticFork(TESTNET_FORK);
        // initializeRealisticFork(MAINNET_FORK);

        _upgrade_etherfi_avs_operators_manager();
        
        avsNodeRunner = address(100000);
        ecdsaSigner = address(100001);

        if (block.chainid == 1) {
            eigenDA_registryCoordinator = 0x0BAAc79acD45A023E19345c352d8a7a83C4e5656;
            eigenDA_servicemanager = 0x870679E138bCdf293b7Ff14dD44b70FC97e12fc0;

            brevis_registryCoordinator = 0x434621cfd8BcDbe8839a33c85aE2B2893a4d596C;
            brevis_servicemanager = 0x9FC952BdCbB7Daca7d420fA55b942405B073A89d;
        } else if (block.chainid == 17000) {
            eigenDA_registryCoordinator = 0x53012C69A189cfA2D9d29eb6F19B32e0A2EA3490;
            eigenDA_servicemanager = 0xD4A7E1Bd8015057293f0D0A557088c286942e84b;

            brevis_registryCoordinator = 0x0dB4ceE042705d47Ef6C0818E82776359c3A80Ca;
            brevis_servicemanager = 0x7A46219950d8a9bf2186549552DA35Bf6fb85b1F;
        }
    }

    function test_bls_key_verification_mainnet_eigenDA() public {
        initializeRealisticFork(MAINNET_FORK);
        eigenDA_registryCoordinator = 0x0BAAc79acD45A023E19345c352d8a7a83C4e5656;
        eigenDA_servicemanager = 0x870679E138bCdf293b7Ff14dD44b70FC97e12fc0;

        id = 3;

        _test_bls_key_verification(address(avsOperatorsManager.avsOperators(id)), eigenDA_registryCoordinator, avsOperatorsManager.getAvsInfo(id, eigenDA_registryCoordinator).params);
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

        // Incorrect BLS key...
        vm.expectRevert();
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
        address nethermind = 0x57b6FdEF3A23B81547df68F44e5524b987755c99;

        assertTrue(avsDirectory.avsOperatorStatus(eigenDA_servicemanager, nethermind) == IAVSDirectory.OperatorAVSRegistrationStatus.REGISTERED);
        assertTrue(avsOperatorsManager.avsOperatorStatus(1, eigenDA_servicemanager) == IAVSDirectory.OperatorAVSRegistrationStatus.UNREGISTERED);
        assertTrue(
            avsOperatorsManager.calculateOperatorAVSRegistrationDigestHash(id, eigenDA_servicemanager, bytes32(abi.encode(1)), 1) ==
            avsDirectory.calculateOperatorAVSRegistrationDigestHash(address(avsOperatorsManager.avsOperators(id)), eigenDA_servicemanager, bytes32(abi.encode(1)), 1)
        );
    }

    function test_registerOperator_holesky_brevis() public {
        id = 1;
        assertEq(avsOperatorsManager.ecdsaSigner(id), 0xD0d7F8a5a86d8271ff87ff24145Cf40CEa9F7A39);

        ISignatureUtils.SignatureWithSaltAndExpiry memory operatorSignature = ISignatureUtils.SignatureWithSaltAndExpiry({
            signature: hex"b8384849b95998faed0809e9a1bb44537593d7997e0a5e9bcb21f2ff9d0a8eb038a7cc14eeb5863cd40a15c492984d294cae9a726395dde5821f32c750ebc6c61c",
            salt: hex"97c8686ec57d4c46b97e18f4427baf272c228e15b488dcbf3aeae3593bfc7647",
            expiry: 1744693557
        });

        address operator = address(avsOperatorsManager.avsOperators(id));
        bytes32 digestHash = avsOperatorsManager.avsDirectory().calculateOperatorAVSRegistrationDigestHash(operator, brevis_servicemanager, operatorSignature.salt, operatorSignature.expiry);
        (address recovered, ) = ECDSAUpgradeable.tryRecover(digestHash, operatorSignature.signature);
        assertEq(recovered, avsOperatorsManager.ecdsaSigner(id));

        vm.prank(avsOperatorsManager.owner());
        avsOperatorsManager.registerOperator(id, brevis_registryCoordinator, operatorSignature);
    }

    function test_registerOperator_holesky_eigenda() public {
        id = 1;
        assertEq(avsOperatorsManager.ecdsaSigner(id), 0xD0d7F8a5a86d8271ff87ff24145Cf40CEa9F7A39);

        ISignatureUtils.SignatureWithSaltAndExpiry memory operatorSignature = ISignatureUtils.SignatureWithSaltAndExpiry({
            signature: hex"9eca8eec68bbd5c7a5724e1ebcafa284438fe73a76321cf122694488388e67aa488ba5ae30bc53a874d9ad001e7c43273b6372b29a976a0ed45bef6bb35d745d1c",
            salt: hex"52e95acdb380cfe37dabd619b607a07b39cb61e67f7f0ca0bcfddac35490d5a6",
            expiry: 1744695978
        });

        address operator = address(avsOperatorsManager.avsOperators(id));
        bytes32 digestHash = avsOperatorsManager.avsDirectory().calculateOperatorAVSRegistrationDigestHash(operator, eigenDA_servicemanager, operatorSignature.salt, operatorSignature.expiry);
        (address recovered, ) = ECDSAUpgradeable.tryRecover(digestHash, operatorSignature.signature);
        assertEq(recovered, avsOperatorsManager.ecdsaSigner(id));

        vm.prank(avsOperatorsManager.owner());
        avsOperatorsManager.registerOperator(id, eigenDA_registryCoordinator, operatorSignature);
    }

    function test_bls_key_verification_holesky_eigenDA() public {
        id = 1;

        _test_bls_key_verification(address(avsOperatorsManager.avsOperators(id)), eigenDA_registryCoordinator, avsOperatorsManager.getAvsInfo(id, eigenDA_registryCoordinator).params);
    }
    
    function test_bls_key_verification_holesky_brevis() public {
        id = 1;

        _test_bls_key_verification(address(avsOperatorsManager.avsOperators(id)), brevis_registryCoordinator, avsOperatorsManager.getAvsInfo(id, brevis_registryCoordinator).params);
    }

    function _test_bls_key_verification(address operator, address registryCoordinator, IBLSApkRegistry.PubkeyRegistrationParams memory params) internal {
        BN254.G1Point memory pubkeyRegistrationMessageHash = IRegistryCoordinator(registryCoordinator).pubkeyRegistrationMessageHash(address(operator));

        // gamma = h(sigma, P, P', H(m))
        uint256 gamma = uint256(keccak256(abi.encodePacked(
            params.pubkeyRegistrationSignature.X, 
            params.pubkeyRegistrationSignature.Y, 
            params.pubkeyG1.X, 
            params.pubkeyG1.Y, 
            params.pubkeyG2.X, 
            params.pubkeyG2.Y, 
            pubkeyRegistrationMessageHash.X, 
            pubkeyRegistrationMessageHash.Y
        ))) % BN254.FR_MODULUS;

        require(BN254.pairing(
            BN254.plus(params.pubkeyRegistrationSignature, BN254.scalar_mul(params.pubkeyG1, gamma)),
            BN254.negGeneratorG2(),
            BN254.plus(pubkeyRegistrationMessageHash, BN254.scalar_mul(BN254.generatorG1(), gamma)),
            params.pubkeyG2
        ), "BLSApkRegistry.registerBLSPublicKey: either the G1 signature is wrong, or G1 and G2 private key do not match");

        
        // e(sigma + P * gamma, [-1]_2) = e(H(m) + [1]_1 * gamma, P') 
        require(
            EtherFiAvsOperator(operator).verifyBlsKey(registryCoordinator, params),
            "BLSApkRegistry.registerBLSPublicKey: either the G1 signature is wrong, or G1 and G2 private key do not match"
        );
    }
}