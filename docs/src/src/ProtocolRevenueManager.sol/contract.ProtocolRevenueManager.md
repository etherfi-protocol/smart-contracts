# ProtocolRevenueManager
[Git Source](https://github.com/GadzeFinance/dappContracts/blob/c722006f91e5a8b00322356d0c967de90bbae6e0/src/ProtocolRevenueManager.sol)

**Inherits:**
[IProtocolRevenueManager](/src/interfaces/IProtocolRevenueManager.sol/interface.IProtocolRevenueManager.md), Pausable


## State Variables
### owner

```solidity
address public owner;
```


### etherFiNodesManager

```solidity
IEtherFiNodesManager etherFiNodesManager;
```


### auctionManager

```solidity
IAuctionManager auctionManager;
```


### globalRevenueIndex

```solidity
uint256 public globalRevenueIndex = 1;
```


### vestedAuctionFeeSplitForStakers

```solidity
uint256 public constant vestedAuctionFeeSplitForStakers = 50;
```


### auctionFeeVestingPeriodForStakersInDays

```solidity
uint256 public constant auctionFeeVestingPeriodForStakersInDays = 6 * 7 * 4;
```


## Functions
### constructor

Constructor to set variables on deployment


```solidity
constructor();
```

### pauseContract


```solidity
function pauseContract() external onlyOwner;
```

### unPauseContract


```solidity
function unPauseContract() external onlyOwner;
```

### receive

All of the received Ether is shared to all validators! Cool!


```solidity
receive() external payable;
```

### addAuctionRevenue

add the revenue from the auction fee paid by the node operator for the corresponding validator


```solidity
function addAuctionRevenue(uint256 _validatorId) external payable onlyAuctionManager;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_validatorId`|`uint256`|the validator ID|


### distributeAuctionRevenue

Distribute the accrued rewards to the validator


```solidity
function distributeAuctionRevenue(uint256 _validatorId) external onlyEtherFiNodesManager returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_validatorId`|`uint256`|id of the validator|


### setEtherFiNodesManagerAddress


```solidity
function setEtherFiNodesManagerAddress(address _etherFiNodesManager) external onlyOwner;
```

### setAuctionManagerAddress


```solidity
function setAuctionManagerAddress(address _auctionManager) external onlyOwner;
```

### getAccruedAuctionRevenueRewards

Compute the accrued rewards for a validator


```solidity
function getAccruedAuctionRevenueRewards(uint256 _validatorId) public view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_validatorId`|`uint256`|id of the validator|


### onlyOwner


```solidity
modifier onlyOwner();
```

### onlyEtherFiNodesManager


```solidity
modifier onlyEtherFiNodesManager();
```

### onlyAuctionManager


```solidity
modifier onlyAuctionManager();
```

