// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.9;

import "forge-std/Test.sol";
import "../../test/mocks/MockEigenPodBase.sol";

contract MockEigenPod is MockEigenPodBase, Test {

    // OVERRIDES

    //************************************************************
    // activeValidatorCount()
    //************************************************************
    function activeValidatorCount() external override view returns (uint256) { return mock_activeValidatorCount; }
    uint256 public mock_activeValidatorCount;
    function mockSet_activeValidatorCount(uint256 count) public { mock_activeValidatorCount = count; }

}

