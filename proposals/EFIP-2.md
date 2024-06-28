# [EFIP-2] Handling Invalidated Withdrawal Requests in WithdrawRequestNFT

**Author**: syko (seongyun@ether.fi)

**Date**: 2024-06-24

## Summary

This EFIP proposes the addition of the `seizeInvalidRequest` function to the `WithdrawRequestNFT` contract. This function allows the contract owner to seize invalidated withdrawal requests, burn the associated NFT, and withdraw the ETH to a specified recipient. This feature aims to handle the withdrawal requests invalidated by the protocol.

## Motivation

Currently, the protocol lacks a mechanism to handle invalidated withdrawal requests. This proposal adds the functionality to the contract to seize and resolve invalidated withdrawal requests.

## Proposal

The proposal introduces the `seizeInvalidRequest` function to the `WithdrawRequestNFT` contract. Key features include:

- **Seizing Invalid Requests**: The contract owner (e.g., multi-sig behind the timelock) can seize invalidated requests, ensuring they cannot be exploited.
- **Burning NFTs**: Invalidated NFTs are burned, preventing further use or transfer.
- **Withdrawing ETH**: The ETH associated with the invalidated request is withdrawn to a specified recipient.
- **Security Checks**: The function includes checks to ensure only invalidated requests are seized and that they are properly owned and unclaimed.

Detailed technical changes include:

1. **Contract Modifications**:
    - `WithdrawRequestNFT.sol`:
      - Addition of `seizeInvalidRequest` function.
      - Associated event `WithdrawRequestSeized`.
    - `LiquidityPool.sol`:
      - Integration with the new function to adjust ETH amount locked for withdrawal.
    - Interface and test updates to support the new functionality.

2. **Event Emission**:
    - Emitting `WithdrawRequestSeized` event upon successful execution of the function.

## References

- [Pull Request #61](https://github.com/etherfi-protocol/smart-contracts/pull/61)
- [Audit review](./references/NM-0217-seize-withdrawalNFT.md)


## Security Considerations

The added functionality shall be used with full transparency to the ether.fi community by the multi-sig to avoid centralization risks.


## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).
