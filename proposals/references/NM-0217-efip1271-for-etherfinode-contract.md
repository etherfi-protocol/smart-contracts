# EIP-1271-compatibility-for-the-EtherFiNode-contract

**File(s)**: [EtherFiNode.sol](https://github.com/etherfi-protocol/smart-contracts/blob/8cdf270c1fe3f9680db97d425ba27e6acf87522f/src/EtherFiNode.sol#L796), [IEtherFiNodeManager.sol](https://github.com/etherfi-protocol/smart-contracts/blob/8cdf270c1fe3f9680db97d425ba27e6acf87522f/src/interfaces/IEtherFiNodesManager.sol#L51)

### Summary

The reviewed PR introduces the `isValidSignature` function in the `EtherFiNode` contract that will make it compatible with `EIP-1271`. 

`EIP-1271` aims to introduce a standard signature validation method for smart contracts. The `IEtherFiNodesManager.sol` interface was also updated in order to be compatible with the new version of the `EtherFiNode` contract.


### Findings

### [Best Practice] No checks for error returned

**File(s)**: [`src/EtherFiNode.sol`](https://github.com/etherfi-protocol/smart-contracts/blob/8cdf270c1fe3f9680db97d425ba27e6acf87522f/src/EtherFiNode.sol#L797)

**Description**: The `isValidSignature(...)` method uses the `tryRecover(...)` function to recover the signer of the provided message and signature pair. This function returns two values:
- The possible signer of the message;
- A value indicating if there was any error during the recovery process.

Currently, the second value is ignored.

**Recommendation(s)**: Consider checking if there was an error during the recovery process and returning early the correct value if there was an error.
