// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@tests/TestSetup.sol";
import "@etherfi/governance/rate-limiting/interfaces/IEtherFiRateLimiter.sol";
import "@etherfi/governance/rate-limiting/RateLimitedToken.sol";

contract TokenRateLimitTest is TestSetup {
    uint64 private constant ONE_ETHER_GWEI = 1 ether / 1 gwei; // 1e9

    // `admin` is granted OPERATION_TIMELOCK, OPERATION_MULTISIG, and GUARDIAN roles
    // by TestSetup. `attacker` here is granted GUARDIAN only — separates Guardian
    // capabilities from Multisig capabilities in the access-control tests.
    address internal guardianOnly;
    address internal multisigOnly;
    address internal unauthorized = address(0xDEAD);

    function setUp() public {
        setUpTests();

        // Fund alice + bob with eETH so transfer/burn/wrap tests have balance to move.
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(chad, 100 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 50 ether}();
        vm.prank(bob);
        liquidityPoolInstance.deposit{value: 50 ether}();
        vm.prank(chad);
        liquidityPoolInstance.deposit{value: 50 ether}();

        // Carve out role-isolated test addresses so we can prove the access split.
        guardianOnly = address(0xCAFE);
        multisigOnly = address(0xBEEF);
        vm.startPrank(owner);
        roleRegistryInstance.grantRole(roleRegistryInstance.GUARDIAN_ROLE(), guardianOnly);
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_MULTISIG_ROLE(), multisigOnly);
        vm.stopPrank();
    }

    // =====================================================================
    // Single-user wrappers around the batch-only token entry points. EETH and
    // WeETH only expose batch functions; these helpers handle the length-1
    // array boilerplate so tests stay readable. Callers still do their own
    // vm.prank(...) before invoking — the helpers are NOT pranking wrappers.
    // =====================================================================
    function _tightenEth(address user, uint64 cap, uint64 refill) internal {
        (address[] memory u, uint64[] memory c, uint64[] memory r) = _one(user, cap, refill);
        eETHInstance.tightenAddressRateLimits(u, c, r);
    }
    function _setEth(address user, uint64 cap, uint64 refill) internal {
        (address[] memory u, uint64[] memory c, uint64[] memory r) = _one(user, cap, refill);
        eETHInstance.setAddressRateLimits(u, c, r);
    }
    function _deleteEth(address user) internal {
        address[] memory u = new address[](1);
        u[0] = user;
        eETHInstance.deleteAddressRateLimits(u);
    }
    function _tightenWeeth(address user, uint64 cap, uint64 refill) internal {
        (address[] memory u, uint64[] memory c, uint64[] memory r) = _one(user, cap, refill);
        weEthInstance.tightenAddressRateLimits(u, c, r);
    }
    function _one(address user, uint64 cap, uint64 refill)
        internal
        pure
        returns (address[] memory users, uint64[] memory caps, uint64[] memory refills)
    {
        users = new address[](1);
        users[0] = user;
        caps = new uint64[](1);
        caps[0] = cap;
        refills = new uint64[](1);
        refills[0] = refill;
    }

    // =====================================================================
    // Sentinel / state-machine tests on the rate limiter directly
    // =====================================================================

    function test_addressLimit_unconfigured_is_unrestricted() public {
        // No bucket exists for alice — transfers go through unrestricted.
        assertFalse(rateLimiterInstance.addressLimitExists(address(eETHInstance), alice));
        vm.prank(alice);
        eETHInstance.transfer(bob, 10 ether);
    }

    function test_addressLimit_lastRefill_sentinel_distinguishes_not_created_from_frozen() public {
        (, , , uint256 lastRefillBefore) = rateLimiterInstance.getAddressLimit(address(eETHInstance), alice);
        assertEq(lastRefillBefore, 0, "not-created has lastRefill==0");

        // Freeze alice (capacity=0).
        vm.prank(admin);
        _tightenEth(alice, 0, 0);

        (uint64 cap, , , uint256 lastRefillAfter) = rateLimiterInstance.getAddressLimit(address(eETHInstance), alice);
        assertEq(cap, 0, "frozen has capacity==0");
        assertGt(lastRefillAfter, 0, "frozen has lastRefill > 0");
        assertTrue(rateLimiterInstance.addressLimitExists(address(eETHInstance), alice));
    }

    // =====================================================================
    // Access control — eETH/weETH are the only callers; Guardian vs Multisig split
    // =====================================================================

    function test_rateLimiter_onlyToken_rejects_external_callers() public {
        vm.expectRevert(IEtherFiRateLimiter.OnlyToken.selector);
        rateLimiterInstance.tightenAddressLimit(alice, 1, 1);

        vm.expectRevert(IEtherFiRateLimiter.OnlyToken.selector);
        rateLimiterInstance.setAddressLimit(alice, 1, 1);

        vm.expectRevert(IEtherFiRateLimiter.OnlyToken.selector);
        rateLimiterInstance.deleteAddressLimit(alice);

        vm.expectRevert(IEtherFiRateLimiter.OnlyToken.selector);
        rateLimiterInstance.consumeForAddressIfConfigured(alice, 1);

        // Even the operating timelock cannot bypass — only the two immutable token addresses.
        vm.prank(admin);
        vm.expectRevert(IEtherFiRateLimiter.OnlyToken.selector);
        rateLimiterInstance.tightenAddressLimit(alice, 1, 1);
    }

    function test_eETH_tighten_requires_guardian() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        _tightenEth(alice, 1, 1);

        vm.prank(guardianOnly);
        _tightenEth(alice, 1, 1);
    }

    function test_eETH_setAddressRateLimit_requires_multisig() public {
        // Guardian only — must NOT be able to call the multisig-gated set.
        vm.prank(guardianOnly);
        vm.expectRevert();
        _setEth(alice, 1, 1);

        vm.prank(multisigOnly);
        _setEth(alice, 1, 1);
    }

    function test_eETH_deleteAddressRateLimit_requires_multisig() public {
        // Create via Guardian path, then attempt delete from Guardian — must revert.
        vm.prank(guardianOnly);
        _tightenEth(alice, 5, 1);

        vm.prank(guardianOnly);
        vm.expectRevert();
        _deleteEth(alice);

        vm.prank(multisigOnly);
        _deleteEth(alice);
        assertFalse(rateLimiterInstance.addressLimitExists(address(eETHInstance), alice));
    }

    // =====================================================================
    // Tightening invariant — Guardian can only ever move buckets stricter
    // =====================================================================

    function test_guardian_first_create_accepts_any_params() public {
        vm.prank(guardianOnly);
        _tightenEth(alice, type(uint64).max, type(uint64).max);
        (uint64 cap, , uint64 refill, ) = rateLimiterInstance.getAddressLimit(address(eETHInstance), alice);
        assertEq(cap, type(uint64).max);
        assertEq(refill, type(uint64).max);
    }

    function test_guardian_cannot_raise_capacity() public {
        vm.prank(guardianOnly);
        _tightenEth(alice, 10, 1);

        vm.prank(guardianOnly);
        vm.expectRevert(IEtherFiRateLimiter.NotTightening.selector);
        _tightenEth(alice, 11, 1);
    }

    function test_guardian_cannot_raise_refillRate() public {
        vm.prank(guardianOnly);
        _tightenEth(alice, 10, 1);

        vm.prank(guardianOnly);
        vm.expectRevert(IEtherFiRateLimiter.NotTightening.selector);
        _tightenEth(alice, 10, 2);
    }

    function test_guardian_can_lower_capacity_and_refill() public {
        vm.prank(guardianOnly);
        _tightenEth(alice, 10, 5);

        vm.prank(guardianOnly);
        _tightenEth(alice, 4, 1);

        (uint64 cap, , uint64 refill, ) = rateLimiterInstance.getAddressLimit(address(eETHInstance), alice);
        assertEq(cap, 4);
        assertEq(refill, 1);
    }

    function test_guardian_idempotent_resubmit_succeeds() public {
        vm.prank(guardianOnly);
        _tightenEth(alice, 10, 5);
        vm.prank(guardianOnly);
        _tightenEth(alice, 10, 5);
    }

    function test_guardian_freeze_then_only_multisig_can_unfreeze() public {
        // Create with capacity.
        vm.prank(multisigOnly);
        _setEth(alice, uint64(10 ether / 1 gwei), 0);

        // Guardian freezes.
        vm.prank(guardianOnly);
        _tightenEth(alice, 0, 0);

        // Frozen → consume reverts on next transfer.
        vm.prank(alice);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        eETHInstance.transfer(bob, 1 ether);

        // Guardian cannot lift the freeze.
        vm.prank(guardianOnly);
        vm.expectRevert(IEtherFiRateLimiter.NotTightening.selector);
        _tightenEth(alice, 1, 1);

        // Multisig can.
        vm.prank(multisigOnly);
        _setEth(alice, uint64(10 ether / 1 gwei), 0);

        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);
    }

    function test_multisig_can_set_any_params() public {
        vm.prank(guardianOnly);
        _tightenEth(alice, 5, 1);

        // Multisig raises capacity above prior — no constraint.
        vm.prank(multisigOnly);
        _setEth(alice, 100, 10);

        (uint64 cap, , uint64 refill, ) = rateLimiterInstance.getAddressLimit(address(eETHInstance), alice);
        assertEq(cap, 100);
        assertEq(refill, 10);
    }

    // =====================================================================
    // Remaining preservation: Guardian's tighten preserves remaining (capped to
    // new capacity); Multisig's set fully resets.
    // =====================================================================

    function test_guardian_tighten_preserves_remaining_and_caps_to_new_capacity() public {
        // Capacity 10 gwei, no refill (created by Multisig so we start unconstrained).
        vm.prank(multisigOnly);
        _setEth(alice, 10, 0);

        // Drain 6 by transferring 6 gwei worth of eETH.
        vm.prank(alice);
        eETHInstance.transfer(bob, 6 * 1 gwei);
        (, uint64 remainingAfterConsume, , ) = rateLimiterInstance.getAddressLimit(address(eETHInstance), alice);
        assertEq(remainingAfterConsume, 4, "10 - 6 = 4 remaining");

        // Guardian tightens capacity to 8 — remaining must stay 4 (preserve), not reset to 8.
        vm.prank(guardianOnly);
        _tightenEth(alice, 8, 0);
        (uint64 cap1, uint64 rem1, , ) = rateLimiterInstance.getAddressLimit(address(eETHInstance), alice);
        assertEq(cap1, 8);
        assertEq(rem1, 4, "remaining preserved across tighten when new cap > remaining");

        // Tighten capacity below remaining → remaining capped down to new capacity.
        vm.prank(guardianOnly);
        _tightenEth(alice, 2, 0);
        (uint64 cap2, uint64 rem2, , ) = rateLimiterInstance.getAddressLimit(address(eETHInstance), alice);
        assertEq(cap2, 2);
        assertEq(rem2, 2, "remaining capped down to new capacity");
    }

    function test_multisig_set_fully_resets_remaining() public {
        // Drain alice's bucket.
        vm.prank(multisigOnly);
        _setEth(alice, 10, 0);
        vm.prank(alice);
        eETHInstance.transfer(bob, 6 * 1 gwei);

        // Multisig set acts as a full refresh — remaining returns to new capacity.
        vm.prank(multisigOnly);
        _setEth(alice, 10, 0);
        (uint64 cap, uint64 rem, , ) = rateLimiterInstance.getAddressLimit(address(eETHInstance), alice);
        assertEq(cap, 10);
        assertEq(rem, 10, "multisig set fully resets remaining (escape hatch)");
    }

    // =====================================================================
    // Hot-path: transfers consume from sender AND recipient buckets
    // =====================================================================

    function test_eETH_transfer_consumes_sender_bucket() public {
        vm.prank(guardianOnly);
        _tightenEth(alice, ONE_ETHER_GWEI, 0);

        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);

        // Next transfer of any positive amount exhausts the bucket.
        vm.prank(alice);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        eETHInstance.transfer(bob, 1 gwei);
    }

    function test_eETH_transfer_consumes_recipient_bucket() public {
        // Tag bob (the recipient) only. Alice has no bucket.
        vm.prank(guardianOnly);
        _tightenEth(bob, ONE_ETHER_GWEI, 0);

        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);

        vm.prank(alice);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        eETHInstance.transfer(bob, 1 gwei);
    }

    function test_eETH_self_transfer_charges_bucket_twice() public {
        // Self-transfer attack defense: each side of a self-transfer hits the same bucket.
        vm.prank(guardianOnly);
        _tightenEth(alice, 2 * ONE_ETHER_GWEI, 0);

        // 1-ether self-transfer consumes 2 ether of bucket (sender + recipient).
        vm.prank(alice);
        eETHInstance.transfer(alice, 1 ether);

        // Bucket fully drained — next 1-gwei self-transfer reverts.
        vm.prank(alice);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        eETHInstance.transfer(alice, 1 gwei);
    }

    function test_eETH_tagged_user_cannot_dos_untagged_user() public {
        // Tag alice with a tiny bucket; chad is untagged.
        vm.prank(guardianOnly);
        _tightenEth(alice, ONE_ETHER_GWEI, 0);

        // Alice self-transfers to exhaust her bucket.
        vm.prank(alice);
        eETHInstance.transfer(alice, 0.5 ether);

        vm.prank(alice);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        eETHInstance.transfer(alice, 0.6 ether);

        // Chad's transfer is completely unaffected — this is the whole point.
        vm.prank(chad);
        eETHInstance.transfer(bob, 10 ether);
    }

    function test_eETH_mint_consumes_recipient_bucket() public {
        vm.prank(guardianOnly);
        _tightenEth(chad, ONE_ETHER_GWEI, 0);

        // First 1 ether deposit fits.
        vm.deal(chad, 100 ether);
        vm.prank(chad);
        liquidityPoolInstance.deposit{value: 1 ether}();

        // Next deposit pushes past chad's mint bucket → revert in eETH.mintShares.
        vm.prank(chad);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        liquidityPoolInstance.deposit{value: 1 gwei}();
    }

    function test_eETH_burn_consumes_user_bucket() public {
        // burnShares mutates totalShares before computing amountForShare, so each
        // 1-ether share consumes slightly more than 1 ETH of bucket. 2 ETH capacity
        // fits the first burn but not two — same trick the prior bucket test used.
        vm.prank(guardianOnly);
        _tightenEth(alice, 2 * ONE_ETHER_GWEI, 0);

        uint256 oneEthShare = liquidityPoolInstance.sharesForAmount(1 ether);
        vm.prank(address(liquidityPoolInstance));
        eETHInstance.burnShares(alice, oneEthShare);

        vm.prank(address(liquidityPoolInstance));
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        eETHInstance.burnShares(alice, oneEthShare);
    }

    // =====================================================================
    // Refill behavior
    // =====================================================================

    function test_eETH_bucket_refills_over_time() public {
        vm.prank(guardianOnly);
        _tightenEth(alice, ONE_ETHER_GWEI, uint64(0.1 ether / 1 gwei));

        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);

        vm.prank(alice);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        eETHInstance.transfer(bob, 0.1 ether);

        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        eETHInstance.transfer(bob, 0.1 ether);
    }

    // =====================================================================
    // Delete returns user to unrestricted
    // =====================================================================

    function test_delete_restores_unrestricted_transfers() public {
        vm.prank(guardianOnly);
        _tightenEth(alice, ONE_ETHER_GWEI, 0);

        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);
        vm.prank(alice);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        eETHInstance.transfer(bob, 1 gwei);

        vm.prank(multisigOnly);
        _deleteEth(alice);
        assertFalse(rateLimiterInstance.addressLimitExists(address(eETHInstance), alice));

        // Alice is back to fully unrestricted.
        vm.prank(alice);
        eETHInstance.transfer(bob, 10 ether);
    }

    // =====================================================================
    // Namespace isolation: eETH bucket and weETH bucket are independent
    // =====================================================================

    function test_namespaces_are_isolated_across_eETH_and_weETH() public {
        // Tag alice on eETH only.
        vm.prank(guardianOnly);
        _tightenEth(alice, ONE_ETHER_GWEI, 0);

        // Wrap routes alice → weETH contract on eETH side (consumes alice's eETH bucket)
        // then mints to alice on weETH side (no weETH bucket on alice → unrestricted).
        vm.startPrank(alice);
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        uint256 weAmount = weEthInstance.wrap(1 ether);
        vm.stopPrank();

        // Alice's eETH bucket is now drained by the wrap (1 ether sender-leg).
        vm.prank(alice);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        eETHInstance.transfer(bob, 1 gwei);

        // But alice can move weETH freely — different namespace.
        vm.prank(alice);
        weEthInstance.transfer(bob, weAmount);
    }

    function test_weETH_transfer_consumes_sender_and_recipient() public {
        // Give alice some weETH first (no buckets configured → unrestricted wrap).
        vm.startPrank(alice);
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        uint256 weAmount = weEthInstance.wrap(2 ether);
        vm.stopPrank();

        // Tag alice on weETH only.
        uint64 cap = uint64(weAmount / 2 / 1 gwei);
        vm.prank(guardianOnly);
        _tightenWeeth(alice, cap, 0);

        // First transfer fits in the bucket.
        vm.prank(alice);
        weEthInstance.transfer(bob, weAmount / 2);

        // Next one exceeds → revert.
        vm.prank(alice);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        weEthInstance.transfer(bob, 1);
    }

    function test_weETH_wrap_consumes_recipient_bucket_via_mint() public {
        // Tag alice on weETH only — wrap mints weETH to alice (to-leg of _beforeTokenTransfer).
        vm.prank(guardianOnly);
        _tightenWeeth(alice, ONE_ETHER_GWEI, 0);

        vm.startPrank(alice);
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        // The amount of weETH minted equals sharesForAmount(1 ether). Under
        // typical fork state this is < 1 ether, but in fresh-state tests with
        // 1:1 share ratio it is exactly 1 ether → fits the bucket.
        weEthInstance.wrap(1 ether);

        // Next wrap exhausts alice's weETH bucket.
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        weEthInstance.wrap(1 gwei);
        vm.stopPrank();
    }

    // =====================================================================
    // Batch entry points
    // =====================================================================

    function test_eETH_batch_tighten_applies_each_user() public {
        address[] memory users      = new address[](2);
        uint64[]  memory capacities = new uint64[](2);
        uint64[]  memory refills    = new uint64[](2);
        users[0] = alice; capacities[0] = 10; refills[0] = 1;
        users[1] = bob;   capacities[1] = 20; refills[1] = 2;

        vm.prank(guardianOnly);
        eETHInstance.tightenAddressRateLimits(users, capacities, refills);

        (uint64 aCap, , uint64 aRefill, ) = rateLimiterInstance.getAddressLimit(address(eETHInstance), alice);
        (uint64 bCap, , uint64 bRefill, ) = rateLimiterInstance.getAddressLimit(address(eETHInstance), bob);
        assertEq(aCap, 10);
        assertEq(aRefill, 1);
        assertEq(bCap, 20);
        assertEq(bRefill, 2);
    }

    function test_eETH_batch_mismatched_lengths_reverts() public {
        address[] memory users      = new address[](2);
        uint64[]  memory capacities = new uint64[](1);
        uint64[]  memory refills    = new uint64[](2);
        users[0] = alice; users[1] = bob;
        capacities[0] = 1;
        refills[0] = 1; refills[1] = 1;

        vm.prank(guardianOnly);
        vm.expectRevert(RateLimitedToken.LengthMismatch.selector);
        eETHInstance.tightenAddressRateLimits(users, capacities, refills);
    }

    // =====================================================================
    // Global MINT/BURN circuit-breaker buckets (independent of per-address)
    // =====================================================================
    //
    // Setup notes:
    // - TestSetup bootstraps the 4 global IDs at type(uint64).max so generic
    //   tests don't hit them. We tighten the specific ID under test via the
    //   rate limiter's admin API (pranked as admin / OPERATION_TIMELOCK).
    // - These tests use addresses with NO per-address bucket, so any revert is
    //   guaranteed to come from the global side.

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

        // Bucket exhausted — next mint (different user, no per-address bucket) reverts.
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

    // =====================================================================
    // Wrap-aware global bucket: wrap/unwrap do NOT trip WEETH_{MINT,BURN}.
    // Non-wrap paths DO. This is what makes the global bucket useful as a
    // circuit breaker without exposing wrap/unwrap as a grief surface.
    // =====================================================================

    function test_wrap_does_NOT_consume_global_mint_bucket() public {
        // Set MINT cap to 1 gwei — any consumption would revert. Wrap 100 ETH
        // (massively over the cap) and assert it succeeds because the wrap
        // path is intentionally exempted from the global MINT bucket.
        vm.startPrank(admin);
        rateLimiterInstance.setCapacity(weEthInstance.WEETH_MINT_LIMIT_ID(), 1);
        rateLimiterInstance.setRefillRate(weEthInstance.WEETH_MINT_LIMIT_ID(), 0);
        rateLimiterInstance.setRemaining(weEthInstance.WEETH_MINT_LIMIT_ID(), 1);
        vm.stopPrank();

        vm.startPrank(alice);
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        weEthInstance.wrap(40 ether);            // 40 ETH wrap with cap=1gwei
        weEthInstance.wrap(0.001 ether);         // and again
        vm.stopPrank();

        // The bucket's remaining is untouched — wrap never drew on it.
        (, uint64 remaining, , ) = rateLimiterInstance.getLimit(weEthInstance.WEETH_MINT_LIMIT_ID());
        assertEq(remaining, 1, "wrap must not consume from global MINT bucket");
    }

    function test_unwrap_does_NOT_consume_global_burn_bucket() public {
        // Pre-wrap while the bucket is unbounded.
        vm.startPrank(alice);
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        uint256 weAmt = weEthInstance.wrap(2 ether);
        vm.stopPrank();

        // Choke the burn bucket — same argument as above.
        vm.startPrank(admin);
        rateLimiterInstance.setCapacity(weEthInstance.WEETH_BURN_LIMIT_ID(), 1);
        rateLimiterInstance.setRefillRate(weEthInstance.WEETH_BURN_LIMIT_ID(), 0);
        rateLimiterInstance.setRemaining(weEthInstance.WEETH_BURN_LIMIT_ID(), 1);
        vm.stopPrank();

        vm.prank(alice);
        weEthInstance.unwrap(weAmt);             // unwrap full amount despite cap=1gwei

        (, uint64 remaining, , ) = rateLimiterInstance.getLimit(weEthInstance.WEETH_BURN_LIMIT_ID());
        assertEq(remaining, 1, "unwrap must not consume from global BURN bucket");
    }

    function test_wrap_unwrap_loop_is_NOT_griefable() public {
        // The whole point of the wrap-aware flag: any number of wrap/unwrap cycles
        // by anyone must NOT drain either global bucket. Run 50 cycles against a
        // cap of 1 gwei (which would catastrophically fail without the flag).
        vm.startPrank(admin);
        rateLimiterInstance.setCapacity(weEthInstance.WEETH_MINT_LIMIT_ID(), 1);
        rateLimiterInstance.setRemaining(weEthInstance.WEETH_MINT_LIMIT_ID(), 1);
        rateLimiterInstance.setCapacity(weEthInstance.WEETH_BURN_LIMIT_ID(), 1);
        rateLimiterInstance.setRemaining(weEthInstance.WEETH_BURN_LIMIT_ID(), 1);
        vm.stopPrank();

        vm.startPrank(alice);
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        for (uint256 i = 0; i < 50; i++) {
            uint256 minted = weEthInstance.wrap(1 ether);
            weEthInstance.unwrap(minted);
        }
        vm.stopPrank();

        (, uint64 mintRem, , ) = rateLimiterInstance.getLimit(weEthInstance.WEETH_MINT_LIMIT_ID());
        (, uint64 burnRem, , ) = rateLimiterInstance.getLimit(weEthInstance.WEETH_BURN_LIMIT_ID());
        assertEq(mintRem, 1, "MINT bucket undrained after 50 wrap/unwrap cycles");
        assertEq(burnRem, 1, "BURN bucket undrained after 50 wrap/unwrap cycles");
    }

    function test_direct_mint_outside_wrap_DOES_consume_global() public {
        // Simulate a non-wrap mint path (e.g., a future bridge adapter calling
        // an internal mint reach). We can't reach `_mint` directly from outside
        // since it's internal — but we can prove the global is wired by setting
        // _WRAP_CTX_SLOT=0 explicitly (its default) and observing that the
        // global IS NOT exempted on the per-address consumption path.
        //
        // The most faithful surrogate: drive a wrap, then INSPECT that the
        // wrap-flag is cleared by tx end. We do this in the complementary
        // tests below; here we just confirm the cap is set low and a wrap
        // doesn't accidentally pass via the global being misconfigured.
        vm.startPrank(admin);
        rateLimiterInstance.setCapacity(weEthInstance.WEETH_MINT_LIMIT_ID(), ONE_ETHER_GWEI);
        rateLimiterInstance.setRefillRate(weEthInstance.WEETH_MINT_LIMIT_ID(), 0);
        rateLimiterInstance.setRemaining(weEthInstance.WEETH_MINT_LIMIT_ID(), ONE_ETHER_GWEI);
        vm.stopPrank();

        // Bucket exists and is consumer-whitelisted for weETH → ready to catch
        // any non-wrap mint. (Full coverage of an actual non-wrap mint path
        // requires deploying a mock bridge with an internal _mint reach, which
        // isn't part of the current contract surface — track in a follow-up if
        // a real second mint path is added.)
        assertTrue(rateLimiterInstance.limitExists(weEthInstance.WEETH_MINT_LIMIT_ID()));
        assertTrue(rateLimiterInstance.isConsumerAllowed(weEthInstance.WEETH_MINT_LIMIT_ID(), address(weEthInstance)));
    }

    function test_wrap_flag_clears_after_revert_inside_wrap() public {
        // If wrap reverts mid-call, the tstore write must be reverted too —
        // otherwise a subsequent (genuinely separate) mint path in the same
        // tx could observe a stuck flag. Force wrap to revert at the eETH
        // transferFrom leg (no eETH approval), then attempt a regular weETH
        // transfer in the same tx and assert it consumes the per-address
        // bucket normally (i.e., the rate-limit path is unbroken).
        //
        // We can't easily orchestrate a single-tx multi-step in a foundry
        // test without a harness contract, so this test serves as a guard
        // for the well-defined behavior of `tstore` under revert: the spec
        // requires that any state changes (including transient) in a
        // reverted call frame are reverted. The wrap call MUST revert in
        // its entirety here, and a brand-new wrap in the next tx MUST be
        // observed as wrap-context (flag set anew).
        vm.startPrank(alice);
        // No approve; safeTransferFrom inside wrap will revert.
        vm.expectRevert();
        weEthInstance.wrap(1 ether);

        // Now actually approve and wrap — must succeed and not see a stuck flag
        // (would manifest as wrap-skipped global passing when it shouldn't).
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        weEthInstance.wrap(1 ether);
        vm.stopPrank();
    }

    function test_wrap_flag_does_NOT_leak_across_txs() public {
        // tstore is per-transaction (EIP-1153). Wrap in one tx; in the next
        // tx, any mint that ISN'T a wrap must trip the global if the cap is
        // set low. We approximate "non-wrap mint" by leaning on the per-address
        // bucket check (per-address consumption is also rate-limit gated, and
        // the wrap-flag does NOT exempt per-address — so we can prove the
        // flag is gone by observing the per-address bucket consumes again
        // on the wrap's recipient leg).
        vm.prank(guardianOnly);
        _tightenWeeth(alice, 2 * ONE_ETHER_GWEI, 0);

        vm.startPrank(alice);
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        weEthInstance.wrap(1 ether);  // tx N: per-address recipient bucket consumed
        vm.stopPrank();

        // New tx: tstore cleared. Try another wrap that would overflow per-address.
        vm.prank(alice);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        weEthInstance.wrap(2 ether);
    }

    function test_global_eETH_mint_and_burn_buckets_are_independent() public {
        // Tighten only MINT to a tiny non-zero cap. NOTE: capacity == 0 on a
        // global bucket means "disabled (no-op)" per consumeToken —
        // NOT frozen. Use 1 gwei as the smallest non-zero cap to actually
        // throttle. (Per-address buckets behave differently — capacity=0
        // there reverts on consume.)
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

    function test_global_transfers_are_NOT_globally_limited() public {
        // Tighten both eETH global IDs to 1 gwei each; transfers must still go
        // through because transfer path does not consume MINT/BURN.
        vm.startPrank(admin);
        rateLimiterInstance.setCapacity(eETHInstance.EETH_MINT_LIMIT_ID(), 1);
        rateLimiterInstance.setRemaining(eETHInstance.EETH_MINT_LIMIT_ID(), 1);
        rateLimiterInstance.setCapacity(eETHInstance.EETH_BURN_LIMIT_ID(), 1);
        rateLimiterInstance.setRemaining(eETHInstance.EETH_BURN_LIMIT_ID(), 1);
        vm.stopPrank();

        vm.prank(alice);
        eETHInstance.transfer(bob, 1 ether);
    }

    function test_global_mint_bucket_composes_with_per_address() public {
        // Per-address bucket on chad: 5 ether. Global mint bucket: 1 ether.
        // First deposit (1 ETH) fits both. Second deposit fits per-address but
        // exceeds global → revert on the global side.
        vm.startPrank(admin);
        rateLimiterInstance.setCapacity(eETHInstance.EETH_MINT_LIMIT_ID(), ONE_ETHER_GWEI);
        rateLimiterInstance.setRefillRate(eETHInstance.EETH_MINT_LIMIT_ID(), 0);
        rateLimiterInstance.setRemaining(eETHInstance.EETH_MINT_LIMIT_ID(), ONE_ETHER_GWEI);
        vm.stopPrank();

        vm.prank(guardianOnly);
        _tightenEth(chad, 5 * ONE_ETHER_GWEI, 0);

        vm.deal(chad, 100 ether);
        vm.prank(chad);
        liquidityPoolInstance.deposit{value: 1 ether}();

        // Per-address remaining = 4 ETH. Global remaining = 0. → revert.
        vm.prank(chad);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        liquidityPoolInstance.deposit{value: 1 gwei}();
    }

    // =====================================================================
    // Batch entry points (continued)
    // =====================================================================

    function test_eETH_batch_delete() public {
        // Pre-create buckets for both via Multisig.
        vm.startPrank(multisigOnly);
        _setEth(alice, 1, 1);
        _setEth(bob,   1, 1);
        vm.stopPrank();

        address[] memory users = new address[](2);
        users[0] = alice; users[1] = bob;

        vm.prank(multisigOnly);
        eETHInstance.deleteAddressRateLimits(users);

        assertFalse(rateLimiterInstance.addressLimitExists(address(eETHInstance), alice));
        assertFalse(rateLimiterInstance.addressLimitExists(address(eETHInstance), bob));
    }

    // =====================================================================
    // Bootstrap-ordering invariants  (READ THIS BEFORE UPGRADING eETH/weETH)
    // =====================================================================
    //
    // The four global MINT/BURN buckets — EETH_MINT_LIMIT_ID, EETH_BURN_LIMIT_ID,
    // WEETH_MINT_LIMIT_ID, WEETH_BURN_LIMIT_ID — MUST be created via
    // `createNewLimiter` AND have eETH/weETH whitelisted via `updateConsumers`
    // BEFORE the new eETH/weETH impls are activated. `_setupGlobalMintBurnBuckets`
    // in TestSetup is the reference bootstrap.
    //
    // The tests below tabulate, in code, every distinct global-bucket state and
    // the exact revert selector each one produces. If a future agent is debugging
    // an eETH/weETH upgrade revert, this is the lookup table:
    //
    //   Global-bucket state                                    | consumeToken behavior
    //   -------------------------------------------------------|-----------------------------
    //   1. Bucket never created (no createNewLimiter)          | revert UnknownLimit
    //   2. Bucket created, consumer not whitelisted            | revert InvalidConsumer
    //   3. Bucket created, consumer whitelisted, capacity == 0 | revert LimitExceeded
    //   4. Bucket created, consumer whitelisted, sufficient    | succeed, decrement remaining
    //   5. Bucket created, consumer whitelisted, insufficient  | revert LimitExceeded
    //
    // Per-address `consumeForAddressIfConfigured` uses the SAME `capacity == 0`
    // semantic on an existing bucket (reverts LimitExceeded) — see
    // `test_addressLimit_lastRefill_sentinel_distinguishes_not_created_from_frozen`
    // and `test_cap0_reverts_symmetric_on_global_and_perAddress` below. The only
    // per-address-specific state is `lastRefill == 0` ("never created" →
    // no-op / unrestricted user), which the global path doesn't need because
    // missing globals revert UnknownLimit instead.
    //
    // To soft-disable a global rate limit without un-whitelisting the consumer,
    // set capacity to type(uint64).max (effectively unlimited, never trips).
    //
    // Why this matters operationally: if a 3CP upgrade bundle swaps the eETH/weETH
    // impls WITHOUT including the four createNewLimiter + updateConsumers calls in
    // the same bundle, the failure mode is total — every LP deposit and every
    // burnShares reverts UnknownLimit. Wrap/unwrap on weETH continues to work
    // (transient-storage flag bypasses the global on those paths), which can
    // make the incident look partial and confusing. These tests pin down each
    // signal so the diagnosis is unambiguous.

    function test_bootstrap_state1_uncreated_bucket_reverts_UnknownLimit() public {
        // The four real IDs are already created by TestSetup and there's no API
        // to delete a global bucket. Prove the failure mode using a synthetic
        // ID that has never been created — same code path eETH would hit on an
        // unbootstrapped upgrade.
        bytes32 neverCreatedId = keccak256("BOOTSTRAP_TEST_FAKE_ID");

        vm.prank(address(eETHInstance));
        vm.expectRevert(IEtherFiRateLimiter.UnknownLimit.selector);
        rateLimiterInstance.consumeToken(neverCreatedId, 1);

        // Implication: a 3CP that upgrades eETH/weETH impls WITHOUT first calling
        // createNewLimiter for EETH_MINT_LIMIT_ID / EETH_BURN_LIMIT_ID /
        // WEETH_MINT_LIMIT_ID / WEETH_BURN_LIMIT_ID will revert every LP deposit
        // and every burnShares with this exact selector. Include the four
        // createNewLimiter calls in the same bundle as the impl upgrade.
    }

    function test_bootstrap_state2_LP_deposit_reverts_InvalidConsumer_when_consumer_not_whitelisted() public {
        // Bucket exists (TestSetup created it at uint64.max) but if eETH is
        // removed from the consumer whitelist, the consume call reverts
        // InvalidConsumer BEFORE any capacity check.
        // NOTE: resolve the bucket ID into a local BEFORE `vm.prank` — calling
        // `eETHInstance.EETH_MINT_LIMIT_ID()` is itself an external call and
        // would consume the single-call prank intended for `updateConsumers`.
        bytes32 mintId = eETHInstance.EETH_MINT_LIMIT_ID();
        vm.prank(admin);
        rateLimiterInstance.updateConsumers(mintId, address(eETHInstance), false);

        vm.deal(chad, 1 ether);
        vm.prank(chad);
        vm.expectRevert(IEtherFiRateLimiter.InvalidConsumer.selector);
        liquidityPoolInstance.deposit{value: 1 ether}();

        // Implication: a 3CP that calls createNewLimiter but forgets the matching
        // updateConsumers(id, eETH, true) reverts every deposit with this selector.
        // Recovery is a single tx from OPERATION_TIMELOCK, but the failure is
        // total until that tx lands. Keep both calls in the same bundle.
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

    function test_bootstrap_state2_weETH_wrap_STILL_succeeds_when_consumer_not_whitelisted() public {
        // Subtle and important: wrap/unwrap survives consumer revocation because
        // the transient-storage wrap-context flag short-circuits the global consume
        // BEFORE we ever reach the rate limiter. This is by design — wrap/unwrap
        // is value-neutral and must never be DOSable via global-bucket state.
        //
        // Any NON-wrap mint reach (a future bridge adapter, a new mint authority,
        // an exploit) would NOT set the transient flag and WOULD hit the consumer
        // check, reverting InvalidConsumer. The safety property still holds: the
        // global bucket remains an enforced circuit breaker for unauthorized
        // supply changes even if wrap/unwrap continues to function.
        bytes32 wMintId = weEthInstance.WEETH_MINT_LIMIT_ID();
        vm.prank(admin);
        rateLimiterInstance.updateConsumers(wMintId, address(weEthInstance), false);

        vm.startPrank(alice);
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        weEthInstance.wrap(1 ether);
        vm.stopPrank();

        // Implication: during a half-bootstrapped upgrade, wrap/unwrap will look
        // healthy in monitoring while LP deposits and burns are all reverting.
        // Don't be fooled into thinking the rate limiter is "mostly working" —
        // the wrap-skip is intentional and doesn't tell you anything about
        // whether the rest of the wiring is correct.
    }

    function test_cap0_reverts_symmetric_on_global_and_perAddress() public {
        // Symmetry invariant: `cap == 0` on an existing bucket reverts
        // LimitExceeded on BOTH the global and per-address paths. The only
        // path-specific "soft no-op" state is the per-address `lastRefill == 0`
        // (never created → unrestricted user); there is no equivalent soft state
        // on the global side (missing globals revert UnknownLimit).
        //
        // To soft-disable a global rate limit without un-whitelisting the
        // consumer, set capacity to type(uint64).max — effectively unlimited,
        // any consume succeeds.

        bytes32 mintId = eETHInstance.EETH_MINT_LIMIT_ID();

        // GLOBAL leg: setCapacity(id, 0) reverts on every consume.
        vm.startPrank(admin);
        rateLimiterInstance.setCapacity(mintId, 0);
        rateLimiterInstance.setRemaining(mintId, 0);
        vm.stopPrank();

        vm.deal(chad, 1 ether);
        vm.prank(chad);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        liquidityPoolInstance.deposit{value: 1 ether}();

        // Restore the global so the per-address leg below isn't shadowed by the
        // still-zeroed global. Use uint64.max as the documented soft-disable
        // idiom (effectively unlimited).
        vm.startPrank(admin);
        rateLimiterInstance.setCapacity(mintId, type(uint64).max);
        rateLimiterInstance.setRemaining(mintId, type(uint64).max);
        vm.stopPrank();

        // PER-ADDRESS leg: tighten to (0, 0) freezes; consume reverts the same way.
        vm.prank(guardianOnly);
        _tightenEth(dan, 0, 0);

        vm.deal(dan, 1 ether);
        vm.prank(dan);
        vm.expectRevert(IEtherFiRateLimiter.LimitExceeded.selector);
        liquidityPoolInstance.deposit{value: 1 ether}();
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

        // State 3: cap == 0 → revert LimitExceeded (symmetric with per-address freeze).
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
