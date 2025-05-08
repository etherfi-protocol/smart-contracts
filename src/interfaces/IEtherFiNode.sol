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
