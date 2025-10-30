// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "../../src/eigenlayer-interfaces/IEigenPodManager.sol";
import "../../test/mocks/MockEigenPod.sol";
import "../../test/mocks/MockEigenPodManagerBase.sol";

import "../../test/mocks/MockStrategy.sol";

import "forge-std/Test.sol";
import "forge-std/console2.sol";

contract MockEigenPodManager is MockEigenPodManagerBase, Test {
    // Overrides

    function createPod() external override returns (address) {
        // use a mock pod that we can edit for testing
        return address(new MockEigenPod());
    }
}
