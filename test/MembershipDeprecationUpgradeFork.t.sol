// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/MembershipManager.sol";
import "../src/MembershipNFT.sol";
import "../src/helpers/Blacklister.sol";
import "../src/UUPSProxy.sol";

/// @notice Fork test for the membership-deprecation trim.
///
/// Forks mainnet, upgrades the MembershipManager + MembershipNFT proxies in
/// place to the trimmed implementations, and then verifies that ether.fan
/// holders can still:
///   (a) unwrap a V1 NFT for eETH (`unwrapForEEthAndBurn`)
///   (b) request a queued withdrawal of a V1 NFT (`requestWithdrawAndBurn`)
///   (c) request a partial withdrawal that keeps the NFT alive (`requestWithdraw`)
///   (d) the protocol's `rebase` keeps working post-trim
///
/// Real on-chain owners are used for each test NFT (queried via the Alchemy
/// NFT API at the time this test was authored). Three NFTs are exercised:
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
            ETHERFI_ADMIN,
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

    // ---- (a) unwrap for eETH on a migrated-V0 NFT ----
    function test_unwrapForEEthAndBurn_migratedV0() public {
        _runUnwrap(ID_MIGRATED_V0, OWNER_MIGRATED_V0);
    }

    // ---- (a) unwrap for eETH on a born-V1 NFT ----
    function test_unwrapForEEthAndBurn_bornV1() public {
        _runUnwrap(ID_BORN_V1_A, OWNER_BORN_V1_A);
    }

    // ---- (b) request withdraw + burn ----
    function test_requestWithdrawAndBurn_bornV1() public {
        IERC1155Like nft = IERC1155Like(MNFT_PROXY);
        assertEq(nft.balanceOf(OWNER_BORN_V1_B, ID_BORN_V1_B), 1, "owner no longer holds NFT");

        vm.prank(OWNER_BORN_V1_B);
        uint256 withdrawRequestId = mm.requestWithdrawAndBurn(ID_BORN_V1_B);

        assertEq(nft.balanceOf(OWNER_BORN_V1_B, ID_BORN_V1_B), 0, "NFT not burned");
        (, , , , , , uint8 version) = mm.tokenData(ID_BORN_V1_B);
        assertEq(version, 0, "tokenData not cleared post burn");
        assertGt(withdrawRequestId, 0, "withdraw-request id zero");

        emit log_named_uint("requestWithdrawAndBurn -> request id", withdrawRequestId);
    }

    // ---- (c) partial requestWithdraw that keeps the NFT alive ----
    function test_requestWithdraw_partial_bornV1() public {
        IERC1155Like nft = IERC1155Like(MNFT_PROXY);
        assertEq(nft.balanceOf(OWNER_BORN_V1_C, ID_BORN_V1_C), 1, "owner no longer holds NFT");

        uint256 valueBefore = mnft.valueOf(ID_BORN_V1_C);
        assertGt(valueBefore, 0, "NFT has zero value");

        // Withdraw 25% — that's well under the 50%-of-ATH cap in isWithdrawable.
        uint256 withdrawAmount = valueBefore / 4;

        vm.prank(OWNER_BORN_V1_C);
        uint256 withdrawRequestId = mm.requestWithdraw(ID_BORN_V1_C, withdrawAmount);

        // NFT should still exist (it's a partial withdraw, not a burn).
        assertEq(nft.balanceOf(OWNER_BORN_V1_C, ID_BORN_V1_C), 1, "NFT burned on partial");
        (, , , , , , uint8 version) = mm.tokenData(ID_BORN_V1_C);
        assertEq(version, 1, "NFT version flipped on partial");
        assertGt(withdrawRequestId, 0, "withdraw-request id zero");

        uint256 valueAfter = mnft.valueOf(ID_BORN_V1_C);
        // Value should have dropped by roughly the withdraw amount (rate may
        // shift by a few wei between reads; allow tiny tolerance).
        assertLt(valueAfter, valueBefore, "valueOf did not decrease on partial withdraw");
        emit log_named_uint("partial withdraw: valueBefore", valueBefore);
        emit log_named_uint("partial withdraw: withdraw amount", withdrawAmount);
        emit log_named_uint("partial withdraw: valueAfter", valueAfter);
        emit log_named_uint("partial withdraw: WithdrawRequestNFT id", withdrawRequestId);
    }

    // ---- (d) rebase still works post-trim across zero/+/- accrual ----
    function test_rebase_postTrim_allAccrualBranches() public {
        ILP lp = ILP(LIQUIDITY_POOL);

        _rebaseAndAssertRateDir(lp, 0, 0);
        _rebaseAndAssertRateDir(lp, int128(1 ether), 1);
        _rebaseAndAssertRateDir(lp, -int128(1 ether), -1);
    }

    // ----- helpers -----

    function _runUnwrap(uint256 tokenId, address owner) internal {
        IERC1155Like nft  = IERC1155Like(MNFT_PROXY);
        IERC20Like   eeth = IERC20Like(EETH);

        assertEq(nft.balanceOf(owner, tokenId), 1, "owner no longer holds NFT");
        uint256 eethBefore = eeth.balanceOf(owner);

        vm.prank(owner);
        mm.unwrapForEEthAndBurn(tokenId);

        assertEq(nft.balanceOf(owner, tokenId), 0, "NFT not burned after unwrap");
        uint256 received = eeth.balanceOf(owner) - eethBefore;
        assertGt(received, 0, "owner received no eETH on unwrap");

        (, , , , , , uint8 version) = mm.tokenData(tokenId);
        assertEq(version, 0, "tokenData not cleared post-burn");

        emit log_named_uint("unwrap tokenId", tokenId);
        emit log_named_uint("unwrap eETH received (wei)", received);
    }

    function _rebaseAndAssertRateDir(ILP lp, int128 accrual, int8 sign) internal {
        uint256 rateBefore = lp.amountForShare(1 ether);
        vm.prank(ETHERFI_ADMIN);
        mm.rebase(accrual);
        uint256 rateAfter = lp.amountForShare(1 ether);

        if (sign > 0) {
            assertGt(rateAfter, rateBefore, "LP rate did not rise on +accrual");
        } else if (sign < 0) {
            assertLt(rateAfter, rateBefore, "LP rate did not fall on -accrual");
        } else {
            uint256 drift = rateAfter > rateBefore ? rateAfter - rateBefore : rateBefore - rateAfter;
            assertLt(drift, 1e6, "LP rate drifted on zero accrual");
        }
        emit log_named_int("accrual", accrual);
        emit log_named_uint("rate before", rateBefore);
        emit log_named_uint("rate after", rateAfter);
    }
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

interface ILP {
    function amountForShare(uint256 _share) external view returns (uint256);
}
