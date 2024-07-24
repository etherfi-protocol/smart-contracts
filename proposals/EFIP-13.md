# [EFIP-10] Remove Transfer Blacklist

**Author**: Jacob Firek jacob@ether.fi

**Date**: 2024-07-22

## Summary

A blacklist was introduced in EFIP-5 as a defense against phishing attacks. This EFIP outlines a proposal to remove this feature.

## Motivation

Given that nothing can be added to smart contracts for free, every feature must be carefully considered before subjecting our users to additional gas costs.

## Proposal

We should remove the transfer blacklist for these reasons:

- The majority of phishing attacks on our users are via gasless permit signatures, which are covered by the introduction of the whitelist.
- Hackers can easily circumvent the blacklist as the recipient by generating a new address.
- The typical pattern for hackers involves the immediate transfer of funds to ETH.
- The blacklist adds 5000 gas to all transfers.

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).
