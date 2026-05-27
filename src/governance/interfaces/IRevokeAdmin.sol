// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IRevokeAdmin {
    function revokeSuperGuardianRole(address account) external;
    function revokeGuardianRole(address account) external;
    function revokeOracleOperationsRole(address account) external;
    function revokeHousekeepingOperationsRole(address account) external;
    function revokeExecutorOperationsRole(address account) external;
    function revokeEigenpodOperationsRole(address account) external;
}