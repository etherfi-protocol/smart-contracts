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
        assertTrue(blacklisterInstance.isBlacklisted(blacklisted));
    }

    function test_blacklist_unblacklist_clears_flag() public {
        vm.prank(owner);
        blacklisterInstance.unblacklistUser(blacklisted);
        assertFalse(blacklisterInstance.isBlacklisted(blacklisted));
    }

    function test_blacklist_requires_role() public {
        address rando = vm.addr(0xBEEF);
        vm.prank(rando);
        vm.expectRevert(Blacklister.IncorrectRole.selector);
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
}
