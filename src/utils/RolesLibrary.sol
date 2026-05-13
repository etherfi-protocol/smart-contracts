// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

abstract contract RolesLibrary {
    bytes32 public constant PROTOCOL_PAUSER = keccak256("PROTOCOL_PAUSER");
    bytes32 public constant PROTOCOL_UNPAUSER = keccak256("PROTOCOL_UNPAUSER");
    bytes32 public constant PAUSE_UNTIL_ROLE = keccak256("PAUSE_UNTIL_ROLE");
    bytes32 public constant UNPAUSE_UNTIL_ROLE = keccak256("UNPAUSE_UNTIL_ROLE");
    bytes32 public constant BLACKLISTER_ROLE = keccak256("BLACKLISTER_ROLE");
    bytes32 public constant BLACKLIST_UNTIL_ROLE = keccak256("BLACKLIST_UNTIL_ROLE");
}