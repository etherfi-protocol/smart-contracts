# ether.fi Liquid Restaking Protocol



## Overview

The ether.fi Liquid Restaking Protocol represents the core infrastructure powering ether.fi's vision of becoming the most secure and efficient liquid staking solution in DeFi. This protocol enables:

- **Liquid Staking**: Seamless ETH staking with immediate liquidity through eETH
- **Native Restaking**: Effortless & Secure restaking of staked ETH. Restaking & AVS management is strictly controlled by the Protocol via ether.fi's AVS operator contracts ([link](https://github.com/etherfi-protocol/etherfi-avs-operator)). Restaking rewards are distributed via KING ([link](https://github.com/orgs/King-Protocol/repositories))
- **Massive Integration with DeFi**: Wide integration with DeFi protocols
- **Cross-Chain Capabilities**: Native support for cross-chain staking & bridging of weETH ([link](https://github.com/etherfi-protocol/weETH-cross-chain/))
- **Enterprise-Grade Security**: Rigorous security measures through audits, formal verification, and continuous monitoring


## 🔒 Security

Security is paramount at ether.fi. Our protocol undergoes:

- Regular & Continuous audits by industry leaders
- Formal verification through Certora
- Continuous monitoring and testing



## 🛠️ Development Setup


```bash
# Install & Setup
curl -L https://foundry.paradigm.xyz | bash
git clone https://github.com/etherfi-protocol/smart-contracts.git && cd smart-contracts
git submodule update --init --recursive
forge build

# Testing
forge test                                    # Run all tests
forge test --fork-url <your_rpc_url>         # Fork testing
certoraRun certora/conf/<contract-name>.conf # Formal verification
```

## 📚 Documentation

- [Protocol Documentation](https://etherfi.gitbook.io/etherfi/)



## 📄 License

ether.fi is open-source and licensed under the [MIT License](LICENSE).

---

<p align="center">Built with ❤️ by the ether.fi team</p>