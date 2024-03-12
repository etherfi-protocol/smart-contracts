// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./IEtherFiNode.sol";
import "../eigenlayer-interfaces/IEigenPodManager.sol";
import "../eigenlayer-interfaces/IDelegationManager.sol";
import "../eigenlayer-interfaces/IDelayedWithdrawalRouter.sol";

interface IEtherFiNodesManager {

    struct ValidatorInfo {
        uint32 validatorIndex;
        uint32 exitRequestTimestamp;
        uint32 exitTimestamp;
        IEtherFiNode.VALIDATOR_PHASE phase;
    }

    struct RewardsSplit {
        uint64 treasury;
        uint64 nodeOperator;
        uint64 tnft;
        uint64 bnft;
    }

    // VIEW functions
    function etherfiNodeAddress(uint256 _validatorId) external view returns (address);

    function calculateTVL(uint256 _validatorId, uint256 _beaconBalance) external view returns (uint256, uint256, uint256, uint256);
    function delayedWithdrawalRouter() external view returns (IDelayedWithdrawalRouter);
    function eigenPodManager() external view returns (IEigenPodManager);
    function delegationManager() external view returns (IDelegationManager);
    function generateWithdrawalCredentials(address _address) external view returns (bytes memory);
    function getFullWithdrawalPayouts(uint256 _validatorId) external view returns (uint256, uint256, uint256, uint256);
    function getNonExitPenalty(uint256 _validatorId) external view returns (uint256);
    function getRewardsPayouts(uint256 _validatorId) external view returns (uint256, uint256, uint256, uint256);
    function getWithdrawalCredentials(uint256 _validatorId) external view returns (bytes memory);
    function getValidatorInfo(uint256 _validatorId) external view returns (ValidatorInfo memory);
    function nonExitPenaltyDailyRate() external view returns (uint64);
    function nonExitPenaltyPrincipal() external view returns (uint64);
    function numberOfValidators() external view returns (uint64);
    function numAssociatedValidators(uint256 _validatorId) external view returns (uint256);
    function phase(uint256 _validatorId) external view returns (IEtherFiNode.VALIDATOR_PHASE phase);
    function maxEigenlayerWithdrawals() external view returns (uint8);

    function admins(address _address) external view returns (bool);
    function treasuryContract() external view returns (address);


    // Non-VIEW functions    
    function updateEtherFiNode(uint256 _validatorId) external;

    function batchQueueRestakedWithdrawal(uint256[] calldata _validatorIds) external;
    function batchSendExitRequest(uint256[] calldata _validatorIds) external;
    function batchRevertExitRequest(uint256[] calldata _validatorIds) external;
    function batchFullWithdraw(uint256[] calldata _validatorIds) external;
    function batchPartialWithdraw(uint256[] calldata _validatorIds) external;
    function fullWithdraw(uint256 _validatorId) external;
    function getUnusedWithdrawalSafesLength() external view returns (uint256);
    function incrementNumberOfValidators(uint64 _count) external;
    function markBeingSlashed(uint256[] calldata _validatorIds) external;
    function partialWithdraw(uint256 _validatorId) external;
    function processNodeExit(uint256[] calldata _validatorIds, uint32[] calldata _exitTimestamp) external;
    function allocateEtherFiNode(bool _enableRestaking) external returns (address);
    function registerValidator(uint256 _validatorId, bool _enableRestaking, address _withdrawalSafeAddress) external;
    function setValidatorPhase(uint256 _validatorId, IEtherFiNode.VALIDATOR_PHASE _phase) external;
    function setNonExitPenalty(uint64 _nonExitPenaltyDailyRate, uint64 _nonExitPenaltyPrincipal) external;
    function setStakingRewardsSplit(uint64 _treasury, uint64 _nodeOperator, uint64 _tnft, uint64 _bnf) external;
    function unregisterValidator(uint256 _validatorId) external;
    
    function updateAdmin(address _address, bool _isAdmin) external;
    function pauseContract() external;
    function unPauseContract() external;
}
