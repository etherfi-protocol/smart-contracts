# [EFIP-8] Purpose and Guidelines

**Author**: Vaibhav Valecha (vaibhav@ether.fi)

**Date**: 2024-07-12


## Summary

EFIP-8 proposes to rescue the weEth held by the treasury contract, which lacks the functionality to transfer ERC20 tokens or upgrade the contract. This can be achieved by upgrading the weEth contract to add a function that allows the owner to transfer the weEth out of the treasury contract and only the treasury contract.  


## Motivation

Currently, we have 32 weETH in the treasury, which is not transferable because the contract does not have the function to transfer ERC20 tokens, and it is not upgradeable. Therefore, the 32 weETH is stuck.

The benefit of this proposal is that it allows us to move the weETH into another wallet from the treasury without losing the trust of our users, as we are only allowing the owner to transfer weETH out of the treasury.

## Proposal

To implement this proposal, we add a function in the weEth contract which calls transfers for the amount of weEth held by the treasury and sends its to the owner.


## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).
