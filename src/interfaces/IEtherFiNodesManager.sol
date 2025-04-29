// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;


import "./IEtherFiNode.sol";

import "../eigenlayer-interfaces/IEigenPodManager.sol";
import "../eigenlayer-interfaces/IDelegationManager.sol";
import "../eigenlayer-interfaces/IDelayedWithdrawalRouter.sol";
import "../interfaces/IAuctionManager.sol";
import "../interfaces/IEtherFiNode.sol";
import "../interfaces/IEtherFiNodesManager.sol";
import "../interfaces/IProtocolRevenueManager.sol";
import "../interfaces/IStakingManager.sol";



interface IEtherFiNodesManager {

    struct LegacyManagerState {
        uint64 numberOfValidators; // # of validators in LIVE or WAITING_FOR_APPROVAL phases
        uint64 nonExitPenaltyPrincipal;
        uint64 nonExitPenaltyDailyRate; // in basis points
        uint64 SCALE;

        address treasuryContract;
        address stakingManagerContract;
        address DEPRECATED_protocolRevenueManagerContract;

        // validatorId == bidId -> withdrawalSafeAddress
        mapping(uint256 => address) etherfiNodeAddress;

        address tnft;
        address bnft;
        IAuctionManager auctionManager;
        IProtocolRevenueManager DEPRECATED_protocolRevenueManager;

        RewardsSplit stakingRewardsSplit;
        RewardsSplit DEPRECATED_protocolRewardsSplit;

        address DEPRECATED_admin;
        mapping(address => bool) admins;

        IEigenPodManager eigenPodManager;
        IDelayedWithdrawalRouter delayedWithdrawalRouter;
        // max number of queued eigenlayer withdrawals to attempt to claim in a single tx
        uint8 maxEigenlayerWithdrawals;

        // stack of re-usable withdrawal safes to save gas
        address[] unusedWithdrawalSafes;

        bool DEPRECATED_enableNodeRecycling;

        mapping(uint256 => ValidatorInfo) validatorInfos;

        IDelegationManager delegationManager;

        mapping(address => bool) operatingAdmin;

        // function -> allowed
        mapping(bytes4 => bool) allowedForwardedEigenpodCalls;
        // function -> target_address -> allowed
        mapping(bytes4 => mapping(address => bool)) allowedForwardedExternalCalls;
    }

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

    function forwardExternalCall(address[] calldata nodes, bytes[] calldata data, address target) external returns (bytes[] memory returnData);
    function addressToWithdrawalCredentials(address addr) external pure returns (bytes memory);
    function linkPubkeyToNode(bytes calldata pubkey, address nodeAddress, uint256 legacyId) external;
    function etherFiNodeFromPubkeyHash(bytes32 pubkeyHash) external view returns (IEtherFiNode);

    function getEigenPod(uint256 id) external view returns (address);

    function etherFiNodeFromId(uint256 id) public view returns (address);


    function eigenPodManager() external view returns (address);
    function delegationManager() external view returns (address);

    function pauseContract() external;
    function unPauseContract() external;



    // VIEW functions
    /*
    function delayedWithdrawalRouter() external view returns (IDelayedWithdrawalRouter);
    function eigenPodManager() external view returns (IEigenPodManager);
    function delegationManager() external view returns (IDelegationManager);
    function treasuryContract() external view returns (address);
    function unusedWithdrawalSafes(uint256 _index) external view returns (address);

    function etherfiNodeAddress(uint256 _validatorId) external view returns (address);
    function calculateTVL(uint256 _validatorId, uint256 _beaconBalance) external view returns (uint256, uint256, uint256, uint256);
    function getFullWithdrawalPayouts(uint256 _validatorId) external view returns (uint256, uint256, uint256, uint256);
    function getNonExitPenalty(uint256 _validatorId) external view returns (uint256);
    function getRewardsPayouts(uint256 _validatorId) external view returns (uint256, uint256, uint256, uint256);
    function getWithdrawalCredentials(uint256 _validatorId) external view returns (bytes memory);
    function getValidatorInfo(uint256 _validatorId) external view returns (ValidatorInfo memory);
    function numAssociatedValidators(uint256 _validatorId) external view returns (uint256);
    function phase(uint256 _validatorId) external view returns (IEtherFiNode.VALIDATOR_PHASE phase);
    function getEigenPod(uint256 _validatorId) external view returns (IEigenPod);

    function generateWithdrawalCredentials(address _address) external view returns (bytes memory);
    function nonExitPenaltyDailyRate() external view returns (uint64);
    function nonExitPenaltyPrincipal() external view returns (uint64);
    function numberOfValidators() external view returns (uint64);
    function maxEigenlayerWithdrawals() external view returns (uint8);

    function admins(address _address) external view returns (bool);
    function operatingAdmin(address _address) external view returns (bool);

    // Non-VIEW functions    
    function updateEtherFiNode(uint256 _validatorId) external;

    function batchQueueRestakedWithdrawal(uint256[] calldata _validatorIds) external;
    function batchSendExitRequest(uint256[] calldata _validatorIds) external;
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
    */
}
