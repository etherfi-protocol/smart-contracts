# V0 → V1 Membership NFT batch migration

One-shot script to migrate the remaining 279 V0 membership NFTs to V1 so we
can delete the V0 / V0→V1 migration code from `MembershipManager` entirely.

## What it does

1. Deploys a tiny helper contract (`MembershipV0Migrator`) — permissionless,
   no privileges, no state. Used only as a batch wrapper.
2. Reads `v0_ids_flat.json` (279 token IDs, ordered high → low so the most
   recently active tokens migrate first).
3. Calls `MembershipManager.migrateFromV0ToV1(tokenId)` for each id in
   batches of 90 (≈ 22.5M gas per tx, comfortably under the 30M block limit).
   Each per-id call is wrapped in try/catch so already-migrated / paused /
   blacklisted ids don't revert the whole batch.
4. After all batches, the script re-reads `tokenDeposits` and `tokenData` for
   every id and **reverts** if any id is left with `version != 1` or
   `tokenDeposits.amounts != 0`. A successful broadcast therefore guarantees
   that every supplied id is fully migrated.

## Pre-flight safety

Two safety nets, both green right now:

- **Mainnet-fork simulation** (`forge script ... --sender 0x..1234` without
  `--broadcast`): all 279 ids report `succeeded`, and the post-migration
  verification loop passes. Estimated gas: ~54.9M total across 1 deploy + 4
  batch txs.
- **Fork test** (`test/V0MigrationFork.t.sol`): forks mainnet, runs the
  migration as a random EOA, asserts every id is now V1, then calls
  `MembershipManager.rebase(0)` as `etherFiAdmin` and asserts the V1 reward
  path still runs without revert. This proves `rebase()` keeps working after
  the V0 storage goes to zero.

Run the fork test before broadcasting:

```bash
forge test --match-contract V0MigrationForkTest \
  --fork-url $MAINNET_RPC_URL -vv
```

## Run the migration on mainnet

Prerequisites in `.env`:

```bash
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/<KEY>
PRIVATE_KEY=0x...        # EOA that will pay ~0.02–0.03 ETH at current gas
```

`PRIVATE_KEY` is read by the script via `vm.envUint("PRIVATE_KEY")` and
passed to `vm.startBroadcast(pk)`, so the same address is used for both
simulation and broadcasting. Do **not** pass `--private-key` or `--sender`
on the CLI.

```bash
source .env
forge script script/operations/v0-migration/MigrateV0ToV1.s.sol:MigrateV0ToV1 \
  --rpc-url $MAINNET_RPC_URL \
  --broadcast \
  -vv
```

Dry-run (no broadcast):

```bash
source .env
forge script script/operations/v0-migration/MigrateV0ToV1.s.sol:MigrateV0ToV1 \
  --rpc-url $MAINNET_RPC_URL \
  -vv
```

Expected log output:

```
Loaded V0 ids: 279
MembershipV0Migrator deployed at: 0x...
batch 0 succeeded: 90
batch 90 succeeded: 90
batch 180 succeeded: 90
batch 270 succeeded: 9
Post-migration verification passed for ids: 279
```

If the post-migration check fails the script reverts with
`MigrationIncomplete(tokenId, version, leftoverAmount)`.

## Cost

| Item | Value |
|---|---|
| Block at simulation | mainnet latest |
| Total gas | ~54.9M (deploy + 4 batches) |
| Estimated ETH at 0.3 gwei | ~0.016 ETH |
| Estimated ETH at 0.5 gwei | ~0.027 ETH |
| Estimated ETH at 1 gwei | ~0.055 ETH |

## After it lands

Once this script has broadcast successfully on mainnet, the
`MembershipManager` V0 storage and migration code can be removed in a
follow-up upgrade (the deprecation trim we sized at MM 26,412 → 16,992
bytes). Until then, leaving the V0 entry point present is safe — it's just
unreachable.

## Files

| Path | Purpose |
|---|---|
| `MembershipV0Migrator.sol` | One-shot batch helper, deployed by the script. |
| `MigrateV0ToV1.s.sol` | Foundry script: deploy + batch + verify. |
| `v0_ids_flat.json` | 279 token IDs (high → low). Consumed by the script. |
| `v0_token_ids.json` | Same ids + per-id amounts; for human auditing only. |
| `../../../test/V0MigrationFork.t.sol` | Fork test: migrate + post-rebase check. |
