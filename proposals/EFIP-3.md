# [EFIP-3] Withdrawals via EigenLayer's m2 proof system

**Author**: dave (dave@ether.fi), syko (seongyun@ether.fi), 

**Date**: 2024-06-24

## Summary

This EFIP proposes the integration of partial and full withdrawal flows on EigenLayer m2 for the `EtherFiNode` and `EtherFiNodesManager` contracts. The goal is to enable withdrawals from EigenLayer's m2 system, which is required to fullfil the withdrawal requests when the liquidity contract lacks sufficient ETH.

## Motivation

Currently, the protocol fulfills withdrawal requests using ETH from the liquidity contract. However, if there is insufficient ETH, the protocol cannot exit validators to fulfill these requests. This proposal addresses the gap by enabling withdrawals from EigenLayer, ensuring user requests can be met even when the liquidity contract is depleted.

## Proposal

The proposal is to add the integration the EigenLayer's m2 proof system with {`EtherFiNode`, `EtherFiNodesManager`} contracts. The main focus is to ensure the system can exit validators to meet withdrawal requests which has re-staked on EigenLayer's EigenPod.

It implements the following withdrawal flows:

- Full Withdrawal
    1. validator is exited & fund is withdrawn from the beacon chain
    2. perform `EigenPod.verifyAndProcessWithdrawals` for the full withdrawal
    3. perform `EtherFiNodesManager.processNodeExit` which calls `DelegationManager.queueWithdrawals`
    4. wait for 'minWithdrawalDelayBlocks' (= 7 days) delay to be passed
    5. perform `EtherFiNodesManager.completeQueuedWithdrawals` which calls `DelegationManager.completeQueuedWithdrawal`
    6. Finally, perform `EtherFiNodesManager.fullWithdraw`


- Partial Withdrawal
    1. validator's rewards is withdrawn from the beacon chain
    2. perform `EigenPod.verifyAndProcessWithdrawals` for the partial withdrawals. It triggers `DelayedWithdrawalRouter.createDelayedWithdrawal`
    3. wait for 'withdrawalDelayBlocks' (= 7 days) delay to be passed
    4. Finally, perform `EtherFiNodesManager.partialWithdraw`

For the details in the implementation, plz check the PR.

## References

- [Pull Request #58](https://github.com/etherfi-protocol/smart-contracts/pull/58)
- [Audit review](./references/NM-0217-withdrawal-with-eigenlayer-m2.md)

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).
