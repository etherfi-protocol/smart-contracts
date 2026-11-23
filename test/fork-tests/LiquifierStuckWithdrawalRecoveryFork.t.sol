// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDelegationManager} from "@etherfi/interfaces/eigenlayer-interfaces/IDelegationManager.sol";
import {IStrategy} from "@etherfi/interfaces/eigenlayer-interfaces/IStrategy.sol";
import {ILiquifier} from "@etherfi/deposits/interfaces/ILiquifier.sol";
import {Liquifier} from "@etherfi/deposits/Liquifier.sol";
import {LiquifierStuckWithdrawalRecovery} from "@etherfi/deposits/LiquifierStuckWithdrawalRecovery.sol";
import {RolesLibrary} from "@etherfi/governance/utils/RolesLibrary.sol";
import {Deployed} from "@scripts/deploys/Deployed.s.sol";
import {StuckWithdrawals} from "@scripts/upgrades/liquifier-stuck-withdrawal-recovery/StuckWithdrawals.sol";

interface IDelegationManagerPending {
    function pendingWithdrawals(bytes32 withdrawalRoot) external view returns (bool);
}

/// @notice Mainnet-fork test for STAKE-2461: upgrade the Liquifier to a recovery implementation,
///         complete the 32 stuck user withdrawals, and upgrade back, in one upgrade-timelock batch.
/// Requires MAINNET_RPC_URL. Forks the latest block.
contract LiquifierStuckWithdrawalRecoveryForkTest is Test, Deployed {
    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    IDelegationManager constant DM = IDelegationManager(0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A);
    IDelegationManagerPending constant DM_PENDING = IDelegationManagerPending(0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A);

    Liquifier liquifier = Liquifier(payable(LIQUIFIER));
    TimelockController timelock = TimelockController(payable(UPGRADE_TIMELOCK));
    address originalImpl;
    LiquifierStuckWithdrawalRecovery recoveryImpl;
    IDelegationManager.Withdrawal[] withdrawals;
    bytes32[] roots;
    IERC20[][] tokens;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        originalImpl = _implementation();
        recoveryImpl = _deployRecoveryImpl();

        (IDelegationManager.Withdrawal[] memory w, bytes32[] memory r) = StuckWithdrawals.all();
        for (uint256 i = 0; i < w.length; i++) {
            withdrawals.push(w[i]);
            roots.push(r[i]);
            IERC20[] memory t = new IERC20[](1);
            t[0] = w[i].strategies[0].underlyingToken();
            tokens.push(t);
        }
    }

    function test_fixture_matchesLiveRoots() public view {
        assertEq(withdrawals.length, StuckWithdrawals.COUNT);
        for (uint256 i = 0; i < withdrawals.length; i++) {
            assertEq(DM.calculateWithdrawalRoot(withdrawals[i]), roots[i], "fixture struct hashes to recorded root");
            assertTrue(DM_PENDING.pendingWithdrawals(roots[i]), "root still pending");
        }
    }

    /// Standalone batch: recover, then return the proxy to the live implementation.
    function test_recoveryBatch_paysStakersAndRestoresImplementation() public {
        _runRecoveryBatch(originalImpl);
    }

    /// Combined batch: recover, then move the proxy to a new Liquifier implementation built from
    /// this branch, as the recovery would run inside the current upgrade set.
    function test_recoveryBatch_thenUpgradesToNewLiquifier() public {
        (ILiquifier.ConstructorAddresses memory a, uint256 d, uint256 w, uint256 m, uint256 t) = _liveConstructorArgs();
        _runRecoveryBatch(address(new Liquifier(a, d, w, m, t)));
    }

    function _runRecoveryBatch(address finalImpl) internal {
        uint256 n = withdrawals.length;
        uint256[] memory expected = new uint256[](n);
        uint256[] memory before = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            expected[i] = withdrawals[i].strategies[0].sharesToUnderlyingView(withdrawals[i].scaledShares[0]);
            before[i] = tokens[i][0].balanceOf(withdrawals[i].staker);
        }
        Snapshot memory pre = _snapshot();

        _scheduleAndExecute(_batchCalldata(finalImpl));

        assertEq(_implementation(), finalImpl, "proxy ends on the intended implementation");
        for (uint256 i = 0; i < n; i++) {
            assertFalse(DM_PENDING.pendingWithdrawals(roots[i]), "root completed");
        }
        // Stakers repeat (one holds 3 roots), so check the summed payout per staker.
        for (uint256 i = 0; i < n; i++) {
            address staker = withdrawals[i].staker;
            IERC20 token = tokens[i][0];
            uint256 expectedForStaker;
            uint256 firstIndex = n;
            for (uint256 j = 0; j < n; j++) {
                if (withdrawals[j].staker == staker && tokens[j][0] == token) {
                    expectedForStaker += expected[j];
                    if (firstIndex == n) firstIndex = j;
                }
            }
            if (firstIndex != i) continue;
            // stETH share math can round down by a few wei per transfer.
            assertApproxEqAbs(token.balanceOf(staker) - before[i], expectedForStaker, 4, "staker received underlying");
        }
        _assertUnchanged(pre, _snapshot());
    }

    function test_recover_revertsForNonTimelockCaller() public {
        vm.prank(UPGRADE_TIMELOCK);
        liquifier.upgradeTo(address(recoveryImpl));

        vm.expectRevert();
        LiquifierStuckWithdrawalRecovery(payable(LIQUIFIER)).recoverStuckWithdrawals(withdrawals, tokens);

        vm.prank(ETHERFI_UPGRADE_ADMIN);
        vm.expectRevert();
        LiquifierStuckWithdrawalRecovery(payable(LIQUIFIER)).recoverStuckWithdrawals(withdrawals, tokens);
    }

    function test_recover_revertsForLiquifierOwnedWithdrawal() public {
        vm.prank(UPGRADE_TIMELOCK);
        liquifier.upgradeTo(address(recoveryImpl));

        IDelegationManager.Withdrawal[] memory w = new IDelegationManager.Withdrawal[](1);
        w[0] = withdrawals[0];
        w[0].staker = LIQUIFIER;
        IERC20[][] memory t = new IERC20[][](1);
        t[0] = tokens[0];

        vm.prank(UPGRADE_TIMELOCK);
        vm.expectRevert(LiquifierStuckWithdrawalRecovery.LiquifierOwnedWithdrawal.selector);
        LiquifierStuckWithdrawalRecovery(payable(LIQUIFIER)).recoverStuckWithdrawals(w, t);
    }

    function test_recover_revertsOnLengthMismatch() public {
        vm.prank(UPGRADE_TIMELOCK);
        liquifier.upgradeTo(address(recoveryImpl));

        IERC20[][] memory t = new IERC20[][](1);
        t[0] = tokens[0];

        vm.prank(UPGRADE_TIMELOCK);
        vm.expectRevert(LiquifierStuckWithdrawalRecovery.LengthMismatch.selector);
        LiquifierStuckWithdrawalRecovery(payable(LIQUIFIER)).recoverStuckWithdrawals(withdrawals, t);
    }

    function test_recoveryImpl_keepsLiveImmutables() public view {
        Liquifier live = Liquifier(payable(originalImpl));
        assertEq(address(recoveryImpl.liquidityPool()), address(live.liquidityPool()));
        assertEq(address(recoveryImpl.lido()), address(live.lido()));
        assertEq(address(recoveryImpl.blacklister()), address(live.blacklister()));
        assertEq(recoveryImpl.etherfiRestaker(), live.etherfiRestaker());
        assertEq(recoveryImpl.l1SyncPool(), live.l1SyncPool());
        assertEq(recoveryImpl.maxPriceThreshold(), live.maxPriceThreshold());
        assertEq(address(RolesLibrary(address(recoveryImpl)).roleRegistry()), ROLE_REGISTRY);
    }

    // ─────────────────────────────────────────────────────────────────────

    struct Snapshot {
        uint256 stEthBalance;
        uint256 cbEthBalance;
        uint256 ethBalance;
        uint256 totalPooledEther;
        uint32 refreshInterval;
        bool quoteStEthWithCurve;
        bool paused;
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        s.stEthBalance = IERC20(address(liquifier.lido())).balanceOf(LIQUIFIER);
        s.cbEthBalance = IERC20(0xBe9895146f7AF43049ca1c1AE358B0541Ea49704).balanceOf(LIQUIFIER);
        s.ethBalance = LIQUIFIER.balance;
        s.totalPooledEther = liquifier.getTotalPooledEther();
        s.refreshInterval = liquifier.timeBoundCapRefreshInterval();
        s.quoteStEthWithCurve = liquifier.quoteStEthWithCurve();
        s.paused = liquifier.paused();
    }

    function _assertUnchanged(Snapshot memory a, Snapshot memory b) internal pure {
        assertEq(b.stEthBalance, a.stEthBalance, "Liquifier stETH unchanged");
        assertEq(b.cbEthBalance, a.cbEthBalance, "Liquifier cbETH unchanged");
        assertEq(b.ethBalance, a.ethBalance, "Liquifier ETH unchanged");
        assertEq(b.totalPooledEther, a.totalPooledEther, "totalPooledEther unchanged");
        assertEq(b.refreshInterval, a.refreshInterval, "refresh interval unchanged");
        assertEq(b.quoteStEthWithCurve, a.quoteStEthWithCurve, "quote flag unchanged");
        assertEq(b.paused, a.paused, "pause state unchanged");
    }

    function _batchCalldata(address finalImpl) internal view returns (bytes[] memory data) {
        data = new bytes[](2);
        data[0] = abi.encodeWithSignature(
            "upgradeToAndCall(address,bytes)",
            address(recoveryImpl),
            abi.encodeCall(LiquifierStuckWithdrawalRecovery.recoverStuckWithdrawals, (withdrawals, tokens))
        );
        data[1] = abi.encodeWithSignature("upgradeTo(address)", finalImpl);
    }

    function _scheduleAndExecute(bytes[] memory data) internal {
        address[] memory targets = new address[](2);
        targets[0] = LIQUIFIER;
        targets[1] = LIQUIFIER;
        uint256[] memory values = new uint256[](2);
        bytes32 salt = keccak256("STAKE-2461 liquifier stuck withdrawal recovery");
        uint256 delay = timelock.getMinDelay();

        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), ETHERFI_UPGRADE_ADMIN), "upgrade admin can propose");
        vm.prank(ETHERFI_UPGRADE_ADMIN);
        timelock.scheduleBatch(targets, values, data, bytes32(0), salt, delay);

        vm.warp(block.timestamp + delay + 1);

        address executor = timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)) ? address(this) : ETHERFI_UPGRADE_ADMIN;
        vm.prank(executor);
        timelock.executeBatch(targets, values, data, bytes32(0), salt);
    }

    function _implementation() internal view returns (address) {
        return address(uint160(uint256(vm.load(LIQUIFIER, IMPLEMENTATION_SLOT))));
    }

    function _deployRecoveryImpl() internal returns (LiquifierStuckWithdrawalRecovery) {
        (ILiquifier.ConstructorAddresses memory a, uint256 d, uint256 w, uint256 m, uint256 t) = _liveConstructorArgs();
        return new LiquifierStuckWithdrawalRecovery(a, d, w, m, t);
    }

    /// Constructor arguments read from the live implementation's immutables.
    function _liveConstructorArgs()
        internal
        view
        returns (ILiquifier.ConstructorAddresses memory addrs, uint256, uint256, uint256, uint256)
    {
        Liquifier live = Liquifier(payable(originalImpl));
        addrs = ILiquifier.ConstructorAddresses({
            liquidityPool: address(live.liquidityPool()),
            lidoWithdrawalQueue: address(live.lidoWithdrawalQueue()),
            lido: address(live.lido()),
            stEth_Eth_Pool: address(live.stEth_Eth_Pool()),
            roleRegistry: ROLE_REGISTRY,
            stEthPriceFeed: address(live.stEthPriceFeed()),
            blacklister: address(live.blacklister()),
            etherfiRestaker: live.etherfiRestaker(),
            l1SyncPool: live.l1SyncPool()
        });
        return (
            addrs,
            live.minDiscountRateInBps(),
            live.stalePriceWindow(),
            live.maxPriceDeviationInBps(),
            live.maxPriceThreshold()
        );
    }
}
