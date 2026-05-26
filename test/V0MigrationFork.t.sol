// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/StdJson.sol";
import "@etherfi/membership/MembershipManager.sol";
import "@etherfi/membership/interfaces/IMembershipManager.sol";
import "@scripts/operations/v0-migration/MembershipV0Migrator.sol";

/// @notice Fork test for the V0 → V1 batch migration. Confirms three things:
///   (1) Every V0 NFT in v0_ids_flat.json gets fully migrated (no leftovers).
///   (2) `MembershipManager.rebase()` still works correctly *after* the
///       migration — i.e. zeroed V0 tier deposits do not cause reverts and
///       the V1 reward path continues to run (zero / positive / negative
///       accrual branches).
///   (3) The migrated NFTs can actually exit through the withdrawal path
///       (the real reason we run the migration in the first place). We
///       exercise both `unwrapForEEthAndBurn` (burn for eETH) and
///       `requestWithdrawAndBurn` (burn for a WithdrawRequestNFT) using
///       on-chain owners of two of the 279 V0 holdouts.
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

    // Two of the 279 V0 holdouts and their on-chain owners (queried via Alchemy
    // getOwnersForNFT). We use these for the post-migration unwrap tests.
    uint256 constant V0_ID_FOR_UNWRAP_EETH      = 6251;
    address constant V0_OWNER_FOR_UNWRAP_EETH   = 0x8a2855ed794d9cc1e39F04C0CF947212aFC0A079;

    uint256 constant V0_ID_FOR_REQUEST_WITHDRAW = 6223;
    address constant V0_OWNER_FOR_REQUEST_WITHDRAW = 0xd6B01c20918a7Ba5D05E81DC59DEd322962b4D37;

    MembershipManager mm;

    function setUp() public {
        // Use the latest fork — these are pure read/migrate flows so block
        // pinning is unnecessary. If a tester wants a specific block they can
        // override via cheatcodes before calling test_*.
        vm.selectFork(vm.createFork(vm.envString("MAINNET_RPC_URL")));
        mm = MembershipManager(payable(MEMBERSHIP_MANAGER));
    }

    function test_migrateAll_thenRebase() public {
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

        // ---- Rebase must still work as etherFiAdmin, for all three branches ----
        // We exercise rebase three ways so we don't only prove "doesn't revert
        // on the trivial path":
        //   (a) 0      -> no rewards delta. Confirms the zero-delta codepath.
        //   (b) +N     -> positive accrual. Exercises the V1 share recomputation
        //                  (`liquidityPool.sharesForAmount(newEthAmount)`) with a
        //                  real reward delta after the LP rate has moved up.
        //   (c) -N     -> negative accrual. Exercises the `isLoss` branch in
        //                  `globalIndexLibrary.calculate{GlobalIndex,VaultEEthShares}`,
        //                  i.e. the slashing path. Failing to exercise this is
        //                  how slashing-time bugs hide in normal operation.
        //
        // For each branch we verify two things:
        //   1. `mm.rebase(...)` did not revert.
        //   2. The LP rate moved in the expected direction (this is the load-bearing
        //      observable signal — V0/V1 reward redistribution among tiers depends on
        //      weights vs current pool composition and may move any single tier vault
        //      either way, but the LP rate change is deterministic in sign).
        ILP lp = ILP(LIQUIDITY_POOL);

        // (a) zero
        _rebaseAndAssertRateDir(lp, 0, 0);

        // (b) positive accrual
        _rebaseAndAssertRateDir(lp, int128(1 ether), 1);

        // (c) negative accrual (slashing path)
        _rebaseAndAssertRateDir(lp, -int128(1 ether), -1);

        // ---- (3) Withdrawal path: migrated NFTs can actually exit ----
        // The whole point of the migration is to clear the way for deleting V0
        // code. That only makes sense if migrated NFTs still behave correctly
        // under the withdrawal path. We exercise both burn-for-eETH and
        // burn-for-WithdrawRequestNFT against real on-chain owners.
        _unwrapForEEthAndBurn_works(V0_ID_FOR_UNWRAP_EETH, V0_OWNER_FOR_UNWRAP_EETH);
        _requestWithdrawAndBurn_works(V0_ID_FOR_REQUEST_WITHDRAW, V0_OWNER_FOR_REQUEST_WITHDRAW);
    }

    function _unwrapForEEthAndBurn_works(uint256 tokenId, address owner) internal {
        IERC1155Like nft = IERC1155Like(MEMBERSHIP_NFT);
        IERC20Like  eeth = IERC20Like(EETH);

        // Sanity: owner currently holds this NFT (still owns it post-migration —
        // migration only mutates MM storage, not ERC1155 balances).
        assertEq(nft.balanceOf(owner, tokenId), 1, "owner no longer holds the NFT");

        uint256 eethBefore = eeth.balanceOf(owner);

        vm.prank(owner);
        mm.unwrapForEEthAndBurn(tokenId);

        // Post-conditions:
        //  - NFT burned: ERC1155 balance is 0
        //  - Owner received some eETH
        //  - tokenData[id] cleared (delete in _withdrawAndBurn)
        assertEq(nft.balanceOf(owner, tokenId), 0, "NFT not burned after unwrap");
        assertGt(eeth.balanceOf(owner) - eethBefore, 0, "owner received no eETH on unwrap");
        (, , , , , , uint8 versionAfter) = mm.tokenData(tokenId);
        assertEq(versionAfter, 0, "tokenData not cleared after burn");

        emit log_named_uint("unwrapForEEthAndBurn: tokenId", tokenId);
        emit log_named_uint("unwrapForEEthAndBurn: eETH received (wei)", eeth.balanceOf(owner) - eethBefore);
    }

    function _requestWithdrawAndBurn_works(uint256 tokenId, address owner) internal {
        IERC1155Like nft = IERC1155Like(MEMBERSHIP_NFT);

        assertEq(nft.balanceOf(owner, tokenId), 1, "owner no longer holds the NFT");

        vm.prank(owner);
        uint256 withdrawRequestId = mm.requestWithdrawAndBurn(tokenId);

        // Post-conditions:
        //  - NFT burned
        //  - tokenData[id] cleared
        //  - returned withdraw-request id is non-zero
        assertEq(nft.balanceOf(owner, tokenId), 0, "NFT not burned after requestWithdrawAndBurn");
        (, , , , , , uint8 versionAfter) = mm.tokenData(tokenId);
        assertEq(versionAfter, 0, "tokenData not cleared after burn");
        assertGt(withdrawRequestId, 0, "withdraw-request id is zero");

        emit log_named_uint("requestWithdrawAndBurn: tokenId", tokenId);
        emit log_named_uint("requestWithdrawAndBurn: returned withdraw-request id", withdrawRequestId);
    }

    /// @param sign 1 = rate must strictly increase, -1 = rate must strictly decrease,
    ///             0 = rate must stay within rounding tolerance.
    function _rebaseAndAssertRateDir(ILP lp, int128 accrual, int8 sign) internal {
        uint256 rateBefore = lp.amountForShare(1 ether);

        vm.prank(ETHERFI_ADMIN);
        mm.rebase(accrual);

        uint256 rateAfter = lp.amountForShare(1 ether);

        if (sign > 0) {
            assertGt(rateAfter, rateBefore, "LP rate did not rise on +accrual");
        } else if (sign < 0) {
            assertLt(rateAfter, rateBefore, "LP rate did not fall on -accrual");
        } else {
            uint256 drift = rateAfter > rateBefore ? rateAfter - rateBefore
                                                    : rateBefore - rateAfter;
            assertLt(drift, 1e6, "LP rate drifted on zero accrual");
        }
        emit log_named_int("rebased with accrual (wei)", accrual);
        emit log_named_uint("LP amountForShare(1e18) before", rateBefore);
        emit log_named_uint("LP amountForShare(1e18) after", rateAfter);
    }
}

interface ILP {
    function amountForShare(uint256 _share) external view returns (uint256);
}

interface IERC1155Like {
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
}
