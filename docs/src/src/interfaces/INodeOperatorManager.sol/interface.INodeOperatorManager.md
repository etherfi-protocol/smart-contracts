# INodeOperatorManager
[Git Source](https://github.com/GadzeFinance/dappContracts/blob/c722006f91e5a8b00322356d0c967de90bbae6e0/src/interfaces/INodeOperatorManager.sol)


## Functions
### registerNodeOperator


```solidity
function registerNodeOperator(bytes32[] calldata _merkleProof, bytes memory ipfsHash, uint64 totalKeys) external;
```

### fetchNextKeyIndex


```solidity
function fetchNextKeyIndex(address _user) external returns (uint64);
```

### getUserTotalKeys


```solidity
function getUserTotalKeys(address _user) external view returns (uint64 totalKeys);
```

### getNumKeysRemaining


```solidity
function getNumKeysRemaining(address _user) external view returns (uint64 numKeysRemaining);
```

### isWhitelisted


```solidity
function isWhitelisted(address _user) external view returns (bool whitelisted);
```

## Structs
### KeyData

```solidity
struct KeyData {
    uint64 totalKeys;
    uint64 keysUsed;
    bytes ipfsHash;
}
```

