# Set Capacity for Whale weETH -> stETH Redemption

# Review checklist
- [ ] Tenderly Simulation and events emitted
- [ ] Contract Addresses
- [ ] Capacity, refillRate, and exitFee updated correctly after Tx 2
- [ ] Whale can redeem 108070.928836140722914995 weETH to stETH
- [ ] Capacity, refillRate, and exitFee reverted correctly after Tx 3

# Operations
- **Safe Address**: `0x2aCA71020De61bb532008049e1Bd41E451aE8AdC` (Operating Safe)

## Tx 1 — Schedule Increase + Schedule Revert (Operating Timelock)
- **Nonce**: TBD
- **Target Contract**: EtherFi Operating Timelock (`0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a`)
- **Purpose**:
  - Schedule `setExitFeeBasisPoints(0, stETH)` + `setCapacity(130_000 ether, stETH)` + `setRefillRatePerSecond(130_000 ether, stETH)` on RedemptionManager
  - Schedule `setExitFeeBasisPoints(10, stETH)` + `setCapacity(5_000 ether, stETH)` + `setRefillRatePerSecond(57_870_000_000_000_000, stETH)` on RedemptionManager
- **JSON**: `set-capacity-whale-weeth-schedule.json` + `set-capacity-whale-weeth-revert-schedule.json`

## Tx 2 — Execute Increase (Operating Timelock)
- **Nonce**: TBD
- **Target Contract**: EtherFi Operating Timelock (`0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a`)
- **Purpose**:
  - Execute increase after 8h timelock delay
  - Whale redeems weETH to stETH
- **JSON**: `set-capacity-whale-weeth-execute.json`

## Tx 3 — Execute Revert (Operating Timelock)
- **Nonce**: TBD
- **Target Contract**: EtherFi Operating Timelock (`0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a`)
- **Purpose**:
  - Execute revert after 8h timelock delay to restore original config
- **JSON**: `set-capacity-whale-weeth-revert-execute.json`

# Details
| Parameter | Current | Increase | Revert |
|-----------|---------|----------|--------|
| exitFeeInBps | 10 | 0 | 10 |
| capacity | 5,000 stETH | 130,000 stETH | 5,000 stETH |
| refillRate | 57,870,000,000,000,000 wei/s | 130,000 stETH | 57,870,000,000,000,000 wei/s |

| Parameter | Value |
|-----------|-------|
| RedemptionManager | `0xDadEf1fFBFeaAB4f68A9fD181395F68b4e4E7Ae0` |
| Operating Timelock | `0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a` |
| stETH | `0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84` |
| Whale | `0x7ee29373F075eE1d83b1b93b4fe94ae242Df5178` |
| weETH Amount | 108,070.928836140722914995 weETH |
| eETH Equivalent | ~117,933 eETH |
| stETH to Receive | ~117,933 stETH (0% exit fee) |
| Timelock Delay | 8 hours |

# Simulations
1. Schedule Increase + Schedule Revert:
2. Execute Increase:
3. Execute Revert:
