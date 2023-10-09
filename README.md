# dappContracts

Smart Contracts for Ether Fi dapp

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

## Deployment Instructions

### Update foundry.toml

The foundry.toml file allows foundry to read which network it should deploy smart contracts to. It is here where you set this variable. For example (deploying to Goerli):

```zsh
[rpc_endpoints]
goerli = "${GOERLI_RPC_URL}"

[etherscan]
goerli = { key = "${ETHERSCAN_API_KEY}" }
```

The first part refers to the RPC endpoint to be used when deploying. You can get this through Alchemy or Infura. Simply create an account and create a new RPC endpoint, selecting the respective network you wish to deploy to.

The second part relates to the etherscan API key that will be used for verifying the contracts on etherscan. If you prefer to keep you contracts unverified, this part can be skipped. To generate an API key, create an account on etherscan and select generate API key.

### Updating env file

Many variables used in deployment, such as the deployer private key, are advised to be kept private. An env file is a great way to achieve this. Make a copy of the .example.env file and create a new file called .env in the root directory. In this file, you will store your RPC endpoint, private key as well as etehrscan api key. Fill in the required parameters in the .env to aid the deployment process.

### Deploy Script

The deploy script controls the actual deployment of the contracts to the specified network. The following part refers to the generation of the merkletree and merkle root:

```zsh
Merkle merkle = new Merkle();
bytes32[] memory data = new bytes32[](5);
data[0] = bytes32(keccak256(
        abi.encodePacked(0x1c5fffDbFDE331A10Ab1e32da8c4Dff210B43145)
    ));
data[1] = bytes32(keccak256(
        abi.encodePacked(0x2f2806e8b288428f23707A69faA60f52BC565c17)
    ));
data[2] = bytes32(keccak256(
        abi.encodePacked(0x5dfb8BC4830ccF60d469D546aEC36531c97B96b5)
    ));
data[3] = bytes32(keccak256(
        abi.encodePacked(0x4507cfB4B077d5DBdDd520c701E30173d5b59Fad)
    ));
data[4] = bytes32(keccak256(
        abi.encodePacked(0xCd5EBC2dD4Cb3dc52ac66CEEcc72c838B40A5931)
    ));

bytes32 root = merkle.getRoot(data);
bytes32[] memory proofOne = merkle.getProof(data, 0);
bytes32[] memory proofTwo = merkle.getProof(data, 1);
bytes32[] memory proofThree = merkle.getProof(data, 2);
bytes32[] memory proofFour = merkle.getProof(data, 3);
bytes32[] memory proofFive = merkle.getProof(data, 4);
```

The above generates a bytes32 array holding five public addresses. If you want more or less, you can add and removes lines as you see fit. However it is important to update the following line accordingly:

```zsh
bytes32[] memory data = new bytes32[](5);
```

Make sure the number in the ( ) corresponds to how many addresses are being whitelisted.

The next set of code refers to the actual deployment of the contracts:

```zsh
uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
vm.startBroadcast(deployerPrivateKey);

Treasury treasury = new Treasury();
Auction auction = new Auction(address(treasury));
Deposit deposit = new Deposit(address(auction));
```

The first part of the above code retrieves the private key from the .env file and uses that address to deploy the contracts. The second part is the functionality of actually creating the new contracts.

Once this is all populated, you can run the deploy function to perform the deployment to the provided network. When you ready, run the following command:

```zsh
source .env
```

followed by:

```zsh
forge script script/Deploy.s.sol:MyScript --rpc-url $GOERLI_RPC_URL --broadcast --verify -vvvv
```

This will run the deployment and verify the contracts on the provided network. It will print data to the terminal which will provide you with the relevant contract addresses and merkle proofs for each whitelisted address.

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
