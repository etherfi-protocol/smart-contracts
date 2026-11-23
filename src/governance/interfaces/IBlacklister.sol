// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IBlacklister {
    function blacklistUser(address user) external;
    function unblacklistUser(address user) external;
    function nonBlacklisted(address user) external view;
    function isBlacklisted(address user) external view returns (bool);
}