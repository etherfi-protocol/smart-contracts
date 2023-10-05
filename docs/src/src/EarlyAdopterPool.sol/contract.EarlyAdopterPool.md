# EarlyAdopterPool
[Git Source](https://github.com/GadzeFinance/dappContracts/blob/c722006f91e5a8b00322356d0c967de90bbae6e0/src/EarlyAdopterPool.sol)

**Inherits:**
Ownable, ReentrancyGuard, Pausable


## State Variables
### claimDeadline

```solidity
uint256 public claimDeadline;
```


### endTime

```solidity
uint256 public endTime;
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


### claimReceiverContract

```solidity
address public claimReceiverContract;
```


### claimingOpen

```solidity
uint8 public claimingOpen;
```


### userToErc20Balance

```solidity
mapping(address => mapping(address => uint256)) public userToErc20Balance;
```


### depositInfo

```solidity
mapping(address => UserDepositInfo) public depositInfo;
```


### rETHInstance

```solidity
IERC20 rETHInstance;
```


### wstETHInstance

```solidity
IERC20 wstETHInstance;
```


### sfrxETHInstance

```solidity
IERC20 sfrxETHInstance;
```


### cbETHInstance

```solidity
IERC20 cbETHInstance;
```


## Functions
### receive

Allows ether to be sent to this contract


```solidity
receive() external payable;
```

### constructor

Sets state variables needed for future functions


```solidity
constructor(address _rETH, address _wstETH, address _sfrxETH, address _cbETH);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_rETH`|`address`|address of the rEth contract to receive|
|`_wstETH`|`address`|address of the wstEth contract to receive|
|`_sfrxETH`|`address`|address of the sfrxEth contract to receive|
|`_cbETH`|`address`|address of the _cbEth contract to receive|


### deposit

deposits ERC20 tokens into contract

*User must have approved contract before*


```solidity
function deposit(address _erc20Contract, uint256 _amount)
    external
    OnlyCorrectAmount(_amount)
    DepositingOpen
    whenNotPaused;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_erc20Contract`|`address`|erc20 token contract being deposited|
|`_amount`|`uint256`|amount of the erc20 token being deposited|


### depositEther

deposits Ether into contract


```solidity
function depositEther() external payable OnlyCorrectAmount(msg.value) DepositingOpen whenNotPaused;
```

### withdraw

withdraws all funds from pool for the user calling

*no points allocated to users who withdraw*


```solidity
function withdraw() public nonReentrant;
```

### claim

Transfers users funds to a new contract such as LP

*can only call once receiver contract is ready and claiming is open*


```solidity
function claim() public nonReentrant;
```

### setClaimingOpen

Sets claiming to be open, to allow users to claim their points


```solidity
function setClaimingOpen(uint256 _claimDeadline) public onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_claimDeadline`|`uint256`|the amount of time in days until claiming will close|


### setClaimReceiverContract

Set the contract which will receive claimed funds


```solidity
function setClaimReceiverContract(address _receiverContract) public onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_receiverContract`|`address`|contract address for where claiming will send the funds|


### calculateUserPoints

Calculates how many points a user currently has owed to them


```solidity
function calculateUserPoints(address _user) public view returns (uint256);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|the amount of points a user currently has accumulated|


### pauseContract


```solidity
function pauseContract() external onlyOwner;
```

### unPauseContract


```solidity
function unPauseContract() external onlyOwner;
```

### transferFunds

Transfers funds to relevant parties and updates data structures


```solidity
function transferFunds(uint256 _identifier) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_identifier`|`uint256`|identifies which contract function called the function|


### getContractTVL

*Returns the total value locked of all currencies in contract*


```solidity
function getContractTVL() public view returns (uint256 tvl);
```

### getUserTVL


```solidity
function getUserTVL(address _user)
    public
    view
    returns (uint256 rETHBal, uint256 wstETHBal, uint256 sfrxETHBal, uint256 cbETHBal, uint256 ethBal, uint256 totalBal);
```

### OnlyCorrectAmount


```solidity
modifier OnlyCorrectAmount(uint256 _amount);
```

### DepositingOpen


```solidity
modifier DepositingOpen();
```

## Events
### DepositERC20

```solidity
event DepositERC20(address indexed sender, uint256 amount);
```

### DepositEth

```solidity
event DepositEth(address indexed sender, uint256 amount);
```

### Withdrawn

```solidity
event Withdrawn(address indexed sender);
```

### ClaimReceiverContractSet

```solidity
event ClaimReceiverContractSet(address indexed receiverAddress);
```

### ClaimingOpened

```solidity
event ClaimingOpened(uint256 deadline);
```

### Fundsclaimed

```solidity
event Fundsclaimed(address indexed user, uint256 indexed pointsAccumulated);
```

### ERC20TVLUpdated

```solidity
event ERC20TVLUpdated(
    uint256 rETHBal, uint256 wstETHBal, uint256 sfrxETHBal, uint256 cbETHBal, uint256 ETHBal, uint256 tvl
);
```

### EthTVLUpdated

```solidity
event EthTVLUpdated(uint256 ETHBal, uint256 tvl);
```

## Structs
### UserDepositInfo

```solidity
struct UserDepositInfo {
    uint256 depositTime;
    uint256 etherBalance;
    uint256 totalERC20Balance;
}
```

