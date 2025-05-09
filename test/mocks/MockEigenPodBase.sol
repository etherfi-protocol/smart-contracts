// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.9;

import "../../src/eigenlayer-interfaces/IEigenPod.sol";
import "../../src/eigenlayer-interfaces/ISemVerMixin.sol";

contract MockEigenPodBase is IEigenPod {
    constructor() {}

    function version() external virtual view returns (string memory) {}

    function nonBeaconChainETHBalanceWei() external virtual view returns(uint256) {}

    /// @notice the amount of execution layer ETH in this contract that is staked in EigenLayer (i.e. withdrawn from beaconchain but not EigenLayer), 
    function withdrawableRestakedExecutionLayerGwei() external virtual view returns(uint64) {}

    /// @notice Used to initialize the pointers to contracts crucial to the pod's functionality, in beacon proxy construction from EigenPodManager
    function initialize(address owner) external virtual {}

    /// @notice Called by EigenPodManager when the owner wants to create another ETH validator.
    function stake(bytes calldata pubkey, bytes calldata signature, bytes32 depositDataRoot) external virtual payable {}

    /**
     * @notice Transfers `amountWei` in ether from this contract to the specified `recipient` address
     * @notice Called by EigenPodManager to withdrawBeaconChainETH that has been added to the EigenPod's balance due to a withdrawal from the beacon chain.
     * @dev Called during withdrawal or slashing.
     * @dev Note that this function is marked as non-reentrant to prevent the recipient calling back into it
     */
    function withdrawRestakedBeaconChainETH(address recipient, uint256 amount) external virtual {}

    /// @notice The single EigenPodManager for EigenLayer
    function eigenPodManager() external virtual view returns (IEigenPodManager) {}

    /// @notice The owner of this EigenPod
    function podOwner() external virtual view returns (address) {}

    /// @notice an indicator of whether or not the podOwner has ever "fully restaked" by successfully calling `verifyCorrectWithdrawalCredentials`.
    function hasRestaked() external virtual view returns (bool) {}

    /// @notice block timestamp of the most recent withdrawal
    function mostRecentWithdrawalTimestamp() external virtual view returns (uint64) {}

    /// @notice Returns the validatorInfo struct for the provided pubkeyHash
    function validatorPubkeyHashToInfo(bytes32 validatorPubkeyHash) external virtual view returns (ValidatorInfo memory) {}

    /// @notice This returns the status of a given validator
    function validatorStatus(bytes32 pubkeyHash) external virtual view returns(VALIDATOR_STATUS) {}

    /// @notice Number of validators with proven withdrawal credentials, who do not have proven full withdrawals
    function activeValidatorCount() external virtual view returns (uint256) {}

    /// @notice The timestamp of the last checkpoint finalized
    function lastCheckpointTimestamp() external virtual view returns (uint64) {}

    /// @notice The timestamp of the currently-active checkpoint. Will be 0 if there is not active checkpoint
    function currentCheckpointTimestamp() external virtual view returns (uint64) {}

    /// @notice Returns the currently-active checkpoint
    function currentCheckpoint() external virtual view returns (Checkpoint memory) {}

    function checkpointBalanceExitedGwei(uint64) external virtual view returns (uint64) {}

    function startCheckpoint(bool revertIfNoBalance) external virtual {}

    function verifyCheckpointProofs(
        BeaconChainProofs.BalanceContainerProof calldata balanceContainerProof,
        BeaconChainProofs.BalanceProof[] calldata proofs
    ) external virtual {}

    function verifyStaleBalance(
        uint64 beaconTimestamp,
        BeaconChainProofs.StateRootProof calldata stateRootProof,
        BeaconChainProofs.ValidatorProof calldata proof
    ) external virtual {}

    function verifyWithdrawalCredentials(
        uint64 oracleTimestamp,
        BeaconChainProofs.StateRootProof calldata stateRootProof,
        uint40[] calldata validatorIndices,
        bytes[] calldata withdrawalCredentialProofs,
        bytes32[][] calldata validatorFields
    ) external virtual {}

    /// @notice Called by the pod owner to withdraw the balance of the pod when `hasRestaked` is set to false
    function activateRestaking() external virtual {}

    /// @notice Called by the pod owner to withdraw the balance of the pod when `hasRestaked` is set to false
    function withdrawBeforeRestaking() external virtual {}

    /// @notice Called by the pod owner to withdraw the nonBeaconChainETHBalanceWei
    function withdrawNonBeaconChainETHBalanceWei(address recipient, uint256 amountToWithdraw) external virtual {}

    /// @notice called by owner of a pod to remove any ERC20s deposited in the pod
    function recoverTokens(IERC20[] memory tokenList, uint256[] memory amountsToWithdraw, address recipient) external virtual {}

    function setProofSubmitter(address newProofSubmitter) external virtual {}

    function proofSubmitter() external virtual view returns (address) {}

    function validatorStatus(bytes calldata pubkey) external virtual view returns (VALIDATOR_STATUS){}
    function validatorPubkeyToInfo(bytes calldata validatorPubkey) external virtual view returns (ValidatorInfo memory){}

    /// @notice Query the 4788 oracle to get the parent block root of the slot with the given `timestamp`
    /// @param timestamp of the block for which the parent block root will be returned. MUST correspond
    /// to an existing slot within the last 24 hours. If the slot at `timestamp` was skipped, this method
    /// will revert.
    function getParentBlockRoot(uint64 timestamp) external virtual view returns (bytes32) {}
}
