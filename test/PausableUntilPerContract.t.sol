// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./TestSetup.sol";
import "../src/utils/PausableUntil.sol";
import "../src/helpers/WeETHWithdrawAdapter.sol";

/// @notice Per-contract exercise of pauseContractUntil() / unpauseContractUntil()
///         on every contract that now inherits PausableUntil. Verifies role gating
///         and the namespaced-storage slot is actually written/cleared on each one.
contract PausableUntilPerContractTest is TestSetup {
    bytes32 constant PAUSABLE_UNTIL_SLOT =
        0x2c7e4bc092c2002f0baaf2f47367bc442b098266b43d189dafe4cb25f1e1fea2;

    address pauseUntilPauser = makeAddr("pauseUntilPauser");
    address unpauseUntilUnpauser = makeAddr("unpauseUntilUnpauser");
    address outsider = makeAddr("outsider");

    WeETHWithdrawAdapter localAdapter; // deployed standalone — TestSetup doesn't wire it in non-fork mode

    function setUp() public {
        setUpTests();

        vm.startPrank(owner);
        roleRegistryInstance.grantRole(roleRegistryInstance.PAUSE_UNTIL_ROLE(), pauseUntilPauser);
        roleRegistryInstance.grantRole(roleRegistryInstance.UNPAUSE_UNTIL_ROLE(), unpauseUntilUnpauser);
        vm.stopPrank();

        // Deploy WeETHWithdrawAdapter locally — setUpTests doesn't deploy it outside the fork path
        WeETHWithdrawAdapter adapterImpl = new WeETHWithdrawAdapter(
            address(weEthInstance),
            address(eETHInstance),
            address(liquidityPoolInstance),
            address(withdrawRequestNFTInstance),
            address(roleRegistryInstance)
        );
        UUPSProxy adapterProxy = new UUPSProxy(address(adapterImpl), "");
        localAdapter = WeETHWithdrawAdapter(address(adapterProxy));
        localAdapter.initialize(owner);

        // Warp past MAX_PAUSE_DURATION + PAUSER_UNTIL_COOLDOWN so the first-pause cooldown
        // (which treats lastPauseTimestamp[pauser] = 0 as "last paused at unix 0") is satisfied.
        // TestSetup usually already warps, but pin a known-good value to be safe.
        if (block.timestamp < 1_700_000_000) vm.warp(1_700_000_000);
    }

    // --------------------------------------------------------
    //  Shared assertions via vm.load — works for every contract
    //  because PausableUntil uses a fixed namespaced slot.
    // --------------------------------------------------------

    function _pausedUntilOf(address c) internal view returns (uint256) {
        return uint256(vm.load(c, PAUSABLE_UNTIL_SLOT));
    }

    function _assertPausedUntilSet(address c) internal view {
        assertGt(_pausedUntilOf(c), 0, "pausedUntil not set");
    }

    function _assertPausedUntilCleared(address c) internal view {
        assertEq(_pausedUntilOf(c), 0, "pausedUntil not cleared");
    }

    // --------------------------------------------------------
    //  LiquidityPool
    // --------------------------------------------------------

    function test_liquidityPool_pauseContractUntil_requiresRole() public {
        vm.prank(outsider);
        vm.expectRevert();
        liquidityPoolInstance.pauseContractUntil();
    }

    function test_liquidityPool_unpauseContractUntil_requiresRole() public {
        vm.prank(pauseUntilPauser);
        liquidityPoolInstance.pauseContractUntil();

        vm.prank(outsider);
        vm.expectRevert();
        liquidityPoolInstance.unpauseContractUntil();
    }

    function test_liquidityPool_pauseUnpauseFlow() public {
        vm.prank(pauseUntilPauser);
        liquidityPoolInstance.pauseContractUntil();
        _assertPausedUntilSet(address(liquidityPoolInstance));

        // gated entrypoint reverts
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        liquidityPoolInstance.deposit{value: 1 ether}(address(0));

        vm.prank(unpauseUntilUnpauser);
        liquidityPoolInstance.unpauseContractUntil();
        _assertPausedUntilCleared(address(liquidityPoolInstance));
    }

    // --------------------------------------------------------
    //  EtherFiRedemptionManager
    // --------------------------------------------------------

    function test_redemptionManager_pauseContractUntil_requiresRole() public {
        vm.prank(outsider);
        vm.expectRevert("EtherFiRedemptionManager: Unauthorized");
        etherFiRedemptionManagerInstance.pauseContractUntil();
    }

    function test_redemptionManager_unpauseContractUntil_requiresRole() public {
        vm.prank(pauseUntilPauser);
        etherFiRedemptionManagerInstance.pauseContractUntil();

        vm.prank(outsider);
        vm.expectRevert("EtherFiRedemptionManager: Unauthorized");
        etherFiRedemptionManagerInstance.unpauseContractUntil();
    }

    function test_redemptionManager_pauseUnpauseFlow() public {
        vm.prank(pauseUntilPauser);
        etherFiRedemptionManagerInstance.pauseContractUntil();
        _assertPausedUntilSet(address(etherFiRedemptionManagerInstance));

        vm.prank(unpauseUntilUnpauser);
        etherFiRedemptionManagerInstance.unpauseContractUntil();
        _assertPausedUntilCleared(address(etherFiRedemptionManagerInstance));
    }

    // --------------------------------------------------------
    //  WithdrawRequestNFT
    // --------------------------------------------------------

    function test_withdrawRequestNFT_pauseContractUntil_requiresRole() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSignature("IncorrectRole()"));
        withdrawRequestNFTInstance.pauseContractUntil();
    }

    function test_withdrawRequestNFT_unpauseContractUntil_requiresRole() public {
        vm.prank(pauseUntilPauser);
        withdrawRequestNFTInstance.pauseContractUntil();

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSignature("IncorrectRole()"));
        withdrawRequestNFTInstance.unpauseContractUntil();
    }

    function test_withdrawRequestNFT_pauseUnpauseFlow() public {
        vm.prank(pauseUntilPauser);
        withdrawRequestNFTInstance.pauseContractUntil();
        _assertPausedUntilSet(address(withdrawRequestNFTInstance));

        vm.prank(unpauseUntilUnpauser);
        withdrawRequestNFTInstance.unpauseContractUntil();
        _assertPausedUntilCleared(address(withdrawRequestNFTInstance));
    }

    // --------------------------------------------------------
    //  PriorityWithdrawalQueue
    // --------------------------------------------------------

    function test_priorityQueue_pauseContractUntil_requiresRole() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSignature("IncorrectRole()"));
        priorityQueueInstance.pauseContractUntil();
    }

    function test_priorityQueue_unpauseContractUntil_requiresRole() public {
        vm.prank(pauseUntilPauser);
        priorityQueueInstance.pauseContractUntil();

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSignature("IncorrectRole()"));
        priorityQueueInstance.unpauseContractUntil();
    }

    function test_priorityQueue_pauseUnpauseFlow() public {
        vm.prank(pauseUntilPauser);
        priorityQueueInstance.pauseContractUntil();
        _assertPausedUntilSet(address(priorityQueueInstance));

        vm.prank(unpauseUntilUnpauser);
        priorityQueueInstance.unpauseContractUntil();
        _assertPausedUntilCleared(address(priorityQueueInstance));
    }

    // --------------------------------------------------------
    //  EtherFiRateLimiter
    // --------------------------------------------------------

    function test_rateLimiter_pauseContractUntil_requiresRole() public {
        vm.prank(outsider);
        vm.expectRevert(IEtherFiRateLimiter.IncorrectRole.selector);
        rateLimiterInstance.pauseContractUntil();
    }

    function test_rateLimiter_unpauseContractUntil_requiresRole() public {
        vm.prank(pauseUntilPauser);
        rateLimiterInstance.pauseContractUntil();

        vm.prank(outsider);
        vm.expectRevert(IEtherFiRateLimiter.IncorrectRole.selector);
        rateLimiterInstance.unpauseContractUntil();
    }

    function test_rateLimiter_pauseUnpauseFlow() public {
        vm.prank(pauseUntilPauser);
        rateLimiterInstance.pauseContractUntil();
        _assertPausedUntilSet(address(rateLimiterInstance));

        vm.prank(unpauseUntilUnpauser);
        rateLimiterInstance.unpauseContractUntil();
        _assertPausedUntilCleared(address(rateLimiterInstance));
    }

    // --------------------------------------------------------
    //  EtherFiNodesManager
    // --------------------------------------------------------

    function test_nodesManager_pauseContractUntil_requiresRole() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSignature("IncorrectRole()"));
        managerInstance.pauseContractUntil();
    }

    function test_nodesManager_unpauseContractUntil_requiresRole() public {
        vm.prank(pauseUntilPauser);
        managerInstance.pauseContractUntil();

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSignature("IncorrectRole()"));
        managerInstance.unpauseContractUntil();
    }

    function test_nodesManager_pauseUnpauseFlow() public {
        vm.prank(pauseUntilPauser);
        managerInstance.pauseContractUntil();
        _assertPausedUntilSet(address(managerInstance));

        vm.prank(unpauseUntilUnpauser);
        managerInstance.unpauseContractUntil();
        _assertPausedUntilCleared(address(managerInstance));
    }

    // --------------------------------------------------------
    //  CumulativeMerkleRewardsDistributor
    // --------------------------------------------------------

    function test_cumulativeMerkle_pauseContractUntil_requiresRole() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSignature("IncorrectRole()"));
        cumulativeMerkleRewardsDistributorInstance.pauseContractUntil();
    }

    function test_cumulativeMerkle_unpauseContractUntil_requiresRole() public {
        vm.prank(pauseUntilPauser);
        cumulativeMerkleRewardsDistributorInstance.pauseContractUntil();

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSignature("IncorrectRole()"));
        cumulativeMerkleRewardsDistributorInstance.unpauseContractUntil();
    }

    function test_cumulativeMerkle_pauseUnpauseFlow() public {
        vm.prank(pauseUntilPauser);
        cumulativeMerkleRewardsDistributorInstance.pauseContractUntil();
        _assertPausedUntilSet(address(cumulativeMerkleRewardsDistributorInstance));

        vm.prank(unpauseUntilUnpauser);
        cumulativeMerkleRewardsDistributorInstance.unpauseContractUntil();
        _assertPausedUntilCleared(address(cumulativeMerkleRewardsDistributorInstance));
    }

    // --------------------------------------------------------
    //  WeETHWithdrawAdapter (locally deployed)
    // --------------------------------------------------------

    function test_weEthAdapter_pauseContractUntil_requiresRole() public {
        vm.prank(outsider);
        vm.expectRevert(WeETHWithdrawAdapter.IncorrectRole.selector);
        localAdapter.pauseContractUntil();
    }

    function test_weEthAdapter_unpauseContractUntil_requiresRole() public {
        vm.prank(pauseUntilPauser);
        localAdapter.pauseContractUntil();

        vm.prank(outsider);
        vm.expectRevert(WeETHWithdrawAdapter.IncorrectRole.selector);
        localAdapter.unpauseContractUntil();
    }

    function test_weEthAdapter_pauseUnpauseFlow() public {
        vm.prank(pauseUntilPauser);
        localAdapter.pauseContractUntil();
        _assertPausedUntilSet(address(localAdapter));

        vm.prank(unpauseUntilUnpauser);
        localAdapter.unpauseContractUntil();
        _assertPausedUntilCleared(address(localAdapter));
    }
}
