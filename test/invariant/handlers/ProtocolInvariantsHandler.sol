// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/StdUtils.sol";
import "forge-std/Vm.sol";

import "../../../src/LiquidityPool.sol";
import "../../../src/EETH.sol";
import "../../../src/WeETH.sol";

/// @notice Stateful-invariant handler for PR #428's two inlined invariants AND
///         the global protocol-accounting conservation laws those two invariants
///         live on top of.
///
///         Design changes vs the original v1 handler (in response to the
///         multi-reviewer audit of PR #436):
///
///         (F-001) Independent rate oracle. The previous `_checkNonExempt`
///         recomputed `P1*S0 < P0*S1` - byte-for-byte the modifier's own
///         predicate. A modifier bug would have been mirrored by the ghost.
///         The new oracle uses `lp.amountForShare(SHARE_PROBE)` AND a fixed-
///         share probe account's `eETH.balanceOf` - both go through `mulDiv`
///         (different code path from cross-multiplication) and the probe is
///         end-user observable. Two independent oracles, both must agree.
///
///         (F-002) Catch with selector capture. Every protocol call now
///         captures `bytes4(returnData)` and records it in `revertSelectors`.
///         Critical selectors (`EETHRateDeflation`, `WeETHUnderbacked`,
///         `Panic`) trigger ghost flags so the test file can prove the
///         protocol's own safety reverts never fire during a normal-input
///         sequence - distinguishing "safety check fired" from "input bound
///         rejected."
///
///         (F-006) Realistic rebase bound. Default rebase magnitude is
///         capped at MAX_REBASE_BPS (~50 bps), reflecting EtherFiAdmin's
///         APR cap. A separate `rebaseExtreme` op keeps the stress range.
///
///         (F-009) Liquifier + fee recipient added to the catalogue
///         enumeration. A future code path that credits shares to either
///         can no longer hide in plain sight.
///
///         (F-011) Bootstrap-exempt branch is counted, not skipped. The
///         `if (S0==0 || S1==0) return` short-circuit duplicated the
///         modifier's exemption; we now record a hit and let the invariant
///         file assert it occurs at most once per protocol life.
///
///         (F-013) Adversarial paths: weETH proxy drain (vm.prank as the
///         proxy and force-transfer eETH out) and first-depositor share-
///         inflation. Both should violate Invariant 1 if the hook were
///         removed; both should be benign if it's intact.
///
///         (F-014) Independent TVL ledger. `getTotalPooledEther()` is just
///         `totalValueInLp + totalValueOutOfLp` - an algebraic identity.
///         The handler now maintains its own running ledger from observed
///         deposits/burns/claims/rebases and the invariant file asserts
///         equality against the on-chain value.
///
///         (F-018) Pause/unpause ops, plus `whilePaused` assertion mode.
///
///         (F-020) Wrap bound widened to `[1, bal]` so the boundary corners
///         (1 wei dust, full balance) are reachable.
///
///         (F-021) `drainToSingleDigitShares` op - explicitly drives
///         `eETH.totalShares()` to low values to stress the rate-precision
///         regime. The previous handler actively avoided this state.
///
///         (F-029) Static-actor residual check: the global-shares-conservation
///         invariant now sums over BOTH the dynamic `shareHolders` set AND
///         the static `actors` pool, so a callback-routed credit to an
///         unobserved address still raises the sum and fails the assertion.
contract ProtocolInvariantsHandler is StdUtils {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 public constant SHARE_PROBE = 1e18;
    uint256 public constant MAX_REBASE_BPS = 50;    // ~0.5% per rebase; ~production APR cap
    uint256 public constant BPS_DENOM      = 10_000;

    /// @dev Critical selectors we expect NEVER to surface as catch reasons in
    ///      a normal-input sequence. Their appearance is a regression signal.
    bytes4 public constant SEL_EETH_RATE_DEFLATION = bytes4(keccak256("EETHRateDeflation()"));
    bytes4 public constant SEL_WEETH_UNDERBACKED   = bytes4(keccak256("WeETHUnderbacked(uint256,uint256)"));
    bytes4 public constant SEL_PANIC               = 0x4e487b71;

    LiquidityPool public immutable lp;
    EETH         public immutable eETH;
    WeETH        public immutable weETH;
    address      public immutable erm;
    address      public immutable wrn;
    address      public immutable pq;
    address      public immutable membershipManager;
    address      public immutable treasury;
    address      public immutable liquifier;       // F-009: catalogue extension
    address      public immutable operatingMultisig;// F-018: passed in to avoid local role wiring
    /// @notice A fixed-share probe account. The handler seeds it with eETH in
    ///         the constructor and NEVER calls a handler op pranked as it.
    ///         The probe's `eETH.shares[probe]` is therefore an invariant
    ///         constant, so `eETH.balanceOf(probe)` is a pure function of
    ///         `(totalPooledEther, totalShares)` - i.e., the rate. (F-001)
    address public immutable probeAccount;

    /// @dev EOA actors - entries 0..N_EOAS-1. The remaining slots are protocol
    ///      contracts used only as transfer destinations (never `vm.prank`'d).
    address[] public actors;
    uint256 public constant N_EOAS = 5;

    // ---- Ghost state ---------------------------------------------------------

    /// @notice (F-001) Set when ANY independent oracle observed a rate drop
    ///         across a non-exempt call. The two oracles are:
    ///         (a) `lp.amountForShare(SHARE_PROBE)` non-decreasing - this is
    ///         end-user-observable and goes through `Math.mulDiv` (different
    ///         code path from the modifier's cross-multiply).
    ///         (b) `eETH.balanceOf(probeAccount)` non-decreasing - same math
    ///         but parameterised by the probe's fixed share balance.
    ///         Both must hold; flipping either flag is a regression.
    bool public ghost_nonExemptRateDrop_viaAmountForShare;
    bool public ghost_nonExemptRateDrop_viaProbeBalance;

    /// @notice Forensic crumb on the first observed drop.
    uint256 public ghost_drop_rate0;
    uint256 public ghost_drop_rate1;
    bytes32 public ghost_drop_op;

    /// @notice (F-002) Per-op, per-selector revert counts. Read by the
    ///         invariant file to assert that critical selectors (modifier
    ///         reverts) never fire during normal-input fuzzing.
    mapping(bytes32 => mapping(bytes4 => uint256)) public revertSelectors;
    /// @notice Sum across all ops of how often the modifier itself fired.
    ///         Should be 0 in a properly-bounded sequence - its appearance
    ///         means the fuzzer found inputs that legitimately triggered
    ///         the modifier (good) OR that the modifier is misfiring (bad).
    uint256 public ghost_modifierRevertCount;
    /// @notice Same for the weETH hook.
    uint256 public ghost_weethHookRevertCount;
    /// @notice Generic Panic(...) reverts - should never fire on protocol
    ///         calls under the bounded-input regime.
    uint256 public ghost_panicRevertCount;

    /// @notice (F-011) Counts how often the bootstrap-exempt branch
    ///         (`S0 == 0 || S1 == 0`) was hit. With actor pre-seeding it
    ///         should be 0 in normal sequences; the invariant file asserts
    ///         the upper bound. A `drainToSingleDigitShares` op intentionally
    ///         drives S into the danger zone - when called, the counter
    ///         increments and the invariant tolerates it.
    uint256 public ghost_bootstrapExemptHits;
    /// @notice Independently surfaces whether the bootstrap path was hit
    ///         from a NON-drain op (i.e., a legitimate-looking handler op
    ///         that accidentally walked into S=0). This is the real bug
    ///         signal.
    bool public ghost_bootstrapExemptFromOrganicPath;

    /// @notice (F-001 forensic) The first observed call where rate0 != rate1
    ///         AND the modifier did NOT revert. Used to pin failures.
    int256 public ghost_worstWeethUnderbacking;

    /// @notice Address pool whose `eETH.shares()` the global-conservation
    ///         invariant sums.
    address[] public shareHolders;
    mapping(address => bool) public isShareHolder;

    /// @notice (F-014) Independent TVL ledger. Each handler op that moves
    ///         ETH into or out of LP updates this counter. The invariant
    ///         file asserts `lp.getTotalPooledEther() == ghost_ledgerTPE`.
    int256 public ghost_ledgerTPE;
    /// @notice Set if ledger drift detected. Forensic.
    bool public ghost_ledgerDrift;

    mapping(bytes32 => uint256) public callCounts;

    constructor(
        LiquidityPool _lp,
        EETH _eETH,
        WeETH _weETH,
        address _erm,
        address _wrn,
        address _pq,
        address _membershipManager,
        address _treasury,
        address _liquifier,             // F-009
        address _operatingMultisig      // F-018
    ) {
        lp = _lp;
        eETH = _eETH;
        weETH = _weETH;
        erm = _erm;
        wrn = _wrn;
        pq = _pq;
        membershipManager = _membershipManager;
        treasury = _treasury;
        liquifier = _liquifier;
        operatingMultisig = _operatingMultisig;
        probeAccount = _label("inv.probe");

        actors.push(_label("inv.actor.0"));
        actors.push(_label("inv.actor.1"));
        actors.push(_label("inv.actor.2"));
        actors.push(_label("inv.actor.3"));
        actors.push(_label("inv.actor.4"));

        // Protocol-address destinations (indices N_EOAS..).
        actors.push(address(_lp));
        actors.push(address(_eETH));
        actors.push(address(_weETH));
        actors.push(_erm);
        actors.push(_wrn);
        actors.push(_pq);
        actors.push(_treasury);

        // Seed each EOA actor with eETH so wrap/burn/transfer paths have
        // stock from call 1. Pre-approve weETH for the wrap path so the
        // per-call `eETH.approve` (previously outside the wrap try/catch)
        // is no longer a hidden revert surface that would skip both the
        // success counter and the revert counter.
        for (uint256 i = 0; i < N_EOAS; i++) {
            vm.deal(actors[i], 1_000 ether);
            vm.prank(actors[i]);
            lp.deposit{value: 100 ether}();
            _observeShareHolder(actors[i]);
            // Ledger: deposit adds 100 ether to TPE.
            ghost_ledgerTPE += int256(uint256(100 ether));
            // One-shot approval: weETH spends eETH for wrap. Doing this
            // here removes the approve from the per-op critical path.
            vm.prank(actors[i]);
            eETH.approve(address(weETH), type(uint256).max);
        }

        // Probe: a dedicated address holding a fixed share balance, used as
        // the (F-001) independent rate oracle. Seeded via a 50 ETH deposit
        // and NEVER touched by any handler op so its shares stay constant.
        vm.deal(probeAccount, 100 ether);
        vm.prank(probeAccount);
        lp.deposit{value: 50 ether}();
        _observeShareHolder(probeAccount);
        ghost_ledgerTPE += int256(uint256(50 ether));

        // Catalogue pre-enumeration (F-009): include Liquifier and fee
        // recipient if non-zero so the global-shares-conservation invariant
        // is resilient to future credits at those addresses.
        _observeShareHolder(address(_lp));
        _observeShareHolder(address(_eETH));
        _observeShareHolder(address(_weETH));
        _observeShareHolder(_erm);
        _observeShareHolder(_wrn);
        _observeShareHolder(_pq);
        _observeShareHolder(_membershipManager);
        _observeShareHolder(_treasury);
        if (_liquifier != address(0)) _observeShareHolder(_liquifier);
        address feeRecipient = _lp.feeRecipient();
        if (feeRecipient != address(0)) _observeShareHolder(feeRecipient);
    }

    // =====================================================================
    // Handler functions - each is a random selector for the fuzzer.
    // =====================================================================

    function depositEth(uint256 actorSeed, uint128 amount) external {
        amount = uint128(bound(uint256(amount), 1 gwei, 10_000 ether));
        address actor = _eoa(actorSeed);
        vm.deal(actor, uint256(amount));

        Snapshot memory before_ = _snap();
        vm.prank(actor);
        try lp.deposit{value: amount}() {
            _checkNonExempt("depositEth", before_, /*organicPath=*/true);
            _observeShareHolder(actor);
            ghost_ledgerTPE += int256(uint256(amount));     // F-014
            callCounts["deposit"]++;
        } catch (bytes memory err) {
            // Counter prefix MUST match the success-counter key so the
            // coverage summary `callCounts("deposit_revert")` resolves
            // to the same `_concat`-produced key.
            _recordRevert("deposit", err);
        }
    }

    /// (F-020) Wrap bound widened to [1, bal] so dust and full-balance
    /// inputs are reachable. Approval is pre-granted in the constructor
    /// so the wrap path's only revert surface is `weETH.wrap` itself,
    /// captured by the try/catch + selector counter.
    function wrap(uint256 actorSeed, uint128 amount) external {
        address actor = _eoa(actorSeed);
        uint256 bal = eETH.balanceOf(actor);
        if (bal == 0) {
            callCounts["wrap_skipped"]++;
            return;
        }
        amount = uint128(bound(uint256(amount), 1, bal));

        vm.prank(actor);
        try weETH.wrap(amount) {
            _observeShareHolder(address(weETH));
            callCounts["wrap"]++;
        } catch (bytes memory err) {
            _recordRevert("wrap", err);
        }
    }

    function unwrap(uint256 actorSeed, uint128 amount) external {
        address actor = _eoa(actorSeed);
        uint256 bal = weETH.balanceOf(actor);
        if (bal == 0) {
            callCounts["unwrap_skipped"]++;
            return;
        }
        amount = uint128(bound(uint256(amount), 1, bal));

        vm.prank(actor);
        try weETH.unwrap(amount) {
            _observeShareHolder(actor);
            callCounts["unwrap"]++;
        } catch (bytes memory err) {
            _recordRevert("unwrap", err);
        }
    }

    function burnEEthShares(uint256 callerSeed, uint128 amount) external {
        address[3] memory burners = [erm, wrn, pq];
        address caller = burners[callerSeed % 3];

        address donor = _eoa(callerSeed);
        uint256 donorBal = eETH.balanceOf(donor);
        if (donorBal > 1 ether) {
            vm.prank(donor);
            try eETH.transfer(caller, donorBal / 4) {
                _observeShareHolder(caller);
            } catch {}
        }

        uint256 callerShares = eETH.shares(caller);
        if (callerShares == 0) {
            callCounts["burn_skipped"]++;
            return;
        }
        amount = uint128(bound(uint256(amount), 1, callerShares));

        // (F-011) No longer artificially keep S1 > 0. The modifier's
        // bootstrap branch is allowed to fire; the test counts hits.
        uint256 ts = eETH.totalShares();
        if (amount >= ts) amount = uint128(ts);

        Snapshot memory before_ = _snap();
        vm.prank(caller);
        try lp.burnEEthShares(amount) {
            _checkNonExempt("burnEEthShares", before_, /*organicPath=*/true);
            callCounts["burn"]++;
        } catch (bytes memory err) {
            _recordRevert("burn", err);     // align with `callCounts["burn"]` success key
        }
    }

    function burnEEthSharesForNonETHWithdrawal(uint128 valueETH, uint128 extra) external {
        uint256 outOfLp = lp.totalValueOutOfLp();
        if (outOfLp < 1 ether) {
            vm.prank(membershipManager);
            try lp.rebase(int128(10 ether)) {
                ghost_ledgerTPE += int256(uint256(10 ether));
            } catch {
                callCounts["bForNon_skipped"]++;
                return;
            }
            outOfLp = lp.totalValueOutOfLp();
        }
        if (outOfLp == 0) {
            callCounts["bForNon_skipped"]++;
            return;
        }

        address donor = _eoa(uint256(uint160(address(this))));
        uint256 donorBal = eETH.balanceOf(donor);
        if (donorBal > 2 ether) {
            vm.prank(donor);
            try eETH.transfer(erm, donorBal / 4) {
                _observeShareHolder(erm);
            } catch {}
        }
        uint256 ermShares = eETH.shares(erm);
        if (ermShares < 2) {
            callCounts["bForNon_skipped"]++;
            return;
        }

        uint256 maxByOutOfLp = outOfLp > 1 ? outOfLp - 1 : 0;
        if (maxByOutOfLp == 0) {
            callCounts["bForNon_skipped"]++;
            return;
        }
        valueETH = uint128(bound(uint256(valueETH), 1 gwei, maxByOutOfLp));

        uint256 minShares = lp.sharesForWithdrawalAmount(valueETH);
        if (minShares == 0 || minShares >= ermShares) {
            callCounts["bForNon_skipped"]++;
            return;
        }

        uint256 cap = ermShares - 1;
        uint256 sharesToBurn = bound(uint256(extra), minShares, cap > minShares ? cap : minShares);

        uint256 ts = eETH.totalShares();
        if (sharesToBurn >= ts) sharesToBurn = ts - 1;
        if (sharesToBurn < minShares) {
            callCounts["bForNon_skipped"]++;
            return;
        }

        Snapshot memory before_ = _snap();
        vm.prank(erm);
        try lp.burnEEthSharesForNonETHWithdrawal(sharesToBurn, valueETH) {
            _checkNonExempt("bForNon", before_, /*organicPath=*/true);
            ghost_ledgerTPE -= int256(uint256(valueETH));   // F-14: ETH leaves OutOfLp accounting
            callCounts["bForNon"]++;
        } catch (bytes memory err) {
            _recordRevert("bForNon", err);
        }
    }

    /// (F-006) Default rebase magnitude is bounded by MAX_REBASE_BPS of
    /// the live `totalValueOutOfLp`. The looser stress range lives in
    /// `rebaseExtreme` so the realistic-vs-pathological coverage split
    /// is observable in the call summary.
    function rebase(int128 delta) external {
        uint256 outOfLp = uint256(lp.totalValueOutOfLp());
        int256 minD;
        int256 maxD;
        if (outOfLp == 0) {
            minD = 0;
            maxD = 1 ether;
        } else {
            uint256 cap = (outOfLp * MAX_REBASE_BPS) / BPS_DENOM;
            if (cap == 0) cap = 1;
            if (cap > uint256(uint128(type(int128).max))) cap = uint256(uint128(type(int128).max));
            minD = -int256(cap);
            maxD = int256(cap);
        }
        delta = int128(bound(int256(delta), minD, maxD));

        vm.prank(membershipManager);
        try lp.rebase(delta) {
            ghost_ledgerTPE += int256(delta);
            callCounts[delta < 0 ? bytes32("rebase_negative") : bytes32("rebase_positive")]++;
        } catch (bytes memory err) {
            _recordRevert("rebase", err);
        }
    }

    /// (F-006) Extreme stress version of rebase - preserves the original
    /// ±outOfLp/3 range so the suite still explores pathological jumps.
    /// Kept as a distinct op so its frequency is observable in the
    /// coverage summary; tune CI by limiting selector weight if needed.
    function rebaseExtreme(int128 delta) external {
        uint256 outOfLp = uint256(lp.totalValueOutOfLp());
        int256 minD;
        int256 maxD;
        if (outOfLp == 0) {
            minD = 0;
            maxD = 100 ether;
        } else {
            uint256 cap = outOfLp / 3;
            if (cap > uint256(uint128(type(int128).max))) cap = uint256(uint128(type(int128).max));
            minD = -int256(cap);
            maxD = int256(cap);
        }
        delta = int128(bound(int256(delta), minD, maxD));

        vm.prank(membershipManager);
        try lp.rebase(delta) {
            ghost_ledgerTPE += int256(delta);
            callCounts["rebaseExtreme"]++;
        } catch (bytes memory err) {
            _recordRevert("rebaseExtreme", err);
        }
    }

    function donateEEthToProxy(uint256 actorSeed, uint128 amount) external {
        address actor = _eoa(actorSeed);
        uint256 bal = eETH.balanceOf(actor);
        if (bal < 2) {
            callCounts["donate_skipped"]++;
            return;
        }
        amount = uint128(bound(uint256(amount), 1, bal / 2));
        vm.prank(actor);
        try eETH.transfer(address(weETH), amount) {
            _observeShareHolder(address(weETH));
            callCounts["donate"]++;
        } catch (bytes memory err) {
            _recordRevert("donate", err);
        }
    }

    /// (F-013) Adversarial: prove the weETH-backing hook fires on a real
    /// underbacking scenario. Atomic drain -> probe-mint -> restore so the
    /// invariant state is preserved at the end of the call.
    ///
    /// eETH.transfer takes an AMOUNT (wei) but moves SHARES (via
    /// sharesForAmount). For small amounts this rounds to 0 shares, so we
    /// drain by ~half the proxy's balance to guarantee a meaningful share
    /// motion, then verify post-drain that the proxy is actually
    /// underbacked before attempting the probe-mint. If shares didn't move
    /// (rounding edge), skip cleanly.
    ///
    /// We probe with a wrap of an amount large enough to mint at least 1
    /// share, because a wrap that mints 0 shares trivially passes the
    /// hook (supply unchanged, gap unchanged).
    function adversarial_drainHookProof(uint128 /*unused*/) external {
        uint256 supply = weETH.totalSupply();
        uint256 proxyBalance = eETH.balanceOf(address(weETH));
        uint256 proxySharesBefore = eETH.shares(address(weETH));
        // Need both supply and a meaningful proxy balance.
        if (proxyBalance < 2 ether || supply == 0 || proxySharesBefore == 0) {
            callCounts["drainProof_skipped"]++;
            return;
        }

        // Drain ~half. eETH.transfer(amount) moves sharesForAmount(amount)
        // shares; for amount = proxyBalance/2 with typical rates, this
        // moves ~proxyShares/2 shares - plenty to underback.
        uint256 drainAmount = proxyBalance / 2;
        address recipient = _label("inv.drain_sink");

        // Step 1: Drain.
        vm.prank(address(weETH));
        try eETH.transfer(recipient, drainAmount) {} catch {
            callCounts["drainProof_skipped"]++;
            return;
        }

        uint256 proxySharesAfter = eETH.shares(address(weETH));
        if (proxySharesAfter >= supply) {
            // Drain didn't underback (proxy still has enough shares). Restore
            // and bail without exercising the hook.
            vm.prank(recipient);
            try eETH.transfer(address(weETH), drainAmount) {} catch {
                ghost_drainProof_restoreFailed = true;
            }
            callCounts["drainProof_no_underback"]++;
            return;
        }

        // Step 2: Probe-mint. Use an amount large enough to mint >=1 share
        // so the hook is meaningfully exercised. amountForShare(1)+1 wei
        // guarantees sharesForAmount of that wei rounds to >= 1.
        address probeActor = _eoa(uint256(uint160(recipient)));
        // Wrap of 1 wei mints 0 shares typically, which still triggers
        // _afterTokenTransfer (mint hook fires on any _mint call) - but
        // the hook checks supply > proxyShares, and supply DID grow by 0,
        // while proxyShares grew by sharesForAmount(1) = 0 too. So the
        // gap is unchanged, and the hook trips on the pre-existing
        // underbacking we constructed via drain. Wrap of 1 wei is fine.
        if (eETH.balanceOf(probeActor) < 2) {
            // Bail and restore.
            vm.prank(recipient);
            try eETH.transfer(address(weETH), drainAmount) {} catch {
                ghost_drainProof_restoreFailed = true;
            }
            callCounts["drainProof_skipped"]++;
            return;
        }

        // probeActor is an EOA from `actors`; constructor already
        // pre-approved weETH for all such actors. No need to re-approve
        // here, which would have been an untracked revert surface.
        vm.prank(probeActor);
        bool wrapDidNotRevert = false;
        try weETH.wrap(1) {
            wrapDidNotRevert = true;
        } catch (bytes memory err) {
            bytes4 sel;
            if (err.length >= 4) assembly { sel := mload(add(err, 32)) }
            if (sel != SEL_WEETH_UNDERBACKED) {
                ghost_drainProof_unexpectedSelector = sel;
            }
        }
        if (wrapDidNotRevert) {
            ghost_drainProof_hookFailedToFire = true;
        }

        // Step 3: Restore. The wrap-success branch pulled 1 wei eETH from
        // probeActor and tried to mint - but the wrap either reverted
        // (state rolled back, eETH stays with probeActor) or succeeded
        // (eETH moved to proxy + 0 shares minted to probeActor). Restore
        // the drained amount in both cases.
        vm.prank(recipient);
        try eETH.transfer(address(weETH), drainAmount) {} catch {
            ghost_drainProof_restoreFailed = true;
        }
        callCounts["drainProof"]++;
    }
    bool public ghost_drainProof_hookFailedToFire;
    bool public ghost_drainProof_restoreFailed;
    bytes4 public ghost_drainProof_unexpectedSelector;

    /// (F-013) First-depositor share-inflation pattern. Deposit 1 wei
    /// via a fresh actor, then donate a large amount of eETH directly to
    /// the weETH proxy without minting weETH. This inflates per-share
    /// value but should NOT violate Invariant 1 (the `<=` form tolerates
    /// over-collateralization).
    function adversarial_inflateFirstShare(uint128 donateAmount) external {
        address newcomer = _label("inv.newcomer");
        if (eETH.balanceOf(newcomer) == 0) {
            vm.deal(newcomer, 1 ether);
            vm.prank(newcomer);
            try lp.deposit{value: 1}() {
                _observeShareHolder(newcomer);
                ghost_ledgerTPE += int256(uint256(1));
            } catch (bytes memory err) {
                _recordRevert("inflate", err);
                return;
            }
        }
        // Donate from any EOA with sufficient balance.
        address donor = _eoa(uint256(donateAmount));
        uint256 donorBal = eETH.balanceOf(donor);
        if (donorBal < 2) {
            callCounts["inflate_skipped"]++;
            return;
        }
        donateAmount = uint128(bound(uint256(donateAmount), 1, donorBal / 2));
        vm.prank(donor);
        try eETH.transfer(address(weETH), donateAmount) {
            _observeShareHolder(address(weETH));
            callCounts["inflate"]++;
        } catch (bytes memory err) {
            _recordRevert("inflate", err);
        }
    }

    /// (F-021) Drives `eETH.totalShares()` to a low value to stress the
    /// rate-precision regime. Burns nearly all of one caller's shares,
    /// optionally pushing into the single-digit zone. Bootstrap-exempt
    /// hits during this op are EXPECTED and counted separately (drainPath)
    /// so the invariant file can distinguish them from organic-path hits.
    function adversarial_drainToSingleDigitShares(uint256 callerSeed) external {
        address[3] memory burners = [erm, wrn, pq];
        address caller = burners[callerSeed % 3];

        // Concentrate shares on `caller` first.
        for (uint256 i = 0; i < N_EOAS; i++) {
            address a = actors[i];
            uint256 b = eETH.balanceOf(a);
            if (b > 0) {
                vm.prank(a);
                try eETH.transfer(caller, b) { _observeShareHolder(caller); } catch {}
            }
        }
        uint256 callerShares = eETH.shares(caller);
        if (callerShares < 2) {
            callCounts["drainShares_skipped"]++;
            return;
        }
        // Leave a residual (1 .. min(9, callerShares - 1)) so we explore
        // the boundary of the rate-precision regime. The cap prevents
        // underflow when callerShares is itself in the single-digit zone
        // (otherwise `callerShares - (callerSeed % 9 + 1)` could panic
        // under fail-on-revert=false, silently disabling the op).
        uint256 maxResidual = callerShares - 1;
        if (maxResidual > 9) maxResidual = 9;
        uint256 residual = (callerSeed % maxResidual) + 1;
        uint256 burnAmt = callerShares - residual;

        Snapshot memory before_ = _snap();
        vm.prank(caller);
        try lp.burnEEthShares(burnAmt) {
            _checkNonExempt("drainShares", before_, /*organicPath=*/false);
            callCounts["drainShares"]++;
        } catch (bytes memory err) {
            _recordRevert("drainShares", err);
        }
    }

    /// (F-018) Pause LP, attempt a deposit (should revert with ContractPaused),
    /// then unpause. Pranks as `operatingMultisigSigner` (alice in TestSetup).
    function pause_lp_and_attempt_deposit(uint256 actorSeed) external {
        vm.prank(address(operatingMultisig));
        try lp.pauseContract() { callCounts["pause_lp"]++; }
        catch (bytes memory err) {
            _recordRevert("pause_lp", err);
            return;
        }
        // While paused, a deposit MUST revert; selector capture records it.
        address actor = _eoa(actorSeed);
        vm.deal(actor, 1 ether);
        vm.prank(actor);
        try lp.deposit{value: 1 ether}() {
            // SUCCESS while paused = bug. Flip ghost.
            ghost_pauseBypassObserved = true;
        } catch (bytes memory err) {
            _recordRevert("pause_lp_deposit_blocked", err);
        }
        // Unpause to keep subsequent ops reachable.
        vm.prank(address(operatingMultisig));
        try lp.unPauseContract() { callCounts["unpause_lp"]++; }
        catch {}
    }
    /// (F-018) Set if a paused contract accepted a state-changing call.
    bool public ghost_pauseBypassObserved;

    function transferEEth(uint256 fromSeed, uint256 toSeed, uint128 amount) external {
        address from = _eoa(fromSeed);
        address to   = _anyHolder(toSeed);
        if (from == to) {
            callCounts["transfer_eeth_skipped"]++;
            return;
        }
        uint256 bal = eETH.balanceOf(from);
        if (bal == 0) {
            callCounts["transfer_eeth_skipped"]++;
            return;
        }
        amount = uint128(bound(uint256(amount), 1, bal));
        vm.prank(from);
        try eETH.transfer(to, amount) {
            _observeShareHolder(to);
            callCounts["transfer_eeth"]++;
        } catch (bytes memory err) {
            _recordRevert("transfer_eeth", err);
        }
    }

    function transferWeETH(uint256 fromSeed, uint256 toSeed, uint128 amount) external {
        address from = _eoa(fromSeed);
        address to   = _anyHolder(toSeed);
        if (from == to) {
            callCounts["transfer_weeth_skipped"]++;
            return;
        }
        uint256 bal = weETH.balanceOf(from);
        if (bal == 0) {
            callCounts["transfer_weeth_skipped"]++;
            return;
        }
        amount = uint128(bound(uint256(amount), 1, bal));
        vm.prank(from);
        try weETH.transfer(to, amount) {
            callCounts["transfer_weeth"]++;
        } catch (bytes memory err) {
            _recordRevert("transfer_weeth", err);
        }
    }

    /// (F-007) EXEMPT path. Drives `LP.withdraw(amount, rate)` pranked as
    /// WRN with an oracle-style rate. This is intentionally an exempt
    /// rate-deflation vector; the test is that a subsequent non-exempt op
    /// in the SAME sequence still passes its own per-call rate-monotonicity
    /// check (the deflation from the exempt path lowers (P0, S0) but the
    /// non-exempt op's (P0, S0) -> (P1, S1) delta is what matters).
    ///
    /// Pre-conditions:
    /// - WRN holds eETH shares (we donate some from an EOA).
    /// - LP has OutOfLp budget (we rebase positively if needed).
    function claimSegregated(uint128 amountSeed, uint128 rateSeed) external {
        uint256 outOfLp = lp.totalValueOutOfLp();
        if (outOfLp < 1 ether) {
            vm.prank(membershipManager);
            try lp.rebase(int128(int256(uint256(2 ether)))) {
                ghost_ledgerTPE += int256(2 ether);
            } catch { callCounts["segClaim_skipped"]++; return; }
            outOfLp = lp.totalValueOutOfLp();
        }
        // Top WRN up with shares from a random EOA.
        address donor = _eoa(uint256(amountSeed));
        uint256 donorBal = eETH.balanceOf(donor);
        if (donorBal > 1 ether) {
            vm.prank(donor);
            try eETH.transfer(wrn, donorBal / 4) { _observeShareHolder(wrn); } catch {}
        }
        uint256 wrnShares = eETH.shares(wrn);
        if (wrnShares == 0) { callCounts["segClaim_skipped"]++; return; }

        // Cap the withdraw amount by OutOfLp budget AND by wrnShares*rate.
        uint256 maxAmount = outOfLp > 1 ? outOfLp - 1 : 0;
        if (maxAmount == 0) { callCounts["segClaim_skipped"]++; return; }
        uint256 amount = bound(uint256(amountSeed), 1 gwei, maxAmount);

        // Oracle-signed rate. In production, this is bounded to
        // [minAcceptableShareRate, maxAcceptableShareRate]. Mirror that
        // by using lp.amountPerShareCeil() with ±25% slack to exercise
        // both the rate-preserving and the rate-dropping cases.
        uint256 livRate = lp.amountPerShareCeil();
        if (livRate == 0) { callCounts["segClaim_skipped"]++; return; }
        uint256 lo = (livRate * 75) / 100;
        uint256 hi = (livRate * 125) / 100;
        if (lo == 0) lo = 1;
        uint256 rate = bound(uint256(rateSeed), lo, hi);

        // Ensure burnedShares <= wrnShares.
        uint256 sharesToBurn = (amount * 1e18 + rate - 1) / rate;     // ceil
        if (sharesToBurn == 0 || sharesToBurn > wrnShares) {
            callCounts["segClaim_skipped"]++; return;
        }
        uint256 ts = eETH.totalShares();
        if (sharesToBurn >= ts) { callCounts["segClaim_skipped"]++; return; }

        // No `_checkNonExempt` here - this is the EXEMPT path.
        // Pass `_shareOfEEth = sharesToBurn` so the new guards are no-ops and the handler
        // reproduces the pre-Option-5 burn behavior exactly.
        vm.prank(wrn);
        try lp.withdraw(amount, rate, sharesToBurn) {
            ghost_ledgerTPE -= int256(amount);   // ETH leaves LP accounting
            callCounts["segClaim"]++;
        } catch (bytes memory err) {
            _recordRevert("segClaim", err);
        }
    }

    function sendRawEth(uint256 actorSeed, uint128 amount) external {
        address actor = _eoa(actorSeed);
        uint256 outOfLp = lp.totalValueOutOfLp();
        uint256 hi = outOfLp == 0 ? 1 ether : (2 * outOfLp + 1);
        amount = uint128(bound(uint256(amount), 1, hi));
        vm.deal(actor, uint256(amount));
        uint256 lpBalanceBefore = address(lp).balance;
        vm.prank(actor);
        (bool ok, ) = address(lp).call{value: amount}("");
        if (ok) {
            // F-014: `receive()` moves OutOfLp -> InLp accounting (no net TPE change).
            uint256 lpBalanceAfter = address(lp).balance;
            require(lpBalanceAfter == lpBalanceBefore + amount, "lp balance drift");
            callCounts["sendRawEth"]++;
        } else {
            callCounts["sendRawEth_revert"]++;
        }
    }

    // =====================================================================
    // Internals - snapshot, oracles, recording
    // =====================================================================

    struct Snapshot {
        uint256 rateAmountForShare;     // lp.amountForShare(SHARE_PROBE)
        uint256 probeBalance;           // eETH.balanceOf(probeAccount)
        uint256 S0;                     // eETH.totalShares()
        uint256 P0;                     // lp.getTotalPooledEther()
    }

    function _snap() internal view returns (Snapshot memory s) {
        s.P0 = lp.getTotalPooledEther();
        s.S0 = eETH.totalShares();
        s.rateAmountForShare = lp.amountForShare(SHARE_PROBE);
        s.probeBalance = eETH.balanceOf(probeAccount);
    }

    /// (F-001) Two independent rate oracles, both checked. (F-011) Bootstrap
    /// exemption is COUNTED not silently skipped, and the call's
    /// `organicPath` flag tells the invariant file whether this hit is a
    /// regression or an intentional drain-path probe.
    function _checkNonExempt(bytes32 op, Snapshot memory s0, bool organicPath) internal {
        Snapshot memory s1 = _snap();

        // Bootstrap exemption (modifier behavior): when either side has zero
        // shares, the rate is undefined. Record the hit but don't flag a drop.
        if (s0.S0 == 0 || s1.S0 == 0) {
            ghost_bootstrapExemptHits++;
            if (organicPath) ghost_bootstrapExemptFromOrganicPath = true;
            return;
        }

        // Oracle (a): amountForShare(SHARE_PROBE) non-decreasing.
        if (s1.rateAmountForShare < s0.rateAmountForShare) {
            if (!ghost_nonExemptRateDrop_viaAmountForShare) {
                ghost_drop_rate0 = s0.rateAmountForShare;
                ghost_drop_rate1 = s1.rateAmountForShare;
                ghost_drop_op = op;
            }
            ghost_nonExemptRateDrop_viaAmountForShare = true;
        }

        // Oracle (b): probe balance non-decreasing. The probe's share
        // balance is constant by construction (we never prank as it), so
        // any drop in balanceOf reflects a rate drop.
        if (s1.probeBalance < s0.probeBalance) {
            ghost_nonExemptRateDrop_viaProbeBalance = true;
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

        // Critical selectors - should NOT fire in a properly-bounded sequence.
        if (sel == SEL_EETH_RATE_DEFLATION) ghost_modifierRevertCount++;
        if (sel == SEL_WEETH_UNDERBACKED)   ghost_weethHookRevertCount++;
        if (sel == SEL_PANIC)               ghost_panicRevertCount++;
    }

    function _captureBackingGap() internal {
        int256 gap = int256(weETH.totalSupply()) - int256(eETH.shares(address(weETH)));
        if (gap > ghost_worstWeethUnderbacking) ghost_worstWeethUnderbacking = gap;
    }

    function _observeShareHolder(address who) internal {
        if (!isShareHolder[who]) {
            isShareHolder[who] = true;
            shareHolders.push(who);
        }
    }

    function observeBackingGap() external returns (int256) {
        _captureBackingGap();
        return int256(weETH.totalSupply()) - int256(eETH.shares(address(weETH)));
    }

    function _eoa(uint256 seed) internal view returns (address) {
        return actors[seed % N_EOAS];
    }

    function _anyHolder(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _label(string memory s) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(s)))));
    }

    function _concat(bytes32 a, bytes memory suffix) internal pure returns (bytes32 r) {
        // Best-effort short-string concat for callCounts keys. Truncates if too long.
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

    // Read-only helpers.
    function actorsLength() external view returns (uint256) { return actors.length; }
    function actorAt(uint256 i) external view returns (address) { return actors[i]; }
    function shareHoldersLength() external view returns (uint256) { return shareHolders.length; }
    function shareHolderAt(uint256 i) external view returns (address) { return shareHolders[i]; }

    /// (F-029) Sum eETH.shares over BOTH the dynamic shareHolders set AND
    /// the static actors pool, deduplicated. Used by the global-conservation
    /// invariant so a callback-routed credit to an unobserved actor still
    /// shows up.
    function sumSharesAcrossAllKnown() external view returns (uint256 acc) {
        uint256 sLen = shareHolders.length;
        for (uint256 i = 0; i < sLen; i++) acc += eETH.shares(shareHolders[i]);
        // Add any actor not already in shareHolders (rare since constructor
        // observes all actors, but defensive).
        uint256 aLen = actors.length;
        for (uint256 i = 0; i < aLen; i++) {
            if (!isShareHolder[actors[i]]) acc += eETH.shares(actors[i]);
        }
    }
}
