# TNFT
[Git Source](https://github.com/GadzeFinance/dappContracts/blob/c722006f91e5a8b00322356d0c967de90bbae6e0/src/TNFT.sol)

**Inherits:**
ERC721


## State Variables
### tokenIds

```solidity
uint256 private tokenIds;
```


### nftValue

```solidity
uint256 public nftValue;
```


### stakingManagerContractAddress

```solidity
address public stakingManagerContractAddress;
```


## Functions
### constructor


```solidity
constructor() ERC721("Transferrable NFT", "TNFT");
```

### mint


```solidity
function mint(address _reciever, uint256 _validatorId) external onlyStakingManagerContract;
```

### onlyStakingManagerContract


```solidity
modifier onlyStakingManagerContract();
```

