# Role Management Documentation

This document provides a comprehensive overview of role-based access control for all smart contracts in the EtherFi protocol. Each contract section contains tables organized by role type, showing which functions are controlled by specific roles and their corresponding modifiers.

## Table Structure

Each table contains:

- Function Name: The name of the function with role-based access control
- Modifier: The modifier used to enforce the role restriction
- Role: The role that has permission to call the function

## Contracts

### AuctionManager

#### Owner-Only Functions

| Function                         | Modifier  | Role  |
| -------------------------------- | --------- | ----- |
| initializeOnUpgrade              | onlyOwner | Owner |
| initializeV2dot5                 | onlyOwner | Owner |
| setStakingManagerContractAddress | onlyOwner | Owner |
| updateNodeOperatorManager        | onlyOwner | Owner |
| \_authorizeUpgrade               | onlyOwner | Owner |

#### AUCTION_ADMIN_ROLE Functions

| Function                       | Modifier                                 | Role               |
| ------------------------------ | ---------------------------------------- | ------------------ |
| setMinBidPrice                 | roleRegistry.hasRole(AUCTION_ADMIN_ROLE) | AUCTION_ADMIN_ROLE |
| setMaxBidPrice                 | roleRegistry.hasRole(AUCTION_ADMIN_ROLE) | AUCTION_ADMIN_ROLE |
| setAccumulatedRevenueThreshold | roleRegistry.hasRole(AUCTION_ADMIN_ROLE) | AUCTION_ADMIN_ROLE |
| transferAccumulatedRevenue     | roleRegistry.hasRole(AUCTION_ADMIN_ROLE) | AUCTION_ADMIN_ROLE |

#### PROTOCOL_PAUSER Functions

| Function      | Modifier                              | Role            |
| ------------- | ------------------------------------- | --------------- |
| pauseContract | roleRegistry.hasRole(PROTOCOL_PAUSER) | PROTOCOL_PAUSER |

#### PROTOCOL_UNPAUSER Functions

| Function        | Modifier                                | Role              |
| --------------- | --------------------------------------- | ----------------- |
| unPauseContract | roleRegistry.hasRole(PROTOCOL_UNPAUSER) | PROTOCOL_UNPAUSER |

#### onlyStakingManagerContract Functions

| Function                     | Modifier                                   
| ---------------------------- | ------------------------------------------ 
| reEnterAuction               | onlyStakingManagerContract |  
| updateSelectedBidInformation | onlyStakingManagerContract |  
| processAuctionFeeTransfer    | onlyStakingManagerContract |  

### EtherFiNode

#### onlyEtherFiNodeManagerContract Functions

| Function                           | Modifier                                 
| ---------------------------------- | --------------------
| migrateVersion                     | onlyEtherFiNodeManagerContract |  
| registerValidator                  | onlyEtherFiNodeManagerContract |  
| unRegisterValidator                | onlyEtherFiNodeManagerContract |  
| updateNumberOfAssociatedValidators | onlyEtherFiNodeManagerContract |  
| updateNumExitedValidators          | onlyEtherFiNodeManagerContract |  
| processNodeExit                    | onlyEtherFiNodeManagerContract |  
| processFullWithdraw                | onlyEtherFiNodeManagerContract |  
| completeQueuedWithdrawal           | onlyEtherFiNodeManagerContract |  
| completeQueuedWithdrawals          | onlyEtherFiNodeManagerContract |  
| withdrawFunds                      | onlyEtherFiNodeManagerContract |  
| callEigenPod                       | onlyEtherFiNodeManagerContract |  
| forwardCall                        | onlyEtherFiNodeManagerContract |  
| startCheckpoint                    | onlyEtherFiNodeManagerContract |  
| setProofSubmitter                  | onlyEtherFiNodeManagerContract |  
| queueEigenpodFullWithdrawal        | onlyEtherFiNodeManagerContract |  

### EtherFiNodesManager

#### Owner-Only Functions

| Function                       | Modifier  | Role  |
| ------------------------------ | --------- | ----- |
| \_authorizeUpgrade             | onlyOwner | Owner |

#### NODE_ADMIN_ROLE Functions

| Function                            | Modifier                              | Role            |
| ----------------------------------- | ------------------------------------- | --------------- |
| processNodeExit                     | roleRegistry.hasRole(NODE_ADMIN_ROLE) | NODE_ADMIN_ROLE |
| batchQueueRestakedWithdrawal        | roleRegistry.hasRole(NODE_ADMIN_ROLE) | NODE_ADMIN_ROLE |
| markBeingSlashed                    | roleRegistry.hasRole(NODE_ADMIN_ROLE) | NODE_ADMIN_ROLE |
| setNonExitPenalty                   | roleRegistry.hasRole(NODE_ADMIN_ROLE) | NODE_ADMIN_ROLE |
| completeQueuedWithdrawals           | roleRegistry.hasRole(NODE_ADMIN_ROLE) | NODE_ADMIN_ROLE |

#### WHITELIST_UPDATER Functions

| Function                            | Modifier                              | Role            |
| ----------------------------------- | ------------------------------------- | --------------- |
| updateAllowedForwardedExternalCalls | roleRegistry.hasRole(WHITELIST_UPDATER) | WHITELIST_UPDATER |
| updateAllowedForwardedEigenpodCalls | roleRegistry.hasRole(WHITELIST_UPDATER) | WHITELIST_UPDATER |


#### PROTOCOL_PAUSER Functions

| Function      | Modifier                              | Role            |
| ------------- | ------------------------------------- | --------------- |
| pauseContract | roleRegistry.hasRole(PROTOCOL_PAUSER) | PROTOCOL_PAUSER |

#### PROTOCOL_UNPAUSER Functions

| Function        | Modifier                                | Role              |
| --------------- | --------------------------------------- | ----------------- |
| unPauseContract | roleRegistry.hasRole(PROTOCOL_UNPAUSER) | PROTOCOL_UNPAUSER |


#### EIGENPOD_CALLER_ROLE Functions

| Function            | Modifier                                   | Role                 |
| ------------------- | ------------------------------------------ | -------------------- |
| forwardEigenpodCall | roleRegistry.hasRole(EIGENPOD_CALLER_ROLE) | EIGENPOD_CALLER_ROLE |
| startCheckpoint                     | roleRegistry.hasRole(EIGENPOD_CALLER_ROLE) | EIGENPOD_CALLER_ROLE |
| setProofSubmitter                   | roleRegistry.hasRole(EIGENPOD_CALLER_ROLE) | EIGENPOD_CALLER_ROLE |

#### EXTERNAL_CALLER_ROLE Functions

| Function            | Modifier                                   | Role                 |
| ------------------- | ------------------------------------------ | -------------------- |
| forwardExternalCall | roleRegistry.hasRole(EXTERNAL_CALLER_ROLE) | EXTERNAL_CALLER_ROLE |

#### onlyStakingManagerContract Functions

| Function                    | Modifier                                   | Role                 |
| --------------------------- | ------------------------------------------ | -------------------- |
| allocateEtherFiNode         | onlyStakingManagerContract |  |
| registerValidator           | onlyStakingManagerContract |  |
| unregisterValidator         | onlyStakingManagerContract |  |
| setValidatorPhase           | onlyStakingManagerContract |  |
| incrementNumberOfValidators | onlyStakingManagerContract |  |

### Liquifier

#### Owner-Only Functions

| Function                          | Modifier  | Role  |
| --------------------------------- | --------- | ----- |
| initializeOnUpgrade               | onlyOwner | Owner |
| updateWhitelistedToken            | onlyOwner | Owner |
| registerToken                     | onlyOwner | Owner |
| \_authorizeUpgrade                | onlyOwner | Owner |

#### EETH_STETH_SWAPPER Functions

| Function         | Modifier                                   | Role                 |
| -------------    | ------------------------------------------ | -------------------- |
| swapEEthForStEth | roleRegistry.hasRole(EETH_STETH_SWAPPER)   | EETH_STETH_SWAPPER |


#### LIQUIFIER_ADMIN_ROLE Functions

| Function                    | Modifier                                   | Role                 |
| --------------------------- | ------------------------------------------ | -------------------- |
| withdrawEther               | roleRegistry.hasRole(LIQUIFIER_ADMIN_ROLE) | LIQUIFIER_ADMIN_ROLE |
| sendToEtherFiRestakeManager | roleRegistry.hasRole(LIQUIFIER_ADMIN_ROLE) | LIQUIFIER_ADMIN_ROLE |
| withdrawEEth                | roleRegistry.hasRole(LIQUIFIER_ADMIN_ROLE) | LIQUIFIER_ADMIN_ROLE |
| sendToEtherFiRestaker       | roleRegistry.hasRole(LIQUIFIER_ADMIN_ROLE) | LIQUIFIER_ADMIN_ROLE |

#### PROTOCOL_UNPAUSER Functions

| Function        | Modifier                                | Role              |
| --------------- | --------------------------------------- | ----------------- |
| unPauseContract | roleRegistry.hasRole(PROTOCOL_UNPAUSER) | PROTOCOL_UNPAUSER |

#### PROTOCOL_PAUSER Functions

| Function                    | Modifier                              | Role            |
| ----------------------------|---------------------------------------| --------------- |
| updateDiscountInBasisPoints | roleRegistry.hasRole(PROTOCOL_PAUSER) | PROTOCOL_PAUSER |
| updateQuoteStEthWithCurve   | roleRegistry.hasRole(PROTOCOL_PAUSER) | PROTOCOL_PAUSER |
| pauseContract               | roleRegistry.hasRole(PROTOCOL_PAUSER) | PROTOCOL_PAUSER |

### TVLOracle

#### Owner-Only Functions

| Function         | Modifier  | Role  |
| ---------------- | --------- | ----- |
| setTVLAggregator | onlyOwner | Owner |

#### onlyTVLAggregator Functions

| Function | Modifier                                  |
| -------- | ----------------------------------------- |
| setTvl   | onlyTVLAggregator                         |


### Pauser

#### PAUSER_ADMIN Functions

| Function       | Modifier               | Role         |
| -------------- | ---------------------- | ------------ |
| addPausable    | onlyRole(PAUSER_ADMIN) | PAUSER_ADMIN |
| removePausable | onlyRole(PAUSER_ADMIN) | PAUSER_ADMIN |

#### PROTOCOL_PAUSER Functions

| Function      | Modifier                                 | Role            |
| ------------- | ---------------------------------------- | --------------- |
| pauseSingle   | onlyRole(roleRegistry.PROTOCOL_PAUSER()) | PROTOCOL_PAUSER |
| pauseMultiple | onlyRole(roleRegistry.PROTOCOL_PAUSER()) | PROTOCOL_PAUSER |
| pauseAll      | onlyRole(roleRegistry.PROTOCOL_PAUSER()) | PROTOCOL_PAUSER |

#### PROTOCOL_UNPAUSER Functions

| Function        | Modifier                                   | Role              |
| --------------- | ------------------------------------------ | ----------------- |
| unpauseSingle   | onlyRole(roleRegistry.PROTOCOL_UNPAUSER()) | PROTOCOL_UNPAUSER |
| unpauseMultiple | onlyRole(roleRegistry.PROTOCOL_UNPAUSER()) | PROTOCOL_UNPAUSER |
| unpauseAll      | onlyRole(roleRegistry.PROTOCOL_UNPAUSER()) | PROTOCOL_UNPAUSER |

#### PROTOCOL_UPGRADER Functions

| Function           | Modifier                                   | Role              |
| ------------------ | ------------------------------------------ | ----------------- |
| \_authorizeUpgrade | onlyRole(roleRegistry.PROTOCOL_UPGRADER()) | PROTOCOL_UPGRADER |

### MembershipNFT

#### Owner-Only Functions

| Function            | Modifier  | Role  |
| ------------------- | --------- | ----- |
| initializeOnUpgrade | onlyOwner | Owner |
| updateAdmin         | onlyOwner | Owner |
| \_authorizeUpgrade  | onlyOwner | Owner |

#### admin Functions

| Function                 | Modifier  |
| ------------------------ | ----------|
| setMaxTokenId            | onlyAdmin
| setUpForEap              | onlyAdmin
| setMintingPaused         | onlyAdmin
| setContractMetadataURI   | onlyAdmin
| setMetadataURI           | onlyAdmin
| alertMetadataUpdate      | onlyAdmin
| alertBatchMetadataUpdate | onlyAdmin

#### MEMBERSHIP_MANAGER_ROLE Functions

| Function                  | Modifier                     |
| ------------------------- | -----------------------------|
| mint                      | onlyMembershipManagerContract
| burn                      | onlyMembershipManagerContract
| incrementLock             | onlyMembershipManagerContract
| processDepositFromEapUser | onlyMembershipManagerContract

### WithdrawRequestNFT

#### Owner-Only Functions

| Function                           | Modifier  | Role  |
| -----------------------------------| --------- | ----- |
| initializeV2dot5                   | onlyOwner | Owner |
| updateAccumulatedDustEEthShares    | onlyOwner | Owner |
| seizeInvalidRequest                | onlyOwner | Owner |
| \_authorizeUpgrade                 | onlyOwner | Owner |

#### WITHDRAW_NFT_ADMIN_ROLE Functions

| Function                          | Modifier                                      | Role                    |
| -----------------------------     | --------------------------------------------- | ----------------------- |
| withdrawAccumulatedDustEEthShares | roleRegistry.hasRole(WITHDRAW_NFT_ADMIN_ROLE) | WITHDRAW_NFT_ADMIN_ROLE |
| finalizeRequests                  | roleRegistry.hasRole(WITHDRAW_NFT_ADMIN_ROLE) | WITHDRAW_NFT_ADMIN_ROLE |
| invalidateRequest                 | roleRegistry.hasRole(WITHDRAW_NFT_ADMIN_ROLE) | WITHDRAW_NFT_ADMIN_ROLE |
| validateRequest                   | roleRegistry.hasRole(WITHDRAW_NFT_ADMIN_ROLE) | WITHDRAW_NFT_ADMIN_ROLE |

#### onlyLiquidtyPool Functions

| Function        | Modifier        |
| --------------- | ----------------|
| requestWithdraw | onlyLiquidtyPool

### DepositAdapter

#### Owner-Only Functions

| Function           | Modifier  | Role  |
| ------------------ | --------- | ----- |
| \_authorizeUpgrade | onlyOwner | Owner |

### EtherFiRestaker

#### Owner-Only Functions

| Function           | Modifier  | Role  |
| ------------------ | --------- | ----- |
| updateAdmin        | onlyOwner | Owner |
| \_authorizeUpgrade | onlyOwner | Owner |

#### onlyAdmin Functions

| Function                  | Modifier |
| ------------------------- | ---------|
| stEthRequestWithdrawal    | onlyAdmin
| stEthClaimWithdrawals     | onlyAdmin
| withdrawEther             | onlyAdmin
| delegateTo                | onlyAdmin
| undelegate                | onlyAdmin
| depositIntoStrategy       | onlyAdmin
| queueWithdrawals          | onlyAdmin
| completeQueuedWithdrawals | onlyAdmin
| updatePauser              | onlyAdmin
| unPauseContract           | onlyAdmin


#### onlyPauser Functions

| Function      | Modifier  |
| ------------- | ----------|
| pauseContract | onlyPauser

### BucketRateLimiter

#### Owner-Only Functions

| Function                       | Modifier  | Role  |
| ------------------------------ | --------- | ----- |
| setCapacity                    | onlyOwner | Owner |
| setRefillRatePerSecond         | onlyOwner | Owner |
| registerToken                  | onlyOwner | Owner |
| setCapacityPerToken            | onlyOwner | Owner |
| setRefillRatePerSecondPerToken | onlyOwner | Owner |
| updateConsumer                 | onlyOwner | Owner |
| updateAdmin                    | onlyOwner | Owner |
| updatePauser                   | onlyOwner | Owner |
| \_authorizeUpgrade             | onlyOwner | Owner |

#### PROTOCOL_UNPAUSER Functions

| Function        | Modifier                                | Role              |
| --------------- | --------------------------------------- | ----------------- |
| unPauseContract | roleRegistry.hasRole(PROTOCOL_UNPAUSER) | PROTOCOL_UNPAUSER |

#### PROTOCOL_PAUSER Functions

| Function      | Modifier                              | Role            |
| ------------- | ------------------------------------- | --------------- |
| pauseContract | roleRegistry.hasRole(PROTOCOL_PAUSER) | PROTOCOL_PAUSER |

### TNFT

#### Owner-Only Functions

| Function            | Modifier  | Role  |
| ------------------- | --------- | ----- |
| initializeOnUpgrade | onlyOwner | Owner |
| \_authorizeUpgrade  | onlyOwner | Owner |

#### onlyStakingManager Functions

| Function               | Modifier          |
| ---------------------- | ------------------|
| mint                   | onlyStakingManager 
| burnFromCancelBNftFlow | onlyStakingManager 

#### onlyEtherFiNodesManager Functions

| Function           | Modifier               | 
| ------------------ | -----------------------|
| burnFromWithdrawal | onlyEtherFiNodesManager

### BNFT

#### Owner-Only Functions

| Function            | Modifier  | Role  |
| ------------------- | --------- | ----- |
| initializeOnUpgrade | onlyOwner | Owner |
| \_authorizeUpgrade  | onlyOwner | Owner |

#### onlyStakingManager Functions

| Function               | Modifier          |
| ---------------------- | ------------------|
| mint                   | onlyStakingManager
| burnFromCancelBNftFlow | onlyStakingManager

#### onlyEtherFiNodesManager Functions

| Function           | Modifier                |
| ------------------ | ------------------------|
| burnFromWithdrawal | onlyEtherFiNodesManager

### EtherFiRewardsRouter

#### Owner-Only Functions

| Function           | Modifier  | Role  |
| ------------------ | --------- | ----- |
| \_authorizeUpgrade | onlyOwner | Owner |

#### ETHERFI_ROUTER_ADMIN Functions

| Function                 | Modifier                                   | Role                 |
| -------------            | ------------------------------------------ | -------------------- |
| withdrawToLiquidityPool  | roleRegistry.hasRole(ETHERFI_ROUTER_ADMIN) | ETHERFI_ROUTER_ADMIN |
| recoverERC20             | roleRegistry.hasRole(ETHERFI_ROUTER_ADMIN) | ETHERFI_ROUTER_ADMIN |
| recoverERC721            | roleRegistry.hasRole(ETHERFI_ROUTER_ADMIN) | ETHERFI_ROUTER_ADMIN |

### EETH

#### Owner-Only Functions

| Function           | Modifier  | Role  |
| ------------------ | --------- | ----- |
| \_authorizeUpgrade | onlyOwner | Owner |

#### onlyPoolContract Functions

| Function    | Modifier        |
| ------------| ----------------|
| mintShares  | onlyPoolContract
| burnShares  | onlyPoolContract

### EtherFiAdmin

#### Owner-Only Functions

| Function           | Modifier  | Role  |
| ------------------ | --------- | ----- |
| \_authorizeUpgrade | onlyOwner | Owner |
| initializeV2dot5 | onlyOwner | Owner |
| setValidatorTaskBatchSize | onlyOwner | Owner |
| updateAcceptableRebaseApr | onlyOwner | Owner |

#### ETHERFI_ADMIN_ADMIN_ROLE Functions

| Function                 | Modifier                                   | Role                 |
| -------------            | ------------------------------------------ | -------------------- |
| executeTasks                       | roleRegistry.hasRole(ETHERFI_ADMIN_ADMIN_ROLE) | ETHERFI_ADMIN_ADMIN_ROLE |
| executeValidatorManagementTask     | roleRegistry.hasRole(ETHERFI_ADMIN_ADMIN_ROLE) | ETHERFI_ADMIN_ADMIN_ROLE |
| invalidateValidatorManagementTask  | roleRegistry.hasRole(ETHERFI_ADMIN_ADMIN_ROLE) | ETHERFI_ADMIN_ADMIN_ROLE |
| updatePostReportWaitTimeInSlots    | roleRegistry.hasRole(ETHERFI_ADMIN_ADMIN_ROLE) | ETHERFI_ADMIN_ADMIN_ROLE |

### WeEETH

#### Owner-Only Functions

| Function            | Modifier  | Role  |
| ------------------  | --------- | ----- |
| \_authorizeUpgrade  | onlyOwner | Owner |
| rescueTreasuryWeeth | onlyOwner | Owner |


### EtherFiOracle

#### Owner-Only Functions

| Function           | Modifier  | Role  |
| ------------------ | --------- | ----- |
| \_authorizeUpgrade | onlyOwner | Owner |
| initializeV2dot5 | onlyOwner | Owner |
| addCommitteeMember | onlyOwner | Owner |
| removeCommitteeMember | onlyOwner | Owner |
| manageCommitteeMember | onlyOwner | Owner |
| setQuorumSize | onlyOwner | Owner |
| setEtherFiAdmin | onlyOwner | Owner |

#### ORACLE_ADMIN_ROLE Functions

| Function                                 | Modifier                                   | Role                 |
| -------------                            | ------------------------------------------ | -------------------- |
| setReportStartSlot                       | roleRegistry.hasRole(ORACLE_ADMIN_ROLE) | ORACLE_ADMIN_ROLE |
| setOracleReportPeriod                    | roleRegistry.hasRole(ORACLE_ADMIN_ROLE) | ORACLE_ADMIN_ROLE |
| setConsensusVersion                      | roleRegistry.hasRole(ORACLE_ADMIN_ROLE) | ORACLE_ADMIN_ROLE |
| updateLastPublishedBlockStamps           | roleRegistry.hasRole(ORACLE_ADMIN_ROLE) | ORACLE_ADMIN_ROLE |
| unpublishReport                          | roleRegistry.hasRole(ORACLE_ADMIN_ROLE) | ORACLE_ADMIN_ROLE |

#### PROTOCOL_PAUSER Functions

| Function      | Modifier                              | Role                 |
| ------------- | --------------------------------------| -------------------- |
| pauseContract | roleRegistry.hasRole(PROTOCOL_PAUSER) | PROTOCOL_PAUSER |

#### PROTOCOL_UNPAUSER Functions

| Function        | Modifier                                   | Role                 |
| -------------   | ------------------------------------------ | -------------------- |
| unpauseContract | roleRegistry.hasRole(PROTOCOL_UNPAUSER)    | PROTOCOL_UNPAUSER |

### LiquidityPool

#### Owner-Only Functions

| Function           | Modifier  | Role  |
| ------------------ | --------- | ----- |
| \_authorizeUpgrade | onlyOwner | Owner |
| initializeV2dot5 | onlyOwner | Owner |
| initializeOnUpgrade | onlyOwner | Owner |
| setTreasury | onlyOwner | Owner |
| updateTvlSplits | onlyOwner | Owner |

#### LIQUIDITY_POOL_ADMIN_ROLE Functions

| Function                   | Modifier                                        | Role                 |
| -------------              | ------------------------------------------      | -------------------- |
| batchApproveRegistration   | roleRegistry.hasRole(LIQUIDITY_POOL_ADMIN_ROLE) | LIQUIDITY_POOL_ADMIN_ROLE |
| registerAsBnftHolder       | roleRegistry.hasRole(LIQUIDITY_POOL_ADMIN_ROLE) | LIQUIDITY_POOL_ADMIN_ROLE |
| deRegisterBnftHolder       | roleRegistry.hasRole(LIQUIDITY_POOL_ADMIN_ROLE) | LIQUIDITY_POOL_ADMIN_ROLE |
| sendExitRequests           | roleRegistry.hasRole(LIQUIDITY_POOL_ADMIN_ROLE) | LIQUIDITY_POOL_ADMIN_ROLE |
| setRestakeBnftDeposits     | roleRegistry.hasRole(LIQUIDITY_POOL_ADMIN_ROLE) | LIQUIDITY_POOL_ADMIN_ROLE |
| updateBnftMode             | roleRegistry.hasRole(LIQUIDITY_POOL_ADMIN_ROLE) | LIQUIDITY_POOL_ADMIN_ROLE |

#### PROTOCOL_PAUSER Functions

| Function      | Modifier                              | Role                 |
| ------------- | --------------------------------------| -------------------- |
| pauseContract | roleRegistry.hasRole(PROTOCOL_PAUSER) | PROTOCOL_PAUSER |

#### PROTOCOL_UNPAUSER Functions

| Function        | Modifier                                   | Role                 |
| -------------   | ------------------------------------------ | -------------------- |
| unPauseContract | roleRegistry.hasRole(PROTOCOL_UNPAUSER)    | PROTOCOL_UNPAUSER |


### MembershipManager

#### Owner-Only Functions

| Function           | Modifier  | Role  |
| ------------------ | --------- | ----- |
| \_authorizeUpgrade | onlyOwner | Owner |
| updateAdmin | onlyOwner | Owner |
| initializeOnUpgrade | onlyOwner | Owner |

#### onlyEtherFiAdmin Functions

| Function                   | Modifier        |
| -------------              | ----------------|
| rebase                     | onlyEtherFiAdmin

#### _requireAdmin Functions

| Function                   | Modifier        |
| -------------              | ----------------|
| addNewTier                     | onlyEtherFiAdmin
| updateTier                     | onlyEtherFiAdmin
| setPoints                     | onlyEtherFiAdmin
| updatePointsParams                     | onlyEtherFiAdmin
| setWithdrawalLockBlocks                     | onlyEtherFiAdmin
| setDepositAmountParams                     | onlyEtherFiAdmin
| setTopUpCooltimePeriod                     | onlyEtherFiAdmin
| setFeeAmounts                     | onlyEtherFiAdmin
| setFanBoostThresholdEthAmount                     | onlyEtherFiAdmin
| pauseContract                     | onlyEtherFiAdmin
| unPauseContract                     | onlyEtherFiAdmin



### NodeOperatorManager

#### Owner-Only Functions

| Function           | Modifier  | Role  |
| ------------------ | --------- | ----- |
| \_authorizeUpgrade | onlyOwner | Owner |
| initializeV2dot5 | onlyOwner | Owner |
| initializeOnUpgrade | onlyOwner | Owner |
| setAuctionContractAddress | onlyOwner | Owner |

#### NODE_OPERATOR_MANAGER_ADMIN_ROLE Functions

| Function                   | Modifier                                        | Role                 |
| -------------              | ------------------------------------------      | -------------------- |
| addToWhitelist             | roleRegistry.hasRole(NODE_OPERATOR_MANAGER_ADMIN_ROLE) | NODE_OPERATOR_MANAGER_ADMIN_ROLE |
| removeFromWhitelist        | roleRegistry.hasRole(NODE_OPERATOR_MANAGER_ADMIN_ROLE) | NODE_OPERATOR_MANAGER_ADMIN_ROLE |
  
#### PROTOCOL_PAUSER Functions

| Function      | Modifier                              | Role                 |
| ------------- | --------------------------------------| -------------------- |
| pauseContract | roleRegistry.hasRole(PROTOCOL_PAUSER) | PROTOCOL_PAUSER |

#### PROTOCOL_UNPAUSER Functions

| Function        | Modifier                                   | Role                 |
| -------------   | ------------------------------------------ | -------------------- |
| unPauseContract | roleRegistry.hasRole(PROTOCOL_UNPAUSER)    | PROTOCOL_UNPAUSER |

#### onlyAuctionManagerContract Functions

| Function                   | Modifier        |
| -------------              | ----------------|
| fetchNextKeyIndex          | onlyAuctionManagerContract


### RoleRegistry

#### DEFAULT_ADMIN_ROLE Functions

| Function           | Modifier  | Role  |
| ------------------ | --------- | ----- |
| \_authorizeUpgrade | onlyOwner | Owner |
| setRoleAdmin       | onlyOwner | Owner |

### StakingManager

#### onlyOwner Functions

| Function                                  | Modifier  | Role  |
| ------------------                        | --------- | ----- |
| \_authorizeUpgrade                        | onlyOwner | Owner |
| initializeV2dot5                          | onlyOwner | Owner |
| initializeOnUpgrade                       | onlyOwner | Owner |
| setEtherFiNodesManagerAddress             | onlyOwner | Owner |
| setLiquidityPoolAddress                   | onlyOwner | Owner |
| registerEtherFiNodeImplementationContract | onlyOwner | Owner |
| registerTNFTContract                      | onlyOwner | Owner |
| registerBNFTContract                      | onlyOwner | Owner |
| upgradeEtherFiNode                        | onlyOwner | Owner |

#### onlyLiquidityPool Functions

| Function                                  | Modifier  
| ------------------                        | --------- 
| batchDepositWithBidIds                   | onlyLiquidityPool 
| batchRegisterValidators                   | onlyLiquidityPool 
| batchApproveRegistration                   | onlyLiquidityPool 
| batchCancelDeposit                   | onlyLiquidityPool 

#### onlyEtherFiNodesManager Functions

| Function                                  | Modifier  
| ------------------                        | --------- 
| instantiateEtherFiNode                    | onlyEtherFiNodesManager 


### Treasury

#### onlyOwner Functions

| Function                                  | Modifier  | Role  |
| ------------------                        | --------- | ----- |
| withdraw                                  | onlyOwner | Owner |


