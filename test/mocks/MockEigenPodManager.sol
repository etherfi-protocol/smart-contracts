// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "@tests/mocks/MockEigenPodManagerBase.sol";
import "@tests/mocks/MockEigenPod.sol";
import "@etherfi/interfaces/eigenlayer-interfaces/IEigenPodManager.sol";
import "@tests/mocks/MockStrategy.sol";
import "forge-std/console2.sol";
import "forge-std/Test.sol";

contract MockEigenPodManager is MockEigenPodManagerBase, Test {

    // Overrides

    function createPod() external override returns (address) {
        // use a mock pod that we can edit for testing
        return address(new MockEigenPod());
    }
}
