// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./IEtherFiNodesManager.sol";

import "../eigenlayer-interfaces/IDelegationManager.sol";


interface IEtherFiNode {
    // State Transition Diagram for StateMachine contract:
    //
    //      NOT_INITIALIZED <-
    //              |        |
    //              ↓        |
    //      STAKE_DEPOSITED --
    //           /    \      |
    //          ↓      ↓     |
    //         LIVE <- WAITING_FOR_APPROVAL
    //         |  \ 
    //         |   ↓  
    //         |  BEING_SLASHED
    //         |   /
    //         ↓  ↓
    //         EXITED
    //         |
    //         ↓
    //     FULLY_WITHDRAWN
    // 
    // Transitions are only allowed as directed above.
    // For instance, a transition from STAKE_DEPOSITED to either LIVE or CANCELLED is allowed,
    // but a transition from LIVE to NOT_INITIALIZED is not.
    //
    // All phase transitions should be made through the setPhase function,
    // which validates transitions based on these rules.
    //
    enum VALIDATOR_PHASE {
        NOT_INITIALIZED,
        STAKE_DEPOSITED,
        LIVE,
        EXITED,
        FULLY_WITHDRAWN,
        DEPRECATED_CANCELLED,
        BEING_SLASHED,
        DEPRECATED_EVICTED,
        WAITING_FOR_APPROVAL,
        DEPRECATED_READY_FOR_DEPOSIT
    }

    // VIEW functions
    function numAssociatedValidators() external view returns (uint256);
    function numExitRequestsByTnft() external view returns (uint16);
    function numExitedValidators() external view returns (uint16);
    function version() external view returns (uint16);
    function eigenPod() external view returns (address);
    function calculateTVL(uint256 _beaconBalance, IEtherFiNodesManager.ValidatorInfo memory _info, IEtherFiNodesManager.RewardsSplit memory _SRsplits, bool _onlyWithdrawable) external view returns (uint256, uint256, uint256, uint256);
    function getNonExitPenalty(uint32 _tNftExitRequestTimestamp, uint32 _bNftExitRequestTimestamp) external view returns (uint256);
    function getRewardsPayouts(uint32 _exitRequestTimestamp, IEtherFiNodesManager.RewardsSplit memory _splits) external view returns (uint256, uint256, uint256, uint256);
    function getFullWithdrawalPayouts(IEtherFiNodesManager.ValidatorInfo memory _info, IEtherFiNodesManager.RewardsSplit memory _SRsplits) external view returns (uint256, uint256, uint256, uint256);
    function associatedValidatorIds(uint256 _index) external view returns (uint256);
    function associatedValidatorIndices(uint256 _validatorId) external view returns (uint256);
    function validatePhaseTransition(VALIDATOR_PHASE _currentPhase, VALIDATOR_PHASE _newPhase) external pure returns (bool);

    function DEPRECATED_exitRequestTimestamp() external view returns (uint32);
    function DEPRECATED_exitTimestamp() external view returns (uint32);
    function DEPRECATED_phase() external view returns (VALIDATOR_PHASE);

    // Non-VIEW functions
    function initialize(address _etherFiNodesManager) external;
    function claimQueuedWithdrawals(uint256 maxNumWithdrawals, bool _checkIfHasOutstandingEigenLayerWithdrawals) external returns (bool);
    function createEigenPod() external;
    function hasOutstaingEigenPodWithdrawalsQueuedBeforeExit() external view returns (bool);
    function isRestakingEnabled() external view returns (bool);
    function processNodeExit(uint256 _validatorId) external returns (bytes32[] memory withdrawalRoots);
    function processFullWithdraw(uint256 _validatorId) external;
    function queueRestakedWithdrawal() external returns (bytes32[] memory withdrawalRoots);
    function completeQueuedWithdrawals(IDelegationManager.Withdrawal[] memory withdrawals, uint256[] calldata middlewareTimesIndexes) external;
    function completeQueuedWithdrawal(IDelegationManager.Withdrawal memory withdrawals, uint256 middlewareTimesIndexes) external;
    function updateNumberOfAssociatedValidators(uint16 _up, uint16 _down) external;
    function updateNumExitedValidators(uint16 _up, uint16 _down) external;
    function registerValidator(uint256 _validatorId, bool _enableRestaking) external;
    function unRegisterValidator(uint256 _validatorId, IEtherFiNodesManager.ValidatorInfo memory _info) external returns (bool);
    function splitBalanceInExecutionLayer() external view returns (uint256 _withdrawalSafe, uint256 _eigenPod, uint256 _delayedWithdrawalRouter);
    function totalBalanceInExecutionLayer() external view returns (uint256);
    function withdrawableBalanceInExecutionLayer() external view returns (uint256);
    function updateNumExitRequests(uint16 _up, uint16 _down) external;
    function migrateVersion(uint256 _validatorId, IEtherFiNodesManager.ValidatorInfo memory _info) external;

    function callEigenPod(bytes memory data) external returns (bytes memory);
    function forwardCall(address to, bytes memory data) external returns (bytes memory);

    function withdrawFunds(
        address _treasury,
        uint256 _treasuryAmount,
        address _operator,
        uint256 _operatorAmount,
        address _tnftHolder,
        uint256 _tnftAmount,
        address _bnftHolder,
        uint256 _bnftAmount
    ) external;

    function moveFundsToManager(uint256 _amount) external;
}
