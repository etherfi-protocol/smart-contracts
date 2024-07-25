// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

import "src/interfaces/IEtherFiNodesManager.sol";
import "src/eigenlayer-interfaces/IEigenPod.sol";
import "src/eigenlayer-interfaces/IEigenPodManager.sol";

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

    function _getDelegationManager() internal view returns (IDelegationManager) {
        return nodesManager.delegationManager();
    }

    function _getEigenPodManager() internal view returns (IEigenPodManager) {
        return nodesManager.eigenPodManager();
    }

    function _getEtherFiNode(uint256 _validatorId) internal view returns (IEtherFiNode) {
        return IEtherFiNode(nodesManager.etherfiNodeAddress(_validatorId));
    }

    function _getEigenPod(uint256 _validatorId) internal view returns (IEigenPod) {
        return IEigenPod(_getEtherFiNode(_validatorId).eigenPod());
    }

    function EigenPod_nonBeaconChainETHBalanceWei(uint256[] memory _validatorIds) external view returns (uint256[] memory _nonBeaconChainETHBalanceWei) {
        _nonBeaconChainETHBalanceWei = new uint256[](_validatorIds.length);
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            _nonBeaconChainETHBalanceWei[i] = _getEigenPod(_validatorIds[i]).nonBeaconChainETHBalanceWei();
        }
    }

    function EigenPod_mostRecentWithdrawalTimestamp(uint256[] memory _validatorIds) external view returns (uint256[] memory _mostRecentWithdrawalTimestamp) {
        _mostRecentWithdrawalTimestamp = new uint256[](_validatorIds.length);
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            _mostRecentWithdrawalTimestamp[i] = _getEigenPod(_validatorIds[i]).mostRecentWithdrawalTimestamp();
        }
    }

    function EigenPod_validatorPubkeyHashToInfo(uint256[] memory _validatorIds, bytes[][] memory _validatorPubkeys) external view returns (IEigenPod.ValidatorInfo[][] memory _validatorInfos) {
        _validatorInfos = new IEigenPod.ValidatorInfo[][](_validatorIds.length);
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            _validatorInfos[i] = new IEigenPod.ValidatorInfo[](_validatorPubkeys[i].length);
            for (uint256 j = 0; j < _validatorPubkeys[i].length; j++) {
                _validatorInfos[i][j] = _getEigenPod(_validatorIds[i]).validatorPubkeyToInfo(_validatorPubkeys[i][j]);
            }
        }
    }

    function EigenPod_validatorStatus(uint256[] memory _validatorIds, bytes[][] memory _validatorPubkeys) external view returns (IEigenPod.VALIDATOR_STATUS[][] memory _validatorStatuses) {
        _validatorStatuses = new IEigenPod.VALIDATOR_STATUS[][](_validatorIds.length);
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            _validatorStatuses[i] = new IEigenPod.VALIDATOR_STATUS[](_validatorPubkeys[i].length);
            for (uint256 j = 0; j < _validatorPubkeys[i].length; j++) {
                _validatorStatuses[i][j] = _getEigenPod(_validatorIds[i]).validatorStatus(_validatorPubkeys[i][j]);
            }
        }
    }

    function EigenPodManager_podOwnerShares(uint256[] memory _validatorIds) external view returns (int256[] memory _podOwnerShares) {
        _podOwnerShares = new int256[](_validatorIds.length);
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            address podOwner = address(_getEtherFiNode(_validatorIds[i]));
            _podOwnerShares[i] = _getEigenPodManager().podOwnerShares(podOwner);
        }
    }

    function DelegationManager_delegatedTo(uint256[] memory _validatorIds) external view returns (address[] memory _delegatedTo) {
        _delegatedTo = new address[](_validatorIds.length);
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            address podOwner = address(_getEtherFiNode(_validatorIds[i]));
            _delegatedTo[i] = _getDelegationManager().delegatedTo(podOwner);
        }
    }

    function DelegationManager_operatorDetails(address[] memory _operators) external view returns (IDelegationManager.OperatorDetails[] memory _operatorDetails) {
        _operatorDetails = new IDelegationManager.OperatorDetails[](_operators.length);
        for (uint256 i = 0; i < _operators.length; i++) {
            _operatorDetails[i] = _getDelegationManager().operatorDetails(_operators[i]);
        }
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
