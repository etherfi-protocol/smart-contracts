// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../../src/eigenlayer-interfaces/IDelegationManager.sol";
import "../../src/interfaces/IStakingManager.sol";

contract ArrayTestHelper {
    // Common types used throughout our and eigenlayers protocol
    function toArray_u256(uint256 val) public pure returns (uint256[] memory) {
        uint256[] memory vals = new uint256[](1);
        vals[0] = val;
        return vals;
    }
    function toArray_u256(uint32 val) public pure returns (uint256[] memory) {
        uint256[] memory vals = new uint256[](1);
        vals[0] = val;
        return vals;
    }
    function toArray_u32(uint32 val) public pure returns (uint32[] memory) {
        uint32[] memory vals = new uint32[](1);
        vals[0] = val;
        return vals;
    }
    function toArray_u40(uint40 val) public pure returns (uint40[] memory) {
        uint40[] memory vals = new uint40[](1);
        vals[0] = val;
        return vals;
    }
    function toArray_bytes(bytes memory val) public pure returns (bytes[] memory) {
        bytes[] memory vals = new bytes[](1);
        vals[0] = val;
        return vals;
    }
    function toArray(IDelegationManager.Withdrawal memory withdrawal) public pure returns (IDelegationManager.Withdrawal[] memory) {
        IDelegationManager.Withdrawal[] memory vals = new IDelegationManager.Withdrawal[](1);
        vals[0] = withdrawal;
        return vals;
    }
    function toArray(IStakingManager.DepositData memory deposit) public pure returns (IStakingManager.DepositData[] memory) {
        IStakingManager.DepositData[] memory vals = new IStakingManager.DepositData[](1);
        vals[0] = deposit;
        return vals;
    }
}
