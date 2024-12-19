// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Create2.sol";

contract Create2Factory {
    event Deployed(address addr, address deployer, bytes32 bytecode_hash, bytes32 salt);

    function deploy(bytes memory code, bytes32 salt) external payable returns (address) {
        address addr = Create2.deploy(msg.value, salt, code);

        emit Deployed(addr, address(this), keccak256(code), salt);
        return addr;
    }
}