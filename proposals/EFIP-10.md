# [EFIP-10] Whitelisted Delegate calls for EtherFiNode/EigenPod


**Author**: dave (dave@ether.fi), syko (seongyun@ether.fi)

**Date**: 2024-07-22

## Summary

This EFIP proposes the introduction of a whitelist mechanism on the delegate call into the EtherFiNode/EigenPod contracts. This change aims to enhance security by restricting call forwarding and function execution to a predefined list of delegates, ensuring that only authorized operations can be performed.

## Motivation

Currently, we use the blacklisting to restrict blacklisted functions from being executed. However, the blacklisting approach is not robust and can be bypassed by malicious actors by upgrade. Introducing the whitelisting will mitigate these risks by ensuring only allowed operations can be executed.

## Proposal

The proposal introduces changes to the EtherFiNode and EtherFiNodesManager contracts to implement the whitelist mechanism:

1. **Whitelist Management**:
    - Addition of functions to manage the whitelist for `eigenPodCall` and `externalCall`
    - Implementation of checks to ensure only whitelisted operations ca be performed.

2. **Call Forwarding Restrictions**:
    - Ensuring that only the whitelisted operations can be performed.


## References

- [Pull Request #100](https://github.com/etherfi-protocol/smart-contracts/pull/100)

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).

