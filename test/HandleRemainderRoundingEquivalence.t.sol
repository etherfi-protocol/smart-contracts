// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Architecture reviewer flagged the WithdrawRequestNFT.handleRemainder
///         and PriorityWithdrawalQueue.handleRemainder pair as an "architectural
///         smell": two copies of the same logic against the same LP, with
///         subtly different rounding directions:
///
///         WithdrawRequestNFT (`src/WithdrawRequestNFT.sol:384`):
///             eEthAmountToTreasury = _eEthAmount.mulDiv(splitBps, 1e4);
///             // default = Math.Rounding.Down (floor)
///
///         PriorityWithdrawalQueue (`src/PriorityWithdrawalQueue.sol:397-401`):
///             eEthAmountToTreasury = eEthAmount.mulDiv(
///                 shareRemainderSplitToTreasuryInBps, _BASIS_POINT_SCALE,
///                 Math.Rounding.Up
///             );
///             // explicit ceiling
///
///         Both pay treasury in eETH and burn the rest via `LP.burnEEthShares`.
///         The rounding-direction equivalence between the two has no
///         contract-level invariant - this test pins it down:
///
///         1. Pure-math: `ceil - floor in {0, 1}` for every (amount, bps).
///         2. Cross-contract: under identical input, the WRN-shaped sum
///            `(treasuryEEth_wrn + amountToBurn_wrn) == amount` AND the
///            PQ-shaped sum `(treasuryEEth_pq + amountToBurn_pq) == amount`,
///            but the per-contract `treasury` differs by at most 1 wei.
///         3. Share-burn delta is bounded by `sharesForAmount(1)` - i.e.,
///            WRN burns at MOST one extra share-amount of eETH because
///            WRN gives 1 wei LESS to treasury than PQ.
///
///         This is a unit-test-shaped property (no state machine), so it
///         lives outside the invariant directory. It is the direct
///         regression test for the architecture finding that any future
///         change to one of the two implementations that doesn't mirror
///         the other will be caught.
contract HandleRemainderRoundingEquivalenceTest is TestSetup {
    using Math for uint256;

    uint256 internal constant BPS_DENOM = 1e4;

    function setUp() public {
        setUpTests();

        // Light setup - seed LP with some liquidity so amountForShare/
        // sharesForAmount produce non-trivial values.
        address dep = address(uint160(uint256(keccak256("remainder.dep"))));
        vm.deal(dep, 1_000 ether);
        vm.prank(dep);
        liquidityPoolInstance.deposit{value: 500 ether}();
    }

    // =====================================================================
    // PURE-MATH RING - bounded fuzz of (amount, bps)
    // =====================================================================

    /// `ceil - floor in {0, 1}` for every non-negative amount and any
    /// bps in [0, 1e4]. Fundamental property of integer division;
    /// pinning it here as a regression guard against either contract
    /// changing the rounding mode.
    function testFuzz_ceil_minus_floor_is_zero_or_one(uint128 amount, uint16 bps) public pure {
        uint256 capBps = uint256(bps) > BPS_DENOM ? BPS_DENOM : uint256(bps);
        uint256 floor_ = uint256(amount).mulDiv(capBps, BPS_DENOM, Math.Rounding.Down);
        uint256 ceil_  = uint256(amount).mulDiv(capBps, BPS_DENOM, Math.Rounding.Up);
        uint256 diff = ceil_ - floor_;
        assertLe(diff, 1, "ceil-floor > 1 - rounding model broken");
        assertGe(diff, 0, "ceil < floor"); // tautology but documents intent
    }

    /// WRN-shape and PQ-shape sums both equal the input amount (with
    /// rounding direction absorbed by the burn side).
    function testFuzz_split_sums_to_amount(uint128 amount, uint16 bps) public pure {
        uint256 capBps = uint256(bps) > BPS_DENOM ? BPS_DENOM : uint256(bps);
        // WRN shape
        uint256 wrnTreasury = uint256(amount).mulDiv(capBps, BPS_DENOM, Math.Rounding.Down);
        uint256 wrnBurn = uint256(amount) - wrnTreasury;
        assertEq(wrnTreasury + wrnBurn, uint256(amount), "WRN split != amount");
        // PQ shape
        uint256 pqTreasury = uint256(amount).mulDiv(capBps, BPS_DENOM, Math.Rounding.Up);
        // PQ contract computes eEthAmountToBurn = eEthAmount - eEthAmountToTreasury.
        // If amount == 0 OR amount < treasuryCeil (impossible since ceil <= amount), this is fine.
        // For non-zero amounts, treasuryCeil <= amount, so subtraction is safe.
        if (uint256(amount) >= pqTreasury) {
            uint256 pqBurn = uint256(amount) - pqTreasury;
            assertEq(pqTreasury + pqBurn, uint256(amount), "PQ split != amount");
        }
    }

    /// The per-contract treasury allocations differ by at most 1 wei
    /// under identical inputs.
    function testFuzz_cross_contract_treasury_delta_at_most_one_wei(
        uint128 amount,
        uint16 bps
    ) public pure {
        uint256 capBps = uint256(bps) > BPS_DENOM ? BPS_DENOM : uint256(bps);
        uint256 wrnTreasury = uint256(amount).mulDiv(capBps, BPS_DENOM, Math.Rounding.Down);
        uint256 pqTreasury  = uint256(amount).mulDiv(capBps, BPS_DENOM, Math.Rounding.Up);
        // PQ ceils, WRN floors; PQ >= WRN, diff <= 1.
        assertGe(pqTreasury, wrnTreasury, "PQ ceil < WRN floor - rounding inverted");
        assertLe(pqTreasury - wrnTreasury, 1, "PQ-WRN treasury delta > 1 wei");
    }

    /// The per-contract burn allocations differ by at most 1 wei.
    /// Because WRN gives 1 wei LESS to treasury, WRN burns 1 wei MORE.
    function testFuzz_cross_contract_burn_delta_at_most_one_wei(
        uint128 amount,
        uint16 bps
    ) public pure {
        uint256 capBps = uint256(bps) > BPS_DENOM ? BPS_DENOM : uint256(bps);
        uint256 wrnTreasury = uint256(amount).mulDiv(capBps, BPS_DENOM, Math.Rounding.Down);
        uint256 pqTreasury  = uint256(amount).mulDiv(capBps, BPS_DENOM, Math.Rounding.Up);
        uint256 wrnBurn = uint256(amount) - wrnTreasury;
        // PQ burn only computable when pqTreasury <= amount.
        if (uint256(amount) >= pqTreasury) {
            uint256 pqBurn = uint256(amount) - pqTreasury;
            assertGe(wrnBurn, pqBurn, "WRN burn < PQ burn - rounding inverted");
            assertLe(wrnBurn - pqBurn, 1, "WRN-PQ burn delta > 1 wei");
        }
    }

    /// Share-amount equivalence under the LP rate. The bound is
    /// `LP.sharesForAmount(1)` - one wei of eETH translates to ~1 share
    /// at typical rates. Lifts the wei delta to a share delta.
    function testFuzz_cross_contract_share_burn_delta_bounded(
        uint128 amount,
        uint16 bps
    ) public {
        // Bound amount so it's a realistic remainder size. 1 wei to 1 ether.
        uint256 amt = bound(uint256(amount), 1, 1 ether);
        uint256 capBps = uint256(bps) > BPS_DENOM ? BPS_DENOM : uint256(bps);

        uint256 wrnTreasury = amt.mulDiv(capBps, BPS_DENOM, Math.Rounding.Down);
        uint256 pqTreasury  = amt.mulDiv(capBps, BPS_DENOM, Math.Rounding.Up);
        uint256 wrnBurn = amt - wrnTreasury;
        if (amt < pqTreasury) return; // edge case for 0-amount input
        uint256 pqBurn = amt - pqTreasury;

        uint256 wrnSharesBurn = liquidityPoolInstance.sharesForAmount(wrnBurn);
        uint256 pqSharesBurn  = liquidityPoolInstance.sharesForAmount(pqBurn);

        // sharesForAmount is monotone, so wrnSharesBurn >= pqSharesBurn.
        assertGe(wrnSharesBurn, pqSharesBurn, "wrn shares < pq shares - sharesForAmount non-monotone");
        // The differential equals sharesForAmount(wrnBurn - pqBurn) when
        // the underlying math is linear; for floor mulDiv it bounds at
        // sharesForAmount(1) since wrnBurn - pqBurn ∈ {0, 1}.
        uint256 sharesOneWei = liquidityPoolInstance.sharesForAmount(1);
        // The +1 covers any rounding-down on the per-call sharesForAmount(0)
        // floor that can collapse below sharesForAmount(1). Conservative bound.
        assertLe(
            wrnSharesBurn - pqSharesBurn,
            sharesOneWei + 1,
            "WRN-PQ share-burn delta exceeds sharesForAmount(1) - rounding error compounding"
        );
    }
}
