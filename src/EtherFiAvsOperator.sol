// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/interfaces/IERC1271Upgradeable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "@openzeppelin-upgradeable/contracts/utils/cryptography/ECDSAUpgradeable.sol";

import "./eigenlayer-interfaces/IRegistryCoordinator.sol";
import "./eigenlayer-interfaces/ISignatureUtils.sol";


contract EtherFiAvsOperator is Initializable, OwnableUpgradeable, UUPSUpgradeable, IERC1271Upgradeable {

    address public avs_operator;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
    }

    function registerOperator(
        address _avsContract,
        bytes calldata _quorumNumbers,
        string calldata _socket,
        IBLSApkRegistry.PubkeyRegistrationParams calldata _params,
        ISignatureUtils.SignatureWithSaltAndExpiry memory _operatorSignature
    ) external operatorOnly {
        require(isAvsWhitelisted(_avsContract), "AVS_NOT_WHITELISTED");

        return IRegistryCoordinator(_avsContract).registerOperator(_quorumNumbers, _socket, _params, _operatorSignature);
    }

    function registerOperatorWithChurn(
        address _avsContract,
        bytes calldata _quorumNumbers, 
        string calldata _socket,
        IBLSApkRegistry.PubkeyRegistrationParams calldata _params,
        IRegistryCoordinator.OperatorKickParam[] calldata _operatorKickParams,
        ISignatureUtils.SignatureWithSaltAndExpiry memory _churnApproverSignature,
        ISignatureUtils.SignatureWithSaltAndExpiry memory _operatorSignature
    ) external operatorOnly {
        require(isAvsWhitelisted(_avsContract), "AVS_NOT_WHITELISTED");

        return IRegistryCoordinator(_avsContract).registerOperatorWithChurn(_quorumNumbers, _socket, _params, _operatorKickParams, _churnApproverSignature, _operatorSignature);
    }

    function deregisterOperator(
        address _avsContract,
        bytes calldata quorumNumbers
    ) external {
        return IRegistryCoordinator(_avsContract).deregisterOperator(quorumNumbers);
    }

    function operatorForwardCall(address _avsContract, bytes4 _signature, bytes calldata _remainingCalldata) external operatorOnly returns (bytes memory) {
        require(isValidOperatorCall(_avsContract, _signature, _remainingCalldata), "INVALID_OPERATOR_CALL");
        Address.functionCall(_avsContract, abi.encodePacked(_signature, _remainingCalldata));
    }

    function forwardCall(address to, bytes calldata data) external onlyOwner returns (bytes memory) {
        return Address.functionCall(to, data);
    }

    function changeAvsOperator(address _avs_operator) external onlyOwner {
        avs_operator = _avs_operator;
    }

    /**
     * @dev Should return whether the signature provided is valid for the provided data
     * @param _digestHash   Hash of the data to be signed
     * @param _signature Signature byte array associated with _data
     */
    function isValidSignature(bytes32 _digestHash, bytes memory _signature) public view override returns (bytes4 magicValue) {
        return ECDSAUpgradeable.recover(_digestHash, _signature) == owner() ? this.isValidSignature.selector : bytes4(0);
    }

    function isAvsWhitelisted(address _avsContract) public view returns (bool) {
        // TODO
        return true;
    }

    function isValidOperatorCall(address _avsContract, bytes4 _signature, bytes calldata _remainingCalldata) public view returns (bool) {
        if (!(isAvsWhitelisted(_avsContract))) return false;
        
        // TODO: Add some rules or refer to Mapping
        return false;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    modifier operatorOnly() {
        require(msg.sender == avs_operator || msg.sender == owner(), "NOT_OPERATOR");
        _;
    }
}