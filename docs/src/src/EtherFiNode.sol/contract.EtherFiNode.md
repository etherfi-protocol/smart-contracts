# EtherFiNode
[Git Source](https://github.com/GadzeFinance/dappContracts/blob/c722006f91e5a8b00322356d0c967de90bbae6e0/src/EtherFiNode.sol)

**Inherits:**
[IEtherFiNode](/src/interfaces/IEtherFiNode.sol/interface.IEtherFiNode.md)


## State Variables
### etherfiNodesManager

```solidity
address etherfiNodesManager;
```


### protocolRevenueManager

```solidity
address protocolRevenueManager;
```


### localRevenueIndex

```solidity
uint256 public localRevenueIndex;
```


### vestedAuctionRewards

```solidity
uint256 public vestedAuctionRewards;
```


### ipfsHashForEncryptedValidatorKey

```solidity
string public ipfsHashForEncryptedValidatorKey;
```


### exitRequestTimestamp

```solidity
uint32 public exitRequestTimestamp;
```


### exitTimestamp

```solidity
uint32 public exitTimestamp;
```


### stakingStartTimestamp

```solidity
uint32 public stakingStartTimestamp;
```


### phase

```solidity
VALIDATOR_PHASE public phase;
```


## Functions
### initialize


```solidity
function initialize(address _protocolRevenueManager) public;
```

### receive


```solidity
receive() external payable;
```

### setPhase

Set the validator phase


```solidity
function setPhase(VALIDATOR_PHASE _phase) external onlyEtherFiNodeManagerContract;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_phase`|`VALIDATOR_PHASE`|the new phase|


### setIpfsHashForEncryptedValidatorKey

Set the deposit data


```solidity
function setIpfsHashForEncryptedValidatorKey(string calldata _ipfsHash) external onlyEtherFiNodeManagerContract;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_ipfsHash`|`string`|the deposit data|


### setLocalRevenueIndex


```solidity
function setLocalRevenueIndex(uint256 _localRevenueIndex) external payable onlyEtherFiNodeManagerContract;
```

### setExitRequestTimestamp


```solidity
function setExitRequestTimestamp() external onlyEtherFiNodeManagerContract;
```

### markExited


```solidity
function markExited(uint32 _exitTimestamp) external onlyEtherFiNodeManagerContract;
```

### receiveVestedRewardsForStakers


```solidity
function receiveVestedRewardsForStakers() external payable onlyProtocolRevenueManagerContract;
```

### processVestedAuctionFeeWithdrawal


```solidity
function processVestedAuctionFeeWithdrawal() external;
```

### moveRewardsToManager


```solidity
function moveRewardsToManager(uint256 _amount) external onlyEtherFiNodeManagerContract;
```

### withdrawFunds


```solidity
function withdrawFunds(
    address _treasury,
    uint256 _treasuryAmount,
    address _operator,
    uint256 _operatorAmount,
    address _tnftHolder,
    uint256 _tnftAmount,
    address _bnftHolder,
    uint256 _bnftAmount
) external onlyEtherFiNodeManagerContract;
```

### getStakingRewardsPayouts

get the accrued staking rewards payouts to (toNodeOperator, toTnft, toBnft, toTreasury)


```solidity
function getStakingRewardsPayouts(IEtherFiNodesManager.RewardsSplit memory _splits, uint256 _scale)
    public
    view
    onlyEtherFiNodeManagerContract
    returns (uint256 toNodeOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_splits`|`RewardsSplit.IEtherFiNodesManager`|the splits for the staking rewards|
|`_scale`|`uint256`|the scale = SUM(_splits)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`toNodeOperator`|`uint256`| the payout to the Node Operator|
|`toTnft`|`uint256`|         the payout to the T-NFT holder|
|`toBnft`|`uint256`|         the payout to the B-NFT holder|
|`toTreasury`|`uint256`|     the payout to the Treasury|


### getProtocolRewards

get the accrued protocol rewards payouts to (toNodeOperator, toTnft, toBnft, toTreasury)


```solidity
function getProtocolRewards(IEtherFiNodesManager.RewardsSplit memory _splits, uint256 _scale)
    public
    view
    onlyEtherFiNodeManagerContract
    returns (uint256 toNodeOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_splits`|`RewardsSplit.IEtherFiNodesManager`|the splits for the protocol rewards|
|`_scale`|`uint256`|the scale = SUM(_splits)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`toNodeOperator`|`uint256`| the payout to the Node Operator|
|`toTnft`|`uint256`|         the payout to the T-NFT holder|
|`toBnft`|`uint256`|         the payout to the B-NFT holder|
|`toTreasury`|`uint256`|     the payout to the Treasury|


### getNonExitPenalty

compute the non exit penalty for the b-nft holder


```solidity
function getNonExitPenalty(uint256 _principal, uint256 _dailyPenalty, uint32 _exitTimestamp)
    public
    view
    onlyEtherFiNodeManagerContract
    returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_principal`|`uint256`|the principal for the non exit penalty (e.g., 1 ether)|
|`_dailyPenalty`|`uint256`|the dailty penalty for the non exit penalty|
|`_exitTimestamp`|`uint32`|the exit timestamp for the validator node|


### getFullWithdrawalPayouts

Given the current balance of the ether fi node after its EXIT,
Compute the payouts to {node operator, t-nft holder, b-nft holder, treasury}


```solidity
function getFullWithdrawalPayouts(
    IEtherFiNodesManager.RewardsSplit memory _splits,
    uint256 _scale,
    uint256 _principal,
    uint256 _dailyPenalty
) external view returns (uint256 toNodeOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_splits`|`RewardsSplit.IEtherFiNodesManager`|the splits for the staking rewards|
|`_scale`|`uint256`|the scale = SUM(_splits)|
|`_principal`|`uint256`|the principal for the non exit penalty (e.g., 1 ether)|
|`_dailyPenalty`|`uint256`|the dailty penalty for the non exit penalty|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`toNodeOperator`|`uint256`| the payout to the Node Operator|
|`toTnft`|`uint256`|         the payout to the T-NFT holder|
|`toBnft`|`uint256`|         the payout to the B-NFT holder|
|`toTreasury`|`uint256`|     the payout to the Treasury|


### _getClaimableVestedRewards


```solidity
function _getClaimableVestedRewards() internal view returns (uint256);
```

### _getDaysPassedSince


```solidity
function _getDaysPassedSince(uint32 _startTimestamp, uint32 _endTimestamp) internal view returns (uint256);
```

### calculatePayouts


```solidity
function calculatePayouts(uint256 _totalAmount, IEtherFiNodesManager.RewardsSplit memory _splits, uint256 _scale)
    public
    view
    returns (uint256, uint256, uint256, uint256);
```

### etherfiNodesManagerAddress


```solidity
function etherfiNodesManagerAddress() internal view returns (address);
```

### protocolRevenueManagerAddress


```solidity
function protocolRevenueManagerAddress() internal view returns (address);
```

### onlyEtherFiNodeManagerContract


```solidity
modifier onlyEtherFiNodeManagerContract();
```

### onlyProtocolRevenueManagerContract


```solidity
modifier onlyProtocolRevenueManagerContract();
```

