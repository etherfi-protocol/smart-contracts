// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@etherfi/archive/membership/MembershipManager.sol";
import "@etherfi/archive/membership/interfaces/IMembershipManager.sol";
import "@etherfi/governance/RoleRegistry.sol";

interface IUUPS {
    function upgradeTo(address newImplementation) external;
}

interface INFT {
    function balanceOfUser(address user, uint256 id) external view returns (uint256);
    function valueOf(uint256 id) external view returns (uint256);
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
}

/// @notice Drains every outstanding membership position on a mainnet fork through
///         forceUnwrapForEEth, then sweeps the unbacked remainder to the treasury.
/// @dev MembershipNFT is ERC1155 with no owner index, so the (holder, tokenId) set is rebuilt
///      off-chain from TransferSingle/TransferBatch logs and loaded from a fixture. The fixture is
///      pinned to the same block as the fork; a mismatch shows up as skipped tokens, not as
///      silently wrong payouts.
contract MembershipDeprecationForkTest is Test {
    address constant MM_PROXY = 0x3d320286E014C3e1ce99Af6d6B00f0C1D63E3000;
    address constant NFT = 0xb49e4420eA6e35F98060Cd133842DbeA9c27e479;
    address constant EETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address constant LIQUIDITY_POOL = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address constant ROLE_REGISTRY = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;
    address constant TREASURY = 0x0c83EAe1FE72c390A02E426572854931EefF93BA;
    address constant OPERATING_TIMELOCK = 0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a;
    /// @dev Live HOUSEKEEPING_OPERATIONS_ROLE holder on mainnet.
    address constant HOUSEKEEPER = 0x67E10B7764A99165665557B3E6cF24555bfC88c3;
    uint256 constant FORK_BLOCK = 25801600;

    MembershipManager mm = MembershipManager(payable(MM_PROXY));
    INFT nft = INFT(NFT);
    IERC20 eETH = IERC20(EETH);
    RoleRegistry roleRegistry = RoleRegistry(ROLE_REGISTRY);

    uint256[] ids;
    address[] holders;

    function setUp() public {
        vm.createSelectFork(vm.envString("FORK_RPC_URL"), FORK_BLOCK);
        _upgradeMembershipManager();
        _loadFixture();
    }

    /// @dev Redeploys MembershipManager with the proxy's own immutables, read off the live contract
    ///      so the upgrade cannot silently repoint a dependency, and swaps the impl slot.
    function _upgradeMembershipManager() internal {
        MembershipManager newImpl = new MembershipManager(
            address(mm.eETH()),
            address(mm.liquidityPool()),
            address(mm.membershipNFT()),
            ROLE_REGISTRY,
            address(mm.blacklister())
        );
        assertEq(address(mm.eETH()), EETH, "eETH immutable matches the known deployment");
        assertEq(address(mm.liquidityPool()), LIQUIDITY_POOL, "LP immutable matches");
        assertEq(address(mm.membershipNFT()), NFT, "NFT immutable matches");

        // EIP-1967 implementation slot.
        vm.store(MM_PROXY, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc, bytes32(uint256(uint160(address(newImpl)))));
    }

    function _loadFixture() internal {
        string memory raw = vm.readFile("test/fixtures/membership-holders.json");
        ids = vm.parseJsonUintArray(raw, ".ids");
        holders = vm.parseJsonAddressArray(raw, ".holders");
        assertEq(ids.length, holders.length, "fixture arrays agree");
        assertGt(ids.length, 1000, "fixture is populated");
    }

    /// @dev No role is granted anywhere in this suite: OPERATING_TIMELOCK already holds
    ///      OPERATION_TIMELOCK_ROLE on mainnet, so these tests exercise the real production
    ///      authority rather than one minted for the test.
    function _assertTimelockAuthority() internal view {
        assertTrue(
            roleRegistry.hasRole(roleRegistry.OPERATION_TIMELOCK_ROLE(), OPERATING_TIMELOCK),
            "operating timelock already holds the role on mainnet"
        );
        assertTrue(
            roleRegistry.hasRole(roleRegistry.HOUSEKEEPING_OPERATIONS_ROLE(), HOUSEKEEPER),
            "housekeeper already holds the role on mainnet"
        );
    }

    function _slice(uint256 start, uint256 count)
        internal
        view
        returns (address[] memory h, uint256[] memory t)
    {
        if (start + count > ids.length) count = ids.length - start;
        h = new address[](count);
        t = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            h[i] = holders[start + i];
            t[i] = ids[start + i];
        }
    }

    /// @dev Runs the whole fixture through forceUnwrapForEEth in batches.
    function _drainAll(uint256 batchSize) internal returns (uint256 unwrapped, uint256 skipped) {
        for (uint256 start = 0; start < ids.length; start += batchSize) {
            (address[] memory h, uint256[] memory t) = _slice(start, batchSize);

            vm.recordLogs();
            vm.prank(HOUSEKEEPER);
            mm.forceUnwrapForEEth(h, t);
            Vm.Log[] memory logs = vm.getRecordedLogs();

            for (uint256 i = 0; i < logs.length; i++) {
                if (logs[i].emitter != MM_PROXY) continue;
                if (logs[i].topics[0] == MembershipManager.NftForceUnwrapped.selector) unwrapped++;
                else if (logs[i].topics[0] == MembershipManager.NftForceUnwrapSkipped.selector) skipped++;
            }
        }
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------  END-TO-END MIGRATION  ---------------------------------
    //--------------------------------------------------------------------------------------

    function test_forceUnwrapAllThenSweepToTreasury() public {
        _assertTimelockAuthority();

        uint256 mmStart = eETH.balanceOf(MM_PROXY);
        uint256 obligationStart = mm.outstandingEEthObligation();
        uint256 treasuryStart = eETH.balanceOf(TREASURY);

        emit log_named_uint("MM eETH before          ", mmStart);
        emit log_named_uint("obligation before       ", obligationStart);
        emit log_named_uint("unbacked before         ", mm.unbackedEEth());
        emit log_named_uint("fixture tokens          ", ids.length);

        (uint256 unwrapped, uint256 skipped) = _drainAll(200);

        emit log_named_uint("unwrapped               ", unwrapped);
        emit log_named_uint("skipped                 ", skipped);

        uint256 obligationEnd = mm.outstandingEEthObligation();
        uint256 mmAfterDrain = eETH.balanceOf(MM_PROXY);

        emit log_named_uint("obligation after        ", obligationEnd);
        emit log_named_uint("MM eETH after drain     ", mmAfterDrain);
        emit log_named_uint("unbacked after drain    ", mm.unbackedEEth());

        assertEq(unwrapped + skipped, ids.length, "every fixture entry produced an outcome");
        assertGt(unwrapped, 0, "at least some positions were unwrapped");
        assertLt(obligationEnd, obligationStart, "obligation fell");

        // Spot-check that unwrapped positions are really gone. Bounded on purpose: re-reading all
        // 1594 tokens costs ~4800 cold storage fetches through the fork and starves the RPC.
        // test_holdersActuallyReceiveTheirEEth checks the per-token invariant directly.
        uint256 verified;
        for (uint256 i = 0; i < ids.length && verified < 40; i += 37) {
            if (nft.balanceOfUser(holders[i], ids[i]) != 0) continue;
            (uint96 vaultShare,,,,,, uint8 version) = mm.tokenData(ids[i]);
            assertEq(vaultShare, 0, "burned token has no residual vault share");
            assertEq(version, 0, "burned token row was deleted");
            verified++;
        }
        emit log_named_uint("spot-checked burned rows", verified);

        // Sweep whatever no position can claim.
        uint256 expectedSweep = mm.unbackedEEth();
        vm.prank(OPERATING_TIMELOCK);
        uint256 swept = mm.recoverTokens(EETH, TREASURY);

        emit log_named_uint("swept to treasury       ", swept);
        emit log_named_uint("MM eETH final           ", eETH.balanceOf(MM_PROXY));
        emit log_named_uint("obligation final        ", mm.outstandingEEthObligation());

        assertEq(swept, expectedSweep, "swept exactly the unbacked amount");
        // eETH is share-denominated, so a transfer of N wei can credit N-1. Tolerance, not slack.
        assertApproxEqAbs(eETH.balanceOf(TREASURY), treasuryStart + swept, 2, "treasury received it");
        // Cannot be exactly 0: transferring N wei of a share-denominated token credits N-1, so the
        // sweep leaves a wei of rounding residue behind. Bounded, not zero.
        assertLe(mm.unbackedEEth(), 2, "at most rounding dust remains unbacked");

        // What is left is only what unburned positions can still claim.
        assertLe(
            eETH.balanceOf(MM_PROXY),
            mm.outstandingEEthObligation() + 1e12,
            "residual balance is bounded by the remaining obligation"
        );
    }

    function test_holdersActuallyReceiveTheirEEth() public {
        _assertTimelockAuthority();

        // Pick holders that hold exactly one token in the fixture, so the balance delta is
        // attributable to a single unwrap.
        uint256 checked;
        for (uint256 i = 0; i < ids.length && checked < 25; i++) {
            address holder = holders[i];
            uint256 tokenId = ids[i];
            if (nft.balanceOfUser(holder, tokenId) != 1) continue;
            (uint96 vaultShare,,,,, uint8 tier, uint8 version) = mm.tokenData(tokenId);
            if (version != 1 || vaultShare == 0) continue;

            uint256 expected = mm.ethAmountForVaultShare(tier, vaultShare);
            if (expected == 0) continue;

            uint256 before = eETH.balanceOf(holder);

            (address[] memory h, uint256[] memory t) = _slice(i, 1);
            vm.prank(HOUSEKEEPER);
            mm.forceUnwrapForEEth(h, t);

            uint256 gained = eETH.balanceOf(holder) - before;
            // eETH is share-based; a 1 wei rounding difference on transfer is expected.
            assertApproxEqAbs(gained, expected, 2, "holder received its position value in eETH");
            assertEq(nft.balanceOfUser(holder, tokenId), 0, "NFT burned");
            checked++;
        }

        assertGt(checked, 10, "checked a meaningful sample");
        emit log_named_uint("holders verified individually", checked);
    }

    //--------------------------------------------------------------------------------------
    //---------------------------------  SECURITY  -----------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice The sweep must never be able to take eETH that still backs a live position.
    ///         This is the whole safety argument for holding it behind governance instead of
    ///         requiring every holder to be paid first.
    function test_sweepCannotTouchBackedEEth() public {
        _assertTimelockAuthority();

        uint256 obligation = mm.outstandingEEthObligation();
        uint256 balance = eETH.balanceOf(MM_PROXY);
        assertGt(obligation, 0, "positions are still outstanding");

        uint256 unbacked = mm.unbackedEEth();
        assertLt(unbacked, balance / 100, "almost everything held is still backed");

        if (unbacked == 0) {
            vm.prank(OPERATING_TIMELOCK);
            vm.expectRevert(MembershipManager.NothingToSweep.selector);
            mm.recoverTokens(EETH, TREASURY);
        } else {
            vm.prank(OPERATING_TIMELOCK);
            uint256 swept = mm.recoverTokens(EETH, TREASURY);
            assertEq(swept, unbacked, "swept only the unbacked slice");
            assertGe(eETH.balanceOf(MM_PROXY), mm.outstandingEEthObligation(), "obligation still covered");
        }
    }

    /// @notice Sweeping partway through the migration must not shortchange the holders who have
    ///         not been paid yet. This is the property that makes the sweep safe to expose at all;
    ///         the end-to-end test only ever sweeps last, which would not catch a wrong bound.
    function test_sweepMidMigrationStillPaysRemainingHolders() public {
        _assertTimelockAuthority();

        uint256 half = ids.length / 2;

        // Drain the first half.
        for (uint256 start = 0; start < half; start += 200) {
            uint256 count = start + 200 > half ? half - start : 200;
            (address[] memory h, uint256[] memory t) = _slice(start, count);
            vm.prank(HOUSEKEEPER);
            mm.forceUnwrapForEEth(h, t);
        }

        // Sweep the surplus while ~half the positions are still outstanding.
        uint256 obligationMid = mm.outstandingEEthObligation();
        assertGt(obligationMid, 0, "positions still outstanding at the sweep");

        vm.prank(OPERATING_TIMELOCK);
        uint256 swept = mm.recoverTokens(EETH, TREASURY);
        emit log_named_uint("swept mid-migration     ", swept);

        assertGe(
            eETH.balanceOf(MM_PROXY) + 2,
            obligationMid,
            "balance still covers everything owed after the mid-migration sweep"
        );

        // Now pay the second half and confirm each one got its full position value.
        uint256 checked;
        for (uint256 i = half; i < ids.length && checked < 20; i++) {
            if (nft.balanceOfUser(holders[i], ids[i]) != 1) continue;
            (uint96 vaultShare,,,,, uint8 tier, uint8 version) = mm.tokenData(ids[i]);
            if (version != 1 || vaultShare == 0) continue;

            uint256 expected = mm.ethAmountForVaultShare(tier, vaultShare);
            if (expected == 0) continue;

            uint256 before = eETH.balanceOf(holders[i]);
            (address[] memory h, uint256[] memory t) = _slice(i, 1);
            vm.prank(HOUSEKEEPER);
            mm.forceUnwrapForEEth(h, t);

            assertApproxEqAbs(
                eETH.balanceOf(holders[i]) - before,
                expected,
                2,
                "holder paid in full despite the earlier sweep"
            );
            checked++;
        }

        assertGt(checked, 10, "checked a meaningful sample after the sweep");
        emit log_named_uint("paid in full after sweep", checked);
    }

    function test_forceUnwrap_revertsWithoutHousekeepingRole() public {
        (address[] memory h, uint256[] memory t) = _slice(0, 1);

        vm.prank(address(0xBAD));
        vm.expectRevert(RoleRegistry.OnlyHousekeepingOperations.selector);
        mm.forceUnwrapForEEth(h, t);

        // The timelock does not hold the housekeeping role, so it cannot run the batch either.
        vm.prank(OPERATING_TIMELOCK);
        vm.expectRevert(RoleRegistry.OnlyHousekeepingOperations.selector);
        mm.forceUnwrapForEEth(h, t);
    }

    /// @notice The sweeps move funds to a caller-named recipient, so they stay on the timelock even
    ///         though the unwrap batch runs on a hot role.
    function test_housekeeperCannotSweep() public {
        _assertTimelockAuthority();

        vm.prank(HOUSEKEEPER);
        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        mm.recoverTokens(EETH, TREASURY);

        vm.prank(HOUSEKEEPER);
        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        mm.recoverTokens(address(0), TREASURY);
    }

    function test_sweep_revertsForNonTimelock() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        mm.recoverTokens(EETH, TREASURY);
    }

    /// @notice forceUnwrapOne is external only so the batch can isolate items. Nobody else may
    ///         reach it, or anyone could burn any holder's NFT.
    function test_forceUnwrapOne_rejectsExternalCallers() public {
        vm.prank(OPERATING_TIMELOCK);
        vm.expectRevert(MembershipManager.OnlySelf.selector);
        mm.forceUnwrapOne(holders[0], ids[0]);

        vm.prank(address(0xBAD));
        vm.expectRevert(MembershipManager.OnlySelf.selector);
        mm.forceUnwrapOne(holders[0], ids[0]);
    }

    /// @notice A wrong holder must be skipped, never paid. Otherwise a bad list entry drains a
    ///         position to an attacker-chosen address.
    function test_wrongHolderIsSkippedNotPaid() public {
        _assertTimelockAuthority();

        address attacker = address(0xA77ACC);

        // The victim token must differ from the one that succeeds, since a successful unwrap burns
        // its token. Pair a good entry with a wrong-holder entry so the batch has one success and
        // does not trip the NoneUnwrapped guard -- that guard is covered separately.
        uint256 goodIdx = _firstLivePosition();
        uint256 victimIdx = type(uint256).max;
        for (uint256 i = goodIdx + 1; i < ids.length; i++) {
            (uint96 vs,,,,,, uint8 version) = mm.tokenData(ids[i]);
            if (version == 1 && vs > 0 && nft.balanceOfUser(holders[i], ids[i]) == 1) { victimIdx = i; break; }
        }
        require(victimIdx != type(uint256).max, "need two live positions in fixture");

        address[] memory h = new address[](2);
        uint256[] memory t = new uint256[](2);
        h[0] = holders[goodIdx]; t[0] = ids[goodIdx];       // succeeds
        h[1] = attacker;         t[1] = ids[victimIdx];     // wrong holder, must be skipped

        uint256 attackerBefore = eETH.balanceOf(attacker);

        vm.prank(HOUSEKEEPER);
        mm.forceUnwrapForEEth(h, t);

        assertEq(eETH.balanceOf(attacker), attackerBefore, "attacker got nothing");
        assertEq(nft.balanceOfUser(holders[victimIdx], ids[victimIdx]), 1, "real holder still holds the NFT");
        (uint96 vaultShare,,,,,,) = mm.tokenData(ids[victimIdx]);
        assertGt(vaultShare, 0, "victim position untouched");
    }

    /// @notice A duplicated entry must not pay twice.
    function test_duplicateEntryPaysOnce() public {
        _assertTimelockAuthority();

        uint256 idx = type(uint256).max;
        for (uint256 i = 0; i < ids.length; i++) {
            (uint96 vs,,,,, , uint8 version) = mm.tokenData(ids[i]);
            if (version == 1 && vs > 0 && nft.balanceOfUser(holders[i], ids[i]) == 1) { idx = i; break; }
        }
        require(idx != type(uint256).max, "no live position in fixture");

        address holder = holders[idx];
        (uint96 vaultShare,,,,, uint8 tier,) = mm.tokenData(ids[idx]);
        uint256 expected = mm.ethAmountForVaultShare(tier, vaultShare);

        address[] memory h = new address[](2);
        uint256[] memory t = new uint256[](2);
        h[0] = holder; h[1] = holder;
        t[0] = ids[idx]; t[1] = ids[idx];

        uint256 before = eETH.balanceOf(holder);

        vm.prank(HOUSEKEEPER);
        mm.forceUnwrapForEEth(h, t);

        assertApproxEqAbs(eETH.balanceOf(holder) - before, expected, 2, "paid exactly once");
    }

    /// @notice An all-failed batch must report (0 unwrapped, N skipped) and keep its skip events,
    ///         not revert. Reverting would discard the very diagnostics that say why each item
    ///         failed, and would let any holder veto a queued governance call by transferring the
    ///         NFT out before the timelock ETA.
    function test_allFailedBatchReportsInsteadOfReverting() public {
        _assertTimelockAuthority();

        address[] memory h = new address[](2);
        uint256[] memory t = new uint256[](2);
        h[0] = address(0xDEAD01); t[0] = ids[0];
        h[1] = address(0xDEAD02); t[1] = ids[1];

        vm.recordLogs();
        vm.prank(HOUSEKEEPER);
        (uint256 unwrapped, uint256 skipped) = mm.forceUnwrapForEEth(h, t);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(unwrapped, 0, "nothing unwrapped");
        assertEq(skipped, 2, "both reported as skipped");

        uint256 skipEvents;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == MM_PROXY && logs[i].topics[0] == MembershipManager.NftForceUnwrapSkipped.selector) {
                skipEvents++;
            }
        }
        assertEq(skipEvents, 2, "skip events survived, so the operator can see why");

        // The real holders keep their positions.
        assertEq(nft.balanceOfUser(holders[0], ids[0]), 1, "position 0 untouched");
        assertEq(nft.balanceOfUser(holders[1], ids[1]), 1, "position 1 untouched");
    }

    /// @notice A holder must not be able to veto a queued batch. With the old revert-on-none guard,
    ///         transferring the NFT out before the timelock ETA made a single-item batch revert and
    ///         burned a full governance delay for the price of one ERC1155 transfer.
    function test_holderCannotVetoBatchByMovingTheNft() public {
        _assertTimelockAuthority();

        uint256 idx = _firstLivePosition();
        address holder = holders[idx];

        // Holder front-runs execution by moving the token to a fresh address.
        vm.prank(holder);
        nft.safeTransferFrom(holder, address(0xFEED), ids[idx], 1, "");

        address[] memory h = new address[](1);
        uint256[] memory t = new uint256[](1);
        h[0] = holder; t[0] = ids[idx];

        vm.prank(HOUSEKEEPER);
        (uint256 unwrapped, uint256 skipped) = mm.forceUnwrapForEEth(h, t);

        assertEq(unwrapped, 0, "item skipped");
        assertEq(skipped, 1, "reported, not reverted");
    }

    /// @notice One bad entry alongside a good one must still commit the good one.
    function test_partialFailureStillCommitsTheGoodItem() public {
        _assertTimelockAuthority();

        uint256 idx = _firstLivePosition();
        address holder = holders[idx];
        uint256 before = eETH.balanceOf(holder);

        address[] memory h = new address[](2);
        uint256[] memory t = new uint256[](2);
        h[0] = address(0xDEAD01); t[0] = ids[idx];   // wrong holder, skipped
        h[1] = holder;           t[1] = ids[idx];   // correct, paid

        vm.prank(HOUSEKEEPER);
        mm.forceUnwrapForEEth(h, t);

        assertGt(eETH.balanceOf(holder), before, "good entry was committed despite the bad one");
        assertEq(nft.balanceOfUser(holder, ids[idx]), 0, "NFT burned");
    }

    /// @notice The contract holds ETH from accumulated burn fees with no other way out. Without a
    ///         sweep the migration strands it behind a UUPS upgrade.
    function test_recoverEtherToTreasury() public {
        _assertTimelockAuthority();

        uint256 mmEth = address(mm).balance;
        assertGt(mmEth, 0, "contract holds ETH on mainnet");

        uint256 treasuryBefore = TREASURY.balance;

        vm.prank(OPERATING_TIMELOCK);
        uint256 swept = mm.recoverTokens(address(0), TREASURY);

        assertEq(swept, mmEth, "swept the whole ETH balance");
        assertEq(TREASURY.balance, treasuryBefore + mmEth, "treasury received the ETH");
        assertEq(address(mm).balance, 0, "no ETH left behind");

        // Second call has nothing to move.
        vm.prank(OPERATING_TIMELOCK);
        vm.expectRevert(MembershipManager.NothingToSweep.selector);
        mm.recoverTokens(address(0), TREASURY);
    }

    function test_recoverEther_revertsForNonTimelock() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        mm.recoverTokens(address(0), TREASURY);
    }

    function test_recoverEther_rejectsZeroRecipient() public {
        _assertTimelockAuthority();

        vm.prank(OPERATING_TIMELOCK);
        vm.expectRevert(MembershipManager.ZeroRecipient.selector);
        mm.recoverTokens(address(0), address(0));
    }

    /// @notice The eETH sweep must refuse to run if any V0 tier ever holds shares, since
    ///         outstandingEEthObligation() cannot see them. Live state has all four at zero, so
    ///         poke one to prove the guard bites rather than asserting on a condition that
    ///         happens to be true.
    function test_sweepRefusesWhenLegacyTierHoldsShares() public {
        _assertTimelockAuthority();

        (uint128 amounts, uint128 shares) = mm.tierDeposits(0);
        assertEq(shares, 0, "live V0 tier holds nothing");

        // tierDeposits lives at slot 259 (forge inspect storage). Dynamic array data starts at
        // keccak256(slot); TierDeposit packs {uint128 amounts, uint128 shares} into one word with
        // shares in the high half.
        bytes32 dataSlot = keccak256(abi.encode(uint256(259)));
        vm.store(MM_PROXY, dataSlot, bytes32((uint256(1) << 128) | uint256(amounts)));

        (, uint128 pokedShares) = mm.tierDeposits(0);
        assertEq(pokedShares, 1, "poke landed, so the guard is actually being exercised");

        vm.prank(OPERATING_TIMELOCK);
        vm.expectRevert(MembershipManager.LegacyPositionsOutstanding.selector);
        mm.recoverTokens(EETH, TREASURY);
    }

    function _firstLivePosition() internal view returns (uint256) {
        for (uint256 i = 0; i < ids.length; i++) {
            (uint96 vs,,,,,, uint8 version) = mm.tokenData(ids[i]);
            if (version == 1 && vs > 0 && nft.balanceOfUser(holders[i], ids[i]) == 1) return i;
        }
        revert("no live position in fixture");
    }

    /// @notice A misaligned list must degrade to skips, never to a wrong payout. Each pair is
    ///         checked independently against balanceOfUser, so pairing holder[i] with someone
    ///         else's token[i] fails that check -- there is no ordering of the two arrays that pays
    ///         an address for a token it does not hold.
    function test_misalignedArraysSkipAndNeverMispay() public {
        _assertTimelockAuthority();

        // Rotate the token list by one against the holder list, so almost every pair is wrong.
        uint256 n = 40;
        address[] memory h = new address[](n);
        uint256[] memory t = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            h[i] = holders[i];
            t[i] = ids[(i + 1) % n];
        }

        uint256[] memory balancesBefore = new uint256[](n);
        for (uint256 i = 0; i < n; i++) balancesBefore[i] = eETH.balanceOf(h[i]);

        vm.prank(HOUSEKEEPER);
        (uint256 unwrapped, uint256 skipped) = mm.forceUnwrapForEEth(h, t);

        emit log_named_uint("misaligned unwrapped", unwrapped);
        emit log_named_uint("misaligned skipped  ", skipped);
        assertEq(unwrapped + skipped, n, "every entry produced an outcome");
        assertGt(skipped, 0, "the rotation produced real mismatches");

        // Whatever went through paid an address that genuinely held the token it was paired with.
        // Anything that did not is untouched.
        for (uint256 i = 0; i < n; i++) {
            uint256 gained = eETH.balanceOf(h[i]) - balancesBefore[i];
            if (gained == 0) continue;
            // Paid, so the pair must have been legitimate: that holder held that token, and it is
            // now burned. A holder owning several tokens can be paid under a rotated list, which is
            // correct -- they owned the token they were paid for.
            assertEq(nft.balanceOfUser(h[i], t[i]), 0, "the token paid for was burned from that holder");
        }
    }

    /// @notice A stray ERC20 comes out in full, since no position has a claim on it.
    function test_recoverStrayErc20InFull() public {
        _assertTimelockAuthority();

        // weETH is a real token the contract has no business holding.
        address weETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
        uint256 amount = 5 ether;
        deal(weETH, MM_PROXY, amount);

        assertEq(mm.recoverableAmount(weETH), amount, "the whole balance is recoverable");

        uint256 treasuryBefore = IERC20(weETH).balanceOf(TREASURY);

        vm.prank(OPERATING_TIMELOCK);
        uint256 recovered = mm.recoverTokens(weETH, TREASURY);

        assertEq(recovered, amount, "recovered the full balance");
        assertEq(IERC20(weETH).balanceOf(TREASURY), treasuryBefore + amount, "treasury received it");
        assertEq(IERC20(weETH).balanceOf(MM_PROXY), 0, "nothing left behind");
    }

    /// @notice The single entrypoint must not turn eETH into a full-balance recovery. This is the
    ///         property that a generic recoverERC20 would have destroyed: the caller names no
    ///         amount, and for eETH the amount is the surplus, not the balance.
    function test_recoverTokens_eEthStaysBoundedByTheObligation() public {
        _assertTimelockAuthority();

        uint256 balance = eETH.balanceOf(MM_PROXY);
        uint256 obligation = mm.outstandingEEthObligation();
        uint256 recoverable = mm.recoverableAmount(EETH);

        assertGt(obligation, 0, "positions are still outstanding");
        assertEq(recoverable, mm.unbackedEEth(), "eETH is quoted as the unbacked surplus");
        assertLt(recoverable, balance / 100, "almost the whole balance is off limits");

        vm.prank(OPERATING_TIMELOCK);
        uint256 recovered = mm.recoverTokens(EETH, TREASURY);

        assertEq(recovered, recoverable, "took only the surplus");
        assertGe(
            eETH.balanceOf(MM_PROXY) + 2,
            mm.outstandingEEthObligation(),
            "every outstanding position is still covered"
        );
    }

    function test_recoverTokens_revertsForNonTimelock() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        mm.recoverTokens(EETH, TREASURY);
    }

    function test_recoverTokens_rejectsSelfRecipient() public {
        _assertTimelockAuthority();

        vm.prank(OPERATING_TIMELOCK);
        vm.expectRevert(MembershipManager.ZeroRecipient.selector);
        mm.recoverTokens(address(0), MM_PROXY);
    }

    function test_lengthMismatchReverts() public {
        _assertTimelockAuthority();

        address[] memory h = new address[](2);
        uint256[] memory t = new uint256[](1);

        vm.prank(HOUSEKEEPER);
        vm.expectRevert(MembershipManager.LengthMismatch.selector);
        mm.forceUnwrapForEEth(h, t);
    }

    function test_sweepRejectsZeroRecipient() public {
        _assertTimelockAuthority();

        vm.prank(OPERATING_TIMELOCK);
        vm.expectRevert(MembershipManager.ZeroRecipient.selector);
        mm.recoverTokens(EETH, address(0));
    }

    /// @notice Voluntary exit must keep working; the migration function is additive.
    function test_voluntaryUnwrapStillWorks() public {
        uint256 idx = type(uint256).max;
        for (uint256 i = 0; i < ids.length; i++) {
            (uint96 vs,,,,,, uint8 version) = mm.tokenData(ids[i]);
            if (version == 1 && vs > 0 && nft.balanceOfUser(holders[i], ids[i]) == 1) { idx = i; break; }
        }
        require(idx != type(uint256).max, "no live position in fixture");

        address holder = holders[idx];
        uint256 before = eETH.balanceOf(holder);

        vm.prank(holder);
        mm.unwrapForEEthAndBurn(ids[idx]);

        assertGt(eETH.balanceOf(holder), before, "voluntary unwrap still pays out");
        assertEq(nft.balanceOfUser(holder, ids[idx]), 0, "NFT burned");
    }
}
