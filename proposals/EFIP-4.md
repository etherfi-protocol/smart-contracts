# [EFIP-4] Processing staking to {Treasury, Node Operators} in eETH

**Author**: Vaibhav Valecha (vaibhav@ether.fi)

**Date**: 2024-05-26

## Summary

The purpose of this EFIP is to optimize reward skimming when paying out the node operator. EtherFi’s Oracle mints eETH daily, distributing 90% of staking rewards from validators to all stakers. The remaining 10% is allocated to node operators and EtherFi’s treasury, which are distributed across Eigenpods and EtherFiNodes. However, the process of claiming ETH from over 20,000 Eigenpods and EtherFiNodes has been inefficient for both node operators and EtherFi.

To address this issue, we will now mint 100% of staking rewards from validators and distribute them as follows: 5% to node operators, 5% to the treasury, and the remaining 90% to stakers, as usual.

## Large Mint
The first mint under this new system will result in a one-time large mint, as staking rewards have been accumulating for over 50,000 validators. These rewards, owed to node operators and the treasury, have not yet been claimed. Consequently, 2,650 eETH will be minted to account for 2,650 ETH in accrued staking rewards for the Eigenpods and EtherFiNodes, which will be distributed to node operators and the EtherFi treasury.

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
-[Nethermind Audit Report](https://file.notion.so/f/f/a2eb6f5b-6767-43e2-890d-4acb71d6176b/3dde22f1-3267-4997-98cc-e4417ec0f94b/EFIP-4_Processing_staking_to_Treasury_Node_Operators_in_eETH_-_HackMD.pdf?table=block&id=10db0952-7c43-800d-a80f-eed35f1269cb&spaceId=a2eb6f5b-6767-43e2-890d-4acb71d6176b&expirationTimestamp=1727827200000&signature=DvOO3EtEMg6ul4REzVIPWaIWjnFfP5boNDorqxCCMc0&downloadName=%5BEFIP-4%5D+Processing+staking+to+%7BTreasury%2C+Node+Operators%7D+in+eETH+-+HackMD.pdf)

-[Certora Draft Report](https://file.notion.so/f/f/a2eb6f5b-6767-43e2-890d-4acb71d6176b/52e43580-5be3-484e-8009-7c5d3ae500dd/EtherFi_draft_report.pdf?table=block&id=10db0952-7c43-80bd-9f43-e55ea5974de5&spaceId=a2eb6f5b-6767-43e2-890d-4acb71d6176b&expirationTimestamp=1727827200000&signature=rPkxoNUsLz2beenBpqbu987QBbw1zX5Y0wz6fq5CBUA&downloadName=EtherFi+draft+report.pdf)

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).

