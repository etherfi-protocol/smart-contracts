# IEtherFiNode
[Git Source](https://github.com/GadzeFinance/dappContracts/blob/c722006f91e5a8b00322356d0c967de90bbae6e0/src/interfaces/IEtherFiNode.sol)


## Functions
### phase


```solidity
function phase() external view returns (VALIDATOR_PHASE);
```

### ipfsHashForEncryptedValidatorKey


```solidity
function ipfsHashForEncryptedValidatorKey() external view returns (string memory);
```

### localRevenueIndex


```solidity
function localRevenueIndex() external view returns (uint256);
```

### stakingStartTimestamp


```solidity
function stakingStartTimestamp() external view returns (uint32);
```

### exitRequestTimestamp


```solidity
function exitRequestTimestamp() external view returns (uint32);
```

### exitTimestamp


```solidity
function exitTimestamp() external view returns (uint32);
```

### vestedAuctionRewards


```solidity
function vestedAuctionRewards() external view returns (uint256);
```

### getNonExitPenalty


```solidity
function getNonExitPenalty(uint256 _principal, uint256 _dailyPenalty, uint32 _endTimestamp)
    external
    view
    returns (uint256);
```

### calculatePayouts


```solidity
function calculatePayouts(uint256 _totalAmount, IEtherFiNodesManager.RewardsSplit memory _splits, uint256 _scale)
    external
    view
    returns (uint256, uint256, uint256, uint256);
```

### getStakingRewardsPayouts


```solidity
function getStakingRewardsPayouts(IEtherFiNodesManager.RewardsSplit memory _splits, uint256 _scale)
    external
    view
    returns (uint256, uint256, uint256, uint256);
```

### getProtocolRewards


```solidity
function getProtocolRewards(IEtherFiNodesManager.RewardsSplit memory _splits, uint256 _scale)
    external
    view
    returns (uint256, uint256, uint256, uint256);
```

### getRewardsPayouts


```solidity
function getRewardsPayouts(
    bool _stakingRewards,
    bool _protocolRewards,
    bool _vestedAuctionFee,
    IEtherFiNodesManager.RewardsSplit memory _SRsplits,
    uint256 _SRscale,
    IEtherFiNodesManager.RewardsSplit memory _PRsplits,
    uint256 _PRscale
) external view returns (uint256, uint256, uint256, uint256);
```

### getFullWithdrawalPayouts


```solidity
function getFullWithdrawalPayouts(
    IEtherFiNodesManager.RewardsSplit memory _splits,
    uint256 _scale,
    uint256 _principal,
    uint256 _dailyPenalty
) external view returns (uint256, uint256, uint256, uint256);
```

### setPhase


```solidity
function setPhase(VALIDATOR_PHASE _phase) external;
```

### setIpfsHashForEncryptedValidatorKey


```solidity
function setIpfsHashForEncryptedValidatorKey(string calldata _ipfs) external;
```

### setLocalRevenueIndex


```solidity
function setLocalRevenueIndex(uint256 _localRevenueIndex) external payable;
```

### setExitRequestTimestamp


```solidity
function setExitRequestTimestamp() external;
```

### markExited


```solidity
function markExited(uint32 _exitTimestamp) external;
```

### receiveVestedRewardsForStakers


```solidity
function receiveVestedRewardsForStakers() external payable;
```

### processVestedAuctionFeeWithdrawal


```solidity
function processVestedAuctionFeeWithdrawal() external;
```

### moveRewardsToManager


```solidity
function moveRewardsToManager(uint256 _amount) external;
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
) external;
```

## Enums
### VALIDATOR_PHASE

```solidity
enum VALIDATOR_PHASE {
    STAKE_DEPOSITED,
    LIVE,
    EXITED,
    CANCELLED
}
```

