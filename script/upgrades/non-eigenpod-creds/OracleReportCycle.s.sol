// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {EtherFiAdmin} from "@etherfi/oracle/EtherFiAdmin.sol";
import {EtherFiOracle} from "@etherfi/oracle/EtherFiOracle.sol";
import {IEtherFiOracle} from "@etherfi/oracle/interfaces/IEtherFiOracle.sol";
import {LiquidityPool} from "@etherfi/core/LiquidityPool.sol";
import {IWithdrawRequestNFT} from "@etherfi/withdrawals/interfaces/IWithdrawRequestNFT.sol";
import {StakingManager} from "@etherfi/staking/StakingManager.sol";
import {DeployNonEigenPodCreds} from "./deploy.s.sol";

/**
 * @title OracleReportCycle
 * @notice Drives a full oracle report cycle against the UPGRADED EtherFiAdmin.
 *
 * Verifying the upgrade lands (impl pointer, immutables) does not prove the oracle still works.
 * EtherFiAdmin is the oracle entry point, so this applies the upgrade and then runs a real cycle:
 * submit -> consensus -> executeTasks, asserting the rebase applies exactly and the report cursors
 * advance.
 *
 * Applies the upgrade directly from the timelock rather than through the governance batch, so it
 * stays valid regardless of what else that batch carries.
 *
 * command:
 * forge script script/upgrades/non-eigenpod-creds/OracleReportCycle.s.sol:OracleReportCycle \
 *   --fork-url $MAINNET_RPC_URL -vv
 */
contract OracleReportCycle is DeployNonEigenPodCreds {
    EtherFiOracle constant oracle = EtherFiOracle(ETHERFI_ORACLE);
    EtherFiAdmin constant etherFiAdmin = EtherFiAdmin(ETHERFI_ADMIN);
    LiquidityPool constant liquidityPool = LiquidityPool(payable(LIQUIDITY_POOL));

    /// @dev ~4.8% APR on a 2.14M ETH TVL over one 1280-slot period, inside the 10% cap and the
    ///      25 bps per-report positive rebase cap
    int128 constant ACCRUED_REWARDS = 50 ether;

    function run() public override {
        _deployAll();
        _applyUpgrade();
        _runReportCycle();
    }

    /// @dev repoints the three UUPS proxies and the node beacon straight from the upgrade timelock
    function _applyUpgrade() internal {
        vm.startPrank(UPGRADE_TIMELOCK);
        UUPSUpgradeable(ETHERFI_NODES_MANAGER).upgradeTo(etherFiNodesManagerImpl);
        UUPSUpgradeable(STAKING_MANAGER).upgradeTo(stakingManagerImpl);
        UUPSUpgradeable(ETHERFI_ADMIN).upgradeTo(etherFiAdminImpl);
        StakingManager(STAKING_MANAGER).upgradeEtherFiNode(etherFiNodeImpl);
        vm.stopPrank();

        require(getImplementation(ETHERFI_ADMIN) == etherFiAdminImpl, "EtherFiAdmin not upgraded");
        console2.log("[OK] upgrade applied. EtherFiAdmin impl:", etherFiAdminImpl);
    }

    function _runReportCycle() internal {
        // The three live committee members, quorum 3. Pranking them exercises the real consensus
        // path; the oracle config is left untouched. (Quorum cannot be lowered to 1 anyway:
        // _checkQuorum requires numActiveCommitteeMembers < 2 * quorumSize.)
        address[3] memory members = [
            0x4293664628469891C4043780874bbFe4Dc6223E2,
            0xc2f2a6308577eC02FF06221b087DBd5960792C9f,
            0x9B705E518E1Ca057c216b1a64b37d6549a72f506
        ];

        IEtherFiOracle.OracleReport memory report;
        report.consensusVersion = oracle.consensusVersion();
        report.validatorsToApprove = new uint256[](0);
        report.accruedRewards = ACCRUED_REWARDS;
        // finalize nothing new: hold the cursor at its current value, zero amount. The report must
        // never carry an id below withdrawRequestNft.lastFinalizedRequestId().
        report.lastFinalizedWithdrawalRequestId =
            IWithdrawRequestNFT(WITHDRAW_REQUEST_NFT).lastFinalizedRequestId();
        report.finalizedWithdrawalAmount = 0;

        // Roll forward until the window is finalized. Warping can also advance slotTo, so re-read
        // the stamp each pass rather than computing a single jump.
        bool ready;
        for (uint256 i = 0; i < 40 && !ready; i++) {
            (uint32 slotFrom, uint32 slotTo, uint32 blockFrom) = oracle.blockStampForNextReport();
            report.refSlotFrom = slotFrom;
            report.refSlotTo = slotTo;
            report.refBlockFrom = blockFrom;
            report.refBlockTo = uint32(block.number - 1);
            try oracle.verifyReport(report) {
                ready = true;
            } catch {
                vm.warp(block.timestamp + 32 * 12);
                vm.roll(block.number + 32);
            }
        }
        require(ready, "could not reach a finalized report window");
        console2.log("report window: refSlotFrom", report.refSlotFrom, "refSlotTo", report.refSlotTo);

        uint256 tvlBefore = liquidityPool.getTotalPooledEther();
        uint256 rateBefore = liquidityPool.amountForShare(1 ether);

        for (uint256 i = 0; i < members.length; i++) {
            vm.prank(members[i]);
            oracle.submitReport(report);
        }
        require(
            oracle.isConsensusReached(oracle.generateReportHash(report)), "consensus not reached"
        );
        console2.log("[OK] report submitted by all 3 members, consensus reached");

        uint256 wait = uint256(etherFiAdmin.postReportWaitTimeInSlots());
        vm.warp(block.timestamp + (wait + 1) * 12);
        vm.roll(block.number + wait + 1);

        // executeTasks reverts with ReportValidationFailed(reason); surface it rather than a bare bool
        if (!etherFiAdmin.canExecuteTasks(report)) {
            try etherFiAdmin.executeTasks(report) {}
            catch Error(string memory reason) {
                console2.log("executeTasks rejected the report:", reason);
                revert(reason);
            } catch (bytes memory raw) {
                if (raw.length >= 4 && bytes4(raw) == EtherFiAdmin.ReportValidationFailed.selector) {
                    console2.log("report rejected:", abi.decode(_slice(raw), (string)));
                }
                revert("executeTasks reverted, see log above");
            }
        }

        etherFiAdmin.executeTasks(report);

        require(etherFiAdmin.lastHandledReportRefSlot() == report.refSlotTo, "refSlot cursor stuck");
        require(etherFiAdmin.lastHandledReportRefBlock() == report.refBlockTo, "refBlock cursor stuck");

        uint256 tvlAfter = liquidityPool.getTotalPooledEther();
        require(
            tvlAfter == tvlBefore + uint256(uint128(ACCRUED_REWARDS)), "rebase did not apply exactly"
        );
        require(liquidityPool.amountForShare(1 ether) > rateBefore, "eETH exchange rate did not rise");

        console2.log("[OK] executeTasks succeeded on the upgraded EtherFiAdmin");
        console2.log("     TVL before:", tvlBefore);
        console2.log("     TVL after: ", tvlAfter);
        console2.log("     rate before:", rateBefore);
        console2.log("     rate after: ", liquidityPool.amountForShare(1 ether));
    }

    /// @dev strips the 4-byte selector so the ABI-encoded revert payload can be decoded
    function _slice(bytes memory raw) internal pure returns (bytes memory out) {
        out = new bytes(raw.length - 4);
        for (uint256 i = 4; i < raw.length; i++) out[i - 4] = raw[i];
    }
}
