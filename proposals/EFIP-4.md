# [EFIP-4] Rewards Skimming Optimization

**Author**: Vaibhav Valecha (vaibhav@ether.fi)

**Date**: 2024-05-26

## Summary

The purpose of this EFIP is to optimize reward skimming when paying out the node operator. Every quarter, we pay out 5% of validator rewards to the corresponding node operator. This is a very expensive operation because we need to skim rewards from over 20,000 eigenpods and 20,000 etherfinode contracts, where all the execution and consensus rewards are directed. Furthermore, determining the rewards accrued by the entire protocol is not a straightforward process due to the number of different contracts holding the rewards.

To address this, during the rebase operation, instead of minting shares of 90% of the rewards (with 5% going to the treasury and 5% to the node operator), we mint 100% of the rewards and distribute 10% to the treasury. Additionally, the oracle report should include an array indicating the amount of rewards each operator should receive. We will also deploy a nodeOperatorAccounting contract that keeps track of the amount of rewards accrued by each operator.


## Motivation

The benefit of this proposal is that it optimizes gas costs by allowing us to skim the etherfinode contracts and eigenpods at our discretion, whenever we deem it necessary. Additionally, it automates the process of paying out the node operators, reducing human error and minimizing the reliance on off-chain data for payments.


## Proposal


1. Deploy a NodeOperator Accounting contract (or upgrade the nodesmanager contract) to serve as the central hub for all node operator information. This contract will store details such as the name, address, rewards accrued, number of validators run by each node operator, and any other necessary information. This will simplify accounting and make it easy for everyone to find information about the validators.

2. Upgrade the oracle contract to be able to take in an array of rewards per node operator

3. Upgrade rebase operation on the liquidity pool to be able to mint eeth to the treasury

4. Upgrade treasury to be able to transfer and burn eeth for eth


## References

This architecture of paying the treasury and node operators in ETH was inspired by Lido's protocol, which holds stETH in its treasury instead of ETH.

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).

