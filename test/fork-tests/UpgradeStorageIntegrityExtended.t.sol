// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";

import {SecurityUpgradesConstants} from "@scripts/upgrades/security-upgrades/Constants.s.sol";

import {EETH as EETHToken} from "@etherfi/core/EETH.sol";
import {WeETH as WeETHToken} from "@etherfi/core/WeETH.sol";
import {Liquifier} from "@etherfi/deposits/Liquifier.sol";
import {EtherFiAdmin} from "@etherfi/oracle/EtherFiAdmin.sol";
import {StakingManager} from "@etherfi/staking/StakingManager.sol";
import {EtherFiNodesManager} from "@etherfi/staking/EtherFiNodesManager.sol";
import {EtherFiRedemptionManager} from "@etherfi/withdrawals/EtherFiRedemptionManager.sol";
import {MembershipManager} from "@etherfi/archive/membership/MembershipManager.sol";
import {Blacklister} from "@etherfi/governance/Blacklister.sol";

import {ILiquifier} from "@etherfi/deposits/interfaces/ILiquifier.sol";
import {IEtherFiAdmin} from "@etherfi/oracle/interfaces/IEtherFiAdmin.sol";
import {IEtherFiRedemptionManager} from "@etherfi/withdrawals/interfaces/IEtherFiRedemptionManager.sol";

/// @notice Closes the storage-layout fork-coverage gap (security review Vuln 2 / storage-F1):
///         RoleMigrationStorageIntegrity + UpgradeStorageIntegrity only diff LiquidityPool,
///         WithdrawRequestNFT, EtherFiOracle, NodeOperatorManager, AuctionManager and
///         EtherFiRestaker. The 8 proxies below were referenced but never slot-scanned, even
///         though the OZ->Deprecated* shim migration moves their base-region storage.
///
///         This extends the established slot-scan pattern (vm.load 0..SCAN before/after the
///         impl swap, assert 0 drift) to all 8. For the value-bearing token proxies (EETH,
///         WeETH) it additionally asserts the storage-backed `totalSupply()` reads identically
///         through the NEW impl — a getter that resolves through the new layout, so a shifted
///         `totalShares`/`_balances` slot would surface as a mismatch.
///
///         Impl swap is done via the ERC1967 implementation slot (auth-free; plain `upgradeTo`
///         runs no initializer and writes no app storage, so a direct slot poke is faithful).
///
///         Requires MAINNET_RPC_URL; no-ops off a chainid-1 fork.
contract UpgradeStorageIntegrityExtendedTest is Test, SecurityUpgradesConstants {
    uint256 internal constant SCAN_SLOTS = 400;
    // ERC1967 implementation slot: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 internal constant IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal blacklister;

    function setUp() public {
        if (block.chainid != 1) return;
        // Fresh Blacklister only to satisfy the non-zero constructor checks on the token impls;
        // it is an immutable (bytecode) arg and does not affect storage layout.
        blacklister = address(new Blacklister(ROLE_REGISTRY));
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------
    function _snapshot(address proxy) internal view returns (bytes32[] memory snap) {
        snap = new bytes32[](SCAN_SLOTS);
        for (uint256 i = 0; i < SCAN_SLOTS; i++) {
            snap[i] = vm.load(proxy, bytes32(i));
        }
    }

    function _diff(string memory label, address proxy, bytes32[] memory pre) internal returns (uint256 drifts) {
        for (uint256 i = 0; i < SCAN_SLOTS; i++) {
            if (vm.load(proxy, bytes32(i)) != pre[i]) {
                drifts++;
                emit log_named_uint(string.concat(label, " drift slot"), i);
            }
        }
    }

    function _swapImpl(address proxy, address newImpl) internal {
        vm.store(proxy, IMPL_SLOT, bytes32(uint256(uint160(newImpl))));
        assertEq(vm.load(proxy, IMPL_SLOT), bytes32(uint256(uint160(newImpl))), "impl slot not set");
    }

    /// @dev Snapshot -> swap -> assert 0 sequential drift.
    function _checkLayout(string memory label, address proxy, address newImpl) internal {
        bytes32[] memory pre = _snapshot(proxy);
        _swapImpl(proxy, newImpl);
        assertEq(_diff(label, proxy, pre), 0, string.concat(label, ": sequential storage drifted"));
    }

    // ---------------------------------------------------------------------------
    // Value-bearing tokens: layout drift would corrupt balances, so also assert the
    // storage-backed totalSupply() reads identically through the new impl.
    // ---------------------------------------------------------------------------
    function test_storage_EETH() public {
        if (block.chainid != 1) return;
        uint256 preSupply = EETHToken(EETH).totalSupply();

        address newImpl = address(new EETHToken(LIQUIDITY_POOL, ROLE_REGISTRY, blacklister, ETHERFI_RATE_LIMITER));
        _checkLayout("EETH", EETH, newImpl);

        assertEq(EETHToken(EETH).totalSupply(), preSupply, "EETH.totalSupply changed across upgrade");
        assertEq(EETHToken(EETH).getImplementation(), newImpl, "EETH impl mismatch");
    }

    function test_storage_WeETH() public {
        if (block.chainid != 1) return;
        uint256 preSupply = WeETHToken(WEETH).totalSupply();

        address newImpl = address(new WeETHToken(EETH, LIQUIDITY_POOL, ROLE_REGISTRY, blacklister));
        _checkLayout("WeETH", WEETH, newImpl);

        assertEq(WeETHToken(WEETH).totalSupply(), preSupply, "WeETH.totalSupply changed across upgrade");
        assertEq(WeETHToken(WEETH).getImplementation(), newImpl, "WeETH impl mismatch");
    }

    // ---------------------------------------------------------------------------
    // Remaining 6 proxies: sequential slot-scan + post-swap impl resolves.
    // ---------------------------------------------------------------------------
    function test_storage_EtherFiAdmin() public {
        if (block.chainid != 1) return;
        address newImpl = address(new EtherFiAdmin(
            IEtherFiAdmin.ConstructorAddresses({
                etherFiOracle: ETHERFI_ORACLE,
                stakingManager: STAKING_MANAGER,
                auctionManager: AUCTION_MANAGER,
                etherFiNodesManager: ETHERFI_NODES_MANAGER,
                liquidityPool: LIQUIDITY_POOL,
                withdrawRequestNft: WITHDRAW_REQUEST_NFT,
                roleRegistry: ROLE_REGISTRY,
                priorityWithdrawalQueue: PRIORITY_WITHDRAWAL_QUEUE
            }),
            ADMIN_MAX_REBASE_APR_BPS,
            ADMIN_MAX_VALIDATOR_TASK_BATCH_SIZE,
            ADMIN_STALE_ORACLE_REPORT_BLOCK_WINDOW,
            ADMIN_MAX_FINALIZED_WITHDRAWAL_AMOUNT_PER_DAY,
            ADMIN_MAX_VALIDATORS_TO_APPROVE_PER_DAY,
            ADMIN_MAX_REQUESTS_TO_FINALIZE_PER_REPORT
        ));
        _checkLayout("EtherFiAdmin", ETHERFI_ADMIN, newImpl);
        assertEq(EtherFiAdmin(ETHERFI_ADMIN).getImplementation(), newImpl, "EtherFiAdmin impl mismatch");
    }

    function test_storage_Liquifier() public {
        if (block.chainid != 1) return;
        address newImpl = address(new Liquifier(
            ILiquifier.ConstructorAddresses({
                liquidityPool: LIQUIDITY_POOL,
                lidoWithdrawalQueue: LIDO_WITHDRAWAL_QUEUE,
                lido: STETH,
                stEth_Eth_Pool: STETH_ETH_CURVE_POOL,
                roleRegistry: ROLE_REGISTRY,
                stEthPriceFeed: STETH_PRICE_FEED,
                blacklister: blacklister,
                etherfiRestaker: ETHERFI_RESTAKER,
                l1SyncPool: ETHERFI_L1_SYNC_POOL_ETH
            }),
            LIQUIFIER_MIN_DISCOUNT_BPS, LIQUIFIER_STALE_PRICE_WINDOW, LIQUIFIER_MAX_PRICE_DEVIATION_BPS,
            LIQUIFIER_MAX_PRICE_THRESHOLD
        ));
        _checkLayout("Liquifier", LIQUIFIER, newImpl);
        assertEq(Liquifier(payable(LIQUIFIER)).getImplementation(), newImpl, "Liquifier impl mismatch");
    }

    function test_storage_StakingManager() public {
        if (block.chainid != 1) return;
        address newImpl = address(new StakingManager(
            LIQUIDITY_POOL, ETHERFI_NODES_MANAGER, ETH2_DEPOSIT_CONTRACT,
            AUCTION_MANAGER, ETHERFI_NODE_BEACON, ROLE_REGISTRY
        ));
        _checkLayout("StakingManager", STAKING_MANAGER, newImpl);
    }

    function test_storage_EtherFiNodesManager() public {
        if (block.chainid != 1) return;
        address newImpl = address(new EtherFiNodesManager(STAKING_MANAGER, ROLE_REGISTRY, ETHERFI_RATE_LIMITER));
        _checkLayout("EtherFiNodesManager", ETHERFI_NODES_MANAGER, newImpl);
    }

    function test_storage_EtherFiRedemptionManager() public {
        if (block.chainid != 1) return;
        address newImpl = address(new EtherFiRedemptionManager(
            IEtherFiRedemptionManager.ConstructorAddresses({
                liquidityPool: LIQUIDITY_POOL,
                eEth: EETH,
                weEth: WEETH,
                treasury: TREASURY,
                roleRegistry: ROLE_REGISTRY,
                etherFiRestaker: ETHERFI_RESTAKER,
                priorityWithdrawalQueue: PRIORITY_WITHDRAWAL_QUEUE,
                blacklister: blacklister,
                stEthPriceFeed: STETH_PRICE_FEED
            }),
            RM_MAX_EXIT_FEE_SPLIT_TO_TREASURY_BPS, RM_MAX_EXIT_FEE_BPS, RM_MAX_LOW_WATERMARK_BPS_OF_TVL,
            RM_STALE_PRICE_WINDOW, RM_MAX_PRICE_THRESHOLD
        ));
        _checkLayout("EtherFiRedemptionManager", ETHERFI_REDEMPTION_MANAGER, newImpl);
        assertEq(EtherFiRedemptionManager(payable(ETHERFI_REDEMPTION_MANAGER)).getImplementation(), newImpl, "ERM impl mismatch");
    }

    function test_storage_MembershipManager() public {
        if (block.chainid != 1) return;
        address newImpl = address(new MembershipManager(
            EETH, LIQUIDITY_POOL, MEMBERSHIP_NFT, ROLE_REGISTRY, blacklister
        ));
        _checkLayout("MembershipManager", MEMBERSHIP_MANAGER, newImpl);
    }
}
