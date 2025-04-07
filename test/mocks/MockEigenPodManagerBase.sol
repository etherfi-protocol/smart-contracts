// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "../../src/eigenlayer-interfaces/IEigenPodManager.sol";
import "./MockShareManagerBase.sol";
import "./MockEigenPod.sol";
import "./MockPausableBase.sol";


// IEigenPodManager but all functions are virtual
contract MockEigenPodManagerBase is IEigenPodManager, MockShareManagerBase, MockPausableBase {

    function version() external virtual view returns (string memory) {}

     /**
     * @notice Creates an EigenPod for the sender.
     * @dev Function will revert if the `msg.sender` already has an EigenPod.
     * @dev Returns EigenPod address
     */
    function createPod() external virtual returns (address) {}

    /**
     * @notice Stakes for a new beacon chain validator on the sender's EigenPod.
     * Also creates an EigenPod for the sender if they don't have one already.
     * @param pubkey The 48 bytes public key of the beacon chain validator.
     * @param signature The validator's signature of the deposit data.
     * @param depositDataRoot The root/hash of the deposit data for the validator's deposit.
     */
    function stake(bytes calldata pubkey, bytes calldata signature, bytes32 depositDataRoot) external virtual payable {}

    /**
     * @notice Adds any positive share delta to the pod owner's deposit shares, and delegates them to the pod
     * owner's operator (if applicable). A negative share delta does NOT impact the pod owner's deposit shares,
     * but will reduce their beacon chain slashing factor and delegated shares accordingly.
     * @param podOwner is the pod owner whose balance is being updated.
     * @param prevRestakedBalanceWei is the total amount restaked through the pod before the balance update, including
     * any amount currently in the withdrawal queue.
     * @param balanceDeltaWei is the amount the balance changed
     * @dev Callable only by the podOwner's EigenPod contract.
     * @dev Reverts if `sharesDelta` is not a whole Gwei amount
     */
    function recordBeaconChainETHBalanceUpdate(
        address podOwner,
        uint256 prevRestakedBalanceWei,
        int256 balanceDeltaWei
    ) external virtual {}

    /// @notice Returns the address of the `podOwner`'s EigenPod if it has been deployed.
    function ownerToPod(
        address podOwner
    ) external virtual view returns (IEigenPod) {}

    /// @notice Returns the address of the `podOwner`'s EigenPod (whether it is deployed yet or not).
    function getPod(
        address podOwner
    ) external virtual view returns (IEigenPod) {}

    /// @notice The ETH2 Deposit Contract
    function ethPOS() external virtual view returns (IETHPOSDeposit) {}

    /// @notice Beacon proxy to which the EigenPods point
    function eigenPodBeacon() external virtual view returns (IBeacon) {}

    /// @notice Returns 'true' if the `podOwner` has created an EigenPod, and 'false' otherwise.
    function hasPod(
        address podOwner
    ) external virtual view returns (bool) {}

    /// @notice Returns the number of EigenPods that have been created
    function numPods() external virtual view returns (uint256) {}

    /**
     * @notice Mapping from Pod owner owner to the number of shares they have in the virtual beacon chain ETH strategy.
     * @dev The share amount can become negative. This is necessary to accommodate the fact that a pod owner's virtual beacon chain ETH shares can
     * decrease between the pod owner queuing and completing a withdrawal.
     * When the pod owner's shares would otherwise increase, this "deficit" is decreased first _instead_.
     * Likewise, when a withdrawal is completed, this "deficit" is decreased and the withdrawal amount is decreased {} We can think of this
     * as the withdrawal "paying off the deficit".
     */
    function podOwnerDepositShares(
        address podOwner
    ) external virtual view returns (int256) {}

    /// @notice returns canonical, virtual beaconChainETH strategy
    function beaconChainETHStrategy() external virtual view returns (IStrategy) {}

    /**
     * @notice Returns the historical sum of proportional balance decreases a pod owner has experienced when
     * updating their pod's balance.
     */
    function beaconChainSlashingFactor(
        address staker
    ) external virtual view returns (uint64) {}

    /// @notice Returns the accumulated amount of beacon chain ETH Strategy shares
    function burnableETHShares() external virtual view returns (uint256) {}

    /// @notice Sets the address that can set proof timestamps
    function setProofTimestampSetter(
        address newProofTimestampSetter
    ) external {}

    /// @notice Sets the Pectra fork timestamp, only callable by `proofTimestampSetter`
    function setPectraForkTimestamp(
        uint64 timestamp
    ) external {}

    /// @notice Returns the timestamp of the Pectra hard fork
    /// @dev Specifically, this returns the timestamp of the first non-missed slot at or after the Pectra hard fork
    function pectraForkTimestamp() external view returns (uint64) {}


}
