/*
 * Certora CVL spec for ether.fi RoleRegistry — authority invariants (I6).
 *
 * I6 = authority-registry consistency / no unauthorized privilege change.
 * RoleRegistry is Ownable2StepUpgradeable + UUPSUpgradeable + solady's
 * EnumerableRoles. Role membership is stored by solady in a custom slot and
 * read back through the public `hasRole` view.
 *
 * The two non-internal write paths to a role bit are:
 *   - setRole / grantRole / revokeRole : guarded by solady _authorizeSetRole,
 *     which reverts unless msg.sender == owner().
 *   - revokeFast(role,account)         : guarded by msg.sender == revokeAdmin,
 *     can ONLY clear a bit, and reverts on the 3 protected roles.
 *
 * ===========================================================================
 * MODELLING NOTE — resolving solady's assembly self-staticcalls.
 * solady's `_enumerableRolesSenderIsContractOwner` decides grant-path
 * authorization by STATICCALLing owner() on address(this) from HAND-ROLLED
 * ASSEMBLY (EnumerableRoles.sol:295-305), and `_validateRole` likewise
 * STATICCALLs MAX_ROLE() (EnumerableRoles.sol:193-205). The Prover cannot
 * recover the 4-byte selectors from that assembly calldata, reports "callee
 * sighash unresolved", and AUTO-havocs the return values — which previously
 * produced spurious "non-owner changed a role" counterexamples on
 * grantRole/revokeRole/setRole. Modelling _authorizeSetRole with an
 * INTERNAL-function CVL summary crashed the Prover backend (it interacts badly
 * with solady's assembly storage writes).
 *
 * The sound fix is a DISPATCH list on the UNRESOLVED EXTERNAL calls (methods
 * block). Both STATICCALLs target literally address(this), and the only
 * external calls reachable inside setRole/grantRole/revokeRole are these two
 * self-calls, so resolving them to currentContract.owner()/MAX_ROLE() is EXACT,
 * not an over-approximation. `optimistic=true` drops the "no match" havoc
 * branch that would otherwise re-introduce the spurious counterexample; the
 * entry is scoped to the three grant-path methods ONLY, so upgradeToAndCall's
 * delegatecall is left to the Prover's default handling.
 *
 *   I6.1  revokeFast AUTHORITY: a successful revokeFast requires the immutable
 *         revokeAdmin — plain Solidity the Prover models natively.       [VERIFIED]
 *   I6.2  revokeFast reverts on the 3 protected roles (InvalidRoleToRevoke is an
 *         explicit guard the Prover sees).                                [VERIFIED]
 *   I6.3  revokeFast never grants (false->true).                          [VERIFIED]
 *   I6.4  the owner-gated paths (grantRole/revokeRole/setRole) and revokeFast
 *         are the ONLY methods that can change a role bit — no OTHER method
 *         (transfers, views) mutates membership. Proven by filtering to
 *         all-other-methods and asserting no change. (upgradeToAndCall excluded:
 *         UUPS delegatecall havocs all storage, a modelling artifact, gated
 *         separately by onlyUpgradeTimelock — see I6.6.)                  [VERIFIED]
 *   I6.5  the owner-gated paths succeed ONLY for msg.sender == owner() — the
 *         grant-path authorization itself, provable directly thanks to the
 *         self-call dispatch above (no longer resting on solady's audit alone).
 *   I6.6  upgradeToAndCall succeeds ONLY for a caller holding
 *         UPGRADE_TIMELOCK_ROLE (_authorizeUpgrade/onlyUpgradeTimelock,
 *         RoleRegistry.sol:252-254); closes the one path I6.4 must exclude.
 * ===========================================================================
 */

methods {
    function owner() external returns (address) envfree;
    function revokeAdmin() external returns (address) envfree;
    function hasRole(bytes32, address) external returns (bool) envfree;

    function UPGRADE_TIMELOCK_ROLE()  external returns (bytes32) envfree;
    function OPERATION_TIMELOCK_ROLE() external returns (bytes32) envfree;
    function OPERATION_MULTISIG_ROLE() external returns (bytes32) envfree;

    // Resolve solady's two assembly self-STATICCALLs (see MODELLING NOTE):
    // owner() in _authorizeSetRole and MAX_ROLE() in _validateRole. Both target
    // address(this), and they are the ONLY external calls reachable inside the
    // grant-path methods, so dispatching to currentContract.owner()/MAX_ROLE()
    // is exact. optimistic=true removes the "no match" havoc branch that would
    // otherwise re-create the spurious non-owner counterexample. Scoped to the
    // three grant-path methods so upgradeToAndCall is left untouched.
    unresolved external in currentContract.setRole(address,uint256,bool) =>
        DISPATCH(optimistic=true) [ currentContract.owner(), currentContract.MAX_ROLE() ];
    unresolved external in currentContract.grantRole(bytes32,address) =>
        DISPATCH(optimistic=true) [ currentContract.owner(), currentContract.MAX_ROLE() ];
    unresolved external in currentContract.revokeRole(bytes32,address) =>
        DISPATCH(optimistic=true) [ currentContract.owner(), currentContract.MAX_ROLE() ];
}

// ----------------------------------------------------------------------------
// I6.4 NO STRAY MUTATION: only the role-management entry points
//      (grantRole / revokeRole / setRole / revokeFast) may change a role bit.
//      Every OTHER method must leave all (role,account) memberships unchanged.
//
//      This is the registry-integrity property: no transfer, config, or view
//      path can silently alter authority. upgradeToAndCall is excluded — a UUPS
//      upgrade delegatecalls an arbitrary impl and the Prover havocs all storage
//      (a modelling artifact, not a real grant); that path is gated by
//      onlyUpgradeTimelock, a separate authority. Matches EtherFiOracle.spec.
// ----------------------------------------------------------------------------
rule I6_only_role_mgmt_methods_change_membership(method f, env e, calldataarg args)
    filtered {
        f -> f.selector != sig:grantRole(bytes32,address).selector
          && f.selector != sig:revokeRole(bytes32,address).selector
          && f.selector != sig:setRole(address,uint256,bool).selector
          && f.selector != sig:revokeFast(bytes32,address).selector
          && f.selector != sig:upgradeToAndCall(address,bytes).selector
    }
{
    bytes32 role; address account;

    bool before = hasRole(role, account);
    f(e, args);
    bool afterCall = hasRole(role, account);

    assert before == afterCall,
        "I6.4: a non-role-management method changed role membership";
}

// ----------------------------------------------------------------------------
// I6.5 OWNER-GATED WRITE PATHS: a successful grantRole / revokeRole / setRole
//      requires msg.sender == owner(). This is the grant-path authorization
//      solady enforces via _authorizeSetRole (owner-or-revert). It is provable
//      here ONLY because the methods block resolves solady's owner()/MAX_ROLE()
//      self-staticcalls (see MODELLING NOTE); without that resolution the Prover
//      havocs the owner() return and reports spurious non-owner counterexamples.
// ----------------------------------------------------------------------------
rule I6_owner_gated_paths_require_owner(method f, env e, calldataarg args)
    filtered {
        f -> f.selector == sig:grantRole(bytes32,address).selector
          || f.selector == sig:revokeRole(bytes32,address).selector
          || f.selector == sig:setRole(address,uint256,bool).selector
    }
{
    f@withrevert(e, args);

    assert !lastReverted => e.msg.sender == owner(),
        "I6.5: an owner-gated role change succeeded for a non-owner caller";
}

// ----------------------------------------------------------------------------
// I6.6 UPGRADE AUTHORITY: a successful upgradeToAndCall requires msg.sender to
//      hold UPGRADE_TIMELOCK_ROLE. upgradeToAndCall is excluded from I6.4
//      because the UUPS delegatecall havocs all storage (a modelling artifact),
//      leaving its authorization otherwise unproven. _authorizeUpgrade calls
//      onlyUpgradeTimelock(msg.sender) (RoleRegistry.sol:252-254), which reverts
//      unless hasRole(UPGRADE_TIMELOCK_ROLE, msg.sender) — it does NOT allow the
//      owner. We capture that membership BEFORE the call (the delegatecall may
//      havoc it) and assert a successful upgrade implies the caller held it.
// ----------------------------------------------------------------------------
rule I6_upgrade_requires_timelock_role(env e, calldataarg args) {
    bool hadRole = hasRole(UPGRADE_TIMELOCK_ROLE(), e.msg.sender);

    upgradeToAndCall@withrevert(e, args);

    assert !lastReverted => hadRole,
        "I6.6: upgradeToAndCall succeeded for a caller without UPGRADE_TIMELOCK_ROLE";
}

// ----------------------------------------------------------------------------
// I6.2 PROTECTED ROLES: revokeFast can NEVER revoke UPGRADE_TIMELOCK_ROLE,
//      OPERATION_TIMELOCK_ROLE, or OPERATION_MULTISIG_ROLE — it reverts
//      (InvalidRoleToRevoke) before reaching solady's _setRole. A reverting
//      call changes no membership, so the three roles are untouchable here.
// ----------------------------------------------------------------------------
rule I6_revokeFast_reverts_on_protected_roles(env e, bytes32 role, address account) {
    require role == UPGRADE_TIMELOCK_ROLE()
         || role == OPERATION_TIMELOCK_ROLE()
         || role == OPERATION_MULTISIG_ROLE();

    revokeFast@withrevert(e, role, account);

    assert lastReverted,
        "I6.2: revokeFast did not revert on a protected role";
}

// ----------------------------------------------------------------------------
// I6.1 revokeFast AUTHORITY: a successful revokeFast requires msg.sender to be
//      the immutable revokeAdmin. (Native check — no assembly, Prover sees it.)
// ----------------------------------------------------------------------------
rule I6_revokeFast_requires_revokeAdmin(env e, bytes32 role, address account) {
    revokeFast@withrevert(e, role, account);
    bool reverted = lastReverted;

    assert !reverted => e.msg.sender == revokeAdmin(),
        "I6.1: revokeFast succeeded for a non-revokeAdmin caller";
}

// ----------------------------------------------------------------------------
// I6.3 revokeFast ONLY REMOVES: across any successful revokeFast, no
//      (role,account) bit may go false->true; it can only stay or clear.
// ----------------------------------------------------------------------------
rule I6_revokeFast_only_removes(env e, bytes32 role, address account) {
    bytes32 r; address a;
    bool before = hasRole(r, a);

    revokeFast(e, role, account);

    bool afterCall = hasRole(r, a);

    assert !(before == false && afterCall == true),
        "I6.3: revokeFast granted a role (false->true), it must only revoke";
}
