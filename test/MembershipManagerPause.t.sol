// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/MembershipManager.sol";

/// Unit tests for the L-02 audit fix: paused users (per-user `pausedUntil` on EETH)
/// must not be able to bypass the pause by routing through MembershipManager.
contract MembershipManagerPauseTest is TestSetup {
    address pauserUntil;

    uint64 constant ONE_DAY = 1 days;

    function setUp() public {
        setUpTests();

        pauserUntil = vm.addr(0xA11CE2);
        vm.startPrank(owner);
        roleRegistryInstance.grantRole(eETHInstance.EETH_PAUSER_UNTIL_ROLE(), pauserUntil);
        vm.stopPrank();

        _upgradeMembershipManagerFromV0ToV1();

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _wrapForUser(address user, uint256 amount) internal returns (uint256) {
        vm.prank(user);
        return membershipManagerV1Instance.wrapEth{value: amount}(amount, 0);
    }

    function _pauseUser(address user) internal {
        vm.prank(pauserUntil);
        eETHInstance.pauseUntil(user);
    }

    // -------------------------------------------------------------------
    //                       wrapEth blocked when paused
    // -------------------------------------------------------------------

    function test_wrapEth_revertsWhenUserPaused() public {
        _pauseUser(alice);

        vm.prank(alice);
        vm.expectRevert(MembershipManager.UserPaused.selector);
        membershipManagerV1Instance.wrapEth{value: 1 ether}(1 ether, 0);
    }

    function test_wrapEth_succeedsWhenNotPaused() public {
        uint256 tokenId = _wrapForUser(alice, 1 ether);
        assertGt(tokenId, 0);
    }

    function test_wrapEth_succeedsAfterPauseExpires() public {
        _pauseUser(alice);
        skip(ONE_DAY + 1);

        // pause has expired; wrap should succeed
        uint256 tokenId = _wrapForUser(alice, 1 ether);
        assertGt(tokenId, 0);
    }

    // -------------------------------------------------------------------
    //                  requestWithdraw blocked when paused
    // -------------------------------------------------------------------

    function test_requestWithdraw_revertsWhenUserPaused() public {
        uint256 tokenId = _wrapForUser(alice, 2 ether);

        _pauseUser(alice);

        vm.prank(alice);
        vm.expectRevert(MembershipManager.UserPaused.selector);
        membershipManagerV1Instance.requestWithdraw(tokenId, 0.5 ether);
    }

    // -------------------------------------------------------------------
    //              requestWithdrawAndBurn blocked when paused
    // -------------------------------------------------------------------

    function test_requestWithdrawAndBurn_revertsWhenUserPaused() public {
        uint256 tokenId = _wrapForUser(alice, 2 ether);

        _pauseUser(alice);

        vm.prank(alice);
        vm.expectRevert(MembershipManager.UserPaused.selector);
        membershipManagerV1Instance.requestWithdrawAndBurn(tokenId);
    }

    // -------------------------------------------------------------------
    //          pause of one user does not affect other users
    // -------------------------------------------------------------------

    function test_pauseUntil_doesNotBlockOtherUsers() public {
        _pauseUser(alice);

        // bob is not paused, should be able to interact normally
        uint256 bobToken = _wrapForUser(bob, 1 ether);
        assertGt(bobToken, 0);
    }
}
