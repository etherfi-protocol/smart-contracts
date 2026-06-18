// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;


interface ITimelock {
    function queueTransaction(address target, uint value, string memory signature, bytes memory data, uint eta) external returns (bytes32);

    function cancelTransaction(address target, uint value, string memory signature, bytes memory data, uint eta) external ;

    function executeTransaction(address target, uint value, string memory signature, bytes memory data, uint eta) external payable returns (bytes memory);

    function admin() external view returns (address);
}
