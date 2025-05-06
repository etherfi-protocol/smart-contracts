// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IDelegationManager} from "../src/eigenlayer-interfaces/IDelegationManager.sol";
import {IEigenPodManager} from "../src/eigenlayer-interfaces/IEigenPodManager.sol";
import {IEigenPod} from "../src/eigenlayer-interfaces/IEigenPod.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";

import {IEtherFiNode} from "../src/interfaces/IEtherFiNode.sol";
import {IEtherFiNodesManager} from "../src/interfaces/IEtherFiNodesManager.sol";
import {IRoleRegistry} from "../src/interfaces/IRoleRegistry.sol";
import {ILiquidityPool} from "../src/interfaces/ILiquidityPool.sol";
import {LibCall} from "../lib/solady/src/utils/LibCall.sol";

contract EtherFiNode is IEtherFiNode {

    ILiquidityPool public immutable liquidityPool;
    IEtherFiNodesManager public immutable etherFiNodesManager;
    IRoleRegistry public immutable roleRegistry;

    // eigenlayer core contracts
    IEigenPodManager public immutable eigenPodManager;
    IDelegationManager public immutable delegationManager;
    uint32 public constant EIGENLAYER_WITHDRAWAL_DELAY_BLOCKS = 100800;

    error TransferFailed();
    error IncorrectRole();

    constructor(address _liquidityPool, address _etherFiNodesManager, address _eigenPodManager, address _delegationManager) {
        eigenPodManager = IEigenPodManager(_eigenPodManager);
        delegationManager = IDelegationManager(_delegationManager);
        liquidityPool = ILiquidityPool(_liquidityPool);
        etherFiNodesManager = IEtherFiNodesManager(_etherFiNodesManager);

        // TODO(dave): add to constructor
        roleRegistry = IRoleRegistry(0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ROLES  ---------------------------------------
    //--------------------------------------------------------------------------------------

    bytes32 public constant ETHERFI_NODE_ADMIN_ROLE = keccak256("ETHERFI_NODE_ADMIN_ROLE");

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
    function createEigenPod() external onlyAdmin returns (address) {
        return eigenPodManager.createPod();
    }

    /// @dev specify another address with permissions to submit checkpoint and withdrawal credential proofs
    function setProofSubmitter(address _newProofSubmitter) external onlyAdmin {
        getEigenPod().setProofSubmitter(_newProofSubmitter);
    }

    /// @dev start an eigenlayer checkpoint proof. Once a checkpoint is started, it must be completed
    function startCheckpoint() external onlyAdmin {
        bool revertIfNoBalance = true; // protect from wasting gas if checkpoint will not increase shares
        getEigenPod().startCheckpoint(revertIfNoBalance);
    }

    /// @dev queue a withdrawal from eigenlayer
    function queueWithdrawal(IDelegationManager.QueuedWithdrawalParams calldata params) external onlyAdmin returns (bytes32 withdrawalRoot) {
        // Implemented this way because we almost never queue multiple withdrawals at the same time
        // so I chose to improve our internal interface and simplify testing
        IDelegationManager.QueuedWithdrawalParams[] memory paramsArray = new IDelegationManager.QueuedWithdrawalParams[](1);
        paramsArray[0] = params;
        return delegationManager.queueWithdrawals(paramsArray)[0];
    }

    /// @dev completes all queued withdrawals that are currently claimable
    function completeQueuedWithdrawals(bool receiveAsTokens) external onlyAdmin {

        // because we are just dealing with beacon eth we don't need to populate the tokens[] array
        IERC20[] memory tokens;

        (IDelegationManager.Withdrawal[] memory queuedWithdrawals, ) = delegationManager.getQueuedWithdrawals(address(this));
        for (uint256 i = 0; i < queuedWithdrawals.length; i++) {

            // skip this withdrawal if not enough time has passed
            uint32 slashableUntil = queuedWithdrawals[i].startBlock + EIGENLAYER_WITHDRAWAL_DELAY_BLOCKS;
            if (uint32(block.number) > slashableUntil) continue;

            delegationManager.completeQueuedWithdrawal(queuedWithdrawals[i], tokens, receiveAsTokens);
        }

        // if there are available rewards, forward them to the liquidityPool
        if (address(this).balance > 0) {
            (bool sent, ) = payable(address(liquidityPool)).call{value: address(this).balance, gas: 20000}("");
            if (!sent) revert TransferFailed();
        }
    }

    // @notice transfers any funds held by the node to the liquidity pool.
    // @dev under normal operations it is not expected for eth to accumulate in the nodes,
    //      this is just to handle any exceptional cases such as someone sending directly to the node.
    function sweepFunds() external onlyAdmin {
            (bool sent, ) = payable(address(liquidityPool)).call{value: address(this).balance, gas: 20000}("");
            if (!sent) revert TransferFailed();
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------- CALL FORWARDING  ------------------------------------
    //--------------------------------------------------------------------------------------

    function forwardEigenPodCall(bytes calldata data) external onlyAdmin returns (bytes memory) {
        // callContract will revert if targeting an EOA so it is safe if getEigenPod() returns the zero address
        return LibCall.callContract(address(getEigenPod()), 0, data);
    }

    function forwardExternalCall(address to, bytes calldata data) external onlyAdmin returns (bytes memory) {
        return LibCall.callContract(to, 0, data);
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier onlyAdmin() {
        if (!roleRegistry.hasRole(ETHERFI_NODE_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        _;
    }

}
