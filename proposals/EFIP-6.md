# [EFIP-6] EL Rewards Directed to Spilter Contract

**Author**: Vaibhav Valecha (vaibhav@ether.fi)

**Date**: 2024-05-26

## Summary

The purpose of this EFIP is to optimize reward skimming which can be done by configuring all the validators to send the execution layer rewards to a dedicated spilter contract that handles accepting execution layer rewards in eth and spilts the rewards to the bnft, liquidity pool and the treasury.

## Motivation
Currently, for a validator, its execution layer rewards and MEV are sent to its withdrawal safe (ether.fi node) contract, and its consensus layer rewards are sent to its EigenPod contracts. The process of skimming rewards is coupled together, so the execution and consensus layer rewards must be skimmed together resulting in prohibitively large gas cost. 

The benefit of this proposal is that by having 1 address where execution layer + MEV rewards flow to from all validators and decoupling the the consensus and execution layer rewards, we only require 1 transaction to distribute execution layer rewards.

## Proposal
1. Have all node operator's configure their validator's to send their execution layer rewards to the spilter contract
2. Create spilter contract that is able to spilt bnft, liquidity pool and the treasury's execution layer rewards. 

## References
WIP



## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).

