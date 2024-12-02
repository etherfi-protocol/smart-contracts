# [NM-0217] OFT Security Upgrades

**File(s)**: [EtherfiOFTUpgradable.sol](https://github.com/etherfi-protocol/weETH-cross-chain/blob/3c8b05409395f4da4f58550afcf63987d633de03/contracts/EtherfiOFTUpgradeable.sol#L1), [PairwiseRateLimiter.sol](https://github.com/etherfi-protocol/weETH-cross-chain/blob/3c8b05409395f4da4f58550afcf63987d633de03/contracts/PairwiseRatelimiter.sol#L1),
[EtherFiOFTAdapterUpgradeable.sol](https://github.com/etherfi-protocol/weETH-cross-chain/blob/3c8b05409395f4da4f58550afcf63987d633de03/contracts/EtherFiOFTAdapterUpgradeable.sol#L9)

### Summary

The reviewed PR is meant to introduce security improvements to the cross chain contracts considering that OFT Adapter migration was completed. This PR adds:

- OFT bridge pausing functionality. It introduces the `PAUSER_ROLE` that can be shared with hypernative to pause bridging to and from the native chain. It uses OpenZeppelin's `AccessControlUpgradeable` contract to achieve this.

- Pairwise rate limiting. The current iteration of the OFT contracts only rate limits outbound transfers on the token contract. This PR extends the LayerZero `RateLimter` contract to allow for the rate limiting of inbound transfers as well. It also integrates rate limiting into the `UpgradeableOFTAdapter` contract.

- Deprecate default admin. Before the update, there were 2 roles that could set critical parameters, `Owner` and `Default_Admin`. They were merged into one, `Owner`.

---

### Findings

### [Info] Wrong import won't allow the contract to compile

**File(s)**: [EtherfiOFTUpgradeable.sol](https://github.com/etherfi-protocol/weETH-cross-chain/blob/3c8b05409395f4da4f58550afcf63987d633de03/contracts/EtherfiOFTUpgradeable.sol#L10)

**Description**: The `EtherfiOFTUpgradeable` file imports `import {PairwiseRateLimiter} from "./PairwiseRateLimiter.sol";`, the problem is that the actual file's name is `PairwiseRatelimiter` with lowercase `l` instead of `L`. Because of this we get the error `Source "contracts/PairwiseRateLimiter.sol" not found: File not found.`

**Recommendation(s)**: Rename the `PairwiseRatelimiter.sol` file accordingly.

**Update from client**:
Updated to ensure consistency across different operating systems:
https://github.com/etherfi-protocol/weETH-cross-chain/pull/14/commits/6a0834b208a33a59036fbbc9cd90afafe0f48f5f

---
