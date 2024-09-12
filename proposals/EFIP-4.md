# [EFIP-4] Processing staking to {Treasury, Node Operators} in eETH

**Author**: Vaibhav Valecha (vaibhav@ether.fi)

**Date**: 2024-05-26

## Summary

The purpose of this EFIP is to optimize reward skimming when paying out the node operator. Every quarter, we pay out 5% of validator rewards to the corresponding node operator. This is a very expensive operation because we need to skim rewards from over 20,000 eigenpods and 20,000 etherfinode contracts, where all the execution and consensus rewards are directed. 

To address this issue, we will now mint 100% of staking rewards from validators and distribute them as follows: 5% to node operators, 5% to the treasury, and the remaining 90% to stakers, as usual. This would require a feature in the liquidity pool that mint shares to the treasury based on the rewards accrued to EtherFi and node operators.

However, the first mint under this new system will result in a one-time large mint, as staking rewards have been accumulating for over 50,000 validators. These rewards, owed to node operators and the treasury, have not yet been claimed. Consequently, around 2,350 eETH will be minted to account for 2,350 ETH in accrued staking rewards for the Eigenpods and EtherFiNodes, which will be distributed to node operators and the EtherFi treasury.
To ensure a smooth process, EtherFi will mint eETH via timelock for the ETH accrued during this first large mint. Going forward, the Oracle will mint 100% of staking rewards, with 10% going to the treasury and node operators, and the remaining 90% continuing to go to stake.


## Motivation

Currently, every quarter we need to skim rewards from the withdrawal safes and eigenpods to pay the node operator. This results in high gas costs due to 40k contracts accumulating ETH that must be transferred to the treasury. Additionally, the need to perform skimming for node operator payouts reduces our flexibility on timing, preventing us from waiting for very low gas prices. Furthermore, tracking eth accrued to the treasury is not optimizable since 40k contract balance needs to be queried.

Paying our node operators and the treasury in eETH reduces gas costs by allowing us to skim withdrawal safes and eigenpods at our discretion, when gas prices are low. This also allows us to skim annually instead of quarterly. If we skim annually and achieve a 25% lower gas price, we can reduce our gas costs by 80%. Additionally, minting eETH to the treasury during the rebase provides easy, daily updates on the accrued ETH for the treasury and node operators.


## Proposal
To implement this proposal, we need to report the rewards accrued to the treasury and node operators and mint the corresponding amount of shares to the treasury during each rebase. Here are the steps to implement the proposal:

1. Add the rewards accrued for the treasury and node operators to the oracle report.  
2. Add functionality in liquidity pool to mint shares to treasury
3. Add call to the EtherfiAdmin to mint the shares within executeTask
4. Add functionality for the treasury to transfer and withdraw eETH for ETH
5. Call setStakingRewardsSplit to set the treasury's allocation to 0 and reallocate it to the tNFT.
6. Grant Timelock permission to mint eeth for unclaimed staking rewards accumulated to EtherFi and Node Operators



## References

This architecture of paying the treasury and node operators in ETH was inspired by Lido's protocol, which holds stETH in its treasury instead of ETH.

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).

