# [EFIP-8] Purpose and Guidelines

**Author**: Vaibhav Valecha (vaibhav@ether.fi)

**Date**: 2024-07-11


## Summary

EFIP-8 proposes to rescue the weEth held by the treasury contract, which currently lacks the functionality to transfer ERC20 tokens or upgrade the contract. This can be achieved by upgrading the weEth contract to add a feature that allows someone to transfer another's weEth at some premium. 


## Motivation

Currently, we have 32 weEth in the treasury which is not transferable because the contract does not have the function to transfer ERC20 tokens, and it is not upgradeable. Therefore, the 32 weEth is stuck.

The benefit of this proposal is that it allows us to move the weEth into another wallet from the treasury without losing the trust of our users. This is because if someone wants to take someone else's weEth, they must transfer 50% more ETH to their wallet.



## Proposal

To implement this proposal, a payable function should be added to the weEth contract. This function will take the address from which you want to transfer the weEth out of and the amount. It will verify that the ETH amount being paid is 1.5 times (or another specified factor) the amount of weEth being transferred. Once verified, the recipient receives the ETH, and the caller gets the weEth.


## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).
