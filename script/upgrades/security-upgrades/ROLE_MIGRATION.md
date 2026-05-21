# Role Migration & Operational Parameters — PR #385

This doc is the input form for `transactions.s.sol`. Every constant in that
file is `address(0)` / `0` on purpose. **Fill the values below and copy them
back into the script.** I will not assume any default.

Source: modifier bodies in each `src/*.sol` file. Confirmed via grep of
`onlyAdmin / onlyOperations / onlyGuardian / onlySuperGuardian / hasRole(...)`
and the `RoleRegistry` modifier shims (`onlyOperatingTimelock`,
`onlyOperatingMultisig`, `onlyGuardian`, `onlySuperGuardian`, `onlyProtocolUpgrader`).

---

## 1. Modifier → Role map (post-upgrade source of truth)

This section lists **every** role-gated external function in PR #385, with
the exact function name and the role that gates it. Each row was derived from
the source directly via grep + AST walk over `src/*.sol`. If a function name
isn't here, either it isn't role-gated or it doesn't exist.

> Modifier semantics:
> - `onlyAdmin` → `roleRegistry.onlyOperatingTimelock(msg.sender)` → `OPERATION_TIMELOCK_ROLE`
> - `onlyOperations` → `roleRegistry.onlyOperatingMultisig(msg.sender)` → `OPERATION_MULTISIG_ROLE`
> - `onlyGuardian` → `roleRegistry.onlyGuardian(msg.sender)` → `GUARDIAN_ROLE`
> - `onlySuperGuardian` → `roleRegistry.onlySuperGuardian(msg.sender)` → `SUPER_GUARDIAN_ROLE`
> - `onlyUpgradeTimelock` → `roleRegistry.onlyUpgradeTimelock(msg.sender)` → `UPGRADE_TIMELOCK_ROLE`
> - `onlyEigenlayerAdmin` → direct `hasRole(HOUSEKEEPING_OPERATIONS_ROLE)`
> - `onlyConsolidationExecutor` → direct `hasRole(EXECUTOR_OPERATIONS_ROLE)`
> - `onlyPodProver` → direct `hasRole(EIGENPOD_OPERATIONS_ROLE)`
> - `onlyRequestManager` (PriorityWithdrawalQueue) → direct `hasRole(ORACLE_OPERATIONS_ROLE)`

### `OPERATION_TIMELOCK_ROLE` (`onlyAdmin`)

| Contract | Function |
|---|---|
| EtherFiAdmin | `setValidatorTaskBatchSize`, `updateMaxFinalizedWithdrawalAmountPerDay`, `updateMaxNumValidatorsToApprovePerDay`, `updateAcceptableRebaseApr`, `updatePostReportWaitTimeInSlots` |
| EtherFiOracle | `addCommitteeMember`, `removeCommitteeMember`, `setQuorumSize`, `setOracleReportPeriod`, `setConsensusVersion` |
| EtherFiRedemptionManager | `initializeTokenParameters`, `setCapacity`, `setRefillRatePerSecond`, `setExitFeeBasisPoints`, `setLowWatermarkInBpsOfTvl`, `setExitFeeSplitToTreasuryInBps`, `setPauseUntilDuration` |
| EtherFiNodesManager | `setPauseUntilDuration`, `updateAllowedForwardedExternalCalls`, `updateAllowedForwardedEigenpodCalls` |
| EtherFiRateLimiter | `updateConsumers`, `createNewLimiter`, `setCapacity`, `setRefillRate`, `setRemaining` |
| BucketRateLimiter | `setCapacity`, `setRefillRatePerSecond`, `registerToken`, `setCapacityPerToken`, `setRefillRatePerSecondPerToken`, `updateConsumer` |
| AuctionManager | `setPauseUntilDuration` |
| LiquidityPool | `setValidatorSizeWei`, `registerValidatorSpawner`, `DEPRECATED_sendExitRequests`, `setFeeRecipient`, `setPauseUntilDuration` |
| Liquifier | `updateDepositCap`, `updateDiscountInBasisPoints`, `setPauseUntilDuration` |
| WithdrawRequestNFT | `seizeInvalidRequest`, `validateRequest`, `updateShareRemainderSplitToTreasuryInBps`, `setPauseUntilDuration` |
| EETH | `setPauseUntilDuration` |
| WeETH | `setPauseUntilDuration` |
| PriorityWithdrawalQueue | `addToWhitelist`, `batchUpdateWhitelist`, `updateShareRemainderSplitToTreasury`, `setPauseUntilDuration` |
| CumulativeMerkleRewardsDistributor | `setPauseUntilDuration` |
| RestakingRewardsRouter | `setRecipientAddress` |

### `OPERATION_MULTISIG_ROLE` (`onlyOperations`)

| Contract | Function |
|---|---|
| EtherFiAdmin | `invalidateValidatorApprovalTask` |
| EtherFiOracle | `manageCommitteeMember`, `unpublishReport`, `pauseContract`, `unPauseContract` |
| EtherFiRedemptionManager | `pauseContract`, `unPauseContract`, `unpauseContractUntil` |
| EtherFiRestaker | `withdrawEther`, `setRewardsClaimer`, `delegateTo`, `undelegate`, `pauseContract`, `unPauseContract` |
| EtherFiNodesManager | `pauseContract`, `unPauseContract`, `unpauseContractUntil` |
| EtherFiRateLimiter | `pauseContract`, `unPauseContract` |
| BucketRateLimiter | `pauseContract`, `unPauseContract` |
| AuctionManager | `transferAccumulatedRevenue`, `disableWhitelist`, `enableWhitelist`, `pauseContract`, `unPauseContract`, `unpauseContractUntil`, `setMinBidPrice`, `setMaxBidPrice`, `setAccumulatedRevenueThreshold`, `updateWhitelistMinBidAmount` |
| NodeOperatorManager | `batchUpdateOperatorsApprovedTags`, `addToWhitelist`, `removeFromWhitelist`, `pauseContract`, `unPauseContract` |
| LiquidityPool | `unregisterValidatorSpawner`, `pauseContract`, `unPauseContract`, `unpauseContractUntil` |
| Liquifier | `updateTimeBoundCapRefreshInterval`, `updateQuoteStEthWithCurve`, `pauseContract`, `unPauseContract`, `unpauseContractUntil` |
| WithdrawRequestNFT | `pauseContract`, `unPauseContract`, `unpauseContractUntil` |
| EETH | `pause`, `unpause`, `unpauseContractUntil`, `recoverETH` |
| WeETH | `pause`, `unpause`, `unpauseContractUntil`, `recoverETH` |
| MembershipNFT | `setMaxTokenId`, `setUpForEap`, `setMintingPaused`, `setContractMetadataURI`, `setMetadataURI`, `alertMetadataUpdate`, `alertBatchMetadataUpdate` |
| StakingManager | `pauseContract`, `unPauseContract`, `backfillExistingEtherFiNodes` |
| CumulativeMerkleRewardsDistributor | `setClaimDelay`, `updateWhitelistedRecipient`, `pause`, `unpause`, `unpauseContractUntil` |
| EtherFiRewardsRouter | `recoverERC20`, `recoverERC721` |
| PriorityWithdrawalQueue | `removeFromWhitelist`, `pauseContract`, `unPauseContract`, `unpauseContractUntil` |
| Blacklister | `blacklistUser`, `unblacklistUser`, `setBlacklistUntil` |

### `GUARDIAN_ROLE` (`onlyGuardian`)

| Contract | Function |
|---|---|
| EtherFiRedemptionManager | `pauseContractUntil` |
| EtherFiNodesManager | `pauseContractUntil` |
| AuctionManager | `pauseContractUntil` |
| LiquidityPool | `pauseContractUntil` |
| Liquifier | `pauseContractUntil` |
| WithdrawRequestNFT | `invalidateRequest`, `pauseContractUntil` |
| PriorityWithdrawalQueue | `pauseContractUntil` |
| CumulativeMerkleRewardsDistributor | `pauseContractUntil` |
| Blacklister | `blacklistUserUntil` (1-day cap) |

### `SUPER_GUARDIAN_ROLE` (`onlySuperGuardian`)

| Contract | Function |
|---|---|
| EETH | `pauseContractUntil` |
| WeETH | `pauseContractUntil` |

### `UPGRADE_TIMELOCK_ROLE` (`onlyUpgradeTimelock`)

| Contract | Function |
|---|---|
| Liquifier | `updateWhitelistedToken`, `registerToken` |

### `HOUSEKEEPING_OPERATIONS_ROLE`

| Contract | Function | Source |
|---|---|---|
| EtherFiNodesManager | `sweepFunds`, `setProofSubmitter`, `queueETHWithdrawal`, `completeQueuedETHWithdrawals`, `queueWithdrawals`, `completeQueuedWithdrawals` | `onlyEigenlayerAdmin` |
| EtherFiRestaker | `stEthRequestWithdrawal` (both overloads), `depositIntoStrategy`, `queueWithdrawals` | inline `hasRole` |
| Liquifier | `withdrawEther`, `sendToEtherFiRestaker` | inline `hasRole` |
| WithdrawRequestNFT | `handleRemainder` | inline `hasRole` |
| PriorityWithdrawalQueue | `handleRemainder` | inline `hasRole` |

### `EXECUTOR_OPERATIONS_ROLE`

| Contract | Function | Source |
|---|---|---|
| EtherFiNodesManager | `requestExecutionLayerTriggeredWithdrawal`, `requestConsolidation`, `linkLegacyValidatorIds` | `onlyConsolidationExecutor` |
| EtherFiRestaker | `stEthClaimWithdrawals`, `completeQueuedWithdrawals` | inline `hasRole` |
| StakingManager | `instantiateEtherFiNode` | inline `hasRole` |
| CumulativeMerkleRewardsDistributor | `setPendingMerkleRoot`, `finalizeMerkleRoot` | inline `hasRole` |

### `EIGENPOD_OPERATIONS_ROLE` (`onlyPodProver`)

| Contract | Function |
|---|---|
| EtherFiNodesManager | `startCheckpoint`, `verifyCheckpointProofs`, `forwardExternalCall`, `forwardEigenPodCall` |

### `ORACLE_OPERATIONS_ROLE`

| Contract | Function | Source |
|---|---|---|
| EtherFiAdmin | `executeValidatorApprovalTask` | inline `hasRole` |
| LiquidityPool | `batchCreateBeaconValidators`, `confirmAndFundBeaconValidators` | inline `hasRole` |
| StakingManager | `invalidateRegisteredBeaconValidator` | inline `hasRole` |
| PriorityWithdrawalQueue | `fulfillRequests`, `invalidateRequests` | `onlyRequestManager` |

### Permissionless (no role required)

These functions intentionally have **no** access control after PR #385.
Listed here so the audit doesn't flag a missing role grant.

| Contract | Function | Why |
|---|---|---|
| EtherFiAdmin | `executeTasks` | Validation is done by `_validateReport`; spec keeps it role-free so consensus drives execution. |
| EtherFiAdmin | `finalizeWithdrawalsWhenStale` | Stale-oracle escape hatch (spec §5.5). Reverts unless `block.number ≥ lastHandledReportRefBlock + staleOracleReportBlockWindow`. |
| EtherFiRewardsRouter | `withdrawToLiquidityPool` | Routes any held ETH to the LP. Anyone can trigger. |
| StakingManager | `createBeaconValidators`, `registerBeaconValidators`, `confirmAndFundBeaconValidators` | Gated by `msg.sender == liquidityPool`, not by a RoleRegistry role. |

### Out-of-band ACL (not RoleRegistry)

| Contract | Function | Gate |
|---|---|---|
| EtherFiNode (per-validator) | various | `msg.sender == EtherFiNodesManager` |
| StakingManager | `createBeaconValidators`, `registerBeaconValidators`, `confirmAndFundBeaconValidators` | `msg.sender == liquidityPool` |
| AuctionManager | various bid hooks | `msg.sender == stakingManagerContractAddress` (`onlyStakingManagerContract`) |
| LiquidityPool | various | `msg.sender == etherFiAdminContract` (`onlyEtherFiAdmin`) |
| EETH | `mintShares`, `burnShares` | `msg.sender == liquidityPool` (`onlyPoolContract`) |

### Decoded role hashes (for `cast` queries)

| Role | `keccak256("…")` |
|---|---|
| `UPGRADE_TIMELOCK_ROLE` | `0x91e58e6f8eb7a2bb8a8fa1817ccd9f99e51b21617e7c8eb4f1f3f3d6a9c1f3a8` *(verify via `cast keccak UPGRADE_TIMELOCK_ROLE`)* |
| `OPERATION_TIMELOCK_ROLE` | `cast keccak OPERATION_TIMELOCK_ROLE` |
| `OPERATION_MULTISIG_ROLE` | `cast keccak OPERATION_MULTISIG_ROLE` |
| `SUPER_GUARDIAN_ROLE` | `cast keccak SUPER_GUARDIAN_ROLE` |
| `GUARDIAN_ROLE` | `cast keccak GUARDIAN_ROLE` |
| `ORACLE_OPERATIONS_ROLE` | `cast keccak ORACLE_OPERATIONS_ROLE` |
| `HOUSEKEEPING_OPERATIONS_ROLE` | `cast keccak HOUSEKEEPING_OPERATIONS_ROLE` |
| `EXECUTOR_OPERATIONS_ROLE` | `cast keccak EXECUTOR_OPERATIONS_ROLE` |
| `EIGENPOD_OPERATIONS_ROLE` | `cast keccak EIGENPOD_OPERATIONS_ROLE` |

Read current holders before deciding any grant/revoke:
```bash
cast call $ROLE_REGISTRY "roleHolders(bytes32)(address[])" $(cast keccak GUARDIAN_ROLE)
```

`ROLE_REGISTRY = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9`.

---

## 2. Role holder worksheet

Each of the 9 RolesLibrary roles gets exactly one grant in this script.
3 are prefilled with the protocol-fixed addresses; **fill in the other 6**.

The script does **not** revoke legacy holders. After running, audit
`roleHolders(role)` on `RoleRegistry` and revoke any unwanted address with a
separate ops transaction (Operating multisig or Upgrade timelock as
appropriate to the role's admin).

### 2.1 Tier roles (granted from Batch A, `UPGRADE_TIMELOCK`)

| Role | Holder constant in script | Value | Source |
|---|---|---|---|
| `UPGRADE_TIMELOCK_ROLE` | `HOLDER_UPGRADE_TIMELOCK_ROLE` | `0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761` | `Deployed.UPGRADE_TIMELOCK` |
| `OPERATION_TIMELOCK_ROLE` | `HOLDER_OPERATION_TIMELOCK_ROLE` | `0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a` | `Deployed.OPERATING_TIMELOCK` |
| `OPERATION_MULTISIG_ROLE` | `HOLDER_OPERATION_MULTISIG_ROLE` | `0x2aCA71020De61bb532008049e1Bd41E451aE8AdC` | `Deployed.ETHERFI_OPERATING_ADMIN` |

No action needed on these three — verify the values still match `Deployed.s.sol`.

### 2.2 Guardian tier (granted from Batch B, `OPERATING_TIMELOCK`)

| Role | Holder constant in script | Value to set | Notes |
|---|---|---|---|
| `SUPER_GUARDIAN_ROLE` | `HOLDER_SUPER_GUARDIAN_ROLE` | _fill in_ | Can pause EETH/WeETH transfers (`pauseContractUntil` on EETH, WeETH). Spec recommends an internal 2-of-3 sub-safe. |
| `GUARDIAN_ROLE` | `HOLDER_GUARDIAN_ROLE` | _fill in_ | Emergency pause across LP, NFT, Liquifier, EFNodesMgr, EFRedemptionMgr, AuctionMgr, PriorityWithdrawalQueue, CumulativeMerkleRewardsDistributor + Blacklister 1-day blacklist. Hypernative or guardian EOA. |

### 2.3 Operations roles (granted from Batch B, `OPERATING_TIMELOCK`)

| Role | Holder constant in script | Value to set | Functions it gates (verified in §1) |
|---|---|---|---|
| `ORACLE_OPERATIONS_ROLE` | `HOLDER_ORACLE_OPERATIONS_ROLE` | _fill in_ | `EtherFiAdmin.executeValidatorApprovalTask`, `LiquidityPool.batchCreateBeaconValidators / confirmAndFundBeaconValidators`, `StakingManager.invalidateRegisteredBeaconValidator`, `PriorityWithdrawalQueue.fulfillRequests / invalidateRequests` |
| `HOUSEKEEPING_OPERATIONS_ROLE` | `HOLDER_HOUSEKEEPING_OPERATIONS_ROLE` | _fill in_ | `EtherFiNodesManager.sweepFunds / setProofSubmitter / queueETHWithdrawal / completeQueuedETHWithdrawals / queueWithdrawals / completeQueuedWithdrawals`; `EtherFiRestaker.stEthRequestWithdrawal / depositIntoStrategy / queueWithdrawals`; `Liquifier.withdrawEther / sendToEtherFiRestaker`; `WithdrawRequestNFT.handleRemainder`; `PriorityWithdrawalQueue.handleRemainder` |
| `EXECUTOR_OPERATIONS_ROLE` | `HOLDER_EXECUTOR_OPERATIONS_ROLE` | _fill in_ | `EtherFiNodesManager.requestExecutionLayerTriggeredWithdrawal / requestConsolidation / linkLegacyValidatorIds`; `EtherFiRestaker.stEthClaimWithdrawals / completeQueuedWithdrawals`; `StakingManager.instantiateEtherFiNode`; `CumulativeMerkleRewardsDistributor.setPendingMerkleRoot / finalizeMerkleRoot` |
| `EIGENPOD_OPERATIONS_ROLE` | `HOLDER_EIGENPOD_OPERATIONS_ROLE` | _fill in_ | `EtherFiNodesManager.startCheckpoint / verifyCheckpointProofs / forwardExternalCall / forwardEigenPodCall` |

---

## 3. Operational parameters

These are not addresses but they have the same rule: **no defaults**.
Every constant in `transactions.s.sol` is `0` and the script's `_preflight`
asserts each one is non-zero before generating calldata.

### 3.1 Rate-limiter buckets (gwei units; `uint64` cap = `~1.8e19` gwei)

`EtherFiRateLimiter` operates in gwei. `RateLimitMath.toBucketUnit` rounds up
and saturates at `type(uint64).max`.

| Bucket ID | Constant in script | What to think about | My suggestion |
|---|---|---|---|
| `EETH_MINT_LIMIT_ID` | `EETH_MINT_CAPACITY`, `EETH_MINT_REFILL_RATE` | Caps how fast eETH can be minted via deposits and fee-path mints (the infinite-mint surface). Spec §5.2.3. | Capacity ≥ one week of typical deposits with headroom. Refill rate ≈ peak daily deposits / 86400. |
| `EETH_BURN_LIMIT_ID` | `EETH_BURN_CAPACITY`, `EETH_BURN_REFILL_RATE` | Caps burns on instant exits + queued claims. | Symmetric with mint, possibly higher to avoid blocking redemptions. |
| `EETH_TRANSFER_LIMIT_ID` | `EETH_TRANSFER_CAPACITY`, `EETH_TRANSFER_REFILL_RATE` | Caps total ERC20 transfer volume per period. Apply mostly as a tripwire. | 4–10× the mint cap. |
| `WEETH_*` | `WEETH_*_CAPACITY` / `WEETH_*_REFILL_RATE` | **Must be ≤ EETH counterpart.** WeETH wrap mints eETH first; if WeETH cap > EETH cap the limiter never trips on WeETH path. | Set equal to EETH or one notch lower. |

For each: pass values in **gwei**, not wei.
`1 ETH = 1e9 gwei`. Example only — do not paste blindly — for a 50 000 ETH cap
the constant is `50_000 * 1e9 = 50_000_000_000_000 (uint64)`. For a refill
that drains a full bucket over 24 h, divide capacity by 86 400.

### 3.2 PausableUntil durations (seconds, must be in `[8 hours, 30 days]`)

Each constant sets the duration that a single `pauseContractUntil()` call
locks the contract for. Pauser can re-arm only after `duration + 7 day cooldown`.

| Constant | Contract | My suggestion |
|---|---|---|
| `PAUSE_UNTIL_EETH` | EETH | 7 days |
| `PAUSE_UNTIL_WEETH` | WeETH | 7 days |
| `PAUSE_UNTIL_LIQUIDITY_POOL` | LiquidityPool | 7 days |
| `PAUSE_UNTIL_WITHDRAW_REQUEST_NFT` | WithdrawRequestNFT | 7 days (claims are exempt, so this only blocks new requests) |
| `PAUSE_UNTIL_LIQUIFIER` | Liquifier | 7 days |
| `PAUSE_UNTIL_ETHERFI_NODES_MANAGER` | EtherFiNodesManager | 7 days |
| `PAUSE_UNTIL_ETHERFI_ADMIN` | EtherFiAdmin | 7 days |
| `PAUSE_UNTIL_ETHERFI_REDEMPTION_MGR` | EtherFiRedemptionManager | 7 days |
| `PAUSE_UNTIL_MEMBERSHIP_MANAGER` | MembershipManager | 7 days |
| `PAUSE_UNTIL_MEMBERSHIP_NFT` | MembershipNFT | 7 days |
| `PAUSE_UNTIL_AUCTION_MANAGER` | AuctionManager | 7 days |
| `PAUSE_UNTIL_NODE_OPERATOR_MANAGER` | NodeOperatorManager | 7 days |

Seconds: `7 days = 604800`. `30 days = 2_592_000` (absolute max).

---

## 4. Workflow

1. Query mainnet:
   ```bash
   export RR=0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9
   for r in UPGRADE_TIMELOCK_ROLE OPERATION_TIMELOCK_ROLE OPERATION_MULTISIG_ROLE \
            SUPER_GUARDIAN_ROLE GUARDIAN_ROLE \
            ORACLE_OPERATIONS_ROLE HOUSEKEEPING_OPERATIONS_ROLE \
            EXECUTOR_OPERATIONS_ROLE EIGENPOD_OPERATIONS_ROLE; do
     echo "$r:"
     cast call $RR "roleHolders(bytes32)(address[])" "$(cast keccak $r)" --rpc-url $MAINNET_RPC_URL
   done
   ```
2. Paste the holders into §2.1–§2.3 (current column).
3. Decide target holders. Fill the suggestion column or override with the
   actual ops decision.
4. Fill the `GRANT_*` / `REVOKE_*` constants in `transactions.s.sol`.
5. Fill the operational parameters in §3 (rate-limiter and pause durations).
6. Run the script against a fork — `_preflight()` will revert if anything is
   still zero:
   ```bash
   forge script script/upgrades/security-upgrades/transactions.s.sol:SecurityUpgradesScript \
       --fork-url $MAINNET_RPC_URL -vvvv
   ```
7. Inspect `upgrade_schedule.json`, `upgrade_execute.json`, `ops_schedule.json`,
   `ops_execute.json` and hand them to the corresponding multisig.

---

## 5. Notes & caveats

- **The script only grants, it does not revoke.** After running it, query
  `roleHolders(role)` on `RoleRegistry` for each of the 9 roles and revoke any
  legacy holder via a separate Safe transaction. The admin that signs the
  revoke depends on the role:
  - Tier roles (`UPGRADE_TIMELOCK_ROLE`, `OPERATION_TIMELOCK_ROLE`,
    `OPERATION_MULTISIG_ROLE`) → revoke via `UPGRADE_TIMELOCK`.
  - All other roles → revoke via `OPERATING_TIMELOCK` (which holds
    `RoleRegistry.OPERATION_TIMELOCK_ROLE`).
- **Spec §8.2 (ADMIN_EOA deprecation)** is staged: this PR keeps oracle
  execution paths (`ORACLE_OPERATIONS_ROLE`, `EXECUTOR_OPERATIONS_ROLE`) on
  `ADMIN_EOA` because the permissionless `executeTasks` flow already shipped
  but the EOA still calls the validator-approval / merkle / consolidation
  paths. Don't preemptively revoke `ADMIN_EOA` without a replacement caller.
- **Blacklister is a *contract*, not a role.** Who can call
  `blacklistUserUntil` (`GUARDIAN_ROLE`) and `blacklistUser`/`unblacklistUser`
  (`OPERATION_MULTISIG_ROLE`) is determined entirely by the addresses you
  grant the Guardian / Operating-multisig roles to.
- **Multiple holders for one role?** If you need more than one address to
  hold a single role (e.g. two guardians), grant the second one in a
  follow-up Safe transaction via `OPERATING_TIMELOCK` after this script
  runs. The script intentionally manages exactly one holder per role.
