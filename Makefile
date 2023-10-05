-include .env

.PHONY: all test clean deploy-anvil extract-abi

all: clean remove install update build

# Clean the repo
clean  :; forge clean

# Remove modules
remove :; rm -rf .gitmodules && rm -rf .git/modules/* && rm -rf lib && touch .gitmodules && git add . && git commit -m "modules"

install :; forge install

# Update Dependencies
update:; forge update

build:; forge build

test :; forge test 

snapshot :; forge snapshot

slither :; slither ./src 

format :; prettier --write src/**/*.sol && prettier --write src/*.sol

# solhint should be installed globally
lint :; solhint src/**/*.sol && solhint src/*.sol
#------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# use the "@" to hide the command from your shell 
deploy-goerli-suite :; @forge script script/deploys/DeployEtherFISuite.s.sol:DeployEtherFiSuiteScript --rpc-url ${GOERLI_RPC_URL} --broadcast --verify  -vvvv --slow

deploy-goerli-early-reward-pool :; @forge script script/deploys/DeployEarlyAdopterPool.s.sol:DeployEarlyAdopterPoolScript --rpc-url ${GOERLI_RPC_URL} --broadcast --verify  -vvvv --slow

deploy-phase-1:; forge clean && forge script script/deploys/DeployPhaseOne.s.sol:DeployPhaseOne --rpc-url ${GOERLI_RPC_URL} --broadcast --verify  -vvvv --slow && bash script/extractABI.sh

deploy-test-deposit-contract:; forge clean && forge script script/deploys/testing/DeployTestDepositContract.s.sol:DeployTestDepositContractScript --rpc-url ${GOERLI_RPC_URL} --broadcast --verify  -vvvv --slow && bash script/extractABI.sh

deploy-goerli-phase-1.5:; forge clean && forge script script/deploys/DeployPhaseOnePointFive.s.sol:DeployPhaseOnePointFiveScript --rpc-url ${GOERLI_RPC_URL} --broadcast --verify  -vvvv --slow && bash script/extractABI.sh

deploy-mainnet-phase-1.5:; forge clean && forge script script/deploys/DeployPhaseOnePointFive.s.sol:DeployPhaseOnePointFiveScript --rpc-url ${MAINNET_RPC_URL} --broadcast --verify  -vvvv --slow && bash script/extractABI.sh

deploy-goerli-tvlOracle:; forge clean && forge script script/deploys/DeployTVLOracle.s.sol:DeployTVLOracleScript --rpc-url ${GOERLI_RPC_URL} --broadcast --verify  -vvvv --slow && bash script/extractABI.sh

deploy-goerli-lpaPoints:; forge clean && forge script script/deploys/DeployLoyaltyPointsMarketSafe.sol:DeployLoyaltyPointsMarketSafeScript --rpc-url ${GOERLI_RPC_URL} --broadcast --verify  -vvvv --slow && bash script/extractABI.sh

deploy-mainnet-lpaPoints:; forge clean && forge script script/deploys/DeployLoyaltyPointsMarketSafe.s.sol:DeployLoyaltyPointsMarketSafeScript --rpc-url ${MAINNET_RPC_URL} --broadcast --verify  -vvvv --slow && bash script/extractABI.sh

deploy-optimism-tvlOracle:; forge clean && forge script script/deploys/DeployTVLOracle.s.sol:DeployTVLOracleScript --rpc-url ${OPTIMISM_RPC_URL} --broadcast --verify  -vvvv --slow && bash script/extractABI.sh

deploy-goerli-address-provider:; forge clean && forge script script/deploys/DeployAndPopulateAddressProviderScript.s.sol:DeployAndPopulateAddressProvider --rpc-url ${GOERLI_RPC_URL} --broadcast --verify  -vvvv --slow && bash script/extractABI.sh

deploy-mainnet-address-provider:; forge clean && forge script script/deploys/DeployAndPopulateAddressProviderScript.s.sol:DeployAndPopulateAddressProvider --rpc-url ${MAINNET_RPC_URL} --broadcast --verify  -vvvv --slow && bash script/extractABI.sh

deploy-goerli-phase-2:; forge clean && forge script script/deploys/DeployPhaseTwo.s.sol:DeployPhaseTwoScript --rpc-url ${GOERLI_RPC_URL} --broadcast --verify  -vvvv && bash script/extractABI.sh

deploy-mainnet-phase-2:; forge clean && forge script script/deploys/DeployPhaseTwo.s.sol:DeployPhaseTwoScript --rpc-url ${MAINNET_RPC_URL} --broadcast --verify  -vvvv --slow && bash script/extractABI.sh

deploy-goerli-node-operator :; forge clean && forge script script/specialized/DeployNewNodeOperatorManager.s.sol:DeployNewNodeOperatorManagerScript --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

deploy-node-operator :; forge clean && forge script script/specialized/DeployNewNodeOperatorManager.s.sol:DeployNewNodeOperatorManagerScript --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

#------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
#upgrade commands (GOERLI)

upgrade-all-phase-one-goerli :; forge clean && forge script script/upgrades/StakingManagerUpgradeScript.s.sol:StakingManagerUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/AuctionManagerUpgradeScript.s.sol:AuctionManagerUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/EtherFiNodeScript.s.sol:EtherFiNodeUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/BNFTUpgradeScript.s.sol:BNFTUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/TNFTUpgradeScript.s.sol:TNFTUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/EtherFiNodesManagerUpgradeScript.s.sol:EtherFiNodesManagerUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/ProtocolRevenueManagerUpgradeScript.s.sol:ProtocolRevenueManagerUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-all-phase-one-point-five-goerli :; forge script script/upgrades/LiquidityPoolUpgradeScript.s.sol:LiquidityPoolUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/MembershipManagerUpgradeScript.s.sol:MembershipManagerUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/MembershipNFTUpgradeScript.s.sol:MembershipNFTUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/WeETHUpgradeScript.s.sol:WeEthUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/EETHUpgradeScript.s.sol:EETHUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/RegulationsManagerUpgradeScript.s.sol:RegulationsManagerUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow 

upgrade-all-phase-two-goerli :; forge script script/upgrades/EtherFiOracleUpgradeScript.s.sol:EtherFiOracleUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/EtherFiAdminUpgradeScript.s.sol:EtherFiAdminUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/WithdrawRequestNFTUpgradeScript.s.sol:WithdrawRequestNFTUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow

upgrade-goerli-staking-manager :; forge clean && forge script script/upgrades/StakingManagerUpgradeScript.s.sol:StakingManagerUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-goerli-auction-manager :; forge clean && forge script script/upgrades/AuctionManagerUpgradeScript.s.sol:AuctionManagerUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-goerli-etherfi-node :; forge clean && forge script script/upgrades/EtherFiNodeScript.s.sol:EtherFiNodeUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-goerli-bnft :; forge clean && forge script script/upgrades/BNFTUpgradeScript.s.sol:BNFTUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-goerli-tnft :; forge clean && forge script script/upgrades/TNFTUpgradeScript.s.sol:TNFTUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-goerli-eeth :; forge clean && forge script script/upgrades/EETHUpgradeScript.s.sol:EETHUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-goerli-etherfi_nodes_manager :; forge clean && forge script script/upgrades/EtherFiNodesManagerUpgradeScript.s.sol:EtherFiNodesManagerUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-goerli-liquidity-pool :; forge clean && forge script script/upgrades/LiquidityPoolUpgradeScript.s.sol:LiquidityPoolUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-goerli-membership-manager :; forge script script/upgrades/MembershipManagerUpgradeScript.s.sol:MembershipManagerUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-goerli-membership-nft :; forge clean && forge script script/upgrades/MembershipNFTUpgradeScript.s.sol:MembershipNFTUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-goerli-nft-exchange :; forge clean && forge script script/upgrades/NFTExchangeUpgradeScript.s.sol:NFTExchangeUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-goerli-node-operator-manager :; forge clean && forge script script/upgrades/NodeOperatorManagerUpgradeScript.s.sol:NodeOperatorManagerUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-goerli-protocol_revenue_manager :; forge clean && forge script script/upgrades/ProtocolRevenueManagerUpgradeScript.s.sol:ProtocolRevenueManagerUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-goerli-regulations_manager :; forge clean && forge script script/upgrades/RegulationsManagerUpgradeScript.s.sol:RegulationsManagerUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-goerli-weeth :; forge clean && forge script script/upgrades/WeETHUpgradeScript.s.sol:WeEthUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-goerli-etherfi-oracle :; forge clean && forge script script/upgrades/EtherFiOracleUpgradeScript.s.sol:EtherFiOracleUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-goerli-etherfi-admin :; forge clean && forge script script/upgrades/EtherFiAdminUpgradeScript.s.sol:EtherFiAdminUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-goerli-withdraw-request-nft :; forge clean && forge script script/upgrades/WithdrawRequestNFTUpgradeScript.s.sol:WithdrawRequestNFTUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

#--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
#upgrade commands (MAINNET)

upgrade-all-phase-one-contracts :;  forge clean && forge script script/upgrades/StakingManagerUpgradeScript.s.sol:StakingManagerUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/AuctionManagerUpgradeScript.s.sol:AuctionManagerUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/EtherFiNodeScript.s.sol:EtherFiNodeUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/BNFTUpgradeScript.s.sol:BNFTUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/TNFTUpgradeScript.s.sol:TNFTUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/EtherFiNodesManagerUpgradeScript.s.sol:EtherFiNodesManagerUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/ProtocolRevenueManagerUpgradeScript.s.sol:ProtocolRevenueManagerUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-all-phase-one-point-five :; forge clean && forge script script/upgrades/LiquidityPoolUpgradeScript.s.sol:LiquidityPoolUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/MembershipManagerUpgradeScript.s.sol:MembershipManagerUpgrade --rpc-url ${GOERLI_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/MembershipNFTUpgradeScript.s.sol:MembershipNFTUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/WeETHUpgradeScript.s.sol:WeEthUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/EETHUpgradeScript.s.sol:EETHUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/RegulationsManagerUpgradeScript.s.sol:RegulationsManagerUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow 

upgrade-all-phase-two :; forge script script/upgrades/EtherFiOracleUpgradeScript.s.sol:EtherFiOracleUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/EtherFiAdminUpgradeScript.s.sol:EtherFiAdminUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && forge script script/upgrades/WithdrawRequestNFTUpgradeScript.s.sol:WithdrawRequestNFTUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow

upgrade-staking-manager :; forge clean && forge script script/upgrades/StakingManagerUpgradeScript.s.sol:StakingManagerUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-auction-manager :; forge clean && forge script script/upgrades/AuctionManagerUpgradeScript.s.sol:AuctionManagerUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-etherfi-node :; forge clean && forge script script/upgrades/EtherFiNodeScript.s.sol:EtherFiNodeUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-bnft :; forge clean && forge script script/upgrades/BNFTUpgradeScript.s.sol:BNFTUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-tnft :; forge clean && forge script script/upgrades/TNFTUpgradeScript.s.sol:TNFTUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-eeth :; forge clean && forge script script/upgrades/EETHUpgradeScript.s.sol:EETHUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-etherfi_nodes_manager :; forge clean && forge script script/upgrades/EtherFiNodesManagerUpgradeScript.s.sol:EtherFiNodesManagerUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-node-operator-manager :; forge clean && forge script script/upgrades/NodeOperatorManagerUpgradeScript.s.sol:NodeOperatorManagerUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-liquidity-pool :; forge clean && forge script script/upgrades/LiquidityPoolUpgradeScript.s.sol:LiquidityPoolUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-membership-manager :; forge clean && forge script script/upgrades/MembershipManagerUpgradeScript.s.sol:MembershipManagerUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-membership-nft :; forge clean && forge script script/upgrades/MembershipNFTUpgradeScript.s.sol:MembershipNFTUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-nft-exchange :; forge clean && forge script script/upgrades/NFTExchangeUpgradeScript.s.sol:NFTExchangeUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-protocol_revenue_manager :; forge clean && forge script script/upgrades/ProtocolRevenueManagerUpgradeScript.s.sol:ProtocolRevenueManagerUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-regulations_manager :; forge clean && forge script script/upgrades/RegulationsManagerUpgradeScript.s.sol:RegulationsManagerUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-weeth :; forge clean && forge script script/upgrades/WeETHUpgradeScript.s.sol:WeEthUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-etherfi-oracle :; forge clean && forge script script/upgrades/EtherFiOracleUpgradeScript.s.sol:EtherFiOracleUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-etherfi-admin :; forge clean && forge script script/upgrades/EtherFiAdminUpgradeScript.s.sol:EtherFiAdminUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

upgrade-withdraw-request-nft :; forge clean && forge script script/upgrades/WithdrawRequestNFTUpgradeScript.s.sol:WithdrawRequestNFTUpgrade --rpc-url ${MAINNET_RPC_URL} --broadcast --verify -vvvv --slow && bash script/extractABI.sh

#--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

update-goerli-admins:; forge clean && forge script script/specialized/UpdateAdminScripts.s.sol:UpdateAdmins --rpc-url ${GOERLI_RPC_URL} --broadcast -vvvv --slow

update-admins:; forge clean && forge script script/specialized/UpdateAdminScripts.s.sol:UpdateAdmins --rpc-url ${MAINNET_RPC_URL} --broadcast -vvvv --slow

transfer-goerli-ownership:; forge clean && forge script script/specialized/TransferOwnership.s.sol:TransferOwnership --rpc-url ${GOERLI_RPC_URL} --broadcast -vvvv --slow

transfer-ownership:; forge clean && forge script script/specialized/TransferOwnership.s.sol:TransferOwnership --rpc-url ${MAINNET_RPC_URL} --broadcast -vvvv --slow

deploy-patch-2:; forge clean && forge script script/DeployPatch2.s.sol:DeployPatchV3 --rpc-url ${GOERLI_RPC_URL} --broadcast --verify  -vvvv --slow

extract-abi :; bash script/extractABI.sh