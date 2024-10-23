# etherfi-protocol smart-contracts

Smart Contracts for ether.fi ethereum staking protocol.

From 2024/02/15, we have migrated from our private repo to this public one.
We start with the shallow copy of the latest commit of the private one.

# EtherFi smart contracts setup

## Get Started

### Install Foundry

```zsh
curl -L https://foundry.paradigm.xyz | bash
```

### Update Foundry

```zsh
foundryup
```

### Install Submodules

```zsh
git submodule update --init --recursive
```

### Formatter and Linter

Run `yarn` to install `package.json` which includes our formatter and linter. We will switch over to Foundry's sol formatter and linter once released.

### Set your environment variables

Check `.env.example` to see some of the environment variables you should have set in `.env` in order to run some of the commands.

### Compile Project

```zsh
forge build
```

### Run Project Tests

```zsh
forge test
```

### Run Project Fork Tests

```zsh
forge test --fork-url <your_rpc_url>>
```

### Run Project Fork Tests

```zsh
certoraRun certora/conf/<contract-name>.conf
```

### Build Troubleshooting Tips

In case you run into an issue of `forge` not being able to find a compatible version of solidity compiler for one of your contracts/scripts, you may want to install the solidity version manager `svm`. To be able to do so, you will need to have [Rust](https://www.rust-lang.org/tools/install) installed on your system and with it the accompanying package manager `cargo`. Once that is done, to install `svm` run the following command:

```zsh
cargo install svm-rs
```

To list the available versions of solidity compiler run:

```zsh
svm list
```

Make sure the version you need is in this list, or choose the closest one and install it:

```zsh
svm install "0.7.6"
```

