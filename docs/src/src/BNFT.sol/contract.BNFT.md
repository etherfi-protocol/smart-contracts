# BNFT
[Git Source](https://github.com/GadzeFinance/dappContracts/blob/c722006f91e5a8b00322356d0c967de90bbae6e0/src/BNFT.sol)

**Inherits:**
ERC721


## State Variables
### tokenIds

```solidity
uint256 private tokenIds;
```


### nftValue

```solidity
uint256 public nftValue = 0.002 ether;
```


### stakingManagerContractAddress

```solidity
address public stakingManagerContractAddress;
```


## Functions
### constructor


```solidity
constructor() ERC721("Bond NFT", "BNFT");
```

### mint


```solidity
function mint(address _reciever, uint256 _validatorId) external onlyStakingManagerContract;
```

### transferFrom


```solidity
function transferFrom(address from, address to, uint256 tokenId) public virtual override(ERC721);
```

### onlyStakingManagerContract


```solidity
modifier onlyStakingManagerContract();
```

