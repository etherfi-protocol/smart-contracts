// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "@etherfi/archive/membership/MembershipManager.sol";
import "@etherfi/archive/membership/MembershipNFT.sol";
import "@etherfi/governance/Blacklister.sol";
import "@etherfi/utils/UUPSProxy.sol";

/// @notice Fork rehearsal of the membership wind-down.
///
/// Forks mainnet, upgrades the MembershipManager + MembershipNFT proxies in
/// place to the wind-down implementations, and then verifies that the
/// operating multisig can `forceExit` real holders: each NFT is burned and its
/// eETH (minus the burn fee) lands with the owner, with no LiquidityPool call.
///
/// Rebase routing is no longer a MembershipManager concern (EARN-1440 routes
/// rebase EtherFiAdmin → LiquidityPool directly); it is covered separately by
/// the EtherFiOracle `executeTasks` and LiquidityPool rebase tests.
///
/// Real on-chain owners are used for each test NFT (queried via the Alchemy
/// NFT API at the time this test was authored). Four NFTs are exercised:
///   - 6251: previously V0, migrated to V1 in the one-shot mainnet migration.
///   - 7500: born V1 (above the highest V0 id, 6251).
///   - 8500: born V1.
///   - 9900: born V1.
///
/// Run:
///   forge test --match-contract MembershipDeprecationUpgradeForkTest \
///     --fork-url $MAINNET_RPC_URL -vv
contract MembershipDeprecationUpgradeForkTest is Test {

    // Deployed proxies + infra
    address constant MM_PROXY        = 0x3d320286E014C3e1ce99Af6d6B00f0C1D63E3000;
    address constant MNFT_PROXY      = 0xb49e4420eA6e35F98060Cd133842DbeA9c27e479;
    address constant LIQUIDITY_POOL  = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address constant EETH            = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address constant ETHERFI_ADMIN   = 0x0EF8fa4760Db8f5Cd4d993f3e3416f30f942D705;
    address constant ROLE_REGISTRY   = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;
    // Existing owner / upgrade authority on the deployed pre-PR-420 proxies.
    // The deployed MM / MNFT still use OZ UUPS Ownable for upgrade auth; the
    // owner is the upgrade timelock (verified by querying `owner()` on chain).
    address constant UPGRADE_TIMELOCK = 0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761;

    // Real fan NFTs + owners
    uint256 constant ID_MIGRATED_V0 = 6251;                                                  // was V0, migrated
    address constant OWNER_MIGRATED_V0 = 0x8a2855ed794d9cc1e39F04C0CF947212aFC0A079;

    uint256 constant ID_BORN_V1_A = 7500;                                                    // born V1
    address constant OWNER_BORN_V1_A = 0x277f5499b1dB94e215f24db590334cd488DF7d44;

    uint256 constant ID_BORN_V1_B = 8500;                                                    // born V1
    address constant OWNER_BORN_V1_B = 0xba3298c9FA06016073Fe967AB3F9D6705d96315B;

    uint256 constant ID_BORN_V1_C = 9900;                                                    // born V1
    address constant OWNER_BORN_V1_C = 0x8B3f14F0582FbF275BE87d265C931B4dfD5F13B7;

    MembershipManager mm;
    MembershipNFT     mnft;

    function setUp() public {
        vm.selectFork(vm.createFork(vm.envString("MAINNET_RPC_URL")));

        mm   = MembershipManager(payable(MM_PROXY));
        mnft = MembershipNFT(MNFT_PROXY);

        // PR-420 introduces a Blacklister; on mainnet at the time this test was
        // written it has not been deployed yet, so we deploy a fresh empty one
        // (no users blacklisted) and wire it into the upgraded implementations.
        Blacklister blacklisterImpl = new Blacklister(ROLE_REGISTRY);
        UUPSProxy bproxy = new UUPSProxy(
            address(blacklisterImpl),
            abi.encodeWithSignature("initialize()")
        );
        address blacklister = address(bproxy);

        // Deploy new implementations + UUPS-upgrade both proxies.
        MembershipManager newMmImpl = new MembershipManager(
            EETH,
            LIQUIDITY_POOL,
            MNFT_PROXY,
            ROLE_REGISTRY,
            blacklister
        );
        MembershipNFT newMnftImpl = new MembershipNFT(
            LIQUIDITY_POOL,
            MM_PROXY,
            ROLE_REGISTRY,
            blacklister
        );

        // The pre-PR-420 deployed proxies use OZ Ownable for _authorizeUpgrade.
        // owner() == UPGRADE_TIMELOCK, so pranking as the timelock works for
        // this one-shot upgrade-from-old-impl call.
        vm.startPrank(UPGRADE_TIMELOCK);
        IUUPS(MM_PROXY).upgradeTo(address(newMmImpl));
        IUUPS(MNFT_PROXY).upgradeTo(address(newMnftImpl));
        vm.stopPrank();

        // Sanity: getImplementation() now points at the freshly-deployed code.
        assertEq(mm.getImplementation(), address(newMmImpl), "MM impl not upgraded");
        assertEq(mnft.getImplementation(), address(newMnftImpl), "MNFT impl not upgraded");
    }

    function test_forceExit_realHolders() public {
        uint256[] memory ids = new uint256[](4);
        address[] memory owners = new address[](4);
        (ids[0], owners[0]) = (ID_MIGRATED_V0, OWNER_MIGRATED_V0);
        (ids[1], owners[1]) = (ID_BORN_V1_A, OWNER_BORN_V1_A);
        (ids[2], owners[2]) = (ID_BORN_V1_B, OWNER_BORN_V1_B);
        (ids[3], owners[3]) = (ID_BORN_V1_C, OWNER_BORN_V1_C);

        IERC1155Like nft = IERC1155Like(MNFT_PROXY);
        IERC20Like eeth = IERC20Like(EETH);
        (, uint256 burnFeeAmount,) = mm.getFees();

        uint256[] memory expected = new uint256[](4);
        uint256[] memory before = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) {
            assertEq(nft.balanceOf(owners[i], ids[i]), 1, "owner no longer holds NFT");
            uint256 value = mnft.valueOf(ids[i]);
            uint256 fee = mm.hasMetBurnFeeWaiverPeriod(ids[i]) ? 0 : (burnFeeAmount < value ? burnFeeAmount : value);
            expected[i] = value - fee;
            before[i] = eeth.balanceOf(owners[i]);
        }

        vm.prank(_operatingMultisigHolder());
        mm.forceExit(ids, owners);

        for (uint256 i = 0; i < 4; i++) {
            assertEq(nft.balanceOf(owners[i], ids[i]), 0, "NFT not burned");
            (, , , , , , uint8 version) = mm.tokenData(ids[i]);
            assertEq(version, 0, "tokenData not cleared");
            assertApproxEqAbs(eeth.balanceOf(owners[i]) - before[i], expected[i], 2, "owner payout mismatch");
            emit log_named_uint("forceExit tokenId", ids[i]);
            emit log_named_uint("forceExit eETH paid (wei)", expected[i]);
        }
    }

    function test_sweepRemainingFunds_revertsWhileHoldersRemain() public {
        vm.prank(_operatingMultisigHolder());
        vm.expectRevert(MembershipManager.TierVaultsNotEmpty.selector);
        mm.sweepRemainingFunds(address(0xdead));
    }

    // ----- helpers -----

    function _operatingMultisigHolder() internal returns (address holder) {
        holder = makeAddr("operatingMultisig");
        IRoleRegistryLike registry = IRoleRegistryLike(ROLE_REGISTRY);
        bytes32 role = registry.OPERATION_MULTISIG_ROLE();
        vm.prank(registry.owner());
        registry.grantRole(role, holder);
    }
}

interface IRoleRegistryLike {
    function owner() external view returns (address);
    function OPERATION_MULTISIG_ROLE() external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;
}

interface IUUPS {
    function upgradeTo(address newImplementation) external;
}

interface IERC1155Like {
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
}
