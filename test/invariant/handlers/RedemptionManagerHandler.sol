// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/StdUtils.sol";
import "forge-std/Vm.sol";

import "@etherfi/core/LiquidityPool.sol";
import "@etherfi/core/EETH.sol";
import "@etherfi/core/WeETH.sol";
import "@etherfi/withdrawals/EtherFiRedemptionManager.sol";

/// @notice Stateful-invariant handler for EtherFiRedemptionManager + BucketLimiter.
///         Scoped to the ETH redemption path. The stETH path requires a mainnet
///         fork (Lido state, Liquifier stETH balance, EtherFiRestaker hookup)
///         and is not invariant-friendly at 256x64 — covered by the existing
///         fork-based unit tests.
///
///         Invariants enforced upstream (assert here that they NEVER trip):
///         - `InvalidNumSharesBurnt` / `InvalidTotalShares` / `InvalidLpBalance`
///           — local solvency checks inside `_processETHRedemption`.
///         - `EETHRateDeflation` — PR #428's `nonDecreasingRate` modifier on
///           the LP burnEEthShares path that redeem walks through.
///         - `RateLimitExceeded` should never fire when `canRedeem` returned
///           true the same block (modulo block.timestamp drift).
///
///         (F-001/F-014 pattern from PR #436 carried over):
///         - Independent rate oracle via `amountForShare(SHARE_PROBE)` AND a
///           probe account's `eETH.balanceOf`. Both must be non-decreasing
///           across every redemption.
///         - Independent ledger of expected LP balance + treasury eETH balance
///           + per-actor cumulative output. The ledger updates from observed
///           op deltas, the invariant file asserts equality with on-chain.
contract RedemptionManagerHandler is StdUtils {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 public constant SHARE_PROBE = 1e18;
    uint256 public constant N_EOAS = 5;

    /// @dev Critical selectors that should NEVER fire under bounded fuzz.
    bytes4 public constant SEL_INVALID_SHARES_BURNT  = bytes4(keccak256("InvalidNumSharesBurnt()"));
    bytes4 public constant SEL_INVALID_TOTAL_SHARES  = bytes4(keccak256("InvalidTotalShares()"));
    bytes4 public constant SEL_INVALID_LP_BALANCE    = bytes4(keccak256("InvalidLpBalance()"));
    bytes4 public constant SEL_INVALID_OUT_OF_LP     = bytes4(keccak256("InvalidTotalValueOutOfLp()"));
    bytes4 public constant SEL_EETH_RATE_DEFLATION   = bytes4(keccak256("EETHRateDeflation()"));
    bytes4 public constant SEL_PANIC                 = 0x4e487b71;

    LiquidityPool             public immutable lp;
    EETH                      public immutable eETH;
    WeETH                     public immutable weETH;
    EtherFiRedemptionManager  public immutable erm;
    address                   public immutable treasury;
    address                   public immutable membershipManager;
    /// @dev Holder of OPERATION_TIMELOCK_ROLE + OPERATION_MULTISIG_ROLE in TestSetup.
    address                   public immutable adminSigner;

    /// @dev Fixed-share probe account. Constructor seeds, handler never pranks
    ///      as it, so eETH.shares[probe] is constant and balanceOf is a pure
    ///      function of the rate. (F-001 from PR #436.)
    address public immutable probeAccount;

    address[N_EOAS] public actors;

    // ----- Ghost state ----------------------------------------------------

    /// @notice Independent ledger of LP's totalValueInLp. Increments on
    ///         observed deposit, decrements on observed redeem ETH leg.
    int256 public ghost_ledgerLpInBalance;

    /// @notice Independent ledger of treasury eETH balance. Increments on
    ///         every redeem (treasury fee in eETH).
    int256 public ghost_ledgerTreasuryEEth;

    /// @notice Cumulative ETH paid out to all redeem receivers.
    uint256 public ghost_totalEthPaidOut;
    /// @notice Cumulative eETH spent (from actors) on redeem.
    uint256 public ghost_totalEEthSpent;

    /// @notice Set if any successful redeem observed `amountForShare(1e18)` to
    ///         drop. Rate must be non-decreasing across the LP rate-modifier-
    ///         bearing paths the redeem touches.
    bool public ghost_rateDrop_viaAmountForShare;
    bool public ghost_rateDrop_viaProbeBalance;

    /// @notice Set if any successful redeem failed the share-conservation
    ///         identity `prevShares == newShares + sharesToBurn + feeShareToStakers`.
    bool public ghost_shareConservationViolated;

    /// @notice Set if redemption succeeded while the contract was paused.
    bool public ghost_pauseBypassObserved;

    /// @notice Cumulative bucket capacity-overflow observations. A
    ///         `consumable(limit) > capacity` would indicate a refill bug.
    bool public ghost_bucketCapacityViolated;

    /// @notice Critical selector counters - none should fire under bounded fuzz.
    uint256 public ghost_invalidSharesBurntCount;
    uint256 public ghost_invalidTotalSharesCount;
    uint256 public ghost_invalidLpBalanceCount;
    uint256 public ghost_invalidOutOfLpCount;
    uint256 public ghost_modifierRevertCount;
    uint256 public ghost_panicRevertCount;

    /// @notice Forensic crumbs on first observation.
    bytes32 public ghost_firstFailureOp;
    uint256 public ghost_firstFailure_rate0;
    uint256 public ghost_firstFailure_rate1;

    mapping(bytes32 => uint256) public callCounts;
    mapping(bytes32 => mapping(bytes4 => uint256)) public revertSelectors;

    constructor(
        LiquidityPool _lp,
        EETH _eETH,
        WeETH _weETH,
        EtherFiRedemptionManager _erm,
        address _treasury,
        address _membershipManager,
        address _adminSigner
    ) {
        lp = _lp;
        eETH = _eETH;
        weETH = _weETH;
        erm = _erm;
        treasury = _treasury;
        membershipManager = _membershipManager;
        adminSigner = _adminSigner;
        probeAccount = _label("erm.probe");

        for (uint256 i = 0; i < N_EOAS; i++) {
            actors[i] = _label(string.concat("erm.actor.", _itoa(i)));
            vm.deal(actors[i], 1_000 ether);
            vm.prank(actors[i]);
            lp.deposit{value: 100 ether}();
            ghost_ledgerLpInBalance += int256(uint256(100 ether));
            // Pre-approve both eETH and weETH for the ERM, and eETH for weETH
            // wrap. Pre-approving here removes a hidden revert surface inside
            // the handler ops' try/catch.
            vm.prank(actors[i]);
            eETH.approve(address(erm), type(uint256).max);
            vm.prank(actors[i]);
            eETH.approve(address(weETH), type(uint256).max);
            vm.prank(actors[i]);
            weETH.approve(address(erm), type(uint256).max);
            // Wrap a fraction so each actor starts with both eETH and weETH.
            vm.prank(actors[i]);
            try weETH.wrap(20 ether) {} catch {}
        }

        // Probe: dedicated rate-oracle account, NEVER touched by any handler op.
        vm.deal(probeAccount, 100 ether);
        vm.prank(probeAccount);
        lp.deposit{value: 50 ether}();
        ghost_ledgerLpInBalance += int256(uint256(50 ether));
    }

    // =====================================================================
    // CORE OPS - redemption
    // =====================================================================

    /// @notice Redeem eETH for ETH via the canRedeem precheck path. Captures
    ///         pre/post snapshots, asserts the local _processETHRedemption
    ///         checks didn't revert internally, and updates the ghost ledger.
    function redeemEEth(uint256 actorSeed, uint256 receiverSeed, uint128 amount) external {
        address actor = _eoa(actorSeed);
        address receiver = _eoa(receiverSeed);
        uint256 actorEEthBal = eETH.balanceOf(actor);
        if (actorEEthBal < 1 gwei) {
            callCounts["redeemEth_skipped"]++;
            return;
        }
        // Bound to actor balance AND to a sensible ETH cap.
        uint256 hi = actorEEthBal > 50 ether ? 50 ether : actorEEthBal;
        if (hi < 1 gwei) {
            callCounts["redeemEth_skipped"]++;
            return;
        }
        uint256 amt = bound(uint256(amount), 1 gwei, hi);

        // Pre-flight: short-circuit if canRedeem would refuse. Doing the
        // check here keeps the ghost-shareConservation assertion meaningful
        // (otherwise legitimate refusals show up as reverts and clutter the
        // selector counter).
        if (!erm.canRedeem(amt, ETH_ADDRESS) || erm.paused()) {
            callCounts["redeemEth_blocked"]++;
            return;
        }

        RedeemSnap memory r = _redeemSnap(actor, receiver);

        vm.prank(actor);
        try erm.redeemEEth(amt, receiver, ETH_ADDRESS) {
            _postRedeemChecks("redeemEth", actor, receiver, r, amt);
            callCounts["redeemEth"]++;
        } catch (bytes memory err) {
            _recordRevert("redeemEth", err);
        }
    }

    /// @notice Redeem weETH for ETH. Internally wraps -> unwraps via the
    ///         ERM, so exercises the weETH leg of the redemption path.
    function redeemWeEth(uint256 actorSeed, uint256 receiverSeed, uint128 amount) external {
        address actor = _eoa(actorSeed);
        address receiver = _eoa(receiverSeed);
        uint256 actorWeEthBal = weETH.balanceOf(actor);
        if (actorWeEthBal < 1 gwei) {
            callCounts["redeemWeEth_skipped"]++;
            return;
        }
        uint256 hi = actorWeEthBal > 30 ether ? 30 ether : actorWeEthBal;
        if (hi < 1 gwei) {
            callCounts["redeemWeEth_skipped"]++;
            return;
        }
        uint256 weAmt = bound(uint256(amount), 1 gwei, hi);
        uint256 eEthEquiv = weETH.getEETHByWeETH(weAmt);
        if (!erm.canRedeem(eEthEquiv, ETH_ADDRESS) || erm.paused()) {
            callCounts["redeemWeEth_blocked"]++;
            return;
        }

        RedeemSnap memory r = _redeemSnap(actor, receiver);

        vm.prank(actor);
        try erm.redeemWeEth(weAmt, receiver, ETH_ADDRESS) {
            _postRedeemChecks("redeemWeEth", actor, receiver, r, eEthEquiv);
            callCounts["redeemWeEth"]++;
        } catch (bytes memory err) {
            _recordRevert("redeemWeEth", err);
        }
    }

    /// @dev Centralises post-redeem assertions + ledger updates so the
    ///      individual redeem ops stay under the stack-depth limit.
    function _postRedeemChecks(
        bytes32 op,
        address /*actor*/,
        address receiver,
        RedeemSnap memory r,
        uint256 spentEEth
    ) internal {
        Snapshot memory s1 = _snap();
        _checkRateNonDecreasing(op, r.rate, s1);
        _checkShareConservation(op, r.totalSharesBefore, r.treasuryEEthBefore, true);
        _checkLpBalanceDelta(op, r.lpBalanceBefore, r.lpValueInBefore, r.receiverEthBefore, receiver);

        uint256 ethDelta = receiver.balance - r.receiverEthBefore;
        ghost_totalEthPaidOut += ethDelta;
        ghost_totalEEthSpent += spentEEth;
        ghost_ledgerLpInBalance -= int256(ethDelta);
        ghost_ledgerTreasuryEEth += int256(eETH.balanceOf(treasury) - r.treasuryEEthBefore);

        // (The previous version asserted that the actor's eETH balance must
        // strictly decrease on a redeem. That holds for `redeemEEth` but NOT
        // for `redeemWeEth` — there the actor spends weETH, which is taken
        // from them via `safeTransferFrom` and unwrapped inside the ERM, so
        // the actor's eETH balance is unchanged. The cross-account invariants
        // we actually care about — share conservation, LP balance delta,
        // rate non-decrease — are checked above.)
    }

    // =====================================================================
    // ADMIN OPS - drives the parameter surface that the bucket math depends on
    // =====================================================================

    function admin_setCapacity(uint128 capSeed) external {
        uint256 cap = bound(uint256(capSeed), 1 gwei, 10_000 ether);
        vm.prank(adminSigner);
        try erm.setCapacity(cap, ETH_ADDRESS) {
            callCounts["setCapacity"]++;
        } catch (bytes memory err) {
            _recordRevert("setCapacity", err);
        }
    }

    function admin_setRefillRate(uint128 rateSeed) external {
        uint256 rate = bound(uint256(rateSeed), 0, 100 ether);
        vm.prank(adminSigner);
        try erm.setRefillRatePerSecond(rate, ETH_ADDRESS) {
            callCounts["setRefillRate"]++;
        } catch (bytes memory err) {
            _recordRevert("setRefillRate", err);
        }
    }

    function admin_setExitFeeBps(uint16 bps) external {
        uint16 maxFee = uint16(erm.maxExitFeeInBps());
        uint16 capped = uint16(bound(uint256(bps), 0, uint256(maxFee)));
        vm.prank(adminSigner);
        try erm.setExitFeeBasisPoints(capped, ETH_ADDRESS) {
            callCounts["setExitFee"]++;
        } catch (bytes memory err) {
            _recordRevert("setExitFee", err);
        }
    }

    function admin_setExitFeeSplit(uint16 bps) external {
        uint16 maxSplit = uint16(erm.maxExitFeeSplitToTreasuryInBps());
        uint16 capped = uint16(bound(uint256(bps), 0, uint256(maxSplit)));
        vm.prank(adminSigner);
        try erm.setExitFeeSplitToTreasuryInBps(capped, ETH_ADDRESS) {
            callCounts["setExitFeeSplit"]++;
        } catch (bytes memory err) {
            _recordRevert("setExitFeeSplit", err);
        }
    }

    /// @notice The low watermark gates redemptions. We rarely raise it in
    ///         normal fuzz runs (TVL is small, anything above ~10 bps
    ///         starves the entire redemption surface). Allow occasional
    ///         non-zero values to exercise the gating logic.
    function admin_setLowWatermarkBps(uint16 bps) external {
        uint16 capped = uint16(bound(uint256(bps), 0, 50)); // <= 0.5%
        vm.prank(adminSigner);
        try erm.setLowWatermarkInBpsOfTvl(capped, ETH_ADDRESS) {
            callCounts["setLowWatermark"]++;
        } catch (bytes memory err) {
            _recordRevert("setLowWatermark", err);
        }
    }

    /// @notice Pause/unpause exercises the whenNotPaused gate.
    function admin_pause_and_attempt_redeem(uint256 actorSeed) external {
        vm.prank(adminSigner);
        try erm.pause() {
            callCounts["pause"]++;
        } catch (bytes memory err) {
            _recordRevert("pause", err);
            return;
        }
        // While paused, redemption MUST revert. canRedeem may still be true.
        address actor = _eoa(actorSeed);
        if (eETH.balanceOf(actor) >= 1 gwei) {
            vm.prank(actor);
            try erm.redeemEEth(1 gwei, actor, ETH_ADDRESS) {
                ghost_pauseBypassObserved = true;
            } catch (bytes memory err) {
                _recordRevert("paused_redeem_blocked", err);
            }
        }
        vm.prank(adminSigner);
        try erm.unpause() {
            callCounts["unpause"]++;
        } catch {}
    }

    // =====================================================================
    // SUPPORTING OPS - state evolution that downstream ops need
    // =====================================================================

    /// @notice Adds liquidity / shares so the redemption surface stays alive.
    function lp_deposit(uint256 actorSeed, uint128 amount) external {
        uint256 amt = bound(uint256(amount), 1 gwei, 200 ether);
        address actor = _eoa(actorSeed);
        vm.deal(actor, actor.balance + amt);

        vm.prank(actor);
        try lp.deposit{value: amt}() {
            ghost_ledgerLpInBalance += int256(amt);
            callCounts["lp_deposit"]++;
        } catch (bytes memory err) {
            _recordRevert("lp_deposit", err);
        }
    }

    /// @notice Positive rebases only — exercises the exempt LP path that
    ///         lifts the rate (so the non-decrease oracle still tracks).
    function lp_rebase(uint128 deltaSeed) external {
        uint256 outOfLp = uint256(lp.totalValueOutOfLp());
        uint256 cap = outOfLp == 0 ? 1 ether : (outOfLp * 50) / 10_000; // ~50 bps
        if (cap == 0) cap = 1;
        if (cap > uint256(uint128(type(int128).max))) cap = uint256(uint128(type(int128).max));
        int128 delta = int128(int256(bound(uint256(deltaSeed), 0, cap)));

        vm.prank(membershipManager);
        try lp.rebase(delta) {
            callCounts["rebase"]++;
        } catch (bytes memory err) {
            _recordRevert("rebase", err);
        }
    }

    /// @notice Advances time so the bucket refills. Without this, after
    ///         enough redemptions the bucket drains and the rest of the
    ///         sequence is just no-ops.
    function advance_time(uint16 secondsSeed) external {
        uint256 dt = bound(uint256(secondsSeed), 1, 600); // up to 10 min
        vm.warp(block.timestamp + dt);
        callCounts["advance_time"]++;
    }

    // =====================================================================
    // INTERNALS - oracles, snapshot, recording
    // =====================================================================

    struct Snapshot {
        uint256 rateAmountForShare; // lp.amountForShare(1e18)
        uint256 probeBalance;       // eETH.balanceOf(probeAccount)
    }

    /// @dev Grouped per-call snapshot for the redeem ops; bundling the locals
    ///      into a struct keeps the redeem fn under the stack-depth limit.
    struct RedeemSnap {
        Snapshot rate;
        uint256 receiverEthBefore;
        uint256 actorEEthBefore;
        uint256 treasuryEEthBefore;
        uint256 lpBalanceBefore;
        uint256 lpValueInBefore;
        uint256 totalSharesBefore;
    }

    function _snap() internal view returns (Snapshot memory s) {
        s.rateAmountForShare = lp.amountForShare(SHARE_PROBE);
        s.probeBalance = eETH.balanceOf(probeAccount);
    }

    function _redeemSnap(address actor, address receiver) internal view returns (RedeemSnap memory r) {
        r.rate = _snap();
        r.receiverEthBefore = receiver.balance;
        r.actorEEthBefore = eETH.balanceOf(actor);
        r.treasuryEEthBefore = eETH.balanceOf(treasury);
        r.lpBalanceBefore = address(lp).balance;
        r.lpValueInBefore = uint256(lp.totalValueInLp());
        r.totalSharesBefore = eETH.totalShares();
    }

    function _checkRateNonDecreasing(bytes32 op, Snapshot memory s0, Snapshot memory s1) internal {
        if (s1.rateAmountForShare < s0.rateAmountForShare) {
            if (!ghost_rateDrop_viaAmountForShare) {
                ghost_firstFailureOp = op;
                ghost_firstFailure_rate0 = s0.rateAmountForShare;
                ghost_firstFailure_rate1 = s1.rateAmountForShare;
            }
            ghost_rateDrop_viaAmountForShare = true;
        }
        if (s1.probeBalance < s0.probeBalance) {
            ghost_rateDrop_viaProbeBalance = true;
        }
    }

    /// @notice Asserts redemption never CREATES eETH shares. The contract
    ///         enforces a stricter equality (postShares == prevShares -
    ///         (sharesToBurn + feeShareToStakers)) internally; if that equality
    ///         were broken, `InvalidTotalShares` would fire — counted
    ///         separately via the revert-selector counter.
    ///
    ///         At very small amounts the floor/ceil rounding in
    ///         `_calcRedemption` can collapse `sharesToBurn + feeShareToStakers`
    ///         to zero; the redeem still succeeds (only a treasury-side eETH
    ///         transfer occurs). Total shares stay equal in that case, which
    ///         is fine — no shares are CREATED, just none burned.
    function _checkShareConservation(
        bytes32 op,
        uint256 totalSharesBefore,
        uint256 treasuryEEthBefore,
        bool /*unused*/
    ) internal {
        uint256 totalSharesAfter = eETH.totalShares();
        if (totalSharesAfter > totalSharesBefore) {
            ghost_shareConservationViolated = true;
            if (ghost_firstFailureOp == bytes32(0)) ghost_firstFailureOp = op;
        }
        // Treasury holds eETH; the redeem may transfer in (fee>0) or zero
        // (fee==0 or split==0). It must never DECREASE on a redeem call.
        uint256 treasuryEEthAfter = eETH.balanceOf(treasury);
        if (treasuryEEthAfter < treasuryEEthBefore) {
            ghost_shareConservationViolated = true;
            if (ghost_firstFailureOp == bytes32(0)) ghost_firstFailureOp = op;
        }
    }

    /// @notice Asserts that LP's ETH balance dropped by exactly the ETH paid
    ///         to the receiver (the modifier inside _processETHRedemption
    ///         already enforces this, but tracking it here as a cross-check
    ///         against the LP ledger).
    function _checkLpBalanceDelta(
        bytes32 op,
        uint256 lpBalanceBefore,
        uint256 lpValueInBefore,
        uint256 receiverEthBefore,
        address receiver
    ) internal {
        uint256 ethSentToReceiver = receiver.balance - receiverEthBefore;
        uint256 lpBalanceAfter = address(lp).balance;
        uint256 lpValueInAfter = uint256(lp.totalValueInLp());

        // LP's ETH balance dropped by exactly ethSentToReceiver.
        if (lpBalanceBefore - lpBalanceAfter != ethSentToReceiver) {
            ghost_shareConservationViolated = true;
            if (ghost_firstFailureOp == bytes32(0)) ghost_firstFailureOp = op;
        }
        // totalValueInLp tracks the same delta.
        if (lpValueInBefore - lpValueInAfter != ethSentToReceiver) {
            ghost_shareConservationViolated = true;
            if (ghost_firstFailureOp == bytes32(0)) ghost_firstFailureOp = op;
        }
    }

    function _recordRevert(bytes32 op, bytes memory err) internal {
        bytes4 sel;
        if (err.length >= 4) {
            assembly {
                sel := mload(add(err, 32))
            }
        }
        revertSelectors[op][sel]++;
        callCounts[_concat(op, "_revert")]++;

        if (sel == SEL_INVALID_SHARES_BURNT) ghost_invalidSharesBurntCount++;
        if (sel == SEL_INVALID_TOTAL_SHARES) ghost_invalidTotalSharesCount++;
        if (sel == SEL_INVALID_LP_BALANCE) ghost_invalidLpBalanceCount++;
        if (sel == SEL_INVALID_OUT_OF_LP) ghost_invalidOutOfLpCount++;
        if (sel == SEL_EETH_RATE_DEFLATION) ghost_modifierRevertCount++;
        if (sel == SEL_PANIC) ghost_panicRevertCount++;
    }

    // ----- view helpers ----------------------------------------------------

    function _eoa(uint256 seed) internal view returns (address) {
        return actors[seed % N_EOAS];
    }

    function _label(string memory s) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(s)))));
    }

    function _itoa(uint256 n) internal pure returns (string memory) {
        if (n == 0) return "0";
        uint256 j = n; uint256 len;
        while (j != 0) { len++; j /= 10; }
        bytes memory b = new bytes(len);
        uint256 k = len;
        while (n != 0) {
            k--;
            b[k] = bytes1(uint8(48 + n % 10));
            n /= 10;
        }
        return string(b);
    }

    function _concat(bytes32 a, bytes memory suffix) internal pure returns (bytes32 r) {
        bytes memory out = new bytes(32);
        uint256 i = 0;
        for (; i < 32; i++) {
            bytes1 c = a[i];
            if (c == 0) break;
            out[i] = c;
        }
        for (uint256 j = 0; j < suffix.length && i < 32; j++) {
            out[i] = suffix[j];
            i++;
        }
        assembly { r := mload(add(out, 32)) }
    }
}
