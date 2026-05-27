// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/StdUtils.sol";
import "forge-std/Vm.sol";

import "../../../src/LiquidityPool.sol";
import "../../../src/EETH.sol";
import "../../../src/WeETH.sol";

/// @notice Stateful-invariant handler for PR #428's two inlined invariants and
///         the global protocol-accounting conservation laws those two
///         invariants live on top of.
///
///         Foundry's invariant runner calls the handler's external functions
///         in random sequences (depth N, runs M). Each function takes random
///         calldata, bounds it to a workable range, picks one of a fixed
///         pool of actors, and routes a protocol operation through the live
///         contracts. After each call we snapshot the rate and, for NON-
///         exempt paths only, flag any rate drop on a ghost variable. The
///         modifier in `LiquidityPool` should already revert such drops, so
///         the flag should remain `false` for every reachable sequence — if
///         the modifier is ever broken, bypassed, or refactored to widen
///         coverage, that flag flips and the global invariant catches it.
///
///         Beyond the two PR #428 properties, the handler also tracks ghost
///         state used by global-conservation invariants in the test file:
///         a running enumeration of every address that has ever held eETH
///         shares (so the test can sum `eETH.shares(addr)` across the entire
///         live universe and compare it to `eETH.totalShares()`), and a
///         monotonically-decreasing low-water mark of `weETH.totalSupply()
///         - eETH.shares(proxy)` that detects any per-sequence underbacking
///         the per-call hook somehow lets through (it can't today, but a
///         refactor could).
///
///         The handler intentionally:
///         - Inherits StdUtils for `bound()` only — no Test base, no test-only
///           selectors (e.g. `setUp`, `excludeArtifacts`) leaking into the
///           fuzzer's selector pool.
///         - Uses a fixed actor pool keyed by seed-modulo so the fuzzer
///           reuses the same addresses across calls (encourages real state
///           accumulation per actor instead of a fresh actor every call).
///           The pool deliberately includes high-leverage protocol addresses
///           (LP itself, eETH proxy, weETH proxy, treasury) as transfer
///           DESTINATIONS so accounting paths where shares end up on those
///           contracts get exercised.
///         - Wraps every protocol call in try/catch so a single
///           legitimate-but-revertable input doesn't abort the whole run; the
///           skip/revert counters in `callCounts` make it observable.
///         - Pre-seeds each EOA actor with eETH in the constructor so wrap /
///           burn / transfer paths have non-zero stock from call 1 and the
///           bootstrap-exempt branch of `nonDecreasingRate` (S0 == 0) never
///           applies.
contract ProtocolInvariantsHandler is StdUtils {
    // ---- Cheats (hand-rolled to avoid pulling Test into the selector pool) ----
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    LiquidityPool public immutable lp;
    EETH         public immutable eETH;
    WeETH        public immutable weETH;
    address      public immutable erm;
    address      public immutable wrn;
    address      public immutable pq;
    address      public immutable membershipManager;
    address      public immutable treasury;

    /// @dev EOA actors — entries 0..N_EOAS-1. The remaining slots are protocol
    ///      contracts used only as transfer destinations (never `vm.prank`'d).
    address[] public actors;
    uint256 public constant N_EOAS = 5;

    // ---- Ghost state (read by the invariant assertions) -------------------------

    /// @notice Set to `true` the FIRST time a non-exempt path (deposit, burn)
    ///         returns successfully AND the rate decreased across the call.
    ///         Since the in-contract modifier reverts on such drops, this
    ///         flag should remain `false` for every reachable trace. If it
    ///         flips, the modifier is bypassed/buggy/refactored.
    bool public ghost_nonExemptRateDrop;

    /// @notice First (P, S) tuple where a non-exempt drop was observed — kept
    ///         as a forensic crumb so a failing invariant trace points to the
    ///         exact call rather than reporting only the final state.
    uint256 public ghost_drop_P0;
    uint256 public ghost_drop_S0;
    uint256 public ghost_drop_P1;
    uint256 public ghost_drop_S1;
    bytes32 public ghost_drop_op;

    /// @notice Ever-observed worst gap of `weETH.totalSupply()` over
    ///         `eETH.shares(proxy)`. The per-call hook reverts if this goes
    ///         positive, so the value should stay 0 across every reachable
    ///         sequence. Recorded as a separate ghost from the assertion so
    ///         a regression that lets a tiny positive drift through is still
    ///         visible in the failure trace rather than only at the end.
    int256 public ghost_worstWeethUnderbacking;

    /// @notice Address pool whose `eETH.shares()` the global-conservation
    ///         invariant sums. Populated by `_observeShareHolder` whenever a
    ///         handler call moves shares to a new address.
    address[] public shareHolders;
    mapping(address => bool) public isShareHolder;

    mapping(bytes32 => uint256) public callCounts;

    constructor(
        LiquidityPool _lp,
        EETH _eETH,
        WeETH _weETH,
        address _erm,
        address _wrn,
        address _pq,
        address _membershipManager,
        address _treasury
    ) {
        lp = _lp;
        eETH = _eETH;
        weETH = _weETH;
        erm = _erm;
        wrn = _wrn;
        pq = _pq;
        membershipManager = _membershipManager;
        treasury = _treasury;

        // ---- EOA actors (indices 0..N_EOAS-1) ----
        // Addresses are derived from labels so failing traces are readable in
        // forge output.
        actors.push(_label("inv.actor.0"));
        actors.push(_label("inv.actor.1"));
        actors.push(_label("inv.actor.2"));
        actors.push(_label("inv.actor.3"));
        actors.push(_label("inv.actor.4"));

        // ---- Protocol-address destinations (indices N_EOAS..) ----
        // These are valid eETH/weETH transfer destinations but the handler
        // MUST NOT prank as them — they have no calldata semantics for an
        // arbitrary call. The transfer ops only USE these as `to`. We pin
        // them past index N_EOAS-1 and gate prank paths on `seed % N_EOAS`.
        actors.push(address(_lp));
        actors.push(address(_eETH));
        actors.push(address(_weETH));
        actors.push(_erm);
        actors.push(_wrn);
        actors.push(_pq);
        actors.push(_treasury);

        // Seed each EOA actor with eETH so wrap/transfer/burn paths have
        // stock from call 1. Without this most early calls would be no-op
        // skips and the bootstrap-exempt branch of `nonDecreasingRate`
        // (S0 == 0) would dominate.
        for (uint256 i = 0; i < N_EOAS; i++) {
            vm.deal(actors[i], 1_000 ether);
            vm.prank(actors[i]);
            lp.deposit{value: 100 ether}();
            _observeShareHolder(actors[i]);
        }

        // Pre-enumerate the system catalogue. The existing handler ops
        // already call `_observeShareHolder` dynamically when shares move
        // to a new address, but pre-registering known protocol-side
        // share-holders here makes the global-conservation invariant
        // resilient to a future handler op that credits one of these
        // addresses but forgets the dynamic observe call — the sum would
        // still cover the new credit, surfacing a `totalShares` drift the
        // moment it happens rather than a sequence later.
        //
        // Addresses with zero shares cost nothing in the sum. Production
        // share-holders missing from this list (e.g. Liquifier, fee
        // recipient) would require constructor wiring and aren't added
        // here because the existing handler doesn't expose ops that route
        // through them; if such ops are added, extend this list in lock-
        // step.
        _observeShareHolder(address(_lp));
        _observeShareHolder(address(_eETH));
        _observeShareHolder(address(_weETH));
        _observeShareHolder(_erm);
        _observeShareHolder(_wrn);
        _observeShareHolder(_pq);
        _observeShareHolder(_membershipManager);
        _observeShareHolder(_treasury);
    }

    // =====================================================================
    // Handler functions — each one is a single random selector for the fuzzer
    // =====================================================================

    /// @notice Non-exempt: rate must not decrease.
    function depositEth(uint256 actorSeed, uint128 amount) external {
        amount = uint128(bound(uint256(amount), 1 gwei, 10_000 ether));
        address actor = _eoa(actorSeed);
        vm.deal(actor, uint256(amount));

        (uint256 P0, uint256 S0) = _snap();
        vm.prank(actor);
        try lp.deposit{value: amount}() {
            _checkNonExempt("depositEth", P0, S0);
            _observeShareHolder(actor);
            callCounts["deposit"]++;
        } catch {
            callCounts["deposit_revert"]++;
        }
    }

    /// @notice Mints weETH — exercises Invariant 1's mint-side hook.
    function wrap(uint256 actorSeed, uint128 amount) external {
        address actor = _eoa(actorSeed);
        uint256 bal = eETH.balanceOf(actor);
        if (bal < 4) {
            callCounts["wrap_skipped"]++;
            return;
        }
        amount = uint128(bound(uint256(amount), 2, bal - 1));

        vm.prank(actor);
        eETH.approve(address(weETH), type(uint256).max);
        vm.prank(actor);
        try weETH.wrap(amount) {
            _observeShareHolder(address(weETH));
            callCounts["wrap"]++;
        } catch {
            callCounts["wrap_revert"]++;
        }
    }

    /// @notice Burns weETH — exercises Invariant 1's burn-side hook.
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
        } catch {
            callCounts["unwrap_revert"]++;
        }
    }

    /// @notice Non-exempt: share-only burn from one of the three permitted
    ///         callers. Donates from a random actor to the caller first so
    ///         there's stock.
    function burnEEthShares(uint256 callerSeed, uint128 amount) external {
        address[3] memory burners = [erm, wrn, pq];
        address caller = burners[callerSeed % 3];

        // Top burner up with some shares from a random actor — keeps the
        // function reachable across long sequences.
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

        // Keep S1 > 0 so we don't fall into the bootstrap-exempt branch.
        uint256 ts = eETH.totalShares();
        if (amount >= ts) {
            amount = ts > 1 ? uint128(ts - 1) : 0;
        }
        if (amount == 0) {
            callCounts["burn_skipped"]++;
            return;
        }

        (uint256 P0, uint256 S0) = _snap();
        vm.prank(caller);
        try lp.burnEEthShares(amount) {
            _checkNonExempt("burnEEthShares", P0, S0);
            callCounts["burn"]++;
        } catch {
            callCounts["burn_revert"]++;
        }
    }

    /// @notice Non-exempt: ERM-only share burn that also accounts for ETH
    ///         leaving via the OutOfLp budget. Belt-and-suspenders path —
    ///         the function has its own `share > _amountSharesToBurn` revert
    ///         AND the `nonDecreasingRate` modifier. We feed the modifier a
    ///         valid value pair so the local check passes and the modifier
    ///         is the only remaining guard the fuzzer can probe.
    function burnEEthSharesForNonETHWithdrawal(uint128 valueETH, uint128 extra) external {
        // ERM needs to hold shares AND there must be enough OutOfLp budget
        // to subtract `valueETH` from. We get both by routing a deposit
        // through alice, transferring shares to ERM, and rebasing positively
        // to grow OutOfLp.
        uint256 outOfLp = lp.totalValueOutOfLp();
        if (outOfLp < 1 ether) {
            // Build the budget once per sequence — keeps the function reachable.
            vm.prank(membershipManager);
            try lp.rebase(int128(10 ether)) {} catch {
                callCounts["bForNon_skipped"]++;
                return;
            }
            outOfLp = lp.totalValueOutOfLp();
        }
        if (outOfLp == 0) {
            callCounts["bForNon_skipped"]++;
            return;
        }

        // Top ERM up with some shares from a random EOA so it has stock.
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

        // Bound `valueETH` so it's burnable against ERM's stock AND the
        // OutOfLp budget.
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

        // Local precondition: sharesToBurn >= minShares. We give the
        // fuzzer slack via `extra` so it can try near-boundary inputs.
        uint256 cap = ermShares - 1;
        uint256 sharesToBurn = bound(uint256(extra), minShares, cap > minShares ? cap : minShares);

        // Don't burn the entire supply.
        uint256 ts = eETH.totalShares();
        if (sharesToBurn >= ts) sharesToBurn = ts - 1;
        if (sharesToBurn < minShares) {
            callCounts["bForNon_skipped"]++;
            return;
        }

        (uint256 P0, uint256 S0) = _snap();
        vm.prank(erm);
        try lp.burnEEthSharesForNonETHWithdrawal(sharesToBurn, valueETH) {
            _checkNonExempt("bForNon", P0, S0);
            callCounts["bForNon"]++;
        } catch {
            callCounts["bForNon_revert"]++;
        }
    }

    /// @notice EXEMPT path — rate drops here are legitimate. Bounded against
    ///         the live `totalValueOutOfLp` so a negative rebase doesn't
    ///         underflow the uint128 accumulator (an LP-level revert that
    ///         has nothing to do with the invariant being tested).
    function rebase(int128 delta) external {
        uint256 outOfLp = uint256(lp.totalValueOutOfLp());

        int256 minD;
        int256 maxD;
        if (outOfLp == 0) {
            // No room to go negative without underflow; allow only positive.
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
            callCounts[delta < 0 ? bytes32("rebase_negative") : bytes32("rebase_positive")]++;
        } catch {
            callCounts["rebase_revert"]++;
        }
    }

    /// @notice Pure eETH donation to the weETH proxy. Over-collateralizes
    ///         weETH; must not violate Invariant 1.
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
        } catch {
            callCounts["donate_revert"]++;
        }
    }

    /// @notice Supply-neutral eETH transfer between any pool entries (EOAs OR
    ///         protocol contracts). Doesn't touch either invariant directly
    ///         but adds state churn — share balances move around so per-
    ///         actor wrap/burn caps shift. Including LP/eETH-proxy/weETH-
    ///         proxy/treasury as destinations forces the global
    ///         total-shares-conservation invariant to enumerate them.
    function transferEEth(uint256 fromSeed, uint256 toSeed, uint128 amount) external {
        address from = _eoa(fromSeed);          // pranked, must be EOA
        address to   = _anyHolder(toSeed);      // can be EOA or contract
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
        } catch {
            callCounts["transfer_eeth_revert"]++;
        }
    }

    /// @notice Supply-neutral weETH transfer between actors. Exercises
    ///         Invariant 1's transfer-skip branch (`_afterTokenTransfer`
    ///         early-returns when neither party is the zero address).
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
        } catch {
            callCounts["transfer_weeth_revert"]++;
        }
    }

    /// @notice Raw ETH send into LP's `receive()`. This is reachable from any
    ///         address on mainnet (no caller check) and rebalances
    ///         `totalValueOutOfLp -> totalValueInLp` — a sneaky vector for
    ///         the `totalValueOutOfLp >= msg.value` precondition. Reverts
    ///         on underflow (when `msg.value > totalValueOutOfLp`); both
    ///         outcomes are legal protocol behaviour, but the GLOBAL
    ///         conservation invariants downstream catch any accounting drift
    ///         either branch might cause.
    function sendRawEth(uint256 actorSeed, uint128 amount) external {
        address actor = _eoa(actorSeed);
        uint256 outOfLp = lp.totalValueOutOfLp();
        // Pick a value that exercises BOTH branches: ~half the time it fits
        // within the OutOfLp budget (success), ~half it exceeds (revert).
        // The fuzzer's natural distribution + `bound` over [1, 2*outOfLp+1]
        // gets us there as long as outOfLp > 0.
        uint256 hi = outOfLp == 0 ? 1 ether : (2 * outOfLp + 1);
        amount = uint128(bound(uint256(amount), 1, hi));
        vm.deal(actor, uint256(amount));
        vm.prank(actor);
        (bool ok, ) = address(lp).call{value: amount}("");
        if (ok) callCounts["sendRawEth"]++;
        else callCounts["sendRawEth_revert"]++;
    }

    // =====================================================================
    // Internals
    // =====================================================================

    function _snap() internal view returns (uint256 P, uint256 S) {
        P = lp.getTotalPooledEther();
        S = eETH.totalShares();
    }

    /// @dev For non-exempt paths only: if rate dropped across the call, record
    ///      that as a violation. Matches the exact form of the in-contract
    ///      modifier (`P1 * S0 >= P0 * S1`, bootstrap-exempt when either S=0).
    function _checkNonExempt(bytes32 op, uint256 P0, uint256 S0) internal {
        (uint256 P1, uint256 S1) = _snap();
        if (S0 == 0 || S1 == 0) return;             // bootstrap branch
        if (P1 * S0 < P0 * S1) {
            ghost_nonExemptRateDrop = true;
            ghost_drop_P0 = P0;
            ghost_drop_S0 = S0;
            ghost_drop_P1 = P1;
            ghost_drop_S1 = S1;
            ghost_drop_op = op;
        }
    }

    /// @dev Tracks every address that has held eETH shares so the
    ///      `invariant_global_total_shares_conserved` test in the invariant
    ///      file can sum `eETH.shares(addr)` across the live universe.
    function _observeShareHolder(address who) internal {
        if (!isShareHolder[who]) {
            isShareHolder[who] = true;
            shareHolders.push(who);
        }
    }

    /// @dev Read-only worst-underbacking tap; called by the invariant file.
    function observeBackingGap() external returns (int256) {
        int256 gap = int256(weETH.totalSupply()) - int256(eETH.shares(address(weETH)));
        if (gap > ghost_worstWeethUnderbacking) ghost_worstWeethUnderbacking = gap;
        return gap;
    }

    /// @dev EOA-only actor index — safe to `vm.prank` as. Modulo over N_EOAS,
    ///      not actors.length, so the protocol-contract slots at the tail
    ///      are never returned here.
    function _eoa(uint256 seed) internal view returns (address) {
        return actors[seed % N_EOAS];
    }

    /// @dev Any pool entry — EOA or protocol contract. Use for `to`/recipient
    ///      addresses only, never as a prank target.
    function _anyHolder(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Deterministic label-to-address (forge-std's makeAddr without the
    ///      Vm.label side effect, which Foundry's invariant fuzzer doesn't
    ///      need to see).
    function _label(string memory s) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(s)))));
    }

    // Read-only helpers for the invariant test to enumerate addresses.
    function actorsLength() external view returns (uint256) { return actors.length; }
    function actorAt(uint256 i) external view returns (address) { return actors[i]; }
    function shareHoldersLength() external view returns (uint256) { return shareHolders.length; }
    function shareHolderAt(uint256 i) external view returns (address) { return shareHolders[i]; }
}
