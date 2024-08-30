# [Eigenlayer] EigenLayer PEPE Upgrade integration

**File(s)**: [EtherFiNode.sol](https://github.com/etherfi-protocol/smart-contracts/blob/7873a6bed9e4e2577625bc518680dcdf51d923f9/src/EtherFiNode.sol#L601), [EtherFiNodesManager.sol](https://github.com/etherfi-protocol/smart-contracts/blob/7873a6bed9e4e2577625bc518680dcdf51d923f9/src/EtherFiNodesManager.sol#L171), [eigenlayer-libraries](https://github.com/etherfi-protocol/smart-contracts/tree/7873a6bed9e4e2577625bc518680dcdf51d923f9/src/eigenlayer-libraries)

### Summary

Eigenlayer's upcoming PEPE upgrade introduces several breaking changes for the pod lifecycle around proving and claiming withdrawals. This PR seeks to implement minimal changes to ensure that the protocol is able to perform its core duties around validator lifecycle after the upgrade. More fully featured support of EigenLayer updates is expected to come with the upcoming v2.5 protocol update.

Primary changes:

- full removal old balance proof functionality
- removal of all functionality relying on `eigenpod.hasRestaked()` which no longer exists after the update
- deprecation of all usage of the `delayedWithdrawalRouter` contract. All funds flow through the `delegationManager` after the update.
- simple forwarding wrapper for the new `checkpoint` functionality

---

### Questions

### Do the new contracts need to implement the new `EigenPod.verifyStaleBalance` functionality?

According to [EigenLayer's docs](https://hackmd.io/@-HV50kYcRqOjl_7du8m1AA/SkJPfqBeC#Stale-Balance-Proofs) the new `startCheckpoint` can tipycally only be called by the pod `owner`.

However, if a large proportion of validators in a pod are slashed on the beacon chain, it's unlikely the pod owner will want to perform a checkpoint. In this case, EigenLayer relies on a `staleness proof` to allow a `third party` to start a checkpoint on behalf of the pod owner.

The `verifyStaleBalance(...)` function which is part of the new `checkpoint` mechanism was not implemented in the `EtherFiNode` or `EtherFiNodesManager` contracts.

Is this function supposed to be called directly on EigenLayer's EigenPod contract by a 3rd party?


---

### Findings

### [Low] `EtherFiNode::getRewardsPayouts` function still uses the soon to be deprecated `DelayedWithdrawalRouter` contract when computing the rewards

**File(s)**: [EtherFiNode.sol](https://github.com/etherfi-protocol/smart-contracts/blob/7873a6bed9e4e2577625bc518680dcdf51d923f9/src/EtherFiNode.sol#L313)

**Description**: The `getRewardsPayouts(...)` function calculates the staking rewards accrued in the safe for the `nodeOperator, tNft, bNft & treasury`. This function calls the `withdrawableBalanceInExecutionLayer(...)` function which computes the `_balance` based on the safe's balance `uint256 safeBalance = address(this).balance` plus the claimable rewards from the `delayedWithdrawalRouter` contract.

Since the `delayedWithdrawalRouter` will be deprecated, this function needs to be updated accordingly.


**Recommendation(s)**: Update the rewards calculation mechanism based on the new checkpoints system provided by EigenLayer

**Update from client**:

---

### [Info] `EtherFiNodesManager::partialWithdraw` flow will need an overhaul

**File(s)**: [EtherFiNodesManager.sol](https://github.com/etherfi-protocol/smart-contracts/blob/7873a6bed9e4e2577625bc518680dcdf51d923f9/src/EtherFiNodesManager.sol#L240)

**Description**: According to [EigenLayer's docs](https://hackmd.io/@-HV50kYcRqOjl_7du8m1AA/SkJPfqBeC#Stale-Balance-Proofs) the new checkpointing system will not differentiate between partial withdrawals and full withdrawals. *"Shares will be awarded for partial withdrawals (as well as any other ETH for which we can't attribute a source)."*

The current implementation of the `EtherFiNodesManager::partialWithdraw` function enforces that the safe's balance should not exceed 16 ETH `address(etherfiNode).balance < 16 ether`. This restriction will conflict with the PEPE upgrade's new checkpoint proof system, which no longer differentiates between partial and full withdrawals. With validators potentially having higher balances (up to 2048 ETH) due to the MaxEB increase in the Pectra hard fork, this enforcement could lead to errors.


**Recommendation(s)**: The `partialWithdraw` flow needs an overhaul since post`PEPE` the new system has a single mechanism that handles both partial and full withdrawals.

**Update from client**:

---

### [Info] `EtherFiNodesManager::completeQueuedWithdrawals` can fail if `receiveAsTokens` is set to `false`

**File(s)**: [EtherFiNodesManager.sol](https://github.com/etherfi-protocol/smart-contracts/blob/7873a6bed9e4e2577625bc518680dcdf51d923f9/src/EtherFiNodesManager.sol#L220), [EtherFiNode.sol](https://github.com/etherfi-protocol/smart-contracts/blob/7873a6bed9e4e2577625bc518680dcdf51d923f9/src/EtherFiNode.sol#L224)

**Description**: The `completeQueuedWithdrawals(...)` logic still relies on the `DelayedWithdrawalRouter` functionality which will be deprecated during the PEPE upgrade.

If the admin wants to withdraw shares instead of tokens, setting `receiveAsTokens == false` will always fail if at least 1 validator has a pending withdrawal.

Since the new system will not rely on the `DelayedWithdrawalRouter` contract anymore, the `completeQueuedWithdrawals(...)` function should be updated accordingly.

```
    function _completeQueuedWithdrawals(...) internal {
//..
//..

        } else {
//@audit this code block seems to be irrelevant after the upgrade
            require(
                pendingWithdrawalFromRestakingInGwei == 0,
                "PENDING_WITHDRAWAL_NOT_ZERO"
            );
        }
//..
//..
```

**Recommendation(s)**: Functions that still rely on the existance of `DelayedWithdrawalRouter` should be updated.

**Update from client**:

---

### [Info] `EtherFiNode::isRestakingEnabled` feature needs to be revisited

**File(s)**: [EtherFiNode.sol](https://github.com/etherfi-protocol/smart-contracts/blob/7873a6bed9e4e2577625bc518680dcdf51d923f9/src/EtherFiNode.sol#L31)

**Description**: According to the docs with checkpoint proofs, the separation between M1 and M2 pods is no longer important, as the checkpoint process directly supports both featuresets:

*- M1 pod owners can continue not restaking their validators' beacon chain ETH and accessing consensus rewards directly by calling `startCheckpoint`.
With no validators restaked via `verifyWithdrawalCredentials`, `startCheckpoint` will auto-complete a checkpoint that awards the pod owner with shares equal to the pod's native ETH balance. These can be restaked or withdrawn via the `DelegationManager`.*

*- M2 pod owners that have restaked beacon chain validators can interact with the checkpoint proof system as normal.*

A lot of the functions in the `EtherFiNode` contract still rely on the `isRestakingEnabled` bool which means that the system tries to differentiate between M1 and M2 pods. This differentiation seems to not be needed anymore after the `PEPE` upgrade.

**Recommendation(s)**: Consider refactoring the code according to the new system. It looks like `isRestakingEnabled` can be treated as `true` by default after the update.

**Update from client**:

---