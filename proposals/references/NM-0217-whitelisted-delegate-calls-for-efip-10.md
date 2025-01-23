# [EFIP-10] Whitelisted Delegate calls for EtherFiNode/EigenPod

**File(s)**: [EtherFiNode.sol](https://github.com/etherfi-protocol/smart-contracts/blob/768bca21fbed35adab4ad4dc1b4d93276ad9e64d/src/EtherFiNode.sol#L507), [EtherFiNodeManager.sol](https://github.com/etherfi-protocol/smart-contracts/blob/768bca21fbed35adab4ad4dc1b4d93276ad9e64d/src/EtherFiNodesManager.sol#L401)

### Summary

This EFIP proposes the introduction of a whitelist mechanism on the delegate call into the EtherFiNode/EigenPod contracts. This change aims to enhance security by restricting call forwarding and function execution to a predefined list of delegates, ensuring that only authorized operations can be performed.

---

### Findings

### [Best Practice] Check input arrays length matches

**File(s)**: [EtherFiNodeManager.sol](https://github.com/etherfi-protocol/smart-contracts/blob/768bca21fbed35adab4ad4dc1b4d93276ad9e64d/src/EtherFiNodesManager.sol)

**Description**: The following functions of the `EtherFiNodeManager` contract do not check if the length of the two input arrays matches `forwardEigenpodCall(...)`, `forwardExternalCall(...)`. It is considered a best practice to check that there is no length mismatch.

**Recommendation(s)**: Consider checking the equality in length of the two array input parameters.

---

### [Best Practice] `forwardEigenpodCall(...)` and `forwardExternalCall(...)` functions don't check if the validator is still registered to the node

**File(s)**: [EtherFiNodesManager.sol](https://github.com/etherfi-protocol/smart-contracts/blob/23fe605a47b03717f8db25ae06301b095da5e5c3/src/EtherFiNodesManager.sol#L387), [EtherFiNodesManager.sol](https://github.com/etherfi-protocol/smart-contracts/blob/23fe605a47b03717f8db25ae06301b095da5e5c3/src/EtherFiNodesManager.sol#L403C14-L403C33)

**Description**: The two functions mentioned above do not check if the validator is still registered to the node. This means that if the valdiator unregistered from the node, the mapping `mapping(uint256 => address) public etherfiNodeAddress` will be zero, and the forward call will fail.

Since the function takes as an input an array of `validatorIds`, if one call fails, it will revert the transaction for all other validators as well.

**Recommendation(s)**: Consider adding a check that the `etherfiNodeAddress[_validatorId] != address(0)`.

---

### [Best Practice] `forwardEigenpodCall(...)` and `forwardExternalCall(...)` don't check the phase of the validator

**File(s)**: [EtherFiNodesManager.sol](https://github.com/etherfi-protocol/smart-contracts/blob/23fe605a47b03717f8db25ae06301b095da5e5c3/src/EtherFiNodesManager.sol#L387), [EtherFiNodesManager](https://github.com/etherfi-protocol/smart-contracts/blob/23fe605a47b03717f8db25ae06301b095da5e5c3/src/EtherFiNodesManager.sol#L403C14-L403C33)

**Description**: A validator can be in one of the following phases `NOT_INITIALIZED, STAKE_DEPOSITED, LIVE, WAITING_FOR_APPROVAL, EXITED, BEING_SLASHED, FULLY_WITHDRAWN`. The two forwarding functions mentioned above do not check the phase in which a validator is before doing the call.

**Recommendation(s)**: Consider checking the phase that the validator is in before proceeding with the call in order to avoid forwarding calls to a validator that is in an unwanted state at the time of the call.

---