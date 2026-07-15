// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "@scripts/deploys/Deployed.s.sol";
import "@etherfi/core/LiquidityPool.sol";
import "@etherfi/core/interfaces/ILiquidityPool.sol";
import "@etherfi/withdrawals/WithdrawRequestNFT.sol";
import "@etherfi/withdrawals/PriorityWithdrawalQueue.sol";
import "@etherfi/withdrawals/interfaces/IWithdrawRequestNFT.sol";
import "@etherfi/governance/RoleRegistry.sol";
import "@etherfi/utils/UUPSProxy.sol";
import "@etherfi/governance/Blacklister.sol";

interface IUUPSProxy { function upgradeTo(address newImpl) external; }
interface IOwnableRead { function owner() external view returns (address); }

/// @notice Fork tests for the REVERT escrow-drain strategy (EARN-1481, REVERT_PLAYBOOK §6.5).
///
/// The 26Q2 upgrade migrates pending-withdrawal escrow OUT of the LiquidityPool into the
/// WithdrawRequestNFT (`LiquidityPool.initializeOnUpgradeV2`). A code-only revert would strand
/// that ETH in the WRN. The chosen revert strategy avoids any reverse-migration code: BEFORE
/// executing the revert, **claim every finalized request** so the WRN escrow drains to 0 through
/// the (permissionless) front door — then the impl revert moves no value.
///
/// These tests prove the load-bearing properties of that strategy against live mainnet state:
///   1. Each claim correctly decrements WRN escrow by the request's full `amountOfEEth`, keeps the
///      `balance == ethAmountLockedForWithdrawal` invariant, sweeps any leftover to the LP, and
///      reconciles LP accounting (`totalValueOutOfLp -= amountOfEEth`). => "claim all ⇒ escrow 0".
///   2. Claims work while the contract is PAUSED (so the drain runs inside the pause window).
///   3. A finalized request owned by a BLACKLISTED address cannot be claimed and its escrow is
///      stuck (REVERT_PLAYBOOK §6.5 edge 1) — the operational caveat the playbook calls out.
///
/// Requires MAINNET_RPC_URL.
contract RevertEscrowDrainTest is Test, Deployed {
    Blacklister internal blacklister;

    /// @dev Last mainnet state before the 26Q2 security upgrade + escrow-drain
    ///      claim flush executed (2026-07-14, upgrade at block 25533308). These
    ///      tests validate the upgrade/migration path from live PRE-upgrade
    ///      state — the deployed post-upgrade impls dropped `owner()` and
    ///      already ran `initializeOnUpgradeV2`, so a latest-block fork can no
    ///      longer exercise them.
    uint256 constant PRE_UPGRADE_BLOCK = 25_526_000;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), PRE_UPGRADE_BLOCK);
        // The new impls wire a Blacklister as an immutable; deploy a fresh one for the harness.
        Blacklister bImpl = new Blacklister(ROLE_REGISTRY);
        blacklister = Blacklister(address(new UUPSProxy(address(bImpl), abi.encodeWithSelector(Blacklister.initialize.selector))));
    }

    // ─────────────────────────────────────────────────────────────────────
    // Harness: apply the security upgrade to LP / WRN / PWQ / RoleRegistry on the fork and run
    // the escrow migration (initializeOnUpgradeV2). Mirrors UpgradeStorageIntegrity.t.sol::_doUpgrade.
    // ─────────────────────────────────────────────────────────────────────
    function _doUpgrade() internal {
        address newLP = address(new LiquidityPool(
            ILiquidityPool.ConstructorAddresses({
                stakingManager: STAKING_MANAGER,
                nodesManager: ETHERFI_NODES_MANAGER,
                eETH: EETH,
                withdrawRequestNFT: WITHDRAW_REQUEST_NFT,
                liquifier: LIQUIFIER,
                etherFiRedemptionManager: ETHERFI_REDEMPTION_MANAGER,
                roleRegistry: ROLE_REGISTRY,
                priorityWithdrawalQueue: PRIORITY_WITHDRAWAL_QUEUE,
                blacklister: address(blacklister),
                etherFiAdminContract: ETHERFI_ADMIN,
                membershipManager: MEMBERSHIP_MANAGER
            })
        ));
        address newWRN = address(new WithdrawRequestNFT(LIQUIDITY_POOL, ROLE_REGISTRY, address(blacklister), ETHERFI_ADMIN));
        address newPQ = address(new PriorityWithdrawalQueue(LIQUIDITY_POOL, EETH, WEETH, address(blacklister), ROLE_REGISTRY, 1 hours));

        address roleRegOwner = IOwnableRead(ROLE_REGISTRY).owner();
        address wrnOwner = IOwnableRead(WITHDRAW_REQUEST_NFT).owner();

        vm.prank(roleRegOwner);
        IUUPSProxy(LIQUIDITY_POOL).upgradeTo(newLP);
        vm.prank(wrnOwner);
        IUUPSProxy(WITHDRAW_REQUEST_NFT).upgradeTo(newWRN);
        vm.prank(roleRegOwner);
        IUUPSProxy(PRIORITY_WITHDRAWAL_QUEUE).upgradeTo(newPQ);

        // Swap RoleRegistry last, then grant UPGRADE_TIMELOCK_ROLE so initializeOnUpgradeV2 passes.
        address newRR = address(new RoleRegistry(address(0xdead)));
        vm.prank(roleRegOwner);
        IUUPSProxy(ROLE_REGISTRY).upgradeTo(newRR);
        RoleRegistry rr = RoleRegistry(ROLE_REGISTRY);
        bytes32 upgradeRole = rr.UPGRADE_TIMELOCK_ROLE();
        vm.prank(roleRegOwner);
        rr.grantRole(upgradeRole, UPGRADE_TIMELOCK);

        LiquidityPool lp = LiquidityPool(payable(LIQUIDITY_POOL));
        if (!lp.escrowMigrationCompleted()) {
            vm.prank(UPGRADE_TIMELOCK);
            lp.initializeOnUpgradeV2();
        }
    }

    /// @dev Scan downward from lastFinalizedRequestId for a finalized + valid + unclaimed request
    ///      with a non-zero claimable amount. Returns 0 if none found in range.
    function _findClaimable(WithdrawRequestNFT wrn, uint256 startBelow) internal view returns (uint256 id, address owner) {
        uint32 lastFin = wrn.lastFinalizedRequestId();
        uint256 top = startBelow == 0 ? lastFin : (startBelow - 1 < lastFin ? startBelow - 1 : lastFin);
        for (uint256 i = 0; i < 1500; i++) {
            if (i > top) break;
            uint256 candidate = top - i;
            if (candidate == 0) break;
            (bool ok, bytes memory data) = address(wrn).staticcall(abi.encodeWithSignature("ownerOf(uint256)", candidate));
            if (!ok) continue;
            address o = abi.decode(data, (address));
            if (o == address(0)) continue;
            if (!wrn.isValid(candidate)) continue;
            if (wrn.getClaimableAmount(candidate) == 0) continue;
            return (candidate, o);
        }
        return (0, address(0));
    }

    /// @dev The new LP has no `ethAmountLockedForWithdrawal()` getter — the legacy slot is now
    ///      part of `__gap_3` (slot 220, packed at bit offset 8). Read it raw, same as
    ///      UpgradeStorageIntegrity.t.sol does.
    function _lpLegacyLocked(address lp) internal view returns (uint128) {
        bytes32 raw = vm.load(lp, bytes32(uint256(220)));
        return uint128(uint256(raw) >> 8);
    }

    function _grantSelf(bytes32 role) internal {
        address roleRegOwner = IOwnableRead(ROLE_REGISTRY).owner();
        vm.prank(roleRegOwner);
        (bool ok,) = ROLE_REGISTRY.call(abi.encodeWithSignature("grantRole(bytes32,address)", role, address(this)));
        require(ok, "grantSelf failed");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 1. A single claim drains WRN escrow correctly and reconciles LP accounting.
    //    This is the per-claim proof that "claim all finalized ⇒ WRN escrow 0".
    // ─────────────────────────────────────────────────────────────────────
    function test_claim_drainsEscrow_andReconcilesAccounting() public {
        _doUpgrade();
        WithdrawRequestNFT wrn = WithdrawRequestNFT(payable(WITHDRAW_REQUEST_NFT));
        LiquidityPool lp = LiquidityPool(payable(LIQUIDITY_POOL));

        // Post-migration the legacy LP locked slot is zeroed; the escrow lives in the WRN.
        assertEq(_lpLegacyLocked(address(lp)), 0, "legacy LP locked slot should be 0 post-migration");
        assertEq(address(wrn).balance, wrn.ethAmountLockedForWithdrawal(), "WRN balance must back its escrow counter exactly");
        assertGt(wrn.ethAmountLockedForWithdrawal(), 0, "fork has no migrated WRN escrow to drain");

        (uint256 id, address owner) = _findClaimable(wrn, 0);
        require(id != 0, "no finalized+valid+unclaimed request found");

        IWithdrawRequestNFT.WithdrawRequest memory req = wrn.getRequest(id);
        uint128 amt = uint128(req.amountOfEEth);          // escrowed amount removed on claim
        uint256 payout = wrn.getClaimableAmount(id);       // actual ETH paid (<= amt)

        uint256 lockedBefore  = wrn.ethAmountLockedForWithdrawal();
        uint256 outBefore     = lp.totalValueOutOfLp();
        uint256 inBefore      = lp.totalValueInLp();
        uint256 tvlBefore      = lp.getTotalPooledEther();
        uint256 ownerBalBefore = owner.balance;

        vm.prank(owner);
        wrn.claimWithdraw(id);

        // Escrow counter drops by the FULL escrowed amount (not the payout).
        assertEq(wrn.ethAmountLockedForWithdrawal(), lockedBefore - amt, "WRN escrow not reduced by amountOfEEth");
        // Invariant maintained: balance still exactly backs the (now smaller) escrow — leftover swept out.
        assertEq(address(wrn).balance, wrn.ethAmountLockedForWithdrawal(), "WRN balance/escrow invariant broken after claim");
        // LP totalValueOutOfLp falls by the full escrowed amount (claim payout + stranded sweep == amt).
        assertEq(lp.totalValueOutOfLp(), outBefore - amt, "totalValueOutOfLp not reduced by amountOfEEth");
        // The negative-rebase leftover (amt - payout) is credited back to totalValueInLp.
        assertEq(lp.totalValueInLp(), inBefore + (amt - payout), "totalValueInLp not credited the swept leftover");
        // Net protocol TVL drops by exactly the payout (the ETH that left to the withdrawer).
        assertEq(lp.getTotalPooledEther(), tvlBefore - payout, "TVL did not fall by payout");
        // Owner received the payout.
        assertApproxEqAbs(owner.balance - ownerBalBefore, payout, 1, "owner payout mismatch");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. Claiming a batch monotonically drives WRN escrow toward 0, holding the invariant at
    //    every step — the inductive proof that claiming ALL finalized requests empties the WRN.
    // ─────────────────────────────────────────────────────────────────────
    function test_batchDrain_monotonicallyReducesEscrow() public {
        _doUpgrade();
        WithdrawRequestNFT wrn = WithdrawRequestNFT(payable(WITHDRAW_REQUEST_NFT));

        uint256 prevLocked = wrn.ethAmountLockedForWithdrawal();
        assertGt(prevLocked, 0, "no escrow to drain");

        uint256 claims;
        uint256 cursor; // start from the top each time via _findClaimable's startBelow
        for (uint256 n = 0; n < 8; n++) {
            (uint256 id, address owner) = _findClaimable(wrn, cursor);
            if (id == 0) break;
            cursor = id; // next search continues below this id

            uint256 lockedBefore = wrn.ethAmountLockedForWithdrawal();
            uint128 amt = uint128(wrn.getRequest(id).amountOfEEth);

            vm.prank(owner);
            wrn.claimWithdraw(id);

            // strictly decreasing escrow, invariant preserved each iteration
            assertEq(wrn.ethAmountLockedForWithdrawal(), lockedBefore - amt, "escrow step decrement wrong");
            assertLt(wrn.ethAmountLockedForWithdrawal(), prevLocked, "escrow did not strictly decrease");
            assertEq(address(wrn).balance, wrn.ethAmountLockedForWithdrawal(), "balance/escrow invariant broken mid-drain");
            prevLocked = wrn.ethAmountLockedForWithdrawal();
            claims++;
        }
        assertGt(claims, 0, "could not claim any finalized request");
        // Generalises: each claim removes exactly its escrow and the invariant holds, so claiming
        // the full finalized-unclaimed set drives `ethAmountLockedForWithdrawal` and balance to 0.
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. The drain runs while the protocol is PAUSED (the revert window keeps everything paused
    //    except EETH/WeETH). claimWithdraw has no whenNotPaused gate, so it must still succeed.
    // ─────────────────────────────────────────────────────────────────────
    function test_claim_worksWhilePaused() public {
        _doUpgrade();
        WithdrawRequestNFT wrn = WithdrawRequestNFT(payable(WITHDRAW_REQUEST_NFT));

        (uint256 id, address owner) = _findClaimable(wrn, 0);
        require(id != 0, "no claimable request");

        // Pause the WRN via OPERATION_MULTISIG_ROLE.
        _grantSelf(wrn.roleRegistry().OPERATION_MULTISIG_ROLE());
        wrn.pause();
        assertTrue(wrn.paused(), "precondition: WRN paused");

        uint256 before = owner.balance;
        vm.prank(owner);
        wrn.claimWithdraw(id); // must NOT revert despite the pause
        assertGt(owner.balance, before, "claim blocked while paused - drain would be impossible");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. EDGE (REVERT_PLAYBOOK §6.5 edge 1): a finalized request owned by a BLACKLISTED address
    //    cannot be claimed, so its escrow stays stuck in the WRN — full drainage is impossible
    //    until the owner is un-blacklisted (or the residual is handled out-of-band).
    // ─────────────────────────────────────────────────────────────────────
    function test_blacklistedHolder_blocksClaim_escrowStuck() public {
        _doUpgrade();
        WithdrawRequestNFT wrn = WithdrawRequestNFT(payable(WITHDRAW_REQUEST_NFT));

        (uint256 id, address owner) = _findClaimable(wrn, 0);
        require(id != 0, "no claimable request");

        uint256 lockedBefore = wrn.ethAmountLockedForWithdrawal();

        // Blacklist the request owner (blacklistUser is onlyOperatingMultisig on the harness blacklister).
        _grantSelf(RoleRegistry(ROLE_REGISTRY).OPERATION_MULTISIG_ROLE());
        blacklister.blacklistUser(owner);

        // The claim reverts with the SPECIFIC blacklist error (not just any revert) — escrow
        // cannot be drained for this request.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Blacklister.BlacklistedUser.selector, owner));
        wrn.claimWithdraw(id);

        // Escrow unchanged: this request's ETH is stuck until the owner is un-blacklisted.
        assertEq(wrn.ethAmountLockedForWithdrawal(), lockedBefore, "escrow should be unchanged when claim is blocked");

        // Un-blacklisting unblocks the drain (the documented mitigation).
        blacklister.unblacklistUser(owner);
        uint128 amt = uint128(wrn.getRequest(id).amountOfEEth);
        vm.prank(owner);
        wrn.claimWithdraw(id);
        assertEq(wrn.ethAmountLockedForWithdrawal(), lockedBefore - amt, "drain should resume after un-blacklist");
    }
}
