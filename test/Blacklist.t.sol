// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/AuctionManager.sol";
import "../src/DepositAdapter.sol";
import "../src/EtherFiRedemptionManager.sol";
import "../src/LiquidityPool.sol";
import "../src/Liquifier.sol";
import "../src/MembershipManager.sol";
import "../src/WithdrawRequestNFT.sol";
import "../src/helpers/Blacklister.sol";
import "../src/interfaces/ILiquidityPool.sol";
import "../src/interfaces/ILiquifier.sol";
import "../src/interfaces/IeETH.sol";
import "../src/interfaces/IWeETH.sol";

contract BlacklistTest is TestSetup {
    address blacklisted;
    DepositAdapter depositAdapter;

    function setUp() public {
        setUpTests();
        _upgradeMembershipManagerFromV0ToV1();

        blacklisted = vm.addr(1337);

        // owner already holds BLACKLISTER_ROLE from TestSetup.
        vm.prank(owner);
        blacklisterInstance.blacklistUser(blacklisted);

        // Deploy a fresh DepositAdapter (not deployed by setUpTests).
        // The exact token wirings don't matter for blacklist checks since the
        // modifier runs before any state-changing logic.
        DepositAdapter impl = new DepositAdapter(
            address(liquidityPoolInstance),
            address(liquifierInstance),
            address(weEthInstance),
            address(eETHInstance),
            address(0),
            address(0),
            address(0),
            address(roleRegistryInstance),
            address(blacklisterInstance)
        );
        UUPSProxy proxy = new UUPSProxy(address(impl), "");
        depositAdapter = DepositAdapter(payable(address(proxy)));
        depositAdapter.initialize();
    }

    // Custom error `BlacklistedUser(address)` lives on Blacklister now — every
    // gate calls `blacklister.nonBlacklisted(user)`, so the revert bubbles up
    // verbatim from there.
    function _expectBlacklistedRevert(address user) internal {
        vm.expectRevert(abi.encodeWithSelector(Blacklister.BlacklistedUser.selector, user));
    }

    function test_blacklist_user_is_blacklisted() public {
        assertTrue(blacklisterInstance.blacklistedUntil(blacklisted) > block.timestamp);
    }

    function test_blacklist_unblacklist_clears_flag() public {
        vm.prank(owner);
        blacklisterInstance.unblacklistUser(blacklisted);
        assertFalse(blacklisterInstance.blacklistedUntil(blacklisted) > block.timestamp);
    }

    function test_blacklist_requires_role() public {
        address rando = vm.addr(0xBEEF);
        vm.prank(rando);
        vm.expectRevert(RoleRegistry.OnlyOperatingMultisig.selector);
        blacklisterInstance.blacklistUser(rando);
    }

    // -------------------------------------------------------------------------
    // AuctionManager
    // -------------------------------------------------------------------------

    function test_blacklist_AuctionManager_createBid_reverts() public {
        vm.deal(blacklisted, 1 ether);
        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        auctionInstance.createBid{value: 0.01 ether}(1, 0.01 ether);
    }

    function test_blacklist_AuctionManager_cancelBid_reverts() public {
        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        auctionInstance.cancelBid(1);
    }

    function test_blacklist_AuctionManager_cancelBidBatch_reverts() public {
        uint256[] memory bidIds = new uint256[](1);
        bidIds[0] = 1;
        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        auctionInstance.cancelBidBatch(bidIds);
    }

    // -------------------------------------------------------------------------
    // DepositAdapter
    // -------------------------------------------------------------------------

    function test_blacklist_DepositAdapter_depositETHForWeETH_reverts() public {
        vm.deal(blacklisted, 1 ether);
        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        depositAdapter.depositETHForWeETH{value: 1 ether}(address(0));
    }

    function test_blacklist_DepositAdapter_depositWETHForWeETH_reverts() public {
        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        depositAdapter.depositWETHForWeETH(1 ether, address(0));
    }

    function test_blacklist_DepositAdapter_depositStETHForWeETHWithPermit_reverts() public {
        ILiquifier.PermitInput memory permit;
        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        depositAdapter.depositStETHForWeETHWithPermit(1 ether, address(0), permit);
    }

    function test_blacklist_DepositAdapter_depositWstETHForWeETHWithPermit_reverts() public {
        ILiquifier.PermitInput memory permit;
        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        depositAdapter.depositWstETHForWeETHWithPermit(1 ether, address(0), permit);
    }

    // -------------------------------------------------------------------------
    // EtherFiRedemptionManager
    // -------------------------------------------------------------------------

    function test_blacklist_EtherFiRedemptionManager_redeemEEth_reverts() public {
        address ethAddress = etherFiRedemptionManagerInstance.ETH_ADDRESS();

        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        etherFiRedemptionManagerInstance.redeemEEth(1 ether, alice, ethAddress);

        vm.prank(alice);
        _expectBlacklistedRevert(blacklisted);
        etherFiRedemptionManagerInstance.redeemEEth(1 ether, blacklisted, ethAddress);
    }

    function test_blacklist_EtherFiRedemptionManager_redeemWeEth_reverts() public {
        address ethAddress = etherFiRedemptionManagerInstance.ETH_ADDRESS();

        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        etherFiRedemptionManagerInstance.redeemWeEth(1 ether, alice, ethAddress);

        vm.prank(alice);
        _expectBlacklistedRevert(blacklisted);
        etherFiRedemptionManagerInstance.redeemWeEth(1 ether, blacklisted, ethAddress);
    }

    function test_blacklist_EtherFiRedemptionManager_redeemEEthWithPermit_reverts() public {
        IeETH.PermitInput memory permit;
        address ethAddress = etherFiRedemptionManagerInstance.ETH_ADDRESS();

        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        etherFiRedemptionManagerInstance.redeemEEthWithPermit(1 ether, alice, permit, ethAddress);

        vm.prank(alice);
        _expectBlacklistedRevert(blacklisted);
        etherFiRedemptionManagerInstance.redeemEEthWithPermit(1 ether, blacklisted, permit, ethAddress);
    }

    function test_blacklist_EtherFiRedemptionManager_redeemWeEthWithPermit_reverts() public {
        IWeETH.PermitInput memory permit;
        address ethAddress = etherFiRedemptionManagerInstance.ETH_ADDRESS();

        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        etherFiRedemptionManagerInstance.redeemWeEthWithPermit(1 ether, alice, permit, ethAddress);

        vm.prank(alice);
        _expectBlacklistedRevert(blacklisted);
        etherFiRedemptionManagerInstance.redeemWeEthWithPermit(1 ether, blacklisted, permit, ethAddress);
    }

    // -------------------------------------------------------------------------
    // LiquidityPool
    // -------------------------------------------------------------------------

    function test_blacklist_LiquidityPool_deposit_reverts() public {
        vm.deal(blacklisted, 1 ether);
        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        liquidityPoolInstance.deposit{value: 1 ether}(address(0));
    }

    function test_blacklist_LiquidityPool_requestWithdraw_reverts() public {
        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        liquidityPoolInstance.requestWithdraw(alice, 1 ether);
    }

    function test_blacklist_LiquidityPool_requestWithdraw_reverts_blacklisted_recipient() public {
        vm.prank(alice);
        _expectBlacklistedRevert(blacklisted);
        liquidityPoolInstance.requestWithdraw(blacklisted, 1 ether);
    }

    function test_blacklist_LiquidityPool_requestWithdrawWithPermit_reverts() public {
        ILiquidityPool.PermitInput memory permit;
        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        liquidityPoolInstance.requestWithdrawWithPermit(alice, 1 ether, permit);
    }

    // -------------------------------------------------------------------------
    // Liquifier
    // -------------------------------------------------------------------------

    function test_blacklist_Liquifier_depositWithERC20_reverts() public {
        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        liquifierInstance.depositWithERC20(address(stEth), 1 ether, address(0));
    }

    function test_blacklist_Liquifier_depositWithERC20WithPermit_reverts() public {
        ILiquifier.PermitInput memory permit;
        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        liquifierInstance.depositWithERC20WithPermit(address(stEth), 1 ether, address(0), permit);
    }

    // -------------------------------------------------------------------------
    // MembershipManager (V1)
    // -------------------------------------------------------------------------

    function test_blacklist_MembershipManager_wrapEthForEap_reverts() public {
        vm.deal(blacklisted, 1 ether);
        bytes32[] memory proof;
        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        membershipManagerV1Instance.wrapEthForEap{value: 1 ether}(0.5 ether, 0.5 ether, 0, 1 ether, 1, proof);
    }

    function test_blacklist_MembershipManager_wrapEth_reverts() public {
        vm.deal(blacklisted, 1 ether);
        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        membershipManagerV1Instance.wrapEth{value: 1 ether}(0.5 ether, 0.5 ether, address(0));
    }

    function test_blacklist_MembershipManager_unwrapForEEthAndBurn_reverts() public {
        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        membershipManagerV1Instance.unwrapForEEthAndBurn(1);
    }

    function test_blacklist_MembershipManager_topUpDepositWithEth_reverts() public {
        vm.deal(blacklisted, 1 ether);
        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        membershipManagerV1Instance.topUpDepositWithEth{value: 1 ether}(1, 0.5 ether, 0.5 ether);
    }

    function test_blacklist_MembershipManager_requestWithdraw_reverts() public {
        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        membershipManagerV1Instance.requestWithdraw(1, 1 ether);
    }

    function test_blacklist_MembershipManager_requestWithdrawAndBurn_reverts() public {
        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        membershipManagerV1Instance.requestWithdrawAndBurn(1);
    }

    function test_blacklist_MembershipManager_claim_reverts() public {
        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        membershipManagerV1Instance.claim(1);
    }

    // -------------------------------------------------------------------------
    // WithdrawRequestNFT
    // -------------------------------------------------------------------------

    function test_blacklist_WithdrawRequestNFT_claimWithdraw_reverts() public {
        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        withdrawRequestNFTInstance.claimWithdraw(1);
    }

    function test_blacklist_WithdrawRequestNFT_batchClaimWithdraw_reverts() public {
        vm.prank(blacklisted);
        _expectBlacklistedRevert(blacklisted);
        withdrawRequestNFTInstance.batchClaimWithdraw(new uint256[](1));
    }

    // -------------------------------------------------------------------------
    // Non-blacklisted users still pass the blacklist gate (sanity check).
    // -------------------------------------------------------------------------

    function test_nonBlacklisted_passes_LiquidityPool_deposit() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        // Should not revert with BlacklistedUser; might succeed or revert for an
        // unrelated reason. Either is fine — we only assert the gate is open.
        try liquidityPoolInstance.deposit{value: 1 ether}(address(0)) returns (uint256) {
            // ok
        } catch (bytes memory reason) {
            assertTrue(
                keccak256(reason) != keccak256(abi.encodeWithSelector(Blacklister.BlacklistedUser.selector, alice)),
                "non-blacklisted user hit BlacklistedUser gate"
            );
        }
    }

    // -------------------------------------------------------------------------
    // Time-bounded blacklist (`blacklistUserUntil`)
    //
    // The Blacklister now stores an expiry timestamp instead of a boolean.
    // `nonBlacklisted` reverts iff `blacklistedUntil[user] > block.timestamp`,
    // so the gate must auto-open once the timestamp catches up.
    // -------------------------------------------------------------------------

    address internal tempBlacklisted = vm.addr(0xC0FFEE);

    function _grantBlacklistUntilRoleTo(address who) internal {
        // blacklistUserUntil() is now onlyGuardian; in the consolidated role
        // model that corresponds to GUARDIAN_ROLE on the registry.
        bytes32 role = roleRegistryInstance.GUARDIAN_ROLE();
        vm.prank(owner);
        roleRegistryInstance.grantRole(role, who);
    }

    function test_blacklistUserUntil_default_sets_one_day_window() public {
        _grantBlacklistUntilRoleTo(owner);

        uint256 t0 = block.timestamp;
        vm.prank(owner);
        blacklisterInstance.blacklistUserUntil(tempBlacklisted);

        assertEq(blacklisterInstance.blacklistedUntil(tempBlacklisted), t0 + 1 days);

        // Inside the window: gate closed.
        _expectBlacklistedRevert(tempBlacklisted);
        blacklisterInstance.nonBlacklisted(tempBlacklisted);

        // One second before expiry: still closed.
        vm.warp(t0 + 1 days - 1);
        _expectBlacklistedRevert(tempBlacklisted);
        blacklisterInstance.nonBlacklisted(tempBlacklisted);

        // At expiry (strict `>` check): gate opens.
        vm.warp(t0 + 1 days);
        blacklisterInstance.nonBlacklisted(tempBlacklisted);

        // After expiry: still open.
        vm.warp(t0 + 1 days + 1);
        blacklisterInstance.nonBlacklisted(tempBlacklisted);
    }

    function test_blacklistUserUntil_default_requires_BLACKLIST_UNTIL_ROLE() public {
        // `owner` only holds OPERATION_MULTISIG_ROLE (the consolidated admin role)
        // in setUp; the default-window overload now requires GUARDIAN_ROLE.
        vm.prank(owner);
        vm.expectRevert(RoleRegistry.OnlyGuardian.selector);
        blacklisterInstance.blacklistUserUntil(tempBlacklisted);
    }

    function test_blacklistUserUntil_default_emits_event() public {
        _grantBlacklistUntilRoleTo(owner);

        vm.expectEmit(false, false, false, true, address(blacklisterInstance));
        emit Blacklister.UserBlacklistedUntil(tempBlacklisted, block.timestamp + 1 days);

        vm.prank(owner);
        blacklisterInstance.blacklistUserUntil(tempBlacklisted);
    }

    function test_blacklistUserUntil_custom_duration_expires() public {
        uint256 duration = 7 days;
        uint256 t0 = block.timestamp;

        // The custom-duration overload requires BLACKLISTER_ROLE, which `owner`
        // already holds.
        vm.prank(owner);
        blacklisterInstance.setBlacklistUntil(tempBlacklisted, duration);

        assertEq(blacklisterInstance.blacklistedUntil(tempBlacklisted), t0 + duration);

        _expectBlacklistedRevert(tempBlacklisted);
        blacklisterInstance.nonBlacklisted(tempBlacklisted);

        vm.warp(t0 + duration);
        blacklisterInstance.nonBlacklisted(tempBlacklisted);
    }

    function test_blacklistUserUntil_custom_requires_BLACKLISTER_ROLE() public {
        address rando = vm.addr(0xB16B00B5);
        vm.prank(rando);
        vm.expectRevert(RoleRegistry.OnlyOperatingMultisig.selector);
        blacklisterInstance.setBlacklistUntil(tempBlacklisted, 1 days);
    }

    function test_blacklistUserUntil_zero_duration_is_immediately_open() public {
        // `blacklistedUntil = block.timestamp + 0` ⇒ `nonBlacklisted` passes
        // immediately because the check is strict `>`.
        vm.prank(owner);
        blacklisterInstance.setBlacklistUntil(tempBlacklisted, 0);

        assertEq(blacklisterInstance.blacklistedUntil(tempBlacklisted), block.timestamp);
        blacklisterInstance.nonBlacklisted(tempBlacklisted);
    }

    function test_blacklistUserUntil_extends_existing_blacklist() public {
        // Initial: indefinite blacklist via `blacklistUser` is overwritten by
        // a finite window if BLACKLISTER_ROLE caller chooses to.
        vm.prank(owner);
        blacklisterInstance.setBlacklistUntil(tempBlacklisted, 1 days);
        uint256 firstUntil = blacklisterInstance.blacklistedUntil(tempBlacklisted);

        vm.warp(block.timestamp + 12 hours);

        vm.prank(owner);
        blacklisterInstance.setBlacklistUntil(tempBlacklisted, 1 days);
        uint256 secondUntil = blacklisterInstance.blacklistedUntil(tempBlacklisted);

        assertGt(secondUntil, firstUntil, "second call should push expiry further out");
    }

    function test_blacklistUserUntil_can_reblacklist_after_expiry() public {
        vm.prank(owner);
        blacklisterInstance.setBlacklistUntil(tempBlacklisted, 1 days);

        vm.warp(block.timestamp + 1 days + 1);
        blacklisterInstance.nonBlacklisted(tempBlacklisted); // open

        vm.prank(owner);
        blacklisterInstance.setBlacklistUntil(tempBlacklisted, 2 days);

        _expectBlacklistedRevert(tempBlacklisted);
        blacklisterInstance.nonBlacklisted(tempBlacklisted);
    }

    function test_blacklistUser_indefinite_does_not_expire() public {
        // The original setUp blacklisted `blacklisted` indefinitely via
        // `blacklistUser` (sets expiry to type(uint256).max). It must not open
        // even after large jumps.
        vm.warp(block.timestamp + 365 days * 100);
        _expectBlacklistedRevert(blacklisted);
        blacklisterInstance.nonBlacklisted(blacklisted);
        assertEq(blacklisterInstance.blacklistedUntil(blacklisted), type(uint256).max);
    }

    function test_unblacklistUser_clears_timed_blacklist() public {
        vm.prank(owner);
        blacklisterInstance.setBlacklistUntil(tempBlacklisted, 30 days);

        _expectBlacklistedRevert(tempBlacklisted);
        blacklisterInstance.nonBlacklisted(tempBlacklisted);

        vm.prank(owner);
        blacklisterInstance.unblacklistUser(tempBlacklisted);

        assertEq(blacklisterInstance.blacklistedUntil(tempBlacklisted), 0);
        blacklisterInstance.nonBlacklisted(tempBlacklisted);
    }

    // Integration: a real gated contract must reflect the time-based open/close
    // transition end-to-end (not just the Blacklister view function).
    function test_blacklistUserUntil_LiquidityPool_gate_opens_after_expiry() public {
        address user = vm.addr(0xDA7A);

        vm.prank(owner);
        blacklisterInstance.setBlacklistUntil(user, 1 days);

        vm.deal(user, 2 ether);
        vm.prank(user);
        _expectBlacklistedRevert(user);
        liquidityPoolInstance.deposit{value: 1 ether}(address(0));

        vm.warp(block.timestamp + 1 days);

        // After expiry the BlacklistedUser revert must not be the one we hit.
        vm.prank(user);
        try liquidityPoolInstance.deposit{value: 1 ether}(address(0)) returns (uint256) {
            // ok
        } catch (bytes memory reason) {
            assertTrue(
                keccak256(reason) != keccak256(abi.encodeWithSelector(Blacklister.BlacklistedUser.selector, user)),
                "gate should have opened after expiry"
            );
        }
    }
}
