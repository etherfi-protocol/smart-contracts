// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@tests/TestSetup.sol";
import "@scripts/deploys/Deployed.s.sol";
import "@etherfi/withdrawals/interfaces/IWithdrawRequestNFT.sol";
// Aliased: `Deployed` defines an `EETH` address constant that shadows the contract type.
import {EETH as EETHImpl} from "@etherfi/core/EETH.sol";

/// @notice Post-upgrade functional smoke tests for the 26Q2 security upgrade.
///
/// `initializeRealisticFork(MAINNET_FORK)` applies the full new-impl upgrade in place
/// (LP / EETH / WeETH / WRN / EtherFiAdmin / RateLimiter / NodesManager / StakingManager /
/// Liquifier / RoleRegistry), runs the escrow migration, seeds the LP withdraw bounds, and
/// bootstraps the rate-limiter mint/burn buckets — i.e. the same end-state the
/// `transactions.s.sol` upgrade batches produce. These tests assert the core user/operator
/// flows still work AFTER that upgrade:
///   1. deposit → eETH minted, TVL updated
///   2. deposit → wrap to weETH → unwrap
///   3. oracle report submit + execute (the 10-field report pipeline)
///   4. full withdrawal lifecycle: requestWithdraw → finalize (via report) → claim
///   5. instant redemption via EtherFiRedemptionManager (redeemEEth)
///
/// Requires MAINNET_RPC_URL. The fork helpers (`_syncOracleReportState`,
/// `_flushPendingWithdrawalBacklog`, `_sumValidRequestAmounts`) mirror
/// test/integration-tests/Withdraw.t.sol.
contract PostUpgradeFlowsTest is TestSetup, Deployed {
    address internal constant ETH_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Mirrors the post-change rate-limiter buckets in Constants.s.sol (gwei units).
    // EETH_MINT cap = 30,000 ETH @ ~2.083 ETH/s refill; EETH_BURN cap = 25,000 ETH @ ~1.736 ETH/s.
    uint64 internal constant EETH_MINT_CAP    = 30_000_000_000_000;
    uint64 internal constant EETH_MINT_REFILL = 2_083_333_333;
    uint64 internal constant EETH_BURN_CAP    = 25_000_000_000_000;
    uint64 internal constant EETH_BURN_REFILL = 1_736_111_111;
    bytes32 internal constant EETH_MINT_LIMIT_ID = keccak256("EETH_MINT_LIMIT_ID");
    bytes32 internal constant EETH_BURN_LIMIT_ID = keccak256("EETH_BURN_LIMIT_ID");

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);
        // `alice` (vm.addr(2)) has bytecode on the mainnet fork; clear it so the
        // WithdrawRequestNFT `_safeMint` to alice doesn't hit a non-ERC721Receiver.
        vm.etch(alice, bytes(""));
        // Upgrade Oracle + Admin to local impls so the new 10-field OracleReport ABI matches.
        _upgradeOracleAndAdminForFork();
        // Make operator report submission possible on a realistic fork.
        _syncOracleReportState();
        // Clear the pre-existing mainnet pending-withdrawal backlog so the per-day cap /
        // sum-of-requests checks start from a clean state.
        _flushPendingWithdrawalBacklog();
    }

    // ── flow 1: deposit ──────────────────────────────────────────────────
    function test_postUpgrade_deposit_mintsEEth_andUpdatesTvl() public {
        uint256 amount = 10 ether;
        vm.deal(alice, amount);

        uint256 tvlBefore  = liquidityPoolInstance.getTotalPooledEther();
        uint256 eethBefore = eETHInstance.balanceOf(alice);

        vm.prank(alice);
        liquidityPoolInstance.deposit{value: amount}();

        assertApproxEqAbs(eETHInstance.balanceOf(alice) - eethBefore, amount, 1e9, "eETH minted != deposit");
        assertApproxEqAbs(liquidityPoolInstance.getTotalPooledEther() - tvlBefore, amount, 1e9, "TVL not increased by deposit");
    }

    // ── flow 2: deposit → wrap → unwrap ──────────────────────────────────
    function test_postUpgrade_depositWrapUnwrapWeETH() public {
        uint256 amount = 10 ether;
        vm.deal(alice, amount);

        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: amount}();
        uint256 eethBal = eETHInstance.balanceOf(alice);

        eETHInstance.approve(address(weEthInstance), eethBal);
        uint256 weethOut = weEthInstance.wrap(eethBal);
        assertGt(weethOut, 0, "wrap produced no weETH");
        assertEq(weEthInstance.balanceOf(alice), weethOut, "weETH balance mismatch after wrap");

        uint256 eethOut = weEthInstance.unwrap(weethOut);
        assertApproxEqAbs(eethOut, eethBal, 1e9, "unwrap did not round-trip eETH");
        vm.stopPrank();
    }

    // ── flow 3: oracle report submission + execution ─────────────────────
    function test_postUpgrade_oracleReport_submitsAndExecutes() public {
        uint32 handledBefore = etherFiAdminInstance.lastHandledReportRefSlot();

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        // No withdrawal finalization in this report: target the current finalized id (no-op
        // range, so finalizedWithdrawalAmount must be 0). This isolates the report pipeline.
        report.lastFinalizedWithdrawalRequestId = withdrawRequestNFTInstance.lastFinalizedRequestId();
        _submitAndExecuteReport(report);

        assertGt(
            etherFiAdminInstance.lastHandledReportRefSlot(),
            handledBefore,
            "oracle report not handled (lastHandledReportRefSlot did not advance)"
        );
    }

    // ── flow 4: full withdrawal lifecycle (request → finalize → claim) ────
    function test_postUpgrade_withdraw_fullLifecycle() public {
        uint256 amount = 5 ether;
        vm.deal(alice, amount);

        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: amount}();
        eETHInstance.approve(address(liquidityPoolInstance), amount);
        uint256 requestId = liquidityPoolInstance.requestWithdraw(alice, amount);
        vm.stopPrank();

        assertEq(withdrawRequestNFTInstance.ownerOf(requestId), alice, "request NFT not owned by requester");
        assertTrue(withdrawRequestNFTInstance.getRequest(requestId).isValid, "request not valid");

        // Finalize via an oracle report covering this request, then claim.
        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.lastFinalizedWithdrawalRequestId = uint32(requestId);
        report.finalizedWithdrawalAmount = _sumValidRequestAmounts(uint32(requestId));
        _submitAndExecuteReport(report);

        assertGe(withdrawRequestNFTInstance.lastFinalizedRequestId(), requestId, "request not finalized");

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        withdrawRequestNFTInstance.claimWithdraw(requestId);
        assertApproxEqAbs(alice.balance - balBefore, amount, 1e12, "claim payout != requested amount");
    }

    // ── flow 5: instant redemption (EtherFiRedemptionManager.redeemEEth) ──
    function test_postUpgrade_instantRedeem_redeemEEth() public {
        // Make the ERH bucket + watermark permissive on the fork.
        vm.startPrank(OPERATING_TIMELOCK);
        etherFiRedemptionManagerInstance.setCapacity(3000 ether, ETH_TOKEN);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(3000 ether, ETH_TOKEN);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, ETH_TOKEN);
        vm.stopPrank();
        vm.warp(block.timestamp + 1); // refill the bucket

        vm.deal(alice, 2010 ether);
        address receiver = makeAddr("redeem-receiver");
        vm.etch(receiver, bytes(""));

        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: 2005 ether}();
        uint256 redeemAmount = 2000 ether;

        (, , uint16 feeBps, ) = etherFiRedemptionManagerInstance.tokenToRedemptionInfo(ETH_TOKEN);
        uint256 shares = liquidityPoolInstance.sharesForAmount(redeemAmount);
        uint256 expectedToReceiver = liquidityPoolInstance.amountForShare((shares * (10000 - feeBps)) / 10000);

        uint256 receiverBefore = receiver.balance;
        eETHInstance.approve(address(etherFiRedemptionManagerInstance), redeemAmount);
        etherFiRedemptionManagerInstance.redeemEEth(redeemAmount, receiver, ETH_TOKEN);
        vm.stopPrank();

        assertApproxEqAbs(receiver.balance - receiverBefore, expectedToReceiver, 1e15, "receiver did not get redeemed ETH");
    }

    // ─────────────────────────────────────────────────────────────────────
    // eETH MINT / BURN rate-limit scenarios under the configured Constants values.
    // (setUp's _setupGlobalMintBurnBuckets bootstraps unbounded buckets; here we
    //  override the EETH_MINT/EETH_BURN buckets to the actual Constants values.)
    // ─────────────────────────────────────────────────────────────────────

    /// @dev `initializeRealisticFork` upgrades every contract EXCEPT EETH before swapping
    ///      RoleRegistry, and the deployed EETH gates `_authorizeUpgrade` via the (now-removed)
    ///      `onlyProtocolUpgrader`, so `upgradeTo` is unavailable afterward. Force the EETH proxy
    ///      onto the new (rate-limited) impl directly so the mint/burn consume path is active —
    ///      matching the real post-upgrade state (transactions.s.sol upgrades EETH).
    function _upgradeEEthToRateLimited() internal {
        address newEEth = address(new EETHImpl(
            address(liquidityPoolInstance), address(roleRegistryInstance),
            address(blacklisterInstance), address(rateLimiterInstance)
        ));
        // ERC1967/UUPS impl slot used across these proxies.
        vm.store(
            address(eETHInstance),
            0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc,
            bytes32(uint256(uint160(newEEth)))
        );
        require(address(eETHInstance.rateLimiter()) == address(rateLimiterInstance), "EETH not on rate-limited impl");
    }

    /// @dev Set the EETH_MINT/EETH_BURN buckets to the Constants values, full and refilled.
    function _configureEEthBuckets() internal {
        _upgradeEEthToRateLimited();
        vm.startPrank(owner); // holds OPERATION_TIMELOCK_ROLE in the realistic-fork setup
        rateLimiterInstance.setCapacity(EETH_MINT_LIMIT_ID, EETH_MINT_CAP);
        rateLimiterInstance.setRefillRate(EETH_MINT_LIMIT_ID, EETH_MINT_REFILL);
        rateLimiterInstance.setRemaining(EETH_MINT_LIMIT_ID, EETH_MINT_CAP);
        rateLimiterInstance.setCapacity(EETH_BURN_LIMIT_ID, EETH_BURN_CAP);
        rateLimiterInstance.setRefillRate(EETH_BURN_LIMIT_ID, EETH_BURN_REFILL);
        rateLimiterInstance.setRemaining(EETH_BURN_LIMIT_ID, EETH_BURN_CAP);
        vm.stopPrank();
    }

    function _makeRedemptionPermissive() internal {
        vm.startPrank(OPERATING_TIMELOCK);
        etherFiRedemptionManagerInstance.setCapacity(100_000 ether, ETH_TOKEN);
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(100_000 ether, ETH_TOKEN);
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, ETH_TOKEN);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
    }

    // The configured values are applied and a normal deposit mints, consuming the mint bucket.
    function test_eethMint_underNewLimit_succeeds_andDecrements() public {
        _configureEEthBuckets();

        (uint64 cap, uint64 remBefore, uint64 refill, ) = rateLimiterInstance.getLimit(EETH_MINT_LIMIT_ID);
        assertEq(cap, EETH_MINT_CAP, "mint capacity not set to Constants value");
        assertEq(refill, EETH_MINT_REFILL, "mint refill not set to Constants value");

        uint256 amount = 100 ether;
        vm.deal(alice, amount);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: amount}();

        (, uint64 remAfter, , ) = rateLimiterInstance.getLimit(EETH_MINT_LIMIT_ID);
        // consumed ~= toBucketUnit(100 ether) = 100e9 gwei (refill over a couple of fork seconds is negligible)
        assertApproxEqAbs(uint256(remBefore) - uint256(remAfter), uint256(100_000_000_000), uint256(EETH_MINT_REFILL) * 5, "mint bucket not decremented by deposit");
    }

    // A deposit larger than the remaining mint allowance is throttled (LimitExceeded).
    function test_eethMint_overRemaining_reverts() public {
        _configureEEthBuckets();
        // Pre-deplete the mint bucket to 5 ETH-equiv so a small deposit crosses it
        // (capacity stays the real 30k value; we only lower `remaining`).
        vm.prank(owner);
        rateLimiterInstance.setRemaining(EETH_MINT_LIMIT_ID, 5_000_000_000); // 5 ETH in gwei

        vm.deal(alice, 6 ether);
        vm.prank(alice);
        vm.expectRevert(bytes4(keccak256("LimitExceeded()")));
        liquidityPoolInstance.deposit{value: 6 ether}();
    }

    // After the mint bucket is emptied, it refills over time at the configured rate.
    function test_eethMint_refillsAtConfiguredRate() public {
        _configureEEthBuckets();
        vm.prank(owner);
        rateLimiterInstance.setRemaining(EETH_MINT_LIMIT_ID, 0); // drained

        vm.deal(alice, 2 ether);
        // Empty bucket: even 1 ETH reverts.
        vm.prank(alice);
        vm.expectRevert(bytes4(keccak256("LimitExceeded()")));
        liquidityPoolInstance.deposit{value: 1 ether}();

        // Warp ~10s: refills ~20 ETH-equiv (10 * 2.083 ETH/s) > 1 ETH.
        vm.warp(block.timestamp + 10);
        assertGt(rateLimiterInstance.consumable(EETH_MINT_LIMIT_ID), 1_000_000_000, "bucket did not refill");
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 1 ether}(); // now succeeds
    }

    // A normal redemption burns eETH and consumes the burn bucket.
    function test_eethBurn_underNewLimit_succeeds_andDecrements() public {
        _configureEEthBuckets();
        _makeRedemptionPermissive();

        vm.deal(alice, 200 ether);
        address receiver = makeAddr("burn-receiver");
        vm.etch(receiver, bytes(""));
        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: 200 ether}();

        (, uint64 remBefore, , ) = rateLimiterInstance.getLimit(EETH_BURN_LIMIT_ID);

        uint256 redeemAmount = 50 ether;
        eETHInstance.approve(address(etherFiRedemptionManagerInstance), redeemAmount);
        etherFiRedemptionManagerInstance.redeemEEth(redeemAmount, receiver, ETH_TOKEN);
        vm.stopPrank();

        (, uint64 remAfter, , ) = rateLimiterInstance.getLimit(EETH_BURN_LIMIT_ID);
        assertLt(remAfter, remBefore, "burn bucket not decremented by redemption");
    }

    // A redemption larger than the remaining burn allowance is throttled (LimitExceeded).
    function test_eethBurn_overRemaining_reverts() public {
        _configureEEthBuckets();
        _makeRedemptionPermissive();

        vm.deal(alice, 200 ether);
        address receiver = makeAddr("burn-receiver-2");
        vm.etch(receiver, bytes(""));
        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: 200 ether}(); // mint OK (mint bucket full)
        vm.stopPrank();

        // Deplete the burn bucket to 5 ETH-equiv, then redeem 50 ETH -> burn crosses it.
        vm.prank(owner);
        rateLimiterInstance.setRemaining(EETH_BURN_LIMIT_ID, 5_000_000_000); // 5 ETH in gwei

        vm.startPrank(alice);
        eETHInstance.approve(address(etherFiRedemptionManagerInstance), 50 ether);
        vm.expectRevert(bytes4(keccak256("LimitExceeded()")));
        etherFiRedemptionManagerInstance.redeemEEth(50 ether, receiver, ETH_TOKEN);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────
    // Helpers (mirrored from test/integration-tests/Withdraw.t.sol)
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Advance the oracle epoch, build/submit the report via both operators, wait the
    ///      post-report window, then executeTasks. Mirrors the inline flow in Withdraw.t.sol.
    function _submitAndExecuteReport(IEtherFiOracle.OracleReport memory report) internal {
        // Advance until the next report epoch is considered finalized.
        while (true) {
            uint32 slot = etherFiOracleInstance.slotForNextReport();
            uint32 curr = etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp);
            uint32 min = ((slot / 32) + 3) * 32;
            if (curr >= min) break;
            uint256 d = min - curr;
            vm.roll(block.number + d);
            vm.warp(etherFiOracleInstance.beaconGenesisTimestamp() + 12 * (curr + uint32(d)));
        }

        (report.refSlotFrom, report.refSlotTo, report.refBlockFrom) = etherFiOracleInstance.blockStampForNextReport();
        report.refBlockTo = uint32(block.number - 1);
        if (report.refBlockTo <= etherFiAdminInstance.lastAdminExecutionBlock()) {
            report.refBlockTo = etherFiAdminInstance.lastAdminExecutionBlock() + 1;
        }

        vm.prank(AVS_OPERATOR_1);
        etherFiOracleInstance.submitReport(report);
        vm.prank(AVS_OPERATOR_2);
        etherFiOracleInstance.submitReport(report);

        uint256 slotsToWait = uint256(etherFiAdminInstance.postReportWaitTimeInSlots() + 1);
        uint32 slotAfter = etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp);
        vm.roll(block.number + slotsToWait);
        vm.warp(etherFiOracleInstance.beaconGenesisTimestamp() + 12 * (slotAfter + slotsToWait));

        vm.prank(ADMIN_EOA);
        etherFiAdminInstance.executeTasks(report);
    }

    function _flushPendingWithdrawalBacklog() internal {
        address roleOwner = roleRegistryInstance.owner();
        vm.startPrank(roleOwner);
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_TIMELOCK_ROLE(), address(this));
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_TIMELOCK_ROLE(), OPERATING_TIMELOCK);
        vm.stopPrank();

        uint32 head = withdrawRequestNFTInstance.nextRequestId();
        if (head > 0) {
            vm.prank(address(etherFiAdminInstance));
            withdrawRequestNFTInstance.finalizeRequests(head - 1);
        }
        etherFiAdminInstance.updateMaxFinalizedWithdrawalAmountPerDay(
            etherFiAdminInstance.maxAcceptableFinalizedWithdrawalAmountPerDay()
        );
    }

    function _syncOracleReportState() internal {
        uint32 lastPublished = etherFiOracleInstance.lastPublishedReportRefSlot();
        uint32 lastHandled   = etherFiAdminInstance.lastHandledReportRefSlot();
        if (lastPublished != lastHandled) {
            uint32 lastPublishedBlock = etherFiOracleInstance.lastPublishedReportRefBlock();
            bytes32 slot209 = vm.load(address(etherFiAdminInstance), bytes32(uint256(209)));
            uint256 val = uint256(slot209);
            val &= ~uint256(0xFFFFFFFFFFFFFFFF);
            val |= uint256(lastPublished);
            val |= uint256(lastPublishedBlock) << 32;
            vm.store(address(etherFiAdminInstance), bytes32(uint256(209)), bytes32(val));
        }

        address oracleOwner = roleRegistryInstance.owner();
        bytes32 opTimelockRole = roleRegistryInstance.OPERATION_TIMELOCK_ROLE();
        vm.prank(roleRegistryInstance.owner());
        roleRegistryInstance.grantRole(opTimelockRole, oracleOwner);
        vm.startPrank(oracleOwner);
        uint32 active = etherFiOracleInstance.numActiveCommitteeMembers();
        uint32 quorumAfterRemove = active > 1 ? (active - 1) / 2 + 1 : 1;
        uint32 quorumAfterAdd = active / 2 + 1;
        etherFiOracleInstance.removeCommitteeMember(AVS_OPERATOR_1, quorumAfterRemove);
        etherFiOracleInstance.addCommitteeMember(AVS_OPERATOR_1, quorumAfterAdd);
        etherFiOracleInstance.removeCommitteeMember(AVS_OPERATOR_2, quorumAfterRemove);
        etherFiOracleInstance.addCommitteeMember(AVS_OPERATOR_2, quorumAfterAdd);
        vm.stopPrank();
    }

    function _sumValidRequestAmounts(uint32 _lastFinalizedRequestIdInclusive) internal view returns (uint128) {
        uint256 sum;
        uint32 from = withdrawRequestNFTInstance.lastFinalizedRequestId() + 1;
        for (uint256 i = from; i <= _lastFinalizedRequestIdInclusive; i++) {
            IWithdrawRequestNFT.WithdrawRequest memory r = withdrawRequestNFTInstance.getRequest(i);
            if (r.isValid) sum += r.amountOfEEth;
        }
        return uint128(sum);
    }
}
