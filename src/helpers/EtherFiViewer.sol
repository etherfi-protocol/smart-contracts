// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

import "src/interfaces/IEtherFiNodesManager.sol";

import "src/helpers/AddressProvider.sol";

contract EtherFiViewer is Initializable, OwnableUpgradeable, UUPSUpgradeable {

    AddressProvider addressProvider;

    IEtherFiNodesManager nodesManager;

    function initialize(address _addressProvider) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();

        addressProvider = AddressProvider(_addressProvider);

        nodesManager = IEtherFiNodesManager(addressProvider.getContractAddress("EtherFiNodesManager"));
    }

    function _getEtherFiNode(uint256 _validatorId) internal view returns (IEtherFiNode) {
        return IEtherFiNode(nodesManager.etherfiNodeAddress(_validatorId));
    }

    function EtherFiNodesManager_etherFiNodeAddress(uint256[] memory _validatorIds) external view returns (address[] memory _etherFiNodeAddresses) {
        _etherFiNodeAddresses = new address[](_validatorIds.length);

        for (uint256 i = 0; i < _validatorIds.length; i++) {
            _etherFiNodeAddresses[i] = address(_getEtherFiNode(_validatorIds[i]));
        }
    }

    function EtherFiNodesManager_splitBalanceInExecutionLayer(uint256[] memory _validatorIds) external view returns (uint256[] memory _withdrawalSafe, uint256[] memory _eigenPod, uint256[] memory _delayedWithdrawalRouter) {
        _withdrawalSafe = new uint256[](_validatorIds.length);
        _eigenPod = new uint256[](_validatorIds.length);
        _delayedWithdrawalRouter = new uint256[](_validatorIds.length);

        for (uint256 i = 0; i < _validatorIds.length; i++) {
            (_withdrawalSafe[i], _eigenPod[i], _delayedWithdrawalRouter[i]) = _getEtherFiNode(_validatorIds[i]).splitBalanceInExecutionLayer();
        }
    }

    function EtherFiNodesManager_withdrawableBalanceInExecutionLayer(uint256[] memory _validatorIds) external view returns (uint256[] memory _withdrawableBalance) {
        _withdrawableBalance = new uint256[](_validatorIds.length);

        for (uint256 i = 0; i < _validatorIds.length; i++) {
            _withdrawableBalance[i] = _getEtherFiNode(_validatorIds[i]).withdrawableBalanceInExecutionLayer();
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

}