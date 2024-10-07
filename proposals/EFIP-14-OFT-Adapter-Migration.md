# [EFIP-14] OFT Adapter Migration

**Author**: Jacob Firek (jacob@ether.fi)

**Date**: 2023-10-03

## Summary

Our current [OFT Adapter](https://etherscan.io/address/0xFE7fe01F8B9A76803aF3750144C2715D9bcf7D0D) is non-upgradeable, limiting our ability to add security features such as rate limiting and contract pausing in case of exploits. This proposal outlines the migration to a new upgradeable version of the OFTAdapter. This will allow us to add additional security features.

## Motivation

LayerZero provides a generic base layer for the bridging of any token via OFT. Their contracts are minimal and lack security features. Moving to an upgradeable version of the OFTAdapter will allow the protocol to add these features listed below and maintain flexibility for future improvements:
 - rate limiting 
 - pausing of the contract 
 - queuing of large transfers

## Proposal

Below is a high-level description of the migration process. Please see the pull request and audit linked below for more details.

1. **Custom Migration Contract**:
   A custom migrationOFT contract will be deployed on Arbitrum to facilitate the migration process. This contract will allow us to send migration messages to mainnet with a hardcoded destination of the UpgradeableOFTAdapter.

2. **Asset Transfer**:
   The sendMigrationMessage function will trigger a series of messages to be sent to the Ethereum mainnet to transfer the weETH tokens from the old OFTAdapter to the new UpgradeableOFTAdapter. The destination is hardcoded to ensure that the assets are securely transferred.

3. **L2 Synchronization**:
   After the asset migration is complete, the Layer 2 OFTs will be reconfigured to designate the new UpgradeableOFTAdapter as the peer contract. This ensures that the new adapter can communicate with the Layer 2 instances and maintain cross-chain functionality.

## References

[Migration Pull Request](https://github.com/etherfi-protocol/weETH-cross-chain/pull/5)  
[Migration Audit](https://github.com/etherfi-protocol/smart-contracts/blob/master/audits/2024.09.30%20-%20Paladin_EtherFi_OFT_Adapter_Migration.pdf)

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).

