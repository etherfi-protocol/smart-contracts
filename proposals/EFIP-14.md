# [EFIP-14] Role Registry Contract


**Author**: dave (dave@ether.fi)

**Date**: 2024-07-25

## Summary

This EFIP proposes the introduction of a central role registry contract in order to provide consistent, secure, and granular permissions for actions across the protocol

## Motivation

Currently most of the ether.fi contracts rely on a mix of admin and ownership mechanisms, often implemented slightly uniquely for each contract.
In several cases mappings of multiple admins are utilized with no convenient way to enumerate who has been assigned those roles.

The existing roles also do not support a high level of granularity. Supporting granular roles allows the protocol to be better secured and opens new opportunities
for functionality internally and for partners needing to perform certain actions against the contracts.

## Proposal

The proposal introduces a RoleRegistry contract that will serve as the source of truth for most roles in the protocol:

1. Registry contract based on Open Zeppelin's AccessManager
  - supports granular roles
  - flexible role admin role to enable future use cases
  - emits events for all role updates to allow much easier auditability and accounting of which addresses can perform which tasks in the protocol
  - root role will be owned by the ether.fi protocol hardware backed timelock multisig

2. Update existing contracts utilizing their own admin systems to instead verify roles from this role registry contract:
    - deprecate existing admin functionality
    - add more granular permissions and roles to each contract where necessary

3. Grant minimum required set of roles to existing operational addresses in order to maintain smooth protocol operation

## References

- [Pull Request #100](https://github.com/etherfi-protocol/smart-contracts/pull/100)

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).
