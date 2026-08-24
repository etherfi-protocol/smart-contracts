// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@etherfi/staking/interfaces/IEtherFiNodesManager.sol";

import "@etherfi/interfaces/eigenlayer-interfaces/IDelegationManager.sol";
import "@etherfi/interfaces/eigenlayer-interfaces/IEigenPod.sol";

interface IEtherFiNode {

    // eigenlayer
    function createEigenPod() external returns (address);
    function getEigenPod() external view returns (IEigenPod);
    function startCheckpoint() external;
    function setProofSubmitter(address newProofSubmitter) external;
    function verifyCheckpointProofs(BeaconChainProofs.BalanceContainerProof calldata balanceContainerProof, BeaconChainProofs.BalanceProof[] calldata proofs) external;
    function queueETHWithdrawal(uint256 amount) external returns (bytes32 withdrawalRoot);
    function completeQueuedETHWithdrawals(bool receiveAsTokens) external returns (uint256 balance);
    function queueWithdrawals(IDelegationManager.QueuedWithdrawalParams[] calldata params) external returns (bytes32[] memory withdrawalRoot);
    function completeQueuedWithdrawals(IDelegationManager.Withdrawal[] calldata withdrawals, IERC20[][] calldata tokens, bool[] calldata receiveAsTokens) external returns (uint256 balance);
    function sweepFunds() external returns (uint256 balance);
    function requestExecutionLayerTriggeredWithdrawal(IEigenPod.WithdrawalRequest[] calldata requests) external payable;
    function requestConsolidation(IEigenPod.ConsolidationRequest[] calldata requests) external payable;
    function getWithdrawalRequestFee() external view returns (uint256);
    function getConsolidationRequestFee() external view returns (uint256);
    function disablePod() external;
    function withdrawDisabledPodETH() external returns (uint256 balance);


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
    event FundsTransferred(address indexed recipient, uint256 amount);

    /// @dev The four events below are emitted only when this node is itself the validators'
    ///      withdrawal-credential target, meaning it has no EigenPod and calls the EIP-7002/7251
    ///      predeploys directly. Names and signatures match `IEigenPodEvents` exactly, so the
    ///      topics are identical to what an EigenPod writes and consumers that follow the
    ///      credential target address decode both without a second code path. A pod-backed node
    ///      emits nothing here because the pod already logs the request itself.

    /// @notice Emitted when a withdrawal request with amountGwei == 0 is accepted by the predeploy
    event ExitRequested(bytes32 indexed validatorPubkeyHash);

    /// @notice Emitted when a partial withdrawal request is accepted by the predeploy
    event WithdrawalRequested(bytes32 indexed validatorPubkeyHash, uint64 withdrawalAmountGwei);

    /// @notice Emitted when a consolidation request with source == target is accepted by the predeploy
    event SwitchToCompoundingRequested(bytes32 indexed validatorPubkeyHash);

    /// @notice Emitted when a consolidation request between two validators is accepted by the predeploy
    event ConsolidationRequested(bytes32 indexed sourcePubkeyHash, bytes32 indexed targetPubkeyHash);

    //--------------------------------------------------------------------------
    //-----------------------------  Errors  -----------------------------------
    //--------------------------------------------------------------------------

    error TransferFailed();
    error ForwardedCallNotAllowed();
    error InvalidForwardedCall();
    error InvalidCaller();
    error NoCompleteableWithdrawals();
    error FeeQueryFailed();
    error PredeployFailed();
    error NoEigenPod();

}
