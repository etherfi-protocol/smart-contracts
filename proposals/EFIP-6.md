# [EFIP-6] Execution Rewards Optimization 

**Author**: Vaibhav Valecha (vaibhav@ether.fi)

**Date**: 2024-05-26

## Summary

The purpose of this EFIP is to optimize reward skimming which can be done by configuring all the validators to distribute execution layer rewards to a dedicated spilter contract that handles accepting execution layer rewards in eth and spilts the rewards to the bnft, liquidity pool and the treasury.

## Motivation

The benefit of this proposal is that it optimizes gas costs by allowing us to skim execution layer rewards from one address instead of transferring execution rewards from all of our etherfinode contract to the desired address. With the current state of the contracts skimming the eigenpods and the etherficontracts tightly coupled therefore, eth must be transferred from eigenpods and etherfinodes at the same time, whereas with this proposal we could skim the execution layer rewards separatly. The gas cost to skim all execution layer rewards and consensus rewards in batches of 40 is 50K validator / 40 * 8M gas * 8gwei = 80eth. And we can say half of that cost is to withdraw the execution layer rewards. By having 1 address where execution layer rewards flow to from the validators then we only need to make 1 transaction to send all execution layer rewards to the treasury and the cost of that is negliable. Therefore, this solution will save the protocol 40eth per year which is equivalent to 40*$4000 = $160,000.


## Proposal
1. Add functionality in liquidity pool to mint shares for treasury/EOA

2. Add call to the EtherfiAdmin to mint the shares

3. Upgrade treasury to be able to transfer eeth (only required if we make it payout to treasury)



## References

This architecture of paying the treasury and node operators in ETH was inspired by Lido's protocol, which holds stETH in its treasury instead of ETH.

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).

