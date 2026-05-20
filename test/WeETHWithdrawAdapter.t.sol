// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/helpers/WeETHWithdrawAdapter.sol";
import "../src/helpers/Blacklister.sol";
import "../src/interfaces/IWeETHWithdrawAdapter.sol";
import "../src/utils/PausableUntil.sol";

contract WeETHWithdrawAdapterTest is TestSetup {
    WeETHWithdrawAdapter public adapter;

    bytes32 constant PAUSABLE_UNTIL_SLOT =
        0x2c7e4bc092c2002f0baaf2f47367bc442b098266b43d189dafe4cb25f1e1fea2;

    address pauseUntilPauser = makeAddr("pauseUntilPauser");
    address unpauseUntilUnpauser = makeAddr("unpauseUntilUnpauser");
    address pauseUntilDurationSetter = makeAddr("pauseUntilDurationSetter");

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
            address(roleRegistryInstance),
            address(blacklisterInstance)
        );
        UUPSProxy proxy = new UUPSProxy(address(impl), "");
        adapter = WeETHWithdrawAdapter(address(proxy));
        adapter.initialize(owner);
    }

    function _grantPauseUntilRoles() internal {
        vm.startPrank(roleRegistryInstance.owner());
        // pauseContractUntil → GUARDIAN_ROLE; unpause + setPauseUntilDuration → OPERATION_MULTISIG_ROLE
        roleRegistryInstance.grantRole(roleRegistryInstance.GUARDIAN_ROLE(), pauseUntilPauser);
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_MULTISIG_ROLE(), unpauseUntilUnpauser);
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_TIMELOCK_ROLE(), pauseUntilDurationSetter);
        vm.stopPrank();
        if (block.timestamp < 1_700_000_000) vm.warp(1_700_000_000);

        uint256 maxDur = adapter.MAX_PAUSE_DURATION();
        vm.prank(pauseUntilDurationSetter);
        adapter.setPauseUntilDuration(maxDur);
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
        vm.expectRevert(RoleRegistry.OnlyGuardian.selector);
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
        vm.expectRevert(RoleRegistry.OnlyOperatingMultisig.selector);
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

    // --- setPauseUntilDuration ---

    function test_setPauseUntilDuration_requiresRole() public {
        _grantPauseUntilRoles();
        uint256 maxDur = adapter.MAX_PAUSE_DURATION();

        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        adapter.setPauseUntilDuration(maxDur);

        // Guardian-only role (pauseUntilPauser) cannot set the duration; needs admin role.
        vm.prank(pauseUntilPauser);
        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        adapter.setPauseUntilDuration(maxDur);
    }

    function test_setPauseUntilDuration_setsValue() public {
        _grantPauseUntilRoles();
        uint256 d = adapter.MIN_PAUSE_DURATION() + 1 hours;

        vm.prank(pauseUntilDurationSetter);
        adapter.setPauseUntilDuration(d);

        vm.prank(pauseUntilPauser);
        adapter.pauseContractUntil();
        assertEq(_pausedUntil(), block.timestamp + d);
    }

    function test_setPauseUntilDuration_revertsOnInvalidValue() public {
        _grantPauseUntilRoles();
        uint256 belowMin = adapter.MIN_PAUSE_DURATION() - 1;
        uint256 aboveMax = adapter.MAX_PAUSE_DURATION() + 1;

        vm.prank(pauseUntilDurationSetter);
        vm.expectRevert(PausableUntil.InvalidPauseUntilDuration.selector);
        adapter.setPauseUntilDuration(belowMin);

        vm.prank(pauseUntilDurationSetter);
        vm.expectRevert(PausableUntil.InvalidPauseUntilDuration.selector);
        adapter.setPauseUntilDuration(aboveMax);
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

    // -------------------------------------------------------------------------
    // Blacklist gate on requestWithdraw / requestWithdrawWithPermit
    //
    // `requestWithdraw` carries the `nonBlacklisted` modifier directly;
    // `requestWithdrawWithPermit` inherits the gate transitively because it
    // forwards into `requestWithdraw`. Both call paths must observe the same
    // open/close transitions.
    // -------------------------------------------------------------------------

    function _expectBlacklistedRevert(address user) internal {
        vm.expectRevert(abi.encodeWithSelector(Blacklister.BlacklistedUser.selector, user));
    }

    function test_requestWithdraw_blockedByBlacklist() public {
        _setupUserWithWeETH(bob, 1 ether, 1 ether);

        vm.prank(owner);
        blacklisterInstance.blacklistUser(bob);

        vm.prank(bob);
        _expectBlacklistedRevert(bob);
        adapter.requestWithdraw(0.5 ether, bob);
    }

    function test_requestWithdrawWithPermit_blockedByBlacklist() public {
        // Permit path doesn't carry the modifier itself — it inherits the gate
        // by forwarding into `requestWithdraw`. Explicit test guards against a
        // future refactor that breaks that forwarding.
        _setupUserWithWeETH(bob, 1 ether, 1 ether);

        vm.prank(owner);
        blacklisterInstance.blacklistUser(bob);

        IWeETHWithdrawAdapter.PermitInput memory emptyPermit;
        vm.prank(bob);
        _expectBlacklistedRevert(bob);
        adapter.requestWithdrawWithPermit(0.5 ether, bob, emptyPermit);
    }

    function test_requestWithdraw_unblockedAfterBlacklistExpires() public {
        _setupUserWithWeETH(bob, 1 ether, 1 ether);

        vm.prank(owner);
        blacklisterInstance.setBlacklistUntil(bob, 1 days);

        // Inside the window: blocked.
        vm.prank(bob);
        _expectBlacklistedRevert(bob);
        adapter.requestWithdraw(0.5 ether, bob);

        // At expiry (strict `>` check in Blacklister): gate opens and the
        // withdrawal goes through end-to-end.
        vm.warp(block.timestamp + 1 days);

        vm.prank(bob);
        adapter.requestWithdraw(0.5 ether, bob);
    }

    function test_requestWithdraw_unblockedAfterExplicitUnblacklist() public {
        _setupUserWithWeETH(bob, 1 ether, 1 ether);

        vm.prank(owner);
        blacklisterInstance.blacklistUser(bob);

        vm.prank(bob);
        _expectBlacklistedRevert(bob);
        adapter.requestWithdraw(0.5 ether, bob);

        vm.prank(owner);
        blacklisterInstance.unblacklistUser(bob);

        vm.prank(bob);
        adapter.requestWithdraw(0.5 ether, bob);
    }

    function test_requestWithdraw_pauseAndBlacklistInteract() public {
        // Both gates active: pause check runs first (modifier order on
        // requestWithdraw is `whenNotPaused`, then `nonBlacklisted`), so the
        // pause revert is what surfaces.
        _setupUserWithWeETH(bob, 1 ether, 1 ether);

        _grantPauseUntilRoles();
        vm.prank(pauseUntilPauser);
        adapter.pauseContractUntil();

        vm.prank(owner);
        blacklisterInstance.blacklistUser(bob);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, _pausedUntil())
        );
        adapter.requestWithdraw(0.5 ether, bob);

        // After unpause, the blacklist gate takes over.
        vm.prank(unpauseUntilUnpauser);
        adapter.unpauseContractUntil();

        vm.prank(bob);
        _expectBlacklistedRevert(bob);
        adapter.requestWithdraw(0.5 ether, bob);
    }

    function test_constructor_revertsOnZeroBlacklister() public {
        vm.expectRevert(WeETHWithdrawAdapter.ZeroAddress.selector);
        new WeETHWithdrawAdapter(
            address(weEthInstance),
            address(eETHInstance),
            address(liquidityPoolInstance),
            address(withdrawRequestNFTInstance),
            address(roleRegistryInstance),
            address(0)
        );
    }
}
