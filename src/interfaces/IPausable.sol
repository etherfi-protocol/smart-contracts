// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

interface IPausable {
    function pauseContract() external;
    function unPauseContract() external;
}
