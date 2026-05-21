// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

abstract contract RolesLibrary {
    bytes32 public constant UPGRADE_TIMELOCK_ROLE = keccak256("UPGRADE_TIMELOCK_ROLE"); // 10 day timelock
    bytes32 public constant OPERATION_TIMELOCK_ROLE = keccak256("OPERATION_TIMELOCK_ROLE"); // 2 day timelock
    bytes32 public constant OPERATION_MULTISIG_ROLE = keccak256("OPERATION_MULTISIG_ROLE"); // 4 of 7 multisig
    bytes32 public constant SUPER_GUARDIAN_ROLE = keccak256("SUPER_GUARDIAN_ROLE"); // Guardian role for pausing eeth/weeth token transfers
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE"); // hypernative and EOA keys for emergency pausing and blacklisting
    bytes32 public constant ORACLE_OPERATIONS_ROLE = keccak256("ORACLE_OPERATIONS_ROLE"); // Oracle operations role
    bytes32 public constant HOUSEKEEPING_OPERATIONS_ROLE = keccak256("HOUSEKEEPING_OPERATIONS_ROLE"); // Housekeeping operations role
    bytes32 public constant EXECUTOR_OPERATIONS_ROLE = keccak256("EXECUTOR_OPERATIONS_ROLE"); // Executor operations role
    bytes32 public constant EIGENPOD_OPERATIONS_ROLE = keccak256("EIGENPOD_OPERATIONS_ROLE"); // Eigenpod operations role
}