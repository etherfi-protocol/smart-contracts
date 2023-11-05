# NodeOperatorManager
[Git Source](https://github.com/GadzeFinance/dappContracts/blob/c722006f91e5a8b00322356d0c967de90bbae6e0/src/NodeOperatorManager.sol)

**Inherits:**
[INodeOperatorManager](/src/interfaces/INodeOperatorManager.sol/interface.INodeOperatorManager.md), Ownable

TODO Test whitelist bidding in auction
TODO Test permissionless bidding in auction


## State Variables
### auctionManagerContractAddress

```solidity
address public auctionManagerContractAddress;
```


### auctionMangerInterface

```solidity
IAuctionManager auctionMangerInterface;
```


### auctionContractAddress

```solidity
address auctionContractAddress;
```


### merkleRoot

```solidity
bytes32 public merkleRoot;
```


### addressToOperatorData

```solidity
mapping(address => KeyData) public addressToOperatorData;
```


### whitelistedAddresses

```solidity
mapping(address => bool) private whitelistedAddresses;
```


## Functions
### registerNodeOperator


```solidity
function registerNodeOperator(bytes32[] calldata _merkleProof, bytes memory _ipfsHash, uint64 _totalKeys) public;
```

### fetchNextKeyIndex


```solidity
function fetchNextKeyIndex(address _user) external onlyAuctionManagerContract returns (uint64);
```

### updateMerkleRoot

Updates the merkle root whitelists have been updated

*merkleroot gets generated in JS offline and sent to the contract*


```solidity
function updateMerkleRoot(bytes32 _newMerkle) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_newMerkle`|`bytes32`|new merkle root to be used for bidding|


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
function isWhitelisted(address _user) public view returns (bool whitelisted);
```

### setAuctionContractAddress


```solidity
function setAuctionContractAddress(address _auctionContractAddress) public onlyOwner;
```

### _verifyWhitelistedAddress


```solidity
function _verifyWhitelistedAddress(address _user, bytes32[] calldata _merkleProof)
    internal
    returns (bool whitelisted);
```

### onlyAuctionManagerContract


```solidity
modifier onlyAuctionManagerContract();
```

## Events
### OperatorRegistered

```solidity
event OperatorRegistered(uint64 totalKeys, uint64 keysUsed, bytes ipfsHash);
```

### MerkleUpdated

```solidity
event MerkleUpdated(bytes32 oldMerkle, bytes32 indexed newMerkle);
```

