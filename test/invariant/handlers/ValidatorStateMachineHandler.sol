// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../../TestSetup.sol";
import "@etherfi/staking/interfaces/IStakingManager.sol";
import "@etherfi/staking/interfaces/IEtherFiNode.sol";
import "@etherfi/core/LiquidityPool.sol";
import "@etherfi/staking/StakingManager.sol";
import "@etherfi/staking/EtherFiNodesManager.sol";

interface ILPValidator {
    function batchRegister(IStakingManager.DepositData[] calldata, uint256[] calldata, address) external;
    // NOT payable: the pool funds the 1 ETH per validator from its own balance
    // (LiquidityPool.batchCreateBeaconValidators -> createBeaconValidators{value: ...}).
    function batchCreateBeaconValidators(IStakingManager.DepositData[] calldata, uint256[] calldata, address) external;
}

/// @notice Stateful-fuzz handler for the validator-creation state machine (I10).
///
///         Drives the three real transition functions against a fixed pool of
///         pre-provisioned (REGISTERED-able) validators, in fuzzer-chosen order:
///           - register  : NOT_REGISTERED -> REGISTERED   (LP.batchRegister, spawner)
///           - create     : REGISTERED     -> CONFIRMED    (LP.batchCreateBeaconValidators, op-admin)
///           - invalidate : REGISTERED     -> INVALIDATED  (StakingManager.invalidateRegisteredBeaconValidator, oracle-ops)
///
///         INVARIANT I10: validatorCreationStatus only ever advances along a
///         LEGAL edge. CONFIRMED and INVALIDATED are terminal; no skip, no
///         reverse, no illegal edge. The handler records each hash's status
///         before/after every attempted call and flips a failure ghost if any
///         observed transition is not in the legal set.
contract ValidatorStateMachineHandler is Test {
    enum S { NOT_REGISTERED, REGISTERED, CONFIRMED, INVALIDATED }

    StakingManager internal immutable sm;
    address internal immutable lp;
    address internal immutable opAdmin;     // batchCreateBeaconValidators caller
    address internal immutable oracleOps;   // invalidate caller

    struct Val {
        IStakingManager.DepositData depositData;
        uint256 bidId;
        address node;
        address spawner;
        bytes32 hash;
    }
    Val[] internal pool;

    // failure ghost — any true => I10 broken
    bool public sawIllegalTransition;
    string public illegalReason;
    // records the actual (before, after) status codes of the illegal edge observed
    uint8 public illegalBefore;
    uint8 public illegalAfter;

    // failure ghost — a successful call landed in the WRONG end-state
    // (register that didn't reach REGISTERED, create that didn't reach CONFIRMED,
    //  invalidate that didn't reach INVALIDATED). Any true => I10 broken.
    bool public sawWrongEndState;
    string public wrongEndStateReason;

    // coverage
    uint256 public register_ok;
    uint256 public register_revert;
    uint256 public create_ok;
    uint256 public create_revert;
    uint256 public invalidate_ok;
    uint256 public invalidate_revert;

    constructor(
        StakingManager _sm,
        address _lp,
        address /* _spawner (unused; per-validator spawner) */,
        address _opAdmin,
        address _oracleOps
    ) {
        sm = _sm;
        lp = _lp;
        opAdmin = _opAdmin;
        oracleOps = _oracleOps;
    }

    function addValidator(
        IStakingManager.DepositData calldata d,
        uint256 bidId,
        address node,
        address spawner,
        bytes32 hash
    ) external {
        pool.push(Val({depositData: d, bidId: bidId, node: node, spawner: spawner, hash: hash}));
    }

    function poolSize() external view returns (uint256) { return pool.length; }

    function _status(bytes32 h) internal view returns (S) {
        return S(uint8(sm.validatorCreationStatus(h)));
    }

    function _check(S before, S afterS) internal {
        if (before == afterS) return; // no-op (revert path) is always fine
        bool legal =
            (before == S.NOT_REGISTERED && afterS == S.REGISTERED) ||
            (before == S.REGISTERED && afterS == S.CONFIRMED) ||
            (before == S.REGISTERED && afterS == S.INVALIDATED);
        if (!legal) {
            sawIllegalTransition = true;
            illegalBefore = uint8(before);
            illegalAfter = uint8(afterS);
            illegalReason = string.concat(
                "illegal status edge ",
                vm.toString(uint256(uint8(before))),
                "->",
                vm.toString(uint256(uint8(afterS)))
            );
        }
    }

    /// After a call that reported success, the hash MUST sit in the expected
    /// end-state. Records a ghost violation (total-function style) rather than
    /// reverting inside the handler.
    function _expectEndState(S expected, S actual) internal {
        if (actual != expected) {
            sawWrongEndState = true;
            wrongEndStateReason = string.concat(
                "success landed in ",
                vm.toString(uint256(uint8(actual))),
                " expected ",
                vm.toString(uint256(uint8(expected)))
            );
        }
    }

    function _arrD(IStakingManager.DepositData memory d) internal pure returns (IStakingManager.DepositData[] memory a) {
        a = new IStakingManager.DepositData[](1);
        a[0] = d;
    }
    function _arrU(uint256 x) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = x;
    }

    // ---- single-step transition primitives (shared by the fuzzed actions and
    //      the coverage bootstrap) ----

    function _register(Val storage v) internal {
        S before = _status(v.hash);
        vm.prank(v.spawner);
        try ILPValidator(lp).batchRegister(_arrD(v.depositData), _arrU(v.bidId), v.node) {
            register_ok++;
            _expectEndState(S.REGISTERED, _status(v.hash));
        } catch {
            register_revert++;
        }
        _check(before, _status(v.hash));
    }

    function _create(Val storage v) internal {
        S before = _status(v.hash);
        // batchCreateBeaconValidators is NOT payable: the LiquidityPool funds the
        // 1 ETH-per-validator initial deposit from its OWN balance (setUp deals it
        // the ETH). Forwarding value here would revert on the non-payable fallback
        // before any state transition, so no create could ever fire.
        vm.prank(opAdmin);
        try ILPValidator(lp).batchCreateBeaconValidators(_arrD(v.depositData), _arrU(v.bidId), v.node) {
            create_ok++;
            _expectEndState(S.CONFIRMED, _status(v.hash));
        } catch {
            create_revert++;
        }
        _check(before, _status(v.hash));
    }

    function _invalidate(Val storage v) internal {
        S before = _status(v.hash);
        vm.prank(oracleOps);
        try sm.invalidateRegisteredBeaconValidator(v.depositData, v.bidId, v.node) {
            invalidate_ok++;
            _expectEndState(S.INVALIDATED, _status(v.hash));
        } catch {
            invalidate_revert++;
        }
        _check(before, _status(v.hash));
    }

    /// Coverage floor: create/invalidate both consume a REGISTERED validator and
    /// compete for the few that exist, so a purely random action order starves one
    /// or the other on some runs (a single doCreate on a random idx usually misses
    /// the registered validator). To make coverage deterministic without weakening
    /// the vacuity gate, the first fuzzed call of every run drives one full legal
    /// register->create on pool[0] and one full register->invalidate on pool[1].
    /// The two now-terminal validators then double as illegal-edge targets that the
    /// fuzzer keeps hammering (create/invalidate/register on a terminal status must
    /// all revert with no status change). Runs revert to the setUp snapshot, so this
    /// re-arms each run.
    bool internal bootstrapped;
    modifier coverageFloor() {
        if (!bootstrapped) {
            bootstrapped = true;
            if (pool.length >= 1) { _register(pool[0]); _create(pool[0]); }
            if (pool.length >= 2) { _register(pool[1]); _invalidate(pool[1]); }
        }
        _;
    }

    function doRegister(uint256 idx) external coverageFloor {
        if (pool.length == 0) return;
        _register(pool[bound(idx, 0, pool.length - 1)]);
    }

    function doCreate(uint256 idx) external coverageFloor {
        if (pool.length == 0) return;
        _create(pool[bound(idx, 0, pool.length - 1)]);
    }

    function doInvalidate(uint256 idx) external coverageFloor {
        if (pool.length == 0) return;
        _invalidate(pool[bound(idx, 0, pool.length - 1)]);
    }
}
