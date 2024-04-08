// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/interfaces/IERC1271Upgradeable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";

import "@openzeppelin-upgradeable/contracts/utils/cryptography/ECDSAUpgradeable.sol";

import "./eigenlayer-interfaces/IRegistryCoordinator.sol";
import "./eigenlayer-interfaces/ISignatureUtils.sol";


contract EtherFiAvsOperator is IERC1271Upgradeable {

    struct AvsInfo {
        bool isWhitelisted;
    }

    address public avsOperatorsManager;
    address public ecdsaSigner;
    address public avsNodeOperator;

    mapping(address => AvsInfo) public avsInfos;


    function initialize(address _avsOperatorsManager) external managerOnly {
        require(avsOperatorsManager == address(0), "ALREADY_INITIALIZED");
        avsOperatorsManager = _avsOperatorsManager;
    }

    function registerOperator(
        address _avsContract,
        bytes calldata _quorumNumbers,
        string calldata _socket,
        IBLSApkRegistry.PubkeyRegistrationParams calldata _params,
        ISignatureUtils.SignatureWithSaltAndExpiry memory _operatorSignature
    ) external managerOnly {
        require(isAvsWhitelisted(_avsContract), "AVS_NOT_WHITELISTED");

        IRegistryCoordinator(_avsContract).registerOperator(_quorumNumbers, _socket, _params, _operatorSignature);
    }

    function registerOperatorWithChurn(
        address _avsContract,
        bytes calldata _quorumNumbers, 
        string calldata _socket,
        IBLSApkRegistry.PubkeyRegistrationParams calldata _params,
        IRegistryCoordinator.OperatorKickParam[] calldata _operatorKickParams,
        ISignatureUtils.SignatureWithSaltAndExpiry memory _churnApproverSignature,
        ISignatureUtils.SignatureWithSaltAndExpiry memory _operatorSignature
    ) external managerOnly {
        require(isAvsWhitelisted(_avsContract), "AVS_NOT_WHITELISTED");

        IRegistryCoordinator(_avsContract).registerOperatorWithChurn(_quorumNumbers, _socket, _params, _operatorKickParams, _churnApproverSignature, _operatorSignature);
    }

    function deregisterOperator(
        address _avsContract,
        bytes calldata quorumNumbers
    ) external managerOnly {
        IRegistryCoordinator(_avsContract).deregisterOperator(quorumNumbers);
    }

    function operatorForwardCall(
        address _avsContract, 
        bytes4 _signature, 
        bytes calldata _remainingCalldata) 
    external managerOnly returns (bytes memory) {
        require(isValidOperatorCall(_avsContract, _signature, _remainingCalldata), "INVALID_OPERATOR_CALL");
        return Address.functionCall(_avsContract, abi.encodePacked(_signature, _remainingCalldata));
    }

    function forwardCall(address to, bytes calldata data) external managerOnly returns (bytes memory) {
        return Address.functionCall(to, data);
    }

    function updateAvsNodeOperator(address _avsNodeOperator) external managerOnly {
        avsNodeOperator = _avsNodeOperator;
    }

    function updateAvsWhitelist(address _avsContract, bool _isWhitelisted) external managerOnly {
        avsInfos[_avsContract].isWhitelisted = _isWhitelisted;
    }

    function updateEcdsaSigner(address _ecdsaSigner) external managerOnly {
        ecdsaSigner = _ecdsaSigner;
    }


    // VIEW functions

    /**
     * @dev Should return whether the signature provided is valid for the provided data
     * @param _digestHash   Hash of the data to be signed
     * @param _signature Signature byte array associated with _data
    */
    function isValidSignature(bytes32 _digestHash, bytes memory _signature) public view override returns (bytes4 magicValue) {
        return ECDSAUpgradeable.recover(_digestHash, _signature) == ecdsaSigner ? this.isValidSignature.selector : bytes4(0xffffffff);
    }

    function isAvsWhitelisted(address _avsContract) public view returns (bool) {
        return avsInfos[_avsContract].isWhitelisted;
    }

    // Disabled all forward calls for now.
    function isValidOperatorCall(address _avsContract, bytes4 _signature, bytes calldata _remainingCalldata) public view returns (bool) {
        if (!isAvsWhitelisted(_avsContract)) return false;
        return false;
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