// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "@scripts/deploys/Deployed.s.sol";
import "@etherfi/core/LiquidityPool.sol";
import "@etherfi/core/interfaces/ILiquidityPool.sol";
import "@etherfi/withdrawals/WithdrawRequestNFT.sol";
import "@etherfi/withdrawals/PriorityWithdrawalQueue.sol";
import "@etherfi/governance/RoleRegistry.sol";
import "@etherfi/utils/UUPSProxy.sol";
import "@etherfi/governance/Blacklister.sol";

interface IUUPSProxy {
    function upgradeTo(address newImpl) external;
}

interface IOwnableRead {
    function owner() external view returns (address);
}

/// @notice Fork test that upgrades the real mainnet LiquidityPool and
///         WithdrawRequestNFT proxies to the new implementation (with the
///         namespaced reentrancy guard added) and verifies that EVERY
///         sequential storage slot is byte-identical before and after the
///         upgrade. This is the load-bearing proof that adding
///         ReentrancyGuardNamespaced to the inheritance chain did not shift
///         any existing state variable.
///
/// Requires MAINNET_RPC_URL to be set.
///
/// Slot scan strategy:
///   - LiquidityPool declared sequential range per `forge inspect`: 0..~220.
///   - WithdrawRequestNFT declared sequential range: 0..~310.
///   - We scan 0..399 on both to comfortably cover both plus any future growth.
///   - Mapping/array element slots live at keccak256-derived addresses far
///     above the scan range; they don't shift when the sequential layout is
///     preserved, so scanning sequentials is sufficient.
///   - The guard slot (keccak256("etherfi.storage.ReentrancyGuard.v1"), value
///     ~2^252) is also outside the scan window and is checked separately.
///   - The ERC-1967 implementation slot changes by design (that's the point of
///     the upgrade) and is also outside 0..399, so it won't produce false drift.
contract UpgradeStorageIntegrityTest is Test, Deployed {
    uint256 internal constant SCAN_SLOTS = 400;
    bytes32 internal constant GUARD_SLOT =
        0xcd24049d7dcc1fde21494dba8ad7a067afb6b8f14dfe804abeeec84903344e97;

    Blacklister internal blacklisterInstance;

    struct LPSnap {
        address eeth;
        address stakingManager;
        address nodesManager;
        address feeRecipient;
        address admin;
        address wrn;
        address liquifier;
        uint128 totalIn;
        uint128 totalOut;
        uint128 locked;
        uint256 valSize;
        bool paused;
        bool restake;
    }

    struct WRNSnap {
        address lp;
        address eeth;
        uint32 nextId;
        uint32 lastFin;
        bool paused;
    }

    function _snapLP(LiquidityPool lp) internal view returns (LPSnap memory s) {
        s.eeth = address(lp.eETH());
        s.stakingManager = address(lp.stakingManager());
        s.nodesManager = address(lp.nodesManager());
        s.feeRecipient = lp.feeRecipient();
        s.admin = lp.etherFiAdminContract();
        s.wrn = address(lp.withdrawRequestNFT());
        s.liquifier = address(lp.liquifier());
        s.totalIn = lp.totalValueInLp();
        s.totalOut = lp.totalValueOutOfLp();
        // Read DEPRECATED_ethAmountLockedForWithdrawal via raw slot load so this
        // snap function works on both the old mainnet impl (which has
        // ethAmountLockedForWithdrawal()) and the new impl (which renames it to
        // DEPRECATED_ethAmountLockedForWithdrawal()). Slot 220, upper 16 bytes.
        bytes32 raw = vm.load(address(lp), bytes32(uint256(220)));
        s.locked = uint128(uint256(raw) >> 8);
        s.valSize = lp.validatorSizeWei();
        s.paused = lp.paused();
    }

    function _snapWRN(WithdrawRequestNFT wrn) internal view returns (WRNSnap memory s) {
        s.lp = address(wrn.liquidityPool());
        s.eeth = address(wrn.eETH());
        s.nextId = wrn.nextRequestId();
        s.lastFin = wrn.lastFinalizedRequestId();
        s.paused = wrn.paused();
    }

    function _assertLPEq(LPSnap memory a, LPSnap memory b) internal {
        assertEq(a.eeth,           b.eeth,           "eETH");
        assertEq(a.stakingManager, b.stakingManager, "stakingManager");
        assertEq(a.nodesManager,   b.nodesManager,   "nodesManager");
        assertEq(a.feeRecipient,   b.feeRecipient,   "feeRecipient");
        assertEq(a.admin,          b.admin,          "etherFiAdminContract");
        assertEq(a.wrn,            b.wrn,            "withdrawRequestNFT");
        assertEq(a.liquifier,      b.liquifier,      "liquifier");
        assertEq(a.totalIn,        b.totalIn,        "totalValueInLp");
        assertEq(a.totalOut,       b.totalOut,       "totalValueOutOfLp");
        assertEq(a.locked,         b.locked,         "DEPRECATED_ethAmountLockedForWithdrawal");
        assertEq(a.valSize,        b.valSize,        "validatorSizeWei");
        assertEq(a.paused,         b.paused,         "paused");
        assertEq(a.restake,        b.restake,        "restakeBnftDeposits");
    }

    function _assertWRNEq(WRNSnap memory a, WRNSnap memory b) internal {
        assertEq(a.lp,         b.lp,         "WRN.liquidityPool");
        assertEq(a.eeth,       b.eeth,       "WRN.eETH");
        assertEq(a.nextId,     b.nextId,     "WRN.nextRequestId");
        assertEq(a.lastFin,    b.lastFin,    "WRN.lastFinalizedRequestId");
        assertEq(a.paused,     b.paused,     "WRN.paused");
    }

    function setUp() public {
        // Latest-block fork; realistic mainnet state.
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // NOTE: RoleRegistry is intentionally NOT upgraded here. The currently
        // deployed LP/WRN/PQ impls authorize upgrades via the legacy
        // `roleRegistry.onlyProtocolUpgrader` / `onlyOwner` paths; once we swap
        // RoleRegistry to the new impl that selector no longer exists, so all
        // proxy upgrades have to happen against the live RoleRegistry. The
        // RoleRegistry upgrade itself is performed by `_upgradeRoleRegistry()`
        // AFTER the other proxies have been upgraded.

        // Deploy a fresh Blacklister — newly-upgraded impls (LP, WRN, etc.)
        // now wire it as an immutable. Storage-integrity assertions don't care
        // about its address; we just need a non-zero target so the constructor
        // input is well-formed.
        Blacklister bImpl = new Blacklister(ROLE_REGISTRY);
        blacklisterInstance = Blacklister(address(new UUPSProxy(address(bImpl), abi.encodeWithSelector(Blacklister.initialize.selector))));
    }

    /// @dev Upgrade RoleRegistry to the new impl (after LP/WRN/PQ have already
    ///      been upgraded) and grant the new UPGRADE_TIMELOCK_ROLE to the
    ///      mainnet UPGRADE_TIMELOCK address so subsequent calls gated by
    ///      `onlyUpgradeTimelock` (e.g. `initializeOnUpgradeV2`) can pass.
    function _upgradeRoleRegistry() internal {
        address roleRegOwner = IOwnableRead(ROLE_REGISTRY).owner();
        address newRoleRegistryImpl = address(new RoleRegistry(address(0)));
        vm.prank(roleRegOwner);
        IUUPSProxy(ROLE_REGISTRY).upgradeTo(newRoleRegistryImpl);

        RoleRegistry rr = RoleRegistry(ROLE_REGISTRY);
        // Cache the role bytes32 in a local first — calling `rr.UPGRADE_TIMELOCK_ROLE()`
        // inline as a `grantRole` argument would consume the next `vm.prank` slot.
        bytes32 upgradeRole = rr.UPGRADE_TIMELOCK_ROLE();
        vm.prank(roleRegOwner);
        rr.grantRole(upgradeRole, UPGRADE_TIMELOCK);
    }

    function _snap(address target, uint256 n) internal view returns (bytes32[] memory a) {
        a = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            a[i] = vm.load(target, bytes32(i));
        }
    }

    function _diff(string memory label, address target, bytes32[] memory pre) internal returns (uint256 drifts) {
        for (uint256 i = 0; i < pre.length; i++) {
            bytes32 post = vm.load(target, bytes32(i));
            if (post != pre[i]) {
                drifts++;
                emit log_named_string("drift in", label);
                emit log_named_uint("  slot", i);
                emit log_named_bytes32("  pre ", pre[i]);
                emit log_named_bytes32("  post", post);
            }
        }
    }

    function test_upgrade_preserves_all_sequential_storage() public {
        // ------------------------------------------------------------------
        // 1. Snapshot every sequential slot pre-upgrade
        // ------------------------------------------------------------------
        bytes32[] memory preLP  = _snap(LIQUIDITY_POOL, SCAN_SLOTS);
        bytes32[] memory preWRN = _snap(WITHDRAW_REQUEST_NFT, SCAN_SLOTS);

        // Guard slot must be pristine (0) on live mainnet prior to upgrade.
        // If not, we'd have a pre-existing collision — the whole approach fails.
        assertEq(vm.load(LIQUIDITY_POOL, GUARD_SLOT), bytes32(0), "LP guard slot not zero pre-upgrade");
        assertEq(vm.load(WITHDRAW_REQUEST_NFT, GUARD_SLOT), bytes32(0), "WRN guard slot not zero pre-upgrade");

        // Typed getter snapshot — independent cross-check of the slot scan.
        LiquidityPool lp = LiquidityPool(payable(LIQUIDITY_POOL));
        WithdrawRequestNFT wrn = WithdrawRequestNFT(payable(WITHDRAW_REQUEST_NFT));

        LPSnap memory lpPre = _snapLP(lp);
        WRNSnap memory wrnPre = _snapWRN(wrn);

        // ------------------------------------------------------------------
        // 2. Deploy new implementation contracts (with the added guard)
        // ------------------------------------------------------------------
        address newLP  = address(new LiquidityPool(
            ILiquidityPool.ConstructorAddresses({
                stakingManager: STAKING_MANAGER,
                nodesManager: ETHERFI_NODES_MANAGER,
                eETH: EETH,
                withdrawRequestNFT: WITHDRAW_REQUEST_NFT,
                liquifier: LIQUIFIER,
                etherFiRedemptionManager: ETHERFI_REDEMPTION_MANAGER,
                roleRegistry: ROLE_REGISTRY,
                priorityWithdrawalQueue: PRIORITY_WITHDRAWAL_QUEUE,
                blacklister: address(blacklisterInstance),
                etherFiAdminContract: ETHERFI_ADMIN,
                membershipManager: MEMBERSHIP_MANAGER
            })
        ));
        address newWRN = address(new WithdrawRequestNFT(WITHDRAW_REQUEST_NFT_BUYBACK_SAFE, EETH, LIQUIDITY_POOL, ROLE_REGISTRY, address(blacklisterInstance), ETHERFI_ADMIN));

        // ------------------------------------------------------------------
        // 3. Upgrade the proxies in place
        //    LP:  legacy _authorizeUpgrade -> roleRegistry.onlyProtocolUpgrader
        //         which on the deployed RoleRegistry checks `owner() == account`.
        //         Use the live RoleRegistry owner.
        //    WRN: legacy _authorizeUpgrade -> onlyOwner (read at runtime).
        // ------------------------------------------------------------------
        address roleRegOwner = IOwnableRead(ROLE_REGISTRY).owner();
        address wrnOwner = IOwnableRead(WITHDRAW_REQUEST_NFT).owner();

        vm.prank(roleRegOwner);
        IUUPSProxy(LIQUIDITY_POOL).upgradeTo(newLP);

        vm.prank(wrnOwner);
        IUUPSProxy(WITHDRAW_REQUEST_NFT).upgradeTo(newWRN);

        // ------------------------------------------------------------------
        // 4. Primary check: every scanned slot is byte-identical
        // ------------------------------------------------------------------
        uint256 lpDrifts  = _diff("LiquidityPool", LIQUIDITY_POOL, preLP);
        uint256 wrnDrifts = _diff("WithdrawRequestNFT", WITHDRAW_REQUEST_NFT, preWRN);

        assertEq(lpDrifts, 0, "LP sequential storage drifted after upgrade");
        assertEq(wrnDrifts, 0, "WRN sequential storage drifted after upgrade");

        // ------------------------------------------------------------------
        // 5. Guard slot remains clean immediately after upgrade
        // ------------------------------------------------------------------
        assertEq(vm.load(LIQUIDITY_POOL, GUARD_SLOT), bytes32(0), "LP guard slot mutated by upgrade");
        assertEq(vm.load(WITHDRAW_REQUEST_NFT, GUARD_SLOT), bytes32(0), "WRN guard slot mutated by upgrade");

        // ------------------------------------------------------------------
        // 6. Typed sanity: every accessor returns the exact same value.
        //    This catches the case where a slot is byte-equal but the
        //    compiler reinterprets it (type change at same offset). Unlikely
        //    given we only added inheritance, but it's a cheap belt.
        // ------------------------------------------------------------------
        _assertLPEq(_snapLP(lp), lpPre);
        _assertWRNEq(_snapWRN(wrn), wrnPre);

        // ------------------------------------------------------------------
        // 7. Smoke test: a `nonReentrant` function executes end-to-end on the
        //    upgraded proxy. The guard is now Solady's transient guard, which
        //    keeps no persistent slot to inspect — a successful deposit through
        //    the modifier is the meaningful post-upgrade check.
        // ------------------------------------------------------------------
        if (!lp.paused()) {
            address user = address(0xB0B0);
            vm.deal(user, 5 ether);
            vm.prank(user);
            lp.deposit{value: 1 ether}();
        }
    }

    /// @notice After the upgrade, a pre-existing finalized-but-unclaimed
    ///         request from live mainnet state must still be claimable by its
    ///         NFT owner. Proves: (a) storage for `_requests[id]` and the NFT
    ///         ownership mapping is intact, (b) the removal of `whenNotPaused`
    ///         does not regress happy-path claims, (c) LP.withdraw still wired
    ///         correctly for the historical accounting path.
    function test_postUpgrade_preExistingFinalizedRequest_isClaimable() public {
        _doUpgrade();

        WithdrawRequestNFT wrn = WithdrawRequestNFT(payable(WITHDRAW_REQUEST_NFT));
        uint32 lastFin = wrn.lastFinalizedRequestId();
        require(lastFin > 0, "no finalized requests on fork");

        // Scan downward from lastFinalizedRequestId looking for an
        // unclaimed (ownerOf doesn't revert) + valid request with non-zero
        // claim amount. Skip the very top few in case the LP doesn't have
        // the liquidity buffered yet.
        uint256 found = 0;
        address nftOwner;
        uint256 maxScan = 1000;
        for (uint256 i = 0; i < maxScan; i++) {
            if (i >= lastFin) break;
            uint256 candidate = lastFin - i;

            (bool ok, bytes memory data) = address(wrn).staticcall(
                abi.encodeWithSignature("ownerOf(uint256)", candidate)
            );
            if (!ok) continue;
            address o = abi.decode(data, (address));
            if (o == address(0)) continue;

            // isValid reverts if !_exists; ownerOf already asserted existence,
            // so this is safe.
            if (!wrn.isValid(candidate)) continue;

            // Skip zero-amount edge cases (partial claims or weird shares).
            if (wrn.getClaimableAmount(candidate) == 0) continue;

            found = candidate;
            nftOwner = o;
            break;
        }

        require(found != 0, "no finalized+valid+unclaimed request found in scan range");

        uint256 claimable = wrn.getClaimableAmount(found);
        uint256 balBefore = nftOwner.balance;

        vm.prank(nftOwner);
        wrn.claimWithdraw(found);

        assertGt(nftOwner.balance, balBefore, "pre-existing finalized request produced no payout");
        assertApproxEqAbs(
            nftOwner.balance - balBefore,
            claimable,
            1,
            "payout deviates from getClaimableAmount"
        );
    }

    /// @notice Also exercises the permissionless-claim property on real state:
    ///         pause WRN (via PROTOCOL_PAUSER), then claim a pre-existing
    ///         finalized request. Must succeed post-upgrade.
    function test_postUpgrade_claimWorksWhilePaused_onMainnetData() public {
        _doUpgrade();

        WithdrawRequestNFT wrn = WithdrawRequestNFT(payable(WITHDRAW_REQUEST_NFT));
        uint32 lastFin = wrn.lastFinalizedRequestId();
        require(lastFin > 0, "no finalized requests on fork");

        uint256 found = 0;
        address nftOwner;
        for (uint256 i = 0; i < 1000; i++) {
            if (i >= lastFin) break;
            uint256 candidate = lastFin - i;
            (bool ok, bytes memory data) = address(wrn).staticcall(
                abi.encodeWithSignature("ownerOf(uint256)", candidate)
            );
            if (!ok) continue;
            address o = abi.decode(data, (address));
            if (o == address(0)) continue;
            if (!wrn.isValid(candidate)) continue;
            if (wrn.getClaimableAmount(candidate) == 0) continue;
            found = candidate;
            nftOwner = o;
            break;
        }
        require(found != 0, "no candidate");

        // Pause WRN directly via the namespaced pauser. Instead of hunting
        // down the live pauser address, grant the role to this test via
        // RoleRegistry's owner/DEFAULT_ADMIN.
        address roleReg = address(wrn.roleRegistry());
        bytes32 pauserRole = wrn.roleRegistry().OPERATION_MULTISIG_ROLE();
        address roleRegOwner = IOwnableRead(roleReg).owner();
        vm.startPrank(roleRegOwner);
        (bool granted,) = roleReg.call(
            abi.encodeWithSignature("grantRole(bytes32,address)", pauserRole, address(this))
        );
        vm.stopPrank();
        require(granted, "role grant failed");

        wrn.pause();
        assertTrue(wrn.paused(), "precondition: WRN paused");

        uint256 balBefore = nftOwner.balance;
        vm.prank(nftOwner);
        wrn.claimWithdraw(found);

        assertGt(nftOwner.balance, balBefore, "paused WRN must not block finalized claim");
    }

    /// @dev Internal helper used by the integrity test above - upgrades all
    ///      three proxies (LP, WRN, PriorityWithdrawalQueue) to the new impls.
    ///      The queue must be upgraded before initializeOnUpgradeV2 because the
    ///      migration sweeps queue-locked ETH into the queue contract via
    ///      receive(); the master queue impl has no receive() and would revert.
    function _doUpgrade() internal {
        address newLP = address(new LiquidityPool(
            ILiquidityPool.ConstructorAddresses({
                stakingManager: STAKING_MANAGER,
                nodesManager: ETHERFI_NODES_MANAGER,
                eETH: EETH,
                withdrawRequestNFT: WITHDRAW_REQUEST_NFT,
                liquifier: LIQUIFIER,
                etherFiRedemptionManager: ETHERFI_REDEMPTION_MANAGER,
                roleRegistry: ROLE_REGISTRY,
                priorityWithdrawalQueue: PRIORITY_WITHDRAWAL_QUEUE,
                blacklister: address(blacklisterInstance),
                etherFiAdminContract: ETHERFI_ADMIN,
                membershipManager: MEMBERSHIP_MANAGER
            })
        ));
        address newWRN = address(new WithdrawRequestNFT(WITHDRAW_REQUEST_NFT_BUYBACK_SAFE, EETH, LIQUIDITY_POOL, ROLE_REGISTRY, address(blacklisterInstance), ETHERFI_ADMIN));
        address newPQ = address(new PriorityWithdrawalQueue(
            LIQUIDITY_POOL, EETH, WEETH, address(blacklisterInstance), ROLE_REGISTRY, TREASURY, 1 hours
        ));

        // Upgrade proxies against the LIVE (pre-upgrade) RoleRegistry, since
        // the deployed LP/PQ impls still call `onlyProtocolUpgrader` and the
        // deployed WRN impl uses `onlyOwner`.
        address roleRegOwner = IOwnableRead(ROLE_REGISTRY).owner();
        address wrnOwner = IOwnableRead(WITHDRAW_REQUEST_NFT).owner();

        vm.prank(roleRegOwner);
        IUUPSProxy(LIQUIDITY_POOL).upgradeTo(newLP);

        vm.prank(wrnOwner);
        IUUPSProxy(WITHDRAW_REQUEST_NFT).upgradeTo(newWRN);

        vm.prank(roleRegOwner);
        IUUPSProxy(PRIORITY_WITHDRAWAL_QUEUE).upgradeTo(newPQ);

        // Now swap RoleRegistry so the freshly-upgraded impls' role getters
        // (onlyUpgradeTimelock, onlyOperatingMultisig, ...) resolve.
        _upgradeRoleRegistry();

        // Migrate pre-existing locked ETH from LP into the NFT escrow so that
        // pre-existing finalized requests can be claimed against the NFT balance.
        // `initializeOnUpgradeV2` is `onlyUpgradeTimelock`; UPGRADE_TIMELOCK was
        // granted UPGRADE_TIMELOCK_ROLE inside `_upgradeRoleRegistry`.
        LiquidityPool lp = LiquidityPool(payable(LIQUIDITY_POOL));
        if (!lp.escrowMigrationCompleted()) {
            vm.prank(UPGRADE_TIMELOCK);
            lp.initializeOnUpgradeV2();
        }
    }

    /// @dev Separately verify that, post-upgrade, the guard actually blocks
    ///      re-entry. This is defence-in-depth in case some ABI mismatch made
    ///      the modifier no-op.
    // NOTE: a former `test_postUpgrade_guardBlocksReentry` planted ENTERED at the
    // namespaced guard slot via `vm.store` and expected the next call to revert. That
    // mechanism no longer exists: the guard is Solady's transient `ReentrancyGuardTransient`,
    // which has no plantable persistent slot. Actual reentry-blocking on the upgraded
    // contracts is covered by `test/ReentrancyGuard.t.sol` (real reentrant attacker).
}
