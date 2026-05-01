// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/helpers/WeETHWithdrawAdapter.sol";
import "../src/interfaces/IWeETHWithdrawAdapter.sol";
import "../src/utils/PausableUntil.sol";

contract WeETHWithdrawAdapterTest is TestSetup {
    WeETHWithdrawAdapter public adapter;

    bytes32 constant PAUSABLE_UNTIL_SLOT =
        0x2c7e4bc092c2002f0baaf2f47367bc442b098266b43d189dafe4cb25f1e1fea2;

    address pauseUntilPauser = makeAddr("pauseUntilPauser");
    address unpauseUntilUnpauser = makeAddr("unpauseUntilUnpauser");

    function setUp() public {
        setUpTests();
        vm.prank(admin);
        withdrawRequestNFTInstance.unPauseContract();

        // Deploy the adapter standalone (TestSetup only wires it up in fork mode)
        WeETHWithdrawAdapter impl = new WeETHWithdrawAdapter(
            address(weEthInstance),
            address(eETHInstance),
            address(liquidityPoolInstance),
            address(withdrawRequestNFTInstance),
            address(roleRegistryInstance)
        );
        UUPSProxy proxy = new UUPSProxy(address(impl), "");
        adapter = WeETHWithdrawAdapter(address(proxy));
        adapter.initialize(owner);
    }

    function _grantPauseUntilRoles() internal {
        vm.startPrank(roleRegistryInstance.owner());
        roleRegistryInstance.grantRole(roleRegistryInstance.PAUSE_UNTIL_ROLE(), pauseUntilPauser);
        roleRegistryInstance.grantRole(roleRegistryInstance.UNPAUSE_UNTIL_ROLE(), unpauseUntilUnpauser);
        vm.stopPrank();
        if (block.timestamp < 1_700_000_000) vm.warp(1_700_000_000);
    }

    function _pausedUntil() internal view returns (uint256) {
        return uint256(vm.load(address(adapter), PAUSABLE_UNTIL_SLOT));
    }

    function _setupUserWithWeETH(address user, uint256 ethAmount, uint256 weEthAmount) internal {
        vm.deal(user, ethAmount);
        vm.startPrank(user);
        liquidityPoolInstance.deposit{value: ethAmount}();
        eETHInstance.approve(address(weEthInstance), ethAmount);
        weEthInstance.wrap(ethAmount);
        IERC20(address(weEthInstance)).approve(address(adapter), weEthAmount);
        vm.stopPrank();
    }

    function test_pauseContractUntil_requiresRole() public {
        _grantPauseUntilRoles();
        vm.prank(bob);
        vm.expectRevert(WeETHWithdrawAdapter.IncorrectRole.selector);
        adapter.pauseContractUntil();

        // PROTOCOL_PAUSER alone is insufficient
        vm.prank(admin);
        vm.expectRevert(WeETHWithdrawAdapter.IncorrectRole.selector);
        adapter.pauseContractUntil();
    }

    function test_pauseContractUntil_setsState() public {
        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        adapter.pauseContractUntil();
        assertEq(_pausedUntil(), block.timestamp + adapter.MAX_PAUSE_DURATION());
    }

    function test_unpauseContractUntil_requiresRole() public {
        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        adapter.pauseContractUntil();

        vm.prank(bob);
        vm.expectRevert(WeETHWithdrawAdapter.IncorrectRole.selector);
        adapter.unpauseContractUntil();

        vm.prank(admin);
        vm.expectRevert(WeETHWithdrawAdapter.IncorrectRole.selector);
        adapter.unpauseContractUntil();
    }

    function test_unpauseContractUntil_clearsState() public {
        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        adapter.pauseContractUntil();

        vm.prank(unpauseUntilUnpauser);
        adapter.unpauseContractUntil();
        assertEq(_pausedUntil(), 0);
    }

    function test_unpauseContractUntil_revertsIfNotPaused() public {
        _grantPauseUntilRoles();
        vm.prank(unpauseUntilUnpauser);
        vm.expectRevert(PausableUntil.ContractNotPausedUntil.selector);
        adapter.unpauseContractUntil();
    }

    // --- each gated function (whenNotPaused → blocked by pause-until too) ---

    function test_requestWithdraw_blockedByPauseContractUntil() public {
        _setupUserWithWeETH(bob, 1 ether, 1 ether);

        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        adapter.pauseContractUntil();

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, _pausedUntil())
        );
        adapter.requestWithdraw(0.5 ether, bob);
    }

    function test_requestWithdrawWithPermit_blockedByPauseContractUntil() public {
        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        adapter.pauseContractUntil();

        IWeETHWithdrawAdapter.PermitInput memory emptyPermit;
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, _pausedUntil())
        );
        adapter.requestWithdrawWithPermit(0.5 ether, bob, emptyPermit);
    }

    function test_requestWithdraw_unblockedAfterPauseExpires() public {
        _setupUserWithWeETH(bob, 1 ether, 1 ether);

        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        adapter.pauseContractUntil();

        vm.warp(block.timestamp + adapter.MAX_PAUSE_DURATION() + 1);

        vm.prank(bob);
        adapter.requestWithdraw(0.5 ether, bob);
    }

    function test_requestWithdraw_unblockedAfterExplicitUnpause() public {
        _setupUserWithWeETH(bob, 1 ether, 1 ether);

        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        adapter.pauseContractUntil();
        vm.prank(unpauseUntilUnpauser);
        adapter.unpauseContractUntil();

        vm.prank(bob);
        adapter.requestWithdraw(0.5 ether, bob);
    }
}
