// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Vm} from "forge-std/Vm.sol";
import {IEigenPod, IEigenPodTypes} from "../../src/eigenlayer-interfaces/IEigenPod.sol";

/// @notice Test-only helpers for forcing EigenPod state in mainnet-fork tests.
///
/// Why this exists: tests that exercise our manager → node → pod path on a
/// realistic mainnet fork must reference real validator pubkeys. EigenPod's
/// `requestWithdrawal` / `requestConsolidation` revert with
/// `ValidatorNotActiveInPod()` unless the validator's recorded status is
/// `ACTIVE`. Real validators get consolidated, exited, or otherwise change
/// state over time, so any test that pins a real pubkey rots silently. We
/// poke pod storage to keep the validator entry ACTIVE for the test, so the
/// test stays a test of *our* code rather than a joint invariant with live
/// beacon-chain state.
///
/// EigenPod storage layout this depends on (mainnet impl, EigenPodStorage.sol):
///   slot 51: podOwner
///   slot 52: __dep_mostRecentWithdrawalTimestamp | restakedExecutionLayerGwei | __dep_hasRestaked
///   slot 53: __deprecated_provenWithdrawal (mapping)
///   slot 54: _validatorPubkeyHashToInfo (mapping)   ← what we write
///   slot 57: activeValidatorCount                    (anchor referenced in CLAUDE.md)
///
/// If EigenLayer ships a pod implementation that inserts or removes a state
/// variable above `_validatorPubkeyHashToInfo`, update the constant below in
/// this one file and every call site stays correct.
library EigenPodTestHelpers {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant _VALIDATOR_INFO_MAPPING_SLOT = 54;

    /// @notice Force `pkHash` to status ACTIVE in `pod`'s validator registry.
    ///         Other ValidatorInfo fields are set to plausible non-zero values
    ///         so any auxiliary read does not see a fully-zeroed struct.
    function forceValidatorActive(IEigenPod pod, bytes32 pkHash) internal {
        bytes32 slot = keccak256(abi.encode(pkHash, _VALIDATOR_INFO_MAPPING_SLOT));

        // ValidatorInfo packing (single slot, low bytes first):
        //   bits   0..63 : validatorIndex      (uint64)
        //   bits  64..127: restakedBalanceGwei (uint64)
        //   bits 128..191: lastCheckpointedAt  (uint64)
        //   bits 192..199: status              (enum, 1 byte)
        uint256 packed =
            uint256(1)
            | (uint256(32_000_000_000) << 64)
            | (uint256(uint64(block.timestamp)) << 128)
            | (uint256(uint8(IEigenPodTypes.VALIDATOR_STATUS.ACTIVE)) << 192);

        vm.store(address(pod), slot, bytes32(packed));
    }

    /// @notice Convenience overload that hashes `pubkey` first using the same
    ///         scheme EigenPod / EtherFiNodesManager use:
    ///         `sha256(pubkey || bytes16(0))`.
    function forceValidatorActive(IEigenPod pod, bytes memory pubkey) internal {
        forceValidatorActive(pod, sha256(abi.encodePacked(pubkey, bytes16(0))));
    }
}
