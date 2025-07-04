// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Create2.sol";

contract Create2Factory {
    event Deployed(address addr, address deployer, bytes32 bytecodeHash, bytes32 salt);

    /// @notice Deploys a contract using CREATE2
    /// @param code The contract bytecode including constructor arguments
    /// @param salt A unique value to influence contract address
    function deploy(bytes memory code, bytes32 salt) external payable returns (address) {
        address addr = Create2.deploy(msg.value, salt, code);

        emit Deployed(addr, msg.sender, keccak256(code), salt);
        return addr;
    }

    /// @notice Computes the deterministic address of a contract
    /// @param salt The salt used for deployment
    /// @param code The bytecode including constructor arguments
    /// @return predicted The predicted deterministic contract address
    function computeAddress(bytes32 salt, bytes memory code) public view returns (address predicted) {
        predicted = Create2.computeAddress(salt, keccak256(code), address(this));
    }

    /// @notice Verifies whether a given deployed address matches provided code and salt
    /// @param addr The address to verify
    /// @param salt The salt used for the deployment
    /// @param code The contract bytecode including constructor arguments
    /// @return True if the address matches the computed address, false otherwise
    function verify(address addr, bytes32 salt, bytes memory code) external view returns (bool) {
        return (addr == computeAddress(salt, code));
    }
}
