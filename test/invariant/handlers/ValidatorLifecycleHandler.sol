// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../../TestSetup.sol";
import "@etherfi/staking/EtherFiNodesManager.sol";

/// @notice Stateful-fuzz handler driving EtherFiNodesManager.linkPubkeyToNode
///         directly, to prove invariant I11 (pubkey -> node uniqueness).
///
///         linkPubkeyToNode is gated `msg.sender == address(stakingManager)`,
///         so the handler pranks as the StakingManager instance. The function
///         dual-writes two maps and guards both:
///           - etherFiNodeFromPubkeyHash[pubkeyHash] must be 0  (else AlreadyLinked)
///           - legacyState.DEPRECATED_etherfiNodeAddress[legacyId] must be 0 (else AlreadyLinked)
///         pubkeyHash = sha256(pubkey ++ bytes16(0)), pubkey is exactly 48 bytes.
///
///         INVARIANT I11: once a pubkey hash is linked to a node, the mapping
///         is permanent and unique — it can never be overwritten or repointed,
///         and any re-link attempt (to the SAME or a DIFFERENT node) reverts.
contract ValidatorLifecycleHandler is Test {
    EtherFiNodesManager internal immutable manager;
    address internal immutable stakingManagerAddr;

    // ---- ghost state ----
    // first node each pubkey hash was linked to (0 = never linked)
    mapping(bytes32 => address) public ghostLinkedNode;
    // legacyIds already consumed (a legacyId can only be used once)
    mapping(uint256 => bool) public ghostLegacyUsed;
    bytes32[] public linkedHashes;

    // failure flags — any true => invariant broken
    bool public sawOverwrite;        // a stored hash->node changed after first set
    bool public sawRelinkSucceed;    // re-linking an already-linked hash succeeded

    // coverage counters
    uint256 public link_ok;
    uint256 public link_already_revert;
    uint256 public relink_attempt;

    constructor(EtherFiNodesManager _manager, address _stakingManagerAddr) {
        manager = _manager;
        stakingManagerAddr = _stakingManagerAddr;
    }

    function _pubkey(uint256 seed) internal pure returns (bytes memory pk) {
        // deterministic 48-byte pubkey from a seed
        pk = new bytes(48);
        bytes32 a = keccak256(abi.encodePacked(seed, uint256(1)));
        bytes32 b = keccak256(abi.encodePacked(seed, uint256(2)));
        for (uint256 i = 0; i < 32; i++) pk[i] = a[i];
        for (uint256 i = 0; i < 16; i++) pk[32 + i] = b[i];
    }

    /// Try to link a fresh (or colliding) pubkey to a node.
    function doLink(uint256 pubkeySeed, uint256 nodeSeed, uint256 legacyId) external {
        pubkeySeed = bound(pubkeySeed, 0, 24); // small space => forces hash collisions / relinks
        legacyId = bound(legacyId, 1, 24);
        address node = address(uint160(uint256(keccak256(abi.encodePacked("node", nodeSeed))) | 1));

        bytes memory pk = _pubkey(pubkeySeed);
        bytes32 h = manager.calculateValidatorPubkeyHash(pk);
        address pre = address(manager.etherFiNodeFromPubkeyHash(h));

        vm.prank(stakingManagerAddr);
        try manager.linkPubkeyToNode(pk, node, legacyId) {
            link_ok++;
            // success path: it MUST have been unlinked beforehand (both guards)
            if (pre != address(0)) sawRelinkSucceed = true;
            if (ghostLinkedNode[h] != address(0)) sawRelinkSucceed = true;
            if (ghostLegacyUsed[legacyId]) sawRelinkSucceed = true;
            ghostLinkedNode[h] = node;
            ghostLegacyUsed[legacyId] = true;
            linkedHashes.push(h);
        } catch {
            link_already_revert++;
        }

        // overwrite check: stored node for an already-ghosted hash must match ghost
        if (ghostLinkedNode[h] != address(0)) {
            if (address(manager.etherFiNodeFromPubkeyHash(h)) != ghostLinkedNode[h]) sawOverwrite = true;
        }
    }

    /// Actively attempt to re-link an already-linked pubkey to a DIFFERENT node — must always revert.
    function doRelinkAttack(uint256 idx, uint256 nodeSeed, uint256 legacyId) external {
        if (linkedHashes.length == 0) return;
        relink_attempt++;
        idx = bound(idx, 0, linkedHashes.length - 1);
        bytes32 h = linkedHashes[idx];
        // recover a pubkey that hashes to h: we stored by seed, so re-derive by scanning small space
        for (uint256 s = 0; s <= 24; s++) {
            bytes memory pk = _pubkey(s);
            if (manager.calculateValidatorPubkeyHash(pk) == h) {
                address attackerNode = address(uint160(uint256(keccak256(abi.encodePacked("atk", nodeSeed))) | 1));
                address before = address(manager.etherFiNodeFromPubkeyHash(h));
                vm.prank(stakingManagerAddr);
                try manager.linkPubkeyToNode(pk, attackerNode, bound(legacyId, 1, 24)) {
                    sawRelinkSucceed = true; // re-link of a linked hash MUST NOT succeed
                } catch {
                    // expected
                }
                if (address(manager.etherFiNodeFromPubkeyHash(h)) != before) sawOverwrite = true;
                return;
            }
        }
    }

    function linkedCount() external view returns (uint256) { return linkedHashes.length; }
}
