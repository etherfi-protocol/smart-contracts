// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../../utils/utils.sol";
import {EtherFiRateLimiter} from "../../../src/EtherFiRateLimiter.sol";

// Reduce consolidation and exit rate limits:
//   forge script script/operations/rate-limits/ReduceRateLimits.s.sol --fork-url $MAINNET_RPC_URL -vvvv
contract ReduceRateLimits is Script, Utils {
    EtherFiRateLimiter internal constant RATE_LIMITER =
        EtherFiRateLimiter(ETHERFI_RATE_LIMITER);

    // Must match EtherFiNodesManager constants
    bytes32 internal constant EXIT_LIMIT_ID =
        keccak256("EXIT_REQUEST_LIMIT_ID");
    bytes32 internal constant CONSOLIDATION_LIMIT_ID =
        keccak256("CONSOLIDATION_REQUEST_LIMIT_ID");

    uint256 internal constant FULL_EXIT_GWEI = 2_048_000_000_000;
    uint256 internal constant SECONDS_PER_DAY = 86_400;

    // ---------------------------------------------------------------
    // Consolidation: 520 validators/day
    //   capacity = 520 * 2_048_000_000_000 = 1_064_960_000_000_000
    //   refill   = 1_064_960_000_000_000 / 86_400 ~ 12_325_925_926
    // ---------------------------------------------------------------
    uint64 internal constant CONSOLIDATION_CAPACITY = 1_064_960_000_000_000;
    uint64 internal constant CONSOLIDATION_REFILL = 12_325_925_926;

    // ---------------------------------------------------------------
    // Exits: 15 validators/day (15 * 2048 ETH = 30,720 ETH)
    //   capacity = 15 * 2_048_000_000_000 = 30_720_000_000_000
    //   refill   = 30_720_000_000_000 / 86_400 ~ 355_555_556
    // ---------------------------------------------------------------
    uint64 internal constant EXIT_CAPACITY = 30_720_000_000_000;
    uint64 internal constant EXIT_REFILL = 355_555_556;

    function run() external {
        _writeGnosisTxFiles();
        _simulateOnFork();
    }

    function _simulateOnFork() internal {
        _logLimits("=== Before ===");

        vm.startPrank(ETHERFI_OPERATING_ADMIN);
        RATE_LIMITER.setCapacity(CONSOLIDATION_LIMIT_ID, CONSOLIDATION_CAPACITY);
        RATE_LIMITER.setRefillRate(CONSOLIDATION_LIMIT_ID, CONSOLIDATION_REFILL);
        RATE_LIMITER.setCapacity(EXIT_LIMIT_ID, EXIT_CAPACITY);
        RATE_LIMITER.setRefillRate(EXIT_LIMIT_ID, EXIT_REFILL);
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
            "Consolidation - validators/day:",
            uint256(cCap) / FULL_EXIT_GWEI
        );

        (uint64 eCap, uint64 eRem, uint64 eRefill,) =
            RATE_LIMITER.getLimit(EXIT_LIMIT_ID);
        console2.log("Exit - capacity:", eCap);
        console2.log("Exit - remaining:", eRem);
        console2.log("Exit - refill/sec:", eRefill);
        console2.log("Exit - ETH/day:", uint256(eCap) / 1e9);
        console2.log("");
    }

    function _writeGnosisTxFiles() internal {
        uint256 txCount = 4;
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
            EtherFiRateLimiter.setRefillRate.selector,
            CONSOLIDATION_LIMIT_ID,
            CONSOLIDATION_REFILL
        );
        data[2] = abi.encodeWithSelector(
            EtherFiRateLimiter.setCapacity.selector,
            EXIT_LIMIT_ID,
            EXIT_CAPACITY
        );
        data[3] = abi.encodeWithSelector(
            EtherFiRateLimiter.setRefillRate.selector,
            EXIT_LIMIT_ID,
            EXIT_REFILL
        );

        writeSafeJson(
            "script/operations/rate-limits",
            "reduce-rate-limits.json",
            ETHERFI_OPERATING_ADMIN,
            targets,
            values,
            data,
            1
        );
    }
}
