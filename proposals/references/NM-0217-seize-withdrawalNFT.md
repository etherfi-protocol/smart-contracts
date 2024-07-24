# NM-0217 - EtherFi - Seize WithdrawalNFT

## Files:
- [PR](https://github.com/etherfi-protocol/smart-contracts/pull/61/files)

## Questions

### Confussion between `eETHAmount` and `eETHShares`

Multiple function used through the withdrawal flow use these two arguments. I am not fully sure about these two variables and their definition. I have collected a couple of doubts about their use.

My understanding from reading the code is that `eETHAmount` refers to an amount of `ETH` that the user is trying to withdraw and `eETHShares` refers to the amount of shares that are equivalent to that amount at the moment of withdrawl.

I have a couple of points that I am not sure if are issues, but might be and are related to these values.

The `withdraw(...)` function in `LiquidityPool.sol` contract contains the following check 

```solidity
// @audit - Should not this be < shares?
if (totalValueInLp < _amount || (msg.sender == address(withdrawRequestNFT) && ethAmountLockedForWithdrawal < _amount) || eETH.balanceOf(msg.sender) < _amount) revert InsufficientLiquidity(); 
```

The third condition of this expression is `eETH.balanceOf(msg.sender) < _amount`, amuont if the desired amount of `ETH` to be withdrawn, however it is compared to amount of `eETH`. Should not `share` be used instead of `amount`?


The `requestWithdrawal(...)` function in the `LiquidityPool.sol` contract transfer `amount` of `eETH`. Should it not transfer `share` instead which is the value measured in `eETH`?

```solidity
eETH.transferFrom(msg.sender, address(withdrawRequestNFT), amount);
```


---

### Use of `reduceEthAmountLockedForWithdrawal(...)` function

This function is used when seizing a `WithdrawalNFT` token. The function is called independently if `reduceEthAmountLockedForWithdrawal(...)` was called or not when the request was made `invalid`. Could you please elaborate on how the `ethAmountLockedForWithdrawal` should behave and in which flows it should be modified?

---

### Full withdrawal flows

I would like to clarify the full flow for withdrawing from the `LiquidityPool`. This is my current understanding:

- User calls `LiquidityPool.requestWithdrawal`.
- When withrawal process is completed for the required validator, the EtherFi admin must call `WithdrawRequestNFT.finalizeRequest(...)` and `LiquidityPool.addEthAmountLockedForWithdrawal(...)` functions.
- User now can call `claimWithdraw(...)` function that will execute the withdrawal.



The current PR allows for the following 2 flows:

1. Request was not finalized before NFT was lost:

    - User calls `LiquidityPool.requestWithdrawal`.
    - `WithdrawalNFT` is stolen.
    - EtherFi admin calls `WithdrawRequestNFT.invalidateRequest(...)`
    - When withrawal process is completed for the required validator, the EtherFi admin must call `WithdrawRequestNFT.finalizeRequest(...)` and `LiquidityPool.addEthAmountLockedForWithdrawal(...)` functions.
    - EtherFi admin calls `WithdrawRequestNFT.seizeInvalidRequest(...)`.
2. Request was already finalized when the NFT was lost:
    - User calls `LiquidityPool.requestWithdrawal`.
    - When withrawal process is completed for the required validator, the EtherFi admin must call `WithdrawRequestNFT.finalizeRequest(...)` and `LiquidityPool.addEthAmountLockedForWithdrawal(...)` functions.
    - `WithdrawalNFT` is stolen.
    - EtherFi admin calls `WithdrawRequestNFT.invalidateRequest(...)` before attacker claims the the withdrawal.
    - EtherFi admin calls `WithdrawRequestNFT.seizeInvalidRequest(...)`.


---

## Findings

**The Nethermind team has not found any issue in this feature during past reviews**




