// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/StdUtils.sol";
import "forge-std/Vm.sol";

import "@etherfi/core/LiquidityPool.sol";
import "@etherfi/core/EETH.sol";
import "@etherfi/withdrawals/WithdrawRequestNFT.sol";
import "@etherfi/withdrawals/PriorityWithdrawalQueue.sol";
import "@etherfi/withdrawals/interfaces/IPriorityWithdrawalQueue.sol";

import "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Stateful-invariant handler for the WRN claim → stranded-ETH →
///         handleRemainder cycle, plus the parallel PQ cycle.
///
///         Focus: properties the existing FrozenRateWithdrawal suite does
///         NOT assert.
///
///         1. **Stranded-ETH ledger conservation.** In WRN, `_claimWithdraw`
///            decrements `ethAmountLockedForWithdrawal` by `request.amountOfEEth`
///            but pays only `amountToWithdraw = min(amountOfEEth, frozenRate
///            * shareOfEEth / 1e18)`. Under a negative rebase between finalize
///            and claim, the delta `amountOfEEth - amountToWithdraw` is
///            stranded in the WRN balance until `handleRemainder` sweeps it
///            to treasury. The handler tracks every per-claim stranded
///            delta and the cumulative-swept counter; the invariant file
///            asserts `WRN.balance - lock == cumulative_stranded - swept`.
///
///         2. **`handleRemainder` share-burn conservation.** Both WRN and
///            PQ enforce `before - sharesMoved == after` on their own
///            share balance after the burn (`InvalidEEthShares` /
///            `InvalidEEthSharesAfterRemainderHandling`). Counted ghost
///            flags trip if those reverts ever fire under bounded fuzz.
///
///         3. **Cross-contract handleRemainder rounding asymmetry tracking.**
///            WRN floors the treasury split (`mulDiv(amount, bps, 1e4)`);
///            PQ ceils it (`mulDiv(amount, bps, 1e4, Up)`). Both burn
///            `sharesForAmount(eEthAmountToBurn)` against the same LP.
///            The handler records the per-call treasury allocation from
///            both contracts under the SAME inputs (when possible) so the
///            invariant file can assert the differential is bounded.
contract WithdrawRemainderHandler is StdUtils {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 public constant N_EOAS = 5;

    /// @dev Critical-revert selectors we never expect to surface.
    bytes4 public constant SEL_INSUFFICIENT_ESCROW           = bytes4(keccak256("InsufficientEscrow()"));
    bytes4 public constant SEL_INVALID_EETH_SHARES           = bytes4(keccak256("InvalidEEthShares()"));
    bytes4 public constant SEL_INVALID_EETH_SHARES_PQ        = bytes4(keccak256("InvalidEEthSharesAfterRemainderHandling()"));
    bytes4 public constant SEL_BURN_EXCEEDS_SHARES           = bytes4(keccak256("BurnExceedsShares()"));
    bytes4 public constant SEL_PANIC                         = 0x4e487b71;

    LiquidityPool             public immutable lp;
    EETH                      public immutable eETH;
    WithdrawRequestNFT        public immutable wrn;
    PriorityWithdrawalQueue   public immutable pq;
    address                   public immutable etherFiAdminAddr;
    address                   public immutable membershipManager;
    address                   public immutable adminSigner;
    address                   public immutable housekeepingSigner;
    address                   public immutable treasury;

    address[N_EOAS] public actors;
    uint256[] public wrnTokenIds;
    /// @dev Per-tokenId requested amount, mirrored from on-chain so wrn_finalize
    ///      can size the ETH lock transfer without re-reading the struct mapping.
    mapping(uint256 => uint96) public wrnTokenAmount;
    IPriorityWithdrawalQueue.WithdrawRequest[] public pqRequests;

    // ----- Stranded-ETH ledger -------------------------------------------

    /// @notice Cumulative sum of (request.amountOfEEth - amountToWithdraw)
    ///         observed across all WRN claims. This is the "owed to
    ///         treasury via handleRemainder" running total.
    uint256 public ghost_wrnCumulativeStranded;

    /// @notice Cumulative ETH that WRN.handleRemainder has actually swept
    ///         out to treasury. Together with ghost_wrnCumulativeStranded,
    ///         it determines what WRN.balance - lock SHOULD be.
    uint256 public ghost_wrnSweptToTreasury;

    /// @notice Set if the post-claim WRN balance != lock + (cumStranded - swept).
    bool public ghost_wrnLedgerDrift;

    // ----- handleRemainder share-conservation ghosts ---------------------

    bool public ghost_wrnInvalidShares;
    bool public ghost_pqInvalidShares;
    bool public ghost_burnExceedsShares;

    /// @notice Set if `wrn.getClaimableAmount(tokenId)` diverged from the
    ///         handler's independent recomputation of
    ///         `min(amountOfEEth, mulDiv(shareOfEEth, frozenRate, 1e18))`.
    ///         A drift here means `_getClaimableAmount` (the contract-side
    ///         function the claim path also uses to size the payout) is
    ///         returning a different value from the same inputs the handler
    ///         can see externally — a serious bug in the rate-freeze logic.
    bool public ghost_getClaimableAmountDrift;
    /// @notice Forensic crumb on the first observed drift.
    uint256 public ghost_drift_independent;
    uint256 public ghost_drift_contract;
    uint256 public ghost_drift_tokenId;

    /// @notice Critical-selector counters. None should fire under bounded fuzz.
    uint256 public ghost_insufficientEscrowCount;
    uint256 public ghost_invalidEEthSharesCount;
    uint256 public ghost_invalidEEthSharesPqCount;
    uint256 public ghost_burnExceedsSharesCount;
    uint256 public ghost_panicCount;

    // ----- Cross-contract rounding-equivalence tracking ------------------

    /// @notice Per-call observation. Sum of WRN's floor-rounded treasury
    ///         allocation across all wrn_handleRemainder calls.
    uint256 public ghost_wrnTotalTreasuryFloor;
    /// @notice Sum of PQ's ceil-rounded treasury allocation across all
    ///         pq_handleRemainder calls.
    uint256 public ghost_pqTotalTreasuryCeil;
    /// @notice Total handleRemainder calls per contract, for normalization.
    uint256 public ghost_wrnRemainderCalls;
    uint256 public ghost_pqRemainderCalls;

    // ----- Coverage / forensics ------------------------------------------

    mapping(bytes32 => uint256) public callCounts;
    mapping(bytes32 => mapping(bytes4 => uint256)) public revertSelectors;

    constructor(
        LiquidityPool _lp,
        EETH _eETH,
        WithdrawRequestNFT _wrn,
        PriorityWithdrawalQueue _pq,
        address _etherFiAdmin,
        address _membershipManager,
        address _adminSigner,
        address _housekeepingSigner,
        address _treasury,
        address[N_EOAS] memory _actors
    ) {
        lp = _lp;
        eETH = _eETH;
        wrn = _wrn;
        pq = _pq;
        etherFiAdminAddr = _etherFiAdmin;
        membershipManager = _membershipManager;
        adminSigner = _adminSigner;
        housekeepingSigner = _housekeepingSigner;
        treasury = _treasury;

        for (uint256 i = 0; i < N_EOAS; i++) {
            actors[i] = _actors[i];
        }
    }

    // =====================================================================
    // WRN lifecycle
    // =====================================================================

    /// @notice Request a withdrawal from the LP, which routes through to
    ///         WRN. Records the new tokenId so downstream ops can target it.
    function wrn_request(uint256 actorSeed, uint128 amount) external {
        address actor = _eoa(actorSeed);
        uint256 actorEEth = eETH.balanceOf(actor);
        if (actorEEth < 0.01 ether) { callCounts["wrn_req_skipped"]++; return; }
        uint256 hi = actorEEth > 30 ether ? 30 ether : actorEEth;
        uint256 amt = bound(uint256(amount), 0.01 ether, hi);

        vm.prank(actor);
        try lp.requestWithdraw(actor, amt) returns (uint256 tokenId) {
            wrnTokenIds.push(tokenId);
            wrnTokenAmount[tokenId] = uint96(amt);
            callCounts["wrn_req"]++;
        } catch (bytes memory err) {
            _recordRevert("wrn_req", err);
        }
    }

    /// @notice Advance lastFinalizedRequestId AND transfer the corresponding
    ///         ETH from LP to WRN so claims can actually pay out. Mirrors
    ///         what EtherFiAdmin.executeTasks does in production: finalize +
    ///         addEthAmountLockedForWithdrawal in the same flow.
    function wrn_finalize() external {
        uint32 nextId = wrn.nextRequestId();
        uint32 lastFin = wrn.lastFinalizedRequestId();
        if (nextId == lastFin + 1) { callCounts["wrn_finalize_skipped"]++; return; }

        uint32 target = nextId - 1;
        // Sum the amountOfEEth for newly-finalized ids.
        uint256 lockAmount;
        for (uint32 id = lastFin + 1; id <= target; id++) {
            lockAmount += uint256(wrnTokenAmount[id]);
        }
        if (lockAmount > 0) {
            if (uint256(lp.totalValueInLp()) < lockAmount) {
                callCounts["wrn_finalize_no_liquidity"]++;
                return;
            }
            if (lockAmount > type(uint128).max) {
                callCounts["wrn_finalize_overflow"]++;
                return;
            }
            vm.prank(etherFiAdminAddr);
            try lp.addEthAmountLockedForWithdrawal(uint128(lockAmount)) {} catch {
                callCounts["wrn_lock_revert"]++;
                return;
            }
        }

        vm.prank(etherFiAdminAddr);
        try wrn.finalizeRequests(uint256(target)) {
            callCounts["wrn_finalize"]++;
        } catch (bytes memory err) {
            _recordRevert("wrn_finalize", err);
        }
    }

    /// @notice Claim an outstanding WRN tokenId. Updates the stranded-ETH
    ///         ledger if amountToWithdraw < request.amountOfEEth (the
    ///         negative-rebase case).
    function wrn_claim(uint256 tokenIdx) external {
        if (wrnTokenIds.length == 0) { callCounts["wrn_claim_skipped"]++; return; }
        uint256 idx = bound(tokenIdx, 0, wrnTokenIds.length - 1);
        uint256 tokenId = wrnTokenIds[idx];

        // Must be finalized and owned and valid.
        if (tokenId > wrn.lastFinalizedRequestId()) { callCounts["wrn_claim_skipped"]++; return; }
        address ownerAddr;
        try wrn.ownerOf(tokenId) returns (address o) { ownerAddr = o; } catch {
            callCounts["wrn_claim_skipped"]++; return;
        }
        if (ownerAddr == address(0)) { callCounts["wrn_claim_skipped"]++; return; }

        // Snapshot before claim to compute the per-claim stranded delta.
        IWithdrawRequestNFT.WithdrawRequest memory req = wrn.getRequest(tokenId);
        if (!req.isValid) { callCounts["wrn_claim_skipped"]++; return; }

        // (1) INDEPENDENT RECOMPUTATION OF `amountToWithdraw`. The previous
        //     version of this handler pulled the value via
        //     `wrn.getClaimableAmount(tokenId)`, which calls the SAME
        //     `_getClaimableAmount` the contract uses internally to size
        //     the payout. That made the stranded-ETH ledger an
        //     oracle-aligned tautology: any bug in `_getClaimableAmount`
        //     would be mirrored by the ghost.
        //
        //     Here we recompute the formula from first principles:
        //         amountToWithdraw = min(
        //             amountOfEEth,
        //             mulDiv(shareOfEEth, frozenRate, 1e18)
        //         )
        //     Resolving the legacy-sentinel branch (frozenRate == 0 ⇒
        //     fall back to `liquidityPool.amountPerShareCeil()`) and
        //     differentially-asserting against the contract's view.
        uint224 frozenRate = wrn.frozenRateFor(tokenId);
        if (frozenRate == 0) {
            uint256 live = lp.amountPerShareCeil();
            frozenRate = uint224(live);
        }
        uint256 independentForShares = Math.mulDiv(
            uint256(req.shareOfEEth), uint256(frozenRate), 1e18
        );
        uint256 independentAmount = independentForShares < uint256(req.amountOfEEth)
            ? independentForShares
            : uint256(req.amountOfEEth);

        // Differential check: the contract's `getClaimableAmount` MUST
        // return exactly what the independent recomputation produces. A
        // divergence here is a finding.
        uint256 contractAmount;
        try wrn.getClaimableAmount(tokenId) returns (uint256 a) { contractAmount = a; }
        catch { callCounts["wrn_claim_skipped"]++; return; }
        if (contractAmount != independentAmount) {
            ghost_getClaimableAmountDrift = true;
            ghost_drift_independent = independentAmount;
            ghost_drift_contract = contractAmount;
            ghost_drift_tokenId = tokenId;
        }

        vm.prank(ownerAddr);
        try wrn.claimWithdraw(tokenId) {
            // Per-claim stranded delta - computed from the INDEPENDENT value
            // so a buggy `_getClaimableAmount` can't hide the drift.
            uint256 strandedDelta = uint256(req.amountOfEEth) - independentAmount;
            ghost_wrnCumulativeStranded += strandedDelta;

            uint128 lockAfter = wrn.ethAmountLockedForWithdrawal();
            uint256 balAfter = address(wrn).balance;
            _assertWrnLedgerConsistency("wrn_claim", uint256(lockAfter), balAfter);

            callCounts["wrn_claim"]++;
        } catch (bytes memory err) {
            _recordRevert("wrn_claim", err);
        }
    }

    /// @notice WRN.handleRemainder sweeps stranded ETH + burns/transfers
    ///         the eETH remainder. Records the floor-rounded treasury
    ///         allocation for cross-contract comparison.
    function wrn_handleRemainder() external {
        uint256 remainderShares = wrn.totalRemainderEEthShares();
        if (remainderShares == 0) { callCounts["wrn_remainder_skipped"]++; return; }
        uint256 remainderAmount = wrn.getEEthRemainderAmount();
        if (remainderAmount == 0) { callCounts["wrn_remainder_skipped"]++; return; }

        uint256 balBefore = address(wrn).balance;
        uint128 lockBefore = wrn.ethAmountLockedForWithdrawal();
        uint256 expectedStrandedSweep = balBefore > uint256(lockBefore) ? balBefore - uint256(lockBefore) : 0;

        // Preview the treasury allocation using WRN's exact formula.
        uint16 splitBps = wrn.shareRemainderSplitToTreasuryInBps();
        uint256 previewTreasury = (remainderAmount * uint256(splitBps)) / 1e4; // floor (Math.mulDiv default)

        vm.prank(housekeepingSigner);
        try wrn.handleRemainder(remainderAmount) {
            ghost_wrnTotalTreasuryFloor += previewTreasury;
            ghost_wrnRemainderCalls++;

            // Stranded ETH should have been swept entirely.
            uint256 balAfter = address(wrn).balance;
            uint128 lockAfter = wrn.ethAmountLockedForWithdrawal();
            if (balAfter > uint256(lockAfter)) {
                // Sweep should have brought balance back down to the lock.
                ghost_wrnLedgerDrift = true;
            }
            ghost_wrnSweptToTreasury += expectedStrandedSweep;

            _assertWrnLedgerConsistency("wrn_remainder", lockAfter, balAfter);

            callCounts["wrn_remainder"]++;
        } catch (bytes memory err) {
            _recordRevert("wrn_remainder", err);
        }
    }

    // =====================================================================
    // PQ lifecycle
    // =====================================================================

    function pq_request(uint256 actorSeed, uint128 amount) external {
        address actor = _eoa(actorSeed);
        uint256 actorEEth = eETH.balanceOf(actor);
        if (actorEEth < 0.01 ether) { callCounts["pq_req_skipped"]++; return; }
        uint256 hi = actorEEth > 30 ether ? 30 ether : actorEEth;
        // PQ has MAX_AMOUNT = 1000 ether.
        if (hi > 1000 ether) hi = 1000 ether;
        uint256 amt = bound(uint256(amount), 0.01 ether, hi);
        // amountWithFee must be <= amount; allow up to 99% to leave room for fee.
        uint96 amtWithFee = uint96((amt * 99) / 100);
        if (amtWithFee == 0) { callCounts["pq_req_skipped"]++; return; }

        vm.prank(actor);
        try pq.requestWithdraw(uint96(amt), amtWithFee) returns (bytes32 reqId) {
            // Reconstruct the request struct for later ops.
            IPriorityWithdrawalQueue.WithdrawRequest memory r = IPriorityWithdrawalQueue.WithdrawRequest({
                user: actor,
                amountOfEEth: uint96(amt),
                shareOfEEth: uint96(lp.sharesForAmount(amt)),
                amountWithFee: amtWithFee,
                nonce: pq.nonce() - 1,
                creationTime: uint32(block.timestamp)
            });
            // Drift guard: if our reconstruction doesn't match the contract's
            // own keccak, skip storing (means inputs collided with the actor's
            // shares post-deposit ordering).
            if (keccak256(abi.encode(r)) == reqId) {
                pqRequests.push(r);
            }
            callCounts["pq_req"]++;
        } catch (bytes memory err) {
            _recordRevert("pq_req", err);
        }
    }

    function pq_fulfill(uint256 reqIdx) external {
        if (pqRequests.length == 0) { callCounts["pq_fulfill_skipped"]++; return; }
        uint256 idx = bound(reqIdx, 0, pqRequests.length - 1);
        IPriorityWithdrawalQueue.WithdrawRequest memory r = pqRequests[idx];
        bytes32 id = keccak256(abi.encode(r));
        if (!pq.requestExists(id) || pq.isFinalized(id)) {
            callCounts["pq_fulfill_skipped"]++; return;
        }
        // Advance time past minDelay.
        if (block.timestamp < uint256(r.creationTime) + uint256(pq.minDelay())) {
            vm.warp(uint256(r.creationTime) + uint256(pq.minDelay()) + 1);
        }
        IPriorityWithdrawalQueue.WithdrawRequest[] memory reqs = new IPriorityWithdrawalQueue.WithdrawRequest[](1);
        reqs[0] = r;
        vm.prank(adminSigner);
        try pq.fulfillRequests(reqs) {
            callCounts["pq_fulfill"]++;
        } catch (bytes memory err) {
            _recordRevert("pq_fulfill", err);
        }
    }

    function pq_claim(uint256 reqIdx) external {
        if (pqRequests.length == 0) { callCounts["pq_claim_skipped"]++; return; }
        uint256 idx = bound(reqIdx, 0, pqRequests.length - 1);
        IPriorityWithdrawalQueue.WithdrawRequest memory r = pqRequests[idx];
        bytes32 id = keccak256(abi.encode(r));
        if (!pq.isFinalized(id)) { callCounts["pq_claim_skipped"]++; return; }
        if (block.timestamp < uint256(r.creationTime) + uint256(pq.minDelay())) {
            vm.warp(uint256(r.creationTime) + uint256(pq.minDelay()) + 1);
        }
        // Pre-flight guards against panics from edge-case state after
        // negative rebases. _claimWithdraw uses both `amountForShare(shareOfEEth)`
        // (via the tolerance check) and `amountPerShareCeil()` (as the rate
        // for `lp.withdraw`). Skip cleanly if either preview would force the
        // claim into a non-graceful path.
        if (eETH.totalShares() == 0) { callCounts["pq_claim_skipped"]++; return; }
        uint256 ratePreview = lp.amountPerShareCeil();
        if (ratePreview == 0) { callCounts["pq_claim_skipped"]++; return; }
        uint256 forSharesPreview = lp.amountForShare(uint256(r.shareOfEEth));
        // Tolerance check in PQ._claimWithdraw: `amountForShares + 10 < amountWithFee` reverts.
        if (forSharesPreview + 10 < uint256(r.amountWithFee)) {
            callCounts["pq_claim_skipped"]++;
            return;
        }
        // Escrow check: PQ.balance must cover amountToWithdraw at claim time.
        if (address(pq).balance < uint256(r.amountWithFee)) {
            callCounts["pq_claim_skipped"]++;
            return;
        }

        vm.prank(r.user);
        try pq.claimWithdraw(r) {
            callCounts["pq_claim"]++;
        } catch (bytes memory err) {
            _recordRevert("pq_claim", err);
        }
    }

    /// @notice PQ.handleRemainder. Records the ceil-rounded treasury
    ///         allocation for cross-contract comparison vs WRN.
    function pq_handleRemainder() external {
        uint96 rs = pq.totalRemainderShares();
        if (rs == 0) { callCounts["pq_remainder_skipped"]++; return; }
        uint256 amt = lp.amountForShare(rs);
        if (amt == 0) { callCounts["pq_remainder_skipped"]++; return; }

        // Preview ceil-rounded treasury allocation.
        uint16 splitBps = pq.shareRemainderSplitToTreasuryInBps();
        // ceil(amount * bps / 1e4) = (amount * bps + 1e4 - 1) / 1e4
        uint256 previewTreasury = (amt * uint256(splitBps) + 1e4 - 1) / 1e4;

        vm.prank(housekeepingSigner);
        try pq.handleRemainder(amt) {
            ghost_pqTotalTreasuryCeil += previewTreasury;
            ghost_pqRemainderCalls++;
            callCounts["pq_remainder"]++;
        } catch (bytes memory err) {
            _recordRevert("pq_remainder", err);
        }
    }

    // =====================================================================
    // STRESS - rebases, time
    // =====================================================================

    /// @notice Negative rebases drive the stranded-ETH delta. Bounded such
    ///         that `outOfLp - |delta| >= WRN.lock + PQ.lock`. This keeps
    ///         the LP's `totalValueOutOfLp -= _amount` decrement inside
    ///         `lp.withdraw` from underflowing when a claim later pays out
    ///         from the segregated escrow.
    ///
    ///         (The protocol-level interaction — that LP.rebase can reduce
    ///         outOfLp without coordinating with the WRN/PQ lock counters
    ///         and so can leave a claim's `lp.withdraw` call underflowing
    ///         when outOfLp < amountToWithdraw — is a real architectural
    ///         "smell" the reviewer flagged. The bound here keeps it out
    ///         of THIS suite so the stranded-ETH ledger property can be
    ///         observed independently; the smell itself wants its own
    ///         dedicated test, probably as a unit test that constructs
    ///         the exact failure sequence.)
    function lp_rebase_negative(uint128 deltaSeed) external {
        uint256 outOfLp = uint256(lp.totalValueOutOfLp());
        uint256 locks = uint256(wrn.ethAmountLockedForWithdrawal())
                      + uint256(pq.ethAmountLockedForPriorityWithdrawal());
        if (outOfLp <= locks) { callCounts["rebase_skipped"]++; return; }
        uint256 headroom = outOfLp - locks;
        uint256 cap = headroom / 2; // leave a margin
        if (cap == 0) { callCounts["rebase_skipped"]++; return; }
        if (cap > uint256(uint128(type(int128).max))) cap = uint256(uint128(type(int128).max));
        int128 delta = -int128(int256(bound(uint256(deltaSeed), 1, cap)));

        vm.prank(membershipManager);
        try lp.rebase(delta) {
            callCounts["rebase_negative"]++;
        } catch (bytes memory err) {
            _recordRevert("rebase", err);
        }
    }

    /// @notice Positive rebases — keeps the rate in the acceptable band.
    function lp_rebase_positive(uint128 deltaSeed) external {
        uint256 outOfLp = uint256(lp.totalValueOutOfLp());
        uint256 cap = outOfLp == 0 ? 1 ether : (outOfLp * 50) / 1e4;
        if (cap == 0) cap = 1;
        if (cap > uint256(uint128(type(int128).max))) cap = uint256(uint128(type(int128).max));
        int128 delta = int128(int256(bound(uint256(deltaSeed), 0, cap)));

        vm.prank(membershipManager);
        try lp.rebase(delta) {
            callCounts["rebase_positive"]++;
        } catch (bytes memory err) {
            _recordRevert("rebase", err);
        }
    }

    function advance_time(uint16 secondsSeed) external {
        uint256 dt = bound(uint256(secondsSeed), 1, 600);
        vm.warp(block.timestamp + dt);
        callCounts["advance_time"]++;
    }

    // =====================================================================
    // INTERNALS
    // =====================================================================

    /// @notice Asserts the WRN ledger identity:
    ///         WRN.balance == lock + (ghost_wrnCumulativeStranded - ghost_wrnSweptToTreasury)
    ///         post-op, modulo a small ceiling-vs-floor wei from the share
    ///         math. We tolerate a 1-wei slack.
    function _assertWrnLedgerConsistency(bytes32 op, uint256 lock, uint256 bal) internal {
        uint256 expectedExtra = ghost_wrnCumulativeStranded - ghost_wrnSweptToTreasury;
        uint256 actualExtra = bal > lock ? bal - lock : 0;
        // 2-wei slack: ceil rate at finalize + floor at claim can shift the
        // stranded estimate by 1 wei in each direction.
        if (actualExtra + 2 < expectedExtra || expectedExtra + 2 < actualExtra) {
            ghost_wrnLedgerDrift = true;
        }
        // Lock must always be backed.
        if (bal < lock) {
            ghost_wrnLedgerDrift = true;
        }
    }

    function _recordRevert(bytes32 op, bytes memory err) internal {
        bytes4 sel;
        if (err.length >= 4) {
            assembly { sel := mload(add(err, 32)) }
        }
        revertSelectors[op][sel]++;
        callCounts[_concat(op, "_revert")]++;

        if (sel == SEL_INSUFFICIENT_ESCROW)        ghost_insufficientEscrowCount++;
        if (sel == SEL_INVALID_EETH_SHARES)        { ghost_invalidEEthSharesCount++; ghost_wrnInvalidShares = true; }
        if (sel == SEL_INVALID_EETH_SHARES_PQ)     { ghost_invalidEEthSharesPqCount++; ghost_pqInvalidShares = true; }
        if (sel == SEL_BURN_EXCEEDS_SHARES)        { ghost_burnExceedsSharesCount++; ghost_burnExceedsShares = true; }
        if (sel == SEL_PANIC)                      ghost_panicCount++;
    }

    function _eoa(uint256 seed) internal view returns (address) {
        return actors[seed % N_EOAS];
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

    // ----- view helpers ---------------------------------------------------

    function wrnTokenIdsLength() external view returns (uint256) { return wrnTokenIds.length; }
    function pqRequestsLength() external view returns (uint256) { return pqRequests.length; }
}
