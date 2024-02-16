# etherfi-protocol smart-contracts

Smart Contracts for ether.fi ethereum staking protocol.

From 2024/02/15, we have migrated from our private repo to this public one.
We start with the shallow copy of the latest commit of the prevate one.

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

### Build Troubleshooting Tips

In case you run into an issue of `forge` not being able to find a compatible version of solidity compiler for one of your contracts/scripts, you may want to install the solidity version manager `svm`. To be able to do so, you will need to have [Rust](https://www.rust-lang.org/tools/install) installed on your system and with it the acompanying package manager `cargo`. Once that is done, to install `svm` run the following command:

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

### Inside your Foundry project working directory:

Install Yarn or Node:

```zsh
yarn or npm init
```

Install hardhat

```zsh
yarn add hardhat --save-dev
```

Setup your Hardhat project as you see fit in the same directory. (We assume a typescript setup)
If you have a ReadMe file and test folder already, move them off the root before creating your hardhat project. Then delete the HH generated ones and copy your original ones back.

```zsh
yarn hardhat
```

You will have to run the below everytime you modify the foundry library. Open remappings.txt when done and make sure all remappings are correct. Sometimes weird remappings can be genrated.

```zsh
forge remappings > remappings.txt
```

Now make the following changes to your Hardhat project.

```zsh
yarn add hardhat-preprocessor --save-dev
```

```zsh
Add import "hardhat-preprocessor"; to your hardhat.config.ts file.
```

```zsh
Add import fs from "fs"; to your hardhat.config.ts file.
```

Add the following function to your hardhat.config.ts file.

```zsh
function getRemappings() {
  return fs
    .readFileSync("remappings.txt", "utf8")
    .split("\n")
    .filter(Boolean) // remove empty lines
    .map((line) => line.trim().split("="));
}
```

Add the following to your exported HardhatUserConfig object:

```zsh
preprocess: {
  eachLine: (hre) => ({
    transform: (line: string) => {
      if (line.match(/^\s*import /i)) {
        for (const [from, to] of getRemappings()) {
          if (line.includes(from)) {
            line = line.replace(from, to);
            break;
          }
        }
      }
      return line;
    },
  }),
},
paths: {
  sources: "./src",
  cache: "./cache_hardhat",
},
```
