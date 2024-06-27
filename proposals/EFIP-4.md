# [EFIP-4] Rewards Skimming Optimization 

**Author**: Vaibhav Valecha (vaibhav@ether.fi)

**Date**: 2024-05-26

## Summary

The purpose of this EFIP is to optimize reward skimming when paying out the node operator. Every quarter, we pay out 5% of validator rewards to the corresponding node operator. This is a very expensive operation because we need to skim rewards from over 20,000 eigenpods and 20,000 etherfinode contracts, where all the execution and consensus rewards are directed. Furthermore, determining the rewards accrued by the entire protocol is not a straightforward process due to the number of different contracts holding the rewards.

To address this, during the rebase operation, instead of minting shares of 90% of the rewards (with 5% going to the treasury and 5% to the node operator), we mint 100% of the rewards and distribute 10% to the treasury. This would require a feature in the liquidity pool that mint shares to the treasury or EOA based on the rewards accrued to the protocol and node operators which would be called by the etherfiadmin. 


## Motivation

The benefit of this proposal is that it optimizes gas costs by allowing us to skim the etherfinode contracts and eigenpods at our discretion, whenever gas price are low and when we believe there is a sufficent amount of ether accumulated to the contracts. Furthermore it gives more clear visibility on how much rewards have been accumulated by the treasury. The required gas required for the partialWithdraw of 40 validator is 8,000,000. Therefore if we are skimming rewards quarter for half our validators to get the rewards to payout to node operators we are spending yearly: 25K validator / 40 * 8M gas * 8gwei * 4 times year = 160eth. Since with this optimization of paying the node operators in eeth we are not required to skimming the rewards on a quarter basis and we can just perform this operator once every year. Additionally, we have more choice on when we want to skim the rewards and are likely to skim consistently when gas is cheaper. If we skim once a year for all validator and adding the cost to mint shares to the treasury and assume a 25% gas reduction from the average price of 8gwei then the cost of skimming is: 50K validator / 40 * 8M gas * 6gwei * 1 time a year + 365 days * 8gwei * 100000 (gas required to deposit) =60eth 




## Proposal

### Simple Solution:
1. Add functionality in liquidity pool to mint shares for treasury/EOA

2. Add call to the EtherfiAdmin to mint the shares

3. Upgrade treasury to be able to transfer eeth (only required if we make it payout to treasury)

### Simple Solution + Node Operator Payout Automation:
1. Deploy a NodeOperator Registry Contract to serve as the central hub for all node operator information. This contract will store details such as the name, address, number of validators run by each node operator, number of live validators, and any other necessary information. Implement functionality that takes an array of rewards payable to each node operator and transfers the rewards accordingly.

2. Upgrade the EtherFiOracle contract so that OracleReport also includes an array indicating how much each node operator should be rewarded.


### Simple Solution + Node Operator Payout Automation socialized:
1. Deploy a NodeOperator Registry Contract to serve as the central hub for all node operator information. This contract will store details such as the name, address, number of validators run by each node operator, number of live validators, and any other necessary information. Implement functionality to transfer the balance of eETH to all node operators based on their validator count in the live phase. Everything else is the same as the simple solution.

## References

This architecture of paying the treasury and node operators in ETH was inspired by Lido's protocol, which holds stETH in its treasury instead of ETH.

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).

