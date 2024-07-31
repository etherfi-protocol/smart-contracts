# [EFIP-7] EIP-1271 Compatibility for EtherFiNode contract

**Author**: syko (seongyun@ether.fi)

**Date**: 2024-07-22

## Summary

This EFIP proposes making the EtherFiNode contract compatible with EIP-1271, which defines a standard interface for smart contract signature validation. This change will allow EtherFiNode to validate signatures according to the EIP-1271 standard, improving interoperability with other smart contracts and applications.

## Motivation

The current EtherFiNode contract lacks support for EIP-1271, limiting its ability to interact with other contracts and applications that require standardized signature validation.

## Proposal

The proposal introduces changes to the EtherFiNode contract to implement the EIP-1271 standard. Key changes include:

1. **EIP-1271's `isValidSignature`**:
    ```solidity
    function isValidSignature(bytes32 _hash, bytes memory _signature) public view returns (bytes4 magicValue);
    ```
    - This function checks if a given signature is valid for the provided data.

2. **Signature Validation Logic**:
    - The function verifies the signature using the stored key or predefined logic.
    - If the signature is valid, it returns `0x1626ba7e` (the magic value specified by EIP-1271).
    - If the signature is invalid, it returns `0xffffffff`.

## References

- [Pull Request #97](https://github.com/etherfi-protocol/smart-contracts/pull/97)
- [EIP-1271 Standard](https://eips.ethereum.org/EIPS/eip-1271)

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).
