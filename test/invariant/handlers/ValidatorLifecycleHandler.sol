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
    address internal immutable executorOps;   // linkLegacyValidatorIds caller (EXECUTOR_OPERATIONS_ROLE)

    // ---- ghost state ----
    // first node each pubkey hash was linked to (0 = never linked)
    mapping(bytes32 => address) public ghostLinkedNode;
    // legacyIds already consumed (a legacyId can only be used once)
    mapping(uint256 => bool) public ghostLegacyUsed;
    bytes32[] public linkedHashes;
    // legacyIds that a successful link populated in DEPRECATED_etherfiNodeAddress
    // (needed to drive linkLegacyValidatorIds past its UnknownNode guard)
    uint256[] public usedLegacyIds;

    // failure flags — any true => invariant broken
    bool public sawOverwrite;        // a stored hash->node changed after first set
    bool public sawRelinkSucceed;    // re-linking an already-linked hash succeeded

    // coverage counters
    uint256 public link_ok;
    uint256 public link_already_revert;
    uint256 public relink_attempt;
    uint256 public legacy_link_attempt;

    constructor(EtherFiNodesManager _manager, address _stakingManagerAddr, address _executorOps) {
        manager = _manager;
        stakingManagerAddr = _stakingManagerAddr;
        executorOps = _executorOps;
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
            usedLegacyIds.push(legacyId);
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
                // Use a guaranteed-FRESH legacyId (1000..1024, disjoint from the
                // 1..24 range doLink consumes) so the DEPRECATED_etherfiNodeAddress
                // slot guard is satisfied and the revert isolates the pubkeyHash
                // AlreadyLinked guard — the thing we're actually asserting here.
                vm.prank(stakingManagerAddr);
                try manager.linkPubkeyToNode(pk, attackerNode, bound(legacyId, 1000, 1024)) {
                    sawRelinkSucceed = true; // re-link of a linked hash MUST NOT succeed
                } catch {
                    // expected
                }
                if (address(manager.etherFiNodeFromPubkeyHash(h)) != before) sawOverwrite = true;
                return;
            }
        }
    }

    /// Actively attempt to repoint an already-linked pubkey via the SECOND writer
    /// to etherFiNodeFromPubkeyHash — linkLegacyValidatorIds (EXECUTOR_OPERATIONS_ROLE).
    /// We feed it a legacyId that a prior link already populated in
    /// DEPRECATED_etherfiNodeAddress (so the UnknownNode guard passes) paired with an
    /// already-linked pubkey. The call MUST revert AlreadyLinked and leave the link
    /// untouched — exercising that this path can't overwrite I11's mapping either.
    function doLegacyLinkAttack(uint256 idx, uint256 legacyIdx) external {
        if (linkedHashes.length == 0 || usedLegacyIds.length == 0) return;
        legacy_link_attempt++;
        idx = bound(idx, 0, linkedHashes.length - 1);
        bytes32 h = linkedHashes[idx];
        uint256 legacyId = usedLegacyIds[bound(legacyIdx, 0, usedLegacyIds.length - 1)];

        // recover a pubkey that hashes to h (stored by seed over the small space)
        for (uint256 s = 0; s <= 24; s++) {
            bytes memory pk = _pubkey(s);
            if (manager.calculateValidatorPubkeyHash(pk) == h) {
                uint256[] memory ids = new uint256[](1);
                ids[0] = legacyId;
                bytes[] memory pks = new bytes[](1);
                pks[0] = pk;
                address before = address(manager.etherFiNodeFromPubkeyHash(h));
                vm.prank(executorOps);
                try manager.linkLegacyValidatorIds(ids, pks) {
                    sawRelinkSucceed = true; // legacy path re-linked an already-linked pubkey
                } catch {
                    // expected: AlreadyLinked
                }
                if (address(manager.etherFiNodeFromPubkeyHash(h)) != before) sawOverwrite = true;
                return;
            }
        }
    }

    function linkedCount() external view returns (uint256) { return linkedHashes.length; }
}
