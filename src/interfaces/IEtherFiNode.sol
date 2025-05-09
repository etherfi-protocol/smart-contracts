// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./IEtherFiNodesManager.sol";

import "../eigenlayer-interfaces/IDelegationManager.sol";
import "../eigenlayer-interfaces/IEigenPod.sol";

interface IEtherFiNode {

    // eigenlayer
    function createEigenPod() external returns (address);
    function getEigenPod() external view returns (IEigenPod);
    function startCheckpoint() external;
    function setProofSubmitter(address _newProofSubmitter) external;
    function queueWithdrawal(IDelegationManager.QueuedWithdrawalParams calldata params) external returns (bytes32 withdrawalRoot);
    function completeQueuedWithdrawals(bool receiveAsTokens) external;

    // call forwarding
    function forwardEigenPodCall(bytes memory data) external returns (bytes memory);
    function forwardExternalCall(address to, bytes memory data) external returns (bytes memory);

    struct LegacyNodeState {
        uint256[10] legacyPadding;
            /*
            ╭---------------------------------------------------+-----------------------------------+------+--------+-------+---------------------------------╮
            | Name                                              | Type                              | Slot | Offset | Bytes | Contract                        |
            +=================================================================================================================================================+
            | etherFiNodesManager                               | address                           | 0    | 0      | 20    | src/EtherFiNode.sol:EtherFiNode |
            |---------------------------------------------------+-----------------------------------+------+--------+-------+---------------------------------|
            | DEPRECATED_localRevenueIndex                      | uint256                           | 1    | 0      | 32    | src/EtherFiNode.sol:EtherFiNode |
            |---------------------------------------------------+-----------------------------------+------+--------+-------+---------------------------------|
            | DEPRECATED_vestedAuctionRewards                   | uint256                           | 2    | 0      | 32    | src/EtherFiNode.sol:EtherFiNode |
            |---------------------------------------------------+-----------------------------------+------+--------+-------+---------------------------------|
            | DEPRECATED_ipfsHashForEncryptedValidatorKey       | string                            | 3    | 0      | 32    | src/EtherFiNode.sol:EtherFiNode |
            |---------------------------------------------------+-----------------------------------+------+--------+-------+---------------------------------|
            | DEPRECATED_exitRequestTimestamp                   | uint32                            | 4    | 0      | 4     | src/EtherFiNode.sol:EtherFiNode |
            |---------------------------------------------------+-----------------------------------+------+--------+-------+---------------------------------|
            | DEPRECATED_exitTimestamp                          | uint32                            | 4    | 4      | 4     | src/EtherFiNode.sol:EtherFiNode |
            |---------------------------------------------------+-----------------------------------+------+--------+-------+---------------------------------|
            | DEPRECATED_stakingStartTimestamp                  | uint32                            | 4    | 8      | 4     | src/EtherFiNode.sol:EtherFiNode |
            |---------------------------------------------------+-----------------------------------+------+--------+-------+---------------------------------|
            | DEPRECATED_phase                                  | enum IEtherFiNode.VALIDATOR_PHASE | 4    | 12     | 1     | src/EtherFiNode.sol:EtherFiNode |
            |---------------------------------------------------+-----------------------------------+------+--------+-------+---------------------------------|
            | DEPRECATED_restakingObservedExitBlock             | uint32                            | 4    | 13     | 4     | src/EtherFiNode.sol:EtherFiNode |
            |---------------------------------------------------+-----------------------------------+------+--------+-------+---------------------------------|
            | eigenPod                                          | address                           | 5    | 0      | 20    | src/EtherFiNode.sol:EtherFiNode |
            |---------------------------------------------------+-----------------------------------+------+--------+-------+---------------------------------|
            | isRestakingEnabled                                | bool                              | 5    | 20     | 1     | src/EtherFiNode.sol:EtherFiNode |
            |---------------------------------------------------+-----------------------------------+------+--------+-------+---------------------------------|
            | version                                           | uint16                            | 5    | 21     | 2     | src/EtherFiNode.sol:EtherFiNode |
            |---------------------------------------------------+-----------------------------------+------+--------+-------+---------------------------------|
            | _numAssociatedValidators                          | uint16                            | 5    | 23     | 2     | src/EtherFiNode.sol:EtherFiNode |
            |---------------------------------------------------+-----------------------------------+------+--------+-------+---------------------------------|
            | numExitRequestsByTnft                             | uint16                            | 5    | 25     | 2     | src/EtherFiNode.sol:EtherFiNode |
            |---------------------------------------------------+-----------------------------------+------+--------+-------+---------------------------------|
            | numExitedValidators                               | uint16                            | 5    | 27     | 2     | src/EtherFiNode.sol:EtherFiNode |
            |---------------------------------------------------+-----------------------------------+------+--------+-------+---------------------------------|
            | associatedValidatorIndices                        | mapping(uint256 => uint256)       | 6    | 0      | 32    | src/EtherFiNode.sol:EtherFiNode |
            |---------------------------------------------------+-----------------------------------+------+--------+-------+---------------------------------|
            | associatedValidatorIds                            | uint256[]                         | 7    | 0      | 32    | src/EtherFiNode.sol:EtherFiNode |
            |---------------------------------------------------+-----------------------------------+------+--------+-------+---------------------------------|
            | DEPRECATED_pendingWithdrawalFromRestakingInGwei   | uint64                            | 8    | 0      | 8     | src/EtherFiNode.sol:EtherFiNode |
            |---------------------------------------------------+-----------------------------------+------+--------+-------+---------------------------------|
            | DEPRECATED_completedWithdrawalFromRestakingInGwei | uint64                            | 8    | 8      | 8     | src/EtherFiNode.sol:EtherFiNode |
            |---------------------------------------------------+-----------------------------------+------+--------+-------+---------------------------------|
            | DEPRECATED_restakingObservedExitBlocks            | mapping(uint256 => uint32)        | 9    | 0      | 32    | src/EtherFiNode.sol:EtherFiNode |
            ╰---------------------------------------------------+-----------------------------------+------+--------+-------+---------------------------------╯
        */
    }

    //---------------------------------------------------------------------------
    //-----------------------------  Events  -----------------------------------
    //---------------------------------------------------------------------------

    event PartialWithdrawal(uint256 indexed _validatorId, address indexed etherFiNode, uint256 toOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury);
    event FullWithdrawal(uint256 indexed _validatorId, address indexed etherFiNode, uint256 toOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury);
    event QueuedRestakingWithdrawal(uint256 indexed _validatorId, address indexed etherFiNode, bytes32[] withdrawalRoots);

    //--------------------------------------------------------------------------
    //-----------------------------  Errors  -----------------------------------
    //--------------------------------------------------------------------------

    error TransferFailed();
    error IncorrectRole();

}
