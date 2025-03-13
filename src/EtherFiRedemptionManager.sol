// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";
import "@openzeppelin-upgradeable/contracts/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/ILiquidityPool.sol";
import "./interfaces/IeETH.sol";
import "./interfaces/IWeETH.sol";

import "lib/BucketLimiter.sol";

import "./RoleRegistry.sol";

/*
    The contract allows instant redemption of eETH and weETH tokens to ETH with an exit fee.
    - It has the exit fee as a percentage of the total amount redeemed.
    - It has a rate limiter to limit the total amount that can be redeemed in a given time period.
*/
contract EtherFiRedemptionManager is Initializable, PausableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 private constant BUCKET_UNIT_SCALE = 1e12;
    uint256 private constant BASIS_POINT_SCALE = 1e4;

    bytes32 public constant ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE = keccak256("ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE");

    RoleRegistry public immutable roleRegistry;
    address public immutable treasury;
    IeETH public immutable eEth;
    IWeETH public immutable weEth;
    ILiquidityPool public immutable liquidityPool;

    BucketLimiter.Limit public limit;
    uint16 public exitFeeSplitToTreasuryInBps;
    uint16 public exitFeeInBps;
    uint16 public lowWatermarkInBpsOfTvl; // bps of TVL

    event Redeemed(address indexed receiver, uint256 redemptionAmount, uint256 feeAmountToTreasury, uint256 feeAmountToStakers);

    receive() external payable {}

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _liquidityPool, address _eEth, address _weEth, address _treasury, address _roleRegistry) {
        roleRegistry = RoleRegistry(_roleRegistry);
        treasury = _treasury;
        liquidityPool = ILiquidityPool(payable(_liquidityPool));
        eEth = IeETH(_eEth);
        weEth = IWeETH(_weEth); 

        _disableInitializers();
    }

    function initialize(uint16 _exitFeeSplitToTreasuryInBps, uint16 _exitFeeInBps, uint16 _lowWatermarkInBpsOfTvl, uint256 _bucketCapacity, uint256 _bucketRefillRate) external initializer {
        require(_exitFeeInBps <= BASIS_POINT_SCALE, "INVALID");
        require(_exitFeeSplitToTreasuryInBps <= BASIS_POINT_SCALE, "INVALID");
        require(_lowWatermarkInBpsOfTvl <= BASIS_POINT_SCALE, "INVALID");

        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        limit = BucketLimiter.create(_convertToBucketUnit(_bucketCapacity, Math.Rounding.Down), _convertToBucketUnit(_bucketRefillRate, Math.Rounding.Down));
        exitFeeSplitToTreasuryInBps = _exitFeeSplitToTreasuryInBps;
        exitFeeInBps = _exitFeeInBps;
        lowWatermarkInBpsOfTvl = _lowWatermarkInBpsOfTvl;
    }

    /**
     * @notice Redeems eETH for ETH.
     * @param eEthAmount The amount of eETH to redeem after the exit fee.
     * @param receiver The address to receive the redeemed ETH.
     */
    function redeemEEth(uint256 eEthAmount, address receiver) public whenNotPaused nonReentrant {
        _redeemEEth(eEthAmount, receiver);
    }

    /**
     * @notice Redeems weETH for ETH.
     * @param weEthAmount The amount of weETH to redeem after the exit fee.
     * @param receiver The address to receive the redeemed ETH.
     */
    function redeemWeEth(uint256 weEthAmount, address receiver) public whenNotPaused nonReentrant {
        _redeemWeEth(weEthAmount, receiver);
    }

    /**
     * @notice Redeems eETH for ETH with permit.
     * @param eEthAmount The amount of eETH to redeem after the exit fee.
     * @param receiver The address to receive the redeemed ETH.
     * @param permit The permit params.
     */
    function redeemEEthWithPermit(uint256 eEthAmount, address receiver, IeETH.PermitInput calldata permit) external whenNotPaused nonReentrant {
        try eEth.permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s) {} catch {}
        _redeemEEth(eEthAmount, receiver);
    }

    /**
     * @notice Redeems weETH for ETH.
     * @param weEthAmount The amount of weETH to redeem after the exit fee.
     * @param receiver The address to receive the redeemed ETH.
     * @param permit The permit params.
     */
    function redeemWeEthWithPermit(uint256 weEthAmount, address receiver, IWeETH.PermitInput calldata permit) external whenNotPaused nonReentrant {
        try weEth.permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s)  {} catch {}
        _redeemWeEth(weEthAmount, receiver);
    }

    /**
     * @notice Redeems ETH.
     * @param ethAmount The amount of ETH to redeem after the exit fee.
     * @param receiver The address to receive the redeemed ETH.
     */
    function _redeem(uint256 ethAmount, uint256 eEthShares, address receiver, uint256 eEthAmountToReceiver, uint256 eEthFeeAmountToTreasury, uint256 sharesToBurn, uint256 feeShareToTreasury) internal {
        _updateRateLimit(ethAmount);

        // Derive additionals
        uint256 eEthShareFee = eEthShares - sharesToBurn;
        uint256 feeShareToStakers = eEthShareFee - feeShareToTreasury;

        // Snapshot balances & shares for sanity check at the end
        uint256 prevBalance = address(this).balance;
        uint256 prevLpBalance = address(liquidityPool).balance;
        uint256 totalEEthShare = eEth.totalShares();

        // Withdraw ETH from the liquidity pool
        require(liquidityPool.withdraw(address(this), eEthAmountToReceiver) == sharesToBurn, "invalid num shares burnt");
        uint256 ethReceived = address(this).balance - prevBalance;

        // To Stakers by burning shares
        liquidityPool.burnEEthShares(feeShareToStakers);

        // To Treasury by transferring eETH
        IERC20(address(eEth)).safeTransfer(treasury, eEthFeeAmountToTreasury);
        
        // uint256 totalShares = eEth.totalShares();
        require(eEth.totalShares() >= 1 gwei && eEth.totalShares() == totalEEthShare - (sharesToBurn + feeShareToStakers), "EtherFiRedemptionManager: Invalid total shares");

        // To Receiver by transferring ETH, using gas 10k for additional safety
        (bool success, ) = receiver.call{value: ethReceived, gas: 10_000}("");
        require(success, "EtherFiRedemptionManager: Transfer failed");

        // Make sure the liquidity pool balance is correct && total shares are correct
        require(address(liquidityPool).balance == prevLpBalance - ethReceived, "EtherFiRedemptionManager: Invalid liquidity pool balance");
        // require(eEth.totalShares() >= 1 gwei && eEth.totalShares() == totalEEthShare - (sharesToBurn + feeShareToStakers), "EtherFiRedemptionManager: Invalid total shares");

        emit Redeemed(receiver, ethAmount, eEthFeeAmountToTreasury, eEthAmountToReceiver);
    }

    /**
     * @dev if the contract has less than the low watermark, it will not allow any instant redemption.
     */
    function lowWatermarkInETH() public view returns (uint256) {
        return liquidityPool.getTotalPooledEther().mulDiv(lowWatermarkInBpsOfTvl, BASIS_POINT_SCALE);
    }

    /**
     * @dev Returns the total amount that can be redeemed.
     */
    function totalRedeemableAmount() external view returns (uint256) {
        uint256 liquidEthAmount = address(liquidityPool).balance - liquidityPool.ethAmountLockedForWithdrawal();
        if (liquidEthAmount < lowWatermarkInETH()) {
            return 0;
        }
        uint64 consumableBucketUnits = BucketLimiter.consumable(limit);
        uint256 consumableAmount = _convertFromBucketUnit(consumableBucketUnits);
        return Math.min(consumableAmount, liquidEthAmount);
    }

    /**
     * @dev Returns whether the given amount can be redeemed.
     * @param amount The ETH or eETH amount to check.
     */
    function canRedeem(uint256 amount) public view returns (bool) {
        uint256 liquidEthAmount = address(liquidityPool).balance - liquidityPool.ethAmountLockedForWithdrawal();
        if (liquidEthAmount < lowWatermarkInETH()) {
            return false;
        }
        uint64 bucketUnit = _convertToBucketUnit(amount, Math.Rounding.Up);
        bool consumable = BucketLimiter.canConsume(limit, bucketUnit);
        return consumable && amount <= liquidEthAmount;
    }

    /**
     * @dev Sets the maximum size of the bucket that can be consumed in a given time period.
     * @param capacity The capacity of the bucket.
     */
    function setCapacity(uint256 capacity) external hasRole(ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE) {
        // max capacity = max(uint64) * 1e12 ~= 16 * 1e18 * 1e12 = 16 * 1e12 ether, which is practically enough
        uint64 bucketUnit = _convertToBucketUnit(capacity, Math.Rounding.Down);
        BucketLimiter.setCapacity(limit, bucketUnit);
    }

    /**
     * @dev Sets the rate at which the bucket is refilled per second.
     * @param refillRate The rate at which the bucket is refilled per second.
     */
    function setRefillRatePerSecond(uint256 refillRate) external hasRole(ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE) {
        // max refillRate = max(uint64) * 1e12 ~= 16 * 1e18 * 1e12 = 16 * 1e12 ether per second, which is practically enough
        uint64 bucketUnit = _convertToBucketUnit(refillRate, Math.Rounding.Down);
        BucketLimiter.setRefillRate(limit, bucketUnit);
    }

    /**
     * @dev Sets the exit fee.
     * @param _exitFeeInBps The exit fee.
     */
    function setExitFeeBasisPoints(uint16 _exitFeeInBps) external hasRole(ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE) {
        require(_exitFeeInBps <= BASIS_POINT_SCALE, "INVALID");
        exitFeeInBps = _exitFeeInBps;
    }

    function setLowWatermarkInBpsOfTvl(uint16 _lowWatermarkInBpsOfTvl) external hasRole(ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE) {
        require(_lowWatermarkInBpsOfTvl <= BASIS_POINT_SCALE, "INVALID");
        lowWatermarkInBpsOfTvl = _lowWatermarkInBpsOfTvl;
    }

    function setExitFeeSplitToTreasuryInBps(uint16 _exitFeeSplitToTreasuryInBps) external hasRole(ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE) {
        require(_exitFeeSplitToTreasuryInBps <= BASIS_POINT_SCALE, "INVALID");
        exitFeeSplitToTreasuryInBps = _exitFeeSplitToTreasuryInBps;
    }

    function pauseContract() external hasRole(roleRegistry.PROTOCOL_PAUSER()) {
        _pause();
    }

    function unPauseContract() external hasRole(roleRegistry.PROTOCOL_UNPAUSER()) {
        _unpause();
    }

    function _redeemEEth(uint256 eEthAmount, address receiver) internal {
        require(eEthAmount <= eEth.balanceOf(msg.sender), "EtherFiRedemptionManager: Insufficient balance");
        require(canRedeem(eEthAmount), "EtherFiRedemptionManager: Exceeded total redeemable amount");

        (uint256 eEthShares, uint256 eEthAmountToReceiver, uint256 eEthFeeAmountToTreasury, uint256 sharesToBurn, uint256 feeShareToTreasury) = _calcRedemption(eEthAmount);

        IERC20(address(eEth)).safeTransferFrom(msg.sender, address(this), eEthAmount);

        _redeem(eEthAmount, eEthShares, receiver, eEthAmountToReceiver, eEthFeeAmountToTreasury, sharesToBurn, feeShareToTreasury);
    }

    function _redeemWeEth(uint256 weEthAmount, address receiver) internal {
        uint256 eEthAmount = weEth.getEETHByWeETH(weEthAmount);
        require(weEthAmount <= weEth.balanceOf(msg.sender), "EtherFiRedemptionManager: Insufficient balance");
        require(canRedeem(eEthAmount), "EtherFiRedemptionManager: Exceeded total redeemable amount");

        (uint256 eEthShares, uint256 eEthAmountToReceiver, uint256 eEthFeeAmountToTreasury, uint256 sharesToBurn, uint256 feeShareToTreasury) = _calcRedemption(eEthAmount);

        IERC20(address(weEth)).safeTransferFrom(msg.sender, address(this), weEthAmount);
        weEth.unwrap(weEthAmount);

        _redeem(eEthAmount, eEthShares, receiver, eEthAmountToReceiver, eEthFeeAmountToTreasury, sharesToBurn, feeShareToTreasury);
    }


    function _updateRateLimit(uint256 amount) internal {
        uint64 bucketUnit = _convertToBucketUnit(amount, Math.Rounding.Up);
        require(BucketLimiter.consume(limit, bucketUnit), "BucketRateLimiter: rate limit exceeded");
    }

    function _convertToBucketUnit(uint256 amount, Math.Rounding rounding) internal pure returns (uint64) {
        require(amount < type(uint64).max * BUCKET_UNIT_SCALE, "EtherFiRedemptionManager: Amount too large");
        return (rounding == Math.Rounding.Up) ? SafeCast.toUint64((amount + BUCKET_UNIT_SCALE - 1) / BUCKET_UNIT_SCALE) : SafeCast.toUint64(amount / BUCKET_UNIT_SCALE);
    }

    function _convertFromBucketUnit(uint64 bucketUnit) internal pure returns (uint256) {
        return bucketUnit * BUCKET_UNIT_SCALE;
    }


    function _calcRedemption(uint256 ethAmount) internal view returns (uint256 eEthShares, uint256 eEthAmountToReceiver, uint256 eEthFeeAmountToTreasury, uint256 sharesToBurn, uint256 feeShareToTreasury) {
        eEthShares = liquidityPool.sharesForAmount(ethAmount);
        eEthAmountToReceiver = liquidityPool.amountForShare(eEthShares.mulDiv(BASIS_POINT_SCALE - exitFeeInBps, BASIS_POINT_SCALE)); // ethShareToReceiver

        sharesToBurn = liquidityPool.sharesForWithdrawalAmount(eEthAmountToReceiver);
        uint256 eEthShareFee = eEthShares - sharesToBurn;
        feeShareToTreasury = eEthShareFee.mulDiv(exitFeeSplitToTreasuryInBps, BASIS_POINT_SCALE);
        eEthFeeAmountToTreasury = liquidityPool.amountForShare(feeShareToTreasury);
    }

    /**
     * @dev Preview taking an exit fee on redeem. See {IERC4626-previewRedeem}.
     */
    // redeemable amount after exit fee
    function previewRedeem(uint256 shares) public view returns (uint256) {
        uint256 amountInEth = liquidityPool.amountForShare(shares);
        return amountInEth - _fee(amountInEth, exitFeeInBps);
    }

    function _fee(uint256 assets, uint256 feeBasisPoints) internal pure virtual returns (uint256) {
        return assets.mulDiv(feeBasisPoints, BASIS_POINT_SCALE, Math.Rounding.Up);
    }

    function _authorizeUpgrade(address newImplementation) internal override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    function _hasRole(bytes32 role, address account) internal view returns (bool) {
        require(roleRegistry.hasRole(role, account), "EtherFiRedemptionManager: Unauthorized");
    }

    modifier hasRole(bytes32 role) {
        _hasRole(role, msg.sender);
        _;
    }

}
