# EETH
[Git Source](https://github.com/GadzeFinance/dappContracts/blob/c722006f91e5a8b00322356d0c967de90bbae6e0/src/EETH.sol)

**Inherits:**
ERC20


## State Variables
### liquidityPool

```solidity
address public liquidityPool;
```


## Functions
### constructor


```solidity
constructor(address _liquidityPool) ERC20("EtherFi ETH", "eETH");
```

### mint

function to mint eETH

*only able to mint from LiquidityPool contract*


```solidity
function mint(address _account, uint256 _amount) external onlyPoolContract;
```

### burn

function to burn eETH

*only able to burn from LiquidityPool contract*


```solidity
function burn(address _account, uint256 _amount) external onlyPoolContract;
```

### onlyPoolContract


```solidity
modifier onlyPoolContract();
```

