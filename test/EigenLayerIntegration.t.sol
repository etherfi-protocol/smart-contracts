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

    bytes internal constant beaconProxyBytecode =
        hex"608060405260405161090e38038061090e83398101604081905261002291610460565b61002e82826000610035565b505061058a565b61003e83610100565b6040516001600160a01b038416907f1cf3b03a6cf19fa2baba4df148e9dcabedea7f8a5c07840e207e5c089be95d3e90600090a260008251118061007f5750805b156100fb576100f9836001600160a01b0316635c60da1b6040518163ffffffff1660e01b8152600401602060405180830381865afa1580156100c5573d6000803e3d6000fd5b505050506040513d601f19601f820116820180604052508101906100e99190610520565b836102a360201b6100291760201c565b505b505050565b610113816102cf60201b6100551760201c565b6101725760405162461bcd60e51b815260206004820152602560248201527f455243313936373a206e657720626561636f6e206973206e6f74206120636f6e6044820152641d1c9858dd60da1b60648201526084015b60405180910390fd5b6101e6816001600160a01b0316635c60da1b6040518163ffffffff1660e01b8152600401602060405180830381865afa1580156101b3573d6000803e3d6000fd5b505050506040513d601f19601f820116820180604052508101906101d79190610520565b6102cf60201b6100551760201c565b61024b5760405162461bcd60e51b815260206004820152603060248201527f455243313936373a20626561636f6e20696d706c656d656e746174696f6e206960448201526f1cc81b9bdd08184818dbdb9d1c9858dd60821b6064820152608401610169565b806102827fa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d5060001b6102de60201b6100641760201c565b80546001600160a01b0319166001600160a01b039290921691909117905550565b60606102c883836040518060600160405280602781526020016108e7602791396102e1565b9392505050565b6001600160a01b03163b151590565b90565b6060600080856001600160a01b0316856040516102fe919061053b565b600060405180830381855af49150503d8060008114610339576040519150601f19603f3d011682016040523d82523d6000602084013e61033e565b606091505b5090925090506103508683838761035a565b9695505050505050565b606083156103c65782516103bf576001600160a01b0385163b6103bf5760405162461bcd60e51b815260206004820152601d60248201527f416464726573733a2063616c6c20746f206e6f6e2d636f6e74726163740000006044820152606401610169565b50816103d0565b6103d083836103d8565b949350505050565b8151156103e85781518083602001fd5b8060405162461bcd60e51b81526004016101699190610557565b80516001600160a01b038116811461041957600080fd5b919050565b634e487b7160e01b600052604160045260246000fd5b60005b8381101561044f578181015183820152602001610437565b838111156100f95750506000910152565b6000806040838503121561047357600080fd5b61047c83610402565b60208401519092506001600160401b038082111561049957600080fd5b818501915085601f8301126104ad57600080fd5b8151818111156104bf576104bf61041e565b604051601f8201601f19908116603f011681019083821181831017156104e7576104e761041e565b8160405282815288602084870101111561050057600080fd5b610511836020830160208801610434565b80955050505050509250929050565b60006020828403121561053257600080fd5b6102c882610402565b6000825161054d818460208701610434565b9190910192915050565b6020815260008251806020840152610576816040850160208701610434565b601f01601f19169190910160400192915050565b61034e806105996000396000f3fe60806040523661001357610011610017565b005b6100115b610027610022610067565b610100565b565b606061004e83836040518060600160405280602781526020016102f260279139610124565b9392505050565b6001600160a01b03163b151590565b90565b600061009a7fa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50546001600160a01b031690565b6001600160a01b0316635c60da1b6040518163ffffffff1660e01b8152600401602060405180830381865afa1580156100d7573d6000803e3d6000fd5b505050506040513d601f19601f820116820180604052508101906100fb9190610249565b905090565b3660008037600080366000845af43d6000803e80801561011f573d6000f35b3d6000fd5b6060600080856001600160a01b03168560405161014191906102a2565b600060405180830381855af49150503d806000811461017c576040519150601f19603f3d011682016040523d82523d6000602084013e610181565b606091505b50915091506101928683838761019c565b9695505050505050565b6060831561020d578251610206576001600160a01b0385163b6102065760405162461bcd60e51b815260206004820152601d60248201527f416464726573733a2063616c6c20746f206e6f6e2d636f6e747261637400000060448201526064015b60405180910390fd5b5081610217565b610217838361021f565b949350505050565b81511561022f5781518083602001fd5b8060405162461bcd60e51b81526004016101fd91906102be565b60006020828403121561025b57600080fd5b81516001600160a01b038116811461004e57600080fd5b60005b8381101561028d578181015183820152602001610275565b8381111561029c576000848401525b50505050565b600082516102b4818460208701610272565b9190910192915050565b60208152600082518060208401526102dd816040850160208701610272565b601f01601f1916919091016040019291505056fe416464726573733a206c6f772d6c6576656c2064656c65676174652063616c6c206661696c6564a2646970667358221220d51e81d3bc5ed20a26aeb05dce7e825c503b2061aa78628027300c8d65b9d89a64736f6c634300080c0033416464726573733a206c6f772d6c6576656c2064656c65676174652063616c6c206661696c6564";
    
    address podOwner;
    address podAddress;
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

        // // Two validators are launched for the eigenPod (0x54c..)
        // // - https://holesky.beaconcha.in/validator/874b46606ee21aa7f6c5b7ca3466895bd1a993ff20de71b983695da7f13a9c06c77ef950fbfc8fa3aad4799b54edc97e#deposits
        // // - https://holesky.beaconcha.in/validator/aef293411fed042f21f4ab1d05ff054d21ef3b7a4747ed4d06693dbba0fc33a14378c04f70366b8b038007db6d83809f#deposits
        // eigenPod = 0x54c702BABacccd92F7bd624C9c17581B5aDa81Ec;
        // podOwner = 0x16eAd66b7CBcAb3F3Cd49e04E6C74b02b05d98E8;

        // {EigenPod, EigenPodOwner} used in EigenLayer's unit test
        podOwner = address(42000094993494);
        podAddress = 0x49c486E3f4303bc11C02F952Fe5b08D0AB22D443;

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

    // Example from the EigenLayer repo
    function test_verifyWithdrawalCredentials_EL() public {
        // Generate the proofs using the library
        setJSON("./test/eigenlayer-utils/test-data/withdrawal_credential_proof_302913.json");
        _setWithdrawalCredentialParams();
        _setOracleBlockRoot();

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
        managerInstance.callEigenPod(validatorId, abi.encodeWithSelector(selector, oracleTimestamp, stateRootProof, validatorIndices, validatorFieldsProofs, validatorFields));
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
        managerInstance.callDelegationManager(validatorId, abi.encodeWithSelector(selector, p2p, signatureWithExpiry, bytes32(0)));
        // == delegationManager.delegateTo(p2p, signatureWithExpiry, bytes32(0));
        vm.stopPrank();
    }

}