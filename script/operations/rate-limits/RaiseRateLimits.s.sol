// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../../utils/utils.sol";
import {EtherFiRateLimiter} from "../../../src/EtherFiRateLimiter.sol";

// One-time burst: raise capacity to cover 4000 consolidations + 2000 exits
// + 200k ETH of unrestaking. Refill rates are intentionally left at the
// reduced steady-state values so the buckets draw down naturally after the
// burst is consumed.
//
//   forge script script/operations/rate-limits/RaiseRateLimits.s.sol --fork-url $MAINNET_RPC_URL -vvvv
contract RaiseRateLimits is Script, Utils {
    EtherFiRateLimiter internal constant RATE_LIMITER =
        EtherFiRateLimiter(ETHERFI_RATE_LIMITER);

    // Must match EtherFiNodesManager constants
    bytes32 internal constant EXIT_LIMIT_ID =
        keccak256("EXIT_REQUEST_LIMIT_ID");
    bytes32 internal constant CONSOLIDATION_LIMIT_ID =
        keccak256("CONSOLIDATION_REQUEST_LIMIT_ID");
    bytes32 internal constant UNRESTAKING_LIMIT_ID =
        keccak256("UNRESTAKING_LIMIT_ID");

    uint256 internal constant FULL_EXIT_GWEI = 2_048_000_000_000;
    uint256 internal constant SECONDS_PER_DAY = 86_400;

    // ---------------------------------------------------------------
    // Consolidation burst: 4000 validators
    //   capacity = 4000 * 2_048_000_000_000 = 8_192_000_000_000_000
    // ---------------------------------------------------------------
    uint64 internal constant CONSOLIDATION_CAPACITY = 8_192_000_000_000_000;

    // ---------------------------------------------------------------
    // Exit burst: 2000 validators
    //   capacity = 2000 * 2_048_000_000_000 = 4_096_000_000_000_000
    // ---------------------------------------------------------------
    uint64 internal constant EXIT_CAPACITY = 4_096_000_000_000_000;

    // ---------------------------------------------------------------
    // Unrestaking burst: 200k ETH
    //   capacity = 200_000 * 1e9 = 200_000_000_000_000 gwei
    // ---------------------------------------------------------------
    uint64 internal constant UNRESTAKING_CAPACITY = 200_000_000_000_000;

    function run() external {
        _writeGnosisTxFiles();
        _simulateOnFork();
    }

    function _simulateOnFork() internal {
        _logLimits("=== Before ===");

        vm.startPrank(ETHERFI_OPERATING_ADMIN);
        RATE_LIMITER.setCapacity(CONSOLIDATION_LIMIT_ID, CONSOLIDATION_CAPACITY);
        RATE_LIMITER.setRemaining(CONSOLIDATION_LIMIT_ID, CONSOLIDATION_CAPACITY);
        RATE_LIMITER.setCapacity(EXIT_LIMIT_ID, EXIT_CAPACITY);
        RATE_LIMITER.setRemaining(EXIT_LIMIT_ID, EXIT_CAPACITY);
        RATE_LIMITER.setCapacity(UNRESTAKING_LIMIT_ID, UNRESTAKING_CAPACITY);
        RATE_LIMITER.setRemaining(UNRESTAKING_LIMIT_ID, UNRESTAKING_CAPACITY);
        vm.stopPrank();

        _logLimits("=== After ===");
        console2.log("Simulation successful");
    }

    function _logLimits(string memory label) internal view {
        console2.log(label);

        (uint64 cCap, uint64 cRem, uint64 cRefill,) =
            RATE_LIMITER.getLimit(CONSOLIDATION_LIMIT_ID);
        console2.log("Consolidation - capacity:", cCap);
        console2.log("Consolidation - remaining:", cRem);
        console2.log("Consolidation - refill/sec:", cRefill);
        console2.log(
            "Consolidation - validators (capacity):",
            uint256(cCap) / FULL_EXIT_GWEI
        );

        (uint64 eCap, uint64 eRem, uint64 eRefill,) =
            RATE_LIMITER.getLimit(EXIT_LIMIT_ID);
        console2.log("Exit - capacity:", eCap);
        console2.log("Exit - remaining:", eRem);
        console2.log("Exit - refill/sec:", eRefill);
        console2.log(
            "Exit - validators (capacity):",
            uint256(eCap) / FULL_EXIT_GWEI
        );

        (uint64 uCap, uint64 uRem, uint64 uRefill,) =
            RATE_LIMITER.getLimit(UNRESTAKING_LIMIT_ID);
        console2.log("Unrestaking - capacity:", uCap);
        console2.log("Unrestaking - remaining:", uRem);
        console2.log("Unrestaking - refill/sec:", uRefill);
        console2.log("Unrestaking - ETH (capacity):", uint256(uCap) / 1e9);
        console2.log("");
    }

    function _writeGnosisTxFiles() internal {
        uint256 txCount = 6;
        address[] memory targets = new address[](txCount);
        uint256[] memory values = new uint256[](txCount);
        bytes[] memory data = new bytes[](txCount);

        for (uint256 i = 0; i < txCount; i++) {
            targets[i] = address(RATE_LIMITER);
            values[i] = 0;
        }

        data[0] = abi.encodeWithSelector(
            EtherFiRateLimiter.setCapacity.selector,
            CONSOLIDATION_LIMIT_ID,
            CONSOLIDATION_CAPACITY
        );
        data[1] = abi.encodeWithSelector(
            EtherFiRateLimiter.setRemaining.selector,
            CONSOLIDATION_LIMIT_ID,
            CONSOLIDATION_CAPACITY
        );
        data[2] = abi.encodeWithSelector(
            EtherFiRateLimiter.setCapacity.selector,
            EXIT_LIMIT_ID,
            EXIT_CAPACITY
        );
        data[3] = abi.encodeWithSelector(
            EtherFiRateLimiter.setRemaining.selector,
            EXIT_LIMIT_ID,
            EXIT_CAPACITY
        );
        data[4] = abi.encodeWithSelector(
            EtherFiRateLimiter.setCapacity.selector,
            UNRESTAKING_LIMIT_ID,
            UNRESTAKING_CAPACITY
        );
        data[5] = abi.encodeWithSelector(
            EtherFiRateLimiter.setRemaining.selector,
            UNRESTAKING_LIMIT_ID,
            UNRESTAKING_CAPACITY
        );

        writeSafeJson(
            "script/operations/rate-limits",
            "raise-rate-limits.json",
            ETHERFI_OPERATING_ADMIN,
            targets,
            values,
            data,
            1
        );
    }
}
