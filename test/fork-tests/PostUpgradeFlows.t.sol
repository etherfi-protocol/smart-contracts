// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@tests/TestSetup.sol";
import "@scripts/deploys/Deployed.s.sol";
import "@etherfi/withdrawals/interfaces/IWithdrawRequestNFT.sol";

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
