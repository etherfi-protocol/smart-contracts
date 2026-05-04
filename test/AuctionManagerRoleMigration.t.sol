// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../test/TestSetup.sol";
import "../src/AuctionManager.sol";

contract AuctionManagerRoleMigrationTest is TestSetup {
    function setUp() public {
        setUpTests();
    }

    function _grantAdmin(address who) internal {
        vm.startPrank(owner);
        roleRegistryInstance.grantRole(auctionInstance.AUCTION_MANAGER_ADMIN_ROLE(), who);
        vm.stopPrank();
    }

    function test_disableWhitelist_revertsWithoutRole() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(AuctionManager.IncorrectRole.selector);
        auctionInstance.disableWhitelist();
    }

    function test_disableWhitelist_succeedsWithRole() public {
        address admin = address(0xA11CE);
        _grantAdmin(admin);
        vm.prank(admin);
        auctionInstance.disableWhitelist();
        assertFalse(auctionInstance.whitelistEnabled());
    }

    function test_pause_revertsWithoutPauserRole() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(AuctionManager.IncorrectRole.selector);
        auctionInstance.pauseContract();
    }

    function test_pause_succeedsWithPauserRole() public {
        address pauser = address(0xCAFE);
        vm.startPrank(owner);
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_PAUSER(), pauser);
        vm.stopPrank();
        vm.prank(pauser);
        auctionInstance.pauseContract();
        assertTrue(auctionInstance.paused());
    }

    function test_setMinBidPrice_revertsWithoutRole() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(AuctionManager.IncorrectRole.selector);
        auctionInstance.setMinBidPrice(0.05 ether);
    }

    function test_DEPRECATED_admins_storageReadable() public view {
        bool v = auctionInstance.DEPRECATED_admins(address(0x1));
        assertEq(v, false);
    }

    function test_updateAdmin_selectorRemoved() public {
        (bool ok,) = address(auctionInstance).call(
            abi.encodeWithSignature("updateAdmin(address,bool)", address(this), true)
        );
        assertFalse(ok);
    }
}
