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

    function etherFiNodeFromPubkeyHash(bytes32 pubkeyHash) external view returns (IEtherFiNode);
    function etherFiNodeFromId(uint256 id) external view returns (address);

    struct LegacyManagerState {
        uint64 test;
        mapping(uint256 => address) DEPRECATED_etherfiNodeAddress;
        /*
        uint64 numberOfValidators; // # of validators in LIVE or WAITING_FOR_APPROVAL phases
        uint64 nonExitPenaltyPrincipal;
        uint64 nonExitPenaltyDailyRate; // in basis points
        uint64 SCALE;

        address treasuryContract;
        address stakingManagerContract;
        address DEPRECATED_protocolRevenueManagerContract;

        // validatorId == bidId -> withdrawalSafeAddress
        */

        /*
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
        */
    }

    /*
    struct ValidatorInfo {
        uint32 validatorIndex;
        uint32 exitRequestTimestamp;
        uint32 exitTimestamp;
        IEtherFiNode.VALIDATOR_PHASE phase;
    }
    */

    //function linkPubkeyToNode(bytes calldata pubkey, address nodeAddress, uint256 legacyId) external;
    //function etherFiNodeFromPubkeyHash(bytes32 pubkeyHash) external view returns (IEtherFiNode);
    //function etherFiNodeFromId(uint256 id) external view returns (address);

    function addressToWithdrawalCredentials(address addr) external pure returns (bytes memory);
    function etherfiNodeAddress(uint256 id) external view returns(address);
    function linkPubkeyToNode(bytes calldata pubkey, address nodeAddress, uint256 legacyId) external;

    function eigenPodManager() external view returns (address);
    function delegationManager() external view returns (address);
    function stakingManager() external view returns (address);

    // eigenlayer interactions
    function getEigenPod(uint256 id) external view returns (address);
    function startCheckpoint(uint256 id) external;
    function setProofSubmitter(uint256 id, address _newProofSubmitter) external;

    // call forwarding
    function updateAllowedForwardedExternalCalls(bytes4 selector, address target, bool allowed) external;
    function updateAllowedForwardedEigenpodCalls(bytes4 selector, bool allowed) external;
    function forwardEigenPodCall(uint256[] calldata ids, bytes[] calldata data) external returns (bytes memory);
    function forwardExternalCall(address[] calldata nodes, bytes[] calldata data, address target) external returns (bytes[] memory returnData);

    // protocol
    function pauseContract() external;
    function unPauseContract() external;


}
