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

        // Grant the blacklist role to the test address. Read the role and
        // owner *before* `vm.prank` so the prank isn't consumed by the view
        // call to `BLACKLISTED_USER()`.
        bytes32 role = roleRegistryInstance.BLACKLISTED_USER();
        address roleOwner = roleRegistryInstance.owner();
        vm.prank(roleOwner);
        roleRegistryInstance.grantRole(role, blacklisted);

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
            address(roleRegistryInstance)
        );
        UUPSProxy proxy = new UUPSProxy(address(impl), "");
        depositAdapter = DepositAdapter(payable(address(proxy)));
        depositAdapter.initialize();
    }

    function test_blacklist_role_is_granted() public {
        assertTrue(roleRegistryInstance.hasRole(roleRegistryInstance.BLACKLISTED_USER(), blacklisted));
    }

    // -------------------------------------------------------------------------
    // AuctionManager
    // -------------------------------------------------------------------------

    function test_blacklist_AuctionManager_createBid_reverts() public {
        vm.deal(blacklisted, 1 ether);
        vm.prank(blacklisted);
        vm.expectRevert(AuctionManager.BlacklistedUser.selector);
        auctionInstance.createBid{value: 0.01 ether}(1, 0.01 ether);
    }

    function test_blacklist_AuctionManager_cancelBid_reverts() public {
        vm.prank(blacklisted);
        vm.expectRevert(AuctionManager.BlacklistedUser.selector);
        auctionInstance.cancelBid(1);
    }

    function test_blacklist_AuctionManager_cancelBidBatch_reverts() public {
        uint256[] memory bidIds = new uint256[](1);
        bidIds[0] = 1;
        vm.prank(blacklisted);
        vm.expectRevert(AuctionManager.BlacklistedUser.selector);
        auctionInstance.cancelBidBatch(bidIds);
    }

    // -------------------------------------------------------------------------
    // DepositAdapter
    // -------------------------------------------------------------------------

    function test_blacklist_DepositAdapter_depositETHForWeETH_reverts() public {
        vm.deal(blacklisted, 1 ether);
        vm.prank(blacklisted);
        vm.expectRevert(DepositAdapter.BlacklistedUser.selector);
        depositAdapter.depositETHForWeETH{value: 1 ether}(address(0));
    }

    function test_blacklist_DepositAdapter_depositWETHForWeETH_reverts() public {
        vm.prank(blacklisted);
        vm.expectRevert(DepositAdapter.BlacklistedUser.selector);
        depositAdapter.depositWETHForWeETH(1 ether, address(0));
    }

    function test_blacklist_DepositAdapter_depositStETHForWeETHWithPermit_reverts() public {
        ILiquifier.PermitInput memory permit;
        vm.prank(blacklisted);
        vm.expectRevert(DepositAdapter.BlacklistedUser.selector);
        depositAdapter.depositStETHForWeETHWithPermit(1 ether, address(0), permit);
    }

    function test_blacklist_DepositAdapter_depositWstETHForWeETHWithPermit_reverts() public {
        ILiquifier.PermitInput memory permit;
        vm.prank(blacklisted);
        vm.expectRevert(DepositAdapter.BlacklistedUser.selector);
        depositAdapter.depositWstETHForWeETHWithPermit(1 ether, address(0), permit);
    }

    // -------------------------------------------------------------------------
    // EtherFiRedemptionManager
    // -------------------------------------------------------------------------

    function test_blacklist_EtherFiRedemptionManager_redeemEEth_reverts() public {
        address ethAddress = etherFiRedemptionManagerInstance.ETH_ADDRESS();
        vm.prank(blacklisted);
        vm.expectRevert(EtherFiRedemptionManager.BlacklistedUser.selector);
        etherFiRedemptionManagerInstance.redeemEEth(1 ether, blacklisted, ethAddress);
    }

    function test_blacklist_EtherFiRedemptionManager_redeemWeEth_reverts() public {
        address ethAddress = etherFiRedemptionManagerInstance.ETH_ADDRESS();
        vm.prank(blacklisted);
        vm.expectRevert(EtherFiRedemptionManager.BlacklistedUser.selector);
        etherFiRedemptionManagerInstance.redeemWeEth(1 ether, blacklisted, ethAddress);
    }

    function test_blacklist_EtherFiRedemptionManager_redeemEEthWithPermit_reverts() public {
        IeETH.PermitInput memory permit;
        address ethAddress = etherFiRedemptionManagerInstance.ETH_ADDRESS();
        vm.prank(blacklisted);
        vm.expectRevert(EtherFiRedemptionManager.BlacklistedUser.selector);
        etherFiRedemptionManagerInstance.redeemEEthWithPermit(1 ether, blacklisted, permit, ethAddress);
    }

    function test_blacklist_EtherFiRedemptionManager_redeemWeEthWithPermit_reverts() public {
        IWeETH.PermitInput memory permit;
        address ethAddress = etherFiRedemptionManagerInstance.ETH_ADDRESS();
        vm.prank(blacklisted);
        vm.expectRevert(EtherFiRedemptionManager.BlacklistedUser.selector);
        etherFiRedemptionManagerInstance.redeemWeEthWithPermit(1 ether, blacklisted, permit, ethAddress);
    }

    // -------------------------------------------------------------------------
    // LiquidityPool
    // -------------------------------------------------------------------------

    function test_blacklist_LiquidityPool_deposit_reverts() public {
        vm.deal(blacklisted, 1 ether);
        vm.prank(blacklisted);
        vm.expectRevert(LiquidityPool.BlacklistedUser.selector);
        liquidityPoolInstance.deposit{value: 1 ether}(address(0));
    }

    function test_blacklist_LiquidityPool_requestWithdraw_reverts() public {
        vm.prank(blacklisted);
        vm.expectRevert(LiquidityPool.BlacklistedUser.selector);
        liquidityPoolInstance.requestWithdraw(blacklisted, 1 ether);
    }

    function test_blacklist_LiquidityPool_requestWithdrawWithPermit_reverts() public {
        ILiquidityPool.PermitInput memory permit;
        vm.prank(blacklisted);
        vm.expectRevert(LiquidityPool.BlacklistedUser.selector);
        liquidityPoolInstance.requestWithdrawWithPermit(blacklisted, 1 ether, permit);
    }

    // -------------------------------------------------------------------------
    // Liquifier
    // -------------------------------------------------------------------------

    function test_blacklist_Liquifier_depositWithERC20_reverts() public {
        vm.prank(blacklisted);
        vm.expectRevert(Liquifier.BlacklistedUser.selector);
        liquifierInstance.depositWithERC20(address(stEth), 1 ether, address(0));
    }

    function test_blacklist_Liquifier_depositWithERC20WithPermit_reverts() public {
        ILiquifier.PermitInput memory permit;
        vm.prank(blacklisted);
        vm.expectRevert(Liquifier.BlacklistedUser.selector);
        liquifierInstance.depositWithERC20WithPermit(address(stEth), 1 ether, address(0), permit);
    }

    // -------------------------------------------------------------------------
    // MembershipManager (V1)
    // -------------------------------------------------------------------------

    function test_blacklist_MembershipManager_wrapEthForEap_reverts() public {
        vm.deal(blacklisted, 1 ether);
        bytes32[] memory proof;
        vm.prank(blacklisted);
        vm.expectRevert(MembershipManager.BlacklistedUser.selector);
        membershipManagerV1Instance.wrapEthForEap{value: 1 ether}(0.5 ether, 0.5 ether, 0, 1 ether, 1, proof);
    }

    function test_blacklist_MembershipManager_wrapEth_reverts() public {
        vm.deal(blacklisted, 1 ether);
        vm.prank(blacklisted);
        vm.expectRevert(MembershipManager.BlacklistedUser.selector);
        membershipManagerV1Instance.wrapEth{value: 1 ether}(0.5 ether, 0.5 ether, address(0));
    }

    function test_blacklist_MembershipManager_unwrapForEEthAndBurn_reverts() public {
        vm.prank(blacklisted);
        vm.expectRevert(MembershipManager.BlacklistedUser.selector);
        membershipManagerV1Instance.unwrapForEEthAndBurn(1);
    }

    function test_blacklist_MembershipManager_topUpDepositWithEth_reverts() public {
        vm.deal(blacklisted, 1 ether);
        vm.prank(blacklisted);
        vm.expectRevert(MembershipManager.BlacklistedUser.selector);
        membershipManagerV1Instance.topUpDepositWithEth{value: 1 ether}(1, 0.5 ether, 0.5 ether);
    }

    function test_blacklist_MembershipManager_requestWithdraw_reverts() public {
        vm.prank(blacklisted);
        vm.expectRevert(MembershipManager.BlacklistedUser.selector);
        membershipManagerV1Instance.requestWithdraw(1, 1 ether);
    }

    function test_blacklist_MembershipManager_requestWithdrawAndBurn_reverts() public {
        vm.prank(blacklisted);
        vm.expectRevert(MembershipManager.BlacklistedUser.selector);
        membershipManagerV1Instance.requestWithdrawAndBurn(1);
    }

    function test_blacklist_MembershipManager_claim_reverts() public {
        vm.prank(blacklisted);
        vm.expectRevert(MembershipManager.BlacklistedUser.selector);
        membershipManagerV1Instance.claim(1);
    }

    // -------------------------------------------------------------------------
    // WithdrawRequestNFT
    // -------------------------------------------------------------------------

    function test_blacklist_WithdrawRequestNFT_claimWithdraw_reverts() public {
        vm.prank(blacklisted);
        vm.expectRevert(WithdrawRequestNFT.BlacklistedUser.selector);
        withdrawRequestNFTInstance.claimWithdraw(1);
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
                keccak256(reason) != keccak256(abi.encodeWithSelector(LiquidityPool.BlacklistedUser.selector)),
                "non-blacklisted user hit BlacklistedUser gate"
            );
        }
    }
}
