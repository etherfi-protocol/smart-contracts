// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IEtherFiNode} from "@etherfi/staking/interfaces/IEtherFiNode.sol";
import {IEtherFiNodesManager} from "@etherfi/staking/interfaces/IEtherFiNodesManager.sol";
import {ILiquidityPool} from "@etherfi/core/interfaces/ILiquidityPool.sol";

import {IDelegationManager} from "@etherfi/eigenlayer-interfaces/IDelegationManager.sol";
import {IDelegationManagerTypes} from "@etherfi/eigenlayer-interfaces/IDelegationManager.sol";
import {IEigenPodManager} from "@etherfi/eigenlayer-interfaces/IEigenPodManager.sol";
import {IEigenPod} from "@etherfi/eigenlayer-interfaces/IEigenPod.sol";
import {IStrategy} from "@etherfi/eigenlayer-interfaces/IStrategy.sol";
import {BeaconChainProofs} from "@etherfi/eigenlayer-libraries/BeaconChainProofs.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {LibCall} from "solady/utils/LibCall.sol";

contract EtherFiNode is IEtherFiNode {
    //---------------------------------------------------------------------------
    //-----------------------------  Storage  -----------------------------------
    //---------------------------------------------------------------------------
    LegacyNodeState legacyState; // all legacy state in this contract has been deprecated

    //--------------------------------------------------------------------------------------
    //-----------------------------  IMMUTABLES  --------------------------------------------
    //--------------------------------------------------------------------------------------
    ILiquidityPool public immutable liquidityPool;
    IEtherFiNodesManager public immutable etherFiNodesManager;
    IEigenPodManager public immutable eigenPodManager;
    IDelegationManager public immutable delegationManager;

    //--------------------------------------------------------------------------------------
    //-----------------------------  CONSTANTS  --------------------------------------------
    //--------------------------------------------------------------------------------------
    uint32 public constant EIGENLAYER_WITHDRAWAL_DELAY_BLOCKS = 100800;
    address public constant BEACON_ETH_STRATEGY_ADDRESS = address(0xbeaC0eeEeeeeEEeEeEEEEeeEEeEeeeEeeEEBEaC0);
    /// @dev Suggested gas stipend for contract receiving ETH to perform a few
    /// storage reads and writes, but low enough to prevent griefing.
    uint256 internal constant GAS_STIPEND_NO_GRIEF = 100_000;

    //--------------------------------------------------------------------------------------
    //-----------------------------  CONSTRUCTOR  --------------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Constructor
     * @param _liquidityPool The address of the liquidity pool
     * @param _etherFiNodesManager The address of the etherFi nodes manager
     * @param _eigenPodManager The address of the eigenpod manager
     * @param _delegationManager The address of the delegation manager
     */
    constructor(address _liquidityPool, address _etherFiNodesManager, address _eigenPodManager, address _delegationManager) {
        liquidityPool = ILiquidityPool(_liquidityPool);
        etherFiNodesManager = IEtherFiNodesManager(_etherFiNodesManager);
        eigenPodManager = IEigenPodManager(_eigenPodManager);
        delegationManager = IDelegationManager(_delegationManager);
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------  FALLBACK  --------------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Fallback function to receive ETH
     * @dev using fallback instead of receive here as nodes are expected to receive ETH from flows with non-empty calldata
     */
    fallback() external payable {}

    //--------------------------------------------------------------------------------------
    //---------------------------- OPERATIONAL FUNCTIONS  ----------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Creates a new eigenpod and returns its address. Reverts if a pod already exists for this node.
     * @dev This address is deterministic and you can pre-compute it if necessary.
     * @dev Only the etherFi nodes manager can call this function
     * @return The address of the new eigenpod
     */
    function createEigenPod() external onlyEtherFiNodesManager returns (address) {
        return eigenPodManager.createPod();
    }

    /**
     * @notice Specifies another address with permissions to submit checkpoint and withdrawal credential proofs
     * @param _newProofSubmitter The address of the new proof submitter
     * @dev Only the etherFi nodes manager can call this function
     */
    function setProofSubmitter(address _newProofSubmitter) external onlyEtherFiNodesManager {
        getEigenPod().setProofSubmitter(_newProofSubmitter);
    }

    /**
     * @notice Starts an eigenlayer checkpoint proof. Once a checkpoint is started, it must be completed
     * @dev Only the etherFi nodes manager can call this function
     */
    function startCheckpoint() external onlyEtherFiNodesManager {
        bool revertIfNoBalance = true; // protect from wasting gas if checkpoint will not increase shares
        getEigenPod().startCheckpoint(revertIfNoBalance);
    }

    /**
     * @notice Submits a subset of proofs for the currently active checkpoint
     * @param balanceContainerProof The balance container proof
     * @param proofs The proofs to submit
     * @dev Only the etherFi nodes manager can call this function
     */
    function verifyCheckpointProofs(BeaconChainProofs.BalanceContainerProof calldata balanceContainerProof, BeaconChainProofs.BalanceProof[] calldata proofs) external onlyEtherFiNodesManager {
        getEigenPod().verifyCheckpointProofs(balanceContainerProof, proofs);
    }

    /**
     * @notice Transfers any funds held by the node to the liquidity pool.
     * @dev Under normal operations it is not expected for eth to accumulate in the nodes,
     *      this is just to handle any exceptional cases such as someone sending directly to the node.
     * @return balance The balance of the node
     */
    function sweepFunds() external onlyEtherFiNodesManager returns (uint256 balance) {
        return _sweepToLiquidityPool();
    }

    /**
     * @notice Requests an execution layer triggered withdrawal from eigenlayer.
     * @param requests The requests to request the withdrawal with
     * @dev Only the etherFi nodes manager can call this function
     */
    function requestExecutionLayerTriggeredWithdrawal(IEigenPod.WithdrawalRequest[] calldata requests) external payable onlyEtherFiNodesManager {
        getEigenPod().requestWithdrawal{value: msg.value}(requests);
    }

    /**
     * @notice Requests an execution layer triggered consolidation from eigenlayer.
     * @param requests The requests to request the consolidation with
     * @dev Only the etherFi nodes manager can call this function
     */
    function requestConsolidation(IEigenPod.ConsolidationRequest[] calldata requests) external payable onlyEtherFiNodesManager {
        getEigenPod().requestConsolidation{value: msg.value}(requests);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------- WITHDRAWAL FUNCTIONS  --------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Convenience function to queue a beaconETH withdrawal from eigenlayer.
     * @param amount The amount of beaconETH to withdraw
     * @dev You must wait EIGENLAYER_WITHDRAWAL_DELAY_BLOCKS before claiming.
     *      It is fine to queue a withdrawal before validators have finished exiting on the beacon chain.
     * @return withdrawalRoot The withdrawal root
     */
    function queueETHWithdrawal(uint256 amount) external onlyEtherFiNodesManager returns (bytes32 withdrawalRoot) {

        // beacon eth is always 1 to 1 with deposit shares
        uint256[] memory depositShares = new uint256[](1);
        depositShares[0] = amount;
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = IStrategy(BEACON_ETH_STRATEGY_ADDRESS);

        IDelegationManagerTypes.QueuedWithdrawalParams[] memory paramsArray = new IDelegationManagerTypes.QueuedWithdrawalParams[](1);
        paramsArray[0] = IDelegationManagerTypes.QueuedWithdrawalParams({
            strategies: strategies, // beacon eth
            depositShares: depositShares,
            __deprecated_withdrawer: address(this)
        });

        return delegationManager.queueWithdrawals(paramsArray)[0];
    }


    /**
     * @notice Completes all queued beaconETH withdrawals that are currently claimable.
     * @param receiveAsTokens Whether to receive the withdrawals as tokens
     * @dev Note that since the node is usually delegated to an operator,
     *      most of the time this should be called with "receiveAsTokens" = true because
     *      receiving shares while delegated will simply redelegate the shares.
     * @return balance The balance of the node
     */
    function completeQueuedETHWithdrawals(bool receiveAsTokens) external onlyEtherFiNodesManager returns (uint256 balance) {

        // because we are just dealing with beacon eth we don't need to populate the tokens[] array
        IERC20[] memory tokens = new IERC20[](1);

        bool anyWithdrawalsCompleted = false;
        (IDelegationManager.Withdrawal[] memory queuedWithdrawals, ) = delegationManager.getQueuedWithdrawals(address(this));
        for (uint256 i = 0; i < queuedWithdrawals.length; i++) {

            // skip this withdrawal if not enough time has passed or if it is not a simple beaconETH withdrawal
            uint32 slashableUntil = queuedWithdrawals[i].startBlock + EIGENLAYER_WITHDRAWAL_DELAY_BLOCKS;
            if (uint32(block.number) <= slashableUntil) continue;
            if (queuedWithdrawals[i].strategies.length != 1) continue;
            if (queuedWithdrawals[i].strategies[0] != IStrategy(BEACON_ETH_STRATEGY_ADDRESS)) continue;

            delegationManager.completeQueuedWithdrawal(queuedWithdrawals[i], tokens, receiveAsTokens);
            anyWithdrawalsCompleted = true;
        }
        if (!anyWithdrawalsCompleted) revert NoCompleteableWithdrawals(); // bad dev experience if function completes but nothing happened

        return _sweepToLiquidityPool();
    }

    /**
     * @notice Queues a withdrawal from eigenlayer.
     * @param params The parameters to queue the withdrawal with
     * @dev You must wait EIGENLAYER_WITHDRAWAL_DELAY_BLOCKS before claiming.
     *      For the general case of queuing a beaconETH withdrawal you can use queueETHWithdrawal instead.
     * @return withdrawalRoots The withdrawal roots
     */
    function queueWithdrawals(IDelegationManager.QueuedWithdrawalParams[] calldata params) external onlyEtherFiNodesManager returns (bytes32[] memory withdrawalRoots) {
        return delegationManager.queueWithdrawals(params);
    }

    /**
     * @notice Completes an arbitrary withdrawal from eigenlayer.
     * @param withdrawals The withdrawals to complete
     * @param tokens The tokens to complete the withdrawals with
     * @param receiveAsTokens Whether to receive the withdrawals as tokens
     * @dev For the general case of claiming beaconETH withdrawals you can use completeQueuedETHWithdrawals instead.
     *      Any ETH that lands on this node as a result of the completion is auto-swept to the liquidity pool;
     *      the swept amount is returned so the manager can emit FundsTransferred at the wrapper level too.
     * @return balance The balance of the node
     */
    function completeQueuedWithdrawals(
        IDelegationManager.Withdrawal[] calldata withdrawals,
        IERC20[][] calldata tokens,
        bool[] calldata receiveAsTokens
    ) external onlyEtherFiNodesManager returns (uint256 balance) {
        delegationManager.completeQueuedWithdrawals(withdrawals, tokens, receiveAsTokens);
        return _sweepToLiquidityPool();
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------- CALL FORWARDING  ------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Forwards a call to the eigenpod
     * @param data The data to forward
     * @dev Only the etherFi nodes manager can call this function
     * @return The result of the call
     */
    function forwardEigenPodCall(bytes calldata data) external onlyEtherFiNodesManager returns (bytes memory) {
        // callContract will revert if targeting an EOA so it is safe if getEigenPod() returns the zero address
        return LibCall.callContract(address(getEigenPod()), 0, data);
    }

    /**
     * @notice Forwards a call to an external contract
     * @param to The address of the external contract
     * @param data The data to forward
     * @dev Only the etherFi nodes manager can call this function
     * @return The result of the call
     */
    function forwardExternalCall(address to, bytes calldata data) external onlyEtherFiNodesManager returns (bytes memory) {
        return LibCall.callContract(to, 0, data);
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------  INTERNAL FUNCTIONS  -----------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Forwards the lesser of (node balance, liquidityPool.totalValueOutOfLp()) to the liquidity pool.
     * @dev Shared by sweepFunds and completeQueued*Withdrawals.
     * @return balance The balance of the node
     */
    function _sweepToLiquidityPool() private returns (uint256 balance) {
        uint256 contractBalance = address(this).balance;
        uint256 totalValueOutOfLp = liquidityPool.totalValueOutOfLp();
        balance = contractBalance < totalValueOutOfLp ? contractBalance : totalValueOutOfLp;
        if (balance > 0) {
            (bool sent, ) = payable(address(liquidityPool)).call{value: balance, gas: GAS_STIPEND_NO_GRIEF}("");
            if (!sent) revert TransferFailed();
            emit FundsTransferred(address(liquidityPool), balance);
        }
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------  GETTERS  --------------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Returns the associated eigenpod or the zero address if it is not created yet.
     * @dev `EigenPodManager.getPod()` is not used because it returns the deterministic address regardless of if it exists
     * @return The associated eigenpod
     */
    function getEigenPod() public view returns (IEigenPod) {
        return eigenPodManager.ownerToPod(address(this));
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Modifier to only allow the etherFi nodes manager to call a function
     * @dev Only the etherFi nodes manager can call this function
     */
    modifier onlyEtherFiNodesManager() {
        if (msg.sender != address(etherFiNodesManager)) revert InvalidCaller();
        _;
    }

}
