// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../test/TestSetup.sol";
import "../src/BucketRateLimiter.sol";

contract BucketRateLimiterRoleMigrationTest is TestSetup {
    BucketRateLimiter internal limiter;

    function setUp() public {
        setUpTests();
        // setUpTests does not call setUpLiquifier, so deploy a fresh instance.
        address impl = address(new BucketRateLimiter(address(roleRegistryInstance)));
        limiter = BucketRateLimiter(address(new UUPSProxy(impl, "")));
        limiter.initialize();
    }

    function _grantAdmin(address who) internal {
        vm.startPrank(owner);
        roleRegistryInstance.grantRole(limiter.BUCKET_RATE_LIMITER_ADMIN_ROLE(), who);
        vm.stopPrank();
    }

    function test_setCapacity_revertsWithoutRole() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(BucketRateLimiter.IncorrectRole.selector);
        limiter.setCapacity(1 ether);
    }

    function test_setCapacity_succeedsWithRole() public {
        address admin = address(0xA11CE);
        _grantAdmin(admin);

        vm.prank(admin);
        limiter.setCapacity(2 ether);

        (uint64 capacity,,,) = limiter.limit();
        assertEq(capacity, uint64(2 ether / 1e12));
    }

    function test_setRefillRate_revertsWithoutRole() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(BucketRateLimiter.IncorrectRole.selector);
        limiter.setRefillRatePerSecond(1 ether);
    }

    function test_pause_revertsWithoutPauserRole() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(BucketRateLimiter.IncorrectRole.selector);
        limiter.pauseContract();
    }

    function test_pause_succeedsWithPauserRole() public {
        address pauser = address(0xCAFE);
        vm.startPrank(owner);
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_PAUSER(), pauser);
        vm.stopPrank();

        vm.prank(pauser);
        limiter.pauseContract();
        assertTrue(limiter.paused());
    }

    function test_DEPRECATED_storageReadable() public view {
        assertEq(limiter.DEPRECATED_admins(address(0x1)), false);
        assertEq(limiter.DEPRECATED_pausers(address(0x1)), false);
    }

    function test_updateAdmin_selectorRemoved() public {
        (bool ok,) = address(limiter).call(
            abi.encodeWithSignature("updateAdmin(address,bool)", address(this), true)
        );
        assertFalse(ok);
    }

    function test_updatePauser_selectorRemoved() public {
        (bool ok,) = address(limiter).call(
            abi.encodeWithSignature("updatePauser(address,bool)", address(this), true)
        );
        assertFalse(ok);
    }
}
