---
title: NM-0217 - EtherFi Deposit Adapter Contract

---

# NM-0217 - EtherFi Deposit Adapter Contract

**File(s)**: [DepositAdapter.sol](https://github.com/etherfi-protocol/smart-contracts/blob/a769cae4951594d6a1c1147387376ce8a24eb360/src/DepositAdapter.sol)

### Summary

The Deposit Adapter contract introduces a new functionality that allows atomic swaps to `weETH` from `ETH, wETH, stETH or wstETH`.

---

### Findings

### [Low] The `depositStETHForWeETHWithPermit` and `depositWstETHForWeETHWithPermit` functions do not account the 1 wei corner case of Lido's `stEth`

**File(s)**: [DepositAdapter.sol](https://github.com/etherfi-protocol/smart-contracts/blob/a769cae4951594d6a1c1147387376ce8a24eb360/src/DepositAdapter.sol#L86)

**Description**: It is a known issue that Lido's `stETH` transfers are off by 1 wei. This means that the actual amount deposited into the protocol through the `depositStETHForWeETHWithPermit` and `depositWstETHForWeETHWithPermit` functions will be `amount - 2 wei` because the deposit process involves two transfers. The first one from `msg.sender -> DepositAdapter` contract and the 2nd one from the `DepositAdapter -> Liquifier` contract. The protocol doesn't account the 2 wei which are lost in the process.

As a side note, the test `DepositAdapter.t.sol::test_DepositStETH` fails because it expects the amount to be off by 1 wei, but the amount is actually off by 2 wei because the depositing flow involves two transfers as explained above. [This assertion](https://github.com/etherfi-protocol/smart-contracts/blob/a769cae4951594d6a1c1147387376ce8a24eb360/test/DepositAdapter.t.sol#L103) fails.

**Recommendation(s)**: Consider adding a check for the balance before and after the transfer in order to maintain 100% accuracy.

**Update from client**:
https://github.com/etherfi-protocol/smart-contracts/pull/169

---

### [Info] Ether sent directly into the contract will be stuck

**File(s)**: [DepositAdapter.sol](https://github.com/etherfi-protocol/smart-contracts/blob/a769cae4951594d6a1c1147387376ce8a24eb360/src/DepositAdapter.sol#L116)

**Description**: The contract implements a `receive` function because it needs it in order to fulfill the swaps. Having this `receive` function allows any user to deposit Ether into the contract, but there is no way to withdraw it from the contract, so the Ether will be stuck.

**Recommendation(s)**: To prevent accidental loss of funds, the `receive` function can be changed to only accept Ether if it comes from one of the expected sources, like the WETH contract for example.

**Update from client**:
https://github.com/etherfi-protocol/smart-contracts/pull/170

---

### [Info] Ignoring the result of the `permit` function call

**File(s)**: [DepositAdapter.sol](https://github.com/etherfi-protocol/smart-contracts/blob/a769cae4951594d6a1c1147387376ce8a24eb360/src/DepositAdapter.sol#L86)

**Description**: The `depositWstETHForWeETHWithPermit` and the `depositStETHForWeETHWithPermit` functions allow users to deposits through permits. The calls to the `permit` functions are inside `try-catch` blocks. Because of this, the result of the call to the `permit` function is ignored. For example, if the permit is expired (the deadline passed), the call will proceed normally provided that we have sufficient allowance left.

We wrote a test for this that you can add in the `DepositAdapter.t.sol`

```solidity
    function test_DepositPermitExpired() public {
        stEth.submit{value: 2 ether}(address(0));

        // valid input
        uint256 protocolStETHBeforeDeposit = stEth.balanceOf(address(liquifierInstance));
        uint256 stEthBalanceBeforeDeposit = stEth.balanceOf(address(alice));
        
        ILiquidityPool.PermitInput memory permitInput = createPermitInput(
            2,
            address(depositAdapterInstance),
            2 ether,
            stEth.nonces(alice),
            2 ** 32 - 1,
            stEth.DOMAIN_SEPARATOR()
        );
        
        ILiquifier.PermitInput memory liquifierPermitInput = ILiquifier.PermitInput({
            value: permitInput.value,
            deadline: permitInput.deadline,
            v: permitInput.v,
            r: permitInput.r,
            s: permitInput.s
        });
        
        //record timestamp and deadline before warp
        uint blockTimestampBefore = block.timestamp;
        uint permitDeadline = permitInput.deadline;
        console.log("Block Timestamp Before:", blockTimestampBefore);
        console.log("Permit Deadline:", permitDeadline);
        depositAdapterInstance.depositStETHForWeETHWithPermit(1 ether, bob, liquifierPermitInput);

        assertApproxEqAbs(stEth.balanceOf(address(alice)), stEthBalanceBeforeDeposit - 1 ether, 2);
        assertApproxEqAbs(weEthInstance.balanceOf(address(alice)), weEthInstance.getWeETHByeETH(1 ether), 2);
        assertApproxEqAbs(stEth.balanceOf(address(liquifierInstance)), protocolStETHBeforeDeposit + 1 ether, 2);

        vm.warp(block.timestamp + permitDeadline + 1 days);
        
        //record timestamp and deadline after warp
        uint blockTimestampAfter = block.timestamp;
        console.log("Block Timestamp After:", blockTimestampAfter);
        console.log("Permit Deadline:", permitDeadline);
        depositAdapterInstance.depositStETHForWeETHWithPermit(1 ether, bob, liquifierPermitInput);
    }
```

Test output

```javascript
Logs:
  Block Timestamp Before: 1726217663
  Permit Deadline:        4294967295
  Block Timestamp After: 6021271358
  Permit Deadline:       4294967295

Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 17.90s (10.10s CPU time)

Ran 1 test suite in 18.87s (17.90s CPU time): 1 tests passed, 0 failed, 0 skipped (1 total tests)
```



**Recommendation(s)**: In order to prevent this the `catch` block can check if the deadline is still valid. For added security, you can also add a check for the allowance in the `catch` block to make sure that `allowance > _amount`.

**Update from client**:

https://github.com/etherfi-protocol/smart-contracts/pull/171