---
title: 'Liquifier: pricing of stETH via CurvePool & fixed rate fee'

---

# Liquifier: pricing of stETH via CurvePool & fixed rate fee

**PR**: https://github.com/etherfi-protocol/smart-contracts/pull/188

## Summary

This PR adds the option to price `stETH` via a `ETH/stETH` Curve pool. Additionally, it adds the option of applying a fixed rate fee in the `depositWithERC20(...)` function. 

---

## Findings

### [Medium] Spot prices from Curve can be manipulated

**File(s)**: [`Liquifier.sol`](https://github.com/etherfi-protocol/smart-contracts/blob/1f95dcd0677f7ffa387e70c2240981c478a701b2/src/Liquifier.sol#L404)

**Description**: The use of `CurvePool` as quoter has the goal of `removing the ability to swap stEth/eETH 1:1 without slippage`. To get the price from the `CurvePool` the `get_dy(...)` function is used.

```solidity
...
if (_token == address(lido)) {
    if (quoteStEthWithCurve) {
        return _min(_amount, ICurvePoolQuoter1(address(stEth_Eth_Pool)).get_dy(1, 0, _amount));
    } else {
        return _amount; /// 1:1 from stETH to eETH
    }
...
```

The `get_dy(...)` function returns the result of swapping `amount` of tokens at the current state of the pool. The result of this function can be easily manipulated by swapping in the `CurvePool`. The returned value could be manipulated to still enforce the use of a `1:1` rate.

**Recommendation(s)**: Consider using a different method to quote the `stEth` that is not easily manipulable. The use of other oracle solutions like `TWAPs` or `Chainlink Oracles` is recommended. 

**Status**: Unresolved

**Update from the client**: