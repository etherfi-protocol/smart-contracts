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

        _upgrade_etherfi_avs_operators_manager();
        
        avsNodeRunner = address(100000);
        ecdsaSigner = address(100001);

        if (block.chainid == 1) {
            eigenDA_registryCoordinator = 0x0BAAc79acD45A023E19345c352d8a7a83C4e5656;
            eigenDA_servicemanager = 0x870679E138bCdf293b7Ff14dD44b70FC97e12fc0;

            brevis_registryCoordinator = 0x434621cfd8BcDbe8839a33c85aE2B2893a4d596C;
            brevis_servicemanager = 0x9FC952BdCbB7Daca7d420fA55b942405B073A89d;
        } else if (block.chainid == 17000) {
            eigenDA_registryCoordinator = 0x0BAAc79acD45A023E19345c352d8a7a83C4e5656;
            eigenDA_servicemanager = 0x870679E138bCdf293b7Ff14dD44b70FC97e12fc0;

            brevis_registryCoordinator = 0x0dB4ceE042705d47Ef6C0818E82776359c3A80Ca;
            brevis_servicemanager = 0x7A46219950d8a9bf2186549552DA35Bf6fb85b1F;
        }
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

    function test_ecdsa_signing() public {
        // https://etherscan.io/tx/0xa1f4dad18f453db36bd85ad953629772f43530d3cf35df7fbecc8dd7e9968e3c
        
        // (quorumNumbers = 0x00, 
        //  socket = 176.96.139.105:32005;32004, 
        //  params = {"pubkeyRegistrationSignature":{"X":"13930132857693227669286552740872125143110598440832128762691891535344523478758","Y":"6922746212735886673397038348770411476602736080156269360551930225918644776978"},
        //  "pubkeyG1":{"X":"2386016606917945660190712972098427855269577476623723422867331055589384084269","Y":"14968962494564624642828972951024997596009870047682971310684803314690728181528"},
        //  "pubkeyG2":{"X":["1212702844116721867258076029541971160984904577278437049781204783739431751522","19354825442469668588126245718346981213263864406248537535463071512803213558712"],"Y":["13931796655362966527501678217695731308545430570263064729277439379944371440611","4198997627479952975656875720441300210986176678754907589897275078042197531587"]}}, 
        // operatorSignature = {
            // "signature":"0x312273c7f514b89a8d0fb48e1c98c96ae79f5c5f85e705911b8174ab182d5f4379e1b4e86a2d2e8bce38737ce3982c7b10acc8558852aa3a828bfec8aa69f4c61c",
            // "salt":"0x80807f7884635486c380ad928e5d596013fcd10211d60219cf9c5896e373d5cb",
            // "expiry":"1713082353"})

        address operator = 0xD7ED603e90D11892e56f00B1462e6d1A9AE488F2;

        bytes memory quorumNumbers = hex"";
        string memory socket = "176.96.139.105:32005;32004";
        IBLSApkRegistry.PubkeyRegistrationParams memory params = IBLSApkRegistry.PubkeyRegistrationParams({
            pubkeyRegistrationSignature: BN254.G1Point(13930132857693227669286552740872125143110598440832128762691891535344523478758, 6922746212735886673397038348770411476602736080156269360551930225918644776978),
            pubkeyG1: BN254.G1Point(2386016606917945660190712972098427855269577476623723422867331055589384084269, 14968962494564624642828972951024997596009870047682971310684803314690728181528),
            pubkeyG2: BN254.G2Point([uint256(1212702844116721867258076029541971160984904577278437049781204783739431751522), uint256(19354825442469668588126245718346981213263864406248537535463071512803213558712)], [uint256(13931796655362966527501678217695731308545430570263064729277439379944371440611), uint256(4198997627479952975656875720441300210986176678754907589897275078042197531587)])
        });

        bytes memory signature = hex"312273c7f514b89a8d0fb48e1c98c96ae79f5c5f85e705911b8174ab182d5f4379e1b4e86a2d2e8bce38737ce3982c7b10acc8558852aa3a828bfec8aa69f4c61c";
        bytes32 salt = 0x80807f7884635486c380ad928e5d596013fcd10211d60219cf9c5896e373d5cb;
        uint256 expiry = 1713082353;

        bytes32 digestHash = avsOperatorsManager.avsDirectory().calculateOperatorAVSRegistrationDigestHash(operator, eigenDA_servicemanager, salt, expiry);
        (address recovered, ) = ECDSAUpgradeable.tryRecover(digestHash, signature);

        assertEq(recovered, operator);
    }

    function test_etherfi_avs_operator_ecdsa_signing() public {
        id = 1;
        EtherFiAvsOperator operator = EtherFiAvsOperator(avsOperatorsManager.avsOperators(id));

        // Make sure the targe avs is whitelisted
        vm.prank(avsOperatorsManager.owner());
        avsOperatorsManager.updateAvsWhitelist(id, brevis_registryCoordinator, true);

        ISignatureUtils.SignatureWithSaltAndExpiry memory operatorSignature = ISignatureUtils.SignatureWithSaltAndExpiry({
            signature: hex"896fb9e3673c86ff9fa7544e6c17afe82f9880af8fdd71ae1dd3d4859bec668845a9aff65566bc5187f80614a633ec4a465ff05a1bbd57d63d58396fce105b941c",
            salt: hex"afaedbee4ef9fc4f2a7b025cf79dac693a6db429b2ec893061528cefb37c1862",
            expiry: 1744685849
        });

        bytes32 digestHash = avsOperatorsManager.calculateOperatorAVSRegistrationDigestHash(id, brevis_servicemanager, operatorSignature.salt, operatorSignature.expiry);
        (address recovered, ) = ECDSAUpgradeable.tryRecover(digestHash, operatorSignature.signature);
        assertEq(recovered, address(operator.ecdsaSigner()));

        vm.prank(avsOperatorsManager.owner());
        avsOperatorsManager.registerOperator(id, brevis_registryCoordinator, operatorSignature);
    }

    function test_bls_key_verification() public {
        address registryCoordinator = brevis_registryCoordinator;

        id = 1;
        EtherFiAvsOperator operator = EtherFiAvsOperator(avsOperatorsManager.avsOperators(id));
        EtherFiAvsOperator.AvsInfo memory avsInfo = avsOperatorsManager.getAvsInfo(id, registryCoordinator);
        
        IBLSApkRegistry.PubkeyRegistrationParams memory params = avsInfo.params;

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
        
        // e(sigma + P * gamma, [-1]_2) = e(H(m) + [1]_1 * gamma, P') 
        require(BN254.pairing(
            BN254.plus(params.pubkeyRegistrationSignature, BN254.scalar_mul(params.pubkeyG1, gamma)),
            BN254.negGeneratorG2(),
            BN254.plus(pubkeyRegistrationMessageHash, BN254.scalar_mul(BN254.generatorG1(), gamma)),
            params.pubkeyG2
        ), "BLSApkRegistry.registerBLSPublicKey: either the G1 signature is wrong, or G1 and G2 private key do not match");

    }
}