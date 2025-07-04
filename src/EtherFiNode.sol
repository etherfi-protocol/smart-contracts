// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IEtherFiNode} from "../src/interfaces/IEtherFiNode.sol";
import {IEtherFiNodesManager} from "../src/interfaces/IEtherFiNodesManager.sol";
import {IRoleRegistry} from "../src/interfaces/IRoleRegistry.sol";
import {ILiquidityPool} from "../src/interfaces/ILiquidityPool.sol";

import {IDelegationManager} from "../src/eigenlayer-interfaces/IDelegationManager.sol";
import {IDelegationManagerTypes} from "../src/eigenlayer-interfaces/IDelegationManager.sol";
import {IEigenPodManager} from "../src/eigenlayer-interfaces/IEigenPodManager.sol";
import {IEigenPod} from "../src/eigenlayer-interfaces/IEigenPod.sol";
import {IStrategy} from "../src/eigenlayer-interfaces/IStrategy.sol";
import {BeaconChainProofs} from "../src/eigenlayer-libraries/BeaconChainProofs.sol";

import {IERC20} from "../lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {LibCall} from "../lib/solady/src/utils/LibCall.sol";

contract EtherFiNode is IEtherFiNode {

    ILiquidityPool public immutable liquidityPool;
    IEtherFiNodesManager public immutable etherFiNodesManager;
    IRoleRegistry public immutable roleRegistry;

    // eigenlayer core contracts
    IEigenPodManager public immutable eigenPodManager;
    IDelegationManager public immutable delegationManager;
    uint32 public constant EIGENLAYER_WITHDRAWAL_DELAY_BLOCKS = 100800;

    //---------------------------------------------------------------------------
    //-----------------------------  Storage  -----------------------------------
    //---------------------------------------------------------------------------

    LegacyNodeState legacyState; // all legacy state in this contract has been deprecated

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ROLES  ---------------------------------------
    //--------------------------------------------------------------------------------------

    bytes32 public constant ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE = keccak256("ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE");
    bytes32 public constant ETHERFI_NODE_CALL_FORWARDER_ROLE = keccak256("ETHERFI_NODE_CALL_FORWARDER_ROLE");

    //-------------------------------------------------------------------------
    //-----------------------------  Admin  -----------------------------------
    //-------------------------------------------------------------------------

    constructor(address _liquidityPool, address _etherFiNodesManager, address _eigenPodManager, address _delegationManager, address _roleRegistry) {
        liquidityPool = ILiquidityPool(_liquidityPool);
        etherFiNodesManager = IEtherFiNodesManager(_etherFiNodesManager);
        eigenPodManager = IEigenPodManager(_eigenPodManager);
        delegationManager = IDelegationManager(_delegationManager);
        roleRegistry = IRoleRegistry(_roleRegistry);
    }

    fallback() external payable {}

    //--------------------------------------------------------------------------------------
    //---------------------------- Eigenlayer Interactions  --------------------------------
    //--------------------------------------------------------------------------------------

    /// @dev returns the associated eigenpod or the zero address if it is not created yet.
    ///      `EigenPodManager.getPod()` is not used because it returns the deterministic address regardless of if it exists
    function getEigenPod() public view returns (IEigenPod) {
        return eigenPodManager.ownerToPod(address(this));
    }

    /// @dev creates a new eigenpod and returns its address. Reverts if a pod already exists for this node.
    ///      This address is deterministic and you can pre-compute it if necessary.
    function createEigenPod() external onlyEigenlayerAdmin returns (address) {
        return eigenPodManager.createPod();
    }

    /// @dev specify another address with permissions to submit checkpoint and withdrawal credential proofs
    function setProofSubmitter(address _newProofSubmitter) external onlyEigenlayerAdmin {
        getEigenPod().setProofSubmitter(_newProofSubmitter);
    }

    /// @dev start an eigenlayer checkpoint proof. Once a checkpoint is started, it must be completed
    function startCheckpoint() external onlyEigenlayerAdmin {
        bool revertIfNoBalance = true; // protect from wasting gas if checkpoint will not increase shares
        getEigenPod().startCheckpoint(revertIfNoBalance);
    }

    /// @dev submit a subset of proofs for the currently active checkpoint
    function verifyCheckpointProofs(BeaconChainProofs.BalanceContainerProof calldata balanceContainerProof, BeaconChainProofs.BalanceProof[] calldata proofs) external onlyEigenlayerAdmin {
        getEigenPod().verifyCheckpointProofs(balanceContainerProof, proofs);
    }

    /// @dev convenience function to queue a beaconETH withdrawal from eigenlayer. You must wait EIGENLAYER_WITHDRAWAL_DELAY_BLOCKS before claiming.
    ///   It is fine to queue a withdrawal before validators have finished exiting on the beacon chain.
    function queueETHWithdrawal(uint256 amount) external onlyEigenlayerAdmin returns (bytes32 withdrawalRoot) {

        // beacon eth is always 1 to 1 with deposit shares
        uint256[] memory depositShares = new uint256[](1);
        depositShares[0] = amount;
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = IStrategy(address(0xbeaC0eeEeeeeEEeEeEEEEeeEEeEeeeEeeEEBEaC0));

        IDelegationManagerTypes.QueuedWithdrawalParams[] memory paramsArray = new IDelegationManagerTypes.QueuedWithdrawalParams[](1);
        paramsArray[0] = IDelegationManagerTypes.QueuedWithdrawalParams({
            strategies: strategies, // beacon eth
            depositShares: depositShares,
            __deprecated_withdrawer: address(this)
        });

        return delegationManager.queueWithdrawals(paramsArray)[0];
    }


    /// @dev completes all queued beaconETH withdrawals that are currently claimable.
    ///   Note that since the node is usually delegated to an operator,
    ///   most of the time this should be called with "receiveAsTokens" = true because
    ///   receiving shares while delegated will simply redelegate the shares.
    function completeQueuedETHWithdrawals(bool receiveAsTokens) external onlyEigenlayerAdmin returns (uint256 balance) {

        // because we are just dealing with beacon eth we don't need to populate the tokens[] array
        IERC20[] memory tokens = new IERC20[](1);

        (IDelegationManager.Withdrawal[] memory queuedWithdrawals, ) = delegationManager.getQueuedWithdrawals(address(this));
        for (uint256 i = 0; i < queuedWithdrawals.length; i++) {

            // skip this withdrawal if not enough time has passed or if it is not a simple beaconETH withdrawal
            uint32 slashableUntil = queuedWithdrawals[i].startBlock + EIGENLAYER_WITHDRAWAL_DELAY_BLOCKS;
            if (uint32(block.number) <= slashableUntil) continue;
            if (queuedWithdrawals[i].strategies.length != 1) continue;
            if (queuedWithdrawals[i].strategies[0] != IStrategy(address(0xbeaC0eeEeeeeEEeEeEEEEeeEEeEeeeEeeEEBEaC0))) continue;

            delegationManager.completeQueuedWithdrawal(queuedWithdrawals[i], tokens, receiveAsTokens);
        }

        // if there are available rewards, forward them to the liquidityPool
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool sent, ) = payable(address(liquidityPool)).call{value: balance, gas: 20000}("");
            if (!sent) revert TransferFailed();
        }
        return balance;
    }

    /// @dev queue a withdrawal from eigenlayer. You must wait EIGENLAYER_WITHDRAWAL_DELAY_BLOCKS before claiming.
    ///   For the general case of queuing a beaconETH withdrawal you can use queueETHWithdrawal instead.
    function queueWithdrawals(IDelegationManager.QueuedWithdrawalParams[] calldata params) external onlyEigenlayerAdmin returns (bytes32[] memory withdrawalRoots) {
        return delegationManager.queueWithdrawals(params);
    }

    /// @dev complete an arbitrary withdrawal from eigenlayer.
    ///   For the general case of claiming beaconETH withdrawals you can use completeQueuedETHWithdrawals instead.
    function completeQueuedWithdrawals(
        IDelegationManager.Withdrawal[] calldata withdrawals,
        IERC20[][] calldata tokens,
        bool[] calldata receiveAsTokens
    ) external onlyEigenlayerAdmin {
        delegationManager.completeQueuedWithdrawals(withdrawals, tokens, receiveAsTokens);
    }

    // @notice transfers any funds held by the node to the liquidity pool.
    // @dev under normal operations it is not expected for eth to accumulate in the nodes,
    //    this is just to handle any exceptional cases such as someone sending directly to the node.
    function sweepFunds() external onlyEigenlayerAdmin returns (uint256 balance) {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool sent, ) = payable(address(liquidityPool)).call{value: balance, gas: 20000}("");
            if (!sent) revert TransferFailed();
        }
        return balance;
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------- CALL FORWARDING  ------------------------------------
    //--------------------------------------------------------------------------------------

    function forwardEigenPodCall(bytes calldata data) external onlyCallForwarder returns (bytes memory) {

        // validate the call
        if (data.length < 4) revert InvalidForwardedCall();
        bytes4 selector = bytes4(data[:4]);
        if (!etherFiNodesManager.allowedForwardedEigenpodCalls(selector)) revert ForwardedCallNotAllowed();

        // callContract will revert if targeting an EOA so it is safe if getEigenPod() returns the zero address
        return LibCall.callContract(address(getEigenPod()), 0, data);
    }

    function forwardExternalCall(address to, bytes calldata data) external onlyCallForwarder returns (bytes memory) {

        // validate the call
        if (data.length < 4) revert InvalidForwardedCall();
        bytes4 selector = bytes4(data[:4]);
        if (!etherFiNodesManager.allowedForwardedExternalCalls(selector, to)) revert ForwardedCallNotAllowed();

        return LibCall.callContract(to, 0, data);
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier onlyEigenlayerAdmin() {
        if (!roleRegistry.hasRole(ETHERFI_NODE_EIGENLAYER_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        _;
    }

    modifier onlyCallForwarder() {
        if (!roleRegistry.hasRole(ETHERFI_NODE_CALL_FORWARDER_ROLE, msg.sender)) revert IncorrectRole();
        _;
    }

}
