// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @notice One-shot helper deployed once to migrate the remaining V0 membership
///         NFTs (279 holdouts at the time of writing) to V1. The target function
///         `migrateFromV0ToV1(uint256)` on MembershipManager is permissionless,
///         so this helper has no privileges and stores no state.
///
///         Each call is wrapped in try/catch so that already-migrated or
///         pause-blocked tokens don't revert the whole batch.
interface IMembershipManagerMigrate {
    function migrateFromV0ToV1(uint256 _tokenId) external;
}

contract MembershipV0Migrator {
    IMembershipManagerMigrate public immutable membershipManager;

    constructor(address _membershipManager) {
        membershipManager = IMembershipManagerMigrate(_membershipManager);
    }

    /// @notice Permissionless. Calls `migrateFromV0ToV1` for each id, swallowing
    ///         per-id reverts. Returns the number of successful migrations.
    function migrate(uint256[] calldata _tokenIds) external returns (uint256 succeeded) {
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            try membershipManager.migrateFromV0ToV1(_tokenIds[i]) {
                succeeded++;
            } catch {
                // skip already-migrated / paused / blacklisted ids
            }
        }
    }
}
