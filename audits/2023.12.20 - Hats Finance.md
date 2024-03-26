# **Ether.fi Audit Competition on Hats.finance**

## **Introduction to Hats.finance**
Hats.finance builds autonomous security infrastructure for integration with major DeFi protocols to secure users' assets. It aims to be the decentralized choice for Web3 security, offering proactive security mechanisms like decentralized audit competitions and bug bounties. The protocol facilitates audit competitions to quickly secure smart contracts by having auditors compete, thereby reducing auditing costs and accelerating submissions. This aligns with their mission of fostering a robust, secure, and scalable Web3 ecosystem through decentralized security solutions​.

## **Ether.fi Overview**
Ether.fi is a trailblazing decentralized, non-custodial Ethereum staking protocol, inspired by predecessors like RocketPool and Lido, emphasizing staker control and decentralization. It features a unique Liquid Staking Token (eETH) and operates across delegated staking, a liquidity pool, and node services, catering to stakers, node operators, and users. Ether.fi combines ETH and T-NFTs in its liquidity pool and facilitates a node services marketplace, underpinned by a commitment to long-term sustainability and community-centric values.

## **Competition Details**
- Type: A public audit competition hosted by Hats.finance.
- Duration: Two weeks.
- Maximum Reward: $72,000
- Total Payout: $6,100 distributed among nine participants.

## **Scope of Audit**
The PRIMARY scope for the audit are our smart contracts found in the repositories "src/" directory. We are not interested in problems in our EarlyAdopterPool.sol. For everything else, audit work is desired. Here's a comprehensive list of auditable contracts:
AuctionManager.sol BNFT.sol EETH.sol EtherFiAdmin.sol EtherFiNode.sol EtherFiNodesManager.sol EtherFiOracle.sol LiquidityPool.sol LoyaltyPointsMarketSafe.sol MembershipManager.sol MembershipManagerV0.sol MembershipNFT.sol NFTExchange.sol NodeOperatorManager.sol ProtocolRevenueManager.sol RegulationsManager.sol RegulationsManagerV2.sol StakingManager.sol TNFT.sol TVLOracle.sol Treasury.sol UUPSProxy.sol WeETH.sol WithdrawRequestNFT.sol
[ether-fi-0x36c3b77853dec9c4a237a692623293223d4b9bc4/src/](https://github.com/hats-finance/ether-fi-0x36c3b77853dec9c4a237a692623293223d4b9bc4/tree/180c708dc7cb3214d68ea9726f1999f67c3551c9/src)" 

## **Findings**
[(Ether.fi issues repo)](https://github.com/hats-finance/ether-fi-0x36c3b77853dec9c4a237a692623293223d4b9bc4/issues)

### **Medium severity findings:**

1. **Reentrancy when requesting a withdraw in the liquidity pool**
   - **Issue URL:** [GitHub Issue Link](https://github.com/hats-finance/ether-fi-0x36c3b77853dec9c4a237a692623293223d4b9bc4/issues/14)
   - **Summary:** This issue, classified as medium severity, involves a reentrancy bug in the LiquidityPool contract that allows a malicious actor to alter the number of shares to transfer to the WithdrawRequestNFT contract when calling requestWithdraw.

### **Low severity finding:**

1. **Beneficiaries of a slashed validator can still withdraw their node rewards**: Despite a validator being slashed, beneficiaries can still access and withdraw node rewards. [GitHub Issue](https://github.com/hats-finance/ether-fi-0x36c3b77853dec9c4a237a692623293223d4b9bc4/issues/53).

2. **Invalidating the withdraw request NFT will make the eEth stuck in the contract**: If a withdrawal request NFT is invalidated, it can result in eEth becoming permanently stuck in the contract. [GitHub Issue](https://github.com/hats-finance/ether-fi-0x36c3b77853dec9c4a237a692623293223d4b9bc4/issues/49).

3. **Griefing and migration prevention in `NodeOperatorManager.sol`**: An issue where protocol migration can be hindered and significant gas fees can be incurred. [GitHub Issue](https://github.com/hats-finance/ether-fi-0x36c3b77853dec9c4a237a692623293223d4b9bc4/issues/42).

4. **Adding a new tier will prevent rebasing**: Introducing a new tier may disrupt the rebasing process, potentially affecting reward distributions. [GitHub Issue](https://github.com/hats-finance/ether-fi-0x36c3b77853dec9c4a237a692623293223d4b9bc4/issues/40).

5. **Immediate minting of all `MembershipNFT`s by a malicious actor**: A loophole that allows rapid minting of all available `MembershipNFT`s, preventing others from participating. [GitHub Issue](https://github.com/hats-finance/ether-fi-0x36c3b77853dec9c4a237a692623293223d4b9bc4/issues/39).

6. **Various low severity issues requiring fixes**: A collection of minor issues that need attention for optimal contract performance. [GitHub Issue](https://github.com/hats-finance/ether-fi-0x36c3b77853dec9c4a237a692623293223d4b9bc4/issues/38).

7. **Denial of Service (DoS) risk by donating to LiquidityProvider.sol**: Excessive donations can lead to a DoS-like scenario. [GitHub Issue](https://github.com/hats-finance/ether-fi-0x36c3b77853dec9c4a237a692623293223d4b9bc4/issues/35).

8. **Unusability of `pause()` function in `EtherFiAdmin.sol`**: The `pause()` function is rendered unusable due to a coding oversight. [GitHub Issue](https://github.com/hats-finance/ether-fi-0x36c3b77853dec9c4a237a692623293223d4b9bc4/issues/31).

9. **Vulnerabilities in Solidity compiler version 0.8.13 affecting EtherFi**: Potential exploits in the Solidity compiler version used by EtherFi. [GitHub Issue](https://github.com/hats-finance/ether-fi-0x36c3b77853dec9c4a237a692623293223d4b9bc4/issues/26).

10. **`PausableUpgradeable` not initialized in `EtherFiOracle.sol`**: Failure to initialize `PausableUpgradeable` affects the pause functionality. [GitHub Issue](https://github.com/hats-finance/ether-fi-0x36c3b77853dec9c4a237a692623293223d4b9bc4/issues/25).

11. **Ownership renunciation of Treasury leading to unusability**: The owner can renounce ownership of the Treasury contract, leaving it inoperable. [GitHub Issue](https://github.com/hats-finance/ether-fi-0x36c3b77853dec9c4a237a692623293223d4b9bc4/issues/20).

12. **Changeable auction variables during ongoing auctions**: Variables can be altered even while an auction is in progress. [GitHub Issue](https://github.com/hats-finance/ether-fi-0x36c3b77853dec9c4a237a692623293223d4b9bc4/issues/13).

13. **Absence of checks for zero address**: Missing validations for zero addresses in contracts. [GitHub Issue](https://github.com/hats-finance/ether-fi-0x36c3b77853dec9c4a237a692623293223d4b9bc4/issues/5).


## **Conclusion**
The audit revealed significant insights into Ether.fi's contract security, particularly highlighting amedium severity issue and low severity issues that need attention. Addressing these findings will enhance the protocol's resilience and trustworthiness.

## **Disclaimer**
This report does not assert that the audited contracts are completely secure. Continuous review and comprehensive testing are advised before deploying critical smart contracts.

The Ether.fi audit competition illustrates the collaborative effort in identifying and rectifying potential vulnerabilities, enhancing the overall security and functionality of the platform.
