# [EFIP-6] Fine-Grained Timelock


**Author**: jtdev (jacob@ether.fi) 

**Date**: 2000-07-11

## Summary

This proposal suggests implementing a fine-grained timelock with OpenZeppelin Access Control v5 system for HyperNative’s automated response to alerts. Specifically, it proposes reducing the timelock for unpausing smart contracts from 3 days to 15 minutes. This change aims to mitigate the impact of false-positive alerts and allow for more aggressive alert configurations to better protect the protocol.

## Motivation

Currently, when HyperNative pauses our smart contracts (SCs) in response to alerts, it takes 3 days to unpause them. This long delay can be problematic, especially in the case of false-positive alerts. By reducing the unpause timelock to 15 minutes, we can decrease the cost of false-positive alerts and configure the alerts more aggressively

## Proposal

To achieve this, we will deploy the OpenZeppelin Access Control v5 contract to manage all necessary functionality. This contract is very powerful with numerous features including fine-grained timelock functionality.

The existing timelock will remain in place to handle the most critical actions, such as upgrading contracts. However, it can delegate other actions with varying degrees of locking. Specifically, we propose:

	1. Deploy OpenZeppelin Access Control v5
    2. Configure Access Control contract to have permission for unpausing smart contracts with a 15 minute timelock
	3. Maintaining the 3-day timelock for other critical actions, such as contract upgrades.

## References

- [Access Control - OpenZeppelin Docs](https://docs.openzeppelin.com/contracts/5.x/api/access#AccessManager)
- [Access Control v5 - Code](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.1/contracts/access/manager/AccessManager.sol)

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).

