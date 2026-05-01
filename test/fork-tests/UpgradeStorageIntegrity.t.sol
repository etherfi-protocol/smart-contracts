// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../script/deploys/Deployed.s.sol";
import "../../src/LiquidityPool.sol";
import "../../src/WithdrawRequestNFT.sol";
import "../../src/ReentrancyGuardNamespaced.sol";

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
        address membership;
        uint32 nextId;
        uint32 lastFin;
        uint16 split;
        uint32 scanFrom;
        uint32 scanTo;
        uint256 agg;
        uint256 remainder;
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
        s.locked = lp.ethAmountLockedForWithdrawal();
        s.valSize = lp.validatorSizeWei();
        s.paused = lp.paused();
        s.restake = lp.restakeBnftDeposits();
    }

    function _snapWRN(WithdrawRequestNFT wrn) internal view returns (WRNSnap memory s) {
        s.lp = address(wrn.liquidityPool());
        s.eeth = address(wrn.eETH());
        s.membership = address(wrn.membershipManager());
        s.nextId = wrn.nextRequestId();
        s.lastFin = wrn.lastFinalizedRequestId();
        s.split = wrn.shareRemainderSplitToTreasuryInBps();
        s.scanFrom = wrn.currentRequestIdToScanFromForShareRemainder();
        s.scanTo = wrn.lastRequestIdToScanUntilForShareRemainder();
        s.agg = wrn.aggregateSumOfEEthShare();
        s.remainder = wrn.totalRemainderEEthShares();
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
        assertEq(a.locked,         b.locked,         "ethAmountLockedForWithdrawal");
        assertEq(a.valSize,        b.valSize,        "validatorSizeWei");
        assertEq(a.paused,         b.paused,         "paused");
        assertEq(a.restake,        b.restake,        "restakeBnftDeposits");
    }

    function _assertWRNEq(WRNSnap memory a, WRNSnap memory b) internal {
        assertEq(a.lp,         b.lp,         "WRN.liquidityPool");
        assertEq(a.eeth,       b.eeth,       "WRN.eETH");
        assertEq(a.membership, b.membership, "WRN.membershipManager");
        assertEq(a.nextId,     b.nextId,     "WRN.nextRequestId");
        assertEq(a.lastFin,    b.lastFin,    "WRN.lastFinalizedRequestId");
        assertEq(a.split,      b.split,      "WRN.split");
        assertEq(a.scanFrom,   b.scanFrom,   "WRN.scanFrom");
        assertEq(a.scanTo,     b.scanTo,     "WRN.scanTo");
        assertEq(a.agg,        b.agg,        "WRN.aggregateSum");
        assertEq(a.remainder,  b.remainder,  "WRN.remainder");
        assertEq(a.paused,     b.paused,     "WRN.paused");
    }

    function setUp() public {
        // Latest-block fork; realistic mainnet state.
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
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
        WithdrawRequestNFT wrn = WithdrawRequestNFT(WITHDRAW_REQUEST_NFT);

        LPSnap memory lpPre = _snapLP(lp);
        WRNSnap memory wrnPre = _snapWRN(wrn);

        // ------------------------------------------------------------------
        // 2. Deploy new implementation contracts (with the added guard)
        // ------------------------------------------------------------------
        address newLP  = address(new LiquidityPool(PRIORITY_WITHDRAWAL_QUEUE));
        address newWRN = address(new WithdrawRequestNFT(WITHDRAW_REQUEST_NFT_BUYBACK_SAFE, PRIORITY_WITHDRAWAL_QUEUE));

        // ------------------------------------------------------------------
        // 3. Upgrade the proxies in place
        //    LP:  _authorizeUpgrade -> roleRegistry.onlyProtocolUpgrader
        //         The UPGRADE_TIMELOCK holds the protocol upgrader role.
        //    WRN: _authorizeUpgrade -> onlyOwner (read at runtime).
        // ------------------------------------------------------------------
        vm.prank(UPGRADE_TIMELOCK);
        IUUPSProxy(LIQUIDITY_POOL).upgradeTo(newLP);

        address wrnOwner = IOwnableRead(WITHDRAW_REQUEST_NFT).owner();
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
        // 7. Smoke test: a guarded function executes end-to-end on the
        //    upgraded proxy and the guard slot cycles correctly.
        // ------------------------------------------------------------------
        if (!lp.paused()) {
            address user = address(0xB0B0);
            vm.deal(user, 5 ether);
            vm.prank(user);
            lp.deposit{value: 1 ether}();

            assertEq(
                vm.load(LIQUIDITY_POOL, GUARD_SLOT),
                bytes32(uint256(1)),
                "guard slot not NOT_ENTERED after guarded deposit"
            );
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

        WithdrawRequestNFT wrn = WithdrawRequestNFT(WITHDRAW_REQUEST_NFT);
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

        WithdrawRequestNFT wrn = WithdrawRequestNFT(WITHDRAW_REQUEST_NFT);
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
        bytes32 pauserRole = wrn.roleRegistry().PROTOCOL_PAUSER();
        address roleRegOwner = IOwnableRead(roleReg).owner();
        vm.startPrank(roleRegOwner);
        (bool granted,) = roleReg.call(
            abi.encodeWithSignature("grantRole(bytes32,address)", pauserRole, address(this))
        );
        vm.stopPrank();
        require(granted, "role grant failed");

        wrn.pauseContract();
        assertTrue(wrn.paused(), "precondition: WRN paused");

        uint256 balBefore = nftOwner.balance;
        vm.prank(nftOwner);
        wrn.claimWithdraw(found);

        assertGt(nftOwner.balance, balBefore, "paused WRN must not block finalized claim");
    }

    /// @dev Internal helper used by the integrity test above - upgrades both
    ///      proxies to new implementations with the guard + permissionless
    ///      claim changes.
    function _doUpgrade() internal {
        address newLP = address(new LiquidityPool(PRIORITY_WITHDRAWAL_QUEUE));
        address newWRN = address(new WithdrawRequestNFT(WITHDRAW_REQUEST_NFT_BUYBACK_SAFE, PRIORITY_WITHDRAWAL_QUEUE));

        vm.prank(UPGRADE_TIMELOCK);
        IUUPSProxy(LIQUIDITY_POOL).upgradeTo(newLP);

        address wrnOwner = IOwnableRead(WITHDRAW_REQUEST_NFT).owner();
        vm.prank(wrnOwner);
        IUUPSProxy(WITHDRAW_REQUEST_NFT).upgradeTo(newWRN);
    }

    /// @dev Separately verify that, post-upgrade, the guard actually blocks
    ///      re-entry. This is defence-in-depth in case some ABI mismatch made
    ///      the modifier no-op.
    function test_postUpgrade_guardBlocksReentry() public {
        address newLP = address(new LiquidityPool(PRIORITY_WITHDRAWAL_QUEUE));
        vm.prank(UPGRADE_TIMELOCK);
        IUUPSProxy(LIQUIDITY_POOL).upgradeTo(newLP);

        // Plant ENTERED directly; the next guarded call must revert with the
        // reentrancy error selector — proves the modifier reads the slot we
        // expect on the upgraded proxy.
        vm.store(LIQUIDITY_POOL, GUARD_SLOT, bytes32(uint256(2)));

        address user = address(0xB0B0);
        vm.deal(user, 1 ether);

        LiquidityPool lp = LiquidityPool(payable(LIQUIDITY_POOL));
        if (!lp.paused()) {
            vm.expectRevert(ReentrancyGuardNamespaced.ReentrancyGuardReentrantCall.selector);
            vm.prank(user);
            lp.deposit{value: 1 ether}();
        }
    }
}
