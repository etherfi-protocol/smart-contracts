// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/StdUtils.sol";
import "forge-std/Vm.sol";

import "@etherfi/rewards/CumulativeMerkleRewardsDistributor.sol";

/// @notice Stateful-invariant handler (fuzz target) for
///         CumulativeMerkleRewardsDistributor. It drives the full lifecycle
///         (set pending root -> finalize after delay -> claim) and maintains
///         independent ghost state used to prove two invariants:
///
///         I12 - cumulative-claim monotonicity & no double-pay.
///               `cumulativeClaimed[token][account]` must be non-decreasing,
///               and the ETH actually delivered to an account over a run must
///               equal `final cumulativeClaimed - initial`. Claimant accounts
///               are dedicated fresh EOAs that NEVER spend, so their on-chain
///               `balance` is an independent oracle for "ETH actually paid".
///
///         I13 - reward-root finalization delay. A pending merkle root cannot
///               become the claimable root until at least `claimDelay` has
///               elapsed since `setPendingMerkleRoot`. The handler reads the
///               on-chain delay predicate before each finalize attempt and
///               flips a ghost if a finalize ever SUCCEEDS while the delay was
///               not yet satisfied.
///
///         Privileged calls (setPendingMerkleRoot / finalizeMerkleRoot are
///         onlyExecutorOperations; setClaimDelay / updateWhitelistedRecipient
///         are onlyAdmin == onlyOperatingTimelock) are pranked as `admin`,
///         which holds BOTH EXECUTOR_OPERATIONS_ROLE and OPERATION_TIMELOCK_ROLE
///         in TestSetup. `claim` is permissionless.
contract RewardsDistributorHandler is StdUtils {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    CumulativeMerkleRewardsDistributor public immutable dist;
    address public immutable admin;
    address public immutable token; // ETH_ADDRESS

    bytes4 internal constant SEL_INSUFFICIENT_DELAY = bytes4(keccak256("InsufficentDelay()"));

    // Dedicated claimant accounts (fresh EOAs that only ever RECEIVE ETH).
    // Four are needed so the S2 scenario can build a REAL 4-leaf Merkle tree
    // (each claimant is one leaf) and have multiple users claim with genuine
    // 2-element proofs.
    address[] public claimants;
    uint256 public constant N_CLAIMANTS = 4;

    // ---- Ghost state --------------------------------------------------------

    // I12 ghosts
    mapping(address => uint256) public lastSeenCumulative; // per claimant
    mapping(address => uint256) public ghostPaid;          // per claimant, summed (cum - preclaimed)
    bool public ghost_monotonicViolated;
    bool public ghost_doublePayViolated;

    // I13 ghosts
    uint256 public ghost_pendingSetAt;   // block.timestamp at last setPendingMerkleRoot
    bytes32 public ghost_pendingRoot;    // root last set pending
    bool public ghost_hasPending;
    // Independent mirror of the contract's claimDelay. Seeded from the contract
    // once in the constructor (initial config, not the runtime predicate) and
    // updated on every successful setClaimDelay, so doFinalize can recompute the
    // delay predicate WITHOUT reading the contract's own storage (which would
    // mirror a bug instead of catching it — see doFinalize).
    uint256 public ghost_claimDelay;
    bool public ghost_finalizeDelayViolated; // finalize succeeded while delay not met
    bool public ghost_finalizeRootMismatch;  // claimable root != recorded pending root after finalize
    bool public ghost_boundaryRejectedAtDelay; // finalize reverted InsufficentDelay AT setAt + delay (too strict)

    // S2 (merkle-proof) ghosts
    bool public ghost_validProofRejected; // a claim with a genuine, in-tree proof reverted
    bool public ghost_badProofAccepted;   // a claim with a proof for the wrong leaf/amount succeeded

    mapping(bytes32 => uint256) public callCounts;

    constructor(CumulativeMerkleRewardsDistributor _dist, address _admin) {
        dist = _dist;
        admin = _admin;
        token = _dist.ETH_ADDRESS();
        // Seed the independent delay oracle from the contract's initial config.
        ghost_claimDelay = _dist.claimDelay();

        for (uint256 i = 0; i < N_CLAIMANTS; i++) {
            address c = address(uint160(uint256(keccak256(abi.encodePacked("rd.claimant", i)))));
            claimants.push(c);
            // Whitelist via admin (onlyAdmin).
            vm.prank(admin);
            dist.updateWhitelistedRecipient(c, true);
        }
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    function _claimant(uint256 seed) internal view returns (address) {
        return claimants[seed % claimants.length];
    }

    /// @dev Establish a finalized claimable root deterministically: set it
    ///      pending, warp past the (current) claimDelay, then finalize. Used by
    ///      the claim path so claims succeed without building real trees.
    function _establishRoot(bytes32 root) internal {
        vm.prank(admin);
        dist.setPendingMerkleRoot(token, root);
        ghost_pendingSetAt = block.timestamp;
        ghost_pendingRoot = root;
        ghost_hasPending = true;

        uint256 delay = dist.claimDelay();
        vm.warp(block.timestamp + delay + 1);

        vm.prank(admin);
        dist.finalizeMerkleRoot(token, block.number);
        callCounts["finalize_ok"]++;
        // Post-finalize: claimable root must equal what we set pending.
        if (dist.claimableMerkleRoots(token) != root) ghost_finalizeRootMismatch = true;
        ghost_hasPending = false;
    }

    // =====================================================================
    // Fuzz actions
    // =====================================================================

    /// @notice Set a fresh pending merkle root (I13 setup).
    function doSetPendingRoot(uint256 rootSeed) external {
        bytes32 root = keccak256(abi.encodePacked("rd.root", rootSeed, block.timestamp));
        vm.prank(admin);
        try dist.setPendingMerkleRoot(token, root) {
            ghost_pendingSetAt = block.timestamp;
            ghost_pendingRoot = root;
            ghost_hasPending = true;
            callCounts["setPending"]++;
        } catch {
            callCounts["setPending_revert"]++;
        }
    }

    /// @notice Attempt to finalize the pending root at the current time. This
    ///         is the core I13 probe: a finalize that SUCCEEDS while the
    ///         on-chain delay predicate is unmet is a violation.
    function doFinalize(uint256 /*blockSeed*/) external {
        // Independent recomputation of the contract's delay predicate from the
        // handler's OWN ghost state — the timestamp we recorded when WE set the
        // root pending (ghost_pendingSetAt) and our mirror of the delay
        // (ghost_claimDelay), NOT the contract's lastPendingMerkleUpdatedToTimestamp
        // / claimDelay storage. Reading the contract's storage back would mirror a
        // bug that corrupted those fields instead of catching it. The assertion is
        // gated on ghost_hasPending: only a FRESH pending root has a delay window to
        // validate; re-finalizing when nothing new is pending makes no new root
        // claimable and has no transition to check.
        bool hadPending = ghost_hasPending;
        bool delayMet = block.timestamp >= ghost_pendingSetAt + ghost_claimDelay;
        bytes32 expectedRoot = ghost_pendingRoot;

        vm.prank(admin);
        try dist.finalizeMerkleRoot(token, block.number) {
            if (hadPending) {
                // Finalize of a fresh pending root succeeded. The delay MUST have
                // been satisfied, and the new claimable root MUST equal the root we
                // recorded as pending.
                if (!delayMet) ghost_finalizeDelayViolated = true;
                if (dist.claimableMerkleRoots(token) != expectedRoot) ghost_finalizeRootMismatch = true;
            }
            ghost_hasPending = false;
            callCounts["finalize_ok"]++;
        } catch (bytes memory err) {
            bytes4 sel;
            if (err.length >= 4) {
                sel = bytes4(err);
            }
            if (sel == SEL_INSUFFICIENT_DELAY) {
                callCounts["finalize_delay_revert"]++;
            } else {
                callCounts["finalize_other_revert"]++;
            }
        }
    }

    /// @notice Full deterministic claim: establish a single-leaf root for the
    ///         chosen claimant at a strictly higher cumulative amount, then
    ///         claim. Proves I12 monotonicity + exact payout. Self-contained: a
    ///         SINGLE call drives the entire lifecycle (setPending -> finalize
    ///         after delay -> claim -> replay-rejected), so the suite is
    ///         non-vacuous even on a 1-call sequence (Foundry shrinks a failing
    ///         run to its minimal subsequence and re-evaluates afterInvariant on
    ///         that replay; a self-contained action keeps the non-vacuity gates
    ///         satisfiable there).
    function doClaim(uint256 acctSeed, uint128 amt) external {
        address account = _claimant(acctSeed);
        uint256 preCum = dist.cumulativeClaimed(token, account);
        uint256 delta = bound(uint256(amt), 1, 50 ether);
        uint256 newCum = preCum + delta;

        // Single-leaf tree: root == leaf, proof is empty.
        bytes32 leaf = keccak256(abi.encodePacked(account, newCum));
        _establishRoot(leaf);

        uint256 preBal = account.balance;
        bytes32[] memory proof = new bytes32[](0);

        try dist.claim(token, account, newCum, leaf, proof) {
            uint256 postCum = dist.cumulativeClaimed(token, account);
            uint256 postBal = account.balance;

            // I12: monotonic non-decrease.
            if (postCum < preCum) ghost_monotonicViolated = true;
            // I12: cumulative advanced to exactly the claimed amount.
            if (postCum != newCum) ghost_doublePayViolated = true;
            // I12: ETH actually delivered == (postCum - preCum), no double pay.
            if (postBal - preBal != postCum - preCum) ghost_doublePayViolated = true;

            ghostPaid[account] += (postCum - preCum);
            lastSeenCumulative[account] = postCum;
            callCounts["claim_ok"]++;

            // Inline replay against the SAME (already-claimed) cumulative: must
            // revert (NothingToClaim). Doing it here makes a single doClaim call
            // exercise finalize + claim + replay-rejection together, so the
            // non-vacuity gates hold even under sequence shrinking.
            uint256 preBalReplay = account.balance;
            try dist.claim(token, account, newCum, leaf, proof) {
                // A successful replay at an equal cumulative is a double-pay.
                ghost_doublePayViolated = true;
                if (account.balance != preBalReplay) ghost_doublePayViolated = true;
                callCounts["replay_unexpected_ok"]++;
            } catch {
                callCounts["replay_revert"]++;
            }
        } catch {
            callCounts["claim_revert"]++;
        }
    }

    /// @notice (I12, monotonic-decrease guard) Attempt to claim a STRICTLY
    ///         LOWER cumulative than already recorded. The contract rejects this
    ///         at CumulativeMerkleRewardsDistributor.sol:113
    ///         (`if (preclaimed >= cumulativeAmount) revert NothingToClaim()`).
    ///         If such a claim ever SUCCEEDS or moves ETH, the monotonic
    ///         guarantee is broken -> trip ghost_monotonicViolated. Self-contained
    ///         (establishes its own root) so it survives sequence-shrinking.
    function doLowerCumulativeClaim(uint256 acctSeed, uint256 dropSeed) external {
        address account = _claimant(acctSeed);

        // Self-contained: first ensure this account has a NON-ZERO cumulative by
        // performing a real claim (establish root -> claim). This makes a SINGLE
        // doLowerCumulativeClaim call drive the whole guard exercise, so the
        // non-vacuity gate survives Foundry sequence-shrinking (a shrunk 1-call
        // replay would otherwise skip on cum==0 and leave lower_rejected at 0).
        uint256 cum = dist.cumulativeClaimed(token, account);
        if (cum == 0) {
            uint256 seed = bound(dropSeed, 1, 50 ether);
            bytes32 bootLeaf = keccak256(abi.encodePacked(account, seed));
            _establishRoot(bootLeaf);
            bytes32[] memory bootProof = new bytes32[](0);
            try dist.claim(token, account, seed, bootLeaf, bootProof) {
                ghostPaid[account] += seed;
                lastSeenCumulative[account] = seed;
                cum = seed;
                callCounts["claim_ok"]++;
            } catch {
                callCounts["lower_boot_failed"]++;
                return;
            }
        }

        // Strictly-lower target in [0, cum-1].
        uint256 lower = bound(dropSeed, 0, cum - 1);
        bytes32 leaf = keccak256(abi.encodePacked(account, lower));
        _establishRoot(leaf);

        uint256 preBal = account.balance;
        bytes32[] memory proof = new bytes32[](0);
        try dist.claim(token, account, lower, leaf, proof) {
            // MUST be unreachable: preclaimed (cum) >= lower by construction.
            ghost_monotonicViolated = true;
            if (account.balance != preBal) ghost_doublePayViolated = true;
            callCounts["lower_unexpected_ok"]++;
        } catch {
            callCounts["lower_rejected"]++;
        }
    }

    /// @notice Attempt to replay the exact same cumulative amount: must revert
    ///         (NothingToClaim). If it ever succeeds, that is a double-pay.
    function doReplayClaim(uint256 acctSeed) external {
        address account = _claimant(acctSeed);
        uint256 cum = dist.cumulativeClaimed(token, account);
        if (cum == 0) {
            callCounts["replay_skipped"]++;
            return;
        }
        // Build & finalize a root for the already-claimed cumulative value.
        bytes32 leaf = keccak256(abi.encodePacked(account, cum));
        _establishRoot(leaf);

        uint256 preBal = account.balance;
        bytes32[] memory proof = new bytes32[](0);
        try dist.claim(token, account, cum, leaf, proof) {
            // A successful replay at an equal cumulative is a double-pay.
            ghost_doublePayViolated = true;
            if (account.balance != preBal) ghost_doublePayViolated = true;
            callCounts["replay_unexpected_ok"]++;
        } catch {
            callCounts["replay_revert"]++;
        }
    }

    /// @notice (S1, I13 delay boundary) Deterministic two-sided probe of the
    ///         finalization-delay boundary. Sets a fresh pending root, then:
    ///           - warps to EXACTLY setAt + delay - 1 and asserts finalize
    ///             reverts InsufficentDelay (one second too early),
    ///           - warps +1s to setAt + delay and asserts finalize SUCCEEDS.
    ///         Positively drives both edges of the `block.timestamp >= setAt +
    ///         claimDelay` predicate rather than relying on the fuzzer to land on
    ///         the exact second. Self-contained (its own setPending -> finalize),
    ///         so it survives Foundry sequence-shrinking. Uses ghost_claimDelay
    ///         (the independent delay mirror), which equals the live claimDelay
    ///         here since we do not change the delay between setPending and
    ///         finalize.
    function doDelayBoundaryProbe(uint256 rootSeed) external {
        uint256 delay = ghost_claimDelay;
        bytes32 root = keccak256(abi.encodePacked("rd.boundary", rootSeed, block.timestamp));

        vm.prank(admin);
        dist.setPendingMerkleRoot(token, root);
        uint256 setAt = block.timestamp;
        ghost_pendingSetAt = setAt;
        ghost_pendingRoot = root;
        ghost_hasPending = true;

        // Negative edge: one second before the boundary, finalize MUST revert
        // InsufficentDelay. (When delay == 0 there is no "before"; skip it.)
        if (delay > 0) {
            vm.warp(setAt + delay - 1);
            vm.prank(admin);
            try dist.finalizeMerkleRoot(token, block.number) {
                // Finalized strictly before the delay elapsed -> I13 violation.
                ghost_finalizeDelayViolated = true;
                ghost_hasPending = false;
                callCounts["boundary_early_ok"]++;
            } catch (bytes memory err) {
                bytes4 sel = err.length >= 4 ? bytes4(err) : bytes4(0);
                if (sel == SEL_INSUFFICIENT_DELAY) {
                    callCounts["boundary_early_rejected"]++;
                } else {
                    callCounts["boundary_early_other_revert"]++;
                }
            }
        }

        // Positive edge: exactly at the boundary, finalize MUST succeed.
        vm.warp(setAt + delay);
        vm.prank(admin);
        try dist.finalizeMerkleRoot(token, block.number) {
            if (dist.claimableMerkleRoots(token) != root) ghost_finalizeRootMismatch = true;
            ghost_hasPending = false;
            callCounts["boundary_at_ok"]++;
            callCounts["finalize_ok"]++; // also counts toward the I13 non-vacuity gate
        } catch (bytes memory err) {
            bytes4 sel = err.length >= 4 ? bytes4(err) : bytes4(0);
            if (sel == SEL_INSUFFICIENT_DELAY) {
                // Rejected AT the boundary though the delay had elapsed -> the
                // delay guard is too strict (an I13 liveness break).
                ghost_boundaryRejectedAtDelay = true;
                callCounts["boundary_at_rejected"]++;
            } else {
                callCounts["boundary_at_other_revert"]++;
            }
        }
    }

    /// @notice (S2, merkle proofs) Build a REAL 4-leaf Merkle tree over the four
    ///         claimants — each at a strictly-higher cumulative than recorded —
    ///         finalize its root, then have every claimant claim with a genuine
    ///         2-element proof. This is the ONLY scenario that exercises
    ///         `_verifyAsm`'s hashing loop (the single-leaf scenarios pass an
    ///         empty proof, so the loop never iterates). Leaf and internal-node
    ///         hashing replicate the contract EXACTLY: leaf =
    ///         keccak256(abi.encodePacked(account, cumulativeAmount)) (claim
    ///         L142) and internal nodes are the sorted-pair keccak that
    ///         `_verifyAsm` computes (L204-214), i.e. OZ's commutative
    ///         MerkleProof hashing. Also feeds a proof for the WRONG amount and
    ///         asserts it is rejected (InvalidProof). Self-contained, so it
    ///         survives sequence-shrinking.
    function doMerkleTreeClaim(uint256 seed) external {
        // Four distinct leaves, one per claimant, each at pre + delta.
        address[4] memory accts;
        uint256[4] memory cum;
        bytes32[4] memory leaf;
        for (uint256 i = 0; i < 4; i++) {
            address a = claimants[i];
            uint256 pre = dist.cumulativeClaimed(token, a);
            uint256 delta = bound(
                uint256(keccak256(abi.encodePacked("rd.tree.delta", seed, i))),
                1,
                20 ether
            );
            accts[i] = a;
            cum[i] = pre + delta;
            leaf[i] = keccak256(abi.encodePacked(a, cum[i]));
        }

        // Level 1 then root, using the contract's sorted-pair hashing.
        bytes32 n01 = _hashPair(leaf[0], leaf[1]);
        bytes32 n23 = _hashPair(leaf[2], leaf[3]);
        bytes32 root = _hashPair(n01, n23);

        // Genuine 2-element proofs (sibling leaf, then the opposite subtree node).
        bytes32[][4] memory proofs;
        proofs[0] = new bytes32[](2); proofs[0][0] = leaf[1]; proofs[0][1] = n23;
        proofs[1] = new bytes32[](2); proofs[1][0] = leaf[0]; proofs[1][1] = n23;
        proofs[2] = new bytes32[](2); proofs[2][0] = leaf[3]; proofs[2][1] = n01;
        proofs[3] = new bytes32[](2); proofs[3][0] = leaf[2]; proofs[3][1] = n01;

        _establishRoot(root);

        // Negative case FIRST (state still clean): claimant[0]'s real proof but a
        // TAMPERED amount. The recomputed leaf != leaf[0], so `_verifyAsm` yields
        // the wrong root -> InvalidProof. The proof check (claim L143) precedes
        // the NothingToClaim check (L147), so cum[0]+1 > preclaimed is irrelevant.
        {
            uint256 preBal = accts[0].balance;
            try dist.claim(token, accts[0], cum[0] + 1, root, proofs[0]) {
                ghost_badProofAccepted = true;
                if (accts[0].balance != preBal) ghost_doublePayViolated = true;
                callCounts["tree_proof_unexpected_ok"]++;
            } catch {
                callCounts["tree_proof_rejected"]++;
            }
        }

        // Positive case: every claimant claims with its genuine proof. Each must
        // succeed, advance cumulative to exactly cum[i], and pay exactly the delta.
        for (uint256 i = 0; i < 4; i++) {
            uint256 preCum = dist.cumulativeClaimed(token, accts[i]);
            uint256 preBal = accts[i].balance;
            try dist.claim(token, accts[i], cum[i], root, proofs[i]) {
                uint256 postCum = dist.cumulativeClaimed(token, accts[i]);
                uint256 postBal = accts[i].balance;
                if (postCum < preCum) ghost_monotonicViolated = true;
                if (postCum != cum[i]) ghost_doublePayViolated = true;
                if (postBal - preBal != postCum - preCum) ghost_doublePayViolated = true;

                ghostPaid[accts[i]] += (postCum - preCum);
                lastSeenCumulative[accts[i]] = postCum;
                callCounts["tree_claim_ok"]++;
                callCounts["claim_ok"]++; // also counts toward the I12 non-vacuity gate
            } catch {
                // A genuine, in-tree proof at a strictly-higher cumulative MUST
                // settle. A revert here means valid-proof verification failed.
                ghost_validProofRejected = true;
                callCounts["tree_claim_revert"]++;
            }
        }
    }

    /// @dev Sorted-pair keccak, matching `_verifyAsm`'s node combination
    ///      (keccak of the smaller value concatenated with the larger).
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b
            ? keccak256(abi.encodePacked(a, b))
            : keccak256(abi.encodePacked(b, a));
    }

    function doSetClaimDelay(uint256 d) external {
        uint256 nd = bound(d, 0, 7 days);
        vm.prank(admin);
        try dist.setClaimDelay(nd) {
            ghost_claimDelay = nd; // keep the independent delay oracle in sync
            callCounts["setClaimDelay"]++;
        } catch {
            callCounts["setClaimDelay_revert"]++;
        }
    }

    function doWarp(uint256 seconds_) external {
        uint256 s = bound(seconds_, 1, 5 days);
        vm.warp(block.timestamp + s);
        callCounts["warp"]++;
    }

    function doRoll(uint256 blocks_) external {
        uint256 b = bound(blocks_, 1, 1000);
        vm.roll(block.number + b);
        callCounts["roll"]++;
    }

    // Convenience views for the invariant file.
    function numClaimants() external view returns (uint256) {
        return claimants.length;
    }
}
