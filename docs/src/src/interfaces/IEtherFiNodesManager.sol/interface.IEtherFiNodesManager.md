# IEtherFiNodesManager
[Git Source](https://github.com/GadzeFinance/dappContracts/blob/c722006f91e5a8b00322356d0c967de90bbae6e0/src/interfaces/IEtherFiNodesManager.sol)


## Functions
### numberOfValidators


```solidity
function numberOfValidators() external view returns (uint256);
```

### etherfiNodeAddress


```solidity
function etherfiNodeAddress(uint256 _validatorId) external view returns (address);
```

### phase


```solidity
function phase(uint256 _validatorId) external view returns (IEtherFiNode.VALIDATOR_PHASE phase);
```

### ipfsHashForEncryptedValidatorKey


```solidity
function ipfsHashForEncryptedValidatorKey(uint256 _validatorId) external view returns (string memory);
```

### localRevenueIndex


```solidity
function localRevenueIndex(uint256 _validatorId) external returns (uint256);
```

### vestedAuctionRewards


```solidity
function vestedAuctionRewards(uint256 _validatorId) external returns (uint256);
```

### generateWithdrawalCredentials


```solidity
function generateWithdrawalCredentials(address _address) external view returns (bytes memory);
```

### getWithdrawalCredentials


```solidity
function getWithdrawalCredentials(uint256 _validatorId) external view returns (bytes memory);
```

### isExitRequested


```solidity
function isExitRequested(uint256 _validatorId) external view returns (bool);
```

### isExited


```solidity
function isExited(uint256 _validatorId) external view returns (bool);
```

### getNonExitPenalty


```solidity
function getNonExitPenalty(uint256 _validatorId, uint32 _endTimestamp) external view returns (uint256);
```

### getStakingRewardsPayouts


```solidity
function getStakingRewardsPayouts(uint256 _validatorId) external view returns (uint256, uint256, uint256, uint256);
```

### getRewardsPayouts


```solidity
function getRewardsPayouts(uint256 _validatorId, bool _stakingRewards, bool _protocolRewards, bool _vestedAuctionFee)
    external
    view
    returns (uint256, uint256, uint256, uint256);
```

### getFullWithdrawalPayouts


```solidity
function getFullWithdrawalPayouts(uint256 _validatorId) external view returns (uint256, uint256, uint256, uint256);
```

### incrementNumberOfValidators


```solidity
function incrementNumberOfValidators(uint256 _count) external;
```

### createEtherfiNode


```solidity
function createEtherfiNode(uint256 _validatorId) external returns (address);
```

### registerEtherFiNode


```solidity
function registerEtherFiNode(uint256 _validatorId, address _address) external;
```

### unregisterEtherFiNode


```solidity
function unregisterEtherFiNode(uint256 _validatorId) external;
```

### setEtherFiNodePhase


```solidity
function setEtherFiNodePhase(uint256 _validatorId, IEtherFiNode.VALIDATOR_PHASE _phase) external;
```

### setEtherFiNodeIpfsHashForEncryptedValidatorKey


```solidity
function setEtherFiNodeIpfsHashForEncryptedValidatorKey(uint256 _validatorId, string calldata _ipfs) external;
```

### setEtherFiNodeLocalRevenueIndex


```solidity
function setEtherFiNodeLocalRevenueIndex(uint256 _validatorId, uint256 _localRevenueIndex) external payable;
```

### sendExitRequest


```solidity
function sendExitRequest(uint256 _validatorId) external;
```

### processNodeExit


```solidity
function processNodeExit(uint256[] calldata _validatorIds, uint32[] calldata _exitTimestamp) external;
```

### partialWithdraw


```solidity
function partialWithdraw(uint256 _validatorId, bool _stakingRewards, bool _protocolRewards, bool _vestedAuctionFee)
    external;
```

### partialWithdraw


```solidity
function partialWithdraw(
    uint256[] calldata _validatorIds,
    bool _stakingRewards,
    bool _protocolRewards,
    bool _vestedAuctionFee
) external;
```

### partialWithdrawBatchGroupByOperator


```solidity
function partialWithdrawBatchGroupByOperator(
    address _operator,
    uint256[] memory _validatorIds,
    bool _stakingRewards,
    bool _protocolRewards,
    bool _vestedAuctionFee
) external;
```

### fullWithdraw


```solidity
function fullWithdraw(uint256 _validatorId) external;
```

### fullWithdrawBatch


```solidity
function fullWithdrawBatch(uint256[] calldata _validatorIds) external;
```

## Structs
### RewardsSplit

```solidity
struct RewardsSplit {
    uint64 treasury;
    uint64 nodeOperator;
    uint64 tnft;
    uint64 bnft;
}
```

## Enums
### ValidatorRecipientType

```solidity
enum ValidatorRecipientType {
    TNFTHOLDER,
    BNFTHOLDER,
    TREASURY,
    OPERATOR
}
```

