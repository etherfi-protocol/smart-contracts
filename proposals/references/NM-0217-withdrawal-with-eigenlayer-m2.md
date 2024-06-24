# NM-0217 - EtherFi - Withdrawal with EigenLayer M2


### [Info] Uninitialized `EtherFiNode` allows anyone to call the `EtherFiNode::initialize(...)` function and change the `etherFiNodesManager`

**File(s)**: [`EtherFiNode.sol`](https://github.com/etherfi-protocol/smart-contracts/blob/e0684c82f8edb55f8b40a2dab23c7fed95e31ab4/src/EtherFiNode.sol#L61)

**Description**: The `EtherFiNode::initialize(...)` function has no access control and anyone can call it to change the `etherFiNodesManager` address of the proxy implementation contract.

**Impact**: The new `etherFiNodesManager` address will be able to call different functions on the implementation contract, like the `forwardCall` function. It is a situation similar to the `AvsOperator` implementation contract where the manager can potentially cause reputational damage.


**Recommendation(s)**: Prevent external users from initializing the implementation contract by adding a `bool = initialized` in the implementation contract, similarly to the solution that was added in the `AvsOperator` contract.

**Status**: Fixed.

**Update from the client**:

---

### [Medium] `hasOutstaingEigenPodWithdrawalsQueuedBeforeExit(...)` function may return wrong result

**File**: [`EtherFiNode.sol`](https://github.com/etherfi-protocol/smart-contracts/blob/e0684c82f8edb55f8b40a2dab23c7fed95e31ab4/src/EtherFiNode.sol#L629)

**Description**: The `hasOutstaingEigenPodWithdrawalsQueuedBeforeExit(...)` is expected to indicate if there are some non-claimed withdrawals that were queued before the call to `processNodeExit(...)` function. The function checks if the `EigenPod` is in `M2` phase before doing any further check as can be seen in the following snippet of code.

```solidity=
function hasOutstaingEigenPodWithdrawalsQueuedBeforeExit() public view returns (bool) {
    if (!isRestakingEnabled) return false;

    if (!IEigenPod(eigenPod).hasRestaked()) {
        IDelayedWithdrawalRouter delayedWithdrawalRouter = IDelayedWithdrawalRouter(IEtherFiNodesManager(etherFiNodesManager).delayedWithdrawalRouter());
        IDelayedWithdrawalRouter.DelayedWithdrawal[] memory unclaimedWithdrawals = delayedWithdrawalRouter.getUserDelayedWithdrawals(address(this));
        for (uint256 i = 0; i < unclaimedWithdrawals.length; i++) {
            if (unclaimedWithdrawals[i].blockCreated < restakingObservedExitBlock) {
                // unclaimed withdrawal from before oracle observed exit
                return true;
            }
        }
    } else {

    }

    return false;
}
```

However, withdrawals are only being check for `EigenPods` in `M1` phase because the `IEigenPod(eigenPod).hasRestaked()` is being negated.

This may cause this function to return `false` in cases when the return value should be `true`. Because this function is to check that there are not remaining withdrawals before executing a `fullWithdraw`, the wrong result could cause to distribute funds from other validators.

**Recommendation(s)**: Consider reviewing the condition for returning earlier.

**Status**: Fixed, but I think loop can be removed.

**Update from the client**:

---

### [Critical] Funds can be stuck in `EtherFiNode` contracts

**File(s)**: [`EtherFiNode.sol`](https://github.com/etherfi-protocol/smart-contracts/blob/syko/feature/m2_withdrawal/src/EtherFiNode.sol)

**Description**: The process for fully withdrawing a validator includes the following steps:

1.  The `tnft` holder requests the validator's exit.
2.  The `bnft` holder exits the node in the beacon chain.
3.  The withdrawal proof is submited to the `EigenPod` contract.
4.  The `EtherFi` protocols processes the validator's exit through the `processNodeExit(...)` function. This will queue withdrawals from `EigenLayer`.
5.  The withdrawals queued on `EigenLayer` are executed.
6.  A `fullWithdraw` is executed for the validator.

A problem arises because step 4, requires to queue one new withdrawal.

```solidity=
function processNodeExit(uint256 _validatorId) external onlyEtherFiNodeManagerContract ensureLatestVersion returns (bytes32[] memory fullWithdrawalRoots) {
    if (isRestakingEnabled) {
        // eigenLayer bookeeping
        // we need to mark a block from which we know all beaconchain eth has been moved to the eigenPod
        // so that we can properly calculate exit payouts and ensure queued withdrawals have been resolved
        // (eigenLayer withdrawals are tied to blocknumber instead of timestamp)
        restakingObservedExitBlock = uint32(block.number);

        fullWithdrawalRoots = queueRestakedWithdrawal();
        require(fullWithdrawalRoots.length == 1, "NO_FULLWITHDRAWAL_QUEUED");
    }
}
```

However, any user can queue withdrawals for an `EtherFiNode` through the `queueRestakedWithdrawal(...)` function. If an user queues a proven withdrawal for the validator, the call to `processNodeExit(...)` will fail because there are not new withdrawals to be queued. This will make impossible to move forward in the withdrawal process for the validator and funds would be stuck.

**Recommendation(s)**: Consider making permissioned the `queueRestakedWithdrawal(...)` function or modifying the full withdrawal process.

**Status**: Fixed, but in which cases should `queueRestakedWithdrawal(...)` function be called out of `processNodeExit(...)`.

**Update from the client**:



---

### [High] Funds from nodes that exited after incurring in penalties are stuck

**File(s)**: [`EtherFiNode.sol`](https://github.com/etherfi-protocol/smart-contracts/blob/e0684c82f8edb55f8b40a2dab23c7fed95e31ab4/src/EtherFiNode.sol#L687)

**Description**: The process for fully withdrawing a validator with restaking enabled includes queueing a withdrawal for the validator in the EigenLayer protocol. The queueing process requires the `EigenPod` to have at least `32 eth` that have not been queued for withdrawals before.

```solidity
function _queueRestakedFullWithdrawal() internal returns (bytes32[] memory fullWithdrawalRoots) {
    ...
    // calculate the pending amount. The withdrawal proof verification will update the EigenPod's `withdrawableRestakedExecutionLayerGwei` value
    uint256 unclaimedFullWithdrawalAmountInGwei = IEigenPod(eigenPod).withdrawableRestakedExecutionLayerGwei() - pendingWithdrawalFromRestakingInGwei;
    if (unclaimedFullWithdrawalAmountInGwei == 0) return fullWithdrawalRoots;

    // TODO: revisit for the case of slashing
    // we will need to re-visit this logic once the EigenLayer's slashing mechanism is implemented
    // + we need to consider the slashing amount in the full withdrawal from the beacon layer as well
    require(unclaimedFullWithdrawalAmountInGwei >= 32 ether / 1 gwei, "SLASHED");

    ...
}
```

If the validator incurred in any penalties and its balance decreased under `32 eth` before it was withdrawn, the withdrawn `eth` will sit in the `EigenPod` without being withdrawable from the `EtherFiNode`.

**Recommendation(s)**: Do not restrict withdrawals to only bigger or equal than `32 eth`.

**Status**: Acknowleged.

**Update from the client**:

---

### [Info] Wrong check in `verifyForwardCall(...)` function

**File(s)**: [`EtherFiNode.sol`](https://github.com/etherfi-protocol/smart-contracts/blob/e0684c82f8edb55f8b40a2dab23c7fed95e31ab4/src/EtherFiNode.sol#L519)

**Description**: The `forwardCall(...)` function from the `EtherFiNode` allows the `EtherFiNodeManager` to execute almost arbitrary calls to the the `DelgationManager`, `EigenPodManager`, and `DelayedWithdrawalRouter` contracts. This function uses the `_verifyForwardCall(...)` function to restrict some of the calls that can be executed.

```solidity
function _verifyForwardCall(address to, bytes memory data) internal view {
    bytes4 selector;
    assembly {
        selector := mload(add(data, 0x20))
    }
    bool allowed = (selector != IDelegationManager.completeQueuedWithdrawal.selector && selector == IDelegationManager.completeQueuedWithdrawals.selector);
    require (allowed, "NOT_ALLOWED");
}
```

However, the `_verifyForwardCall(...)` only allows to execute calls to the function `completeQueuedWithdrawals(...)`.

**Recommendation(s)**: Consider revisiting the mentioend condition.

**Status**: Fixed.

**Update from the client**:

---

### [Low] Exit process from one validator can delay exit process from a different validator

**File(s)**: [`EtherFiNodeManager.sol`](https://github.com/etherfi-protocol/smart-contracts/blob/e0684c82f8edb55f8b40a2dab23c7fed95e31ab4/src/EtherFiNodesManager.sol#L241)

**Description**: One `EtherFiNode` may contain multiple validators, these validators can be exited individually. Part of the process to fully withdraw a validator is to execute the `fullWithdraw(...)` function. This function does multiple checks before completing the withdrawal. One of the checks consists in ensuring that there are not queued withdrawals related to this validator in the `EigenLayer` protocol. This is done through the `claimQueuedWithdrawals(...)` function with the second argument set as `true`, this function will execute claimable withdrawals until a maximum of `maxEigenlayerWithdrawals`, and after finishing those, it will check if there are any remaining queued withdrawals that were queued before `restakingObservedExitBlock`.

```solidity=
function fullWithdraw(uint256 _validatorId) public nonReentrant whenNotPaused{
    ...
    require (!IEtherFiNode(etherfiNode).claimQueuedWithdrawals(maxEigenlayerWithdrawals, true), "PENDING_WITHDRAWALS");
    require(phase(_validatorId) == IEtherFiNode.VALIDATOR_PHASE.EXITED, "NOT_EXITED");
    ...
}
```

However, the `restakingObservedExitBlock` variable is unique for the `EtherFiNode` and it is updated everytime `processNodeExit(...)` is executed in the node. This could lead to the following scenario:

- Validator A start withdrawal process.
- `processNodeExit(...)` is executed for Validator A and its withdrawal from `EigenLayer` is queued. `restakingObservedExitBlock` is updated to current `block.timestamp`.
- Validator B start withdrawal process.
- `processNodeExit(...)` is executed for Validator B and its withdrawal from `EigenLayer` is queeud. `restakingObservedExitBlock` is updated to current `block.timestamp`.
- `fullWithdraw(...)` is executed for Validator A, `claimQueuedWithdrawals(...)` is called and it processes the withdrawal from Validator A, however delay time for withdrawal from Validator B has not been completed. Because `restakingObservedExitBlock` was updated when `processNodeExit(...)` was called for node B, the check will fail stoping the withdrawal process of Validator A.

**Recommendation(s)**: Consider keeping the `restakingObservedExitBlock` per validator, this could be achieved with a mapping.

**Status**: Acknowleged.

**Update from the client**:

