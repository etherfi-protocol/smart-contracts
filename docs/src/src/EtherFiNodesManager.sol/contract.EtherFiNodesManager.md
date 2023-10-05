# EtherFiNodesManager
[Git Source](https://github.com/GadzeFinance/dappContracts/blob/c722006f91e5a8b00322356d0c967de90bbae6e0/src/EtherFiNodesManager.sol)

**Inherits:**
[IEtherFiNodesManager](/src/interfaces/IEtherFiNodesManager.sol/interface.IEtherFiNodesManager.md)


## State Variables
### nonExitPenaltyPrincipal

```solidity
uint256 private constant nonExitPenaltyPrincipal = 1 ether;
```


### nonExitPenaltyDailyRate

```solidity
uint256 private constant nonExitPenaltyDailyRate = 3;
```


### implementationContract

```solidity
address public immutable implementationContract;
```


### numberOfValidators

```solidity
uint256 public numberOfValidators;
```


### owner

```solidity
address public owner;
```


### treasuryContract

```solidity
address public treasuryContract;
```


### auctionContract

```solidity
address public auctionContract;
```


### stakingManagerContract

```solidity
address public stakingManagerContract;
```


### protocolRevenueManagerContract

```solidity
address public protocolRevenueManagerContract;
```


### etherfiNodeAddress

```solidity
mapping(uint256 => address) public etherfiNodeAddress;
```


### tnftInstance

```solidity
TNFT public tnftInstance;
```


### bnftInstance

```solidity
BNFT public bnftInstance;
```


### stakingManagerInstance

```solidity
IStakingManager public stakingManagerInstance;
```


### auctionInterfaceInstance

```solidity
IAuctionManager public auctionInterfaceInstance;
```


### protocolRevenueManagerInstance

```solidity
IProtocolRevenueManager public protocolRevenueManagerInstance;
```


### SCALE

```solidity
uint256 public constant SCALE = 1000000;
```


### stakingRewardsSplit

```solidity
RewardsSplit public stakingRewardsSplit;
```


### protocolRewardsSplit

```solidity
RewardsSplit public protocolRewardsSplit;
```


## Functions
### constructor

Constructor to set variables on deployment

*Sets the revenue splits on deployment*

*AuctionManager, treasury and deposit contracts must be deployed first*


```solidity
constructor(
    address _treasuryContract,
    address _auctionContract,
    address _stakingManagerContract,
    address _tnftContract,
    address _bnftContract,
    address _protocolRevenueManagerContract
);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_treasuryContract`|`address`|the address of the treasury contract for interaction|
|`_auctionContract`|`address`|the address of the auction contract for interaction|
|`_stakingManagerContract`|`address`|the address of the deposit contract for interaction|
|`_tnftContract`|`address`||
|`_bnftContract`|`address`||
|`_protocolRevenueManagerContract`|`address`||


### receive


```solidity
receive() external payable;
```

### createEtherfiNode


```solidity
function createEtherfiNode(uint256 _validatorId) external returns (address);
```

### registerEtherFiNode

Sets the validator ID for the EtherFiNode contract


```solidity
function registerEtherFiNode(uint256 _validatorId, address _address) public onlyStakingManagerContract;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_validatorId`|`uint256`|id of the validator associated to the node|
|`_address`|`address`|address of the EtherFiNode contract|


### unregisterEtherFiNode

UnSet the EtherFiNode contract for the validator ID


```solidity
function unregisterEtherFiNode(uint256 _validatorId) public onlyStakingManagerContract;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_validatorId`|`uint256`|id of the validator associated|


### sendExitRequest

send the request to exit the validator node


```solidity
function sendExitRequest(uint256 _validatorId) external;
```

### processNodeExit

Once the node's exit is observed, the protocol calls this function:
For each node,
- mark it EXITED
- distribute the protocol (auction) revenue
- stop sharing the protocol revenue; by setting their local revenue index to '0'


```solidity
function processNodeExit(uint256[] calldata _validatorIds, uint32[] calldata _exitTimestamps) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_validatorIds`|`uint256[]`|the list of validators which exited|
|`_exitTimestamps`|`uint32[]`|the list of exit timestamps of the validators|


### partialWithdraw

process the rewards skimming


```solidity
function partialWithdraw(uint256 _validatorId, bool _stakingRewards, bool _protocolRewards, bool _vestedAuctionFee)
    public;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_validatorId`|`uint256`|the validator Id|
|`_stakingRewards`|`bool`||
|`_protocolRewards`|`bool`||
|`_vestedAuctionFee`|`bool`||


### partialWithdraw

batch-process the rewards skimming


```solidity
function partialWithdraw(
    uint256[] calldata _validatorIds,
    bool _stakingRewards,
    bool _protocolRewards,
    bool _vestedAuctionFee
) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_validatorIds`|`uint256[]`|a list of the validator Ids|
|`_stakingRewards`|`bool`||
|`_protocolRewards`|`bool`||
|`_vestedAuctionFee`|`bool`||


### partialWithdrawBatchGroupByOperator

batch-process the rewards skimming for the validator nodes belonging to the same operator


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

process the full withdrawal


```solidity
function fullWithdraw(uint256 _validatorId) public;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_validatorId`|`uint256`|the validator Id|


### fullWithdrawBatch

process the full withdrawal


```solidity
function fullWithdrawBatch(uint256[] calldata _validatorIds) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_validatorIds`|`uint256[]`|the validator Ids|


### setEtherFiNodePhase

Sets the phase of the validator


```solidity
function setEtherFiNodePhase(uint256 _validatorId, IEtherFiNode.VALIDATOR_PHASE _phase)
    public
    onlyStakingManagerContract;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_validatorId`|`uint256`|id of the validator associated to this withdraw safe|
|`_phase`|`VALIDATOR_PHASE.IEtherFiNode`|phase of the validator|


### setEtherFiNodeIpfsHashForEncryptedValidatorKey

Sets the ipfs hash of the validator's encrypted private key


```solidity
function setEtherFiNodeIpfsHashForEncryptedValidatorKey(uint256 _validatorId, string calldata _ipfs)
    external
    onlyStakingManagerContract;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_validatorId`|`uint256`|id of the validator associated to this withdraw safe|
|`_ipfs`|`string`|ipfs hash|


### incrementNumberOfValidators


```solidity
function incrementNumberOfValidators(uint256 _count) external onlyStakingManagerContract;
```

### phase


```solidity
function phase(uint256 _validatorId) public view returns (IEtherFiNode.VALIDATOR_PHASE phase);
```

### ipfsHashForEncryptedValidatorKey


```solidity
function ipfsHashForEncryptedValidatorKey(uint256 _validatorId) external view returns (string memory);
```

### localRevenueIndex


```solidity
function localRevenueIndex(uint256 _validatorId) external view returns (uint256);
```

### vestedAuctionRewards


```solidity
function vestedAuctionRewards(uint256 _validatorId) external returns (uint256);
```

### generateWithdrawalCredentials


```solidity
function generateWithdrawalCredentials(address _address) public pure returns (bytes memory);
```

### getWithdrawalCredentials


```solidity
function getWithdrawalCredentials(uint256 _validatorId) external view returns (bytes memory);
```

### isExitRequested


```solidity
function isExitRequested(uint256 _validatorId) external view returns (bool);
```

### getNonExitPenalty


```solidity
function getNonExitPenalty(uint256 _validatorId, uint32 _endTimestamp) public view returns (uint256);
```

### getStakingRewardsPayouts


```solidity
function getStakingRewardsPayouts(uint256 _validatorId) public view returns (uint256, uint256, uint256, uint256);
```

### getRewardsPayouts


```solidity
function getRewardsPayouts(uint256 _validatorId, bool _stakingRewards, bool _protocolRewards, bool _vestedAuctionFee)
    public
    view
    returns (uint256, uint256, uint256, uint256);
```

### getFullWithdrawalPayouts


```solidity
function getFullWithdrawalPayouts(uint256 _validatorId) public view returns (uint256, uint256, uint256, uint256);
```

### isExited


```solidity
function isExited(uint256 _validatorId) external view returns (bool);
```

### onlyOwner


```solidity
modifier onlyOwner();
```

### onlyStakingManagerContract


```solidity
modifier onlyStakingManagerContract();
```

### onlyProtocolRevenueManagerContract


```solidity
modifier onlyProtocolRevenueManagerContract();
```

## Events
### FundsWithdrawn

```solidity
event FundsWithdrawn(uint256 indexed _validatorId, uint256 amount);
```

### NodeExitRequested

```solidity
event NodeExitRequested(uint256 _validatorId);
```

