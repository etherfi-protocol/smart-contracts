// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

import "@etherfi/staking/interfaces/IEtherFiNodesManager.sol";
import "@etherfi/interfaces/eigenlayer-interfaces/IEigenPod.sol";
import "@etherfi/interfaces/eigenlayer-interfaces/IEigenPodManager.sol";
import "@etherfi/interfaces/eigenlayer-interfaces/IDelegationManager.sol";

import "@etherfi/helpers/AddressProvider.sol";

interface ILegacyViewerNodesManager {
    function delegationManager() external view returns (IDelegationManager);
    function eigenPodManager() external view returns (IEigenPodManager);
    function getUnusedWithdrawalSafesLength() external view returns (uint256);
    function unusedWithdrawalSafes(uint256 index) external view returns (address);
}

interface ILegacyViewerNode {
    function eigenPod() external view returns (address);
    function isRestakingEnabled() external view returns (bool);
    function withdrawableBalanceInExecutionLayer() external view returns (uint256);
    function numAssociatedValidators() external view returns (uint256);
    function version() external view returns (uint256);
}

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
        return ILegacyViewerNodesManager(address(nodesManager)).delegationManager();
    }

    function _getEigenPodManager() internal view returns (IEigenPodManager) {
        return ILegacyViewerNodesManager(address(nodesManager)).eigenPodManager();
    }

    function _getEtherFiNode(uint256 _validatorId) internal view returns (IEtherFiNode) {
        return IEtherFiNode(nodesManager.etherfiNodeAddress(_validatorId));
    }

    function _getEigenPod(uint256 _validatorId) internal view returns (IEigenPod) {
        return IEigenPod(ILegacyViewerNode(address(_getEtherFiNode(_validatorId))).eigenPod());
    }

    function EigenPod_hasRestaked(uint256[] memory _validatorIds) external view returns (bool[] memory _hasRestaked) {
        _hasRestaked = new bool[](_validatorIds.length);
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            _hasRestaked[i] = ILegacyViewerNode(address(_getEtherFiNode(_validatorIds[i]))).isRestakingEnabled();
        }
    }

    function EigenPod_withdrawableRestakedExecutionLayerGwei(uint256[] memory _validatorIds) external view returns (uint256[] memory _withdrawableRestakedExecutionLayerGwei) {
        _withdrawableRestakedExecutionLayerGwei = new uint256[](_validatorIds.length);
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            _withdrawableRestakedExecutionLayerGwei[i] = _getEigenPod(_validatorIds[i]).withdrawableRestakedExecutionLayerGwei();
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

    function EigenPod_validatorPubkeyToInfo(uint256[] memory _validatorIds, bytes[][] memory _validatorPubkeys) external view returns (IEigenPod.ValidatorInfo[][] memory _validatorInfos) {
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

    // WARNING: these shares have not been scaled by any slashing events
    function EigenPodManager_podOwnerDepositShares(uint256[] memory _validatorIds) external view returns (int256[] memory _podOwnerShares) {
        _podOwnerShares = new int256[](_validatorIds.length);
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            address podOwner = address(_getEtherFiNode(_validatorIds[i]));
            _podOwnerShares[i] = _getEigenPodManager().podOwnerDepositShares(podOwner);
        }
    }

    function DelegationManager_delegatedTo(uint256[] memory _validatorIds) external view returns (address[] memory _delegatedTo) {
        _delegatedTo = new address[](_validatorIds.length);
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            address podOwner = address(_getEtherFiNode(_validatorIds[i]));
            _delegatedTo[i] = _getDelegationManager().delegatedTo(podOwner);
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
            _withdrawalSafe[i] = address(_getEtherFiNode(_validatorIds[i])).balance;
            _eigenPod[i] = address(_getEigenPod(_validatorIds[i])).balance;
            _delayedWithdrawalRouter[i] = 0;
        }
    }

    function EtherFiNodesManager_withdrawableBalanceInExecutionLayer(uint256[] memory _validatorIds) external view returns (uint256[] memory _withdrawableBalance) {
        _withdrawableBalance = new uint256[](_validatorIds.length);
        for (uint256 i = 0; i < _validatorIds.length; i++) {
            _withdrawableBalance[i] = ILegacyViewerNode(address(_getEtherFiNode(_validatorIds[i]))).withdrawableBalanceInExecutionLayer();
        }
    }

    function EtherFiNodesManager_aggregatedBalanceOfUnusedSafes() external view returns (uint256 total) {
        ILegacyViewerNodesManager manager = ILegacyViewerNodesManager(address(nodesManager));
        uint256 n = manager.getUnusedWithdrawalSafesLength();
        for (uint256 i = 0; i < n; i++) {
            address safe = manager.unusedWithdrawalSafes(i);
            address eigenpod = ILegacyViewerNode(safe).eigenPod();
            total += safe.balance + eigenpod.balance;
        }
    }

    function EtherFiNode_withdrawableBalanceInExecutionLayer(address[] memory _etherFiNodes) external view returns (uint256[] memory _withdrawableBalance) {
        _withdrawableBalance = new uint256[](_etherFiNodes.length);
        for (uint256 i = 0; i < _etherFiNodes.length; i++) {
            _withdrawableBalance[i] = ILegacyViewerNode(_etherFiNodes[i]).withdrawableBalanceInExecutionLayer();
        }
    }

    function EtherFiNode_numAssociatedValidators(address[] memory _etherFiNodes) external view returns (uint256[] memory _numAssociatedValidators) {
        _numAssociatedValidators = new uint256[](_etherFiNodes.length);
        for (uint256 i = 0; i < _etherFiNodes.length; i++) {
            _numAssociatedValidators[i] = ILegacyViewerNode(_etherFiNodes[i]).numAssociatedValidators();
        }
    }

    function EtherFiNode_version(address[] memory _etherFiNodes) external view returns (uint256[] memory _versions) {
        _versions = new uint256[](_etherFiNodes.length);
        for (uint256 i = 0; i < _etherFiNodes.length; i++) {
            _versions[i] = ILegacyViewerNode(_etherFiNodes[i]).version();
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
