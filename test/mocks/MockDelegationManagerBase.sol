// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "src/eigenlayer-interfaces/IDelegationManager.sol";

import "../../src/eigenlayer-interfaces/IStrategy.sol";
import "../../src/eigenlayer-interfaces/IPauserRegistry.sol";
import "../../src/eigenlayer-interfaces/ISignatureUtilsMixin.sol";
import "../../src/eigenlayer-libraries/SlashingLib.sol";

// IDelegationManager but with all functions made virtual
contract MockDelegationManagerBase is IDelegationManager {

    /**
     * @dev Initializes the initial owner and paused status.
     */
    function initialize(address initialOwner, uint256 initialPausedStatus) external virtual {}

    function domainSeparator() external view returns (bytes32) {}

    function version() external view returns (string memory) {}

    /**
     * @notice Registers the caller as an operator in EigenLayer.
     * @param initDelegationApprover is an address that, if set, must provide a signature when stakers delegate
     * to an operator.
     * @param allocationDelay The delay before allocations take effect.
     * @param metadataURI is a URI for the operator's metadata, i.e. a link providing more details on the operator.
     *
     * @dev Once an operator is registered, they cannot 'deregister' as an operator, and they will forever be considered "delegated to themself".
     * @dev This function will revert if the caller is already delegated to an operator.
     * @dev Note that the `metadataURI` is *never stored * and is only emitted in the `OperatorMetadataURIUpdated` event
     */
    function registerAsOperator(
        address initDelegationApprover,
        uint32 allocationDelay,
        string calldata metadataURI
    ) external virtual {}

    /**
     * @notice Updates an operator's stored `delegationApprover`.
     * @param operator is the operator to update the delegationApprover for
     * @param newDelegationApprover is the new delegationApprover for the operator
     *
     * @dev The caller must have previously registered as an operator in EigenLayer.
     */
    function modifyOperatorDetails(address operator, address newDelegationApprover) external virtual {}

    /**
     * @notice Called by an operator to emit an `OperatorMetadataURIUpdated` event indicating the information has updated.
     * @param operator The operator to update metadata for
     * @param metadataURI The URI for metadata associated with an operator
     * @dev Note that the `metadataURI` is *never stored * and is only emitted in the `OperatorMetadataURIUpdated` event
     */
    function updateOperatorMetadataURI(address operator, string calldata metadataURI) external virtual {}

    /**
     * @notice Caller delegates their stake to an operator.
     * @param operator The account (`msg.sender`) is delegating its assets to for use in serving applications built on EigenLayer.
     * @param approverSignatureAndExpiry (optional) Verifies the operator approves of this delegation
     * @param approverSalt (optional) A unique single use value tied to an individual signature.
     * @dev The signature/salt are used ONLY if the operator has configured a delegationApprover.
     * If they have not, these params can be left empty.
     */
    function delegateTo(
        address operator,
        SignatureWithExpiry memory approverSignatureAndExpiry,
        bytes32 approverSalt
    ) external virtual {}

    /**
     * @notice Undelegates the staker from their operator and queues a withdrawal for all of their shares
     * @param staker The account to be undelegated
     * @return withdrawalRoots The roots of the newly queued withdrawals, if a withdrawal was queued. Returns
     * an empty array if none was queued.
     *
     * @dev Reverts if the `staker` is also an operator, since operators are not allowed to undelegate from themselves.
     * @dev Reverts if the caller is not the staker, nor the operator who the staker is delegated to, nor the operator's specified "delegationApprover"
     * @dev Reverts if the `staker` is not delegated to an operator
     */
    function undelegate(
        address staker
    ) external virtual returns (bytes32[] memory withdrawalRoots) {}

    /**
     * @notice Undelegates the staker from their current operator, and redelegates to `newOperator`
     * Queues a withdrawal for all of the staker's withdrawable shares. These shares will only be
     * delegated to `newOperator` AFTER the withdrawal is completed.
     * @dev This method acts like a call to `undelegate`, then `delegateTo`
     * @param newOperator the new operator that will be delegated all assets
     * @dev NOTE: the following 2 params are ONLY checked if `newOperator` has a `delegationApprover`.
     * If not, they can be left empty.
     * @param newOperatorApproverSig A signature from the operator's `delegationApprover`
     * @param approverSalt A unique single use value tied to the approver's signature
     */
    function redelegate(
        address newOperator,
        SignatureWithExpiry memory newOperatorApproverSig,
        bytes32 approverSalt
    ) external virtual returns (bytes32[] memory withdrawalRoots) {}

    /**
     * @notice Allows a staker to queue a withdrawal of their deposit shares. The withdrawal can be
     * completed after the MIN_WITHDRAWAL_DELAY_BLOCKS via either of the completeQueuedWithdrawal methods.
     *
     * While in the queue, these shares are removed from the staker's balance, as well as from their operator's
     * delegated share balance (if applicable). Note that while in the queue, deposit shares are still subject
     * to slashing. If any slashing has occurred, the shares received may be less than the queued deposit shares.
     *
     * @dev To view all the staker's strategies/deposit shares that can be queued for withdrawal, see `getDepositedShares`
     * @dev To view the current conversion between a staker's deposit shares and withdrawable shares, see `getWithdrawableShares`
     */
    function queueWithdrawals(
        QueuedWithdrawalParams[] calldata params
    ) external virtual returns (bytes32[] memory) {}

    /**
     * @notice Used to complete a queued withdrawal
     * @param withdrawal The withdrawal to complete
     * @param tokens Array in which the i-th entry specifies the `token` input to the 'withdraw' function of the i-th Strategy in the `withdrawal.strategies` array.
     * @param tokens For each `withdrawal.strategies`, the underlying token of the strategy
     * NOTE: if `receiveAsTokens` is false, the `tokens` array is unused and can be filled with default values. However, `tokens.length` MUST still be equal to `withdrawal.strategies.length`.
     * NOTE: For the `beaconChainETHStrategy`, the corresponding `tokens` value is ignored (can be 0).
     * @param receiveAsTokens If true, withdrawn shares will be converted to tokens and sent to the caller. If false, the caller receives shares that can be delegated to an operator.
     * NOTE: if the caller receives shares and is currently delegated to an operator, the received shares are
     * automatically delegated to the caller's current operator.
     */
    function completeQueuedWithdrawal(
        Withdrawal calldata withdrawal,
        IERC20[] calldata tokens,
        bool receiveAsTokens
    ) external virtual {}

    /**
     * @notice Used to complete multiple queued withdrawals
     * @param withdrawals Array of Withdrawals to complete. See `completeQueuedWithdrawal` for the usage of a single Withdrawal.
     * @param tokens Array of tokens for each Withdrawal. See `completeQueuedWithdrawal` for the usage of a single array.
     * @param receiveAsTokens Whether or not to complete each withdrawal as tokens. See `completeQueuedWithdrawal` for the usage of a single boolean.
     * @dev See `completeQueuedWithdrawal` for relevant dev tags
     */
    function completeQueuedWithdrawals(
        Withdrawal[] calldata withdrawals,
        IERC20[][] calldata tokens,
        bool[] calldata receiveAsTokens
    ) external virtual {}

    /**
     * @notice Called by a share manager when a staker's deposit share balance in a strategy increases.
     * This method delegates any new shares to an operator (if applicable), and updates the staker's
     * deposit scaling factor regardless.
     * @param staker The address whose deposit shares have increased
     * @param strategy The strategy in which shares have been deposited
     * @param prevDepositShares The number of deposit shares the staker had in the strategy prior to the increase
     * @param addedShares The number of deposit shares added by the staker
     *
     * @dev Note that if the either the staker's current operator has been slashed 100% for `strategy`, OR the
     * staker has been slashed 100% on the beacon chain such that the calculated slashing factor is 0, this
     * method WILL REVERT.
     */
    function increaseDelegatedShares(
        address staker,
        IStrategy strategy,
        uint256 prevDepositShares,
        uint256 addedShares
    ) external virtual {}

    /**
     * @notice If the staker is delegated, decreases its operator's shares in response to
     * a decrease in balance in the beaconChainETHStrategy
     * @param staker the staker whose operator's balance will be decreased
     * @param curDepositShares the current deposit shares held by the staker
     * @param beaconChainSlashingFactorDecrease the amount that the staker's beaconChainSlashingFactor has decreased by
     * @dev Note: `beaconChainSlashingFactorDecrease` are assumed to ALWAYS be < 1 WAD.
     * These invariants are maintained in the EigenPodManager.
     */
    function decreaseDelegatedShares(
        address staker,
        uint256 curDepositShares,
        uint64 beaconChainSlashingFactorDecrease
    ) external virtual {}

    /**
     * @notice Decreases the operators shares in storage after a slash and increases the burnable shares by calling
     * into either the StrategyManager or EigenPodManager (if the strategy is beaconChainETH).
     * @param operator The operator to decrease shares for
     * @param strategy The strategy to decrease shares for
     * @param prevMaxMagnitude the previous maxMagnitude of the operator
     * @param newMaxMagnitude the new maxMagnitude of the operator
     * @dev Callable only by the AllocationManager
     * @dev Note: Assumes `prevMaxMagnitude <= newMaxMagnitude`. This invariant is maintained in
     * the AllocationManager.
     */
    function slashOperatorShares(
        address operator,
        IStrategy strategy,
        uint64 prevMaxMagnitude,
        uint64 newMaxMagnitude
    ) external virtual {}

    /**
     *
     *                         VIEW FUNCTIONS
     *
     */

    /**
     * @notice returns the address of the operator that `staker` is delegated to.
     * @notice Mapping: staker => operator whom the staker is currently delegated to.
     * @dev Note that returning address(0) indicates that the staker is not actively delegated to any operator.
     */
    function delegatedTo(
        address staker
    ) external virtual view returns (address) {}

    /**
     * @notice Mapping: delegationApprover => 32-byte salt => whether or not the salt has already been used by the delegationApprover.
     * @dev Salts are used in the `delegateTo` function. Note that this function only processes the delegationApprover's
     * signature + the provided salt if the operator being delegated to has specified a nonzero address as their `delegationApprover`.
     */
    function delegationApproverSaltIsSpent(address _delegationApprover, bytes32 salt) external virtual view returns (bool) {}

    /// @notice Mapping: staker => cumulative number of queued withdrawals they have ever initiated.
    /// @dev This only increments (doesn't decrement), and is used to help ensure that otherwise identical withdrawals have unique hashes.
    function cumulativeWithdrawalsQueued(
        address staker
    ) external virtual view returns (uint256) {}

    /**
     * @notice Returns 'true' if `staker` *is* actively delegated, and 'false' otherwise.
     */
    function isDelegated(
        address staker
    ) external virtual view returns (bool) {}

    /**
     * @notice Returns true is an operator has previously registered for delegation.
     */
    function isOperator(
        address operator
    ) external virtual view returns (bool) {}

    /**
     * @notice Returns the delegationApprover account for an operator
     */
    function delegationApprover(
        address operator
    ) external virtual view returns (address) {}

    /**
     * @notice Returns the shares that an operator has delegated to them in a set of strategies
     * @param operator the operator to get shares for
     * @param strategies the strategies to get shares for
     */
    function getOperatorShares(
        address operator,
        IStrategy[] memory strategies
    ) external virtual view returns (uint256[] memory) {}

    /**
     * @notice Returns the shares that a set of operators have delegated to them in a set of strategies
     * @param operators the operators to get shares for
     * @param strategies the strategies to get shares for
     */
    function getOperatorsShares(
        address[] memory operators,
        IStrategy[] memory strategies
    ) external virtual view returns (uint256[][] memory) {}

    /**
     * @notice Returns amount of withdrawable shares from an operator for a strategy that is still in the queue
     * and therefore slashable. Note that the *actual* slashable amount could be less than this value as this doesn't account
     * for amounts that have already been slashed. This assumes that none of the shares have been slashed.
     * @param operator the operator to get shares for
     * @param strategy the strategy to get shares for
     * @return the amount of shares that are slashable in the withdrawal queue for an operator and a strategy
     */
    function getSlashableSharesInQueue(address operator, IStrategy strategy) external virtual view returns (uint256) {}

    /**
     * @notice Given a staker and a set of strategies, return the shares they can queue for withdrawal and the
     * corresponding depositShares.
     * This value depends on which operator the staker is delegated to.
     * The shares amount returned is the actual amount of Strategy shares the staker would receive (subject
     * to each strategy's underlying shares to token ratio).
     */
    function getWithdrawableShares(
        address staker,
        IStrategy[] memory strategies
    ) external virtual view returns (uint256[] memory withdrawableShares, uint256[] memory depositShares) {}

    /**
     * @notice Returns the number of shares in storage for a staker and all their strategies
     */
    function getDepositedShares(
        address staker
    ) external virtual view returns (IStrategy[] memory, uint256[] memory) {}

    /**
     * @notice Returns the scaling factor applied to a staker's deposits for a given strategy
     */
    function depositScalingFactor(address staker, IStrategy strategy) external virtual view returns (uint256) {}

    /**
     * @notice Returns the Withdrawal and corresponding shares associated with a `withdrawalRoot`
     * @param withdrawalRoot The hash identifying the queued withdrawal
     * @return withdrawal The withdrawal details
     * @return shares Array of shares corresponding to each strategy in the withdrawal
     * @dev The shares are what a user would receive from completing a queued withdrawal, assuming all slashings are applied
     * @dev Withdrawals queued before the slashing release cannot be queried with this method
     */
    function getQueuedWithdrawal(
        bytes32 withdrawalRoot
    ) external virtual view returns (Withdrawal memory withdrawal, uint256[] memory shares) {}

    /**
     * @notice Returns all queued withdrawals and their corresponding shares for a staker.
     * @param staker The address of the staker to query withdrawals for.
     * @return withdrawals Array of Withdrawal structs containing details about each queued withdrawal.
     * @return shares 2D array of shares, where each inner array corresponds to the strategies in the withdrawal.
     * @dev The shares are what a user would receive from completing a queued withdrawal, assuming all slashings are applied.
     */
    function getQueuedWithdrawals(
        address staker
    ) external virtual view returns (Withdrawal[] memory withdrawals, uint256[][] memory shares) {}

    /// @notice Returns a list of queued withdrawal roots for the `staker`.
    /// NOTE that this only returns withdrawals queued AFTER the slashing release.
    function getQueuedWithdrawalRoots(
        address staker
    ) external virtual view returns (bytes32[] memory) {}

    /**
     * @notice Converts shares for a set of strategies to deposit shares, likely in order to input into `queueWithdrawals`
     * @param staker the staker to convert shares for
     * @param strategies the strategies to convert shares for
     * @param withdrawableShares the shares to convert
     * @return the deposit shares
     * @dev will be a few wei off due to rounding errors
     */
    function convertToDepositShares(
        address staker,
        IStrategy[] memory strategies,
        uint256[] memory withdrawableShares
    ) external virtual view returns (uint256[] memory) {}

    /// @notice Returns the keccak256 hash of `withdrawal`.
    function calculateWithdrawalRoot(
        Withdrawal memory withdrawal
    ) external virtual pure returns (bytes32) {}

    /**
     * @notice Calculates the digest hash to be signed by the operator's delegationApprove and used in the `delegateTo` function.
     * @param staker The account delegating their stake
     * @param operator The account receiving delegated stake
     * @param _delegationApprover the operator's `delegationApprover` who will be signing the delegationHash (in general)
     * @param approverSalt A unique and single use value associated with the approver signature.
     * @param expiry Time after which the approver's signature becomes invalid
     */
    function calculateDelegationApprovalDigestHash(
        address staker,
        address operator,
        address _delegationApprover,
        bytes32 approverSalt,
        uint256 expiry
    ) external virtual view returns (bytes32) {}

    /// @notice return address of the beaconChainETHStrategy
    function beaconChainETHStrategy() external virtual view returns (IStrategy) {}

    /**
     * @notice Returns the minimum withdrawal delay in blocks to pass for withdrawals queued to be completable.
     * Also applies to legacy withdrawals so any withdrawals not completed prior to the slashing upgrade will be subject
     * to this longer delay.
     * @dev Backwards-compatible interface to return the internal `MIN_WITHDRAWAL_DELAY_BLOCKS` value
     * @dev Previous value in storage was deprecated. See `__deprecated_minWithdrawalDelayBlocks`
     */
    function minWithdrawalDelayBlocks() external virtual view returns (uint32) {}

    /// @notice The EIP-712 typehash for the DelegationApproval struct used by the contract
    function DELEGATION_APPROVAL_TYPEHASH() external virtual view returns (bytes32) {}
}
