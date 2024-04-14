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

    struct AvsInfo {
        bool isWhitelisted;
        bytes quorumNumbers;
        string socket;
        IBLSApkRegistry.PubkeyRegistrationParams params;
        bool isRegistered;
    }

    address public avsOperatorsManager;
    address public ecdsaSigner;   // ECDSA signer that ether.fi owns
    address public avsNodeRunner; // Staking Company such as DSRV, Pier Two, Nethermind, ...

    mapping(address => AvsInfo) public avsInfos;

    function initialize(address _avsOperatorsManager) external {
        require(avsOperatorsManager == address(0), "ALREADY_INITIALIZED");
        avsOperatorsManager = _avsOperatorsManager;
    }

    function registerAsOperator(IDelegationManager _delegationManager, IDelegationManager.OperatorDetails calldata _detail, string calldata _metaDataURI) external managerOnly {
        _delegationManager.registerAsOperator(_detail, _metaDataURI);
    }

    function modifyOperatorDetails(IDelegationManager _delegationManager, IDelegationManager.OperatorDetails calldata _newOperatorDetails) external managerOnly {
        _delegationManager.modifyOperatorDetails(_newOperatorDetails);
    }

    function updateOperatorMetadataURI(IDelegationManager _delegationManager, string calldata _metadataURI) external managerOnly {
        _delegationManager.updateOperatorMetadataURI(_metadataURI);
    }

    function updateSocket(address _avsRegistryCoordinator, string memory _socket) external {
        require(isAvsWhitelisted(_avsRegistryCoordinator), "AVS_NOT_WHITELISTED");
        require(isAvsRegistered(_avsRegistryCoordinator), "AVS_NOT_REGISTERED");

        IRegistryCoordinator(_avsRegistryCoordinator).updateSocket(_socket);
        avsInfos[_avsRegistryCoordinator].socket = _socket;
    }

    function registerBlsKeyAsDelegatedNodeOperator(
        address _avsRegistryCoordinator, 
        bytes calldata _quorumNumbers,
        string calldata _socket,
        IBLSApkRegistry.PubkeyRegistrationParams calldata _params
    ) external managerOnly {
        require(isAvsWhitelisted(_avsRegistryCoordinator), "AVS_NOT_WHITELISTED");
        require(!isAvsRegistered(_avsRegistryCoordinator), "AVS_ALREADY_REGISTERED");

        avsInfos[_avsRegistryCoordinator].quorumNumbers = _quorumNumbers;
        avsInfos[_avsRegistryCoordinator].socket = _socket;
        avsInfos[_avsRegistryCoordinator].params = _params;
    }

    function registerOperator(
        address _avsRegistryCoordinator,
        bytes calldata _quorumNumbers,
        string calldata _socket,
        IBLSApkRegistry.PubkeyRegistrationParams calldata _params,
        ISignatureUtils.SignatureWithSaltAndExpiry memory _operatorSignature
    ) external managerOnly {
        require(isAvsWhitelisted(_avsRegistryCoordinator), "AVS_NOT_WHITELISTED");
        require(!isAvsRegistered(_avsRegistryCoordinator), "AVS_ALREADY_REGISTERED");
        require(isRegisteredBlsKey(_avsRegistryCoordinator, _quorumNumbers, _socket, _params), "NOT_REGISTERED_BLS_KEY");

        avsInfos[_avsRegistryCoordinator].isRegistered = true;

        IRegistryCoordinator(_avsRegistryCoordinator).registerOperator(_quorumNumbers, _socket, _params, _operatorSignature);
    }

    function registerOperatorWithChurn(
        address _avsRegistryCoordinator,
        bytes calldata _quorumNumbers, 
        string calldata _socket,
        IBLSApkRegistry.PubkeyRegistrationParams calldata _params,
        IRegistryCoordinator.OperatorKickParam[] calldata _operatorKickParams,
        ISignatureUtils.SignatureWithSaltAndExpiry memory _churnApproverSignature,
        ISignatureUtils.SignatureWithSaltAndExpiry memory _operatorSignature
    ) external managerOnly {
        require(isAvsWhitelisted(_avsRegistryCoordinator), "AVS_NOT_WHITELISTED");
        require(!isAvsRegistered(_avsRegistryCoordinator), "AVS_ALREADY_REGISTERED");
        require(isRegisteredBlsKey(_avsRegistryCoordinator, _quorumNumbers, _socket, _params), "NOT_REGISTERED_BLS_KEY");

        IRegistryCoordinator(_avsRegistryCoordinator).registerOperatorWithChurn(_quorumNumbers, _socket, _params, _operatorKickParams, _churnApproverSignature, _operatorSignature);
    }

    function deregisterOperator(
        address _avsRegistryCoordinator,
        bytes calldata quorumNumbers
    ) external managerOnly {
        delete avsInfos[_avsRegistryCoordinator];

        IRegistryCoordinator(_avsRegistryCoordinator).deregisterOperator(quorumNumbers);
    }

    function runnerForwardCall(
        address _target, 
        bytes4 _selector, 
        bytes calldata _remainingCalldata) 
    external managerOnly returns (bytes memory) {
        require(isValidOperatorCall(_target, _selector, _remainingCalldata), "INVALID_OPERATOR_CALL");
        return Address.functionCall(_target, abi.encodePacked(_selector, _remainingCalldata));
    }

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


    // VIEW functions

    function getAvsInfo(address _avsRegistryCoordinator) external view returns (AvsInfo memory) {
        return avsInfos[_avsRegistryCoordinator];
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

    function isAvsRegistered(address _avsRegistryCoordinator) public view returns (bool) {
        return avsInfos[_avsRegistryCoordinator].isRegistered;
    }

    function isValidOperatorCall(address _avsRegistryCoordinator, bytes4 _selector, bytes calldata _remainingCalldata) public view returns (bool) {
        if (!isAvsWhitelisted(_avsRegistryCoordinator)) return false;

        if (_selector == hex"11d2c708") {
            // Witness Chain
            // OperatorRegistry.registerWatchtowerAsOperator(address watchtower, uint256 expiry, bytes memory signedMessage)
            // - https://github.com/witnesschain-com/diligencewatchtower-contracts/blob/main/src/core/OperatorRegistry.sol#L158
            return true;
        }
        
        return false;
    }

    function isRegisteredBlsKey(
        address _avsRegistryCoordinator,
        bytes calldata _quorumNumbers,
        string calldata _socket,
        IBLSApkRegistry.PubkeyRegistrationParams calldata _params
    ) public view returns (bool) {
        AvsInfo memory avsInfo = avsInfos[_avsRegistryCoordinator];
        bytes32 digestHash1 = keccak256(abi.encode(_avsRegistryCoordinator, _quorumNumbers, _socket, _params));
        bytes32 digestHash2 = keccak256(abi.encode(_avsRegistryCoordinator, avsInfo.quorumNumbers, avsInfo.socket, avsInfo.params));

        return digestHash1 == digestHash2;
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

    modifier managerOnly() {
        require(msg.sender == avsOperatorsManager, "NOT_MANAGER");
        _;
    }
}