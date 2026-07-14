// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../TestSetup.sol";
import "./handlers/ValidatorLifecycleHandler.sol";

/// @notice Stateful invariant suite for validator pubkey->node uniqueness.
///
///         I11 — pubkey -> node uniqueness: each validator pubkey hash maps to
///         exactly one EtherFiNode, set once, never overwritten or repointed.
///         Defense: EtherFiNodesManager.linkPubkeyToNode reverts AlreadyLinked
///         when etherFiNodeFromPubkeyHash[hash] (or the legacyId slot) is
///         already set (src/EtherFiNodesManager.sol ~lines 343-349).
///
///         The handler drives linkPubkeyToNode directly (pranked as the
///         StakingManager, its only authorized caller) over a deliberately
///         small pubkey space so collisions and re-link attempts are frequent,
///         and includes an explicit re-link-attack action.
///
///         NOTE on I10 (validator-creation state machine): driving the real
///         beacon flow (registerValidatorBeaconDeposit -> createBeaconValidators)
///         in a stateful fuzzer requires a deployed EtherFiNode + EigenPod,
///         an active auction bid, and valid beacon deposit-data roots — the
///         existing scaffolding for that lives in fork-based tests
///         (test/StakingManager.t.sol uses initializeRealisticFork). That is
///         out of scope for this non-fork suite and is tracked separately.
///         I11 is proven here cleanly without beacon deposits.
///
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = false
contract ValidatorLifecycleInvariantTest is TestSetup {
    ValidatorLifecycleHandler internal handler;

    address internal executorOps = address(0xE0E0);

    function setUp() public {
        setUpTests();

        // linkLegacyValidatorIds is onlyExecutorOperations; grant the role to a
        // dedicated address the handler pranks for the legacy-path re-link attack.
        // startPrank (not prank) so the nested EXECUTOR_OPERATIONS_ROLE() read doesn't
        // consume the prank before grantRole runs.
        vm.startPrank(roleRegistryInstance.owner());
        roleRegistryInstance.grantRole(roleRegistryInstance.EXECUTOR_OPERATIONS_ROLE(), executorOps);
        vm.stopPrank();

        handler = new ValidatorLifecycleHandler(managerInstance, address(stakingManagerInstance), executorOps);
        targetContract(address(handler));

        // Restrict fuzzing to the three action functions. Without this, the engine
        // also targets the handler's view getters (linkedCount, ghostLinkedNode,
        // the counters), wasting call budget on no-ops.
        bytes4[] memory sel = new bytes4[](3);
        sel[0] = handler.doLink.selector;
        sel[1] = handler.doRelinkAttack.selector;
        sel[2] = handler.doLegacyLinkAttack.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    /// I11: no pubkey-hash link was ever overwritten / repointed after first set.
    function invariant_I11_pubkey_node_link_immutable() public view {
        assertFalse(handler.sawOverwrite(), "I11: a pubkey-hash->node link was overwritten");
    }

    /// I11: re-linking an already-linked pubkey (same or different node) never succeeds.
    function invariant_I11_no_relink_succeeds() public view {
        assertFalse(handler.sawRelinkSucceed(), "I11: re-link of an already-linked pubkey succeeded");
    }

    /// I11 (global sweep): every pubkey hash the handler ever linked still points at
    /// the exact node it was FIRST set to. The per-step sawOverwrite ghost only checks
    /// the hash touched by the current call; this walks the whole recorded set each
    /// invariant round so a stray repoint of any other hash is caught too.
    function invariant_I11_all_links_match_first_node() public view {
        uint256 n = handler.linkedCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 h = handler.linkedHashes(i);
            assertEq(
                address(managerInstance.etherFiNodeFromPubkeyHash(h)),
                handler.ghostLinkedNode(h),
                "I11: a linked pubkey hash diverged from its first-set node"
            );
        }
    }

    /// Soft coverage observability (mirrors existing suites' convention).
    function invariant_call_coverage_summary() public view {
        // no assertion; surfaced under -vv
        handler.link_ok();
        handler.link_already_revert();
        handler.relink_attempt();
        handler.legacy_link_attempt();
    }

    /// Non-vacuity gate: prove the fuzzer actually drove the I11 lifecycle —
    /// at least one successful link, at least one rejected re-link (either via
    /// doLink hitting an already-linked hash or the explicit re-link attack).
    /// Without this, both invariant_I11_* could pass trivially because no link
    /// or re-link attempt ever fired.
    function afterInvariant() public {
        emit log_named_uint("link_ok            ", handler.link_ok());
        emit log_named_uint("link_already_revert", handler.link_already_revert());
        emit log_named_uint("relink_attempt     ", handler.relink_attempt());
        emit log_named_uint("legacy_link_attempt", handler.legacy_link_attempt());

        assertGt(handler.link_ok(), 0, "non-vacuity: no pubkey->node link ever succeeded");
        assertGt(
            handler.link_already_revert() + handler.relink_attempt() + handler.legacy_link_attempt(),
            0,
            "non-vacuity: no re-link / already-linked path was ever exercised"
        );
    }
}
