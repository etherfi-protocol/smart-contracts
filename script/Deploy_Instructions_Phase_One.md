# EtherFi Contract Phase One Deploy Instructions

# Step 1:
## Setup Environment

Once you have the environment on VS code, you will need to run the following commands to get everything working.
* curl -L https://foundry.paradigm.xyz | bash
* foundryup
* git submodule update --init --recursive

Make sure you have xcode installed. You will need it to run the makefile.
* xcode-select -p 
If not, install it with
* xcode-select --install

Install the jq utility.
For windows use Chocolatey NuGet to install jq 1.5 with:
*  chocolatey install jq
For Mac use Homebrew to install jq 1.6 with:
* brew install jq

# Step 2:
## Deploy EtherFi Suite
 
Deploy the EtherFi phase one suite.

This consists of the Node Operator Manager, Auction Manager, Staking Manager, EtherFi Nodes Manager, Protocol Revenue Manager, EtherFi Node, Treasury, TNFT, BNFT and Score Manager contracts. The deploy script will set all dependencies automatically.

There are a few important variables to set before running the deploy command.

If you currently do not have a .env file, and only a .example.env, perform the following:
1. Copy the .example.env file and create a new file with the same contents called .env (this name will hide it from public sources)
2. The file will consist of the following:

    * GOERLI_RPC_URL=
    * PRIVATE_KEY=
    * ETHERSCAN_API_KEY=

3. Please fill in the data accordingly. You can find a GOERLI_RPC_URL or MAINNET_RPC_URL in the case of mainnet deployment, on Alchemy. The private key used here will be the multisig wallet you wish to use. And lastly you can retrieve a ETHERSCAN_API_KEY from etherscan if you sign up.

4. Once your environment is set up, run
    source .env

5. Lastly, run the following command to deploy
    ```make deploy-phase-1```

# Step 3
## Set Merkle Root

Once all contracts have been deployed and dependencies set up, we will need to update the merkle roots. 

1. Generate the merkle tree for the Node Operators and call the updateMerkleRoot function in the Node Operator Manager to set the root.
2. Generate the merkle tree for stakers who are whitelisted and call the updateMerkleRoot function in the Staking Manager to set the root.

