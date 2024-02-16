// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./IEtherFiNodesManager.sol";

interface IEtherFiNode {
    // State Transition Diagram for StateMachine contract:
    //
    //      NOT_INITIALIZED
    //              |
    //      READY_FOR_DEPOSIT
    //              ↓
    //      STAKE_DEPOSITED
    //           /      \
    //          /        \
    //         ↓          ↓
    //         LIVE    CANCELLED
    //         |  \ \ 
    //         |   \ \
    //         |   ↓  --> EVICTED
    //         |  BEING_SLASHED
    //         |    /
    //         |   /
    //         ↓  ↓
    //         EXITED
    //           |
    //           ↓
    //      FULLY_WITHDRAWN
    // Transitions are only allowed as directed above.
    // For instance, a transition from STAKE_DEPOSITED to either LIVE or CANCELLED is allowed,
    // but a transition from STAKE_DEPOSITED to NOT_INITIALIZED, BEING_SLASHED, or EXITED is not.
    //
    // All phase transitions should be made through the setPhase function,
    // which validates transitions based on these rules.
    //
    // Fully_WITHDRAWN or CANCELLED nodes can be recycled via resetWithdrawalSafe()
    enum VALIDATOR_PHASE {
        NOT_INITIALIZED,
        STAKE_DEPOSITED,
        LIVE,
        EXITED,
        FULLY_WITHDRAWN,
        CANCELLED,
        BEING_SLASHED,
        EVICTED,
        WAITING_FOR_APPROVAL,
        READY_FOR_DEPOSIT
    }

    // VIEW functions
    function calculateTVL(uint256 _beaconBalance, uint256 _executionBalance, IEtherFiNodesManager.RewardsSplit memory _SRsplits, uint256 _scale) external view returns (uint256, uint256, uint256, uint256);
    function eigenPod() external view returns (address);
    function exitRequestTimestamp() external view returns (uint32);
    function exitTimestamp() external view returns (uint32);
    function getNonExitPenalty(uint32 _tNftExitRequestTimestamp, uint32 _bNftExitRequestTimestamp) external view returns (uint256);
    function getStakingRewardsPayouts(uint256 _beaconBalance, IEtherFiNodesManager.RewardsSplit memory _splits, uint256 _scale) external view returns (uint256, uint256, uint256, uint256);
    function ipfsHashForEncryptedValidatorKey() external view returns (string memory);
    function phase() external view returns (VALIDATOR_PHASE);
    function stakingStartTimestamp() external view returns (uint32);

    // Non-VIEW functions
    function claimQueuedWithdrawals(uint256 maxNumWithdrawals) external;
    function createEigenPod() external;
    function hasOutstandingEigenLayerWithdrawals() external view returns (bool);
    function isRestakingEnabled() external view returns (bool);
    function markExited(uint32 _exitTimestamp) external;
    function markBeingSlashed() external;
    function moveRewardsToManager(uint256 _amount) external;
    function queueRestakedWithdrawal() external;
    function recordStakingStart(bool _enableRestaking) external;
    function resetWithdrawalSafe() external;
    function setExitRequestTimestamp(uint32 _timestamp) external;
    function setIpfsHashForEncryptedValidatorKey(string calldata _ipfs) external;
    function setIsRestakingEnabled(bool _enabled) external;
    function setPhase(VALIDATOR_PHASE _phase) external;
    function splitBalanceInExecutionLayer() external view returns (uint256 _withdrawalSafe, uint256 _eigenPod, uint256 _delayedWithdrawalRouter);
    function totalBalanceInExecutionLayer() external view returns (uint256);
    function withdrawableBalanceInExecutionLayer() external view returns (uint256);

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


}
