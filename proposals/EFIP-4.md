# [EFIP-4] Processing staking to {Treasury, Node Operators} in eETH

**Author**: Vaibhav Valecha (vaibhav@ether.fi)

**Date**: 2024-05-26

## Summary

The purpose of this EFIP is to optimize reward skimming when paying out the node operator. EtherFi’s Oracle mints eETH daily, distributing 90% of staking rewards from validators to all stakers. The remaining 10% is allocated to node operators and EtherFi’s treasury, which are distributed across Eigenpods and EtherFiNodes. However, the process of claiming ETH from over 20,000 Eigenpods and EtherFiNodes has been inefficient for both node operators and EtherFi.

To address this issue, we will now mint 100% of staking rewards from validators and distribute them as follows: 5% to node operators, 5% to the treasury, and the remaining 90% to stakers, as usual.

## First Deposit of Protocol Fees for EETH

The 10% staking rewards have been accumulating and unclaimed for over 50,000 validator for the past 10 months. EtherFi will deposit all the unclaimed protocol rewards, owned by EtherFi, node operators, and bNFTs to mint eETH. As a result, 2,700 eETH will be minted for the 2,700 ETH in accrued staking rewards across Eigenpods and EtherFi Nodes, which will be distributed to the node operators and the EtherFi treasury. Thereafter, EtherFi will be depositing their 10% staking rewards and bnft rewards for eeth on a daily basis. 

## Motivation

Currently, every quarter we need to skim rewards from the withdrawal safes and eigenpods to pay the node operator. This results in high gas costs due to 40k contracts accumulating ETH that must be transferred to the treasury. Additionally, the need to perform skimming for node operator payouts reduces our flexibility on timing, preventing us from waiting for very low gas prices. Furthermore, tracking eth accrued to the treasury is not optimizable since 40k contract balance needs to be queried.

Paying our node operators and the treasury in eETH reduces gas costs by allowing us to skim withdrawal safes and eigenpods at our discretion, when gas prices are low. This also allows us to skim annually instead of quarterly. If we skim annually and achieve a 25% lower gas price, we can reduce our gas costs by 80%. Additionally, minting eETH to the treasury during the rebase provides easy, daily updates on the accrued ETH for the treasury and node operators.


## Proposal
To implement this proposal, we need to report the rewards accrued to the treasury and node operators and mint the corresponding amount of shares to the treasury during each rebase. Here are the steps to implement the proposal:

1. Add the rewards accrued for the treasury and node operators to the oracle report.  
2. Add functionality in liquidity pool to mint shares for treasury
3. Add call to the EtherfiAdmin to mint the shares within executeTask
4. Call setStakingRewardsSplit to set the treasury's allocation to 0 and reallocate it to the TNFT.

## Audits
- [Nethermind Audit Report](./references/efip-4-nethermind-review.md)

- [Certora Draft Report](../audits/2024.10.08%20-%20Certora%20-%20EtherFi%20draft.pdf)

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).

