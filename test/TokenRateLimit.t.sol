// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@tests/TestSetup.sol";
import "@etherfi/governance/rate-limiting/interfaces/IEtherFiRateLimiter.sol";

contract TokenRateLimitTest is TestSetup {
    uint64 private constant ONE_ETHER_GWEI = 1 ether / 1 gwei; // 1e9

    function setUp() public {
        setUpTests();

        // Fund alice + bob + chad with eETH so transfer/burn/wrap tests have balance to move.
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(chad, 100 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 50 ether}();
        vm.prank(bob);
        liquidityPoolInstance.deposit{value: 50 ether}();
        vm.prank(chad);
        liquidityPoolInstance.deposit{value: 50 ether}();
    }

    // =====================================================================
    // Transfers are unrestricted — per-address rate limiting has been removed.
    // Any transfer size succeeds and touches no rate-limit bucket.
    // =====================================================================

    function test_eETH_large_transfer_passes_unrestricted() public {
        // Even with both eETH global buckets choked to 1 gwei, a large transfer
        // must go through: the transfer path consumes no bucket whatsoever.
        vm.startPrank(admin);
        rateLimiterInstance.setCapacity(eETHInstance.EETH_MINT_LIMIT_ID(), 1);
        rateLimiterInstance.setRemaining(eETHInstance.EETH_MINT_LIMIT_ID(), 1);
        rateLimiterInstance.setCapacity(eETHInstance.EETH_BURN_LIMIT_ID(), 1);
        rateLimiterInstance.setRemaining(eETHInstance.EETH_BURN_LIMIT_ID(), 1);
        vm.stopPrank();

        vm.prank(alice);
        eETHInstance.transfer(bob, 40 ether);
    }

    function test_weETH_large_transfer_passes_unrestricted() public {
        // weETH is not rate-limited at all (no mint/burn buckets). Wrap a chunk and
        // prove a large weETH transfer passes — there is no bucket to choke.
        vm.startPrank(alice);
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        uint256 weAmount = weEthInstance.wrap(40 ether);
        vm.stopPrank();

        vm.prank(alice);
        weEthInstance.transfer(bob, weAmount);
    }

    function test_global_transfers_are_NOT_globally_limited() public {
        // Tighten both eETH global IDs to 1 gwei each; transfers must still go
        // through because the transfer path does not consume MINT/BURN.
        vm.startPrank(admin);
        rateLimiterInstance.setCapacity(eETHInstance.EETH_MINT_LIMIT_ID(), 1);
        rateLimiterInstance.setRemaining(eETHInstance.EETH_MINT_LIMIT_ID(), 1);
        rateLimiterInstance.setCapacity(eETHInstance.EETH_BURN_LIMIT_ID(), 1);
        rateLimiterInstance.setRemaining(eETHInstance.EETH_BURN_LIMIT_ID(), 1);
        vm.stopPrank();

        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);
    }

    // =====================================================================
    // Access control — eETH is the only caller of consumeToken.
    // =====================================================================

    function test_rateLimiter_consumeToken_onlyToken_rejects_external_callers() public {
        bytes32 mintId = eETHInstance.EETH_MINT_LIMIT_ID();

        vm.expectRevert(IEtherFiRateLimiter.OnlyToken.selector);
        rateLimiterInstance.consumeToken(mintId, 1);

        // Even the operating timelock cannot bypass — only the two immutable token addresses.
        vm.prank(admin);
        vm.expectRevert(IEtherFiRateLimiter.OnlyToken.selector);
        rateLimiterInstance.consumeToken(mintId, 1);
    }

    // =====================================================================
    // Global MINT/BURN circuit-breaker buckets
    // =====================================================================
    //
    // Setup notes:
    // - TestSetup bootstraps the 4 global IDs at type(uint64).max so generic
    //   tests don't hit them. We tighten the specific ID under test via the
    //   rate limiter's admin API (pranked as admin / OPERATION_TIMELOCK).

    function test_global_eETH_mint_bucket_throttles_protocol_wide_mints() public {
        // Cap the global mint bucket at exactly 1 ether/gwei, no refill.
        vm.startPrank(admin);
        rateLimiterInstance.setCapacity(eETHInstance.EETH_MINT_LIMIT_ID(), ONE_ETHER_GWEI);
        rateLimiterInstance.setRefillRate(eETHInstance.EETH_MINT_LIMIT_ID(), 0);
        rateLimiterInstance.setRemaining(eETHInstance.EETH_MINT_LIMIT_ID(), ONE_ETHER_GWEI);
        vm.stopPrank();

        // First 1-ether deposit fits exactly.
        vm.deal(chad, 100 ether);
        vm.prank(chad);
        liquidityPoolInstance.deposit{value: 1 ether}();

        // Bucket exhausted — next mint reverts.
        vm.deal(dan, 1 ether);
        vm.prank(dan);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        liquidityPoolInstance.deposit{value: 1 gwei}();
    }

    function test_global_eETH_burn_bucket_throttles_protocol_wide_burns() public {
        // Cap the global burn bucket at 2 ether/gwei (covers exactly 2 burns of ~1 ETH).
        vm.startPrank(admin);
        rateLimiterInstance.setCapacity(eETHInstance.EETH_BURN_LIMIT_ID(), 2 * ONE_ETHER_GWEI);
        rateLimiterInstance.setRefillRate(eETHInstance.EETH_BURN_LIMIT_ID(), 0);
        rateLimiterInstance.setRemaining(eETHInstance.EETH_BURN_LIMIT_ID(), 2 * ONE_ETHER_GWEI);
        vm.stopPrank();

        uint256 oneEthShare = liquidityPoolInstance.sharesForAmount(1 ether);
        vm.prank(address(liquidityPoolInstance));
        eETHInstance.burnShares(alice, oneEthShare);

        // Second burn pushes past the global cap.
        vm.prank(address(liquidityPoolInstance));
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        eETHInstance.burnShares(alice, oneEthShare);
    }

    function test_global_eETH_mint_and_burn_buckets_are_independent() public {
        // Tighten only MINT to a tiny non-zero cap. NOTE: capacity == 0 on a
        // global bucket means "disabled (no-op)" per consumeToken — NOT frozen.
        // Use 1 gwei as the smallest non-zero cap to actually throttle.
        vm.startPrank(admin);
        rateLimiterInstance.setCapacity(eETHInstance.EETH_MINT_LIMIT_ID(), 1);
        rateLimiterInstance.setRefillRate(eETHInstance.EETH_MINT_LIMIT_ID(), 0);
        rateLimiterInstance.setRemaining(eETHInstance.EETH_MINT_LIMIT_ID(), 1);
        vm.stopPrank();

        vm.deal(dan, 1 ether);
        vm.prank(dan);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        liquidityPoolInstance.deposit{value: 1 ether}();

        // Burn path unaffected (BURN bucket still at type(uint64).max).
        uint256 oneEthShare = liquidityPoolInstance.sharesForAmount(1 ether);
        vm.prank(address(liquidityPoolInstance));
        eETHInstance.burnShares(alice, oneEthShare);
    }

    function test_cap0_reverts_LimitExceeded_on_global_consume() public {
        // `cap == 0` on an existing global bucket reverts LimitExceeded on every
        // consume. To soft-disable a global rate limit without un-whitelisting the
        // consumer, set capacity to type(uint64).max — effectively unlimited.
        bytes32 mintId = eETHInstance.EETH_MINT_LIMIT_ID();

        vm.startPrank(admin);
        rateLimiterInstance.setCapacity(mintId, 0);
        rateLimiterInstance.setRemaining(mintId, 0);
        vm.stopPrank();

        vm.deal(chad, 1 ether);
        vm.prank(chad);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        liquidityPoolInstance.deposit{value: 1 ether}();
    }

    // =====================================================================
    // weETH is not rate-limited: wrap/unwrap (and any other weETH mint/burn)
    // touch no bucket. The wrap/unwrap path is exercised by the deposit/flow
    // tests; there is no weETH mint/burn circuit breaker to assert here.
    // =====================================================================

    // =====================================================================
    // Bootstrap-ordering invariants  (READ THIS BEFORE UPGRADING eETH)
    // =====================================================================
    //
    // The two global MINT/BURN buckets — EETH_MINT_LIMIT_ID, EETH_BURN_LIMIT_ID —
    // MUST be created via `createNewLimiter` AND have eETH whitelisted via
    // `updateConsumers` BEFORE the new eETH impl is activated.
    // `_setupGlobalMintBurnBuckets` in TestSetup is the reference bootstrap.
    // (weETH is not rate-limited, so it has no bucket to bootstrap.)
    //
    //   Global-bucket state                                    | consumeToken behavior
    //   -------------------------------------------------------|-----------------------------
    //   1. Bucket never created (no createNewLimiter)          | revert UnknownLimit
    //   2. Bucket created, consumer not whitelisted            | revert InvalidConsumer
    //   3. Bucket created, consumer whitelisted, capacity == 0 | revert LimitExceeded
    //   4. Bucket created, consumer whitelisted, sufficient    | succeed, decrement remaining
    //   5. Bucket created, consumer whitelisted, insufficient  | revert LimitExceeded
    //
    // To soft-disable a global rate limit without un-whitelisting the consumer,
    // set capacity to type(uint64).max (effectively unlimited, never trips).
    //
    // Why this matters operationally: if a 3CP upgrade bundle swaps the eETH impl
    // WITHOUT including the createNewLimiter + updateConsumers calls in the same
    // bundle, the failure mode is total — every LP deposit and every burnShares
    // reverts. weETH wrap/unwrap is unaffected (weETH is not rate-limited). These
    // tests pin down each signal so the diagnosis is unambiguous.

    function test_bootstrap_state1_uncreated_bucket_reverts_UnknownLimit() public {
        // The real IDs are already created by TestSetup and there's no API
        // to delete a global bucket. Prove the failure mode using a synthetic
        // ID that has never been created — same code path eETH would hit on an
        // unbootstrapped upgrade.
        bytes32 neverCreatedId = keccak256("BOOTSTRAP_TEST_FAKE_ID");

        vm.prank(address(eETHInstance));
        vm.expectRevert(IEtherFiRateLimiter.UnknownLimit.selector);
        rateLimiterInstance.consumeToken(neverCreatedId, 1);
    }

    function test_bootstrap_state2_LP_deposit_reverts_InvalidConsumer_when_consumer_not_whitelisted() public {
        // Bucket exists (TestSetup created it at uint64.max) but if eETH is
        // removed from the consumer whitelist, the consume call reverts
        // InvalidConsumer BEFORE any capacity check.
        // NOTE: resolve the bucket ID into a local BEFORE `vm.prank`.
        bytes32 mintId = eETHInstance.EETH_MINT_LIMIT_ID();
        vm.prank(admin);
        rateLimiterInstance.updateConsumers(mintId, address(eETHInstance), false);

        vm.deal(chad, 1 ether);
        vm.prank(chad);
        vm.expectRevert(IEtherFiRateLimiter.InvalidConsumer.selector);
        liquidityPoolInstance.deposit{value: 1 ether}();
    }

    function test_bootstrap_state2_LP_burn_reverts_InvalidConsumer_when_consumer_not_whitelisted() public {
        // Same story for the burn side — confirms both directions of the supply
        // change are gated by the same consumer-whitelist check.
        bytes32 burnId = eETHInstance.EETH_BURN_LIMIT_ID();
        vm.prank(admin);
        rateLimiterInstance.updateConsumers(burnId, address(eETHInstance), false);

        uint256 oneEthShare = liquidityPoolInstance.sharesForAmount(1 ether);
        vm.prank(address(liquidityPoolInstance));
        vm.expectRevert(IEtherFiRateLimiter.InvalidConsumer.selector);
        eETHInstance.burnShares(alice, oneEthShare);
    }

    function test_bootstrap_weETH_wrap_is_never_rate_limited() public {
        // weETH has no mint/burn bucket, so wrap/unwrap can never be gated by
        // rate-limiter state. Revoking eETH's consumer entry would only affect
        // eETH mint/burn — weETH wrap stays available regardless.
        vm.startPrank(alice);
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        weEthInstance.wrap(1 ether);
        vm.stopPrank();
    }

    function test_bootstrap_sentinel_matrix_via_rateLimiter_direct() public {
        // Same matrix as the LP-level tests above, but called directly on the
        // rate limiter so future agents can see all five outcomes in one
        // executable lookup table.
        bytes32 fakeId = keccak256("BOOTSTRAP_TEST_SENTINEL_MATRIX");
        bytes32 realId = eETHInstance.EETH_MINT_LIMIT_ID();

        // State 1: bucket never created.
        vm.prank(address(eETHInstance));
        vm.expectRevert(IEtherFiRateLimiter.UnknownLimit.selector);
        rateLimiterInstance.consumeToken(fakeId, 1);

        // State 2: bucket created, consumer revoked.
        vm.prank(admin);
        rateLimiterInstance.updateConsumers(realId, address(eETHInstance), false);
        vm.prank(address(eETHInstance));
        vm.expectRevert(IEtherFiRateLimiter.InvalidConsumer.selector);
        rateLimiterInstance.consumeToken(realId, 1);

        // Re-whitelist for the remaining states.
        vm.prank(admin);
        rateLimiterInstance.updateConsumers(realId, address(eETHInstance), true);

        // State 3: cap == 0 → revert LimitExceeded.
        vm.startPrank(admin);
        rateLimiterInstance.setCapacity(realId, 0);
        rateLimiterInstance.setRemaining(realId, 0);
        vm.stopPrank();
        vm.prank(address(eETHInstance));
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        rateLimiterInstance.consumeToken(realId, 1);

        // State 4: cap > 0, sufficient → succeeds.
        vm.startPrank(admin);
        rateLimiterInstance.setCapacity(realId, 100);
        rateLimiterInstance.setRemaining(realId, 100);
        rateLimiterInstance.setRefillRate(realId, 0);
        vm.stopPrank();
        vm.prank(address(eETHInstance));
        rateLimiterInstance.consumeToken(realId, 50);

        // State 5: cap > 0, insufficient → LimitExceeded.
        // After the 50-unit consume above, remaining == 50. Asking for 51 reverts.
        vm.prank(address(eETHInstance));
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        rateLimiterInstance.consumeToken(realId, 51);
    }
}
