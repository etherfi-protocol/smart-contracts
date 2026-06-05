// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/StdError.sol";
import "./TestSetup.sol";

/// @notice **Architectural finding — surfaced during PR #437 fuzz work, pinned here.**
///
///         `LiquidityPool.rebase(negative)` reduces `totalValueOutOfLp`
///         without coordinating with the segregated-escrow lock counters
///         on `WithdrawRequestNFT` (`ethAmountLockedForWithdrawal`) and
///         `PriorityWithdrawalQueue` (`ethAmountLockedForPriorityWithdrawal`).
///
///         When a finalized WRN claim subsequently calls
///         `LiquidityPool.withdraw(amount, frozenRate)` and the rebase
///         has driven `totalValueOutOfLp` below `amount`, the contract's
///         checked subtraction
///
///             totalValueOutOfLp -= uint128(_amountOfEEth);   // LiquidityPool.sol
///
///         underflows and the entire claim transaction reverts with
///         `Panic(0x11)`. This is a **user-facing DoS on a finalized
///         withdrawal**: the user's ETH is physically held by the WRN
///         escrow (their `WRN.balance >= amountToWithdraw`), but
///         `WRN.claimWithdraw` cannot complete because the LP-side
///         accounting subtraction underflows.
///
///         **Production exposure assessment.**
///         - `LP.rebase` is gated to `msg.sender == membershipManager`.
///         - In production, `membershipManager` is invoked from
///           `EtherFiAdmin.executeTasks`, which runs `_validateRebaseApr`
///           and reverts if `|reportedAprInBps| > acceptableRebaseAprInBps`.
///         - The APR cap is `acceptableRebaseAprInBps`, an admin-tunable
///           int32 with an upper bound of `maxAcceptableRebaseAprInBps`
///           (an immutable). Test default = `10000` bps = 100% annualised.
///         - For a single report, the magnitude is bounded by
///           `apr_bps * currentTVL * elapsedTime / (365 days * BPS)`.
///         - The DoS is reachable when accumulated negative rebases
///           between a request being finalized and the user claiming
///           drop `totalValueOutOfLp` below that request's `amountOfEEth`.
///           This requires `Σ(negative_rebases) > totalValueOutOfLp - amountOfEEth`,
///           which is possible with sustained slashing or oracle bugs.
///
///         **Why this matters even with the APR cap.**
///         - `totalValueOutOfLp` includes BOTH staking ETH (legitimately
///           reducible via slashing) AND segregated-escrow locks (which
///           must remain backed by `outOfLp` accounting). A negative
///           rebase that legitimately reflects slashing on staked ETH
///           still reduces the SAME `outOfLp` counter the lock
///           accounting lives on.
///         - The fix shape (separately tracked staking-vs-locked
///           buckets, or a `rebase` that excludes the lock-counter sum,
///           or a claim path that floors the LP-side decrement at 0)
///           is an architectural decision for the team. This test pins
///           the current behaviour as a regression guard either way.
///
///         **Two tests in this file:**
///         1. `test_rebase_after_finalize_underflows_lp_withdraw` —
///            constructs the exact failure sequence and asserts the
///            current behaviour (Panic). If the contract is later
///            patched, this test will fail and force a follow-up.
///         2. `test_small_rebase_after_finalize_claim_succeeds` —
///            positive control: a rebase small enough to keep
///            `outOfLp >= amountToWithdraw` lets the claim succeed.
contract LpRebaseWrnClaimUnderflowTest is TestSetup {
    address internal claimant;

    function setUp() public {
        setUpTests();
        // Unpause WRN — TestSetup leaves it paused; claimWithdraw is not
        // gated by that flag but the rest of the WRN surface is.
        vm.prank(alice);
        withdrawRequestNFTInstance.unpause();

        claimant = address(uint160(uint256(keccak256("rebase-underflow.claimant"))));
        vm.deal(claimant, 200 ether);
        vm.prank(claimant);
        liquidityPoolInstance.deposit{value: 100 ether}();
        // LP.requestWithdraw transfers eETH from the caller to WRN —
        // requires allowance.
        vm.prank(claimant);
        eETHInstance.approve(address(liquidityPoolInstance), type(uint256).max);
    }

    /// **Demonstrates the DoS.** Setup → request 50 ETH → finalize + lock
    /// → negative rebase that drops outOfLp below the pending claim's
    /// amount → claim reverts with Panic(0x11) inside `LP.withdraw`.
    function test_rebase_after_finalize_underflows_lp_withdraw() public {
        uint256 requestAmount = 50 ether;

        // ===== Step 1: actor requests withdrawal. No ETH moves yet — only =====
        // shares get transferred from claimant to WRN. outOfLp still 0.
        vm.prank(claimant);
        uint256 tokenId = liquidityPoolInstance.requestWithdraw(claimant, requestAmount);

        assertEq(uint256(liquidityPoolInstance.totalValueOutOfLp()), 0, "outOfLp dirty pre-finalize");
        assertEq(uint256(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal()), 0, "WRN lock dirty pre-finalize");

        // ===== Step 2: EtherFiAdmin finalizes + transfers ETH to WRN. =====
        // After this, the request is claimable: outOfLp +=
        // requestAmount, WRN.balance == requestAmount, WRN.lock ==
        // requestAmount.
        vm.startPrank(address(etherFiAdminInstance));
        liquidityPoolInstance.addEthAmountLockedForWithdrawal(uint128(requestAmount));
        withdrawRequestNFTInstance.finalizeRequests(tokenId);
        vm.stopPrank();

        assertEq(uint256(liquidityPoolInstance.totalValueOutOfLp()), requestAmount, "outOfLp wrong post-finalize");
        assertEq(uint256(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal()), requestAmount, "WRN lock wrong post-finalize");
        assertEq(address(withdrawRequestNFTInstance).balance, requestAmount, "WRN balance wrong post-finalize");

        // ===== Step 3: negative rebase. Drops outOfLp by 45 ether, =====
        // leaving 5 ether. The WRN.lock counter does NOT decrease.
        // After this, `outOfLp (5) < requestAmount (50)`.
        int128 rebaseDelta = -int128(int256(uint256(45 ether)));
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(rebaseDelta);

        assertEq(uint256(liquidityPoolInstance.totalValueOutOfLp()), 5 ether, "outOfLp wrong post-rebase");
        assertEq(uint256(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal()), requestAmount, "WRN lock should be UNCHANGED");
        assertEq(address(withdrawRequestNFTInstance).balance, requestAmount, "WRN balance should be UNCHANGED");

        // ===== Step 4: claim. The WRN side has the ETH physically =====
        // available (balance == requestAmount). But LP.withdraw runs
        // `totalValueOutOfLp -= uint128(_amount)` where _amount ==
        // amountToWithdraw (~50 ether) > outOfLp (5 ether). Checked
        // subtraction underflows → Panic(0x11) → the entire claim
        // reverts.
        vm.prank(claimant);
        vm.expectRevert(stdError.arithmeticError);
        withdrawRequestNFTInstance.claimWithdraw(tokenId);

        // Sanity: the WRN's lock counter remained intact (the revert
        // rolled back the lock decrement too), so the funds are not
        // accounting-orphaned — they're just stuck behind the
        // underflow until either (a) outOfLp is restored via positive
        // rebase or (b) the protocol is patched.
        assertEq(uint256(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal()), requestAmount, "WRN lock corrupted by reverted claim");
        assertEq(address(withdrawRequestNFTInstance).balance, requestAmount, "WRN balance corrupted by reverted claim");
    }

    /// **Positive control.** Same setup, but pre-seed `outOfLp` headroom
    /// with a positive rebase so a small subsequent negative rebase
    /// can't drive `outOfLp` below the lock. Demonstrates that the
    /// underflow only fires under the specific magnitude condition,
    /// not as a general rule.
    function test_small_rebase_after_finalize_claim_succeeds() public {
        uint256 requestAmount = 50 ether;

        // Seed 0.25 ether of headroom in outOfLp via a positive rebase (within the 25 bps
        // cap: 0.25% of the 100 ETH pool). This simulates legitimate accrued rewards:
        // outOfLp grows without ETH actually moving into the LP. Without this, the lock
        // transfer at finalize would leave outOfLp == lock exactly, and a negative rebase
        // would underflow at claim time.
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(int128(int256(uint256(0.25 ether))));

        vm.prank(claimant);
        uint256 tokenId = liquidityPoolInstance.requestWithdraw(claimant, requestAmount);

        vm.startPrank(address(etherFiAdminInstance));
        liquidityPoolInstance.addEthAmountLockedForWithdrawal(uint128(requestAmount));
        withdrawRequestNFTInstance.finalizeRequests(tokenId);
        vm.stopPrank();

        // outOfLp == 50.25 ether (0.25 seeded + 50 from lock), lock == 50.
        // A small negative rebase (-0.1 ether) drops outOfLp to 50.15 —
        // still above the lock.
        int128 rebaseDelta = -int128(int256(uint256(0.1 ether)));
        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(rebaseDelta);

        assertGt(uint256(liquidityPoolInstance.totalValueOutOfLp()), requestAmount, "outOfLp dropped below lock");

        uint256 claimantBalBefore = claimant.balance;
        vm.prank(claimant);
        withdrawRequestNFTInstance.claimWithdraw(tokenId);
        assertGt(claimant.balance, claimantBalBefore, "claim paid nothing");
        assertEq(uint256(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal()), 0, "lock not cleared after claim");
    }

    /// **Quantifies the boundary.** Shows the rebase magnitude that
    /// EXACTLY exhausts outOfLp's headroom over the locked amount.
    /// Any rebase magnitude greater than this triggers the underflow;
    /// any rebase ≤ this is safe.
    ///
    /// Useful for the team's decision on whether to:
    /// (a) keep the current architecture and document
    ///     `acceptableRebaseAprInBps × elapsedTime` as the ceiling, OR
    /// (b) change `LP.rebase` to revert when it would drive `outOfLp <
    ///     WRN.lock + PQ.lock`, OR
    /// (c) change `LP.withdraw` to floor the `totalValueOutOfLp`
    ///     decrement at 0 when called from the segregated path.
    function test_boundary_rebase_exactly_at_safe_limit() public {
        uint256 requestAmount = 50 ether;

        vm.prank(claimant);
        uint256 tokenId = liquidityPoolInstance.requestWithdraw(claimant, requestAmount);

        vm.startPrank(address(etherFiAdminInstance));
        liquidityPoolInstance.addEthAmountLockedForWithdrawal(uint128(requestAmount));
        withdrawRequestNFTInstance.finalizeRequests(tokenId);
        vm.stopPrank();

        // Compute amountToWithdraw via the same formula the contract uses.
        // For this test (no rebase yet between request and finalize), it
        // equals requestAmount up to wei-rounding on the rate.
        uint256 amountToWithdraw = withdrawRequestNFTInstance.getClaimableAmount(tokenId);

        // Safe boundary: outOfLp_after == amountToWithdraw exactly.
        uint256 outOfLpBefore = uint256(liquidityPoolInstance.totalValueOutOfLp());
        uint256 maxSafeRebase = outOfLpBefore - amountToWithdraw;
        int128 rebaseDelta = -int128(int256(maxSafeRebase));

        vm.prank(address(membershipManagerInstance));
        liquidityPoolInstance.rebase(rebaseDelta);

        // outOfLp == amountToWithdraw. The claim's LP.withdraw decrement
        // brings it to exactly 0 — no underflow.
        assertEq(uint256(liquidityPoolInstance.totalValueOutOfLp()), amountToWithdraw, "boundary miscomputed");

        vm.prank(claimant);
        withdrawRequestNFTInstance.claimWithdraw(tokenId);

        assertEq(uint256(liquidityPoolInstance.totalValueOutOfLp()), 0, "outOfLp not exactly zero post-claim");

        // One more wei of rebase magnitude would have underflowed.
        // (Captured implicitly: the test_rebase_after_finalize_underflows
        // test above is the same shape with a much larger magnitude.)
    }
}
