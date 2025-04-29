// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

//import "../lib/eigenlayer-contracts/src/contracts/interfaces/IEigenPodManager.sol";
//import "../lib/eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";
import {IDelegationManager} from "../src/eigenlayer-interfaces/IDelegationManager.sol";
import {IEigenPodManager} from "../src/eigenlayer-interfaces/IEigenPodManager.sol";
import {IEigenPod} from "../src/eigenlayer-interfaces/IEigenPod.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";

//import {IPodOwner} from "../src/iEtherFiNode/IPodOwner.sol";
import {IEtherFiNode} from "../src/interfaces/IEtherFiNode.sol";
import {IEtherFiNodesManager} from "../src/interfaces/IEtherFiNodesManager.sol";
import {ILiquidityPool} from "../src/interfaces/ILiquidityPool.sol";
//import {IRewardsManager} from "../src/RewardsManager.sol";
import {LibCall} from "../lib/solady/src/utils/LibCall.sol";

contract EtherFiNode is IEtherFiNode {

    IEigenPodManager public immutable eigenPodManager;
    IDelegationManager public immutable delegationManager;
    ILiquidityPool public immutable liquidityPool;
    IEtherFiNodesManager public immutable etherFiNodesManager;

    constructor(address _eigenPodManager, address _delegationManager, address _liquidityPool, address _etherFiNodesManager) {
        eigenPodManager = IEigenPodManager(_eigenPodManager);
        delegationManager = IDelegationManager(_delegationManager);
        liquidityPool = ILiquidityPool(_liquidityPool);
        etherFiNodesManager = IEtherFiNodesManager(_etherFiNodesManager);
    }


    //--------------------------------------------------------------------------------------
    //---------------------------- Eigenlayer Interactions  --------------------------------
    //--------------------------------------------------------------------------------------

    /// @dev returns the associated eigenpod or the zero address if it is not created yet.
    ///      `EigenPodManager.getPod()` is not used because it returns the deterministic address regardless of if it exists
    function getEigenPod() public view returns (IEigenPod) {
        return eigenPodManager.ownerToPod(address(this));
    }

    function createEigenPod() external {
        eigenPodManager.createPod();
    }

    // TODO(dave): permissions
    function startCheckpoint() external {
        bool revertIfNoBalance = true; // protect from wasting gas if checkpoint will not increase shares
        getEigenPod().startCheckpoint(revertIfNoBalance);
    }

    // TODO(dave): permissions
    function setProofSubmitter(address _newProofSubmitter) external {
        getEigenPod().setProofSubmitter(_newProofSubmitter);
    }

    // TODO(dave): permissions
    function queueWithdrawal(IDelegationManager.QueuedWithdrawalParams calldata params) external returns (bytes32 withdrawalRoot) {
        // Implemented this way because we almost never queue multiple withdrawals at the same time
        // so I chose to improve our internal interface and simplify testing
        IDelegationManager.QueuedWithdrawalParams[] memory paramsArray = new IDelegationManager.QueuedWithdrawalParams[](1);
        paramsArray[0] = params;
        return delegationManager.queueWithdrawals(paramsArray)[0];
    }

    // TODO(dave): permissions
    /// @dev the latest slashing release adds eigenPodManager.getQueuedWithdrawals which allows us
    ///      to complete withdrawals without needing an external indexer to track the queued withdrawal params
    function completeQueuedWithdrawals(bool receiveAsTokens) external {

        // because we are just dealing with beacon eth we don't need to populate the tokens[] array
        IERC20[] memory tokens;

        //TODO: skip withdrawals that haven't had enough time pass yet
        (IDelegationManager.Withdrawal[] memory queuedWithdrawals, ) = delegationManager.getQueuedWithdrawals(address(this));
        for (uint256 i = 0; i < queuedWithdrawals.length; i++) {
            delegationManager.completeQueuedWithdrawal(queuedWithdrawals[i], tokens, receiveAsTokens);
        }

        // if there are available rewards, forward them to the rewardsManager
        if (address(this).balance > 0) {
            //rewardsManager.depositETHRewards{value: address(this).balance}();
        }
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------- CALL FORWARDING  ------------------------------------
    //--------------------------------------------------------------------------------------

    // TODO(dave): Permissions

    function callEigenPod(bytes calldata data) external returns (bytes memory) {
        // callContract will revert if targeting an EOA so it is safe if getEigenPod() returns the zero address
        return LibCall.callContract(address(getEigenPod()), 0, data);
    }

    function forwardExternalCall(address to, bytes calldata data) external returns (bytes memory) {
        return LibCall.callContract(to, 0, data);
    }

}
