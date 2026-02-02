// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {LiquidRefer} from "src/helpers/LiquidRefer.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ILayerZeroTellerWithRateLimiting} from "src/liquid-interfaces/ILayerZeroTellerWithRateLimiting.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract LiquidReferWhitelistTest is Test {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant LIQUID_ETH_TELLER = 0x9AA79C84b79816ab920bBcE20f8f74557B514734;

    LiquidRefer internal liquidRefer;
    address internal owner;
    address internal user;
    address internal referrer;
    ILayerZeroTellerWithRateLimiting internal teller;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        owner = makeAddr("owner");
        user = makeAddr("user");
        referrer = makeAddr("referrer");
        teller = ILayerZeroTellerWithRateLimiting(LIQUID_ETH_TELLER);

        LiquidRefer implementation = new LiquidRefer();
        bytes memory initData = abi.encodeWithSelector(LiquidRefer.initialize.selector, owner);
        address proxy = address(new ERC1967Proxy(address(implementation), initData));
        liquidRefer = LiquidRefer(payable(proxy));
    }

    function test_RevertWhen_TellerNotWhitelisted() public {
        uint256 amount = 1 ether;
        deal(WETH, user, amount);

        vm.startPrank(user);
        IERC20(WETH).approve(address(liquidRefer), amount);

        vm.expectRevert("Teller not whitelisted");
        liquidRefer.deposit(teller, WETH, amount, 0, referrer);
        vm.stopPrank();
    }

    function test_RevertWhen_NonOwnerTogglesWhitelist() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        liquidRefer.toggleWhiteList(address(teller), true);
    }

    function test_OwnerCanAddToWhitelist() public {
        assertFalse(liquidRefer.tellerWhiteList(address(teller)));

        vm.prank(owner);
        liquidRefer.toggleWhiteList(address(teller), true);

        assertTrue(liquidRefer.tellerWhiteList(address(teller)));
    }

    function test_OwnerCanRemoveFromWhitelist() public {
        vm.prank(owner);
        liquidRefer.toggleWhiteList(address(teller), true);
        assertTrue(liquidRefer.tellerWhiteList(address(teller)));

        vm.prank(owner);
        liquidRefer.toggleWhiteList(address(teller), false);
        assertFalse(liquidRefer.tellerWhiteList(address(teller)));
    }

    function test_DepositSucceedsAfterWhitelisting() public {
        uint256 amount = 1 ether;
        deal(WETH, user, amount);

        vm.prank(owner);
        liquidRefer.toggleWhiteList(address(teller), true);

        vm.startPrank(user);
        IERC20(WETH).approve(address(liquidRefer), amount);
        uint256 shares = liquidRefer.deposit(teller, WETH, amount, 0, referrer);
        vm.stopPrank();

        assertGt(shares, 0, "Should receive shares");
    }

    function test_DepositFailsAfterRemovingFromWhitelist() public {
        uint256 amount = 1 ether;

        vm.prank(owner);
        liquidRefer.toggleWhiteList(address(teller), true);

        vm.prank(owner);
        liquidRefer.toggleWhiteList(address(teller), false);

        deal(WETH, user, amount);

        vm.startPrank(user);
        IERC20(WETH).approve(address(liquidRefer), amount);

        vm.expectRevert("Teller not whitelisted");
        liquidRefer.deposit(teller, WETH, amount, 0, referrer);
        vm.stopPrank();
    }

    // Pause tests

    function test_RevertWhen_NonOwnerPauses() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        liquidRefer.pause();
    }

    function test_RevertWhen_NonOwnerUnpauses() public {
        vm.prank(owner);
        liquidRefer.pause();

        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        liquidRefer.unpause();
    }

    function test_OwnerCanPause() public {
        assertFalse(liquidRefer.paused());

        vm.prank(owner);
        liquidRefer.pause();

        assertTrue(liquidRefer.paused());
    }

    function test_OwnerCanUnpause() public {
        vm.prank(owner);
        liquidRefer.pause();
        assertTrue(liquidRefer.paused());

        vm.prank(owner);
        liquidRefer.unpause();
        assertFalse(liquidRefer.paused());
    }

    function test_RevertWhen_DepositWhilePaused() public {
        uint256 amount = 1 ether;
        deal(WETH, user, amount);

        vm.prank(owner);
        liquidRefer.toggleWhiteList(address(teller), true);

        vm.prank(owner);
        liquidRefer.pause();

        vm.startPrank(user);
        IERC20(WETH).approve(address(liquidRefer), amount);

        vm.expectRevert("Pausable: paused");
        liquidRefer.deposit(teller, WETH, amount, 0, referrer);
        vm.stopPrank();
    }

    function test_DepositSucceedsAfterUnpause() public {
        uint256 amount = 1 ether;
        deal(WETH, user, amount);

        vm.prank(owner);
        liquidRefer.toggleWhiteList(address(teller), true);

        vm.prank(owner);
        liquidRefer.pause();

        vm.prank(owner);
        liquidRefer.unpause();

        vm.startPrank(user);
        IERC20(WETH).approve(address(liquidRefer), amount);
        uint256 shares = liquidRefer.deposit(teller, WETH, amount, 0, referrer);
        vm.stopPrank();

        assertGt(shares, 0, "Should receive shares");
    }
}
