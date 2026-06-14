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

    function setUp() public {
        setUpTests();
        handler = new ValidatorLifecycleHandler(managerInstance, address(stakingManagerInstance));
        targetContract(address(handler));
    }

    /// I11: no pubkey-hash link was ever overwritten / repointed after first set.
    function invariant_I11_pubkey_node_link_immutable() public view {
        assertFalse(handler.sawOverwrite(), "I11: a pubkey-hash->node link was overwritten");
    }

    /// I11: re-linking an already-linked pubkey (same or different node) never succeeds.
    function invariant_I11_no_relink_succeeds() public view {
        assertFalse(handler.sawRelinkSucceed(), "I11: re-link of an already-linked pubkey succeeded");
    }

    /// Soft coverage observability (mirrors existing suites' convention).
    function invariant_call_coverage_summary() public view {
        // no assertion; surfaced under -vv
        handler.link_ok();
        handler.link_already_revert();
        handler.relink_attempt();
    }
}
