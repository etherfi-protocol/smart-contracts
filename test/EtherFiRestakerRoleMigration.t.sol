// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../test/TestSetup.sol";
import "../src/EtherFiRestaker.sol";
import "../src/interfaces/IEtherFiRateLimiter.sol";
import "../src/eigenlayer-interfaces/IDelegationManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract EtherFiRestakerRoleMigrationTest is TestSetup {
    EtherFiRestaker internal restaker;

    function setUp() public {
        setUpTests();
        restaker = etherFiRestakerInstance;
    }

    function _grant(bytes32 role, address who) internal {
        vm.startPrank(roleRegistryInstance.owner());
        roleRegistryInstance.grantRole(role, who);
        vm.stopPrank();
    }

    function test_stEthRequestWithdrawal_revertsWithoutRole() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(EtherFiRestaker.IncorrectRole.selector);
        restaker.stEthRequestWithdrawal();
    }

    function test_stEthClaimWithdrawals_revertsWithoutRole() public {
        uint256[] memory ids;
        uint256[] memory hints;
        vm.prank(address(0xBEEF));
        vm.expectRevert(EtherFiRestaker.IncorrectRole.selector);
        restaker.stEthClaimWithdrawals(ids, hints);
    }

    function test_queueWithdrawals_revertsWithoutRole() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(EtherFiRestaker.IncorrectRole.selector);
        restaker.queueWithdrawals(address(0), 0);
    }

    function test_completeQueuedWithdrawals_revertsWithoutRole() public {
        IDelegationManager.Withdrawal[] memory ws;
        IERC20[][] memory tokens;
        vm.prank(address(0xBEEF));
        vm.expectRevert(EtherFiRestaker.IncorrectRole.selector);
        restaker.completeQueuedWithdrawals(ws, tokens);
    }

    function test_depositIntoStrategy_revertsWithoutRole() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(EtherFiRestaker.IncorrectRole.selector);
        restaker.depositIntoStrategy(address(0), 0);
    }

    function test_withdrawEther_revertsWithoutAdminRole() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(EtherFiRestaker.IncorrectRole.selector);
        restaker.withdrawEther();
    }

    function test_setRewardsClaimer_revertsWithoutAdminRole() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(EtherFiRestaker.IncorrectRole.selector);
        restaker.setRewardsClaimer(address(0xCAFE));
    }

    function test_pause_revertsWithoutPauserRole() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(EtherFiRestaker.IncorrectRole.selector);
        restaker.pauseContract();
    }

    function test_pause_succeedsWithPauserRole() public {
        address pauser = address(0xCAFE);
        _grant(roleRegistryInstance.PROTOCOL_PAUSER(), pauser);
        vm.prank(pauser);
        restaker.pauseContract();
        assertTrue(restaker.paused());
    }

    function test_DEPRECATED_admins_storageReadable() public view {
        assertEq(restaker.DEPRECATED_admins(address(0x1)), false);
        assertEq(restaker.DEPRECATED_pausers(address(0x1)), false);
    }

    function test_updateAdmin_selectorRemoved() public {
        (bool ok,) = address(restaker).call(
            abi.encodeWithSignature("updateAdmin(address,bool)", address(this), true)
        );
        assertFalse(ok);
    }

    function test_updatePauser_selectorRemoved() public {
        (bool ok,) = address(restaker).call(
            abi.encodeWithSignature("updatePauser(address,bool)", address(this), true)
        );
        assertFalse(ok);
    }
}
