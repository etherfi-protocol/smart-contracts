// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/interfaces/IEtherFiRateLimiter.sol";
import "../src/utils/RateLimitedToken.sol";

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
}
