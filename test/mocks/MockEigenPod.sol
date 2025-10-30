// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.9;

import "../../test/mocks/MockEigenPodBase.sol";
import "forge-std/Test.sol";

contract MockEigenPod is MockEigenPodBase, Test {
    // OVERRIDES

    //************************************************************
    // activeValidatorCount()
    //************************************************************
    function activeValidatorCount() external view override returns (uint256) {
        return mock_activeValidatorCount;
    }

    uint256 public mock_activeValidatorCount;

    function mockSet_activeValidatorCount(uint256 count) public {
        mock_activeValidatorCount = count;
    }
}
