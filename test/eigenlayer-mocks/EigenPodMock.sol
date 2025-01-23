// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.9;

import "forge-std/Test.sol";
import "../../src/eigenlayer-interfaces/IEigenPod.sol";

contract EigenPodMock is IEigenPod, Test {

    uint256 internal mock_nonBeaconChainETHBalanceWEI;
    function mock_set_nonBeaconChainETHBalanceWEI(uint256 balance) external { mock_nonBeaconChainETHBalanceWEI = balance; }
    function nonBeaconChainETHBalanceWei() external view returns(uint256) { return mock_nonBeaconChainETHBalanceWEI; }

    /// @notice the amount of execution layer ETH in this contract that is staked in EigenLayer (i.e. withdrawn from beaconchain but not EigenLayer), 
    uint64 internal mock_withdrawableRestakedExecutionLayerGwei;
    function mock_set_withdrawableRestakedExecutionLayerGwei(uint64 val) external { mock_withdrawableRestakedExecutionLayerGwei = val; }
    function withdrawableRestakedExecutionLayerGwei() external view returns(uint64) { return mock_withdrawableRestakedExecutionLayerGwei; }

    /// @notice Used to initialize the pointers to contracts crucial to the pod's functionality, in beacon proxy construction from EigenPodManager
    function initialize(address owner) external {}

    /// @notice Called by EigenPodManager when the owner wants to create another ETH validator.
    function stake(bytes calldata pubkey, bytes calldata signature, bytes32 depositDataRoot) external payable {}

    /**
     * @notice Transfers `amountWei` in ether from this contract to the specified `recipient` address
     * @notice Called by EigenPodManager to withdrawBeaconChainETH that has been added to the EigenPod's balance due to a withdrawal from the beacon chain.
     * @dev Called during withdrawal or slashing.
     * @dev Note that this function is marked as non-reentrant to prevent the recipient calling back into it
     */
    function withdrawRestakedBeaconChainETH(address recipient, uint256 amount) external {}

    /// @notice The single EigenPodManager for EigenLayer
    function eigenPodManager() external view returns (IEigenPodManager) {}

    /// @notice The owner of this EigenPod
    address internal mock_podOwner;
    function mock_set_podOWner(address owner) external { mock_podOwner = owner; }
    function podOwner() external view returns (address) { return mock_podOwner; }

    /// DEPRECATED
    /// @notice an indicator of whether or not the podOwner has ever "fully restaked" by successfully calling `verifyCorrectWithdrawalCredentials`.
    function hasRestaked() external view returns (bool) {}

    /// DEPRECATED
    /// @notice block timestamp of the most recent withdrawal
    function mostRecentWithdrawalTimestamp() external view returns (uint64) {}

    /// @notice Returns the validatorInfo struct for the provided pubkeyHash
    mapping(bytes32 => ValidatorInfo) internal mock_validatorPubkeyHashToInfo;
    function mock_set_validatorPubkeyHashToInfo(bytes32 hash, ValidatorInfo memory info) external { mock_validatorPubkeyHashToInfo[hash] = info; }
    function validatorPubkeyHashToInfo(bytes32 validatorPubkeyHash) external view returns (ValidatorInfo memory) { return mock_validatorPubkeyHashToInfo[validatorPubkeyHash]; }

    /// @notice This returns the status of a given validator
    mapping(bytes32 => VALIDATOR_STATUS) internal mock_validatorStatus;
    function mock_set_validatorStatus(bytes32 hash, VALIDATOR_STATUS status) external { mock_validatorStatus[hash] = status; }
    function validatorStatus(bytes32 pubkeyHash) external view returns(VALIDATOR_STATUS) { return mock_validatorStatus[pubkeyHash]; }

    /// @notice Number of validators with proven withdrawal credentials, who do not have proven full withdrawals
    uint256 internal mock_activeValidatorCount;
    function mock_set_activeValidatorCount(uint256 count) external { mock_activeValidatorCount = count; }
    function activeValidatorCount() external view returns (uint256) { return mock_activeValidatorCount; }

    function checkpointBalanceExitedGwei(uint64) external view returns (uint64) {}

    function verifyStaleBalance(
        uint64 beaconTimestamp,
        BeaconChainProofs.StateRootProof calldata stateRootProof,
        BeaconChainProofs.ValidatorProof calldata proof
    ) external {}

    /// @notice Called by the pod owner to withdraw the balance of the pod when `hasRestaked` is set to false
    function activateRestaking() external {}

    /// DEPRECATED
    /// @notice Called by the pod owner to withdraw the balance of the pod when `hasRestaked` is set to false
    function withdrawBeforeRestaking() external {}

    /// @notice Called by the pod owner to withdraw the nonBeaconChainETHBalanceWei
    function withdrawNonBeaconChainETHBalanceWei(address recipient, uint256 amountToWithdraw) external {}

    /// @notice called by owner of a pod to remove any ERC20s deposited in the pod
    function recoverTokens(IERC20[] memory tokenList, uint256[] memory amountsToWithdraw, address recipient) external {}

    function proofSubmitter() external view returns (address) {}

    function validatorStatus(bytes calldata pubkey) external view returns (VALIDATOR_STATUS){}
    function validatorPubkeyToInfo(bytes calldata validatorPubkey) external view returns (ValidatorInfo memory){}

    /// @notice Query the 4788 oracle to get the parent block root of the slot with the given `timestamp`
    /// @param timestamp of the block for which the parent block root will be returned. MUST correspond
    /// to an existing slot within the last 24 hours. If the slot at `timestamp` was skipped, this method
    /// will revert.
    function getParentBlockRoot(uint64 timestamp) external view returns (bytes32) {}
    function currentCheckpoint() external view returns (Checkpoint memory) {}
    function currentCheckpointTimestamp() external view returns (uint64) {}
    function lastCheckpointTimestamp() external view returns (uint64) {}

    function startCheckpoint(bool revertIfNoBalance) external {}
    function verifyCheckpointProofs(
        BeaconChainProofs.BalanceContainerProof calldata balanceContainerProof,
        BeaconChainProofs.BalanceProof[] calldata proofs
    ) external {}
    function setProofSubmitter(address newProofSubmitter) external {}


    function verifyBalanceUpdates(
        uint64 oracleTimestamp,
        uint40[] calldata validatorIndices,
        BeaconChainProofs.StateRootProof calldata stateRootProof,
        bytes[] calldata validatorFieldsProofs,
        bytes32[][] calldata validatorFields
    ) external {}
    
    function verifyWithdrawalCredentials(
        uint64 beaconTimestamp,
        BeaconChainProofs.StateRootProof calldata stateRootProof,
        uint40[] calldata validatorIndices,
        bytes[] calldata validatorFieldsProofs,
        bytes32[][] calldata validatorFields
    ) external {}

}
