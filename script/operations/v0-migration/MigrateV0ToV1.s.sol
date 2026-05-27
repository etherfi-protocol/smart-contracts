// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import "@etherfi/membership/interfaces/IMembershipManager.sol";
import "@scripts/operations/v0-migration/MembershipV0Migrator.sol";

/// @notice Deploys MembershipV0Migrator and walks the remaining V0 membership
///         NFTs through `migrateFromV0ToV1` in batches. After all batches, the
///         script asserts that every supplied ID is now V1 (version == 1) with
///         empty V0 storage (tokenDeposits.amounts == 0). The script reverts if
///         any ID is left unmigrated, so a successful `--broadcast` run is a
///         strong guarantee that no V0 NFT remains.
///
/// Usage (PRIVATE_KEY must be set in `.env`, then `source .env` first):
///   forge script script/operations/v0-migration/MigrateV0ToV1.s.sol:MigrateV0ToV1 \
///     --rpc-url $MAINNET_RPC_URL --broadcast
///
/// The script reads `PRIVATE_KEY` from the env and passes it directly to
/// `vm.startBroadcast(pk)`, so both the simulation phase AND the broadcast
/// use the address derived from your key. You do NOT need `--sender` or
/// `--private-key` on the CLI.
///
/// IDs are processed in the order they appear in `v0_ids_flat.json` (currently
/// sorted high → low so we touch the most-recently-active tokens first).
///
/// Each per-token migration is wrapped in try/catch inside
/// `MembershipV0Migrator.migrate`, so running twice or against an already-
/// migrated id is a no-op (just costs gas).
contract MigrateV0ToV1 is Script {
    using stdJson for string;

    // Mainnet address — see script/deploys/Deployed.s.sol.
    address constant MEMBERSHIP_MANAGER = 0x3d320286E014C3e1ce99Af6d6B00f0C1D63E3000;

    // Calls per transaction. Each migrate ≈ 150–250k gas; 90×250k = 22.5M < block limit.
    uint256 constant BATCH_SIZE = 90;

    string constant IDS_JSON_PATH = "script/operations/v0-migration/v0_ids_flat.json";

    error MigrationIncomplete(uint256 tokenId, uint8 version, uint128 leftoverAmount);

    function run() external {
        string memory json = vm.readFile(IDS_JSON_PATH);
        uint256[] memory ids = json.readUintArray(".ids");
        require(ids.length > 0, "no ids loaded");
        console.log("Loaded V0 ids:", ids.length);

        // Read the broadcasting key from env so the sender is the address
        // derived from PRIVATE_KEY for both the simulation and broadcast phases.
        // This avoids the "using Foundry's default sender" warning that fires
        // when `vm.startBroadcast()` is called with no argument.
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(pk);
        console.log("Broadcasting from:", sender);

        vm.startBroadcast(pk);
        MembershipV0Migrator migrator = new MembershipV0Migrator(MEMBERSHIP_MANAGER);
        console.log("MembershipV0Migrator deployed at:", address(migrator));

        for (uint256 start = 0; start < ids.length; start += BATCH_SIZE) {
            uint256 end = start + BATCH_SIZE;
            if (end > ids.length) end = ids.length;

            uint256[] memory batch = new uint256[](end - start);
            for (uint256 j = 0; j < batch.length; j++) {
                batch[j] = ids[start + j];
            }
            uint256 ok = migrator.migrate(batch);
            console.log("batch", start, "succeeded:", ok);
        }

        vm.stopBroadcast();

        // ---- Post-migration verification (read-only) ----
        // For every supplied id we expect:
        //   tokenData(id).version  == 1  (now V1)
        //   tokenDeposits(id).amounts == 0  (V0 storage cleared by _migrateFromV0ToV1)
        IMembershipManager mm = IMembershipManager(MEMBERSHIP_MANAGER);
        uint256 verified = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            (uint128 amounts, ) = mm.tokenDeposits(ids[i]);
            (, , , , , , uint8 version) = mm.tokenData(ids[i]);
            if (version != 1 || amounts != 0) {
                revert MigrationIncomplete(ids[i], version, amounts);
            }
            verified++;
        }
        console.log("Post-migration verification passed for ids:", verified);
    }
}
