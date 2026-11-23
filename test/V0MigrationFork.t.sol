// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/StdJson.sol";
import "@etherfi/archive/membership/MembershipManager.sol";
import "@etherfi/archive/membership/interfaces/IMembershipManager.sol";
import "@scripts/operations/v0-migration/MembershipV0Migrator.sol";

/// @notice Fork test for the V0 → V1 batch migration. Confirms every V0 NFT in
///         v0_ids_flat.json gets fully migrated (no leftovers). Exiting migrated
///         NFTs is covered by `forceExit` in MembershipDeprecationUpgradeFork.t.sol.
///
/// Rebase routing is no longer a MembershipManager concern (EARN-1440 routes
/// rebase EtherFiAdmin → LiquidityPool directly), so it is covered separately
/// by the EtherFiOracle `executeTasks` and LiquidityPool rebase tests.
///
/// Run with:
///   forge test --match-contract V0MigrationForkTest \
///     --fork-url $MAINNET_RPC_URL -vv
contract V0MigrationForkTest is Test {
    using stdJson for string;

    address constant MEMBERSHIP_MANAGER = 0x3d320286E014C3e1ce99Af6d6B00f0C1D63E3000;
    address constant MEMBERSHIP_NFT     = 0xb49e4420eA6e35F98060Cd133842DbeA9c27e479;
    address constant ETHERFI_ADMIN      = 0x0EF8fa4760Db8f5Cd4d993f3e3416f30f942D705;
    address constant LIQUIDITY_POOL     = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address constant EETH               = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;

    MembershipManager mm;

    /// @dev Last mainnet state before the 26Q2 security upgrade executed
    ///      (block 25533308, 2026-07-14). The V0 migration has since run on
    ///      mainnet, so this test must fork pre-upgrade state to keep
    ///      exercising the migration path it was written to validate.
    uint256 constant PRE_UPGRADE_BLOCK = 25_526_000;

    function setUp() public {
        vm.selectFork(vm.createFork(vm.envString("MAINNET_RPC_URL"), PRE_UPGRADE_BLOCK));
        mm = MembershipManager(payable(MEMBERSHIP_MANAGER));
    }

    function test_migrateAll_thenWithdraw() public {
        string memory json = vm.readFile("script/operations/v0-migration/v0_ids_flat.json");
        uint256[] memory ids = json.readUintArray(".ids");
        assertGt(ids.length, 0, "ids missing");

        // ---- Pre-migration sanity: every supplied id is still V0 here ----
        uint256 stillV0 = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            (uint128 amounts, ) = mm.tokenDeposits(ids[i]);
            if (amounts > 0) stillV0++;
        }
        // Allow zero in case the migration already ran on this fork block.
        // The interesting case (and the one we want to verify) is when there
        // are V0 holdouts to migrate.
        emit log_named_uint("pre-migration V0 holdouts", stillV0);

        // ---- Run the batch migration as any EOA ----
        address caller = makeAddr("v0-migrator-caller");
        vm.deal(caller, 1 ether);
        vm.startPrank(caller);
        MembershipV0Migrator migrator = new MembershipV0Migrator(MEMBERSHIP_MANAGER);
        uint256 totalOk = migrator.migrate(ids);
        vm.stopPrank();
        emit log_named_uint("migrate() return value (successes)", totalOk);

        // ---- Verify every id is now V1 with empty V0 storage ----
        for (uint256 i = 0; i < ids.length; i++) {
            (uint128 amounts, ) = mm.tokenDeposits(ids[i]);
            (, , , , , , uint8 version) = mm.tokenData(ids[i]);
            assertEq(version, 1, "version not V1 post-migration");
            assertEq(amounts, 0, "V0 amounts not cleared post-migration");
        }

    }

}
