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

    //--------------------------------------------------------------------------
    //-----------------------------  Errors  -----------------------------------
    //--------------------------------------------------------------------------

    error TransferFailed();
    error IncorrectRole();

}
