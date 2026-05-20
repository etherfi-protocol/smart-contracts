// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

abstract contract RolesLibrary {
    bytes32 public constant UPGRADE_TIMELOCK_ROLE = keccak256("UPGRADE_TIMELOCK_ROLE"); // 10 day timelock
    bytes32 public constant OPERATION_TIMELOCK_ROLE = keccak256("OPERATION_TIMELOCK_ROLE"); // 3 day timelock
    bytes32 public constant OPERATION_MULTISIG_ROLE = keccak256("OPERATION_MULTISIG_ROLE"); // 4 of 7 multisig
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE"); // hypernative and EOA keys for emergency pausing and blacklisting
    bytes32 public constant EOA_1 = keccak256("EOA_1"); // EOA key 1
    bytes32 public constant EOA_2 = keccak256("EOA_2"); // EOA key 2
    bytes32 public constant EOA_3 = keccak256("EOA_3"); // EOA key 3
    bytes32 public constant EOA_4 = keccak256("EOA_4"); // EOA key 4
}