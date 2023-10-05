# IProtocolRevenueManager
[Git Source](https://github.com/GadzeFinance/dappContracts/blob/c722006f91e5a8b00322356d0c967de90bbae6e0/src/interfaces/IProtocolRevenueManager.sol)


## Functions
### globalRevenueIndex


```solidity
function globalRevenueIndex() external view returns (uint256);
```

### auctionFeeVestingPeriodForStakersInDays


```solidity
function auctionFeeVestingPeriodForStakersInDays() external view returns (uint256);
```

### addAuctionRevenue


```solidity
function addAuctionRevenue(uint256 _validatorId) external payable;
```

### distributeAuctionRevenue


```solidity
function distributeAuctionRevenue(uint256 _validatorId) external returns (uint256);
```

### setEtherFiNodesManagerAddress


```solidity
function setEtherFiNodesManagerAddress(address _etherFiNodesManager) external;
```

### getAccruedAuctionRevenueRewards


```solidity
function getAccruedAuctionRevenueRewards(uint256 _validatorId) external returns (uint256);
```

## Structs
### AuctionRevenueSplit

```solidity
struct AuctionRevenueSplit {
    uint64 treasurySplit;
    uint64 nodeOperatorSplit;
    uint64 tnftHolderSplit;
    uint64 bnftHolderSplit;
}
```

