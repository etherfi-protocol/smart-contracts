# ConversionPool
[Git Source](https://github.com/GadzeFinance/dappContracts/blob/c722006f91e5a8b00322356d0c967de90bbae6e0/src/ClaimReceiverPool.sol)

**Inherits:**
Ownable, ReentrancyGuard, Pausable


## State Variables
### poolFee

```solidity
uint24 public constant poolFee = 500;
```


### wEth

```solidity
address private immutable wEth;
```


### rETH

```solidity
address private immutable rETH;
```


### wstETH

```solidity
address private immutable wstETH;
```


### sfrxETH

```solidity
address private immutable sfrxETH;
```


### cbETH

```solidity
address private immutable cbETH;
```


### swapRouter

```solidity
ISwapRouter public immutable swapRouter;
```


### wethContract

```solidity
IWETH public wethContract;
```


### adopterPool

```solidity
EarlyAdopterPool public adopterPool;
```


### userToERC20Deposit

```solidity
mapping(address => mapping(address => uint256)) public userToERC20Deposit;
```


### etherBalance

```solidity
mapping(address => uint256) public etherBalance;
```


### userPoints

```solidity
mapping(address => uint256) public userPoints;
```


## Functions
### constructor


```solidity
constructor(
    address _routerAddress,
    address _adopterPool,
    address _rEth,
    address _wstEth,
    address _sfrxEth,
    address _cbEth,
    address _wEth
);
```

### setPointsData


```solidity
function setPointsData(address _user, uint256 _points) external;
```

### depositEther


```solidity
function depositEther() external payable;
```

### depositERC20


```solidity
function depositERC20(address _erc20Contract, uint256 _amount) external;
```

### pauseContract


```solidity
function pauseContract() external onlyOwner;
```

### unPauseContract


```solidity
function unPauseContract() external onlyOwner;
```

### _swapExactInputSingle


```solidity
function _swapExactInputSingle(uint256 _amountIn, address _tokenIn) internal returns (uint256 amountOut);
```

