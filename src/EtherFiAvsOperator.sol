// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/interfaces/IERC1271Upgradeable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "@openzeppelin-upgradeable/contracts/utils/cryptography/ECDSAUpgradeable.sol";


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

    function forwardCall(address to, bytes memory data) external onlyOwner returns (bytes memory) {
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
        return ECDSAUpgradeable.recover(_digestHash, _signature) == avs_operator ? this.isValidSignature.selector : bytes4(0);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}