# StakingManager
[Git Source](https://github.com/GadzeFinance/dappContracts/blob/c722006f91e5a8b00322356d0c967de90bbae6e0/src/StakingManager.sol)

**Inherits:**
[IStakingManager](/src/interfaces/IStakingManager.sol/interface.IStakingManager.md), Ownable, Pausable, ReentrancyGuard


## State Variables
### test
*please remove before mainnet deployment*


```solidity
bool public test = true;
```


### maxBatchDepositSize

```solidity
uint256 public maxBatchDepositSize = 16;
```


### TNFTInterfaceInstance

```solidity
ITNFT public TNFTInterfaceInstance;
```


### BNFTInterfaceInstance

```solidity
IBNFT public BNFTInterfaceInstance;
```


### auctionInterfaceInstance

```solidity
IAuctionManager public auctionInterfaceInstance;
```


### depositContractEth2

```solidity
IDepositContract public depositContractEth2;
```


### nodesManagerIntefaceInstance

```solidity
IEtherFiNodesManager public nodesManagerIntefaceInstance;
```


### protocolRevenueManager

```solidity
IProtocolRevenueManager protocolRevenueManager;
```


### stakeAmount

```solidity
uint256 public stakeAmount;
```


### treasuryAddress

```solidity
address public treasuryAddress;
```


### auctionAddress

```solidity
address public auctionAddress;
```


### nodesManagerAddress

```solidity
address public nodesManagerAddress;
```


### tnftContractAddress

```solidity
address public tnftContractAddress;
```


### bnftContractAddress

```solidity
address public bnftContractAddress;
```


### bidIdToStaker

```solidity
mapping(uint256 => address) public bidIdToStaker;
```


## Functions
### constructor

Constructor to set variables on deployment

*Deploys NFT contracts internally to ensure ownership is set to this contract*

*AuctionManager contract must be deployed first*


```solidity
constructor(address _auctionAddress);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_auctionAddress`|`address`|the address of the auction contract for interaction|


### switchMode

Switches the deposit mode of the contract

*Used for testing purposes. WILL BE DELETED BEFORE MAINNET DEPLOYMENT*


```solidity
function switchMode() public;
```

### registerTnftContract


```solidity
function registerTnftContract() private returns (address);
```

### registerBnftContract


```solidity
function registerBnftContract() private returns (address);
```

### batchDepositWithBidIds


```solidity
function batchDepositWithBidIds(uint256[] calldata _candidateBidIds)
    external
    payable
    whenNotPaused
    correctStakeAmount
    nonReentrant
    returns (uint256[] memory);
```

### registerValidator

Creates validator object, mints NFTs, sets NB variables and deposits into beacon chain


```solidity
function registerValidator(uint256 _validatorId, DepositData calldata _depositData) public whenNotPaused;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_validatorId`|`uint256`|id of the validator to register|
|`_depositData`|`DepositData`|data structure to hold all data needed for depositing to the beacon chain|


### batchRegisterValidators

Creates validator object, mints NFTs, sets NB variables and deposits into beacon chain


```solidity
function batchRegisterValidators(uint256[] calldata _validatorId, DepositData[] calldata _depositData)
    public
    whenNotPaused;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_validatorId`|`uint256[]`|id of the validator to register|
|`_depositData`|`DepositData[]`|data structure to hold all data needed for depositing to the beacon chain|


### cancelDeposit

Cancels a users stake

*Only allowed to be cancelled before step 2 of the depositing process*


```solidity
function cancelDeposit(uint256 _validatorId) public whenNotPaused;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_validatorId`|`uint256`|the ID of the validator deposit to cancel|


### fetchEtherFromContract

Allows withdrawal of funds from contract

*Will be removed in final version*


```solidity
function fetchEtherFromContract(address _wallet) public onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_wallet`|`address`|the address to send the funds to|


### setEtherFiNodesManagerAddress


```solidity
function setEtherFiNodesManagerAddress(address _nodesManagerAddress) public onlyOwner;
```

### setTreasuryAddress


```solidity
function setTreasuryAddress(address _treasuryAddress) public onlyOwner;
```

### setProtocolRevenueManager


```solidity
function setProtocolRevenueManager(address _protocolRevenueManager) public onlyOwner;
```

### setMaxBatchDepositSize


```solidity
function setMaxBatchDepositSize(uint256 _newMaxBatchDepositSize) public onlyOwner;
```

### pauseContract


```solidity
function pauseContract() external onlyOwner;
```

### unPauseContract


```solidity
function unPauseContract() external onlyOwner;
```

### uncheckedInc


```solidity
function uncheckedInc(uint256 x) private pure returns (uint256);
```

### processDeposit

Update the state of the contract now that a deposit has been made


```solidity
function processDeposit(uint256 _bidId) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_bidId`|`uint256`|the bid that won the right to the deposit|


### _refundDeposit

Refunds the depositor their staked ether for a specific stake

*Gets called internally from cancelStakingManager or when the time runs out for calling registerValidator*


```solidity
function _refundDeposit(address _depositOwner, uint256 _amount) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_depositOwner`|`address`|address of the user being refunded|
|`_amount`|`uint256`|the amount to refund the depositor|


### correctStakeAmount


```solidity
modifier correctStakeAmount();
```

## Events
### StakeDeposit

```solidity
event StakeDeposit(address indexed staker, uint256 bidId, address withdrawSafe);
```

### DepositCancelled

```solidity
event DepositCancelled(uint256 id);
```

### ValidatorRegistered

```solidity
event ValidatorRegistered(address indexed operator, uint256 validatorId, string ipfsHashForEncryptedValidatorKey);
```

