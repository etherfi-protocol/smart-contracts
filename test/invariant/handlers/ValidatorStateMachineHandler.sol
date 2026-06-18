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
    function batchCreateBeaconValidators(IStakingManager.DepositData[] calldata, uint256[] calldata, address) external payable;
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
            illegalReason = "illegal status edge observed";
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

    function doRegister(uint256 idx) external {
        if (pool.length == 0) return;
        Val storage v = pool[bound(idx, 0, pool.length - 1)];
        S before = _status(v.hash);
        vm.prank(v.spawner);
        try ILPValidator(lp).batchRegister(_arrD(v.depositData), _arrU(v.bidId), v.node) {
            register_ok++;
        } catch {
            register_revert++;
        }
        _check(before, _status(v.hash));
    }

    function doCreate(uint256 idx) external {
        if (pool.length == 0) return;
        Val storage v = pool[bound(idx, 0, pool.length - 1)];
        S before = _status(v.hash);
        vm.deal(opAdmin, 100 ether);
        vm.prank(opAdmin);
        try ILPValidator(lp).batchCreateBeaconValidators{value: 1 ether}(_arrD(v.depositData), _arrU(v.bidId), v.node) {
            create_ok++;
        } catch {
            create_revert++;
        }
        _check(before, _status(v.hash));
    }

    function doInvalidate(uint256 idx) external {
        if (pool.length == 0) return;
        Val storage v = pool[bound(idx, 0, pool.length - 1)];
        S before = _status(v.hash);
        vm.prank(oracleOps);
        try sm.invalidateRegisteredBeaconValidator(v.depositData, v.bidId, v.node) {
            invalidate_ok++;
        } catch {
            invalidate_revert++;
        }
        _check(before, _status(v.hash));
    }
}
