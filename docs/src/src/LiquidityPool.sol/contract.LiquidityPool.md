# LiquidityPool
[Git Source](https://github.com/GadzeFinance/dappContracts/blob/c722006f91e5a8b00322356d0c967de90bbae6e0/src/LiquidityPool.sol)

**Inherits:**
Ownable


## State Variables
### eETH

```solidity
address public eETH;
```


## Functions
### constructor

initializes owner address


```solidity
constructor();
```

### setTokenAddress

sets the contract address for eETH

*can't do it in constructor due to circular dependencies*


```solidity
function setTokenAddress(address _eETH) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_eETH`|`address`|address of eETH contract|


### deposit

deposit into pool

*mints the amount of eTH 1:1 with ETH sent*


```solidity
function deposit() external payable;
```

### withdraw

withdraw from pool

*Burns user balance from msg.senders account & Sends equal amount of ETH back to user*


```solidity
function withdraw(uint256 _amount) external payable;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_amount`|`uint256`|the amount to withdraw from contract|


### receive

Allows ether to be sent to this contract


```solidity
receive() external payable;
```

## Events
### Received

```solidity
event Received(address indexed sender, uint256 value);
```

### TokenAddressChanged

```solidity
event TokenAddressChanged(address indexed newAddress);
```

### Deposit

```solidity
event Deposit(address indexed sender, uint256 amount);
```

### Withdraw

```solidity
event Withdraw(address indexed sender, uint256 amount);
```

