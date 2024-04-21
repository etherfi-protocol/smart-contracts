// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import "@openzeppelin-upgradeable/contracts/utils/cryptography/ECDSAUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/interfaces/IERC1271Upgradeable.sol";

import "./eigenlayer-interfaces/IRegistryCoordinator.sol";
import "./eigenlayer-interfaces/ISignatureUtils.sol";
import "./eigenlayer-interfaces/IDelegationManager.sol";


contract EtherFiAvsOperator is IERC1271Upgradeable, IBeacon {


    address public avsOperatorsManager;
    address public ecdsaSigner;   // ECDSA signer that ether.fi owns
    address public avsNodeRunner; // Staking Company such as DSRV, Pier Two, Nethermind, ...

    struct AvsInfo {
        bool isWhitelisted;
        bytes UNUSED_quorumNumbers;
        string UNUSED_socket;
        IBLSApkRegistry.PubkeyRegistrationParams UNUSED_params;
        bool UNUSED_isRegistered;
    }
    mapping(address => AvsInfo) public avsInfos;

    function initialize(address _avsOperatorsManager) external {
        require(avsOperatorsManager == address(0), "ALREADY_INITIALIZED");
        avsOperatorsManager = _avsOperatorsManager;
    }

    // register this contract as a valid operator that can be delegated funds within eigenlayer core contracts
    function registerAsOperator(IDelegationManager _delegationManager, IDelegationManager.OperatorDetails calldata _detail, string calldata _metaDataURI) external managerOnly {
        _delegationManager.registerAsOperator(_detail, _metaDataURI);
    }

    function modifyOperatorDetails(IDelegationManager _delegationManager, IDelegationManager.OperatorDetails calldata _newOperatorDetails) external managerOnly {
        _delegationManager.modifyOperatorDetails(_newOperatorDetails);
    }

    function updateOperatorMetadataURI(IDelegationManager _delegationManager, string calldata _metadataURI) external managerOnly {
        _delegationManager.updateOperatorMetadataURI(_metadataURI);
    }

    function registerEigenDALikeOperator(
        address _avsRegistryCoordinator,
        bytes calldata _quorumNumbers,
        string calldata _socket,
        IBLSApkRegistry.PubkeyRegistrationParams calldata _params,
        ISignatureUtils.SignatureWithSaltAndExpiry memory _operatorSignature
    ) external managerOnly {
        require(isAvsWhitelisted(_avsRegistryCoordinator), "AVS_NOT_WHITELISTED");

        IRegistryCoordinator(_avsRegistryCoordinator).registerOperator(_quorumNumbers, _socket, _params, _operatorSignature);
    }

    function registerEigenDALikeOperatorWithChurn(
        address _avsRegistryCoordinator,
        bytes calldata _quorumNumbers,
        string calldata _socket,
        IBLSApkRegistry.PubkeyRegistrationParams calldata _params,
        IRegistryCoordinator.OperatorKickParam[] calldata _operatorKickParams,
        ISignatureUtils.SignatureWithSaltAndExpiry memory _churnApproverSignature,
        ISignatureUtils.SignatureWithSaltAndExpiry memory _operatorSignature
    ) external managerOnly {
        require(isAvsWhitelisted(_avsRegistryCoordinator), "AVS_NOT_WHITELISTED");

        IRegistryCoordinator(_avsRegistryCoordinator).registerOperatorWithChurn(
            _quorumNumbers,
            _socket,
            _params,
            _operatorKickParams,
            _churnApproverSignature,
            _operatorSignature
        );
    }

    function deregisterEigenDALikeOperator(
        address _avsRegistryCoordinator,
        bytes calldata _quorumNumbers
    ) external managerOnly {
        delete avsInfos[_avsRegistryCoordinator];

        IRegistryCoordinator(_avsRegistryCoordinator).deregisterOperator(_quorumNumbers);
    }

    // forwards a whitelisted call from the manager contract to an arbitrary target
    function forwardCall(address to, bytes calldata data) external managerOnly returns (bytes memory) {
        return Address.functionCall(to, data);
    }

    function updateAvsNodeRunner(address _avsNodeRunner) external managerOnly {
        avsNodeRunner = _avsNodeRunner;
    }

    function updateAvsWhitelist(address _avsRegistryCoordinator, bool _isWhitelisted) external managerOnly {
        avsInfos[_avsRegistryCoordinator].isWhitelisted = _isWhitelisted;
    }

    function updateEcdsaSigner(address _ecdsaSigner) external managerOnly {
        ecdsaSigner = _ecdsaSigner;
    }

    /**
     * @dev Should return whether the signature provided is valid for the provided data
     * @param _digestHash   Hash of the data to be signed
     * @param _signature Signature byte array associated with _data
    */
    function isValidSignature(bytes32 _digestHash, bytes memory _signature) public view override returns (bytes4 magicValue) {
        (address recovered, ) = ECDSAUpgradeable.tryRecover(_digestHash, _signature);
        return recovered == ecdsaSigner ? this.isValidSignature.selector : bytes4(0xffffffff);
    }

    function isAvsWhitelisted(address _avsRegistryCoordinator) public view returns (bool) {
        return avsInfos[_avsRegistryCoordinator].isWhitelisted;
    }

    /// @dev implementation address for beacon proxy.
    ///      https://docs.openzeppelin.com/contracts/3.x/api/proxy#beacon
    function implementation() external view returns (address) {
        bytes32 slot = bytes32(uint256(keccak256('eip1967.proxy.beacon')) - 1);
        address implementationVariable;
        assembly {
            implementationVariable := sload(slot)
        }

        IBeacon beacon = IBeacon(implementationVariable);
        return beacon.implementation();
    }

    function verifyBlsKeyAgainstHash(BN254.G1Point memory pubkeyRegistrationMessageHash, IBLSApkRegistry.PubkeyRegistrationParams memory params) public view returns (bool) {
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
        return BN254.pairing(
                BN254.plus(params.pubkeyRegistrationSignature, BN254.scalar_mul(params.pubkeyG1, gamma)),
                BN254.negGeneratorG2(),
                BN254.plus(pubkeyRegistrationMessageHash, BN254.scalar_mul(BN254.generatorG1(), gamma)),
                params.pubkeyG2
              );
    }

    function verifyBlsKey(address registryCoordinator, IBLSApkRegistry.PubkeyRegistrationParams memory params) public view returns (bool) {
        BN254.G1Point memory pubkeyRegistrationMessageHash = IRegistryCoordinator(registryCoordinator).pubkeyRegistrationMessageHash(address(this));

        return verifyBlsKeyAgainstHash(pubkeyRegistrationMessageHash, params);
    }

    modifier managerOnly() {
        require(msg.sender == avsOperatorsManager, "NOT_MANAGER");
        _;
    }
}
