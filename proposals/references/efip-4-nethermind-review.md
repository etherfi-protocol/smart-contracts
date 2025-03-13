# [EFIP-4] Processing staking to {Treasury, Node Operators} in eETH

**File(s)**: [EtherFiOracleExecutor.sol](https://github.com/etherfi-protocol/smart-contracts/blob/9cae955d2e897cb5e8bf5266a0de22da73f1ac99/src/EtherFiOracleExecutor.sol#L20), [EtherFiOracle.sol](https://github.com/etherfi-protocol/smart-contracts/blob/9cae955d2e897cb5e8bf5266a0de22da73f1ac99/src/EtherFiOracle.sol#L14), [LiquidityPool.sol](https://github.com/etherfi-protocol/smart-contracts/blob/9cae955d2e897cb5e8bf5266a0de22da73f1ac99/src/LiquidityPool.sol#L26), 

### Summary

The purpose of this `EFIP` is to optimize reward skimming when paying out the node operator. Every quarter, protocol pays 5% of validator rewards to the corresponding node operator. This is a very expensive operation because the protocol needs to skim rewards from over 20,000 eigenpods and 20,000 etherfinode contracts, where all the execution and consensus rewards are directed.

To address this, during the rebase operation, instead of minting shares of 90% of the rewards (with 5% going to the treasury and 5% to the node operator), the protocol mints 100% of the rewards and distributes 10% to the treasury. This would require a feature in the liquidity pool that mints shares to the treasury or EOA based on the rewards accrued to the protocol and node operators which would be called by the etherfiadmin.

---

### Findings

### [Best practice] `LiquidityPool::payProtocolFees` function can be frontran

**File(s)**: [LiquidityPool.sol](https://github.com/etherfi-protocol/smart-contracts/blob/9cae955d2e897cb5e8bf5266a0de22da73f1ac99/src/LiquidityPool.sol#L467)

**Description**: The `LiquidityPool::payProtocolFees()` can be frontran and in order to manipulate the amount of Ether deposited into the pool. We checked the possibility of manipulating the `LiquidityPool's` balance in order to manipulate the number of shares minted towards the `treasury`. We didn't find a clear attack path, it seems that even if the transaction is frontran, the number of shares minted will be the one expected.

**Recommendation(s)**: To mitigate the potential of being frontran consider using a private RPC network like Flashbots when distributing the rewards through this new mechanism.

**Update from client**:

---

### [Info] Centralization risk

**File(s)**: [EtherFiOracleExecutor.sol](https://github.com/etherfi-protocol/smart-contracts/blob/9cae955d2e897cb5e8bf5266a0de22da73f1ac99/src/EtherFiOracleExecutor.sol#L154)

**Description**: The new `EtherFiOracleExecutor::_handleProtocolFees()` function only checks that `protocolFees` passed inside the `report` are `>=0`. There is no upper limit on how many shares can be minted to the treasury address. The owner is able to mint an indefinite amount of shares to the treasury address through this mechanism.

This function is part of the `executeTasks()` function which is guarded by an `isAdmin` modifier so we assume that the `Admin` is trusted and will always behave honestly.

**Recommendation(s)**: Consider adding some limits to the amount of shares that can be minted to the `treasury` address.

**Update from client**:

---
