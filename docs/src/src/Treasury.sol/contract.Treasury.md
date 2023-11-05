# Treasury
[Git Source](https://github.com/GadzeFinance/dappContracts/blob/c722006f91e5a8b00322356d0c967de90bbae6e0/src/Treasury.sol)

**Inherits:**
[ITreasury](/src/interfaces/ITreasury.sol/interface.ITreasury.md), Ownable


## Functions
### withdraw

Function allows only the owner to withdraw all the funds in the contract


```solidity
function withdraw(uint256 _amount) external onlyOwner;
```

### receive


```solidity
receive() external payable;
```

