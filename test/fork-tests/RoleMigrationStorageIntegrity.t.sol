// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../script/deploys/Deployed.s.sol";
import "../../src/EtherFiOracle.sol";
import "../../src/NodeOperatorManager.sol";
import "../../src/AuctionManager.sol";
import "../../src/EtherFiRestaker.sol";

interface IUUPSProxy {
    function upgradeTo(address newImpl) external;
}

interface IOwnableRead {
    function owner() external view returns (address);
}

/// @notice Fork test: verifies sequential storage layout is preserved across the
///         RoleRegistry admin migration for 4 mainnet proxies. Also asserts the
///         new immutable `roleRegistry` member reads non-zero post-upgrade.
///         Requires MAINNET_RPC_URL.
///
/// Proxies covered:
///   - ETHERFI_ORACLE        (0x57Aa...)
///   - NODE_OPERATOR_MANAGER (0xd5ed...)
///   - AUCTION_MANAGER       (0x00C4...)
///   - ETHERFI_RESTAKER      (0x1B7a...)
///
/// BucketRateLimiter is NOT included: it has no standalone mainnet proxy.
/// It is deployed fresh in unit tests via TestSetup and covered by
/// BucketRateLimiterRoleMigration.t.sol.
///
/// Slot scan strategy:
///   All 4 contracts have sequential storage layouts well below slot 400.
///   Immutables live in bytecode, not storage, so they cannot produce false
///   drift. The ERC-1967 implementation slot (~2^252) is outside 0..399 and
///   also cannot produce false drift.
contract RoleMigrationStorageIntegrityTest is Test, Deployed {
    uint256 internal constant SCAN_SLOTS = 400;

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    function _snapshot(address proxy) internal view returns (bytes32[] memory snap) {
        snap = new bytes32[](SCAN_SLOTS);
        for (uint256 i = 0; i < SCAN_SLOTS; i++) {
            snap[i] = vm.load(proxy, bytes32(i));
        }
    }

    /// @dev Returns the number of slots that changed. Logs each drifted slot index.
    function _diff(
        string memory label,
        address proxy,
        bytes32[] memory pre
    ) internal returns (uint256 drifts) {
        for (uint256 i = 0; i < SCAN_SLOTS; i++) {
            bytes32 cur = vm.load(proxy, bytes32(i));
            if (cur != pre[i]) {
                drifts++;
                emit log_named_uint(string.concat(label, " drift slot"), i);
            }
        }
    }

    /// @dev All 4 proxies use `_authorizeUpgrade onlyOwner`.
    function _upgradeProxy(address proxy, address newImpl) internal {
        address proxyOwner = IOwnableRead(proxy).owner();
        vm.prank(proxyOwner);
        IUUPSProxy(proxy).upgradeTo(newImpl);
    }

    // ---------------------------------------------------------------------------
    // Internal: snapshot + upgrade + diff for EtherFiOracle and NodeOperatorManager
    // ---------------------------------------------------------------------------
    function _checkOracleAndNom() internal {
        bytes32[] memory preOracle = _snapshot(ETHERFI_ORACLE);
        bytes32[] memory preNOM    = _snapshot(NODE_OPERATOR_MANAGER);

        address newOracle = address(new EtherFiOracle(ROLE_REGISTRY));
        address newNOM    = address(new NodeOperatorManager(ROLE_REGISTRY));

        _upgradeProxy(ETHERFI_ORACLE,        newOracle);
        _upgradeProxy(NODE_OPERATOR_MANAGER, newNOM);

        assertEq(_diff("EtherFiOracle",       ETHERFI_ORACLE,        preOracle), 0);
        assertEq(_diff("NodeOperatorManager", NODE_OPERATOR_MANAGER, preNOM),    0);

        assertEq(address(EtherFiOracle(ETHERFI_ORACLE).roleRegistry()),              ROLE_REGISTRY);
        assertEq(address(NodeOperatorManager(NODE_OPERATOR_MANAGER).roleRegistry()), ROLE_REGISTRY);
    }

    // ---------------------------------------------------------------------------
    // Internal: snapshot + upgrade + diff for AuctionManager and EtherFiRestaker
    // ---------------------------------------------------------------------------
    function _checkAmAndEr() internal {
        bytes32[] memory preAM = _snapshot(AUCTION_MANAGER);
        bytes32[] memory preER = _snapshot(ETHERFI_RESTAKER);

        address newAM = address(new AuctionManager(ROLE_REGISTRY));
        address newER = address(new EtherFiRestaker(
            EIGENLAYER_REWARDS_COORDINATOR,
            ETHERFI_REDEMPTION_MANAGER,
            ROLE_REGISTRY,
            ETHERFI_RATE_LIMITER
        ));

        _upgradeProxy(AUCTION_MANAGER,  newAM);
        _upgradeProxy(ETHERFI_RESTAKER, newER);

        assertEq(_diff("AuctionManager",  AUCTION_MANAGER,  preAM), 0);
        assertEq(_diff("EtherFiRestaker", ETHERFI_RESTAKER, preER), 0);

        assertEq(address(AuctionManager(AUCTION_MANAGER).roleRegistry()),                ROLE_REGISTRY);
        assertEq(address(EtherFiRestaker(payable(ETHERFI_RESTAKER)).roleRegistry()),     ROLE_REGISTRY);
        assertEq(address(EtherFiRestaker(payable(ETHERFI_RESTAKER)).rateLimiter()),      ETHERFI_RATE_LIMITER);
    }

    // ---------------------------------------------------------------------------
    // Test entry point
    // ---------------------------------------------------------------------------

    function test_storageIntegrityAcrossAllProxies() public {
        // Skip if not running against a mainnet fork.
        if (block.chainid != 1) return;

        _checkOracleAndNom();
        _checkAmAndEr();
    }
}
