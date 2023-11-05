# IAuctionManager
[Git Source](https://github.com/GadzeFinance/dappContracts/blob/c722006f91e5a8b00322356d0c967de90bbae6e0/src/interfaces/IAuctionManager.sol)


## Functions
### createBid


```solidity
function createBid(uint256 _bidSize, uint256 _bidAmount) external payable returns (uint256[] memory);
```

### updateSelectedBidInformation


```solidity
function updateSelectedBidInformation(uint256 _bidId) external;
```

### cancelBid


```solidity
function cancelBid(uint256 _bidId) external;
```

### getBidOwner


```solidity
function getBidOwner(uint256 _bidId) external view returns (address);
```

### reEnterAuction


```solidity
function reEnterAuction(uint256 _bidId) external;
```

### setStakingManagerContractAddress


```solidity
function setStakingManagerContractAddress(address _stakingManagerContractAddress) external;
```

### processAuctionFeeTransfer


```solidity
function processAuctionFeeTransfer(uint256 _validatorId) external;
```

### isBidActive


```solidity
function isBidActive(uint256 _bidId) external view returns (bool);
```

### numberOfActiveBids


```solidity
function numberOfActiveBids() external view returns (uint256);
```

### setProtocolRevenueManager


```solidity
function setProtocolRevenueManager(address _protocolRevenueManager) external;
```

## Structs
### Bid

```solidity
struct Bid {
    uint256 amount;
    uint64 bidderPubKeyIndex;
    address bidderAddress;
    bool isActive;
}
```

