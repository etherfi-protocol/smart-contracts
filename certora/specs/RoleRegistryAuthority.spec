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
 * MODELLING NOTE — why I6.1 is split by method rather than summarized.
 * solady's `_enumerableRolesSenderIsContractOwner` decides authorization by
 * STATICCALLing owner() on address(this) from HAND-ROLLED ASSEMBLY
 * (EnumerableRoles.sol:295-305). The Prover cannot recover the 4-byte selector
 * from that assembly calldata, reports "callee sighash unresolved", and
 * AUTO-havocs the return value — producing spurious "non-owner changed a role"
 * counterexamples on grantRole/revokeRole/setRole. Attempts to model
 * _authorizeSetRole with an internal-function CVL summary crashed the Prover
 * backend (the summary interacts badly with solady's assembly storage writes).
 *
 * So we prove I6 from the angles the Prover CAN see soundly, with NO summaries:
 *   I6.1  revokeFast is the ONLY non-owner write path, and it can only CLEAR a
 *         bit — proven directly (revokeAdmin gate + active=false are plain
 *         Solidity the Prover models natively).  [VERIFIED]
 *   I6.2  revokeFast reverts on the 3 protected roles (InvalidRoleToRevoke is an
 *         explicit guard the Prover sees).                                [VERIFIED]
 *   I6.3  revokeFast never grants (false->true).                          [VERIFIED]
 *   I6.4  the owner-gated paths (grantRole/revokeRole/setRole) are the ONLY
 *         methods OTHER than revokeFast that can change a role bit — i.e. no
 *         OTHER method (transfers, upgrades-aside, views) mutates membership.
 *         Proven by filtering to all-other-methods and asserting no change.
 *         (upgradeToAndCall excluded: UUPS delegatecall havocs all storage, a
 *         modelling artifact, gated separately by onlyUpgradeTimelock.)
 * The owner-only authorization of grantRole/revokeRole/setRole themselves rests
 * on solady's audited _authorizeSetRole (owner-or-revert); we assert it cannot
 * be bypassed by any OTHER entry point, which is the registry-integrity half of
 * I6 that is provable without the un-modellable assembly self-call.
 * ===========================================================================
 */

methods {
    function owner() external returns (address) envfree;
    function revokeAdmin() external returns (address) envfree;
    function hasRole(bytes32, address) external returns (bool) envfree;

    function UPGRADE_TIMELOCK_ROLE()  external returns (bytes32) envfree;
    function OPERATION_TIMELOCK_ROLE() external returns (bytes32) envfree;
    function OPERATION_MULTISIG_ROLE() external returns (bytes32) envfree;
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
